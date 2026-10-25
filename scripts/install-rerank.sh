#!/usr/bin/env bash
#
# 阶段五：部署本地 Rerank 重排服务，并注册到 WeKnora
# 适用于 OBARA 知识库系统部署 —— 阶段五
#
# 为什么单独部署：
#   Ollama 不提供 rerank 能力，WeKnora v0.8.3 的 docker-compose 也未内置 rerank 服务。
#   本脚本用 infinity（Cohere 兼容的 /rerank 接口，CPU 镜像可跑 0.6B 级模型）单独起容器，
#   权重提前下载到本机目录后以只读方式挂载，避免每次重建容器重复下载。
#   **禁止使用公有 rerank API**：检索片段同属内部资料，调用公有 API 与"数据不出内网"要求冲突。
#
# 接口约定（对齐 WeKnora internal/models/api/cohererank）：
#   POST {base_url}/rerank  {"model":..,"query":..,"documents":[..]}
#   -> {"results":[{"index":..,"relevance_score":..}], ...}
#
# 用法：
#   sudo bash scripts/install-rerank.sh                              # 下载模型 + 起容器 + 注册 + 验证
#   sudo bash scripts/install-rerank.sh --model BAAI/bge-reranker-v2-m3
#   sudo bash scripts/install-rerank.sh --model-dir /path/to/local/model
#   sudo bash scripts/install-rerank.sh --no-register                # 只起容器，不注册到 WeKnora
#   sudo bash scripts/install-rerank.sh --skip-verify                # 注册但跳过 WeKnora 侧调用验证
#   sudo bash scripts/install-rerank.sh --admin-password '<后台登录密码>'  # 非交互式注册
#   sudo bash scripts/install-rerank.sh --recreate                   # 重建容器（换模型 / 改资源限制时用）
#   sudo bash scripts/install-rerank.sh --recreate --cpus 6 --memory 4g --batch-size 8
#
# 特性：
#   - 幂等：权重已完整则跳过下载；容器存在则跳过创建；WeKnora 模型按 name 已存在则 PUT 更新
#   - 权重支持断点续传与重试，自动挑选可达的下载源（hf-mirror.com → huggingface.co）
#   - 端口冲突、容器退出、20 分钟未就绪均给出明确排查建议
#
set -euo pipefail

# ---------------------------------------------------------------- 默认参数
CONTAINER="${CONTAINER:-weknora-rerank}"
IMAGE="${IMAGE:-michaelf34/infinity}"
IMAGE_TAG="${IMAGE_TAG:-0.0.78-cpu}"       # 固定版本，不使用 latest（README 安全与运维表要求）
MIRRORS=("docker.1ms.run" "docker.xuanyuan.me")

MODEL="${MODEL:-BAAI/bge-reranker-v2-m3}"  # 默认备选；Qwen3-Reranker-0.6B 需更高版本 transformers，见部署记录
MODEL_DIR=""                           # 权重落地目录，默认 /opt/obara/rerank-models/models/<仓库名>
SERVED_NAME=""                         # 对外暴露的模型名，默认取 MODEL 的仓库名
PORT="7997"
STORE_DIR="/opt/obara/rerank-models"
ENGINE="torch"                         # torch（兼容性最好）；optimum（ONNX，部分模型不支持）
DTYPE="float32"                        # CPU 推理显式指定，避免自动选到不支持的精度
MEM_LIMIT="4g"                         # 必须限制容器上限，避免与 WeKnora 争抢主机内存
CPUS="4"                               # 本机 12 核；实测 2 核→6 核延迟下降约 35%
BATCH_SIZE="8"

