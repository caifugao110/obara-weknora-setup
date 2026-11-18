#!/usr/bin/env bash
#
# 断点续传拉取镜像并导入 docker（弱网 / 镜像站间歇可用时使用）
#
# 背景：
#   docker pull 不支持跨次断点续传，网络一断就整层重下；当镜像含数百 MB 大层、
#   出口又不稳定时，pull 会永远停在"重试 -> 从头下"的循环里。
#   本脚本改为：curl -C - 把各层 blob 落到本地磁盘（断点续传、可跨天接力），
#   全部到齐后构造 docker-archive（manifest.json 格式）并 docker load。
#
# 用法：
#   sudo bash pull-images-resilient.sh wechatopenai/weknora-docreader:v0.8.3
#   sudo bash pull-images-resilient.sh paradedb/paradedb:v0.25.11-pg17
#
# 可选环境变量：
#   REGISTRY_MIRRORS  逗号分隔的镜像站（默认见下方 HOSTS）
#   WORKDIR           中间文件目录（默认 /opt/obara/image-cache）
#   镜像导入成功后自动清理 WORKDIR 中的 blobs 与 tar
#
set -euo pipefail

if [[ "$(id -u)" -ne 0 ]]; then
  echo "❌ 请以 root 运行：sudo bash $0 <repo:tag>" >&2
  exit 1
fi

IMAGE="${1:-}"
if [[ -z "${IMAGE}" ]]; then
  echo "用法：sudo bash $0 <repo:tag>" >&2
  echo "示例：sudo bash $0 wechatopenai/weknora-docreader:v0.8.3" >&2
  exit 1
fi

WORKDIR="${WORKDIR:-/opt/obara/image-cache}"
HOSTS="${REGISTRY_MIRRORS:-docker.367231.xyz,hub.1panel.dev,docker.1panel.live,dockerproxy.cool,docker.1ms.run,docker.m.daocloud.io}"
mkdir -p "${WORKDIR}"

exec python3 -u - "${IMAGE}" "${WORKDIR}" "${HOSTS}" <<'PY'
import hashlib, json, os, shutil, subprocess, sys, time
from concurrent.futures import ThreadPoolExecutor

IMAGE, WORKDIR, HOSTS = sys.argv[1], sys.argv[2], sys.argv[3].split(",")
REPO, _, TAG = IMAGE.rpartition(":")
if not REPO:
    REPO, TAG = IMAGE, "latest"

OCI = os.path.join(WORKDIR, "oci")
BLOBS = os.path.join(OCI, "blobs", "sha256")
OUT = os.path.join(WORKDIR, "archive")
TAR = os.path.join(WORKDIR, "image.tar")
ARCH = "arm64" if os.uname().machine in ("aarch64", "arm64") else "amd64"
IDX_ACCEPT = ",".join([
    "application/vnd.oci.image.index.v1+json",
    "application/vnd.docker.distribution.manifest.list.v2+json",
])
MAN_ACCEPT = ",".join([
    "application/vnd.oci.image.manifest.v1+json",
    "application/vnd.docker.distribution.manifest.v2+json",
])


def log(msg):
    print(time.strftime("%F %T ") + msg, flush=True)


def curl_json(url, accept):
    p = subprocess.run(
        ["curl", "-sS", "--fail", "--connect-timeout", "10", "-m", "25", "-H", "Accept: " + accept, url],
        capture_output=True)
    if p.returncode != 0:
        return None
    try:
        return json.loads(p.stdout)
    except Exception:
        return None


def resolve():
    """返回 (manifest_digest, manifest, host)；manifest list 时按本机架构挑选"""
    for h in HOSTS:
        d = curl_json(f"https://{h}/v2/{REPO}/manifests/{TAG}", IDX_ACCEPT)
        if not d:
            continue
        if "manifests" in d:
            for m in d["manifests"]:
                p = m.get("platform") or {}
                if p.get("architecture") == ARCH and p.get("os") == "linux":
                    md = curl_json(f"https://{h}/v2/{REPO}/manifests/{m['digest']}", MAN_ACCEPT)
                    if md:
                        return m["digest"], md, h
            continue
        if "layers" in d:
            return None, d, h
    return None, None, None


