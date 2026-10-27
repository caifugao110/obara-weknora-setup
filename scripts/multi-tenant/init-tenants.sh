#!/usr/bin/env bash
#
# 多租户初始化脚本：一键创建部门工作空间 + 批量接入人员
#
# 做什么：
#   1) 以超管身份登录 WeKnora，读取 data/departments-personnel.json
#   2) 为每个部门创建工作空间（Tenant），同名已存在则跳过（幂等）
#   3) 为每位成员创建账号（邮箱取自 data/departments-personnel.json 的 email 字段，
#      规则为「姓全拼+名首字母@obara.com.cn」，可用 gen-emails.py 生成），已注册则跳过
#   4) 把成员直接加入部门空间：全部为 contributor，不设默认管理员（已加入则跳过）
#   5) 把平台空间已注册的模型注入每个部门空间（模型是空间级资源，新空间默认没有模型）
#   6) 为每个部门的内置「快速问答」智能体绑定本空间的对话模型 / 重排模型
#      （内置智能体默认 model_id 为空，不绑定则提问时后端报 chat model is not configured，
#        且错误不进 SSE 流，页面表现为一直转圈、无法问答）
#   7) 为每个部门生成 owner / contributor 两条共享邀请链接，供后续补员与换人使用
#   8) 汇总输出 output/invitations-<时间戳>.txt 与 output/accounts-<时间戳>.csv
#   9) 保证超管（admin@obara.local）在「所有」部门都具备管理员身份（幂等，第 5c 步）
#
# 关于部门管理员：
#   平台超管（admin）默认就是所有部门的管理员：新建空间时后端会把创建者置为 Owner，
#   第 5c 步再对历史空间做一次补齐 / 提升，见 scripts/multi-tenant/ensure-admin-all-departments.sh。
#   初始化不自动授予 owner：即使 JSON 中保留了 is_admin 标记也会被忽略，所有人先以
#   contributor 身份加入本部门空间。初始化完成后，由超管在 WeKnora 原生后台（端口 80）
#   「工作空间 → 成员」中把各部门负责人逐个改为 owner（文档管理员），该部门才会出现
#   「人员 / 智能体 / 文档」管理入口。
#   第 7 步生成的 owner 邀请链接同样会把使用者直接变成部门管理员，只发给已确定的负责人。
#
# 用法：
#   sudo ADMIN_PASSWORD='<后台密码>' bash scripts/multi-tenant/init-tenants.sh
#   sudo bash scripts/multi-tenant/init-tenants.sh --dry-run               # 只打印计划，不调用 API
#   sudo bash scripts/multi-tenant/init-tenants.sh --only-dept NJG-GM,SHA-QA
#   sudo bash scripts/multi-tenant/init-tenants.sh --base-url http://192.168.227.133:8080
#   sudo bash scripts/multi-tenant/init-tenants.sh --links-only            # 只建空间 + 邀请链接，不动账号
#   sudo bash scripts/multi-tenant/init-tenants.sh --no-links              # 不生成邀请链接
#   sudo bash scripts/multi-tenant/init-tenants.sh --no-bind-models        # 不绑定智能体模型
#
# 前置条件：
#   - WeKnora 已运行（后端 8080）
#   - 管理员账号已创建，且具备跨空间权限（is_system_admin / can_access_all_tenants）
#   - 已开启 RBAC：.env 中 WEKNORA_TENANT_ENABLE_RBAC=true（否则空间内角色守卫只记日志不拦截）
#   - 已设置 .env：WEKNORA_AUTH_DEFAULT_TENANT_MODE=tenantless（注册不另建个人空间）
#                  FRONTEND_BASE_URL=http://<虚拟机IP>:8081（邀请链接指向门户）
#   - 公开注册未关闭：DISABLE_REGISTRATION=false（脚本用 /auth/register 批量开户）
#
set -euo pipefail