WEKNORA_DIR="${WEKNORA_DIR:-/opt/obara/weknora}"
BASE_URL="${BASE_URL:-http://127.0.0.1:8080}"
ADMIN_EMAIL="${ADMIN_EMAIL:-admin@obara.local}"
ADMIN_USER="${ADMIN_USER:-admin}"
ADMIN_PASSWORD="${ADMIN_PASSWORD:-}"   # 也可通过环境变量传入：sudo ADMIN_PASSWORD='xxx' bash scripts/install-rerank.sh
HOST_IP="${HOST_IP:-}"
NO_REGISTER="false"
SKIP_VERIFY="false"
RECREATE="false"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --model)          MODEL="${2}"; shift 2 ;;
    --model-dir)      MODEL_DIR="${2}"; shift 2 ;;
    --served-name)    SERVED_NAME="${2}"; shift 2 ;;
    --container)      CONTAINER="${2}"; shift 2 ;;
    --image)          IMAGE="${2}"; shift 2 ;;
    --tag)            IMAGE_TAG="${2}"; shift 2 ;;
    --port)           PORT="${2}"; shift 2 ;;
    --store-dir)      STORE_DIR="${2}"; shift 2 ;;
    --engine)         ENGINE="${2}"; shift 2 ;;
    --dtype)          DTYPE="${2}"; shift 2 ;;
    --memory)         MEM_LIMIT="${2}"; shift 2 ;;
    --cpus)           CPUS="${2}"; shift 2 ;;
    --batch-size)     BATCH_SIZE="${2}"; shift 2 ;;
    --weknora-dir)    WEKNORA_DIR="${2}"; shift 2 ;;
    --base-url)       BASE_URL="${2}"; shift 2 ;;
    --admin-email)    ADMIN_EMAIL="${2}"; shift 2 ;;
    --admin-user)     ADMIN_USER="${2}"; shift 2 ;;
    --admin-password) ADMIN_PASSWORD="${2}"; shift 2 ;;
    --host-ip)        HOST_IP="${2}"; shift 2 ;;
    --no-register)    NO_REGISTER="true"; shift ;;
    --skip-verify)    SKIP_VERIFY="true"; shift ;;
    --recreate)       RECREATE="true"; shift ;;
    -h|--help)
      sed -n '2,29p' "$0"; exit 0 ;;
    *) echo "❌ 未知参数：$1（--help 查看用法）" >&2; exit 1 ;;
  esac
done

MODEL_BASENAME="${MODEL##*/}"
[[ -z "${SERVED_NAME}" ]] && SERVED_NAME="${MODEL_BASENAME}"
[[ -z "${MODEL_DIR}" ]] && MODEL_DIR="${STORE_DIR}/models/${MODEL_BASENAME}"

API="${BASE_URL}/api/v1"
GATEWAY_IP="127.0.0.1"
json_field() { python3 -c "import sys,json;d=json.load(sys.stdin);print(${1})" 2>/dev/null || true; }

# ---------------------------------------------------------------- 1. 前置检查
echo "==> [1/8] 前置检查"
if [[ "$(id -u)" -ne 0 ]]; then
  echo "❌ 请以 root 权限执行：sudo bash $0" >&2; exit 1
fi
for bin in docker curl python3; do
  command -v "${bin}" >/dev/null 2>&1 || { echo "❌ 缺少依赖：${bin}" >&2; exit 1; }
done
docker info >/dev/null 2>&1 || { echo "❌ Docker 守护进程不可用" >&2; exit 1; }

# 宿主 IP：WeKnora 跑在容器内，不能填 localhost，需从容器视角可达的宿主地址
if [[ -z "${HOST_IP}" ]]; then
  HOST_IP="$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1); exit}')"
fi
[[ -z "${HOST_IP}" ]] && HOST_IP="127.0.0.1"
RERANK_BASE_URL="http://${HOST_IP}:${PORT}"

if [[ -z "$(docker ps -a --filter "name=^/${CONTAINER}$" --format '{{.Names}}')" ]] \
   && command -v ss >/dev/null 2>&1 && ss -lnt "sport = :${PORT}" 2>/dev/null | grep -q LISTEN; then
  echo "❌ 宿主端口 ${PORT} 已被占用；请加 --port 换端口或先释放" >&2
  ss -lntp "sport = :${PORT}" 2>/dev/null | sed -n '2p'
  exit 1
fi
echo "    镜像：${IMAGE}:${IMAGE_TAG}"
echo "    模型：${MODEL}（对外名 ${SERVED_NAME}）"
echo "    权重目录：${MODEL_DIR}"
echo "    端口：${PORT}   资源上限：${CPUS} 核 / ${MEM_LIMIT}   batch=${BATCH_SIZE}"
echo "    WeKnora 侧 Base URL：${RERANK_BASE_URL}"

