#!/usr/bin/env bash
#
# 保证「平台管理员（admin）默认拥有所有部门的管理员身份」
#
# 做什么：逐个部门（工作空间）检查平台管理员的成员记录
#     缺失         → 补建成员记录（默认 owner，可用 --role admin 调整）
#     角色不够     → 提升为目标角色（如 admin → owner）
#     已是目标角色 → 跳过（幂等，可反复执行）
#
# 为什么需要：门户代理层虽对超管放行，但成员列表里看不到 admin、原生后台换人时也
#   容易把超管的部门身份改低。本脚本把「admin 默认是所有部门的管理员」落成数据库
#   中的确定事实；新建部门时后端已自动把创建者置为 Owner，这里兜住其它场景。
#
# 用法（在部署机上执行，直连 Postgres 容器）：
#   sudo bash scripts/multi-tenant/ensure-admin-all-departments.sh             # 生效
#   sudo bash scripts/multi-tenant/ensure-admin-all-departments.sh --dry-run   # 只检查
#   sudo bash scripts/multi-tenant/ensure-admin-all-departments.sh --role admin
#   sudo bash scripts/multi-tenant/ensure-admin-all-departments.sh --tenant 10011
#
set -euo pipefail

ADMIN_EMAIL="${ADMIN_EMAIL:-admin@obara.local}"
TARGET_ROLE="owner"
DRY_RUN="false"
DB_CONTAINER="${DB_CONTAINER:-WeKnora-postgres}"
DB_NAME="${DB_NAME:-WeKnora}"
DB_USER="${DB_USER:-postgres}"
FILTER=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --admin-email)  ADMIN_EMAIL="$2"; shift 2 ;;
    --role)         TARGET_ROLE="$2"; shift 2 ;;
    --tenant)       FILTER+=("$2"); shift 2 ;;
    --db-container) DB_CONTAINER="$2"; shift 2 ;;
    --db-name)      DB_NAME="$2"; shift 2 ;;
    --db-user)      DB_USER="$2"; shift 2 ;;
    --dry-run)      DRY_RUN="true"; shift ;;
    -h|--help)      sed -n '3,22p' "$0"; exit 0 ;;
    *) echo "未知参数：$1（-h 查看用法）" >&2; exit 1 ;;
  esac
done

if [[ "${TARGET_ROLE}" != "owner" && "${TARGET_ROLE}" != "admin" ]]; then
  echo "❌ --role 只支持 owner / admin：只有这两种角色具备部门管理能力" >&2
  exit 1
fi

log() { printf '%s\n' "$*"; }
err() { printf '  ❌ %s\n' "$*" >&2; }

STAT_TOTAL=0; STAT_OK=0; STAT_CREATED=0; STAT_FIXED=0; STAT_FAILED=0

sql_str() { printf "%s" "${1//\'/\'\'}"; }
# 注意：不能用 docker exec -i，否则 psql 会把 while read 的输入一起吃掉
psql_exec() { docker exec "${DB_CONTAINER}" psql -U "${DB_USER}" -d "${DB_NAME}" -tAq -c "$1"; }

# 未指定 --tenant 时全部处理
wanted() {
  [[ ${#FILTER[@]} -eq 0 ]] && return 0
  local f
  for f in "${FILTER[@]}"; do [[ "$f" == "$1" ]] && return 0; done
  return 1
}

echo "================================================================"
echo "  保证平台管理员在全部部门的管理员身份"
echo "================================================================"
DRY_TAG=""
[[ "${DRY_RUN}" == "true" ]] && DRY_TAG="   (dry-run)"
echo "  目标账号：${ADMIN_EMAIL}   目标角色：${TARGET_ROLE}${DRY_TAG}"

command -v docker >/dev/null 2>&1 || { err "未找到 docker"; exit 1; }
docker ps --format '{{.Names}}' | grep -qx "${DB_CONTAINER}" || { err "容器 ${DB_CONTAINER} 未运行"; exit 1; }

EMAIL="$(sql_str "${ADMIN_EMAIL}")"
UID_="$(psql_exec "select id from users where lower(email)=lower('${EMAIL}') and deleted_at is null limit 1;")"
[[ -n "${UID_}" ]] || UID_="$(psql_exec "select id from users where lower(email)=lower('${EMAIL}') limit 1;")"
[[ -n "${UID_}" ]] || { err "数据库中找不到账号 ${ADMIN_EMAIL}"; exit 1; }
log "  管理员账号：${ADMIN_EMAIL}（user_id=${UID_}）"

ROWS="$(psql_exec "select id||E'\t'||name from tenants where deleted_at is null order by id;")"

while IFS=$'\t' read -r TID TNAME; do
  [[ -z "${TID}" ]] && continue
  wanted "${TID}" || continue
  STAT_TOTAL=$((STAT_TOTAL + 1))
  ROLE="$(psql_exec "select role from tenant_members where user_id='${UID_}' and tenant_id=${TID} and deleted_at is null limit 1;")"

  if [[ "${ROLE}" == "${TARGET_ROLE}" ]]; then
    STAT_OK=$((STAT_OK + 1)); log "    [${TID}] ${TNAME}：已是 ${TARGET_ROLE}"; continue
  fi
  if [[ "${DRY_RUN}" == "true" ]]; then
    if [[ -z "${ROLE}" ]]; then log "    [${TID}] ${TNAME}：[dry-run] 无成员记录，将补建为 ${TARGET_ROLE}"
    else log "    [${TID}] ${TNAME}：[dry-run] ${ROLE} → ${TARGET_ROLE}"; fi
    STAT_FIXED=$((STAT_FIXED + 1)); continue
  fi
  if [[ -z "${ROLE}" ]]; then
    if psql_exec "insert into tenant_members (user_id, tenant_id, role, status, joined_at, created_at, updated_at) values ('${UID_}', ${TID}, '${TARGET_ROLE}', 'active', now(), now(), now());" >/dev/null 2>&1; then
      STAT_CREATED=$((STAT_CREATED + 1)); log "    [${TID}] ${TNAME}：已补建成员记录（${TARGET_ROLE}）"
    else
      STAT_FAILED=$((STAT_FAILED + 1)); err "[${TID}] ${TNAME}：补建成员记录失败"
    fi
  else
    if psql_exec "update tenant_members set role='${TARGET_ROLE}', status='active', deleted_at=null, updated_at=now() where user_id='${UID_}' and tenant_id=${TID};" >/dev/null 2>&1; then
      STAT_FIXED=$((STAT_FIXED + 1)); log "    [${TID}] ${TNAME}：${ROLE} → ${TARGET_ROLE}"
    else
      STAT_FAILED=$((STAT_FAILED + 1)); err "[${TID}] ${TNAME}：提升角色失败"
    fi
  fi
done < <(printf '%s\n' "${ROWS}")

echo
echo "  检查部门 ${STAT_TOTAL}：已合规 ${STAT_OK}，补建 ${STAT_CREATED}，提升 ${STAT_FIXED}，失败 ${STAT_FAILED}"
[[ ${STAT_FAILED} -eq 0 ]] || { echo "  ❌ 有部门未能处理，请检查上方输出"; exit 1; }
echo "  ✅ 平台管理员已是全部部门的管理员"
echo "================================================================"
