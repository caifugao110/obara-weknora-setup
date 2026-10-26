#!/usr/bin/env bash
#
# 为各工作空间的内置「快速问答」智能体绑定对话模型 / 重排模型
#
# 背景（踩坑记录）：
#   新建工作空间时，WeKnora 会自动生成内置智能体 builtin-quick-answer（快速问答），
#   但它的 config.model_id / config.rerank_model_id 是空的。此时提问后端会直接报：
#       ERROR chat model is not configured: please set model_id on agent builtin-quick-answer
#   且该错误不会写进 SSE 流：响应头 200、正文为空、连接不关闭，
#   前端表现为「一直转圈、无法问答」。模型是空间级资源，注入模型行并不会自动绑定。
#
# 做什么：
#   1) 以超管身份登录，逐个空间读取内置快速问答智能体
#   2) 按名称优先级挑选本空间已激活的对话模型（KnowledgeQA）与重排模型（Rerank）
#   3) 把 model_id / rerank_model_id 回写进智能体配置（其它配置项原样保留）
#   4) 已绑定且未加 --force 时跳过，可重复执行
#
# 用法：
#   ADMIN_PASSWORD='<超管密码>' bash scripts/multi-tenant/bind-agent-models.sh
#   bash scripts/multi-tenant/bind-agent-models.sh --tenants 10003,10004     # 只处理指定空间
#   bash scripts/multi-tenant/bind-agent-models.sh --dry-run                 # 只打印将要做的改动
#   bash scripts/multi-tenant/bind-agent-models.sh --force                   # 已绑定也重新绑定
#   bash scripts/multi-tenant/bind-agent-models.sh --chat-model deepseek-v4-pro
#
# 前置条件：WeKnora 已运行；超管具备跨空间权限；各空间已注入模型（init-tenants.sh 第 5 步）
#
set -euo pipefail

BASE_URL="${BASE_URL:-http://127.0.0.1:8080}"
ADMIN_EMAIL="${ADMIN_EMAIL:-admin@obara.local}"
ADMIN_PASSWORD="${ADMIN_PASSWORD:-}"
TENANTS_ARG="${TENANTS_ARG:-}"
DRY_RUN="false"
FORCE="false"
AGENT_ID="${AGENT_ID:-builtin-quick-answer}"
CHAT_MODEL="${CHAT_MODEL:-deepseek-flash}"
RERANK_MODEL="${RERANK_MODEL:-bge-reranker-v2-m3}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --base-url)         BASE_URL="${2}"; shift 2 ;;
    --admin-email)      ADMIN_EMAIL="${2}"; shift 2 ;;
    --admin-password)   ADMIN_PASSWORD="${2}"; shift 2 ;;
    --tenants)          TENANTS_ARG="${2}"; shift 2 ;;
    --agent-id)         AGENT_ID="${2}"; shift 2 ;;
    --chat-model)       CHAT_MODEL="${2}"; shift 2 ;;
    --rerank-model)     RERANK_MODEL="${2}"; shift 2 ;;
    --dry-run)          DRY_RUN="true"; shift ;;
    --force)            FORCE="true"; shift ;;
    -h|--help)          sed -n '2,30p' "$0"; exit 0 ;;
    *) echo "❌ 未知参数：$1（--help 查看用法）" >&2; exit 1 ;;
  esac
done

API="${BASE_URL}/api/v1"
TOKEN=""

log() { echo "[$(date +%H:%M:%S)] $*"; }
err() { echo "[$(date +%H:%M:%S)] ❌ $*" >&2; }

pyget() {
  printf '%s' "${1}" | python3 -c "
import sys,json
try:
    d=json.load(sys.stdin)
except Exception:
    d={}
try:
    v=$2
    print('' if v is None else v)
except Exception:
    print('')
" 2>/dev/null || true
}

# 注意：http 的签名是 METHOD PATH [BODY] [TENANT_ID]，
# 只读请求也必须显式传空 body（http GET "/models" "" "${TID}"），
# 否则租户 ID 会被当成请求体、X-Tenant-ID 头丢失，
# 服务端按默认空间返回数据 —— 结果是所有空间都绑到别家的模型 ID 上，
# 问答时报 configured chat model ... is unavailable。
http() {
  local method="$1" path="$2" body="${3:-}" tid="${4:-}"
  local -a args=(-s -m 60 -X "${method}" "${API}${path}")
  [[ -n "${TOKEN}" ]] && args+=(-H "Authorization: Bearer ${TOKEN}")
  args+=(-H 'Content-Type: application/json' -H 'Accept: application/json')
  [[ -n "${tid}" ]] && args+=(-H "X-Tenant-ID: ${tid}")
  [[ -n "${body}" ]] && args+=(-d "${body}")
  curl "${args[@]}" 2>/dev/null || true
}