# ---------------------------------------------------------------- 2. 容器镜像
echo "==> [2/8] 准备容器镜像"
if ! docker pull "${IMAGE}:${IMAGE_TAG}" >/dev/null 2>&1; then
  echo "    直连 Docker Hub 失败，尝试国内镜像源…"
  pulled="false"
  for m in "${MIRRORS[@]}"; do
    echo "    尝试 ${m}/${IMAGE}:${IMAGE_TAG}"
    if docker pull "${m}/${IMAGE}:${IMAGE_TAG}" >/dev/null 2>&1; then
      docker tag "${m}/${IMAGE}:${IMAGE_TAG}" "${IMAGE}:${IMAGE_TAG}"
      pulled="true"; break
    fi
  done
  [[ "${pulled}" == "true" ]] || { echo "❌ 镜像拉取失败，请检查加速器配置（fix-docker-env.sh）后重试" >&2; exit 1; }
fi
SIZE_BYTES="$(docker image inspect "${IMAGE}:${IMAGE_TAG}" --format '{{.Size}}')"
echo "    镜像就绪：${IMAGE}:${IMAGE_TAG}（$(awk -v s="${SIZE_BYTES}" 'BEGIN{printf "%.0f MB", s/1048576}')）"

# ---------------------------------------------------------------- 3. 下载模型权重
# MOUNT_DIR 是容器内的权重根：本地目录以只读方式挂载，模型以本地路径加载，避免依赖容器内网络
MOUNT_DIR="/opt/obara/models"
CONTAINER_MODEL_DIR="${MOUNT_DIR}/${MODEL_BASENAME}"

if [[ -d "${MODEL_DIR}" ]] && compgen -G "${MODEL_DIR}/*" > /dev/null; then
  echo "==> [3/8] 权重目录已存在：${MODEL_DIR}（跳过下载；如需更新请手动删除后重跑）"
  du -sh "${MODEL_DIR}" | awk '{print "    已占用："$1}'
else
  echo "==> [3/8] 下载模型权重：${MODEL}"
  HF_ENDPOINT=""
  for ep in "https://hf-mirror.com" "https://huggingface.co"; do
    echo "    探测源：${ep}"
    if curl -fsSL --connect-timeout 10 --max-time 25 -o /dev/null -w '%{http_code}' \
         "${ep}/${MODEL}/resolve/main/config.json" 2>/dev/null | grep -q '^200$'; then
      HF_ENDPOINT="${ep}"; break
    fi
  done
  if [[ -z "${HF_ENDPOINT}" ]]; then
    echo "❌ hf-mirror.com 与 huggingface.co 均不可达，无法下载权重" >&2
    echo "   处理：确认临时出站权限（README 3.2 节网络策略）；或在有网环境下载后放入 ${MODEL_DIR}" >&2
    exit 1
  fi
  echo "    下载源：${HF_ENDPOINT}"

  # 取文件清单（含大小，用于断点续传与完整性校验）
  # recursive=true：部分仓库把推理文件放在子目录（如 optimum 所需的 onnx/model.onnx）
  FILE_LIST="$(curl -fsSL --connect-timeout 10 --max-time 30 "${HF_ENDPOINT}/api/models/${MODEL}/tree/main?recursive=true" \
    | python3 -c "
import sys,json
skip = {'.gitattributes'}
rows = []
for f in json.load(sys.stdin):
    if f.get('type') != 'file':
        continue
    rows.append((f.get('path',''), f.get('size',0)))
paths = {p for p,_ in rows}
# 同时提供 safetensors 与 pytorch_model.bin 时只取前者，省一半下载量
if 'model.safetensors' in paths:
    rows = [r for r in rows if r[0] != 'pytorch_model.bin']
for p, s in rows:
    if p in skip:
        continue
    print(f'{p} {s}')
" 2>/dev/null || true)"
  if [[ -z "${FILE_LIST}" ]]; then
    # API 不可用时退化为固定清单（覆盖 sentence-transformers / transformers 常见文件）
    FILE_LIST="config.json 0
