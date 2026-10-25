#!/usr/bin/env bash
#
# 配置阶段四模型：DeepSeek 对话模型（OpenAI 兼容）+ 本地 Ollama 向量模型
# 适用于 OBARA 知识库系统部署 —— 阶段四
#
# 用法：
#   sudo bash scripts/configure-deepseek.sh                     # 密钥取自 .secrets 或环境变量
#   sudo bash scripts/configure-deepseek.sh --api-key sk-xxxxx   # 显式传入密钥
#   sudo bash scripts/configure-deepseek.sh --skip-verify       # 只注册，不做上游连通性验证
#   sudo bash scripts/configure-deepseek.sh --base-url http://127.0.0.1:8080 \
#        --admin-email admin@obara.local --admin-password 'xxxxx'
#
# 特性：
#   - 幂等：按模型 name 判断是否已存在，已存在则执行更新而非重复创建
#   - 密钥不写日志：请求体经 sed 脱敏后输出；密钥只落盘到 700/600 权限的 .secrets
#   - 自动创建管理员账号（首次执行），后续执行直接登录
#
set -euo pipefail

# ---------------------------------------------------------------- 默认参数
WEKNORA_DIR="${WEKNORA_DIR:-/opt/obara/weknora}"
BASE_URL="${BASE_URL:-http://127.0.0.1:8080}"
ADMIN_EMAIL="${ADMIN_EMAIL:-admin@obara.local}"
ADMIN_USER="${ADMIN_USER:-admin}"
ADMIN_PASSWORD="${ADMIN_PASSWORD:-}"
API_KEY="${DEEPSEEK_API_KEY:-}"
DS_BASE_URL="${DS_BASE_URL:-https://api.deepseek.com/v1}"
OLLAMA_URL="${OLLAMA_URL:-http://192.168.227.133:11434}"
EMBED_MODEL="${EMBED_MODEL:-bge-m3}"
EMBED_DIM="${EMBED_DIM:-1024}"
SKIP_VERIFY="false"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --api-key)         API_KEY="${2:-}"; shift 2 ;;
    --base-url)        BASE_URL="${2}"; shift 2 ;;
    --weknora-dir)     WEKNORA_DIR="${2}"; shift 2 ;;
    --admin-email)     ADMIN_EMAIL="${2}"; shift 2 ;;
    --admin-user)      ADMIN_USER="${2}"; shift 2 ;;
    --admin-password)  ADMIN_PASSWORD="${2}"; shift 2 ;;
    --ds-base-url)     DS_BASE_URL="${2}"; shift 2 ;;
    --ollama-url)      OLLAMA_URL="${2}"; shift 2 ;;
    --embed-model)     EMBED_MODEL="${2}"; shift 2 ;;
    --embed-dim)       EMBED_DIM="${2}"; shift 2 ;;
    --skip-verify)     SKIP_VERIFY="true"; shift ;;
    -h|--help)
      sed -n '2,25p' "$0"; exit 0 ;;
    *) echo "❌ 未知参数：$1（--help 查看用法）" >&2; exit 1 ;;
  esac
done

# ---------------------------------------------------------------- 基础检查
if [[ "$(id -u)" -ne 0 ]]; then
  echo "❌ 请以 root 权限执行：sudo bash $0" >&2
  exit 1
fi

for bin in curl python3; do
  command -v "${bin}" >/dev/null 2>&1 || { echo "❌ 缺少依赖：${bin}" >&2; exit 1; }
done

API="${BASE_URL}/api/v1"

# ---------------------------------------------------------------- 1. 健康检查
echo "==> [1/5] 检查 WeKnora 服务（${BASE_URL}）"
if ! curl -fsS -m 10 "${BASE_URL}/health" >/dev/null 2>&1; then
  echo "❌ WeKnora 未就绪，请先启动：cd ${WEKNORA_DIR} && docker compose up -d" >&2
  exit 1
fi
echo "    健康检查通过"

# ---------------------------------------------------------------- 2. 获取密钥
echo "==> [2/5] 读取 DeepSeek API 密钥"
SECRET_FILE="${WEKNORA_DIR}/.secrets/deepseek.env"
if [[ -z "${API_KEY}" && -f "${SECRET_FILE}" ]]; then
  # shellcheck disable=SC1090
  source <(grep -E '^\s*DEEPSEEK_API_KEY=' "${SECRET_FILE}" || true)
  API_KEY="${DEEPSEEK_API_KEY:-}"
fi
if [[ -z "${API_KEY}" ]]; then
  read -rsp "    未找到密钥，请输入 DeepSeek API Key（sk-...）：" API_KEY
  echo
fi
if [[ "${API_KEY}" != sk-* ]]; then
  echo "❌ 密钥格式不正确（应以 sk- 开头）" >&2
  exit 1
