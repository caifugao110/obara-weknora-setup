#!/usr/bin/env bash
#
# OBARA 知识问答平台 — 80 端口登录守卫（仅系统管理员可登录 WeKnora 原生后台）
#
# 作用：
#   1. 把 WeKnora 原生前端从对外 80 端口挪到内部端口 8088（写 .env 的 FRONTEND_PORT）
#   2. 安装并启动 obara-admin-gate.service（Python 网关占用 80 端口，反代 8088）
#   3. 网关拦截登录：仅 GATE_ADMIN_EMAILS（默认 admin@obara.local）可登录，
#      其余账号与令牌一律 403，普通用户走 8081 门户
#   4. 网关关闭注册：注册 / 找回密码类接口与页面（/register 等）一律 403，任何人不能注册
#
# 用法：
#   sudo bash scripts/deploy/enable-admin-gate.sh                 # 启用守卫（幂等）
#   sudo GATE_ADMIN_EMAILS=admin@obara.local,ops@obara.local \
#        bash scripts/deploy/enable-admin-gate.sh                 # 自定义白名单
#   sudo bash scripts/deploy/enable-admin-gate.sh --disable       # 撤掉守卫，恢复 80 直出
#
# 可选环境变量：
#   WEKNORA_DIR        WeKnora compose 目录（默认 /opt/obara/weknora）
#   FRONTEND_INNER_PORT 原生前端内部端口（默认 8088）
#   GATE_ADMIN_EMAILS 允许登录 80 端口的邮箱白名单（默认 admin@obara.local）
#   GATE_PORTAL_URL   非管理员登录 / 进注册页被拦截后跳转的门户地址
#                     （默认 http://<请求 Host>:8081/，可用 GATE_PORTAL_PORT 改端口）
#
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WEKNORA_DIR="${WEKNORA_DIR:-/opt/obara/weknora}"
INNER_PORT="${FRONTEND_INNER_PORT:-8088}"
GATE_ADMIN_EMAILS="${GATE_ADMIN_EMAILS:-admin@obara.local}"
SERVICE_NAME="obara-admin-gate.service"
UNIT_FILE="/etc/systemd/system/${SERVICE_NAME}"
GATE_SCRIPT="${ROOT_DIR}/portal/admin_gate.py"

ACTION="install"
[[ "${1:-}" == "--disable" ]] && ACTION="disable"

if [[ "$(id -u)" -ne 0 ]]; then
  exec sudo WEKNORA_DIR="${WEKNORA_DIR}" FRONTEND_INNER_PORT="${INNER_PORT}" \
            GATE_ADMIN_EMAILS="${GATE_ADMIN_EMAILS}" bash "$0" "${1:-}"
fi

info() { echo "==> $*"; }
ok()   { echo "✅ $*"; }
warn() { echo "⚠️  $*" >&2; }
fail() { echo "❌ $*" >&2; exit 1; }

wait_http() {
  local url="$1" timeout="${2:-60}" waited=0
  while (( waited < timeout )); do
    if curl -fsS -m 3 "$url" >/dev/null 2>&1; then return 0; fi
    sleep 2; waited=$(( waited + 2 ))
  done
  return 1
}

# ---------------------------------------------------------------- 撤除守卫
if [[ "${ACTION}" == "disable" ]]; then
  info "停止并卸载 ${SERVICE_NAME}"
  systemctl disable --now "${SERVICE_NAME}" >/dev/null 2>&1 || true
  rm -f "${UNIT_FILE}"
  systemctl daemon-reload

  info "恢复 WeKnora 前端对外端口 80"
  if [[ -f "${WEKNORA_DIR}/.env" ]]; then
    if grep -qE '^FRONTEND_PORT=' "${WEKNORA_DIR}/.env"; then
      sed -i 's/^FRONTEND_PORT=.*/FRONTEND_PORT=80/' "${WEKNORA_DIR}/.env"
    else
      echo 'FRONTEND_PORT=80' >> "${WEKNORA_DIR}/.env"
    fi
    # 还原 compose 里前端的回环绑定（见 install 分支的说明）
    sed -i 's|- "127.0.0.1:${FRONTEND_PORT:-80}:80"|- "${FRONTEND_PORT:-80}:80"|' \
      "${WEKNORA_DIR}/docker-compose.yml" 2>/dev/null || true
    rm -f "${WEKNORA_DIR}/docker-compose.override.yml"
    ( cd "${WEKNORA_DIR}" && docker compose up -d --force-recreate frontend )
    wait_http "http://127.0.0.1/" 60 && ok "原生后台已恢复直接对外 80 端口" \
      || warn "80 端口暂未响应，请检查：docker logs --tail 50 WeKnora-frontend"
  else
    warn "未找到 ${WEKNORA_DIR}/.env，请手动把 FRONTEND_PORT 改回 80"
  fi
  ok "已撤除登录守卫"
  exit 0