# ---------------------------------------------------------------- 默认参数
BASE_URL="${BASE_URL:-http://127.0.0.1:8080}"
ADMIN_EMAIL="${ADMIN_EMAIL:-admin@obara.local}"
ADMIN_PASSWORD="${ADMIN_PASSWORD:-}"
ONLY_DEPT="${ONLY_DEPT:-}"
DRY_RUN="false"
CREATE_ACCOUNTS="true"
CREATE_LINKS="true"
SEED_MODELS="true"
BIND_AGENT_MODELS="true"
MODEL_SOURCE_TENANT="${MODEL_SOURCE_TENANT:-10000}"
DB_CONTAINER="${DB_CONTAINER:-WeKnora-postgres}"
DB_NAME="${DB_NAME:-WeKnora}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DATA_FILE="${DATA_FILE:-${REPO_ROOT}/data/departments-personnel.json}"
OUTPUT_DIR="${OUTPUT_DIR:-${REPO_ROOT}/output}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --base-url)        BASE_URL="${2}"; shift 2 ;;
    --admin-email)     ADMIN_EMAIL="${2}"; shift 2 ;;
    --admin-password)  ADMIN_PASSWORD="${2}"; shift 2 ;;
    --data-file)       DATA_FILE="${2}"; shift 2 ;;
    --output-dir)      OUTPUT_DIR="${2}"; shift 2 ;;
    --only-dept)       ONLY_DEPT="${2}"; shift 2 ;;
    --dry-run)         DRY_RUN="true"; shift ;;
    --links-only)      CREATE_ACCOUNTS="false"; shift ;;
    --no-links)        CREATE_LINKS="false"; shift ;;
    --no-models)       SEED_MODELS="false"; shift ;;
    --no-bind-models)  BIND_AGENT_MODELS="false"; shift ;;
    --model-source-tenant) MODEL_SOURCE_TENANT="${2}"; shift 2 ;;
    --db-container)    DB_CONTAINER="${2}"; shift 2 ;;
    --db-name)         DB_NAME="${2}"; shift 2 ;;
    -h|--help)         sed -n '2,39p' "$0"; exit 0 ;;
    *) echo "❌ 未知参数：$1（--help 查看用法）" >&2; exit 1 ;;
  esac
done

API="${BASE_URL}/api/v1"
TOKEN=""

# ---------------------------------------------------------------- 工具函数
log() { echo "[$(date +%H:%M:%S)] $*"; }
err() { echo "[$(date +%H:%M:%S)] ❌ $*" >&2; }

# 从 JSON 响应中取值：pyget '<json>' '<python 表达式（变量为 d）>'
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

# 构造 JSON 对象：json_obj role=owner email=a@b.local
json_obj() {
  python3 -c "
import json,sys
out={}
for a in sys.argv[1:]:
    k,_,v=a.partition('=')
    out[k]=v
print(json.dumps(out,ensure_ascii=False))
" "$@"
}

# 调用 API：http METHOD PATH [BODY] [TENANT_ID]
http() {
  local method="$1" path="$2" body="${3:-}" tid="${4:-}"
  local -a args=(-s -m 60 -X "${method}" "${API}${path}")
  [[ -n "${TOKEN}" ]] && args+=(-H "Authorization: Bearer ${TOKEN}")
  args+=(-H 'Content-Type: application/json' -H 'Accept: application/json')
  [[ -n "${tid}" ]] && args+=(-H "X-Tenant-ID: ${tid}")
  [[ -n "${body}" ]] && args+=(-d "${body}")
  curl "${args[@]}" 2>/dev/null || true
}

# 响应是否成功，或是否已存在（幂等跳过）
resp_ok()   { [[ "$(pyget "${1}" "d.get('success', False)")" == "True" ]]; }
resp_dup() {
  local msg; msg="$(pyget "${1}" "str(d.get('message',''))+str(d.get('error',''))")"
  [[ "${msg}" =~ (已存在|已注册|already|exists|duplicate|conflict) ]]
}

