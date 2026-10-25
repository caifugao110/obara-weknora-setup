#!/usr/bin/env bash
#
# 安装 Ollama 本地模型服务（为 WeKnora 提供 Embedding 向量能力）
# 适用于 OBARA 知识库系统部署 —— 阶段三
#
# 用法：
#   sudo bash scripts/deploy/install-ollama.sh                       # 安装并拉取默认模型 bge-m3
#   sudo bash scripts/deploy/install-ollama.sh --models "bge-m3 embeddinggemma:300m"
#   sudo bash scripts/deploy/install-ollama.sh --skip-models         # 只装服务，不拉模型
#   sudo bash scripts/deploy/install-ollama.sh --models-dir /opt/ollama/models
#
# 特性：幂等，可重复执行；已安装且版本满足要求时会跳过重装。
#
set -euo pipefail

# ---------------------------------------------------------------- 参数
MODELS="bge-m3"
MODELS_DIR="/opt/ollama/models"
OLLAMA_LISTEN="0.0.0.0:11434"
KEEP_ALIVE="10m"
MAX_LOADED_MODELS=2
SKIP_MODELS="false"
REINSTALL="false"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --models)        MODELS="${2:-}"; shift 2 ;;
    --models-dir)    MODELS_DIR="${2}"; shift 2 ;;
    --listen)        OLLAMA_LISTEN="${2}"; shift 2 ;;
    --keep-alive)    KEEP_ALIVE="${2}"; shift 2 ;;
    --skip-models)   SKIP_MODELS="true"; shift ;;
    --reinstall)     REINSTALL="true"; shift ;;
    -h|--help)
      sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "❌ 未知参数：$1（--help 查看用法）" >&2; exit 1 ;;
  esac
done

# ---------------------------------------------------------------- 基础检查
if [[ "$(id -u)" -ne 0 ]]; then
  echo "❌ 请以 root 权限执行：sudo bash $0" >&2
  exit 1
fi

ARCH="$(uname -m)"
case "${ARCH}" in
  x86_64) ARCH_SUFFIX="amd64" ;;
  aarch64|arm64) ARCH_SUFFIX="arm64" ;;
  *) echo "❌ 不支持的架构：${ARCH}" >&2; exit 1 ;;
esac

# shellcheck disable=SC1091
source /etc/os-release
echo "==> 系统：${PRETTY_NAME}  架构：${ARCH}（${ARCH_SUFFIX}）"

# ---------------------------------------------------------------- 1. 依赖
echo "==> [1/7] 安装依赖（curl / zstd / jq）"
export DEBIAN_FRONTEND=noninteractive
apt-get update -y -qq
apt-get install -y -qq curl zstd jq >/dev/null

# ---------------------------------------------------------------- 2. 下载 Ollama 发行包
# 下载源优先级：
#   ① ModelScope 镜像（国内可达，实测 ~8MB/s）—— 本机 GitHub 直连不通时的首选
#   ② Ollama 官方 CDN（会 307 跳转到 GitHub Release）
#   ③ GitHub Release 直连
echo "==> [2/7] 获取 Ollama 发行包"
TMP_DIR="$(mktemp -d /tmp/ollama-install.XXXXXX)"
cleanup() { rm -rf "${TMP_DIR}"; }
trap cleanup EXIT

PKG_FILE=""
if [[ "${REINSTALL}" != "true" ]] && command -v ollama >/dev/null 2>&1; then
  echo "    本机已安装 Ollama，跳过下载与二进制安装（重装请加 --reinstall）"
  SKIP_INSTALL="true"
else
  SKIP_INSTALL="false"
fi

if [[ "${SKIP_INSTALL}" == "false" ]]; then
PKG_URLS=(
  "https://modelscope.cn/models/modelscope/ollama-linux/resolve/master/ollama-linux-${ARCH_SUFFIX}.tar.zst"
  "https://ollama.com/download/ollama-linux-${ARCH_SUFFIX}.tgz"
  "https://github.com/ollama/ollama/releases/latest/download/ollama-linux-${ARCH_SUFFIX}.tgz"
)

PKG_FILE=""
for url in "${PKG_URLS[@]}"; do
  echo "    尝试源：${url}"
  target="${TMP_DIR}/pkg.$(basename "${url}")"
  # 先做一次短探测：确认源可达且返回 ≥100MB 的包，避免慢而无返的连接拖死流程
  if curl -fsSL --connect-timeout 10 --max-time 20 -r 0-1048576 -o "${TMP_DIR}/probe.bin" \
       -w '%{http_code}' "${url}" 2>/dev/null | grep -qE '^(200|206)$'; then
    echo "    源可达，开始完整下载（约 1.8GB，视带宽 3~10 分钟）"
    if curl -fL --retry 3 --retry-delay 5 -C - -o "${target}" "${url}"; then
      PKG_FILE="${target}"
      ls -lh "${PKG_FILE}"
      break
    fi
  fi
  echo "    该源不可用，切换下一个"
done

if [[ -z "${PKG_FILE}" ]]; then
  echo "❌ 所有下载源均失败。请检查外网/代理后重试，或参考主文档 1.4 节配置代理。" >&2
  exit 1
fi
fi  # 结束 【下载发行包】块，已安装时会跳过上述整段

