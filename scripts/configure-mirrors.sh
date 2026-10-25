#!/usr/bin/env bash
#
# Docker 国内镜像加速器自动探测与配置
#   - 探测候选 registry 的可用性（/v2/ 返回 200 或 401 视为可用）
#   - 按响应延迟排序，取前 N 个写入 /etc/docker/daemon.json
#   - 保留已有的 exec-opts / log / live-restore / dns / max-concurrent-downloads 设置
#   - JSON 校验通过后才落盘
#
# 用法：
#   sudo bash configure-mirrors.sh            # 只写入配置，不重启（正在拉取镜像时用这个）
#   sudo bash configure-mirrors.sh --apply   # 写入并重启 docker 立即生效
#
set -euo pipefail

if [[ "$(id -u)" -ne 0 ]]; then
  echo "❌ 请以 root 权限执行：sudo bash $0 [--apply]" >&2
  exit 1
fi

APPLY=0
[[ "${1:-}" == "--apply" ]] && APPLY=1

CANDIDATES=(
  "https://docker.m.daocloud.io"
  "https://docker.1ms.run"
  "https://docker.1panel.live"
  "https://docker.xuanyuan.me"
  "https://docker.nju.edu.cn"
  "https://docker.ckyl.me"
  "https://dockerhub.jobcher.com"
  "https://docker.chenby.cn"
  "https://docker.mirrors.ustc.edu.cn"
  "https://hub-mirror.c.163.com"
  "https://mirror.ccs.tencentyun.com"
  "https://registry.docker-cn.com"
)

echo "==> 探测镜像加速器可用性"
declare -a AVAILABLE=()
declare -A TTFB=()
for m in "${CANDIDATES[@]}"; do
  out="$(curl -o /dev/null -sS -m 8 -w "%{http_code} %{time_starttransfer}" "${m}/v2/" 2>/dev/null || true)"
  code="$(awk '{print $1}' <<<"${out}")"
  ttfb="$(awk '{print $2}' <<<"${out}")"
  [[ -z "${code}" ]] && code=000
  [[ -z "${ttfb}" ]] && ttfb=99
  # imgdb.de 之类已变域名售卖页的站点会返回 200 的 HTML，用 content-type 过滤
  ctype="$(curl -o /dev/null -sS -m 8 -w "%{content_type}" "${m}/v2/" 2>/dev/null || true)"
  if [[ "${code}" =~ ^(200|401)$ ]] && [[ "${ctype}" != text/html* ]]; then
    printf "    [OK]   %-38s HTTP=%s TTFB=%ss\n" "${m}" "${code}" "${ttfb}"
    AVAILABLE+=("${m}")
    TTFB["${m}"]="${ttfb}"
  else
    printf "    [SKIP] %-38s HTTP=%s %s\n" "${m}" "${code}" "${ctype:+type=${ctype}}"
  fi
done

if [[ ${#AVAILABLE[@]} -eq 0 ]]; then
  echo "⚠️  无可用加速器，改为不配置 registry-mirrors（直连）"
fi

# 按 TTFB 排序
SORTED=($(for m in "${AVAILABLE[@]}"; do echo "${TTFB[$m]} $m"; done | sort -n | awk '{print $2}'))
TOP=("${SORTED[@]:0:5}")

echo "==> 最终选用（按延迟排序）"
for m in "${TOP[@]}"; do echo "    ${m}"; done

mkdir -p /etc/docker
cp -a /etc/docker/daemon.json "/etc/docker/daemon.json.bak.$(date +%Y%m%d%H%M%S)" 2>/dev/null || true

python3 - "$(
  IFS=,
  echo "${TOP[*]}"
)" <<'PY'
import json, os, sys

mirrors = [m for m in sys.argv[1].split(",") if m]
path = "/etc/docker/daemon.json"
d = {}
if os.path.exists(path):
    try:
        d = json.load(open(path))
    except Exception:
        d = {}

if mirrors:
    d["registry-mirrors"] = mirrors
else:
    d.pop("registry-mirrors", None)

# 部署基线：保持与 WeKnora 部署一致
d.setdefault("exec-opts", ["native.cgroupdriver=systemd"])
d.setdefault("storage-driver", "overlay2")
d.setdefault("log-driver", "json-file")
d.setdefault("log-opts", {"max-size": "100m", "max-file": "3"})
d.setdefault("live-restore", True)
d.setdefault("dns", ["223.5.5.5", "114.114.114.114"])
d.setdefault("max-concurrent-downloads", 16)

json.dump(d, open(path, "w"), indent=2, ensure_ascii=False)
print(json.dumps(d, indent=2, ensure_ascii=False))
PY

python3 -c 'import json; json.load(open("/etc/docker/daemon.json")); print("==> JSON 校验通过")'

if [[ "${APPLY}" -eq 1 ]]; then
  echo "==> 重启 Docker 使配置生效"
  systemctl restart docker
  sleep 3
  docker info --format 'ServerVersion={{.ServerVersion}} CgroupDriver={{.CgroupDriver}}'
  docker info --format '{{range .RegistryConfig.Mirrors}}{{println .}}{{end}}' || true
else
  echo "==> 配置已写入，未重启（避免中断正在进行的镜像拉取）"
  echo "    使其生效：sudo systemctl restart docker"
fi
