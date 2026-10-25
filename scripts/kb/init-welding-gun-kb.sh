#!/usr/bin/env bash
#
# 阶段六：焊枪选型知识库初始化
# 适用于 OBARA 知识库系统部署 —— 阶段六（知识库初始化与验证）
#
# 做什么：
#   1) 创建（或复用）知识库：绑定 Embedding 模型 bge-m3，按 README 2.2 节设置分片参数
#   2) 导入 weaving-gun-selection-kb/01-knowledge-files 下的 6 个 Excel（按幂等跳过已存在的）
#   3) 轮询等待解析 / 切片 / 向量化完成（可 --no-wait 交给后台慢慢跑）
#   4) 用 02-answer-prompt/welding-gun-selection-prompt.md 的内容创建（或更新）受管智能体，
#      绑定对话模型 deepseek-flash、重排模型 bge-reranker-v2-m3 与检索参数
#   5) 写入工作空间级检索参数（/tenants/kv/retrieval-config）
#
# 为什么这样建：
#   - WeKnora v0.8.3 的 KnowledgeBase 上没有「答复约束提示词」字段，也没有独立的"设为默认模型"接口；
#     模型绑定发生在「知识库 → embedding_model_id」与「智能体 → config.model_id」两处，
#     答复约束则落在绑定到该知识库的智能体 config.system_prompt 上（见 docs/deployment/deployment-log.md 阶段四 4.6）
#   - 导入按数据量从小到大排队，先完成的小文件可用于提前抽查解析质量
#   - CPU 环境下 18,701 行 ≈ 18,700 个分片，向量化约 2 秒/片，全量导入需数小时，
#     属于预期（试点只验证流程与效果，不追求速度），可用 --no-wait 后台执行
#
# 用法：
#   sudo ADMIN_PASSWORD='<后台密码>' bash scripts/kb/init-welding-gun-kb.sh
#   sudo bash scripts/kb/init-welding-gun-kb.sh --no-wait              # 只上传，不等解析
#   sudo bash scripts/kb/init-welding-gun-kb.sh --kb-dir /path/to/01-knowledge-files
#   sudo bash scripts/kb/init-welding-gun-kb.sh --kb-name 焊枪选型知识库 --agent-name 焊枪选型助手
#   sudo bash scripts/kb/init-welding-gun-kb.sh --status               # 只看进度
#   sudo bash scripts/kb/init-welding-gun-kb.sh --pause                # 暂停：取消排队 / 处理中的文档（文件保留）
#   sudo bash scripts/kb/init-welding-gun-kb.sh --resume               # 恢复：对 cancelled / failed 的文档重新解析
#
# 特性：
#   - 幂等：知识库按名称复用并 PUT 校正参数；文档按文件名跳过；智能体按名称复用并 PUT 更新提示词
#   - 可暂停 / 可恢复：--pause 只是把文档标记为 cancelled 释放 CPU，不删文件；--resume 原地重解析
#   - 参数可改：分片、检索 top_k、阈值均可命令行覆盖（默认值来自 README 2.2 + 阶段五结论）
#   - 失败可读：登录失败、模型缺失、文档解析失败都给出明确处理建议
#
set -euo pipefail

# ---------------------------------------------------------------- 默认参数
BASE_URL="${BASE_URL:-http://127.0.0.1:8080}"
ADMIN_EMAIL="${ADMIN_EMAIL:-admin@obara.local}"
ADMIN_PASSWORD="${ADMIN_PASSWORD:-}"     # 建议：sudo ADMIN_PASSWORD='xxx' bash scripts/kb/init-welding-gun-kb.sh