resp_ok() { [[ "$(pyget "${1}" "d.get('success', False)")" == "True" ]]; }

# ---------------------------------------------------------------- 1. 登录
log "==> [1/3] 登录（${ADMIN_EMAIL}）"
if [[ "${DRY_RUN}" == "true" ]]; then
  log "    [dry-run] 跳过登录"
else
  curl -fsS -m 10 "${BASE_URL}/health" >/dev/null 2>&1 || { err "WeKnora 未就绪（${BASE_URL}/health 不通）"; exit 1; }
  if [[ -z "${ADMIN_PASSWORD}" ]]; then
    read -rsp "    未指定管理员密码，请输入 ${ADMIN_EMAIL} 的密码：" ADMIN_PASSWORD
    echo
  fi
  LOGIN_RESP="$(http POST "/auth/login" "$(python3 -c "
import json,sys
print(json.dumps({'email':sys.argv[1],'password':sys.argv[2]},ensure_ascii=False))
" "${ADMIN_EMAIL}" "${ADMIN_PASSWORD}")")"
  TOKEN="$(pyget "${LOGIN_RESP}" "d.get('token','')")"
  [[ -n "${TOKEN}" ]] || { err "登录失败：$(printf '%s' "${LOGIN_RESP}" | head -c 200)"; exit 1; }
  log "    登录成功"
fi

# ---------------------------------------------------------------- 2. 确定待处理空间
log "==> [2/3] 确定待处理工作空间"
TENANT_IDS=()
if [[ -n "${TENANTS_ARG}" ]]; then
  IFS=',' read -r -a TENANT_IDS <<< "${TENANTS_ARG}"
elif [[ "${DRY_RUN}" == "true" ]]; then
  log "    [dry-run] 无法枚举空间，请显式指定 --tenants"
  exit 0
else
  RESP="$(http GET "/tenants/all?page=1&page_size=500")"
  ITEMS="$(pyget "${RESP}" "','.join(str(t.get('id','')) for t in d.get('data',{}).get('items',[]) if t.get('id'))")"
  if [[ -z "${ITEMS}" ]]; then
    RESP="$(http GET "/auth/me")"
    ITEMS="$(pyget "${RESP}" "','.join(str(m.get('tenant_id','')) for m in d.get('data',{}).get('memberships',[]) if m.get('tenant_id'))")"
  fi
  [[ -n "${ITEMS}" ]] || { err "未取到任何工作空间"; exit 1; }
  IFS=',' read -r -a TENANT_IDS <<< "${ITEMS}"
fi
log "    待处理空间数：${#TENANT_IDS[@]}"

# ---------------------------------------------------------------- 3. 逐个空间绑定
log "==> [3/3] 为「${AGENT_ID}」绑定对话模型 / 重排模型"
STAT_BOUND=0
STAT_SKIP=0
STAT_FAIL=0