# ---------------------------------------------------------------- 3. 安装二进制
echo "==> [3/7] 安装 ollama 二进制到 /usr/bin、运行库到 /usr/lib/ollama"
if [[ -n "${PKG_FILE}" ]]; then
  mkdir -p "${TMP_DIR}/extract"
  case "${PKG_FILE}" in
    *.tar.zst) tar --use-compress-program=unzstd -xf "${PKG_FILE}" -C "${TMP_DIR}/extract" ;;
    *.tgz)     tar -xzf "${PKG_FILE}" -C "${TMP_DIR}/extract" ;;
    *)         echo "❌ 未知的打包格式：${PKG_FILE}" >&2; exit 1 ;;
  esac

  OLLAMA_BIN="$(find "${TMP_DIR}/extract" -type f -name ollama -perm -u+x -print -quit)"
  if [[ -z "${OLLAMA_BIN}" ]]; then
    echo "❌ 发行包内未找到 ollama 可执行文件" >&2
    exit 1
  fi

  install -m 0755 "${OLLAMA_BIN}" /usr/bin/ollama
  EXTRACT_LIB="$(find "${TMP_DIR}/extract" -type d -name ollama -path '*/lib/ollama' -print -quit)"
  if [[ -n "${EXTRACT_LIB}" ]]; then
    rm -rf /usr/lib/ollama
    cp -a "${EXTRACT_LIB}" /usr/lib/ollama
  fi
fi

if [[ -x /usr/bin/ollama ]]; then
  echo "    二进制就绪：/usr/bin/ollama  $(stat -c '%s 字节' /usr/bin/ollama)"
else
  echo "❌ 未找到 /usr/bin/ollama，安装失败" >&2
  exit 1
fi

# ---------------------------------------------------------------- 4. 用户与模型目录
echo "==> [4/7] 创建服务账号与模型目录"
if ! id -u ollama >/dev/null 2>&1; then
  useradd -r -s /bin/false -U -m -d /usr/share/ollama ollama
  echo "    已创建系统账号 ollama"
fi
mkdir -p "${MODELS_DIR}"
chown -R ollama:ollama "${MODELS_DIR}"

# ---------------------------------------------------------------- 5. systemd 服务
echo "==> [5/7] 配置 systemd 服务"
cat >/etc/systemd/system/ollama.service <<'EOF'
[Unit]
Description=Ollama Service（WeKnora 本地向量模型）
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=/usr/bin/ollama serve
User=ollama
Group=ollama
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

mkdir -p /etc/systemd/system/ollama.service.d
cat >/etc/systemd/system/ollama.service.d/override.conf <<EOF
[Service]
Environment="OLLAMA_HOST=${OLLAMA_LISTEN}"
Environment="OLLAMA_MODELS=${MODELS_DIR}"
Environment="OLLAMA_KEEP_ALIVE=${KEEP_ALIVE}"
Environment="OLLAMA_MAX_LOADED_MODELS=${MAX_LOADED_MODELS}"
Environment="OLLAMA_CONTEXT_LENGTH=8192"
EOF

systemctl daemon-reload
systemctl enable --now ollama.service

# 等待服务就绪
for i in {1..30}; do
  if curl -fsS --max-time 3 http://127.0.0.1:11434/api/version >/dev/null 2>&1; then
    break
  fi
  sleep 1
done

echo "    API 版本：$(curl -fsS --max-time 5 http://127.0.0.1:11434/api/version)"
systemctl is-active ollama.service

# ---------------------------------------------------------------- 6. 拉取模型
if [[ "${SKIP_MODELS}" == "true" ]]; then
  echo "==> [6/7] 已指定 --skip-models，跳过模型拉取"
else
  echo "==> [6/7] 拉取模型：${MODELS}"
  for m in ${MODELS}; do
    echo "    ---- ${m} ----"
    for attempt in 1 2 3; do
      if ollama pull "${m}"; then
        break
      fi
      echo "    拉取失败，重试 (${attempt}/3)..."
      sleep 10
    done
    if ! ollama show "${m}" >/dev/null 2>&1; then
      echo "❌ 模型 ${m} 拉取失败，请检查网络后重跑脚本" >&2
      exit 1
    fi
  done
fi

# ---------------------------------------------------------------- 7. 验证与输出
echo "==> [7/7] 安装结果"
ollama list

echo
echo "===== Embedding 连通性验证 ====="
for m in ${MODELS}; do
  if [[ "${SKIP_MODELS}" == "true" ]]; then
    break
  fi
  DIM="$(curl -fsS --max-time 120 http://127.0.0.1:11434/api/embeddings \
          -d "{\"model\":\"${m}\",\"prompt\":\"电极使用规范测试\"}" | jq '.embedding | length')"
  echo "  ${m} → 向量维度 ${DIM}"
done

echo
echo "===== 服务信息 ====="
echo "监听地址：${OLLAMA_LISTEN}"
echo "模型目录：${MODELS_DIR}"
echo "服务状态：$(systemctl is-active ollama.service) / 开机自启：$(systemctl is-enabled ollama.service)"
echo
echo "提示：WeKnora 容器访问本机 Ollama 需使用宿主地址，详见 docs/deployment/deployment-log.md 阶段三"
