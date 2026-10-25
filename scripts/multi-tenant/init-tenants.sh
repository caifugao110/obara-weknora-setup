#!/usr/bin/env bash
#
# 多租户初始化脚本：一键创建部门工作空间 + 批量邀请人员
#
# 做什么：
#   1) 以超级管理员身份登录 WeKnora
#   2) 读取 data/departments-personnel.json，遍历所有部门
#   3) 为每个部门创建工作空间（Tenant），已存在则跳过
#   4) 为每位成员生成邀请（文档管理员=owner，其余=contributor）
#   5) 汇总所有邀请链接到 output/invitations-<timestamp>.txt，便于管理员分发
#
# 用法：
#   sudo ADMIN_PASSWORD='<后台密码>' bash scripts/multi-tenant/init-tenants.sh
#   sudo bash scripts/multi-tenant/init-tenants.sh --dry-run              # 只打印计划，不调用 API
#   sudo bash scripts/multi-tenant/init-tenants.sh --base-url http://192.168.227.133:8080
#   sudo bash scripts/multi-tenant/init-tenants.sh --only-dept NJG-DEV2    # 只处理指定部门
#
# 前置条件：
#   - WeKnora 已运行（端口 8080）
#   - 管理员账号已创建（默认 admin@obara.local）
#   - 建议先开启 RBAC：.env 中 WEKNORA_TENANT_ENABLE_RBAC=true
#
set -euo pipefail

# ---------------------------------------------------------------- 默认参数
BASE_URL="${BASE_URL:-http://127.0.0.1:8080}"
ADMIN_EMAIL="${ADMIN_EMAIL:-admin@obara.local}"
ADMIN_PASSWORD="${ADMIN_PASSWORD:-}"
DATA_FILE="${DATA_FILE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/data/departments-personnel.json}"
OUTPUT_DIR="${OUTPUT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/output}"
DRY_RUN="false"
ONLY_DEPT="${ONLY_DEPT:-}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --base-url)       BASE_URL="${2}"; shift 2 ;;
    --admin-email)    ADMIN_EMAIL="${2}"; shift 2 ;;
    --admin-password) ADMIN_PASSWORD="${2}"; shift 2 ;;
    --data-file)      DATA_FILE="${2}"; shift 2 ;;
    --dry-run)        DRY_RUN="true"; shift ;;
    --only-dept)      ONLY_DEPT="${2}"; shift 2 ;;
    -h|--help)        sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "❌ 未知参数：$1（--help 查看用法）" >&2; exit 1 ;;
  esac
done

API="${BASE_URL}/api/v1"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# ---------------------------------------------------------------- 工具函数
log()  { echo "[$(date +%H:%M:%S)] $*"; }
err()  { echo "[$(date +%H:%M:%S)] ❌ $*" >&2; }

# 调用 WeKnora API：api_call METHOD PATH [JSON_BODY]
# 全局变量 AUTH 需先设置
api_call() {
  local method="$1" path="$2" body="${3:-}"
  local args=(-s -m 60 -X "${method}" "${API}${path}" "${AUTH[@]}")
  if [[ -n "${body}" ]]; then
    args+=(-d "${body}")
  fi
  curl "${args[@]}" 2>/dev/null || true
}

# ---------------------------------------------------------------- 0. 前置检查
log "==> [0/5] 前置检查"
for bin in curl python3; do
  command -v "${bin}" >/dev/null 2>&1 || { err "缺少依赖：${bin}"; exit 1; }
done
[[ -f "${DATA_FILE}" ]] || { err "数据文件不存在：${DATA_FILE}"; exit 1; }

if [[ "${DRY_RUN}" != "true" ]]; then
  curl -fsS -m 10 "${BASE_URL}/health" >/dev/null 2>&1 || {
    err "WeKnora 未就绪（${BASE_URL}/health 不通）"
    exit 1
  }
  if [[ -z "${ADMIN_PASSWORD}" ]]; then
    read -rsp "    未指定管理员密码，请输入 ${ADMIN_EMAIL} 的密码：" ADMIN_PASSWORD
    echo
  fi
fi
mkdir -p "${OUTPUT_DIR}"

# ---------------------------------------------------------------- 1. 登录
log "==> [1/5] 登录（${ADMIN_EMAIL}）"
if [[ "${DRY_RUN}" == "true" ]]; then
  log "    [dry-run] 跳过登录"