tokenizer_config.json 0
tokenizer.json 0
vocab.json 0
merges.txt 0
generation_config.json 0
sentence_bert_config.json 0
config_sentence_transformers.json 0
modules.json 0
model.safetensors 0"
  fi

  mkdir -p "${MODEL_DIR}"
  while read -r rel expected; do
    [[ -z "${rel}" ]] && continue
    target="${MODEL_DIR}/${rel}"
    mkdir -p "$(dirname "${target}")"
    if [[ -f "${target}" && "${expected}" != "0" && "$(stat -c %s "${target}")" == "${expected}" ]]; then
      echo "    跳过（已完整）：${rel}"
      continue
    fi
    echo "    下载：${rel}（$(awk -v s="${expected}" 'BEGIN{printf "%.1f MB", s/1048576}')）"
    for attempt in 1 2 3 4 5; do
      if curl -fL --connect-timeout 15 -C - --retry 2 --retry-delay 3 \
              -o "${target}" "${HF_ENDPOINT}/${MODEL}/resolve/main/${rel}"; then
        break
      fi
      echo "      失败，重试（${attempt}/5）…"
      sleep 8
    done
    [[ -f "${target}" ]] || { echo "❌ ${rel} 下载失败" >&2; exit 1; }
  done <<< "${FILE_LIST}"
  du -sh "${MODEL_DIR}" | awk '{print "    权重落盘完成，占用："$1}'
fi

# ---------------------------------------------------------------- 4. 启动容器
echo "==> [4/8] 启动 rerank 容器"
if [[ -n "$(docker ps -a --filter "name=^/${CONTAINER}$" --format '{{.Names}}')" ]]; then
  if [[ "${RECREATE}" == "true" ]]; then
    echo "    --recreate：删除旧容器"
    docker rm -f "${CONTAINER}" >/dev/null
  else
    echo "    容器 ${CONTAINER} 已存在（$(docker inspect -f '{{.State.Status}}' "${CONTAINER}")），跳过创建"
    echo "    换模型 / 改资源限制请加 --recreate"
  fi
fi

if [[ -z "$(docker ps -a --filter "name=^/${CONTAINER}$" --format '{{.Names}}')" ]]; then
  # 端口发布到 0.0.0.0：WeKnora 在另一个容器里，需经宿主 IP 访问；来源限制由内网端口管控负责
  docker run -d \
    --name "${CONTAINER}" \
    --restart unless-stopped \
    -p "${PORT}:${PORT}" \
    -v "${MODEL_DIR}:${CONTAINER_MODEL_DIR}:ro" \
    -e "HF_HUB_OFFLINE=1" \
    -e "TRANSFORMERS_OFFLINE=1" \
    --memory="${MEM_LIMIT}" --memory-swap="${MEM_LIMIT}" \
    --cpus="${CPUS}" \
    --shm-size=1g \
    "${IMAGE}:${IMAGE_TAG}" \
    v2 --model-id "${CONTAINER_MODEL_DIR}" --served-model-name "${SERVED_NAME}" \
       --engine "${ENGINE}" --dtype "${DTYPE}" --device cpu \
       --batch-size "${BATCH_SIZE}" --port "${PORT}" --host 0.0.0.0 >/dev/null
  echo "    容器已创建（首次加载会做 warmup，视 CPU 需数十秒到数分钟）"
fi

# ---------------------------------------------------------------- 5. 等待就绪
# /models 返回能力列表即代表模型已加载完成；只探 /health 会得到 {"unix":...} 的假就绪
echo "==> [5/8] 等待模型加载就绪"
ready="false"
for i in $(seq 1 120); do
  if models="$(curl -fsS --max-time 5 "http://${GATEWAY_IP}:${PORT}/models" 2>/dev/null)"; then
    if printf '%s' "${models}" | grep -q '"capabilities"'; then
      ready="true"
      echo "    服务就绪（等待 $((i*10)) 秒）"
      printf '%s' "${models}" | python3 -c "