fi
masked_key() { printf '%s' "${API_KEY}" | sed -E 's/^(sk-).*(.{4})$/\1****\2/'; }
echo "    密钥已加载：$(masked_key)"

# 落盘保存（幂等，权限收紧）
install -d -m 700 "${WEKNORA_DIR}/.secrets"
printf 'DEEPSEEK_API_KEY=%s\n' "${API_KEY}" > "${SECRET_FILE}"
chmod 600 "${SECRET_FILE}"

# ---------------------------------------------------------------- 3. 登录 / 注册管理员
echo "==> [3/5] 认证（${ADMIN_EMAIL}）"
json_field() { python3 -c "import sys,json;d=json.load(sys.stdin);print(${1})" 2>/dev/null || true; }

LOGIN_RESP="$(curl -s -m 20 -X POST "${API}/auth/login" \
  -H 'Content-Type: application/json' \
  -d "$(python3 -c "import json,sys;print(json.dumps({'email':sys.argv[1],'password':sys.argv[2]}))" "${ADMIN_EMAIL}" "${ADMIN_PASSWORD}")" || true)"

TOKEN="$(printf '%s' "${LOGIN_RESP}" | json_field "d.get('token','')")"
if [[ -z "${TOKEN}" ]]; then
  echo "    账号不存在，尝试注册…"
  if [[ -z "${ADMIN_PASSWORD}" ]]; then
    ADMIN_PASSWORD="$(head -c 18 /dev/urandom | base64 | tr -d '/+=' | head -c 16)Aa1!"
    GENERATED_PW="true"
  fi
  curl -fsS -m 20 -X POST "${API}/auth/register" \
    -H 'Content-Type: application/json' \
    -d "$(python3 -c "import json,sys;print(json.dumps({'username':sys.argv[1],'email':sys.argv[2],'password':sys.argv[3]}))" "${ADMIN_USER}" "${ADMIN_EMAIL}" "${ADMIN_PASSWORD}")" >/dev/null
  LOGIN_RESP="$(curl -s -m 20 -X POST "${API}/auth/login" \
    -H 'Content-Type: application/json' \
    -d "$(python3 -c "import json,sys;print(json.dumps({'email':sys.argv[1],'password':sys.argv[2]}))" "${ADMIN_EMAIL}" "${ADMIN_PASSWORD}")")"
  TOKEN="$(printf '%s' "${LOGIN_RESP}" | json_field "d.get('token','')")"
fi
if [[ -z "${TOKEN}" ]]; then
  echo "❌ 认证失败，请检查账号密码或 DISABLE_REGISTRATION 配置" >&2
  exit 1
fi
echo "    认证成功"

AUTH=(-H "Authorization: Bearer ${TOKEN}")

# ---------------------------------------------------------------- 4. 注册模型
# 说明：source 必须为 remote —— 只有 remote 会直接置为 active；
#       填厂商名（deepseek）会被当成"本地模型"触发 Ollama 下载并失败。
echo "==> [4/5] 注册模型"

upsert_model() {
  local name="$1" display="$2" mtype="$3" source="$4" desc="$5" payload="$6"
  local existing_id
  existing_id="$(curl -s -m 20 "${API}/models" "${AUTH[@]}" \
    | python3 -c "
import sys,json
try:
    d=json.load(sys.stdin)
    for m in d.get('data',[]):
        if m.get('name')==sys.argv[1]:
            print(m['id']); break
except Exception: pass
" "${name}")"

  if [[ -n "${existing_id}" ]]; then
    curl -fsS -m 30 -X PUT "${API}/models/${existing_id}" "${AUTH[@]}" \
      -H 'Content-Type: application/json' -d "${payload}" >/dev/null
    echo "    ✅ 已更新：${display}（${name}）"
  else
    curl -fsS -m 30 -X POST "${API}/models" "${AUTH[@]}" \
      -H 'Content-Type: application/json' -d "${payload}" >/dev/null
    echo "    ✅ 已创建：${display}（${name}）"
  fi
}

build_payload() {
  python3 - "$@" <<'PY'
import json, sys
name, display, mtype, source, desc, base_url, api_key, provider, dim = sys.argv[1:10]
params = {"base_url": base_url, "api_key": api_key, "provider": provider}
if mtype == "Embedding":
    params["embedding_parameters"] = {
        "dimension": int(dim),
        "truncate_prompt_tokens": 0,
        "supports_dimension_override": False,
    }
else:
    params["context_window"] = 1000000
    params["max_output_tokens"] = 384000
print(json.dumps({
    "name": name, "display_name": display, "type": mtype,
    "source": source, "description": desc, "parameters": params,
}, ensure_ascii=False))
PY
}

