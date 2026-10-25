#!/usr/bin/env bash
#
# OBARA 知识问答平台 — 门户启动脚本
#
# 用法：
#   bash portal/start.sh                          # 默认端口 8081，上游 127.0.0.1:8080
#   PORTAL_PORT=8082 bash portal/start.sh         # 自定义端口
#   WEKNORA_URL=http://192.168.1.10:8080 bash portal/start.sh   # 自定义上游
#   bash portal/start.sh --daemon                 # 后台运行
#
set -euo pipefail

PORTAL_PORT="${PORTAL_PORT:-8081}"
WEKNORA_URL="${WEKNORA_URL:-http://127.0.0.1:8080}"
DAEMON="false"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --port)        PORTAL_PORT="${2}"; shift 2 ;;
    --upstream)    WEKNORA_URL="${2}"; shift 2 ;;
    --daemon|-d)   DAEMON="true"; shift ;;
    -h|--help)     sed -n '2,12p' "$0"; exit 0 ;;
    *) echo "未知参数：$1"; exit 1 ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"

# 检查 Python3
if ! command -v python3 >/dev/null 2>&1; then
  echo "❌ 缺少 python3，请先安装：sudo apt install python3" >&2
  exit 1
fi

# 检查上游连通性
echo "==> 检查 WeKnora 上游连通性（${WEKNORA_URL}/health）"
if ! curl -fsS -m 5 "${WEKNORA_URL}/health" >/dev/null 2>&1; then
  echo "⚠️  上游 ${WEKNORA_URL} 暂不可达，门户仍会启动但 API 调用会失败"
fi

export PORTAL_PORT WEKNORA_URL

if [[ "${DAEMON}" == "true" ]]; then
  LOG_FILE="${SCRIPT_DIR}/portal.log"
  nohup python3 server.py --port "${PORTAL_PORT}" --upstream "${WEKNORA_URL}" > "${LOG_FILE}" 2>&1 &
  PID=$!
  echo "==> 门户已后台启动（PID=${PID}）"
  echo "    日志：${LOG_FILE}"
  echo "    访问：http://<本机IP>:${PORTAL_PORT}"
  echo "    停止：kill ${PID}"
else
  echo "==> 启动门户（前台运行，Ctrl+C 停止）"
  echo "    访问地址：http://<本机IP>:${PORTAL_PORT}"
  exec python3 server.py --port "${PORTAL_PORT}" --upstream "${WEKNORA_URL}"
fi