def fetch_blob(digest, size):
    hexd = digest.split(":", 1)[1]
    path = os.path.join(BLOBS, hexd)
    if os.path.exists(path) and os.path.getsize(path) == size:
        return True
    os.makedirs(BLOBS, exist_ok=True)
    while True:
        for h in HOSTS:
            url = f"https://{h}/v2/{REPO}/blobs/{digest}"
            subprocess.call([
                "curl", "-sSL", "--fail", "--connect-timeout", "10", "-m", "900",
                "--speed-limit", "20480", "--speed-time", "25",
                "--retry", "2", "--retry-delay", "3",
                "-C", "-", "-o", path, url,
            ])
            if os.path.exists(path) and os.path.getsize(path) == size:
                log(f"  OK {hexd[:12]} {size/1048576:.1f}MB via {h}")
                return True
            have = os.path.getsize(path) / 1048576 if os.path.exists(path) else 0
            log(f"  续传 {hexd[:12]} {have:.1f}/{size/1048576:.1f}MB via {h} 未完成，换源重试")
        time.sleep(20)


def build_archive(man, cfg_hex, layer_hexes):
    if os.path.exists(OUT):
        shutil.rmtree(OUT)
    os.makedirs(OUT, exist_ok=True)
    shutil.copyfile(os.path.join(BLOBS, cfg_hex), os.path.join(OUT, cfg_hex + ".json"))

    layers = []
    for i, hexd in enumerate(layer_hexes):
        src = os.path.join(BLOBS, hexd)
        d = os.path.join(OUT, hexd)
        os.makedirs(d, exist_ok=True)
        dst = os.path.join(d, "layer.tar")
        with open(src, "rb") as f:
            gz = f.read(2) == b"\x1f\x8b"
        if gz:
            with open(dst, "wb") as o:
                subprocess.check_call(["gzip", "-dc", src], stdout=o)
        else:
            shutil.copyfile(src, dst)
        layers.append(f"{hexd}/layer.tar")
        log(f"  解包 {i+1}/{len(layer_hexes)} {hexd[:12]} -> {os.path.getsize(dst)/1048576:.0f}MB")

    with open(os.path.join(OUT, "manifest.json"), "w") as f:
        json.dump([{"Config": cfg_hex + ".json", "RepoTags": [f"{REPO}:{TAG}"], "Layers": layers}], f)
    return TAR


def main():
    log(f"=== 断点续传拉取 {REPO}:{TAG} ({ARCH}) ===")
    digest, man, host = None, None, None
    while not man:
        digest, man, host = resolve()
        if not man:
            log("manifest 获取失败（网络不可用或镜像站全部不通），30s 后重试")
            time.sleep(30)
    log(f"manifest OK via {host}，层数={len(man['layers'])}")

    cfg = man["config"]
    jobs = [(cfg["digest"], cfg["size"])] + [(l["digest"], l["size"]) for l in man["layers"]]
    total = sum(s for _, s in jobs)
    log(f"blob 数={len(jobs)} 总量={total/1048576:.0f}MB（压缩后）")

    with ThreadPoolExecutor(max_workers=6) as ex:
        ok = list(ex.map(lambda t: fetch_blob(*t), jobs))
    if not all(ok):
        log("部分 blob 未能下载完成，退出")
        sys.exit(1)

    log("全部 blob 就绪，开始构造 docker-archive")
    tar = build_archive(man, cfg["digest"].split(":")[1], [l["digest"].split(":")[1] for l in man["layers"]])
    log(f"tar 完成 {os.path.getsize(tar)/1048576:.0f}MB")

    rc = subprocess.call(["docker", "load", "-i", tar])
    if rc != 0:
        log(f"docker load 失败 rc={rc}，保留 {WORKDIR} 以便排查")
        sys.exit(1)
    log(f"=== 导入成功：{REPO}:{TAG} ===")

    shutil.rmtree(OCI, ignore_errors=True)
    shutil.rmtree(OUT, ignore_errors=True)
    os.remove(tar)
    log("中间文件已清理")


main()
PY
