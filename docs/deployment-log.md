# OBARA 知识库系统 — 部署执行记录

> 本文记录**阶段一（Docker 环境）**与**阶段二（WeKnora 部署）**的实际执行过程、遇到的问题与验证结果。
> 顶层方案见 [README](../README.md)；本文只记录"实际怎么做的、踩了什么坑"，便于复现与交接。
>
> 最后更新：2026-10-25

---

## 0. 主机环境基线

| 项 | 实测值 |
| --- | --- |
| 主机名 / IP | `obara-weknora` / `192.168.227.133`（VMware NAT） |
| 操作系统 | Ubuntu 20.04.6 LTS（focal，内核 5.15.0-139） |
| 架构 | x86_64 |
| vCPU / 内存 / 磁盘 | 8 核 / 8 GB / 118 GB（根分区，剩余约 78 GB） |
| Docker Engine | 28.1.1（build 4eba377） |
| Docker Compose | v2.35.1（V2 插件） |
| containerd | 1.7.27 |
| 存储驱动 / Cgroup | overlay2 / systemd |
| APT 源 | 清华 `mirrors.tuna.tsinghua.edu.cn` |
| SSH | 已安装并启用 `openssh-server`（22 端口），供文件传输使用 |

---

## 一、阶段一：Docker 环境安装

### 1.1 安装结果

| 组件 | 版本 |
| --- | --- |
| docker-ce | 5:28.1.1-1~ubuntu.20.04~focal |
| docker-ce-cli | 5:28.1.1 |
| containerd.io | 1.7.27 |
| docker-buildx-plugin | 0.23.0 |
| docker-compose-plugin | 2.35.1 |

- 开机自启：`docker.service`、`containerd.service` 均 `enabled`
- 普通用户 `tobin` 已加入 `docker` 组，免 sudo 使用 docker
- 验证：`docker run --rm hello-world` 拉取并运行成功

交付脚本（可重复执行、幂等）：

| 脚本 | 用途 |
| --- | --- |
| `scripts/install-docker.sh` | 首次安装：依赖 → GPG 公钥 → 清华 docker-ce 源 → 安装 → daemon 配置 → 加组 → 验证 |
| `scripts/fix-docker-env.sh` | 修复：APT 源域名、daemon.json 未生效、加速器重选 |
| `scripts/configure-mirrors.sh` | 镜像加速器自动探测与配置（默认只写配置，`--apply` 重启生效） |

### 1.2 `/etc/docker/daemon.json` 最终配置

```json
{
  "registry-mirrors": [
    "https://docker.m.daocloud.io",
    "https://docker.1ms.run",
    "https://docker.xuanyuan.me",
    "https://docker.1panel.live"
  ],
  "exec-opts": ["native.cgroupdriver=systemd"],
  "storage-driver": "overlay2",
  "log-driver": "json-file",
  "log-opts": { "max-size": "100m", "max-file": "3" },
  "live-restore": true,
  "dns": ["223.5.5.5", "114.114.114.114"],
  "max-concurrent-downloads": 16
}
```

设计说明：
- **多个 registry-mirrors**：按顺序降级，任意一个可用即可拉取
- **`live-restore: true`**：重启 dockerd 时不停止已运行容器（后续重启 daemon 应用配置时服务未中断）
- **`max-concurrent-downloads: 16`**：默认 3，实测单连接被限速约 200KB/s，提到 16 后总吞吐约 2.5MB/s
- 日志滚动 100MB × 3，避免容器日志撑爆磁盘

### 1.3 踩坑记录

| # | 现象 | 根因 | 解决 |
| --- | --- | --- | --- |
| 1 | apt update 报 `无法解析域名 cn.mirrors.tuna.tsinghua.edu.cn` | `sources.list` 中 focal / updates / backports 使用了带 `cn.` 前缀的域名，本机 DNS 解析不了 | 全量替换为 `mirrors.tuna.tsinghua.edu.cn`（脚本已处理，含备份） |
| 2 | `docker info` 显示 `CgroupDriver=cgroupfs`，加速器列表为空 | dpkg 安装过程中 docker 已被自动拉起，`systemctl enable --now` 对**已运行**的服务不会重启，导致 `daemon.json` 完全没被加载 | 写入配置后显式 `systemctl restart docker` |
| 3 | hello-world 拉取失败 | 问题 2 导致加速器未生效；且本机 Docker Hub 直连全断（`registry-1.docker.io`、`auth.docker.io` 均不可达） | 必须配置 registry-mirror，不能依赖直连 |
| 4 | 部分老牌镜像站不可用 | 163、腾讯云、中科大、docker-cn 等已停止服务；`docker.imgdb.de` 已变成域名售卖页（仍返回 200 的 HTML） | 脚本按 `/v2/` 返回码**且** content-type 非 HTML 双重判定，过滤假阳性 |
| 5 | 拉取过程中断后进度回退 | docker pull 被 kill 时，未完成/未提交的层会被清理 | 拉取期间不要随意 kill pull 进程；确实要中断时用 `docker compose pull` 重新跑，已入库层会保留 |