else
  LOGIN_BODY="$(ADMIN_PASSWORD="${ADMIN_PASSWORD}" python3 -c "
import json,os
print(json.dumps({'email':'${ADMIN_EMAIL}','password':os.environ['ADMIN_PASSWORD']}))
")"
  LOGIN_RESP="$(curl -s -m 20 -X POST "${API}/auth/login" -H 'Content-Type: application/json' -d "${LOGIN_BODY}" || true)"
  TOKEN="$(printf '%s' "${LOGIN_RESP}" | python3 -c "import sys,json;d=json.load(sys.stdin);print(d.get('token') or d.get('data',{}).get('token',''))" 2>/dev/null || true)"
  if [[ -z "${TOKEN}" ]]; then
    err "登录失败：$(printf '%s' "${LOGIN_RESP}" | head -c 200)"
    exit 1
  fi
  AUTH=(-H "Authorization: Bearer ${TOKEN}" -H 'Content-Type: application/json')
  log "    登录成功"
fi

# ---------------------------------------------------------------- 2. 获取已有工作空间列表
log "==> [2/5] 获取已有工作空间"
if [[ "${DRY_RUN}" == "true" ]]; then
  EXISTING_TENANTS='{}'
else
  TENANTS_RESP="$(api_call GET "/tenants")"
  EXISTING_TENANTS="$(printf '%s' "${TENANTS_RESP}" | python3 -c "
import sys,json
try:
    data=json.load(sys.stdin).get('data',[])
    print(json.dumps({t['name']:t['id'] for t in data}))
except: print('{}')
" 2>/dev/null || echo '{}')"
fi
log "    已有工作空间数：$(printf '%s' "${EXISTING_TENANTS}" | python3 -c "import sys,json;print(len(json.load(sys.stdin)))" 2>/dev/null || echo 0)"

# ---------------------------------------------------------------- 3. 遍历部门，创建工作空间 + 邀请
log "==> [3/5] 创建工作空间并邀请成员"
INVITATION_SUMMARY="${OUTPUT_DIR}/invitations-$(date +%Y%m%d-%H%M%S).txt"
> "${INVITATION_SUMMARY}"

# 用 Python 遍历数据并输出 shell 可解析的格式
# 输出行格式：DEPT\t<dept_code>\t<dept_name>
#           MEMBER\t<dept_code>\t<name>\t<email>\t<role>
MAP_FILE="$(mktemp)"
python3 - "${DATA_FILE}" "${ONLY_DEPT}" > "${MAP_FILE}" <<'PY'
import json, sys, os
data_file = sys.argv[1]
only_dept = sys.argv[2]
with open(data_file, encoding="utf-8") as f:
    data = json.load(f)
domain = data.get("email_domain", "obara.local")
admin_role = data.get("admin_role", "owner")
default_role = data.get("default_role", "contributor")
for loc in data.get("locations", []):
    for dept in loc.get("departments", []):
        code = dept["code"]
        if only_dept and code != only_dept:
            continue
        print(f"DEPT\t{code}\t{dept['name']}")
        for m in dept.get("members", []):
            name = m["name"]
            email = m.get("email") or f"{name}@{domain}"
            role = admin_role if m.get("is_admin") else default_role
            print(f"MEMBER\t{code}\t{name}\t{email}\t{role}")
PY

# 逐行处理
declare -A TENANT_IDS   # dept_code -> tenant_id
CUR_DEPT=""
while IFS=$'\t' read -r type code name email role; do
  case "${type}" in
    DEPT)
      CUR_DEPT="${code}"
      # 检查是否已存在
      TID="$(printf '%s' "${EXISTING_TENANTS}" | NAME="${name}" python3 -c "