fi

# ---------------------------------------------------------------- 启用守卫
echo "==> [1/6] 检查运行环境"
PYTHON_BIN="$(command -v python3 || true)"
[[ -n "${PYTHON_BIN}" ]] || fail "未找到 python3，请先安装：apt install python3"
[[ -f "${GATE_SCRIPT}" ]] || fail "未找到 ${GATE_SCRIPT}"
[[ -f "${WEKNORA_DIR}/docker-compose.yml" ]] || fail "未找到 ${WEKNORA_DIR}/docker-compose.yml，请用 WEKNORA_DIR 指定目录"
echo "    仓库目录：${ROOT_DIR}"
echo "    前端内部端口：${INNER_PORT}"
echo "    登录白名单：${GATE_ADMIN_EMAILS}"

echo "==> [2/6] 把 WeKnora 原生前端挪到内部端口 ${INNER_PORT}"
ENV_FILE="${WEKNORA_DIR}/.env"
if [[ ! -f "${ENV_FILE}" ]]; then
  warn "未找到 ${ENV_FILE}，从 .env.example 复制"
  cp "${WEKNORA_DIR}/.env.example" "${ENV_FILE}"
fi
if grep -qE '^FRONTEND_PORT=' "${ENV_FILE}"; then
  sed -i "s/^FRONTEND_PORT=.*/FRONTEND_PORT=${INNER_PORT}/" "${ENV_FILE}"
else
  echo "FRONTEND_PORT=${INNER_PORT}" >> "${ENV_FILE}"
fi
grep -E '^FRONTEND_PORT=' "${ENV_FILE}"

# 只监听回环：否则员工可直接访问 ${INNER_PORT} 绕过 80 端口的登录守卫。
# 注：compose 对 ports 是「数组合并」而非替换，用 override 文件会同时绑 0.0.0.0 与
# 127.0.0.1 导致端口冲突，因此这里直接改 docker-compose.yml 中前端的那一行（幂等）。
rm -f "${WEKNORA_DIR}/docker-compose.override.yml"
if grep -q '127.0.0.1:${FRONTEND_PORT:-80}:80' "${WEKNORA_DIR}/docker-compose.yml"; then
  echo "    compose 已绑定回环，跳过"
else
  cp -n "${WEKNORA_DIR}/docker-compose.yml" "${WEKNORA_DIR}/docker-compose.yml.obara-gate.bak" || true
  sed -i 's|- "${FRONTEND_PORT:-80}:80"|- "127.0.0.1:${FRONTEND_PORT:-80}:80"|' \
    "${WEKNORA_DIR}/docker-compose.yml"
fi
grep -n 'FRONTEND_PORT:-80' "${WEKNORA_DIR}/docker-compose.yml" || true

echo "==> [3/6] 重建前端容器（使其只监听 127.0.0.1:${INNER_PORT}）"
( cd "${WEKNORA_DIR}" && docker compose up -d --force-recreate frontend )
if wait_http "http://127.0.0.1:${INNER_PORT}/" 90; then
  ok "原生前端已运行在 127.0.0.1:${INNER_PORT}（不再直接对外）"
else
  fail "前端未就绪，请查看：docker logs --tail 50 WeKnora-frontend"
fi

echo "==> [4/6] 写入 systemd 服务 ${SERVICE_NAME}"
RUN_USER="${SUDO_USER:-}"
if [[ -z "${RUN_USER}" || "${RUN_USER}" == "root" ]]; then
  RUN_USER="$(stat -c '%U' "${ROOT_DIR}")"
