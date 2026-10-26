#!/usr/bin/env bash
#
# OBARA 知识问答平台 — 安装门户开机自启（systemd）
#
# 作用：
#   1. 创建 /etc/systemd/system/obara-portal.service（端口 8081 门户）
#   2. 设置开机自启并立即启动
#   3. 确认 docker / ollama 也已开机自启（WeKnora 容器由 docker 的
#      restart: unless-stopped 策略随开机拉起）
#
# 用法：
#   sudo bash scripts/deploy/install-autostart.sh              # 安装并启用
#   sudo bash scripts/deploy/install-autostart.sh --uninstall  # 卸载自启服务
#
# 可选环境变量：
#   PORTAL_PORT   门户端口（默认 8081）
#   WEKNORA_URL   WeKnora 后端地址（默认 http://127.0.0.1:8080）
#
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PORTAL_PORT="${PORTAL_PORT:-8081}"
WEKNORA_URL="${WEKNORA_URL:-http://127.0.0.1:8080}"
SERVICE_NAME="obara-portal.service"
UNIT_FILE="/etc/systemd/system/${SERVICE_NAME}"

ACTION="install"
[[ "${1:-}" == "--uninstall" ]] && ACTION="uninstall"

if [[ "${ACTION}" == "uninstall" ]]; then
  [[ "$(id -u)" -eq 0 ]] || exec sudo bash "$0" --uninstall
  systemctl disable --now "${SERVICE_NAME}" 2>/dev/null || true
  rm -f "${UNIT_FILE}"
  systemctl daemon-reload
  echo "✅ 已卸载 ${SERVICE_NAME}（门户不再开机自启）"
  exit 0
fi

# 需要 root：未提权时自动用 sudo 重新执行
if [[ "$(id -u)" -ne 0 ]]; then
  exec sudo bash "$0" "$@"
fi

echo "==> [1/5] 检查运行环境"
PYTHON_BIN="$(command -v python3 || true)"
[[ -n "${PYTHON_BIN}" ]] || { echo "❌ 未找到 python3，请先安装：apt install python3" >&2; exit 1; }
[[ -f "${ROOT_DIR}/portal/server.py" ]] || { echo "❌ 未找到 ${ROOT_DIR}/portal/server.py" >&2; exit 1; }

# 运行用户：优先使用执行 sudo 的普通用户，其次使用仓库目录属主
RUN_USER="${SUDO_USER:-}"
if [[ -z "${RUN_USER}" || "${RUN_USER}" == "root" ]]; then
  RUN_USER="$(stat -c '%U' "${ROOT_DIR}")"
fi

echo "    仓库目录：${ROOT_DIR}"
echo "    运行用户：${RUN_USER}"
echo "    Python：  ${PYTHON_BIN}"
echo "    门户端口：${PORTAL_PORT} → 上游 ${WEKNORA_URL}"

echo "==> [2/5] 检查 ${PORTAL_PORT} 端口占用"
if ss -ltn 2>/dev/null | awk '{print $4}' | grep -qE ":${PORTAL_PORT}$"; then
  if systemctl is-active --quiet "${SERVICE_NAME}" 2>/dev/null; then
    echo "    端口由 ${SERVICE_NAME} 占用，稍后会重启该服务"
  else
    echo "❌ ${PORTAL_PORT} 端口已被其他进程占用，请先停止后重试：" >&2
    echo "   sudo ss -ltnp | grep ':${PORTAL_PORT}'" >&2
    echo "   或执行：bash scripts/start-all.sh stop" >&2
    exit 1
  fi
else
  echo "    端口空闲"
fi

echo "==> [3/5] 写入 systemd 服务"
cat > "${UNIT_FILE}" <<EOF
[Unit]
Description=OBARA Knowledge Portal (port ${PORTAL_PORT})
Documentation=file://${ROOT_DIR}/docs/multi-tenant-design.md
After=network-online.target docker.service ollama.service
Wants=network-online.target

[Service]
Type=simple
User=${RUN_USER}
WorkingDirectory=${ROOT_DIR}/portal
Environment=PYTHONUNBUFFERED=1
Environment=PORTAL_PORT=${PORTAL_PORT}
Environment=WEKNORA_URL=${WEKNORA_URL}
ExecStart=${PYTHON_BIN} ${ROOT_DIR}/portal/server.py --port ${PORTAL_PORT} --upstream ${WEKNORA_URL}
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

echo "==> [4/5] 启用开机自启并启动"
systemctl daemon-reload
systemctl enable "${SERVICE_NAME}" >/dev/null
# Docker 与 Ollama 也需要随开机启动（通常已 enabled，这里做幂等确认）
systemctl enable docker.service >/dev/null 2>&1 || true
systemctl enable ollama.service >/dev/null 2>&1 || true
systemctl restart "${SERVICE_NAME}"

echo "==> [5/5] 健康检查"
for i in {1..20}; do
  if curl -fsS -m 3 "http://127.0.0.1:${PORTAL_PORT}/" >/dev/null 2>&1; then
    break
  fi
  sleep 1
done

if curl -fsS -m 3 "http://127.0.0.1:${PORTAL_PORT}/" >/dev/null 2>&1; then
  LAN_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
  echo
  echo "✅ 门户已启动并设为开机自启"
  echo "   服务状态：$(systemctl is-active "${SERVICE_NAME}") / 开机自启：$(systemctl is-enabled "${SERVICE_NAME}")"
  echo "   访问地址：http://${LAN_IP:-<虚拟机IP>}:${PORTAL_PORT}"
  echo "   查看日志：journalctl -u ${SERVICE_NAME} -f"
  echo
  echo "提示：虚拟机重启后，Docker 会按 restart 策略自动拉起 WeKnora 容器，"
  echo "      本服务会自动启动门户。若需手动一键启停，使用：bash scripts/start-all.sh"
else
  echo "❌ 门户未能响应，请查看日志：journalctl -u ${SERVICE_NAME} -n 50" >&2
  exit 1
fi