KB_NAME="${KB_NAME:-焊枪选型知识库}"
KB_DESC="${KB_DESC:-阶段六试点：C / X 型焊枪图号选型（6 个 Excel，共 18,701 行）}"
AGENT_NAME="${AGENT_NAME:-焊枪选型助手}"
AGENT_DESC="${AGENT_DESC:-按答复约束提示词筛选符合条件的焊枪图号，只输出图号}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
KB_DIR="${KB_DIR:-${REPO_ROOT}/welding-gun-selection-kb/01-knowledge-files}"
PROMPT_FILE="${PROMPT_FILE:-${REPO_ROOT}/welding-gun-selection-kb/02-answer-prompt/welding-gun-selection-prompt.md}"

EMBEDDING_MODEL="${EMBEDDING_MODEL:-bge-m3}"                      # Embedding 模型名（阶段三/四注册）
CHAT_MODEL="${CHAT_MODEL:-deepseek-flash}"                        # 快速问答对话模型（阶段四注册）
RERANK_MODEL="${RERANK_MODEL:-bge-reranker-v2-m3}"                # 本地重排模型（阶段五注册）

# 分片参数（README 2.2）
CHUNK_SIZE="${CHUNK_SIZE:-1000}"
CHUNK_OVERLAP="${CHUNK_OVERLAP:-200}"

# 检索参数（README 2.2 + 阶段五结论：候选池 ≤ 20、rerank_top_k=8）
EMBEDDING_TOP_K="${EMBEDDING_TOP_K:-20}"
RERANK_TOP_K="${RERANK_TOP_K:-8}"
RERANK_THRESHOLD="${RERANK_THRESHOLD:-0.3}"
KEYWORD_THRESHOLD="${KEYWORD_THRESHOLD:-0.3}"
VECTOR_THRESHOLD="${VECTOR_THRESHOLD:-0.15}"   # README 2.2 的 0.47 偏保守，先用代码默认值 0.15，验收时再复核

WAIT="true"
TIMEOUT_MIN="${TIMEOUT_MIN:-600}"              # 等待解析的最长时间（分钟）
STATUS_ONLY="false"
PAUSE_ONLY="false"
RESUME_ONLY="false"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --base-url)           BASE_URL="${2}"; shift 2 ;;
    --admin-email)        ADMIN_EMAIL="${2}"; shift 2 ;;
    --admin-password)     ADMIN_PASSWORD="${2}"; shift 2 ;;
    --kb-name)            KB_NAME="${2}"; shift 2 ;;
    --kb-desc)            KB_DESC="${2}"; shift 2 ;;
    --kb-dir)             KB_DIR="${2}"; shift 2 ;;
    --prompt-file)        PROMPT_FILE="${2}"; shift 2 ;;
    --agent-name)         AGENT_NAME="${2}"; shift 2 ;;
    --embedding-model)    EMBEDDING_MODEL="${2}"; shift 2 ;;
    --chat-model)         CHAT_MODEL="${2}"; shift 2 ;;
    --rerank-model)       RERANK_MODEL="${2}"; shift 2 ;;
    --chunk-size)         CHUNK_SIZE="${2}"; shift 2 ;;
    --chunk-overlap)      CHUNK_OVERLAP="${2}"; shift 2 ;;
    --embedding-top-k)    EMBEDDING_TOP_K="${2}"; shift 2 ;;
    --rerank-top-k)       RERANK_TOP_K="${2}"; shift 2 ;;
    --rerank-threshold)   RERANK_THRESHOLD="${2}"; shift 2 ;;
    --vector-threshold)   VECTOR_THRESHOLD="${2}"; shift 2 ;;
    --keyword-threshold)  KEYWORD_THRESHOLD="${2}"; shift 2 ;;
    --timeout-min)        TIMEOUT_MIN="${2}"; shift 2 ;;
    --wait)               WAIT="true";  shift ;;
    --no-wait)            WAIT="false"; shift ;;
    --status)             STATUS_ONLY="true"; shift ;;
    --pause)              PAUSE_ONLY="true"; shift ;;
    --resume)             RESUME_ONLY="true"; shift ;;
    -h|--help)            sed -n '2,38p' "$0"; exit 0 ;;
    *) echo "❌ 未知参数：$1（--help 查看用法）" >&2; exit 1 ;;
  esac