import sys,json
d=json.load(sys.stdin)
for m in d.get('data',[]):
    print(f\"    模型 {m.get('id')}: backend={m.get('backend')} capabilities={m.get('capabilities')}\")
"
      break
    fi
  fi
  if ! docker ps --filter "name=^/${CONTAINER}$" --format '{{.Status}}' | grep -q 'Up'; then
    echo "❌ 容器已退出，日志尾部：" >&2
    docker logs --tail 40 "${CONTAINER}" >&2 || true
    echo "处置：内存不足时下调 batch-size（默认 4）或换更小模型；详见 README 阶段五踩坑表" >&2
    exit 1
  fi
  sleep 10
done
if [[ "${ready}" != "true" ]]; then
  echo "❌ 20 分钟内未就绪，日志尾部如下：" >&2
  docker logs --tail 60 "${CONTAINER}" >&2 || true
  exit 1
fi
docker stats --no-stream --format '    资源占用：内存 {{.MemUsage}}  CPU {{.CPUPerc}}' "${CONTAINER}"

# ---------------------------------------------------------------- 6. 接口冒烟测试
echo "==> [6/8] 冒烟测试（中文查询 + 一组候选片段）"
python3 - "http://${GATEWAY_IP}:${PORT}" "${SERVED_NAME}" <<'PY'
import json, sys, time, urllib.request

base, model = sys.argv[1], sys.argv[2]
query = "电极的使用寿命一般是多久？"
docs = [
    "电极的使用寿命取决于使用工况、电流密度与维护周期，规范要求在累计运行 800 小时后必须更换。",
    "员工报销流程管理办法：差旅费用需在返回后 30 个工作日内提交审批。",
    "The electrode service life is defined as 800 operating hours before mandatory replacement.",
]
req = urllib.request.Request(
    f"{base}/rerank",
    data=json.dumps({"model": model, "query": query, "documents": docs}).encode(),
    headers={"Content-Type": "application/json"})
t0 = time.time()
with urllib.request.urlopen(req, timeout=180) as r:
    resp = json.load(r)
elapsed = time.time() - t0
results = sorted(resp.get("results", []),
                 key=lambda x: -x.get("relevance_score", x.get("score", 0)))
for rank, item in enumerate(results, 1):
    text = docs[item.get("index", -1)] if 0 <= item.get("index", -1) < len(docs) else ""
    print(f"    #{rank} idx={item.get('index')} score={item.get('relevance_score'):.4f}  {text[:34]}…")
top = results[0].get("index") if results else -1
verdict = "PASS（相关片段排在首位）" if top in (0, 2) else "⚠️ 首位不是相关片段，建议换模型（如 BAAI/bge-reranker-v2-m3）复核"
print(f"    耗时 {elapsed:.2f}s / {len(docs)} 条候选   {verdict}")
PY

# ---------------------------------------------------------------- 7. 注册到 WeKnora
if [[ "${NO_REGISTER}" == "true" ]]; then
  echo "==> [7/8] 已指定 --no-register，跳过注册"
  echo
  echo "🎉 阶段五（服务部分）完成：${RERANK_BASE_URL}/rerank"
  exit 0
fi

echo "==> [7/8] 注册到 WeKnora（${API}）"
if ! curl -fsS -m 10 "${BASE_URL}/health" >/dev/null 2>&1; then
  echo "❌ WeKnora 未就绪，跳过注册；请先：cd ${WEKNORA_DIR} && docker compose up -d" >&2
  exit 1
fi

echo "    认证（${ADMIN_EMAIL}）"
if [[ -z "${ADMIN_PASSWORD}" ]]; then
  read -rsp "    未指定后台管理员密码，请输入 ${ADMIN_EMAIL} 的密码：" ADMIN_PASSWORD
  echo
fi
LOGIN_RESP="$(curl -s -m 20 -X POST "${API}/auth/login" -H 'Content-Type: application/json' \
  -d "$(python3 -c "import json,sys;print(json.dumps({'email':sys.argv[1],'password':sys.argv[2]}))" "${ADMIN_EMAIL}" "${ADMIN_PASSWORD}")" || true)"
TOKEN="$(printf '%s' "${LOGIN_RESP}" | json_field "d.get('token','')")"
if [[ -z "${TOKEN}" ]]; then
  echo "❌ 登录失败：账号不存在或密码不正确（响应：$(printf '%s' "${LOGIN_RESP}" | head -c 200)）" >&2
  echo "   处理：用已知管理员密码重跑" >&2
  echo "        sudo ADMIN_PASSWORD='<后台登录密码>' bash $0 [--model ...]" >&2
  echo "   或先加 --no-register 完成服务部署，再到管理后台手工注册（README 阶段五）" >&2
  exit 1
fi
AUTH=(-H "Authorization: Bearer ${TOKEN}")

# source 必须为 remote：填厂商名或 local 会被判为"本地模型"并触发 Ollama 下载失败（阶段四已踩坑）
payload="$(SERVED_NAME="${SERVED_NAME}" MODEL="${MODEL}" RERANK_BASE_URL="${RERANK_BASE_URL}" python3 - <<'PY'
import json, os
name = os.environ["SERVED_NAME"]; repo = os.environ["MODEL"]; base = os.environ["RERANK_BASE_URL"]
print(json.dumps({
    "name": name,
    "display_name": f"{repo}（本地 Rerank）",
    "type": "Rerank",
    "source": "remote",
    "description": f"内网本地重排服务：{repo}，经 infinity 提供 Cohere 兼容的 /rerank 接口",
    "parameters": {"base_url": base, "api_key": "", "provider": "generic"},
}, ensure_ascii=False))
PY
)"