---

## 二、阶段二：WeKnora v0.8.3 部署

### 2.1 部署位置与版本

| 项 | 值 |
| --- | --- |
| 源码目录 | `/opt/obara/weknora` |
| 版本 | `v0.8.3`（Tag 锁定，commit `3e22822`） |
| 配置文件 | `/opt/obara/weknora/.env`（权限 600，不入 Git） |
| 应用配置 | `./config/config.yaml` 只读挂载进 app 容器 |

### 2.2 镜像清单（全部已本地化）

| 镜像 | Tag | 大小 | 说明 |
| --- | --- | --- | --- |
| `wechatopenai/weknora-app` | v0.8.3 | 1.7 GB | Go 后端 |
| `wechatopenai/weknora-docreader` | v0.8.3 | 3.91 GB | 文档解析（gRPC 50051，仅容器内可达） |
| `paradedb/paradedb` | v0.25.11-pg17 | 975 MB | PostgreSQL 17 + BM25 全文检索 |
| `wechatopenai/weknora-ui` | v0.8.3 | 83.4 MB | 前端（nginx） |
| `redis` | 7.0-alpine | 32.9 MB | 流处理 / Asynq 队列 |

`docker-compose.yml` 中每个服务同时写了 `image:` 和 `build:`；本地已存在对应 tag 镜像时，Compose 直接使用本地镜像、不触发源码构建，因此无需在本机准备 Go/Node 工具链。

### 2.3 启用的服务（默认 profile）

`docreader`、`postgres`、`redis`、`app`、`frontend` —— 共 5 个。

其余为可选 profile（`searxng` / `minio` / `neo4j` / `qdrant` / `milvus` / `weaviate` / `doris` / `sandbox` 等），本次未启用；知识库向量检索走 PostgreSQL（ParadeDB 自带向量能力），无需额外向量库。

### 2.4 `.env` 关键配置

| 变量 | 值 | 说明 |
| --- | --- | --- |
| `WEKNORA_VERSION` | `v0.8.3` | 固定版本，不使用 latest |
| `FRONTEND_PORT` | `80` | 对外访问端口 |
| `APP_PORT` | `8080` | 后端 API（容器网络内由 nginx 反代） |
| `DB_DRIVER` / `DB_HOST` | `postgres` / `postgres` | 数据库 |
| `DB_PASSWORD` | 随机 | 生成后未记录在文档中 |
| `REDIS_PASSWORD` | 随机 | 同上 |
| `JWT_SECRET` / `SYSTEM_AES_KEY` / `SYSTEM_SIGNING_KEY` | 随机 | 同上 |
| `STORAGE_TYPE` | `local` | 文件存储本地卷 `data-files` |
| `MAX_FILE_SIZE_MB` | `100` | 放宽上传上限（默认 50） |
| `DISABLE_REGISTRATION` | `false` | 一期试点允许注册 |

> ⚠️ **必须备份 `.env`**：`SYSTEM_AES_KEY` 丢失将导致库内已加密的模型 API Key 等字段永久无法解密。

### 2.5 启动与验证

```bash
cd /opt/obara/weknora
sudo docker compose up -d
sudo docker compose ps
```

| 容器 | 状态 | 端口 |
| --- | --- | --- |
| WeKnora-app | Up (healthy) | `0.0.0.0:8080->8080` |
| WeKnora-frontend | Up | `0.0.0.0:80->80` |
| WeKnora-docreader | Up (healthy) | 50051（仅容器网络） |
| WeKnora-postgres | Up (healthy) | 5432（仅容器网络） |
| WeKnora-redis | Up | 6379（仅容器网络） |

验证结果：

```
$ curl -I http://localhost/            → HTTP 200
$ curl    http://localhost:8080/health  → {"status":"ok"}   HTTP 200
```

访问地址（内网）：`http://192.168.227.133`

### 2.6 踩坑记录

