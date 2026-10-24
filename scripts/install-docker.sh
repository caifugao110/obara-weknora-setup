#!/usr/bin/env bash
#
# 安装 Docker 引擎 + Docker Compose 插件（Ubuntu 20.04/22.04，amd64）
# 适用于 OBARA 知识库系统（WeKnora）部署的前置环境准备
#
# 用法：sudo bash install-docker.sh
#
set -euo pipefail

# ---------------------------------------------------------------- 基础检查
if [[ "$(id -u)" -ne 0 ]]; then
  echo "❌ 请以 root 权限执行：sudo bash $0" >&2
  exit 1
fi

source /etc/os-release
ARCH="$(dpkg --print-architecture)"
echo "==> 系统：${PRETTY_NAME}  架构：${ARCH}"

if [[ "${ARCH}" != "amd64" && "${ARCH}" != "arm64" ]]; then
  echo "❌ 不支持的架构：${ARCH}" >&2
  exit 1
fi

SUDO_USER_NAME="${SUDO_USER:-${USER:-root}}"

# ---------------------------------------------------------------- 1. 依赖
echo "==> [1/6] 安装依赖包"
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y ca-certificates curl gnupg lsb-release apt-transport-https

install -m 0755 -d /etc/apt/keyrings

# ---------------------------------------------------------------- 2. GPG 公钥
echo "==> [2/6] 导入 Docker 官方 GPG 公钥"
GPG_DST="/etc/apt/keyrings/docker.asc"
for i in 1 2 3; do
  if curl -fsSL --connect-timeout 15 "https://mirrors.tuna.tsinghua.edu.cn/docker-ce/linux/ubuntu/gpg" -o "${GPG_DST}" \
     || curl -fsSL --connect-timeout 15 "https://download.docker.com/linux/ubuntu/gpg" -o "${GPG_DST}"; then
    break
  fi
  echo "    重试导入公钥 (${i}/3)..."
  sleep 3
done

if [[ ! -s "${GPG_DST}" ]]; then
  echo "❌ GPG 公钥下载失败，请检查网络/代理后重试" >&2
  exit 1
fi
chmod a+r "${GPG_DST}"

# ---------------------------------------------------------------- 3. APT 源
echo "==> [3/6] 配置 Docker APT 源（清华镜像）"
CODENAME="$(lsb_release -cs)"
# 兜底：部分镜像站尚未提供 noble/jammy 之外的代号映射
case "${CODENAME}" in
  focal|jammy|noble) ;;
  *) CODENAME="jammy" ;;
esac

DOCKER_REPO_URL="https://mirrors.tuna.tsinghua.edu.cn/docker-ce/linux/ubuntu"
if ! curl -fsSI --connect-timeout 10 "${DOCKER_REPO_URL}/dists/${CODENAME}/Release" >/dev/null 2>&1; then
  echo "    清华源不可用，回退官方源"
  DOCKER_REPO_URL="https://download.docker.com/linux/ubuntu"
fi

cat >/etc/apt/sources.list.d/docker.list <<EOF
deb [arch=${ARCH} signed-by=${GPG_DST}] ${DOCKER_REPO_URL} ${CODENAME} stable
EOF
echo "    源已写入：${DOCKER_REPO_URL} ${CODENAME} stable"

# ---------------------------------------------------------------- 4. 安装
echo "==> [4/6] 安装 docker-ce / containerd.io / compose 插件"
apt-get update -y
apt-get install -y \
  docker-ce \
  docker-ce-cli \
  containerd.io \
  docker-buildx-plugin \
  docker-compose-plugin

# ---------------------------------------------------------------- 5. daemon 配置
echo "==> [5/6] 配置 /etc/docker/daemon.json"
mkdir -p /etc/docker
if [[ -f /etc/docker/daemon.json ]]; then
  cp -a /etc/docker/daemon.json "/etc/docker/daemon.json.bak.$(date +%Y%m%d%H%M%S)"
  echo "    已备份原配置"
fi

cat >/etc/docker/daemon.json <<'EOF'
{
  "registry-mirrors": [
    "https://docker.m.daocloud.io",
    "https://docker.xuanyuan.me"
  ],
  "exec-opts": ["native.cgroupdriver=systemd"],
  "storage-driver": "overlay2",
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "100m",
    "max-file": "3"
  },
  "live-restore": true,
  "dns": ["223.5.5.5", "114.114.114.114"]
}
EOF

systemctl daemon-reload
systemctl enable --now docker

# ---------------------------------------------------------------- 6. 权限与验证
echo "==> [6/6] 配置用户组并验证"
if [[ "${SUDO_USER_NAME}" != "root" ]]; then
  usermod -aG docker "${SUDO_USER_NAME}"
  echo "    已将 ${SUDO_USER_NAME} 加入 docker 组（需重新登录生效）"
fi

echo
echo "===== 安装结果 ====="
docker --version
docker compose version
echo "--- 服务状态 ---"
systemctl is-active docker
echo "--- daemon 信息 ---"
docker info --format 'ServerVersion={{.ServerVersion}} StorageDriver={{.Driver}} CgroupDriver={{.CgroupDriver}}'
docker info --format '{{range .RegistryConfig.Mirrors}}{{println .}}{{end}}' || true

echo
echo "===== 镜像拉取连通性测试（hello-world）====="
if timeout 180 docker run --rm hello-world >/dev/null 2>&1; then
  echo "✅ Docker 安装完成，镜像拉取正常"
else
  echo "⚠️  hello-world 拉取失败：可能是网络/加速器不通。"
  echo "    可手动排查：sudo docker pull hello-world"
  echo "    或检查公司代理后在 /etc/docker/daemon.json 中配置 proxies"
fi

echo
echo "提示：当前终端执行 newgrp docker 或重新登录后即可免 sudo 使用 docker"