# 4-1 本地 Ollama 向量模型
upsert_model "${EMBED_MODEL}" "${EMBED_MODEL}（本地 Ollama）" "Embedding" "local" \
  "本地 Ollama 向量模型：1024 维 / 8192 上下文 / 100+ 语种，跨语种检索强" \
  "$(build_payload "${EMBED_MODEL}" "${EMBED_MODEL}（本地 Ollama）" "Embedding" "local" "本地 Ollama 向量模型" "${OLLAMA_URL}" "" "generic" "${EMBED_DIM}")"

# 4-2 DeepSeek 快速问答
upsert_model "deepseek-flash" "DeepSeek V4.1 Flash（快速问答）" "KnowledgeQA" "remote" \
  "DeepSeek-V4.1-Flash：快速问答档位，日常知识库问答默认走此模型" \
  "$(build_payload "deepseek-flash" "DeepSeek V4.1 Flash（快速问答）" "KnowledgeQA" "remote" "DeepSeek 快速问答" "${DS_BASE_URL}" "${API_KEY}" "deepseek" "0")"

# 4-3 DeepSeek 智能推理
upsert_model "deepseek-v4-pro" "DeepSeek V4 Pro（智能推理）" "KnowledgeQA" "remote" \
  "DeepSeek V4 Pro：复杂多跳问题与深度推理档位" \
  "$(build_payload "deepseek-v4-pro" "DeepSeek V4 Pro（智能推理）" "KnowledgeQA" "remote" "DeepSeek 智能推理" "${DS_BASE_URL}" "${API_KEY}" "deepseek" "0")"

# ---------------------------------------------------------------- 5. 验证
echo "==> [5/5] 连通性验证"
if [[ "${SKIP_VERIFY}" == "true" ]]; then
  echo "    已跳过（--skip-verify）"
  exit 0
fi

curl -s -m 30 "${API}/models" "${AUTH[@]}" | python3 -c "
import sys,json
d=json.load(sys.stdin)
for m in d.get('data',[]):
    print(f\"    {m['name']:<16} type={m['type']:<12} source={m['source']:<7} status={m['status']:<10} key={m['credentials']['api_key']['configured']}\")
"

verify() {
  local id="$1" label="$2" input="$3"
  [[ -z "${id}" ]] && { echo "    ${label}: 未找到模型 ID，跳过"; return 0; }
  local out
  out="$(curl -s -m 180 -X POST "${API}/models/${id}/debug" "${AUTH[@]}" -F "input=${input}")"
  printf '%s' "${out}" | python3 -c "
import sys,json
raw=sys.stdin.read()
try:
    d=json.loads(raw)['data']
    ok=d.get('ok'); el=d.get('elapsed_ms')
    obs=d.get('observations') or {}
    r=d.get('raw_response')
    if isinstance(r, list):            # embedding 返回向量数组
        out='向量长度=%d' % len(r)
    elif isinstance(r, dict):
        out='输出=%s' % (r.get('content') or '')[:60]
    else:
        out='输出=%s' % str(r)[:60]
    print(f'    $label: ok={ok} 耗时={el}ms 维度={obs.get(\"dimension\",\"-\")} {out}')
except Exception:
    print('    $label: 解析失败 ->', raw[:200])
"
}

echo "    上游调用验证（会产生少量费用）："
verify "$(curl -s -m 20 "${API}/models" "${AUTH[@]}" | python3 -c "
import sys,json
d=json.load(sys.stdin)
print(next((m['id'] for m in d.get('data',[]) if m.get('name')=='deepseek-flash'),''))
")" "deepseek-flash    " "请用一句话回答：1+1等于几？"
verify "$(curl -s -m 20 "${API}/models" "${AUTH[@]}" | python3 -c "
import sys,json
d=json.load(sys.stdin)
print(next((m['id'] for m in d.get('data',[]) if m.get('name')=='deepseek-v4-pro'),''))
")" "deepseek-v4-pro   " "请用一句话回答：水的化学式是什么？"
verify "$(curl -s -m 20 "${API}/models" "${AUTH[@]}" | python3 -c "
import sys,json
d=json.load(sys.stdin)
print(next((m['id'] for m in d.get('data',[]) if m.get('name')=='${EMBED_MODEL}'),''))
")" "${EMBED_MODEL}           " "电极的使用寿命是多久？"

echo
echo "🎉 阶段四配置完成"
echo "   后台地址：${BASE_URL%/}（前端默认 80 端口）"
if [[ "${GENERATED_PW:-false}" == "true" ]]; then
  echo "   ⚠️  已自动生成管理员密码，请妥善保存并尽快修改：${ADMIN_PASSWORD}"
fi
echo "   密钥存放：${SECRET_FILE}（权限 600，请勿提交到 Git）"