done

API="${BASE_URL}/api/v1"
j() { python3 -c "import sys,json;d=json.load(sys.stdin);print(${1})" 2>/dev/null || true; }

# 供 python3 片段读取的参数（heredoc 内用 os.environ 取值，避免中文 / 特殊字符被 shell 解析）
export AGENT_NAME AGENT_DESC PROMPT_FILE ADMIN_EMAIL KB_NAME KB_DESC KB_DIR
export EMBEDDING_MODEL CHAT_MODEL RERANK_MODEL
export CHUNK_SIZE CHUNK_OVERLAP EMBEDDING_TOP_K RERANK_TOP_K RERANK_THRESHOLD VECTOR_THRESHOLD KEYWORD_THRESHOLD

# ---------------------------------------------------------------- 0. 前置检查
echo "==> [0/7] 前置检查"
for bin in curl python3; do
  command -v "${bin}" >/dev/null 2>&1 || { echo "❌ 缺少依赖：${bin}" >&2; exit 1; }
done
curl -fsS -m 10 "${BASE_URL}/health" >/dev/null 2>&1 || {
  echo "❌ WeKnora 未就绪（${BASE_URL}/health 不通）；请先 cd /opt/obara/weknora && docker compose up -d" >&2; exit 1
}
[[ -d "${KB_DIR}" ]] || { echo "❌ 知识库文档目录不存在：${KB_DIR}" >&2; exit 1; }
[[ -f "${PROMPT_FILE}" ]] || { echo "❌ 答复约束提示词文件不存在：${PROMPT_FILE}" >&2; exit 1; }

if [[ -z "${ADMIN_PASSWORD}" ]]; then
  read -rsp "    未指定管理员密码，请输入 ${ADMIN_EMAIL} 的密码：" ADMIN_PASSWORD
  echo
fi

# ---------------------------------------------------------------- 1. 登录
echo "==> [1/7] 登录（${ADMIN_EMAIL}）"
LOGIN_RESP="$(curl -s -m 20 -X POST "${API}/auth/login" -H 'Content-Type: application/json' \
  -d "$(ADMIN_PASSWORD="${ADMIN_PASSWORD}" python3 -c "import json,os;print(json.dumps({'email':'${ADMIN_EMAIL}','password':os.environ['ADMIN_PASSWORD']}))")" || true)"
TOKEN="$(printf '%s' "${LOGIN_RESP}" | j "d.get('token') or d.get('data',{}).get('token','')")"
if [[ -z "${TOKEN}" ]]; then
  echo "❌ 登录失败：账号不存在或密码不正确（响应：$(printf '%s' "${LOGIN_RESP}" | head -c 200)）" >&2
  echo "   处理：sudo ADMIN_PASSWORD='<后台登录密码>' bash $0" >&2
  exit 1
fi
AUTH=(-H "Authorization: Bearer ${TOKEN}" -H 'Content-Type: application/json')

# ---------------------------------------------------------------- 2. 解析模型 ID
echo "==> [2/7] 解析模型 ID"
MODELS="$(curl -s -m 30 "${API}/models" "${AUTH[@]}")"
resolve_model() {   # $1=模型名 $2=类型
  printf '%s' "${MODELS}" | MODELS_ENV="${MODELS}" python3 -c "
import json,os
name=os.environ['NAME']; typ=os.environ['TYPE']
for m in json.loads(os.environ['MODELS_ENV'])['data']:
    if m['name']==name and (not typ or m['type']==typ): print(m['id']); break
" 2>/dev/null || true
}
EMBEDDING_ID="$(NAME="${EMBEDDING_MODEL}" TYPE="Embedding" resolve_model)"
CHAT_ID="$(NAME="${CHAT_MODEL}" TYPE="KnowledgeQA" resolve_model)"
RERANK_ID="$(NAME="${RERANK_MODEL}" TYPE="Rerank" resolve_model)"