model_id="$(SERVED_NAME="${SERVED_NAME}" python3 -c "
import sys,json,os
try:
    d=json.load(sys.stdin)
    print(next((m['id'] for m in d.get('data',[]) if m.get('name')==os.environ['SERVED_NAME']),''))
except Exception: print('')
" <<< "$(curl -s -m 20 "${API}/models" "${AUTH[@]}")" 2>/dev/null || true)"
if [[ -n "${model_id}" ]]; then
  curl -fsS -m 30 -X PUT "${API}/models/${model_id}" "${AUTH[@]}" -H 'Content-Type: application/json' -d "${payload}" >/dev/null
  echo "    ✅ 已更新模型记录：${SERVED_NAME}"
else
  curl -fsS -m 30 -X POST "${API}/models" "${AUTH[@]}" -H 'Content-Type: application/json' -d "${payload}" >/dev/null
  echo "    ✅ 已创建模型记录：${SERVED_NAME}"
fi

curl -s -m 20 "${API}/models" "${AUTH[@]}" | python3 -c "
import sys,json
d=json.load(sys.stdin)
for m in d.get('data',[]):
    print(f\"    {m['name']:<26} type={m['type']:<12} source={m['source']:<7} status={m['status']}\")
"

# ---------------------------------------------------------------- 8. WeKnora 侧调用验证
echo "==> [8/8] WeKnora 侧调用验证"
if [[ "${SKIP_VERIFY}" == "true" ]]; then
  echo "    已跳过（--skip-verify）"
  model_id=""
fi
if [[ -z "${model_id:-}" ]]; then
  model_id="$(SERVED_NAME="${SERVED_NAME}" python3 -c "
import sys,json,os
try:
    d=json.load(sys.stdin)
    print(next((m['id'] for m in d.get('data',[]) if m.get('name')==os.environ['SERVED_NAME']),''))
except Exception: print('')
" <<< "$(curl -s -m 20 "${API}/models" "${AUTH[@]}")" 2>/dev/null || true)"
fi
if [[ -n "${model_id}" && "${SKIP_VERIFY}" != "true" ]]; then
  # debug 接口要求 documents 是一个 JSON 字符串数组（见 handler/model.go: c.PostForm("documents")）
  docs_json="$(python3 -c "
import json
print(json.dumps([
    '电极的使用寿命取决于工况与维护周期，规范要求累计运行 800 小时后更换',
    '员工报销流程管理办法规定了差旅费用的审批时限',
    'Electrode service life is 800 operating hours before mandatory replacement',
], ensure_ascii=False))")"
  out="$(curl -s -m 180 -X POST "${API}/models/${model_id}/debug" "${AUTH[@]}" \
    -F "input=电极的使用寿命是多久？" \
    -F "documents=${docs_json}")"
  printf '%s' "${out}" | python3 -c "
import sys,json
raw=sys.stdin.read()
try:
    d=json.loads(raw)['data']
    rr=d.get('raw_response')
    items=(rr or {}).get('results', []) if isinstance(rr, dict) else (rr or [])
    print(f\"    ok={d.get('ok')}  耗时={d.get('elapsed_ms')}ms  结果数={len(items)}\")
    for item in items:
        text=(item.get('document') or {}).get('text','')
        print(f\"      idx={item.get('index')} score={item.get('relevance_score'):.4f} {text[:30]}\")
except Exception:
    print('    解析失败 ->', raw[:300])
"
fi

echo
echo "🎉 阶段五完成"
echo "   rerank 服务：${RERANK_BASE_URL}/rerank（容器 ${CONTAINER}）"
echo "   权重目录：${MODEL_DIR}   容器日志：docker logs -f ${CONTAINER}"
echo "   下一步（阶段六）：建库时启用 Rerank，按 README 2.2 节设置 rerank_top_k / rerank_threshold"