fi
# 拦截后跳转的门户地址：默认用本机内网 IP，避免依赖浏览器请求里的 Host
if [[ -z "${GATE_PORTAL_URL:-}" ]]; then
  LAN_IP_NOW="$(hostname -I 2>/dev/null | awk '{print $1}')"
  [[ -n "${LAN_IP_NOW}" ]] && GATE_PORTAL_URL="http://${LAN_IP_NOW}:8081/"
fi
echo "    拦截后跳转：${GATE_PORTAL_URL:-（按请求 Host 推导 :8081）}"
cat > "${UNIT_FILE}" <<EOF
[Unit]
Description=OBARA Admin Gate (port 80 -> ${INNER_PORT}, admin-only login)
Documentation=file://${ROOT_DIR}/portal/admin_gate.py
After=network-online.target docker.service
Wants=network-online.target

[Service]
Type=simple
User=${RUN_USER}
WorkingDirectory=${ROOT_DIR}/portal
Environment=PYTHONUNBUFFERED=1
Environment=GATE_PORT=80
Environment=GATE_UPSTREAM=http://127.0.0.1:${INNER_PORT}
Environment=GATE_ADMIN_EMAILS=${GATE_ADMIN_EMAILS}
Environment=GATE_PORTAL_URL=${GATE_PORTAL_URL:-}
# 绑定 80 特权端口：只授予 CAP_NET_BIND_SERVICE，不整体以 root 运行
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_BIND_SERVICE
NoNewPrivileges=true
ExecStart=${PYTHON_BIN} ${GATE_SCRIPT} --port 80 --upstream http://127.0.0.1:${INNER_PORT}
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable "${SERVICE_NAME}" >/dev/null
systemctl restart "${SERVICE_NAME}"
sleep 2

echo "==> [5/6] 健康检查"
if ! wait_http "http://127.0.0.1/" 30; then
  fail "80 端口未响应，请查看：journalctl -u ${SERVICE_NAME} -n 50"
fi
ok "80 端口可访问（网关已接管）"

echo "==> [6/6] 登录守卫验证"
CODE_NONADMIN="$(curl -s -o /tmp/obara-gate-check.json -w '%{http_code}' -X POST \
  http://127.0.0.1/api/v1/auth/login \
  -H 'Content-Type: application/json' \
  -d '{"email":"nobody@obara.local","password":"not-a-real-password"}' || true)"
if [[ "${CODE_NONADMIN}" == "403" ]]; then
  ok "非白名单账号登录已被拦截（HTTP 403）"
else
  warn "非白名单账号未被拦截（HTTP ${CODE_NONADMIN}），请检查：journalctl -u ${SERVICE_NAME} -n 50"
fi
cat /tmp/obara-gate-check.json 2>/dev/null | head -c 300; echo
rm -f /tmp/obara-gate-check.json

# 任何人都不能注册：注册接口与注册页面都必须被拒
CODE_REGISTER="$(curl -s -o /dev/null -w '%{http_code}' -X POST \
  http://127.0.0.1/api/v1/auth/register \
  -H 'Content-Type: application/json' \
  -d '{"email":"nobody@obara.local","password":"not-a-real-password"}' || true)"
if [[ "${CODE_REGISTER}" == "403" ]]; then
  ok "自助注册接口已关闭（HTTP 403）"
else
  warn "自助注册未被拦截（HTTP ${CODE_REGISTER}），请检查：journalctl -u ${SERVICE_NAME} -n 50"
fi

CODE_REGISTER_PAGE="$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1/register || true)"
if [[ "${CODE_REGISTER_PAGE}" == "403" ]]; then
  ok "注册页面已关闭（HTTP 403，返回提示页）"
else
  warn "注册页面未被拦截（HTTP ${CODE_REGISTER_PAGE}）"
fi

LAN_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
echo
echo "================ 访问策略 ================"
echo "  原生后台（仅管理员）：http://${LAN_IP:-<虚拟机IP>}          → 白名单：${GATE_ADMIN_EMAILS}"
echo "  OBARA 门户（全体员工）：http://${LAN_IP:-<虚拟机IP>}:8081"
echo "------------------------------------------"
echo "  服务状态：$(systemctl is-active "${SERVICE_NAME}") / 开机自启：$(systemctl is-enabled "${SERVICE_NAME}")"
echo "  查看日志：journalctl -u ${SERVICE_NAME} -f"
echo "  撤除守卫：sudo bash scripts/deploy/enable-admin-gate.sh --disable"
echo "=========================================="
