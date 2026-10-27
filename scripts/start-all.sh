#!/usr/bin/env bash
#
# OBARA 知识问答平台 — 一键启动 / 停止 / 状态
#
# 启动内容：
#   1. Ollama 本地向量模型服务（systemd）
#   2. WeKnora 全部容器（docker compose，位于 /opt/obara/weknora）
#   3. 门户服务（8081，优先用 systemd 的 obara-portal.service，否则后台直启）
#   4. 80 端口登录守卫（obara-admin-gate.service，已安装时才启停；未安装则跳过）
#
# 用法：
#   bash scripts/start-all.sh              # 启动全部服务（默认）
#   bash scripts/start-all.sh status       # 查看各服务状态与健康检查
#   bash scripts/start-all.sh stop         # 停止门户与 WeKnora 容器
#   bash scripts/start-all.sh restart      # 重启全部服务
#
# 可选环境变量：
#   WEKNORA_DIR   WeKnora compose 目录（默认 /opt/obara/weknora）
#   PORTAL_PORT   门户端口（默认 8081）
#   WEKNORA_URL   WeKnora 后端地址（默认 http://127.0.0.1:8080）
#
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WEKNORA_DIR="${WEKNORA_DIR:-/opt/obara/weknora}"
PORTAL_PORT="${PORTAL_PORT:-8081}"
WEKNORA_URL="${WEKNORA_URL:-http://127.0.0.1:8080}"
PORTAL_URL="http://127.0.0.1:${PORTAL_PORT}"
PORTAL_PID_FILE="${PORTAL_PID_FILE:-/tmp/obara-portal.pid}"
PORTAL_SERVICE="obara-portal.service"
# 80 端口登录守卫（仅系统管理员可登录 WeKnora 原生后台，由 enable-admin-gate.sh 安装）
GATE_SERVICE="obara-admin-gate.service"
FRONTEND_INNER_PORT="${FRONTEND_INNER_PORT:-8088}"
# 超管部门身份保障：默认职位“所有部门的管理员”的平台账号与 Postgres 容器名
ADMIN_EMAIL="${ADMIN_EMAIL:-admin@obara.local}"
PG_CONTAINER="${PG_CONTAINER:-WeKnora-postgres}"

ACTION="${1:-start}"

info()  { echo "==> $*"; }
ok()    { echo "✅ $*"; }
warn()  { echo "⚠️  $*" >&2; }
fail()  { echo "❌ $*" >&2; exit 1; }

as_root() {
  if [[ "$(id -u)" -eq 0 ]]; then "$@"; else sudo "$@"; fi
}

lan_ip() {
  hostname -I 2>/dev/null | awk '{print $1}'
}

# HTTP 健康检查：wait_http <url> <超时秒数>
wait_http() {
  local url="$1" timeout="${2:-60}" waited=0
  while (( waited < timeout )); do
    if curl -fsS -m 3 "$url" >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
    waited=$((waited + 2))
  done
  return 1
}

has_portal_service() {
  systemctl cat "${PORTAL_SERVICE}" >/dev/null 2>&1
}

has_gate_service() {
  systemctl cat "${GATE_SERVICE}" >/dev/null 2>&1
}

port_pid() {
  ss -ltnp 2>/dev/null | awk -v p=":${PORTAL_PORT}" '
    $4 ~ p { if (match($0, /pid=[0-9]+/)) { print substr($0, RSTART + 4, RLENGTH - 4); exit } }
  '
}

# ---------------------------------------------------------------- 启动
start_ollama() {
  info "检查 Ollama 服务"
  if systemctl is-active --quiet ollama 2>/dev/null; then
    ok "Ollama 已运行"
  else
    info "启动 Ollama"
    as_root systemctl start ollama
    wait_http "http://127.0.0.1:11434/api/version" 30 \
      && ok "Ollama 已启动" \
      || warn "Ollama 启动后仍未就绪，请查看：journalctl -u ollama -n 50"
  fi
}