| # | 现象 | 根因 | 解决 |
| --- | --- | --- | --- |
| 1 | `git clone` 极慢（~50KB/s）且报 `GnuTLS recv error (-54)` 断流 | GitHub 直连带宽受限且连接不稳定 | 后台循环重试浅克隆，最终成功；后续升级建议走 GitHub 代理或先在有高速网的环境打包 |
| 2 | 开启 VPN（verge-mihomo，监听 `127.0.0.1:7897`）后下载速度反降 10 倍 | TUN/全局模式把本应走国内骨干的加速器流量绕到境外节点（出口落在巴西），延迟没坏但吞吐崩了 | **拉取镜像时关闭 VPN 或切规则模式**；Docker Hub 经该代理实测仅 ~7KB/s，不如国内加速器 |
| 3 | 大层（776MB）单连接限速约 200KB/s，估算要 1 小时 | 加速器单流限速，与总带宽无关 | `max-concurrent-downloads: 16` 提高并发，多流叠加后总吞吐约 2.5MB/s |
| 4 | 解压阶段长时间无进度，swap 被占用 | 可用内存不足导致换页抖动 | `sync && echo 3 > /proc/sys/vm/drop_caches` 释放页缓存；并避免同时跑多个 pull |
| 5 | 镜像 tag 不一致时 Compose 仍会联网拉取 | Windows 上已有的镜像是 v0.8.2 / paradedb v0.22.6，与部署要求不符 | 跨机迁移前必须核对**版本与 tag 完全一致**，并用 `docker image inspect --format '{{.Os}}/{{.Architecture}}'` 确认 `linux/amd64` |

### 2.7 跨机迁移镜像（备用方案）

宿主机网络受限时，可在有高速网络的机器拉取后离线导入：

```powershell
# Windows（Docker Desktop）
docker pull --platform=linux/amd64 <image>:<tag>
docker image inspect <image>:<tag> --format "{{.Os}}/{{.Architecture}}"   # 必须 linux/amd64
docker save -o <name>.tar <image>:<tag>
```

```bash
# 目标机
docker load -i <name>.tar
docker image inspect <image>:<tag> --format '{{.Os}}/{{.Architecture}} {{.Id}}'
```

注意：U 盘需 NTFS/exFAT（`app` 1.7GB、`docreader` 约 4GB，FAT32 单文件上限 4GB）；镜像格式与文件系统无关，关键是架构一致。

---

## 三、运维手册

```bash
cd /opt/obara/weknora

# 状态 / 日志
sudo docker compose ps
sudo docker compose logs -f app
sudo docker compose logs -f docreader

# 重启单个服务（改 .env 后需重建才生效）
sudo docker compose restart app
sudo docker compose up -d --force-recreate app

# 停止 / 启动整套
sudo docker compose down      # 数据卷保留
sudo docker compose up -d

# 升级（确认新版本后）
sudo docker compose pull && sudo docker compose up -d
```

**需要纳入备份的内容**：
- `/opt/obara/weknora/.env`（含 `SYSTEM_AES_KEY`，丢失不可恢复）
- 数据卷 `postgres-data`（数据库）、`data-files`（上传文件）、`docreader-tmp`
- `config/config.yaml` 及 `config/builtin_models.yaml`（如启用）

```bash
# 卷备份示例
sudo docker run --rm -v postgres-data:/data -v $PWD:/backup busybox tar czf /backup/postgres-data.tar.gz -C /data .
```

---

## 四、安全相关（试点结束后回收）

- `/etc/sudoers.d/tobin-nopasswd`：部署期为便于自动化运维配置的免密 sudo（`NOPASSWD: ALL`），**试点结束后执行 `sudo rm /etc/sudoers.d/tobin-nopasswd` 回收**；所有 sudo 调用仍记录在 `/var/log/auth.log`
- SSH（22 端口）为文件传输临时开启，如信息课有端口管控要求，用完后可关闭
- `.env` 中的密钥不进 Git、不写文档

---

## 五、后续阶段

| 阶段 | 内容 | 状态 |
| --- | --- | --- |
| 阶段三 | 部署 Ollama，拉取候选向量模型 `bge-m3` 与 `embeddinggemma:300m`，导库前完成 A/B 定夺（换 Embedding 需全量重向量化） | ⏸️ 待开始 |
| 阶段四 | 管理后台配置 DeepSeek（`api.deepseek.com`，快速问答 `deepseek-flash` / 智能推理 `deepseek-v4-pro`），Embedding 指向本机 Ollama | ⏸️ 待开始 |
| 阶段五 | 部署本地 Rerank 服务容器（如 `Qwen3-Reranker-0.6B`），端口预留 `7997`，禁用公有 rerank API | ⏸️ 待开始 |
| 阶段六 | 创建知识库、导入试点文档、验证解析与 RAG 溯源问答（含跨语种验收） | ⏸️ 待开始 |

各阶段详细方案与验收清单见 [README §4 部署步骤](../README.md#4-部署步骤)。