import sys,json,os
d=json.load(sys.stdin)
print(d.get(os.environ['NAME'],''))
" 2>/dev/null || true)"
      if [[ -n "${TID}" ]]; then
        log "    [${code}] 工作空间已存在：${name}（${TID}）"
      else
        if [[ "${DRY_RUN}" == "true" ]]; then
          log "    [dry-run] 将创建工作空间：${name}"
          TID="dryrun-${code}"
        else
          CREATE_BODY="$(python3 -c "import json;print(json.dumps({'name':'${name}','description':'OBARA ${code} 部门工作空间'}))")"
          CREATE_RESP="$(api_call POST "/tenants" "${CREATE_BODY}")"
          TID="$(printf '%s' "${CREATE_RESP}" | python3 -c "import sys,json;d=json.load(sys.stdin);print(d.get('data',{}).get('id',''))" 2>/dev/null || true)"
          if [[ -z "${TID}" ]]; then
            err "    [${code}] 创建工作空间失败：$(printf '%s' "${CREATE_RESP}" | head -c 200)"
            continue
          fi
          log "    [${code}] 已创建工作空间：${name}（${TID}）"
        fi
      fi
      TENANT_IDS["${code}"]="${TID}"
      echo "=== ${name}（${code}）===" >> "${INVITATION_SUMMARY}"
      ;;
    MEMBER)
      TID="${TENANT_IDS[${code}]:-}"
      if [[ -z "${TID}" ]]; then
        err "    [${code}] 工作空间 ID 缺失，跳过成员 ${name}"
        continue
      fi
      if [[ "${DRY_RUN}" == "true" ]]; then
        log "    [dry-run] 将邀请 ${name}（${email}）→ ${code} 角色=${role}"
        echo "  ${name} <${email}> 角色=${role}  邀请链接：[dry-run]" >> "${INVITATION_SUMMARY}"
        continue
      fi
      # 创建邀请
      INV_BODY="$(python3 -c "import json;print(json.dumps({'email':'${email}','role':'${role}'}))")"
      INV_RESP="$(api_call POST "/tenants/${TID}/invitations" "${INV_BODY}")"
      # 尝试从响应中提取邀请链接
      INV_LINK="$(printf '%s' "${INV_RESP}" | python3 -c "
import sys,json
try:
    d=json.load(sys.stdin).get('data',{})
    # 兼容多种可能的字段名
    for k in ('invite_url','invitation_url','link','url','accept_url'):
        if d.get(k): print(d[k]); break
    else:
        t=d.get('token') or d.get('invitation_token') or d.get('id','')
        if t: print('INVITE_TOKEN:'+t)
        else: print('')
except: print('')
" 2>/dev/null || true)"
      if [[ -n "${INV_LINK}" ]]; then
        log "    [${code}] 已邀请 ${name}（${role}）"
        echo "  ${name} <${email}> 角色=${role}" >> "${INVITATION_SUMMARY}"
        echo "    ${INV_LINK}" >> "${INVITATION_SUMMARY}"
      else
        # 邀请可能已存在或 API 返回格式不同，尝试获取邀请列表
        log "    [${code}] 邀请 ${name}（${role}）— 响应：$(printf '%s' "${INV_RESP}" | head -c 120)"
        echo "  ${name} <${email}> 角色=${role}  [响应未含链接，请到门户人员管理页查看]" >> "${INVITATION_SUMMARY}"
      fi
      ;;
  esac
done < "${MAP_FILE}"
rm -f "${MAP_FILE}"

# ---------------------------------------------------------------- 4. 验证成员数
log "==> [4/5] 验证工作空间成员"
if [[ "${DRY_RUN}" != "true" ]]; then
  for code in "${!TENANT_IDS[@]}"; do
    TID="${TENANT_IDS[${code}]}"
    [[ "${TID}" == dryrun-* ]] && continue
    MEMBERS_RESP="$(api_call GET "/tenants/${TID}/members")"
    COUNT="$(printf '%s' "${MEMBERS_RESP}" | python3 -c "import sys,json;print(len(json.load(sys.stdin).get('data',[])))" 2>/dev/null || echo '?')"
    log "    [${code}] 成员数：${COUNT}"
  done
fi

# ---------------------------------------------------------------- 5. 输出汇总
log "==> [5/5] 完成"
echo
echo "================================================================"
echo "  多租户初始化完成"
echo "================================================================"
echo "  工作空间数：${#TENANT_IDS[@]}"
echo "  邀请汇总文件：${INVITATION_SUMMARY}"
echo
echo "  下一步："
echo "    1. 将邀请链接分发给各部门文档管理员（Owner）"
echo "    2. 文档管理员登录后在门户「人员管理」中邀请本部门其他成员"
echo "    3. 文档管理员在「文档管理」中创建知识库并上传文档"
echo "    4. 文档管理员在「智能体管理」中创建问答智能体"
echo "    5. 普通成员通过邀请链接加入后即可在「问答」页提问"
echo
echo "  门户地址：http://<虚拟机IP>:8081"
echo "  WeKnora 原生后台：http://<虚拟机IP>:80"
echo "================================================================"