start_containers() {
  info "启动 WeKnora 容器（${WEKNORA_DIR}）"
  [[ -f "${WEKNORA_DIR}/docker-compose.yml" ]] || fail "未找到 ${WEKNORA_DIR}/docker-compose.yml，请用 WEKNORA_DIR 指定目录"
  ( cd "${WEKNORA_DIR}" && docker compose up -d )

  # Rerank 为独立容器（install-rerank.sh 创建，不归 compose 管理）
  if docker inspect weknora-rerank >/dev/null 2>&1 \
     && [[ "$(docker inspect -f '{{.State.Running}}' weknora-rerank)" != "true" ]]; then
    docker start weknora-rerank >/dev/null
    ok "Rerank 容器已启动（模型加载约需数十秒）"
  fi

  info "等待 WeKnora 后端就绪（${WEKNORA_URL}/health）"
  if wait_http "${WEKNORA_URL}/health" 150; then
    ok "WeKnora 后端已就绪"
  else
    warn "后端健康检查超时，查看日志：docker logs --tail 100 WeKnora-app"
  fi
}

ensure_admin_departments() {
  # 「admin 默认是所有部门的管理员」：每次启动兜一次，缺失 / 被降级的超管成员身份自动补齐
  local script="${ROOT_DIR}/scripts/multi-tenant/ensure-admin-all-departments.sh"
  [[ -f "${script}" ]] || { info "未找到保障脚本，跳过超管部门身份校验"; return 0; }
  if ! docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "${PG_CONTAINER}"; then
    info "Postgres 容器 ${PG_CONTAINER} 不在本机，跳过超管部门身份校验"
    return 0
  fi
  info "校验超管在所有部门的管理员身份"
  local logf; logf="$(mktemp)"
  if bash "${script}" --admin-email "${ADMIN_EMAIL}" >"${logf}" 2>&1; then
    ok "平台管理员已是全部部门的管理员"
  else
    warn "补齐超管部门身份失败，详情：" ; cat "${logf}" >&2
  fi
  rm -f "${logf}"
}

start_portal() {
  info "启动门户（${PORTAL_PORT}）"
  if curl -fsS -m 3 "${PORTAL_URL}/" >/dev/null 2>&1; then
    ok "门户已在运行"
    return 0
  fi

  if has_portal_service; then
    as_root systemctl start "${PORTAL_SERVICE}"
  else
    warn "未安装开机自启服务，使用后台进程方式启动（建议执行：sudo bash scripts/deploy/install-autostart.sh）"
    nohup python3 "${ROOT_DIR}/portal/server.py" \
      --port "${PORTAL_PORT}" --upstream "${WEKNORA_URL}" \
      > "${ROOT_DIR}/portal/portal.log" 2>&1 &
    echo $! > "${PORTAL_PID_FILE}"
  fi

  if wait_http "${PORTAL_URL}/" 30; then
    ok "门户已启动"
  else
    fail "门户启动失败。自启服务请查看：journalctl -u ${PORTAL_SERVICE} -n 50；后台模式请查看：portal/portal.log"
  fi
}

start_gate() {
  # 未安装守卫时 80 端口仍由 WeKnora 前端直出，无需处理
  has_gate_service || { info "80 端口登录守卫未安装（sudo bash scripts/deploy/enable-admin-gate.sh 可启用）"; return 0; }
  info "启动 80 端口登录守卫（${GATE_SERVICE}）"
  # 守卫反代的是已被挪到内部端口的原生前端，先确认它起来了
  if ! curl -fsS -m 3 "http://127.0.0.1:${FRONTEND_INNER_PORT}/" >/dev/null 2>&1; then
    warn "内部前端 ${FRONTEND_INNER_PORT} 未就绪，守卫启动后 80 端口会返回 502"
  fi
  as_root systemctl start "${GATE_SERVICE}"
  wait_http "http://127.0.0.1/" 30 && ok "登录守卫已启动（80 → ${FRONTEND_INNER_PORT}）" \
    || warn "守卫启动后 80 端口未响应，查看：journalctl -u ${GATE_SERVICE} -n 50"
}

do_start() {
  start_ollama
  start_containers
  ensure_admin_departments
  start_portal
  start_gate
  show_urls
}

# ---------------------------------------------------------------- 停止
stop_portal() {
  info "停止门户"
  if has_portal_service && systemctl is-active --quiet "${PORTAL_SERVICE}"; then
    as_root systemctl stop "${PORTAL_SERVICE}"
    ok "门户服务已停止"
  elif [[ -f "${PORTAL_PID_FILE}" ]] && kill -0 "$(cat "${PORTAL_PID_FILE}")" 2>/dev/null; then
    kill "$(cat "${PORTAL_PID_FILE}")" && rm -f "${PORTAL_PID_FILE}"
    ok "门户后台进程已停止"
  else
    local pid; pid="$(port_pid || true)"
    if [[ -n "${pid}" ]]; then
      kill "${pid}"
      ok "已停止占用 ${PORTAL_PORT} 的进程（PID=${pid}）"
    else
      ok "门户未运行"
    fi
  fi
}

