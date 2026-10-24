#!/usr/bin/env bash
#
# 修复项：
#   1) /etc/apt/sources.list 中 cn.mirrors.tuna.tsinghua.edu.cn 无法解析，替换为可用域名
#   2) Docker daemon 在包安装时已先启动，导致 /etc/docker/daemon.json 未生效 → 重启加载
#   3) 重新校准 registry 加速器（当前网络下 Docker Hub 直连不通）
#
# 用法：sudo bash fix-docker-env.sh
#
set -euo pipefail

if [[ "$(id -u)" -ne 0 ]]; then
  echo "❌ 请以 root 权限执行：sudo bash $0" >&2
  exit 1
fi

apt-get install -y curl >/dev/null 2>&1 || true

# ------------------------------------------------- 1. 修复 APT 源域名
echo "==> [1/4] 修复 APT 源域名"
if [[ -f /etc/apt/sources.list ]]; then
  cp -a /etc/apt/sources.list "/etc/apt/sources.list.bak.$(date +%Y%m%d%H%M%S)"
  sed -i 's#cn\.mirrors\.tuna\.tsinghua\.edu\.cn#mirrors.tuna.tsinghua.edu.cn#g' /etc/apt/sources.list
fi
sed -i 's#cn\.mirrors\.tuna\.tsinghua\.edu\.cn#mirrors.tuna.tsinghua.edu.cn#g' /etc/apt/sources.list.d/*.list 2>/dev/null || true
echo "    已替换不可用域名 cn.mirrors.tuna.tsinghua.edu.cn"

# ------------------------------------------------- 2. 选举可用的镜像加速器
echo "==> [2/4] 探测并选举可用的 Docker 镜像加速器"
CANDIDATES=(
  "https://docker.m.daocloud.io"
  "https://docker.imgdb.de"
  "https://docker.1panel.live"
  "https://hub.rat.dev"
)
MIRRORS=()
for m in "${CANDIDATES[@]}"; do
  code="$(curl -o /dev/null -sS -m 10 -w '%{http_code}' "${m}/v2/" 2>/dev/null || echo 000)"
  if [[ "${code}" =~ ^(200|401|301|302)$ ]]; then
    echo "    [OK]   ${m} (HTTP ${code})"
    MIRRORS+=("${m}")
  else
    echo "    [SKIP] ${m} (HTTP ${code})"
  fi
done

if [[ ${#MIRRORS[@]} -eq 0 ]]; then
  echo "⚠️  无可用加速器，将仅保留本地直连配置"
fi

# ------------------------------------------------- 3. 写入 daemon.json 并重启
echo "==> [3/4] 写入 /etc/docker/daemon.json 并重启 Docker"
mkdir -p /etc/docker
cp -a /etc/docker/daemon.json "/etc/docker/daemon.json.bak.$(date +%Y%m%d%H%M%S)" 2>/dev/null || true

{
  printf '{\n'
  if [[ ${#MIRRORS[@]} -gt 0 ]]; then
    printf '  "registry-mirrors": [\n'
    for i in "${!MIRRORS[@]}"; do
      if [[ $i -eq $(( ${#MIRRORS[@]} - 1 )) ]]; then
        printf '    "%s"\n' "${MIRRORS[$i]}"
      else
        printf '    "%s",\n' "${MIRRORS[$i]}"
      fi
    done
    printf '  ],\n'
  fi
  cat <<'EOF'
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
} >/etc/docker/daemon.json

cat /etc/docker/daemon.json

# 校验 JSON 合法性
python3 -c 'import json,sys; json.load(open("/etc/docker/daemon.json")); print("    JSON 校验通过")'

systemctl daemon-reload
systemctl restart docker
sleep 3

# ------------------------------------------------- 4. 验证
echo "==> [4/4] 验证"
systemctl is-active docker
docker info --format 'ServerVersion={{.ServerVersion}} StorageDriver={{.Driver}} CgroupDriver={{.CgroupDriver}}'
echo "--- 已生效加速器 ---"
docker info --format '{{range .RegistryConfig.Mirrors}}{{println .}}{{end}}' || true

echo "--- APT 源自检 ---"
if apt-get update 2>&1 | grep -q "无法下载\|无法解析"; then
  echo "⚠️  APT 仍有不可达源，请检查 /etc/apt/sources.list"
  apt-get update 2>&1 | grep "无法" || true
else
  echo "✅ APT 源全部可达"
fi

echo "--- 镜像拉取测试（hello-world）---"
if timeout 180 docker run --rm hello-world >/dev/null 2>&1; then
  echo "✅ 镜像拉取正常，Docker 环境就绪"
else
  echo "❌ 拉取仍失败，输出详细日志："
  docker pull hello-world 2>&1 | tail -20 || true
fi