gen_password() {
  local suffix=""
  while [[ ${#suffix} -lt 8 ]]; do
    suffix="$(head -c 32 /dev/urandom | base64 | tr -dc 'a-zA-Z0-9' | head -c 8)"
  done
  echo "Ob2025${suffix}"
}

# ---------------------------------------------------------------- 0. 前置检查
log "==> [0/7] 前置检查"
for bin in curl python3; do
  command -v "${bin}" >/dev/null 2>&1 || { err "缺少依赖：${bin}"; exit 1; }
done
[[ -f "${DATA_FILE}" ]] || { err "数据文件不存在：${DATA_FILE}"; exit 1; }

if [[ "${DRY_RUN}" != "true" ]]; then
  curl -fsS -m 10 "${BASE_URL}/health" >/dev/null 2>&1 || { err "WeKnora 未就绪（${BASE_URL}/health 不通）"; exit 1; }
  if [[ -z "${ADMIN_PASSWORD}" ]]; then
    read -rsp "    未指定管理员密码，请输入 ${ADMIN_EMAIL} 的密码：" ADMIN_PASSWORD
    echo
  fi
fi
mkdir -p "${OUTPUT_DIR}"

# ---------------------------------------------------------------- 1. 登录
log "==> [1/7] 登录（${ADMIN_EMAIL}）"
if [[ "${DRY_RUN}" == "true" ]]; then
  log "    [dry-run] 跳过登录"
else
  LOGIN_RESP="$(http POST "/auth/login" "$(json_obj "email=${ADMIN_EMAIL}" "password=${ADMIN_PASSWORD}")")"
  TOKEN="$(pyget "${LOGIN_RESP}" "d.get('token','')")"
  if [[ -z "${TOKEN}" ]]; then
    err "登录失败：$(printf '%s' "${LOGIN_RESP}" | head -c 200)"
    exit 1
  fi
  CAN_ALL="$(pyget "${LOGIN_RESP}" "d.get('user',{}).get('can_access_all_tenants', False)")"
  if [[ "${CAN_ALL}" != "True" ]]; then
    err "账号 ${ADMIN_EMAIL} 不是跨空间超管，无法批量创建部门空间。"
    err "    请先授予权限：UPDATE users SET is_system_admin=true, can_access_all_tenants=true WHERE email='${ADMIN_EMAIL}';"
    exit 1
  fi
  log "    登录成功（跨空间超管）"
fi

# ---------------------------------------------------------------- 2. 已有工作空间
log "==> [2/7] 读取已有工作空间"
declare -A TENANT_OF_NAME
EXISTING_TENANT_COUNT=0
if [[ "${DRY_RUN}" == "true" ]]; then
  log "    [dry-run] 跳过读取"
else
  # 超管优先用 /tenants/all 拿全量目录；无跨空间权限时回退到 /auth/me 的 memberships。
  # 注意：GET /tenants 只返回当前登录用户的归属空间，不能用于重名判断。
  TENANTS_RESP="$(http GET "/tenants/all?page=1&page_size=500")"
  ITEMS="$(pyget "${TENANTS_RESP}" "'\n'.join('%s\t%s'%(t.get('id',''),t.get('name','')) for t in d.get('data',{}).get('items',[]))")"
  if [[ -z "${ITEMS}" ]]; then
    TENANTS_RESP="$(http GET "/auth/me")"
    ITEMS="$(pyget "${TENANTS_RESP}" "'\n'.join('%s\t%s'%(m.get('tenant_id',''),m.get('tenant_name','')) for m in d.get('data',{}).get('memberships',[]))")"
  fi
  while IFS=$'\t' read -r tid tname; do
    if [[ -n "${tid}" && -n "${tname}" ]]; then
      TENANT_OF_NAME["${tname}"]="${tid}"
      EXISTING_TENANT_COUNT=$((EXISTING_TENANT_COUNT + 1))
    fi
  done < <(printf '%s\n' "${ITEMS}")
fi
log "    已有工作空间数：${EXISTING_TENANT_COUNT}"

# ---------------------------------------------------------------- 3. 生成执行计划
PLAN_FILE="$(mktemp)"
trap 'rm -f "${PLAN_FILE}"' EXIT
python3 - "${DATA_FILE}" "${ONLY_DEPT}" > "${PLAN_FILE}" <<'PY'
import json, sys
data_file, only_dept = sys.argv[1], sys.argv[2]
wanted = {c.strip() for c in only_dept.split(',') if c.strip()}
with open(data_file, encoding='utf-8') as f:
    data = json.load(f)
domain = data.get('email_domain', 'obara.com.cn')
default_role = data.get('default_role', 'contributor')
ignored_admin = 0
for loc in data.get('locations', []):
    for dept in loc.get('departments', []):
        code = dept['code']
        if wanted and code not in wanted:
            continue
        print('DEPT\t%s\t%s' % (code, dept['name']))
        for m in dept.get('members', []):
            name = m['name']
            email = m.get('email') or '%s@%s' % (name, domain)
            # 用户名全局唯一：重名者用「姓名(部门)」区分，生成规则见 gen-emails.py
            username = m.get('username') or name
            # 不设默认管理员：一律以普通成员加入，部门 Owner 由超管初始化后手动指派
            if m.get('is_admin'):
                ignored_admin += 1
            print('MEMBER\t%s\t%s\t%s\t%s\t%s' % (code, name, email, default_role, username))

if ignored_admin:
    print('⚠️ 数据中有 %d 个 is_admin 标记，已忽略：初始化不设默认管理员，'
          '部门 Owner 由超管在后台手动指派。' % ignored_admin, file=sys.stderr)
PY

TOTAL_DEPT="$(grep -c '^DEPT' "${PLAN_FILE}" || true)"
TOTAL_MEMBER="$(grep -c '^MEMBER' "${PLAN_FILE}" || true)"
log "    计划：${TOTAL_DEPT} 个部门 / ${TOTAL_MEMBER} 位成员"

# 账号已存在时无法再次拿到密码，这里先载入上一次运行记录的密码，
# 保证重复执行后账号清单仍是完整可用的（而不是一片「上次未记录」）。
# 注意：必须在生成本轮清单文件之前载入，否则 ls -t 会选到本轮的空文件。
declare -A PREV_PASSWORD
PREV_COUNT=0
PREV_CSV="$(ls -1t "${OUTPUT_DIR}"/accounts-*.csv 2>/dev/null | head -n 1 || true)"
if [[ -n "${PREV_CSV}" ]]; then
  while IFS=',' read -r _c1 _c2 _c3 email _c5 password _c7; do
    [[ -z "${email}" || "${password}" == "初始密码" || "${password}" == "（"* ]] && continue
    PREV_PASSWORD["${email}"]="${password}"
    PREV_COUNT=$((PREV_COUNT + 1))
  done < "${PREV_CSV}"
  log "    已载入上次账号清单：${PREV_CSV##*/}（${PREV_COUNT} 条密码）"
fi

# ---------------------------------------------------------------- 4. 执行
log "==> [3/7] 创建工作空间"
log "==> [4/7] 接入人员并生成邀请链接"
STAMP="$(date +%Y%m%d-%H%M%S)"
SUMMARY="${OUTPUT_DIR}/invitations-${STAMP}.txt"
ACCOUNTS="${OUTPUT_DIR}/accounts-${STAMP}.csv"
: > "${SUMMARY}"
printf '部门编码,部门,姓名,邮箱,角色,初始密码,账号状态\n' > "${ACCOUNTS}"

declare -A TENANT_IDS        # dept_code -> tenant_id
declare -A DEPT_NAME_OF      # dept_code -> dept name
DEPT_COUNT=0
CUR_DEPT=""

STAT_NEW_USER=0
STAT_OLD_USER=0
STAT_NEW_MEMBER=0
STAT_SKIP_MEMBER=0
STAT_FAIL_MEMBER=0

write_summary() { echo "${1}" >> "${SUMMARY}"; }

while IFS=$'\t' read -r kind c1 c2 c3 c4 c5; do
  case "${kind}" in
    DEPT)
      CUR_DEPT="${c1}"
      DEPT_NAME="${c2}"
      DEPT_NAME_OF["${CUR_DEPT}"]="${DEPT_NAME}"
      DEPT_COUNT=$((DEPT_COUNT + 1))

      TID="${TENANT_OF_NAME[${DEPT_NAME}]:-}"
      if [[ -n "${TID}" ]]; then
        log "    [${CUR_DEPT}] 工作空间已存在：${DEPT_NAME}（${TID}）"
      else
        if [[ "${DRY_RUN}" == "true" ]]; then
          log "    [dry-run] 将创建工作空间：${DEPT_NAME}"
          TID="dryrun-${CUR_DEPT}"
        else
          RESP="$(http POST "/tenants" "$(json_obj "name=${DEPT_NAME}" "description=OBARA ${CUR_DEPT} 部门工作空间")")"
          TID="$(pyget "${RESP}" "d.get('data',{}).get('id','')")"
          if [[ -z "${TID}" ]]; then
            err "    [${CUR_DEPT}] 创建工作空间失败：$(printf '%s' "${RESP}" | head -c 200)"
            continue
          fi
          TENANT_OF_NAME["${DEPT_NAME}"]="${TID}"
          log "    [${CUR_DEPT}] 已创建工作空间：${DEPT_NAME}（${TID}）"
        fi
      fi
      TENANT_IDS["${CUR_DEPT}"]="${TID}"

      write_summary ""
      write_summary "=== ${DEPT_NAME}（${CUR_DEPT}）· 工作空间 ID=${TID} ==="

      # 共享邀请链接（owner / contributor），已存在则复用
      if [[ "${CREATE_LINKS}" == "true" ]]; then
        for role in owner contributor; do
          if [[ "${DRY_RUN}" == "true" ]]; then
            write_summary "  邀请链接（${role}）：[dry-run]"
            continue
          fi
          EXISTING="$(http GET "/tenants/${TID}/invitations?page=1&page_size=50" "${TID}")"
          URL="$(pyget "${EXISTING}" "next((i.get('invite_url','') for i in d.get('data',{}).get('invitations',[]) if i.get('is_share_link') and i.get('role')=='${role}' and i.get('status')=='pending'),'')")"
          if [[ -n "${URL}" ]]; then
            write_summary "  邀请链接（${role}，复用已有）：${URL}"
          else
            RESP="$(http POST "/tenants/${TID}/invite-links" "$(json_obj "role=${role}" "message=OBARA ${DEPT_NAME} 成员加入邀请")" "${TID}")"
            URL="$(pyget "${RESP}" "d.get('data',{}).get('invite_url','')")"
            if [[ -n "${URL}" ]]; then
              write_summary "  邀请链接（${role}）：${URL}"
            else
              err "    [${CUR_DEPT}] 生成 ${role} 邀请链接失败：$(printf '%s' "${RESP}" | head -c 160)"
              write_summary "  邀请链接（${role}）：生成失败，请在门户「人员管理」中重新生成"
            fi
          fi
        done
      fi
      ;;

    MEMBER)
      DEPT_CODE="${c1}"; NAME="${c2}"; EMAIL="${c3}"; ROLE="${c4}"; USERNAME="${c5:-${c2}}"
      TID="${TENANT_IDS[${DEPT_CODE}]:-}"
      if [[ -z "${TID}" ]]; then
        err "    [${DEPT_CODE}] 工作空间缺失，跳过 ${NAME}"
        STAT_FAIL_MEMBER=$((STAT_FAIL_MEMBER + 1))
        continue
      fi

      PASSWORD=""
      ACCOUNT_STATE=""

      # 4a. 创建账号
      if [[ "${CREATE_ACCOUNTS}" == "false" ]]; then
        ACCOUNT_STATE="未创建（--links-only）"
      elif [[ "${DRY_RUN}" == "true" ]]; then
        ACCOUNT_STATE="[dry-run] 将注册"
      else
        PASSWORD="$(gen_password)"
        RESP="$(http POST "/auth/register" "$(json_obj "username=${USERNAME}" "email=${EMAIL}" "password=${PASSWORD}")")"
        if resp_ok "${RESP}"; then
          ACCOUNT_STATE="新建"
          STAT_NEW_USER=$((STAT_NEW_USER + 1))
        elif resp_dup "${RESP}"; then
          ACCOUNT_STATE="已存在"
          PASSWORD="${PREV_PASSWORD[${EMAIL}]:-（上次未记录，请用超管重置密码）}"
          STAT_OLD_USER=$((STAT_OLD_USER + 1))
        else
          err "    [${DEPT_CODE}] 注册账号失败 ${NAME} <${EMAIL}>：$(printf '%s' "${RESP}" | head -c 160)"
          ACCOUNT_STATE="注册失败"
          PASSWORD=""
          STAT_FAIL_MEMBER=$((STAT_FAIL_MEMBER + 1))
        fi
      fi

      # 4b. 加入部门空间
      if [[ "${CREATE_ACCOUNTS}" == "false" ]]; then
        write_summary "  ${NAME} <${EMAIL}> 角色=${ROLE}  账号=${ACCOUNT_STATE}，请通过上方邀请链接自行注册加入"
      elif [[ "${DRY_RUN}" == "true" ]]; then
        write_summary "  ${NAME} <${EMAIL}> 角色=${ROLE}  [dry-run]"
      elif [[ "${ACCOUNT_STATE}" == "注册失败" ]]; then
        write_summary "  ${NAME} <${EMAIL}> 角色=${ROLE}  ⚠️ 账号注册失败，需人工处理"
      else
        RESP="$(http POST "/tenants/${TID}/members" "$(json_obj "email=${EMAIL}" "role=${ROLE}")" "${TID}")"
        if resp_ok "${RESP}" || resp_dup "${RESP}"; then
          if resp_dup "${RESP}"; then
            STAT_SKIP_MEMBER=$((STAT_SKIP_MEMBER + 1))
            write_summary "  ${NAME} <${EMAIL}> 角色=${ROLE}  初始密码=${PASSWORD}  （已是成员，跳过）"
          else
            STAT_NEW_MEMBER=$((STAT_NEW_MEMBER + 1))
            write_summary "  ${NAME} <${EMAIL}> 角色=${ROLE}  初始密码=${PASSWORD}"
          fi
        else
          err "    [${DEPT_CODE}] 加入空间失败 ${NAME}：$(printf '%s' "${RESP}" | head -c 160)"
          STAT_FAIL_MEMBER=$((STAT_FAIL_MEMBER + 1))
          write_summary "  ${NAME} <${EMAIL}> 角色=${ROLE}  ⚠️ 加入空间失败，需人工处理"
        fi
      fi

      printf '%s,%s,%s,%s,%s,%s,%s\n' \
        "${DEPT_CODE}" "${DEPT_NAME_OF[${DEPT_CODE}]:-}" "${NAME}" "${EMAIL}" "${ROLE}" "${PASSWORD}" "${ACCOUNT_STATE}" >> "${ACCOUNTS}"
      ;;
  esac
done < "${PLAN_FILE}"

# ---------------------------------------------------------------- 5. 注入模型
log "==> [5/7] 为部门空间注入模型"
if [[ "${SEED_MODELS}" != "true" ]]; then
  log "    已跳过（--no-models）"
elif [[ "${DRY_RUN}" == "true" ]]; then
  log "    [dry-run] 跳过注入模型"
elif [[ ${DEPT_COUNT} -eq 0 ]]; then
  log "    无部门空间需要处理"
else
  # WeKnora 的模型是空间级资源：新空间默认没有任何模型，部门文档管理员也就无法
  # 建出可运行的智能体。平台没有跨空间发布模型的接口，而 GET /models 会脱敏掉
  # api_key，因此这里直接把平台空间（默认 10000）已注册的模型行复制到各空间，
  # 参数（含密钥）原样保留。同名同类型的模型不会重复注入，可重复执行。
  if ! docker exec "${DB_CONTAINER}" psql -U postgres -d "${DB_NAME}" -c "select 1" >/dev/null 2>&1; then
    err "    无法访问数据库容器 ${DB_CONTAINER}，跳过模型注入。"
    err "    请手动为每个部门空间在原生后台「模型管理」中注册模型（含 API Key），否则智能体无法运行。"
  else
    for code in "${!TENANT_IDS[@]}"; do
      TID="${TENANT_IDS[${code}]}"
      [[ "${TID}" == dryrun-* ]] && continue
      COPIED="$(docker exec "${DB_CONTAINER}" psql -U postgres -d "${DB_NAME}" -t -A -c "
INSERT INTO models (id, tenant_id, name, display_name, type, source, description, parameters, is_default, status, created_at, updated_at, is_builtin, managed_by)
SELECT md5(random()::text || clock_timestamp()::text || m.id), ${TID}, m.name, m.display_name, m.type, m.source, m.description, m.parameters, m.is_default, m.status, now(), now(), m.is_builtin, m.managed_by
FROM models m
WHERE m.tenant_id = ${MODEL_SOURCE_TENANT} AND m.deleted_at IS NULL
  AND NOT EXISTS (SELECT 1 FROM models x WHERE x.tenant_id = ${TID} AND x.name = m.name AND x.type = m.type AND x.deleted_at IS NULL);
" 2>&1 | tr -d '[:space:]')"
      MODELS="$(http GET "/models" "${TID}")"
      MCOUNT="$(pyget "${MODELS}" "len([m for m in d.get('data',[])])")"
      log "    [${code}] 模型数：${MCOUNT}（本次新增 ${COPIED}）"
      write_summary "  —— 可用模型数：${MCOUNT}"
    done
  fi
fi

# ---------------------------------------------------------------- 5b. 绑定模型到内置智能体
# 只注入模型行不够：内置智能体 builtin-quick-answer 的 model_id 默认为空，
# 提问时后端直接报 chat model is not configured 且不写入 SSE 流，页面会一直转圈。
log "==> [5/7] 为部门空间的内置「快速问答」智能体绑定模型"
if [[ "${BIND_AGENT_MODELS}" != "true" ]]; then
  log "    已跳过（--no-bind-models）"
elif [[ "${DRY_RUN}" == "true" || ${DEPT_COUNT} -eq 0 ]]; then
  log "    [dry-run] 跳过绑定智能体模型"
else
  BIND_TIDS=""
  for code in "${!TENANT_IDS[@]}"; do
    BIND_TIDS="${BIND_TIDS:+${BIND_TIDS},}${TENANT_IDS[${code}]}"
  done
  BIND_ARGS=(--base-url "${BASE_URL}" --admin-email "${ADMIN_EMAIL}" --tenants "${BIND_TIDS}")
  [[ -n "${ADMIN_PASSWORD}" ]] && BIND_ARGS+=(--admin-password "${ADMIN_PASSWORD}")
  bash "${REPO_ROOT}/scripts/multi-tenant/bind-agent-models.sh" "${BIND_ARGS[@]}" \
    || err "    绑定智能体模型有失败项，请检查上方输出"
fi

# ---------------------------------------------------------------- 5c. 超管加入所有部门
# 「admin 默认是所有部门的管理员」：新建空间时后端已把创建者置为 Owner，这里再兜一次，
# 把历史空间、以及被原生后台改低了的超管身份统一补齐/提升（幂等，可反复执行）。
log "==> [5c/7] 保证 ${ADMIN_EMAIL} 在所有部门的管理员身份"
if [[ "${DRY_RUN}" == "true" ]]; then
  log "    [dry-run] 跳过"
else
  if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "${DB_CONTAINER}"; then
    bash "${REPO_ROOT}/scripts/multi-tenant/ensure-admin-all-departments.sh" \
        --admin-email "${ADMIN_EMAIL}" --db-container "${DB_CONTAINER}" --db-name "${DB_NAME}" \
      || err "    补齐超管部门身份有失败项，请检查上方输出"
  else
    log "    容器 ${DB_CONTAINER} 不在本机，跳过；请到部署机上执行："
    log "      sudo bash scripts/multi-tenant/ensure-admin-all-departments.sh"
  fi
fi

# ---------------------------------------------------------------- 6. 校验
log "==> [6/7] 校验各部门成员数"
if [[ "${DRY_RUN}" == "true" ]]; then
  log "    [dry-run] 跳过校验"
else
  if [[ ${DEPT_COUNT} -gt 0 ]]; then
    for code in "${!TENANT_IDS[@]}"; do
      TID="${TENANT_IDS[${code}]}"
      [[ "${TID}" == dryrun-* ]] && continue
      RESP="$(http GET "/tenants/${TID}/members?page=1&page_size=1" "${TID}")"
      COUNT="$(pyget "${RESP}" "d.get('data',{}).get('total','?')")"
      log "    [${code}] 成员数：${COUNT}"
      write_summary "  —— 当前成员数：${COUNT}"
    done
  fi
fi

# ---------------------------------------------------------------- 7. 汇总
log "==> [7/7] 完成"
cat >> "${SUMMARY}" <<EOF


================================================================
  生成时间：$(date '+%F %T')
  WeKnora：${BASE_URL}
  部门数：${DEPT_COUNT}
  新建账号：${STAT_NEW_USER}    已存在账号：${STAT_OLD_USER}
  新加入成员：${STAT_NEW_MEMBER}  已存在成员：${STAT_SKIP_MEMBER}  失败：${STAT_FAIL_MEMBER}
================================================================

  ⚠️ accounts CSV 含初始密码，属敏感文件，分发后请妥善保管并删除。

  ⚠️ 初始化未设置任何部门管理员：除平台超管（${ADMIN_EMAIL}）外，所有人当前都是
     contributor（普通成员）——超管在第 5c 步已是所有部门的管理员。

  后续操作：
    1. 由超管登录 WeKnora 原生后台（http://<虚拟机IP>:80），进入
       「工作空间 → 成员」，把各部门负责人逐个改为 owner（文档管理员）
       ——这一步必须做，否则该部门没有「人员 / 智能体 / 文档」管理入口
    2. 把成员账号密码或部门 contributor 邀请链接发给各部门负责人分发
    3. 被指定为文档管理员的成员登录门户（http://<虚拟机IP>:8081）后：
       「文档管理」建知识库并上传文档 → 「智能体管理」建智能体并绑定知识库
    4. 普通成员登录门户后即可在「问答」页对本部门文档提问
EOF

echo
echo "================================================================"
echo "  多租户初始化完成"
echo "================================================================"
echo "  部门工作空间：${DEPT_COUNT}"
echo "  新建账号 ${STAT_NEW_USER} / 已存在 ${STAT_OLD_USER}"
echo "  新加入成员 ${STAT_NEW_MEMBER} / 已存在 ${STAT_SKIP_MEMBER} / 失败 ${STAT_FAIL_MEMBER}"
echo
echo "  邀请与账号汇总：${SUMMARY}"
echo "  账号密码清单：  ${ACCOUNTS}（敏感，请妥善保管）"
echo
echo "  ⚠️ 未设置任何部门管理员，当前所有人都是 contributor（普通成员）。"
echo "     请由超管在原生后台逐个指派各部门 owner，详见汇总文件「后续操作」。"
echo
echo "  门户地址：http://<虚拟机IP>:8081"
echo "  WeKnora 原生后台：http://<虚拟机IP>:80"
echo "================================================================"