stop_containers() {
  info "停止 WeKnora 容器"
  if [[ -f "${WEKNORA_DIR}/docker-compose.yml" ]]; then
    ( cd "${WEKNORA_DIR}" && docker compose stop )
    if docker inspect weknora-rerank >/dev/null 2>&1 \
       && [[ "$(docker inspect -f '{{.State.Running}}' weknora-rerank)" == "true" ]]; then
      docker stop weknora-rerank >/dev/null
    fi
    ok "WeKnora 容器已停止（Ollama 保持运行）"
  else
    warn "未找到 ${WEKNORA_DIR}/docker-compose.yml，跳过"
  fi
}

stop_gate() {
  if has_gate_service && systemctl is-active --quiet "${GATE_SERVICE}"; then
    as_root systemctl stop "${GATE_SERVICE}"
    ok "80 端口登录守卫已停止"
  else
    ok "登录守卫未运行"
  fi
}

do_stop() {
  stop_gate
  stop_portal
  stop_containers
}

# ---------------------------------------------------------------- 状态
do_status() {
  info "Ollama：$(systemctl is-active ollama 2>/dev/null || true) / 开机自启：$(systemctl is-enabled ollama 2>/dev/null || true)"

  info "WeKnora 容器"
  if [[ -f "${WEKNORA_DIR}/docker-compose.yml" ]]; then
    ( cd "${WEKNORA_DIR}" && docker compose ps )
  else
    warn "未找到 ${WEKNORA_DIR}/docker-compose.yml"
  fi
  if docker inspect weknora-rerank >/dev/null 2>&1; then
    info "Rerank 容器：$(docker inspect -f '{{.State.Status}}' weknora-rerank) / 重启策略：$(docker inspect -f '{{.HostConfig.RestartPolicy.Name}}' weknora-rerank)"
  fi

  local portal_state="未运行"
  if has_portal_service && systemctl is-active --quiet "${PORTAL_SERVICE}"; then
    portal_state="systemd 运行中 / 开机自启：$(systemctl is-enabled "${PORTAL_SERVICE}" 2>/dev/null || true)"
  elif [[ -n "$(port_pid || true)" ]]; then
    portal_state="后台进程运行中"
  fi
  info "门户 8081：${portal_state}"

  local gate_state="未安装（80 端口由 WeKnora 前端直出）"
  if has_gate_service; then
    gate_state="systemd $(systemctl is-active "${GATE_SERVICE}" 2>/dev/null || true) / 开机自启：$(systemctl is-enabled "${GATE_SERVICE}" 2>/dev/null || true)"
  fi
  info "80 端口守卫：${gate_state}"

  echo
  if curl -fsS -m 5 "${WEKNORA_URL}/health" >/dev/null 2>&1; then
    ok "WeKnora 后端健康：${WEKNORA_URL}/health"
  else
    warn "WeKnora 后端不可达：${WEKNORA_URL}/health"
  fi
  if curl -fsS -m 5 "${PORTAL_URL}/" >/dev/null 2>&1; then
    ok "门户可访问：${PORTAL_URL}/"
  else
    warn "门户不可访问：${PORTAL_URL}/"
    return 1
  fi
}

show_urls() {
  local ip; ip="$(lan_ip)"
  echo
  echo "================ 访问地址 ================"
  echo "  门户（全体员工）： http://${ip:-<虚拟机IP>}:${PORTAL_PORT}"
  if has_gate_service; then
    echo "  原生后台（仅管理员登录）：http://${ip:-<虚拟机IP>}"
  else
    echo "  WeKnora 原生后台： http://${ip:-<虚拟机IP>}"
  fi
  echo "  WeKnora 后端 API： http://${ip:-<虚拟机IP>}:8080"
  echo "=========================================="
}

case "${ACTION}" in
  start)   do_start ;;
  stop)    do_stop ;;
  restart) do_stop; do_start ;;
  status)  do_status ;;
  -h|--help) sed -n '2,20p' "$0" ;;
  *) fail "未知参数：${ACTION}（支持 start / stop / restart / status）" ;;
esac