if [[ -z "${EMBEDDING_ID}" ]]; then
  echo "❌ 未找到 Embedding 模型 ${EMBEDDING_MODEL}（阶段三/四未注册？）；先执行 scripts/deploy/configure-deepseek.sh" >&2; exit 1
fi
if [[ -z "${CHAT_ID}" ]]; then
  echo "❌ 未找到 KnowledgeQA 模型 ${CHAT_MODEL}；缺少它会导致保存答复约束提示词时返回 503（无可用问答模型）" >&2; exit 1
fi
[[ -n "${RERANK_ID}" ]] || echo "    ⚠️ 未找到 Rerank 模型 ${RERANK_MODEL}，将以纯向量检索运行（先跑 scripts/deploy/install-rerank.sh 可启用重排）"
echo "    Embedding：${EMBEDDING_MODEL} → ${EMBEDDING_ID}"
echo "    问答模型：${CHAT_MODEL} → ${CHAT_ID}"
echo "    重排模型：${RERANK_MODEL} → ${RERANK_ID:-未启用}"

# 步骤 6/7 的 python3 片段要读这几个 ID，这里导出给子进程
export EMBEDDING_ID CHAT_ID RERANK_ID

# ---------------------------------------------------------------- 3. 创建/复用知识库
echo "==> [3/7] 知识库「${KB_NAME}」"
KB_PAYLOAD="$(python3 - <<PY
import json,os
print(json.dumps({
  "name": os.environ["KB_NAME"],
  "description": os.environ["KB_DESC"],
  "type": "document",
  "embedding_model_id": os.environ["EMBEDDING_ID"],
  "summary_model_id": os.environ["CHAT_ID"],
  "chunking_config": {
      "chunk_size": int(os.environ["CHUNK_SIZE"]),
      "chunk_overlap": int(os.environ["CHUNK_OVERLAP"]),
  },
}))
PY
)"
KB_ID="$(curl -s -m 30 "${API}/knowledge-bases" "${AUTH[@]}" \
  | KB_NAME_ENV="${KB_NAME}" python3 -c "
import json,os,sys
for kb in json.load(sys.stdin)['data']:
    if kb['name']==os.environ['KB_NAME_ENV']: print(kb['id']); break
" 2>/dev/null || true)"

if [[ -z "${KB_ID}" ]]; then
  KB_ID="$(curl -s -m 30 -X POST "${API}/knowledge-bases" "${AUTH[@]}" -d "${KB_PAYLOAD}" -o /tmp/kb_create.json \
    >/dev/null 2>&1; python3 -c "import json;print(json.load(open('/tmp/kb_create.json'))['data']['id'])" 2>/dev/null || true)"
  [[ -n "${KB_ID}" ]] || { echo "❌ 创建知识库失败：$(head -c 300 /tmp/kb_create.json 2>/dev/null)" >&2; exit 1; }
  echo "    已创建：${KB_ID}"
else
  # --status 只看进度，不能顺手写 PUT：否则会把当次命令行指定的分片参数冲掉
  if [[ "${STATUS_ONLY}" == "true" ]]; then
    echo "    已存在：${KB_ID}（--status 不修改知识库参数）"
  else
    curl -s -m 30 -X PUT "${API}/knowledge-bases/${KB_ID}" "${AUTH[@]}" -d "${KB_PAYLOAD}" >/dev/null
    echo "    已存在并校正参数：${KB_ID}"
  fi
fi
echo "    分片：chunk_size=${CHUNK_SIZE} / overlap=${CHUNK_OVERLAP}（本次命令行取值；服务端实际值以 PUT 结果为准）"
export KB_ID    # 步骤 6 的智能体配置要绑定这个知识库 ID