for TID in "${TENANT_IDS[@]}"; do
  [[ -n "${TID}" ]] || continue

  if [[ "${DRY_RUN}" == "true" ]]; then
    log "    [${TID}] [dry-run] 将检查并绑定 ${CHAT_MODEL} / ${RERANK_MODEL}"
    continue
  fi

  # 3a. 取本空间模型：优先按名称匹配，其次取同类型第一个 active 模型
  MODELS="$(http GET "/models" "" "${TID}")"
  CHAT_ID="$(pyget "${MODELS}" "next((m.get('id','') for m in d.get('data',[]) if m.get('type')=='KnowledgeQA' and m.get('status')=='active' and m.get('name')=='${CHAT_MODEL}'), next((m.get('id','') for m in d.get('data',[]) if m.get('type')=='KnowledgeQA' and m.get('status')=='active'), ''))")"
  RERANK_ID="$(pyget "${MODELS}" "next((m.get('id','') for m in d.get('data',[]) if m.get('type')=='Rerank' and m.get('status')=='active' and m.get('name')=='${RERANK_MODEL}'), next((m.get('id','') for m in d.get('data',[]) if m.get('type')=='Rerank' and m.get('status')=='active'), ''))")"
  if [[ -z "${CHAT_ID}" ]]; then
    err "    [${TID}] 无可用对话模型（KnowledgeQA），请先注入模型"
    STAT_FAIL=$((STAT_FAIL + 1))
    continue
  fi

  # 3b. 取智能体当前配置
  AGENT="$(http GET "/agents/${AGENT_ID}" "" "${TID}")"
  AID="$(pyget "${AGENT}" "(d.get('data') or {}).get('id','') if isinstance(d.get('data'),dict) else next((a.get('id','') for a in (d.get('data') or []) if a.get('id')=='${AGENT_ID}'),'')")"
  if [[ -z "${AID}" ]]; then
    # 部分版本不提供按 ID 详情接口，退回列表接口
    AGENT="$(http GET "/agents" "" "${TID}")"
    AID="$(pyget "${AGENT}" "next((a.get('id','') for a in (d.get('data') or []) if a.get('id')=='${AGENT_ID}'),'')")"
  fi
  if [[ -z "${AID}" ]]; then
    err "    [${TID}] 未找到智能体 ${AGENT_ID}，跳过"
    STAT_FAIL=$((STAT_FAIL + 1))
    continue
  fi

  CUR_MODEL="$(pyget "${AGENT}" "((d.get('data') or {}).get('config') if isinstance(d.get('data'),dict) else next((a.get('config') for a in (d.get('data') or []) if a.get('id')=='${AGENT_ID}'),None) or {}).get('model_id','')")"
  if [[ -n "${CUR_MODEL}" && "${FORCE}" != "true" ]]; then
    log "    [${TID}] 已绑定对话模型 ${CUR_MODEL}，跳过（--force 可强制覆盖）"
    STAT_SKIP=$((STAT_SKIP + 1))
    continue
  fi

  # 3c. 回写：保留原有 config，只覆盖 model_id / rerank_model_id
  PAYLOAD="$(printf '%s' "${AGENT}" | python3 -c "
import json,sys
aid, chat_id, rerank_id = sys.argv[1], sys.argv[2], sys.argv[3]
d=json.load(sys.stdin)
raw=d.get('data')
a=raw if isinstance(raw,dict) else next((x for x in (raw or []) if x.get('id')==aid),None)
if not a:
    sys.exit(1)
cfg=dict(a.get('config') or {})
cfg['model_id']=chat_id
if rerank_id:
    cfg['rerank_model_id']=rerank_id
print(json.dumps({'name':a.get('name',''),'description':a.get('description',''),'config':cfg},ensure_ascii=False))
" "${AGENT_ID}" "${CHAT_ID}" "${RERANK_ID}")" || { err "    [${TID}] 构造请求体失败，跳过"; STAT_FAIL=$((STAT_FAIL + 1)); continue; }

  RESP="$(http PUT "/agents/${AID}" "${PAYLOAD}" "${TID}")"
  if resp_ok "${RESP}" || [[ "$(pyget "${RESP}" "(d.get('data') or {}).get('id','') if isinstance(d.get('data'),dict) else ''")" == "${AID}" ]]; then
    # 3d. 回读校验：必须落成本空间自己的模型 ID，
    #     否则服务端会报 configured chat model ... is unavailable，问答依旧挂死。
    VERIFY="$(http GET "/agents/${AGENT_ID}" "" "${TID}")"
    NEW_MODEL="$(pyget "${VERIFY}" "((d.get('data') or {}).get('config') if isinstance(d.get('data'),dict) else next((a.get('config') for a in (d.get('data') or []) if a.get('id')=='${AGENT_ID}'),None) or {}).get('model_id','')")"
    if [[ "${NEW_MODEL}" != "${CHAT_ID}" ]]; then
      err "    [${TID}] 回读校验失败：期望 ${CHAT_ID}，实际 ${NEW_MODEL:-（空）}"
      STAT_FAIL=$((STAT_FAIL + 1))
      continue
    fi
    log "    [${TID}] ✅ 已绑定：对话=${CHAT_ID}${RERANK_ID:+  重排=${RERANK_ID}}"
    STAT_BOUND=$((STAT_BOUND + 1))
  else
    err "    [${TID}] 绑定失败：$(printf '%s' "${RESP}" | head -c 200)"
    STAT_FAIL=$((STAT_FAIL + 1))
  fi
done

echo
echo "================================================================"
echo "  绑定完成：成功 ${STAT_BOUND} / 已绑定跳过 ${STAT_SKIP} / 失败 ${STAT_FAIL}"
echo "  对话模型优先级：${CHAT_MODEL}（无则取同类型第一个 active）"
echo "  重排模型优先级：${RERANK_MODEL}（无则取同类型第一个 active）"
echo "================================================================"
[[ ${STAT_FAIL} -eq 0 ]] || exit 1