kb_progress() {
  curl -s -m 30 "${API}/knowledge-bases/${KB_ID}/knowledge" "${AUTH[@]}" | python3 -c "
import sys,json
rows=json.load(sys.stdin)['data']
tot=len(rows); done=sum(1 for r in rows if r.get('parse_status')=='completed')
fail=[r for r in rows if r.get('parse_status')=='failed']
print(done, tot, len(fail), ';'.join('%s(%s)%s' % (r.get('file_name'), r.get('parse_status'), ' '+str(r.get('error_message')).replace(' ', '_')[:120] if r.get('error_message') else '') for r in rows))
" 2>/dev/null || echo "0 0 0 列表拉取失败"
}

# 列出符合指定状态的文档（每行：id \t file_name \t parse_status）
kb_list_by_status() {   # $1=逗号分隔的状态
  curl -s -m 30 "${API}/knowledge-bases/${KB_ID}/knowledge" "${AUTH[@]}" | python3 -c "
import sys,json,os
want=set(os.environ['WANT'].split(','))
for r in json.load(sys.stdin)['data']:
    if r.get('parse_status') in want:
        print('%s\t%s\t%s' % (r['id'], r.get('file_name'), r.get('parse_status')))
" 2>/dev/null || true
}

# ---------------------------------------------------------------- 暂停：取消排队 / 处理中的文档（文件保留）
if [[ "${PAUSE_ONLY}" == "true" ]]; then
  echo "==> 暂停解析（释放 CPU，文件保留，可 --resume 恢复）"
  mapfile -t TARGETS < <(WANT="pending,processing" kb_list_by_status)
  [[ ${#TARGETS[@]} -gt 0 ]] || { echo "    没有正在处理的文档"; exit 0; }
  for row in "${TARGETS[@]}"; do
    kid="${row%%$'\t'*}"; rest="${row#*$'\t'}"; fname="${rest%%$'\t'*}"
    code="$(curl -s -m 30 -o /tmp/kb_cancel.json -w '%{http_code}' -X POST "${API}/knowledge/${kid}/cancel-parse" "${AUTH[@]}" -d '{}')"
    if [[ "${code}" == "200" ]]; then echo "    已暂停：${fname}"
    else echo "    ❌ 暂停失败（HTTP ${code}）：${fname} $(head -c 150 /tmp/kb_cancel.json)"; fi
  done
  exit 0
fi

# ---------------------------------------------------------------- 恢复：对 cancelled / failed 的文档原地重解析
if [[ "${RESUME_ONLY}" == "true" ]]; then
  echo "==> 恢复解析（reparse，重新走切片 + 向量化，不会重复上传文件）"
  mapfile -t TARGETS < <(WANT="cancelled,failed" kb_list_by_status)
  [[ ${#TARGETS[@]} -gt 0 ]] || { echo "    没有待恢复的文档"; exit 0; }
  for row in "${TARGETS[@]}"; do
    kid="${row%%$'\t'*}"; rest="${row#*$'\t'}"; fname="${rest%%$'\t'*}"
    code="$(curl -s -m 30 -o /tmp/kb_reparse.json -w '%{http_code}' -X POST "${API}/knowledge/${kid}/reparse" "${AUTH[@]}" -d '{}')"
    if [[ "${code}" == "200" ]]; then echo "    已提交：${fname}"
    else echo "    ❌ 恢复失败（HTTP ${code}）：${fname} $(head -c 150 /tmp/kb_reparse.json)"; fi
  done
  echo "    后台正在处理；查看进度：bash $0 --status"
  exit 0
fi

if [[ "${STATUS_ONLY}" == "true" ]]; then
  read -r DONE TOTAL FAILED DETAIL <<<"$(kb_progress)"
  echo "    文档完成 ${DONE}/${TOTAL}${FAILED:+，失败 ${FAILED}}"
  printf '%s\n' "${DETAIL}" | tr ';' '\n' | sed 's/^/      - /'
  exit 0
fi

# ---------------------------------------------------------------- 4. 导入文档
echo "==> [4/7] 导入文档（${KB_DIR}）"
mapfile -t FILES < <(ls -S -r "${KB_DIR}" | grep -Ei '\.(xlsx|xls|csv|md|txt|pdf|docx?)$' | sed "s|^|${KB_DIR}/|")
[[ ${#FILES[@]} -gt 0 ]] || { echo "❌ 目录内没有可导入的文件" >&2; exit 1; }

EXISTING="$(curl -s -m 30 "${API}/knowledge-bases/${KB_ID}/knowledge" "${AUTH[@]}" | python3 -c "
import sys,json
print(' '.join(r.get('file_name','') for r in json.load(sys.stdin)['data']))
" 2>/dev/null || true)"

UPLOADED=0
for f in "${FILES[@]}"; do
  base="$(basename "${f}")"
  if printf '%s' " ${EXISTING} " | grep -qF " ${base} "; then
    echo "    跳过（已存在）：${base}"; continue
  fi
  if curl -sS -m 300 -X POST "${API}/knowledge-bases/${KB_ID}/knowledge/file" \
      -H "Authorization: Bearer ${TOKEN}" -F "file=@${f}" -o /tmp/kb_upload.json 2>/dev/null \
     && python3 -c "import json;d=json.load(open('/tmp/kb_upload.json'));print(d['data']['parse_status'])" 2>/dev/null | grep -qE 'pending|processing|completed'; then
    echo "    已提交：${base}"
    UPLOADED=$((UPLOADED+1))
  else
    echo "    ❌ 上传失败：${base}（$(head -c 200 /tmp/kb_upload.json 2>/dev/null)）"
  fi
done
echo "    本次提交 ${UPLOADED} 个文件（按数据量从小到大排队处理）"

# ---------------------------------------------------------------- 5. 等待解析完成
if [[ "${WAIT}" == "false" ]]; then
  echo "==> [5/7] 跳过等待（--no-wait）；后台正在解析，可用以下命令查看进度："
  echo "    bash $0 --status"
else
  echo "==> [5/7] 等待解析 / 切片 / 向量化完成（最多 ${TIMEOUT_MIN} 分钟）"
  echo "    提示：本机 CPU 环境约 2 秒/分片，18,701 行预计数小时；Ctrl-C 不会中断服务侧处理"
  deadline=$(( $(date +%s) + TIMEOUT_MIN*60 ))
  last_done=-1
  while true; do
    read -r DONE TOTAL FAILED DETAIL <<<"$(kb_progress)"
    if [[ "${DONE}" != "${last_done}" ]]; then
      echo "    $(date +%H:%M:%S) 完成 ${DONE}/${TOTAL}${FAILED:+，失败 ${FAILED}}"
      last_done="${DONE}"
    fi
    if [[ "${TOTAL}" -gt 0 && "${DONE}" -eq "${TOTAL}" ]]; then echo "    ✅ 全部文档解析完成"; break; fi
    if [[ "${FAILED}" -gt 0 ]]; then
      echo "    ❌ 有文档解析失败：" >&2; printf '%s\n' "${DETAIL}" | tr ';' '\n' | sed 's/^/      - /' >&2; exit 1
    fi
    if [[ "$(date +%s)" -ge "${deadline}" ]]; then
      echo "     ⏳ 等待超时；服务侧仍在后台处理，稍后执行：bash $0 --status" >&2
      break
    fi
    sleep 30
  done
fi

# ---------------------------------------------------------------- 6. 答复约束提示词 → 受管智能体
echo "==> [6/7] 答复约束提示词 → 智能体「${AGENT_NAME}」"
AGENT_PAYLOAD="$(PROMPT_FILE_ENV="${PROMPT_FILE}" python3 - <<'PY'
import json, os
env = os.environ
prompt = open(env["PROMPT_FILE_ENV"], encoding="utf-8").read()
print(json.dumps({
    "name": env["AGENT_NAME"],
    "description": env["AGENT_DESC"],
    "config": {
        "agent_mode": "quick-answer",
        "system_prompt": prompt,
        "model_id": env["CHAT_ID"],
        "rerank_model_id": env["RERANK_ID"],
        "kb_selection_mode": "selected",
        "knowledge_bases": [env["KB_ID"]],
        "embedding_top_k": int(env["EMBEDDING_TOP_K"]),
        "keyword_threshold": float(env["KEYWORD_THRESHOLD"]),
        "vector_threshold": float(env["VECTOR_THRESHOLD"]),
        "rerank_top_k": int(env["RERANK_TOP_K"]),
        "rerank_threshold": float(env["RERANK_THRESHOLD"]),
        "max_completion_tokens": 4096,
        "temperature": 0.1,
        "citation_enabled": True,
        "multi_turn_enabled": False,
        "enable_query_expansion": False,
        "web_search_enabled": False,
    },
}))
PY
)"
AGENT_ID="$(curl -s -m 30 "${API}/agents" "${AUTH[@]}" | AGENT_NAME_ENV="${AGENT_NAME}" python3 -c "
import sys,json,os
for a in json.load(sys.stdin)['data']:
    if a.get('name')==os.environ['AGENT_NAME_ENV']: print(a['id']); break
" 2>/dev/null || true)"
if [[ -z "${AGENT_ID}" ]]; then
  AGENT_ID="$(curl -s -m 60 -X POST "${API}/agents" "${AUTH[@]}" -d "${AGENT_PAYLOAD}" -o /tmp/agent_create.json >/dev/null 2>&1
              python3 -c "import json;print(json.load(open('/tmp/agent_create.json'))['data']['id'])" 2>/dev/null || true)"
  [[ -n "${AGENT_ID}" ]] || { echo "❌ 创建智能体失败：$(head -c 300 /tmp/agent_create.json 2>/dev/null)" >&2; exit 1; }
  echo "    已创建：${AGENT_ID}"
else
  curl -s -m 60 -X PUT "${API}/agents/${AGENT_ID}" "${AUTH[@]}" -d "${AGENT_PAYLOAD}" >/dev/null
  echo "    已存在并更新提示词：${AGENT_ID}"
fi
echo "    绑定：对话模型 ${CHAT_MODEL}、知识库 ${KB_NAME}、候选池 ${EMBEDDING_TOP_K} → rerank top ${RERANK_TOP_K}"

# ---------------------------------------------------------------- 7. 工作空间检索参数
echo "==> [7/7] 写入工作空间检索参数"
curl -s -m 30 -X PUT "${API}/tenants/kv/retrieval-config" "${AUTH[@]}" -d "$(python3 - <<PY
import json,os
env=os.environ
print(json.dumps({
  "embedding_top_k": int(env["EMBEDDING_TOP_K"]),
  "vector_threshold": float(env["VECTOR_THRESHOLD"]),
  "keyword_threshold": float(env["KEYWORD_THRESHOLD"]),
  "rerank_top_k": int(env["RERANK_TOP_K"]),
  "rerank_threshold": float(env["RERANK_THRESHOLD"]),
  "rerank_model_id": env["RERANK_ID"],
}))
PY
)" >/dev/null
echo "    embedding_top_k=${EMBEDDING_TOP_K} rerank_top_k=${RERANK_TOP_K} rerank_threshold=${RERANK_THRESHOLD}"
echo "    vector_threshold=${VECTOR_THRESHOLD} keyword_threshold=${KEYWORD_THRESHOLD}"

cat <<EOF

==> 完成 ✅
    知识库：${KB_NAME}（${KB_ID}）
    智能体：${AGENT_NAME}（${AGENT_ID}）
    进度查看：bash $0 --status
    验收脚本：bash scripts/kb/verify-welding-gun-kb.sh
    后台入口：${BASE_URL}（在会话里选择「${AGENT_NAME}」提问）
EOF
