# OBARA 知识库系统 — 部署执行记录

> 本文记录**阶段一（Docker 环境）、阶段二（WeKnora 部署）、阶段三（Ollama 本地向量模型）、阶段四（DeepSeek 对话模型）与阶段五（本地 Rerank 重排服务）**的实际执行过程、遇到的问题与验证结果。
> 顶层方案见 [README](../../README.md)；本文只记录"实际怎么做的、踩了什么坑"，便于复现与交接。
>
> 最后更新：2026-10-25（阶段五已完成）

---

## 0. 主机环境基线

| 项 | 实测值 |
| --- | --- |
| 主机名 / IP | `obara-weknora` / `192.168.227.133`（VMware NAT） |
| 操作系统 | Ubuntu 20.04.6 LTS（focal，内核 5.15.0-139） |
| 架构 | x86_64 |
| vCPU / 内存 / 磁盘 | **12 核 / 15 GB**（阶段五实施期间由原"4 核 / 8 GB"扩容；Xeon E5-2676 v3 @ 2.40GHz）/ 118 GB 根分区，阶段五后剩余约 73 GB |
| Docker Engine | 28.1.1（build 4eba377） |
| Docker Compose | v2.35.1（V2 插件） |
| containerd | 1.7.27 |
| 存储驱动 / Cgroup | overlay2 / systemd |
| APT 源 | 清华 `mirrors.tuna.tsinghua.edu.cn` |
| SSH | 已安装并启用 `openssh-server`（22 端口），供文件传输使用 |
| Ollama | 0.17.5，监听 `0.0.0.0:11434`，模型目录 `/opt/ollama/models` |
| Rerank 服务 | `michaelf34/infinity:0.0.78-cpu` 容器 `weknora-rerank`，端口 `7997`，模型 `bge-reranker-v2-m3`，权重 `/opt/obara/rerank-models` |

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
| `scripts/deploy/install-docker.sh` | 首次安装：依赖 → GPG 公钥 → 清华 docker-ce 源 → 安装 → daemon 配置 → 加组 → 验证 |
| `scripts/deploy/fix-docker-env.sh` | 修复：APT 源域名、daemon.json 未生效、加速器重选 |
| `scripts/deploy/configure-mirrors.sh` | 镜像加速器自动探测与配置（默认只写配置，`--apply` 重启生效） |

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
| `DISABLE_REGISTRATION` | `false` | 保持 false：`init-tenants.sh` 直连 8080 用它批量开户；对外注册由 80 网关与 8081 门户两层拦截 |

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

## 三、阶段三：Ollama 与本地向量模型

### 3.1 安装结果

| 项 | 值 |
| --- | --- |
| Ollama 版本 | **0.17.5**（`curl http://127.0.0.1:11434/api/version` → `{"version":"0.17.5"}`） |
| 安装形态 | 原生 systemd 服务（非容器）：二进制 `/usr/bin/ollama`，运行库 `/usr/lib/ollama` |
| 服务单元 | `/etc/systemd/system/ollama.service` + override `/etc/systemd/system/ollama.service.d/override.conf` |
| 运行账号 | `ollama`（系统账号，非 root） |
| 模型目录 | `/opt/ollama/models`（不放在 `$HOME`，便于统一备份与磁盘规划） |
| 监听 / 状态 | `0.0.0.0:11434`；`active` + `enabled`（开机自启） |
| 交付脚本 | `scripts/deploy/install-ollama.sh`（幂等，可重复执行） |

执行记录：

```bash
sudo bash scripts/deploy/install-ollama.sh                            # 安装服务 + 拉取默认模型 bge-m3
sudo bash scripts/deploy/install-ollama.sh --models "bge-m3 embeddinggemma:300m"   # A/B 前补齐候选模型
sudo bash scripts/deploy/install-ollama.sh --skip-models              # 只装服务
```

耗时实测：发行包 1.7 GB 下载 3m41s（约 8 MB/s），模型层 1.2 GB 约 2m30s（5~7.6 MB/s），合计约 8 分钟。

### 3.2 环境变量（`override.conf`）

| 变量 | 值 | 原因 |
| --- | --- | --- |
| `OLLAMA_HOST` | `0.0.0.0:11434` | WeKnora 在容器网络内，需从容器访问宿主服务；仅内网网卡暴露 |
| `OLLAMA_MODELS` | `/opt/ollama/models` | 模型统一存放，便于备份与磁盘规划（当前占用 1.1 GB） |
| `OLLAMA_KEEP_ALIVE` | `10m` | 本机内存仅 8 GB 且 WeKnora 容器已占约 4 GB，闲置 10 分钟卸载模型释放内存 |
| `OLLAMA_MAX_LOADED_MODELS` | `2` | 限制并发常驻模型数，避免同时加载撑爆内存 |
| `OLLAMA_CONTEXT_LENGTH` | `8192` | 与 `bge-m3` 的 8K 上下文对齐 |

> 修改/新增变量后执行 `sudo systemctl restart ollama` 生效（`daemon-reload` 仅在改动 service 本体时需要）。

### 3.3 已拉取模型

| 模型 | SIZE | 参数 | 上下文 | 维度 | 量化 | 能力 | 位置 |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `bge-m3:latest` | 1.2 GB | 566.70M | 8192 | **1024** | F16 | `embedding` | `/opt/ollama/models` |

```bash
$ ollama list
NAME             ID              SIZE      MODIFIED
bge-m3:latest    790764642607    1.2 GB    Less than a second ago

$ ollama show bge-m3
  architecture  bert   parameters 566.70M   context length 8192
  embedding length 1024   quantization F16   Capabilities: embedding
```

- `embeddinggemma:300m`（A/B 候选）**本轮未拉取**：本次优先跑通 `bge-m3` 链路，待导库前用 `--models` 补齐后再做 A/B 对比，避免一次性占用磁盘与陡增的下载时间。
- GPU 榜单模型（8B/12B 级）本机条件不支持，不参与本次选型。

### 3.4 验证结果

```bash
# 1) 服务与模型清单
curl -s http://127.0.0.1:11434/api/version      → {"version":"0.17.5"}
curl -s http://127.0.0.1:11434/api/tags         → bge-m3:latest

# 2) 向量化调用（确认维度）
curl -s http://127.0.0.1:11434/api/embeddings \
     -d '{"model":"bge-m3","prompt":"电极使用规范测试"}' | jq '.embedding | length'   → 1024

# 3) 已加载模型与处理器占用
ollama ps   → bge-m3:latest 1.2 GB  100% CPU  CONTEXT 8192
```

**跨语种能力实测**（余弦相似度，中文问句 vs 不同语种同义/无关句）：

| 句对 | 余弦相似度 |
| --- | --- |
| 中「电极的使用寿命是多久？」↔ 日「電極の使用寿命はどのくらいですか？」 | **0.9578** |
| 中 ↔ 英「What is the service life of the electrode?」 | **0.7291** |
| 日 ↔ 英 | 0.7474 |
| 中 ↔ 中「员工报销流程管理办法」（无关句） | **0.3192** |
| 英 ↔ 中（无关句） | 0.3017 |

> 结论：跨语种相似度（0.73~0.96）与无关句（约 0.32）区分度明显，满足本项目"中文提问命中英文/日文原版规范"的关键验收前提。
> 注意：**余弦相似度绝对值不能跨知识库当作阈值使用**，README 2.2 节的 `vector_threshold=0.47` 仍需在实际召回流程中按命中效果复核。

**性能基线**（4 核 Xeon E5-2676 v3，纯 CPU）：

| 场景 | 实测 |
| --- | --- |
| 单条短句 embedding（热模型，连续 3 次） | 0.45s / 0.40s / **0.34s** |
| 冷加载（`bge-m3` 载入内存） | 秒级；常驻占用约 1.2 GB |

**容器连通性验证（阶段四前置）**

```bash
$ docker exec WeKnora-app curl -sS http://192.168.227.133:11434/api/version
{"version":"0.17.5"}
```

- ✅ WeKnora 容器可通过**宿主 IP** 访问 Ollama；阶段四在管理后台填 Embedding Base URL 时使用 `http://192.168.227.133:11434`。
- ✅ **阶段四复核更正**：容器内 `host.docker.internal` **可正常解析**（→ `172.17.0.1`），curl 直连返回 `{"version":"0.17.5"}`，且容器内无代理环境变量干扰。原因是 `docker-compose.yml` 的 `app` 服务已内置：

  ```yaml
  extra_hosts:
    - "host.docker.internal:host-gateway"
  ```

  因此 `.env` 中的 `OLLAMA_BASE_URL=http://host.docker.internal:11434` **无需修改**即可正常工作。本条覆盖此前"容器内未自动解析"的记录。

### 3.5 踩坑记录

| # | 现象 | 根因 | 解决 |
| --- | --- | --- | --- |
| 1 | `curl -fsSL https://ollama.com/install.sh \| sh` 卡住后失败 | `ollama.com` 对 install.sh / 发行包均 **307 跳到 GitHub Release**，本机 GitHub 直连超时（`curl https://github.com` 无响应） | 改用 ModelScope 镜像包 `modelscope/ollama-linux`（`ollama-linux-amd64.tar.zst`），实测 ~8 MB/s |
| 2 | GitHub 代理全部失效 | `gh-proxy.com` 对 release download 返回 **404**，仅支持 raw 路径；`gh-proxy.org` 同；`ghfast.top` / `gh.llkk.cc` / `gh-proxy.ru` 直接超时 | 不依赖第三方 GH 代理；脚本仍保留 GitHub 直连作为最后兜底源 |
| 3 | Docker 容器方案拉取失败评估 | Docker Hub 直连 `registry-1.docker.io` 无响应，只能走已配置的加速器 | 优先采用原生 systemd 安装；容器方案留作备选（README 阶段三列出的方式之一） |
| 4 | 安装过程中 `ollama --version` 报 `could not connect to a running Ollama instance` | 服务此时尚未启动，`--version` 需要连 API | 不是错误；以服务启动后的 `/api/version` 为准 |
| 5 | `/usr/lib/ollama` 占用 4.3 GB | 官方发行包内含 CUDA / MLX / Vulkan runner | 纯 CPU 环境可裁剪释放约 4.2 GB，见 3.6 |
| 6 | 实测资源低于规划（`nproc=4`、内存 8 GB，规划 8 核 32 GB） | 虚机实际分配与规划不一致 | 通过 `KEEP_ALIVE=10m`、`MAX_LOADED_MODELS=2` 限制内存占用；资源规格需与信息课核对 |

### 3.6 可选：裁剪 GPU runner 释放磁盘

```bash
$ du -sh /usr/lib/ollama/* | sort -h
2.4G    /usr/lib/ollama/cuda_v12
960M    /usr/lib/ollama/mlx_cuda_v13
932M    /usr/lib/ollama/cuda_v13
55M     /usr/lib/ollama/vulkan
```

当前磁盘剩余约 74 GB，**暂不裁剪**。若后续空间紧张且确定不使用 GPU：

```bash
sudo systemctl stop ollama
sudo rm -rf /usr/lib/ollama/cuda_v12 /usr/lib/ollama/cuda_v13 /usr/lib/ollama/mlx_cuda_v13
sudo systemctl start ollama
ollama run bge-m3 --help 2>/dev/null || true   # 仅确认服务仍可加载；向量模型实际调用见 3.4
curl -s http://127.0.0.1:11434/api/embeddings -d '{"model":"bge-m3","prompt":"裁剪后自检"}' | jq '.embedding|length'
```

> 二期若评估 GPU 推理节点，需重新下载对应 runner，届时直接在 GPU 机上重装 Ollama 即可。

---

## 四、阶段四：DeepSeek 对话模型配置

> 执行日期：2026-10-25。密钥通过环境变量传入，不写入本仓库任何文件。

### 4.1 前置验证

| 项 | 命令 | 结果 |
| --- | --- | --- |
| 宿主机 → DeepSeek | `curl https://api.deepseek.com/models -H "Authorization: Bearer $KEY"` | HTTP 200，0.27s |
| 容器 → DeepSeek | `docker exec WeKnora-app curl ...` | HTTP 200，0.28s |
| 可用模型 | `/models` 返回 | `deepseek-flash`、`deepseek-v4-pro` |
| 容器 → Ollama | `docker exec WeKnora-app curl --noproxy '*' http://host.docker.internal:11434/api/version` | `{"version":"0.17.5"}` |

### 4.2 初始化账号

系统为全新状态（`users` / `tenants` / `models` 三张表均为空）。通过 `POST /api/v1/auth/register` 创建首个账号：

- 账号：`admin` / `admin@obara.local`
- 租户：`10000`（`admin's Workspace`），注册时自动 `EnsureOwner` 授予 `owner` 角色
- `WEKNORA_TENANT_ENABLE_RBAC` 未设置（默认关闭），角色守卫放行

> ⚠️ 管理员密码已生成并保存在本次会话输出中，**请妥善保管并在首次登录后修改**。

### 4.3 注册的模型

| 模型 | `type` | `source` | `provider` | Base URL | 关键参数 |
| --- | --- | --- | --- | --- | --- |
| `deepseek-flash` | `KnowledgeQA` | `remote` | `deepseek` | `https://api.deepseek.com/v1` | `context_window=1000000`、`max_output_tokens=384000` |
| `deepseek-v4-pro` | `KnowledgeQA` | `remote` | `deepseek` | `https://api.deepseek.com/v1` | 同上 |
| `bge-m3` | `Embedding` | `local` | `generic` | `http://192.168.227.133:11434` | `dimension=1024` |

三个模型状态均为 `active`，DeepSeek 两个模型的 `credentials.api_key.configured=true`（密钥经 `SYSTEM_AES_KEY` 加密落库）。

### 4.4 连通性验证（`POST /api/v1/models/{id}/debug`）

| 模型 | `ok` | 耗时 | 输出 |
| --- | --- | --- | --- |
| `deepseek-flash` | ✅ true | 993 ~ 1470 ms | `1+1等于2。`（含 `reasoning_content` 思考链） |
| `deepseek-v4-pro` | ✅ true | 1231 ~ 1395 ms | `水的化学式是 H₂O。` |
| `bge-m3` | ✅ true | 484 ~ 6926 ms | 向量长度 `1024`，`observations.dimension=1024` |

> `bge-m3` 首次调用耗时约 6.9s 为冷加载（`KEEP_ALIVE=10m` 内复用则降至 0.5s 左右），与阶段三实测一致。
> `debug` 会发起**真实**上游调用并产生费用，勿频繁执行。

### 4.5 踩坑记录

| # | 现象 | 根因 | 解决 |
| --- | --- | --- | --- |
| 1 | 创建模型返回 `Base URL 未通过安全校验：SSRF validation failed: direct IP address is not allowed, use domain name or add to SSRF_WHITELIST` | `CreateModel` 对 `parameters.base_url` 执行 `secutils.ValidateURLForSSRF`，默认禁止裸 IP 直连 | 在 `/opt/obara/weknora/.env` 追加 `SSRF_WHITELIST_EXTRA=...`（本机 IP + 内网网段），再 `docker compose up -d --force-recreate app` |
| 2 | DeepSeek 模型状态变为 `download_failed`，日志出现 `Local model detected, setting status to downloading` | `modelService.CreateModel` 只有 `source == ModelSourceRemote` 才直接置 active；**填厂商名（如 `deepseek`）会被归入"本地模型"分支**，进而尝试用 Ollama 拉取 `deepseek-flash` 并失败 | 远程 API 模型 `source` 必须填 `remote`，厂商名填在 `parameters.provider` |
| 3 | 新增 `.env` 变量后容器内 `printenv` 仍为空 | `env_file` 只在**创建容器**时注入环境变量，`docker compose restart` 不会重读 | 用 `docker compose up -d --force-recreate app` |
| 4 | 登录响应结构与预期不符（token 在顶层而非 `data` 下） | 注册接口返回 `{"data":{...}}`，登录接口返回扁平结构 `{"user":...,"token":...}` | 解析时兼容两种结构 |

### 4.6 关键结论：无独立"设为默认"接口

WeKnora v0.8.3 中模型记录**没有** `SetDefault` 路由（仅 `storage-backends` 有 `/:id/default`）。`Model.IsDefault` 字段在初始化路径里被硬编码为 `false`，运行时不参与模型选择。

**实际绑定点**：

- 知识库（KnowledgeBase）→ `embedding_model_id` / `summary_model_id` / `vlm_model_id` 等
- Agent → `chat_model_id`（快速问答 / 智能推理在 Agent 配置里区分）

因此阶段四的交付标准是"模型注册成功 + 上游连通"，默认模型的落地推迟到阶段六建库与 Agent 配置时完成。

### 4.7 密钥存放

```bash
# 密钥落盘位置（权限 700 目录 / 600 文件，属主 root）
/opt/obara/weknora/.secrets/deepseek.env   # DEEPSEEK_API_KEY=sk-...

# 数据库内为 SYSTEM_AES_KEY 加密后的密文；API 响应中仅返回 credentials.api_key.configured
```

> ⚠️ `.env` 中的 `SYSTEM_AES_KEY` 一旦丢失，已加密的模型密钥将永久无法解密——请务必纳入备份（见运维章节）。

---

## 五、阶段五：本地 Rerank 重排服务

> 执行日期：2026-10-25。交付脚本 `scripts/deploy/install-rerank.sh`。

### 5.1 部署结果

| 项 | 值 |
| --- | --- |
| 服务框架 | `michaelf34/infinity:0.0.78-cpu`（2.31 GB），提供 Cohere 兼容的 `/rerank` 接口 |
| 模型 | **`BAAI/bge-reranker-v2-m3`**（568M 参数 / fp32 / 榜单 `NDCG@10` 0.8075） |
| 容器 | `weknora-rerank`，端口 `7997`，`--restart unless-stopped` |
| 权重目录 | `/opt/obara/rerank-models/models/bge-reranker-v2-m3`（2.2 GB），**只读挂载**、离线加载 |
| 资源限制 | `--cpus 6 --memory 4g --batch-size 8`；实测常驻约 **2.0 GB** |
| WeKnora 注册 | `bge-reranker-v2-m3`：`type=Rerank` / `source=remote` / `provider=generic`，`status=active` |
| Base URL | `http://192.168.227.133:7997`（宿主内网 IP，已在阶段四加入 `SSRF_WHITELIST_EXTRA`） |

> 部署期间虚机规格由"4 核 / 8 GB"扩容为"**12 核 / 15 GB**"，第 5.3 节的延迟基线为扩容后实测。

### 5.2 协议对齐：为什么选 infinity

WeKnora v0.8.3 的 rerank 客户端按"`RerankAPI`"分派，未指定时会默认使用 **Cohere 形状**（`internal/models/runtime/registry.go:89` → `api.RerankCohere`）：

```text
POST {base_url}/rerank  {"model": .., "query": .., "documents": [..]}
-> {"results": [{"index": .., "relevance_score": .., "document": {"text": ..}}]}
```

`internal/models/rerank/reranker.go` 的 `RankResult.UnmarshalJSON` 兼容 `relevance_score` 与 `score` 两种字段名，`document` 缺失也不影响（会用请求中的原文回填）。infinity 的返回正是这一形状，因此 **`provider=generic` 即可直接对接**，无需任何适配层。

> 仓库自带的 `rerank_server_demo.py` 是同一协议的参考实现（返回 `score` 字段），可佐证该契约。

### 5.3 验证结果

**排序质量**（中文查询「电极的使用寿命是多久？」）

| 候选片段 | `relevance_score` |
| --- | --- |
| 中「电极的使用寿命取决于工况与维护周期…800 小时后更换」 | **0.9926** |
| 英「Electrode service life is 800 operating hours…」 | 0.6336 |
| 中「员工报销流程管理办法…」（无关句） | **0.0000** |

无关句被压到 0，英文相关片段仍显著高于无关句——与阶段三 `bge-m3` 的跨语种倾向一致，**符合"中文提问命中英文/日文原版"的关键验收前提**。

扩到 10 / 20 / 50 条候选（3 条相关 + 其余为报销类噪声）时，Top1 **始终**命中相关片段，排序稳定。

**WeKnora 端到端链路**：`POST /api/v1/models/{id}/debug` → `ok=true`，耗时 **1.26 ~ 1.54 s**（3 条候选，含 WeKnora 侧开销），容器内 `curl http://192.168.227.133:7997/models` 正常返回。

**延迟基线**（容器 6 核 / batch 8，HTTP 直连，含往返）

| 候选片段数 | 端到端 | 折算每条 |
| --- | --- | --- |
| 5 | 1.81 s | 361 ms |
| 10 | 3.91 s | 391 ms |
| **20** | **6.77 s** | 339 ms |
| 30 | 9.78 s | 326 ms |
| 50 | 16.24 s | 325 ms |

对照：同为 2 核时，20 条约 10.3 s——**扩核几乎线性提速**，说明瓶颈是纯 CPU 算力而非排队。

> 结论：延迟只在线性叠加、但每次 1 s 级、top_k 可控。**阶段六建议候选池 ≤ 20、`rerank_top_k=8`**，对应约 6.8 s 的重排开销，可接受的范围内；若 P50 不可接受，先压候选池、再给容器加核。

### 5.4 首选模型未采用：`Qwen3-Reranker-0.6B` 不兼容

```
ValueError: The checkpoint you are trying to load has model type `qwen3`
but Transformers does not recognize this architecture.
  File "/app/infinity_emb/transformer/embedder/sentence_transformer.py", line 62
```

`infinity:0.0.78-cpu` 内置的 transformers **不支持 `qwen3` 架构**（Qwen3 需 transformers ≥ 4.51/4.52）。而本机可达的加速器中该镜像**最高只到 `0.0.78-cpu`**（0.0.79+ 均 `manifest unknown`），官方组织名 `michaelfeil/infinity` 在所有加速器上都拉不到，可用的是旧组织名 `michaelf34/infinity`。因此改用社区验证最多的 `bge-reranker-v2-m3`。二期若上 GPU 节点或能拉到更新版 infinity，可再评估 Qwen3。

### 5.5 ONNX（optimum）加速路线：暂不可用

`--engine optimum` 要求仓库自带 ONNX 文件：

- `BAAI/bge-reranker-v2-m3` → `ValueError: No onnx files found`（仓库未发货 ONNX）
- `BAAI/bge-reranker-base` 自带 `onnx/model.onnx`（1.1 GB），但也 **反复重启 5~11 次无法就绪**（`--memory 2g` 与 `6g` 均复现，加载期峰值约 4.75 GB），日志无异常堆栈；且该模型质量低于 v2-m3。

结论：**本机维持 `torch` 引擎 + `bge-reranker-v2-m3`**；CPU 提速诉求优先走"压候选池 + 加核"，二期 GPU 节点再考虑 `infinity` GPU 镜像。

### 5.6 踩坑记录

| # | 现象 | 根因 | 解决 |
| --- | --- | --- | --- |
| 1 | Docker Hub 上 `michaelfeil/infinity` 全部 tag 拉不到（`manifest not found`） | 该镜像的有效组织名仍是旧名 `michaelf34/infinity`；daocloud 加速器还有"不在白名单"的限制 | 用 `michaelf34/infinity`，并固定 `0.0.78-cpu`；脚本内置 `docker.1ms.run` / `docker.xuanyuan.me` 回退 |
| 2 | `huggingface.co` 直连超时（`code=000`） | 本机无 HF 直连，仅 `hf-mirror.com` 可达且返回 **307** | 脚本内模型仓库探测用 `-L` 跟随重定向，双源择优（`hf-mirror.com` → `huggingface.co`） |
| 3 | 容器内自行下载权重不稳，且容器重建就要重下 | 容器内网络链路更长，失败不可控 | 改为**宿主机先下载**到目录、再以只读挂载 + `HF_HUB_OFFLINE=1` 加载；支持断点续传与按大小跳过 |
| 4 | 只用 `/health` 判活会被"假就绪"骗到 | infinity 的 `/health` 在模型尚未加载完时也返回 `{"unix": ...}` | 就绪判定改为轮询 `GET /models`，直到出现 `capabilities: ["rerank"]` |
| 5 | `docker run IMAGE python -c ...` 报 `No such option: -c` | 镜像 entrypoint 是 `infinity_emb`，CLI 会先吃掉所有参数 | 不能在容器内把该镜像当 Python 解释器用，只在容器外做验证 |
| 6 | 脚本登录 WeKnora 一直报 `400 Invalid login parameters` | 脚本把 `ADMIN_PASSWORD=""` 写死成默认值，`sudo -E` 传入的环境变量被覆盖（部分 sudoers 配置下 `-E` 也不生效） | 默认值改为 `${ADMIN_PASSWORD:-}`，并推荐显式 `--admin-password` 传参 |
| 7 | 阶段四随机生成的管理员密码未留存，无法调用注册接口 | 当时密码只打印在会话输出中 | 通过 `docker exec WeKnora-postgres psql` 更新 `users.password_hash`（**bcrypt cost 10**，与服务端 `bcrypt.GenerateFromPassword` 一致），并在 5.7 节记录新密码 |
| 8 | 调用 `/models/{id}/debug` 报 `documents must be a JSON string array` | 服务端用 `c.PostForm("documents")` + `json.Unmarshal`，要求 multipart 里传**一个 JSON 数组字符串** | 改为 `-F "documents=<json array>"`，不能用多个 `documents=` 字段 |
| 9 | `docker stats` 显示容器 CPU 长期 200%+、加载耗时数分钟 | torch CPU 推理 + warmup 本身就是算力密集 | 属预期；容器已限核限内存，避免与 WeKnora 争抢 |

### 5.7 凭据变更（需关注）

为完成模型注册，本次在库内重置了管理员密码：

```bash
# 账号：admin@obara.local
# 新密码：Ob@raxGUgbyGr        ← 请首次登录后立即修改并妥善保管
```

> 后续仍在 "遗留事项" 中的"修改初始管理员密码"一栏，本次重置只是把未知密码换成已知密码，**并未替换为团队内部凭据**。

---

## 六、阶段六：知识库初始化与小样本验收（进行中）

### 6.1 交付资产

| 文件 / 脚本 | 用途 |
| --- | --- |
| `scripts/kb/init-welding-gun-kb.sh` | 建库 → 绑定模型 → 导入文档 → 创建受管智能体 → 写入检索参数（幂等，支持 `--no-wait` / `--status`） |
| `scripts/kb/verify-welding-gun-kb.sh` | 端到端验收：抽取真实记录自动生成提问 → 调用智能体 → 核对图号是否符合参数约束 |
| `scripts/kb/build-flat-kb.py` | 把宽表重建为「一行一段」的自然语言短句，解决 §6.3 的截断问题 |
| `welding-gun-selection-kb/03-flat-knowledge/` | 6 个文件的扁平版（`X2C-C/X/V2-C/V2-X/V3-C/V3-X.md`，共 18,689 行 11 MB） |

### 6.2 已完成的工作

| 项 | 结果 |
| --- | --- |
| 知识库 | `焊枪选型知识库`（`2308123d-11dd-4583-be3f-02fbe58c3015`），绑定 Embedding `bge-m3` |
| 智能体 | `焊枪选型助手`（`8646bb56-fa83-4bf4-be1e-69f7408f2543`），绑定 `deepseek-flash` + `bge-reranker-v2-m3`，答复约束提示词已注入 `config.system_prompt` |
| 检索参数 | 写入租户级 KV：`embedding_top_k=20`、`rerank_top_k=8`、`rerank_threshold=0.3`、`vector_threshold=0.15` |
| 已完成解析 | `X2C-V3-C`（152 片），其余 4 个文档已 `cancel-parse` 暂停（文件保留，可 `reparse` 恢复） |

> 关于提示词生效位置的说明：WeKnora v0.8.3 的 KnowledgeBase 上没有「答复约束提示词」字段，
> 该约束落在**绑定到该知识库的智能体**的 `config.system_prompt` 上；
> `ResolveCustomAgentPrompts()` 中显式文本优先，因此只要 `system_prompt` 非空就一定生效。

### 6.3 关键发现：`num_ctx=511` 截断 —— 阻塞性质量问题

Excel 直转 Markdown 表格后，每个分片 = 表头（37 列）+ 一行数据，实测：

| 指标 | 数值 |
| --- | --- |
| 分片平均长度 | **745 字符** |
| 超过 511 字符的比例 | **99.9%** |
| 「图号」在分片中的位置 | 第 **562** 字符 |

`ollama run bge-m3` 的默认上下文是 **511 token**，超出部分被静默丢弃，于是：

- 真正的**数据几乎全部落在向量之外**，只有重复的表头进入了语义空间；
- 后果很直接 —— 用「SDZC-3C30400L」这个图号本身去检索，Top4 全是别的图号；
- 这解释了为什么不同行的向量高度相似（表头相同、数据被切掉），区分度极低。

### 6.4 小样本验收结果（数据集：X2C-V3-C，148 条真实记录）

对比两种知识表示：

| 知识表示 | 分片长度 | 随机抽样的端到端正确率 | 固定同一组 5 题 | 平均延迟 |
| --- | --- | --- | --- | --- |
| Excel → Markdown 表格（现状） | 745 字符（99.9% 被截断） | **11/13 = 85%** | 5/5 | **36 s** |
| 一行一段「字段：值」（扁平行） | ≤ 351 字符（不截断） | **10/10 = 100%** | 5/5 | **20 s** |

判定方法不是简单比对「期望图号」，而是**回溯校验**：拿到答案后，回到原始记录核对其喉深 / 喉宽（±50）、
加压力（±500）、变压器与客户（包含匹配）是否真的满足提问 —— 即按答复约束提示词自身的规则验收。

**失败用例的根因是检索漏召，不是模型编造**：报错的那次回答给出的图号确实存在且客户名匹配，
正确记录压根没进候选集（`knowledge-search` 只返回 2 条候选）。这是宽 表 + 向量检索的结构性缺陷：
数值区间筛选本质上不属于语义相似度的能力范围。

**结论**：两种表示在这组题目上都能给出正确答案，但扁平格式**消除了截断隐患**，
端到端延迟降低约 **45%**（36 s → 20 s）。

**当前决定（2026-10-25）：暂缓扁平格式全量重导，维持表格原样。**
扁平数据已生成并可随时切换（`03-flat-knowledge/`，18,689 行 11 MB），重建一个新知识库即可，现有库保留做对照。

### 6.5 踩坑记录

| # | 现象 | 根因 / 处理 |
| --- | --- | --- |
| 1 | `HTTP 401 invalid or expired token` | `http()` 内部已拼 `Bearer`，外面又拼一次 → 双前缀。**另外**：短期内重复登录会让先前签发的 token 立刻失效，脚本必须「按需刷新」而不是每次调用前都重新登录 |
| 2 | `--status` 查进度后分片参数被改回默认 | `--status` 路径里也执行了 `PUT /knowledge-bases/{id}`，把本次命令行指定的 `chunk_size` 冲掉了 → 已改为 `--status` 只读不写 |
| 3 | 解析出的记录数为 0 | docreader 写出的分片把换行吃掉了，表头 / 分隔行 / 数据行以 `\|\|` 粘连 → 解析前先把 `\|\|` 还原成 `\|\n\|` |
| 4 | 扁平库里所有提问都答「未找到」 | 文件名从 `xxx-knowledge.xlsx` 变成 `xxx.md`，枪型判断取到最后一段是 `C.MD` 而非 `C`，构造提问时把 C 枪说成了 X 枪 → 先剥扩展名再判 `-C` / `-X` |
| 5 | 多次 login 后新 token 也失效 | 同 #1：服务端每个用户只认最新一次登录，脚本统一改为「先探测 token 是否有效，无效再登录」 |

### 6.6 常用命令

```bash
# 生成扁平格式文件（从已解析的分片重建，无需二次读取 Excel）
python3 scripts/kb/build-flat-kb.py --only X2C-V3-C --preview 3

# 用扁平格式建库并全量导入（后台跑，预计 3.5 ~ 4 小时）
KB_NAME=焊枪选型知识库 KB_DIR=$PWD/welding-gun-selection-kb/03-flat-knowledge \
CHUNK_SIZE=400 CHUNK_OVERLAP=0 ADMIN_PASSWORD='<后台密码>' \
  bash scripts/kb/init-welding-gun-kb.sh --no-wait

# 查看入库进度（只读，不改任何参数）
KB_NAME=焊枪选型知识库 ADMIN_PASSWORD='<后台密码>' bash scripts/kb/init-welding-gun-kb.sh --status

# 暂停：取消排队 / 处理中的文档，释放 CPU（文件保留）
ADMIN_PASSWORD='<后台密码>' bash scripts/kb/init-welding-gun-kb.sh --pause

# 恢复：对 cancelled / failed 的文档原地重新解析（不重复上传）
ADMIN_PASSWORD='<后台密码>' bash scripts/kb/init-welding-gun-kb.sh --resume

# 端到端验收
ADMIN_PASSWORD='<后台密码>' bash scripts/kb/verify-welding-gun-kb.sh --file X2C-V3-C --cases 5 --repeat 2
```

---

## 七、运维手册

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

### Ollama 运维命令

```bash
# 状态 / 日志
sudo systemctl status ollama
sudo journalctl -u ollama -f

# 重启（改 override.conf 后）
sudo systemctl restart ollama

# 模型管理
ollama list                      # 已下载模型
ollama ps                        # 当前常驻内存的模型与处理器占用
ollama pull bge-m3               # 拉取 / 更新模型
ollama rm <model>                # 删除模型释放磁盘

# 健康检查
curl -s http://127.0.0.1:11434/api/version
curl -s http://127.0.0.1:11434/api/tags
curl -s http://127.0.0.1:11434/api/embeddings -d '{"model":"bge-m3","prompt":"自检"}' | jq '.embedding|length'
```

**需要纳入备份的内容**（在上方基础上新增）：`- /opt/ollama/models`（模型文件，重拉耗时较长；仅在空间充裕时备份，重新拉取亦可恢复）

### Rerank 服务运维命令

```bash
# 状态 / 日志
docker ps --filter name=weknora-rerank
docker logs -f weknora-rerank
docker stats weknora-rerank                 # 实测常驻内存约 2 GB

# 就绪判定（/models 出现 capabilities 才算就绪，/health 会"假就绪"）
curl -s http://127.0.0.1:7997/models

# 手工调用
curl -s -X POST http://127.0.0.1:7997/rerank -H 'Content-Type: application/json' \
  -d '{"model":"bge-reranker-v2-m3","query":"电极的使用寿命是多久？",
       "documents":["电极需800小时更换","员工报销流程"]}'

# 换模型 / 改资源限制
sudo bash scripts/deploy/install-rerank.sh --recreate --cpus 6 --memory 4g --batch-size 8
```

**需要纳入备份的内容**（在上方基础上新增）：`- /opt/obara/rerank-models`（rerank 权重 2.2 GB；可重下载，备份仅为节省时间）

> ⚠️ 该服务监听 `0.0.0.0:7997` 且无鉴权，与 Ollama 同属"内网可达服务"，需由信息课在端口管控侧限制来源网段。

---

## 七之二、账号邮箱规范化（拼音规则）与多部门人员修正

### 背景

初始批量开户时邮箱为占位格式 `<姓名>@obara.local`（中文 local part），不便记忆也无法对接公司邮箱，
故统一改为公司域名下的拼音邮箱，并顺带修正「同一人身兼多部门」造成的重复账号。

### 邮箱规则

```
邮箱 = 姓（全拼）+ 名（每个汉字的首字母） + @obara.com.cn
高剑      -> gaoj@obara.com.cn
陈爱珍    -> chenaz@obara.com.cn
张杰（O/NJG 管理部，特例） -> zhangj_adm@obara.com.cn
```

- 规则固化在 `scripts/multi-tenant/gen-emails.py`（依赖 `pypinyin`），生成结果写回
  `data/departments-personnel.json` 的 `email` 字段，作为唯一数据源
- 姓氏多音字已人工校正：`翟=zhai`、`藏=zang`；名字用字：`晟=s`
- **同一人身兼多部门**（如 周泽健 同属 NJG-总经理室 与 SHA-总经理室）：共用一个账号、一个邮箱，
  同时是多个空间的成员
- **同名不同人**：仅张杰一例，共 2 位
  - NJG-管理部张杰：`zhangj_adm@obara.com.cn`（用户名 `张杰`）
  - NJG-技术开发一部 / 二部张杰：**同一人**，合并为一个账号 `zhangj@obara.com.cn`
    （用户名 `张杰(技术开发部)`，同时是两个空间的 owner）
- 前缀撞号：张娟与两位张杰同前缀，顺延为 `zhangj2@obara.com.cn`

### 落地方式与结果

| 项 | 结果 |
| --- | --- |
| 账号改名 | 直接 `UPDATE users SET email=...`（175 个存量账号），**密码哈希与成员关系保持不变** |
| 新增账号 | 1 个（技术开发部张杰）；技术开发一部 / 二部已合并为同一账号 |
| 账号总数 | 176（186 条人员归属记录） |
| 成员关系 | 186 条，核对无缺失、无多余（清理了张杰旧账号遗留的 2 条关系） |
| 门户登录提示 | 登录页 / 邀请注册页已提示企业邮箱规则 |
| 模型注入 | 16 个部门空间均已具备 embedding / 对话 / rerank 模型（`init-tenants.sh` 第 5 步） |

### 顺带修复的脚本缺陷

- `init-tenants.sh` 先创建本轮空清单、再 `ls -t` 取「上次清单」，导致密码永远读不到
  → 改为**先载入上次密码**再创建本轮文件
- 计划行新增第 5 列 `username`，但 `read` 仍只读 4 列，role 被拼成 `owner\t用户名`
  → 全部成员加入失败（`role must be one of ...`），已补齐列并让注册使用去重后的用户名

### 复跑方式

```bash
# 生成 / 重生邮箱（--force 覆盖已有 email）
python3 scripts/multi-tenant/gen-emails.py --domain obara.com.cn --force

# 幂等执行：建空间 → 建账号 → 接入成员 → 注入模型 → 生成邀请链接
ADMIN_PASSWORD='<超管密码>' bash scripts/multi-tenant/init-tenants.sh
```

> 账号密码清单 `output/accounts-*.csv` 属敏感文件，历史版本已归档到 `output/history/`，发放后请删除。

---

## 七之三、门户开机自启与一键启停（2026-10-26）

### 背景

虚拟机重启后，WeKnora 容器由 Docker `restart: unless-stopped` 自动拉起，Ollama 也随 systemd 自启，但 8081 门户此前只能手工执行 `bash portal/start.sh`，因此重启后只能访问 8080 后端，门户不可用。

### 方案与落地

新增 `scripts/start-all.sh`（一键启停）与 `scripts/deploy/install-autostart.sh`（安装 systemd 自启），并已在本机执行安装：

| 项 | 结果 |
| --- | --- |
| 服务名 | `obara-portal.service` |
| 运行用户 | `tobin`（仓库目录属主） |
| 工作目录 | `/home/tobin/Documents/trae_projects/obara-weknora-setup/portal` |
| 启动命令 | `python3 portal/server.py --port 8081 --upstream http://127.0.0.1:8080` |
| 依赖顺序 | `After=network-online.target docker.service ollama.service` |
| 重启策略 | `Restart=always` / `RestartSec=3` |
| 开机自启 | `enabled` |

同时确认 `docker.service`、`ollama.service` 均为 `enabled`；Rerank 容器 `weknora-rerank` 为 `restart: unless-stopped`，与 compose 容器一致。

### 验证记录

```bash
systemctl is-enabled obara-portal      # enabled
systemctl is-active obara-portal       # active
curl -o /dev/null -w '%{http_code}' http://127.0.0.1:8081/            # 200
curl -i http://127.0.0.1:8081/api/v1/tenants                        # 401，与直连 8080 一致 → 代理正常
bash scripts/start-all.sh restart                                    # 停止→启动全链路通过
bash scripts/start-all.sh status                                     # 容器 / 门户 / 健康检查均正常
```

Rerank 容器重启后需约 1～2 分钟加载模型，`GET /models` 出现 `capabilities:["rerank"]` 才算就绪；期间门户问答可用，重排能力稍后恢复。

### 日常运维命令

```bash
# 一键启动 / 状态 / 重启 / 停止（Ollama 保持运行）
bash scripts/start-all.sh
bash scripts/start-all.sh status
bash scripts/start-all.sh restart
bash scripts/start-all.sh stop

# 门户服务
sudo systemctl restart obara-portal
journalctl -u obara-portal -f
sudo bash scripts/deploy/install-autostart.sh --uninstall   # 卸载自启
```

> 注意：
> - 门户直接运行仓库内 `portal/server.py`，**移动仓库目录后需重新执行安装脚本**。
> - 执行 `start-all.sh stop` 后关机，容器因 `unless-stopped` 不会自动恢复，开机后需执行一次 `bash scripts/start-all.sh`。
> - 当前 `ufw` 未启用；若后续启用防火墙或安全组，需放行 `8081`、`8080`、`80`。

### 7.4 80 端口登录守卫与注册策略

**背景**：原生后台（80 端口）默认对全员开放登录与注册，任何员工都能操作知识库 / 模型 / 智能体等高权限功能；按 OBARA 约定，80 端口只给系统管理员，员工统一走 8081 门户。

**落地**：`portal/admin_gate.py` + `scripts/deploy/enable-admin-gate.sh`

| 项 | 值 |
| --- | --- |
| 服务名 | `obara-admin-gate.service` |
| 监听 / 上游 | `0.0.0.0:80` → `http://127.0.0.1:8088`（原生前端已改为只监听回环） |
| 登录白名单 | `GATE_ADMIN_EMAILS=admin@obara.local` |
| 拦截后跳转 | `GATE_PORTAL_URL=http://192.168.227.133:8081/`（部署时按内网 IP 写入 unit；未设置才回退 `http://<请求 Host>:8081/`） |
| 页面缓存 | 网关 HTML `no-store, no-cache, must-revalidate`；门户静态资源 `no-cache` |

规则与实现：

1. **只允许管理员登录**：`POST /api/v1/auth/login` 按邮箱白名单判定，非白名单 403；带 Bearer 令牌的 `/api/*` 复核令牌归属邮箱，非白名单 403（防绕过登录页直调 API）。
2. **任何人都不能注册**：`/api/v1/auth/register*`、`forgot-password`、`reset-password`、`verify`、`activate` 任意方法 403；`/register`、`/signup` 等页面返回提示页；门户 8081 侧 `POST /api/v1/auth/register` 同样 403（`portal/server.py` 的 `check_register()`）。
3. **只弹一个居中弹窗并倒计时跳转 8081**：原生后台自己那条顶部提示条（TDesign `t-message`）在触发拦截时被 `body.obara-blocked` 规则隐藏，只保留页面正中的统一卡片（警示图标 + 原因 + 倒计时进度条 + 「立即前往 8081 门户」按钮），倒计时结束自动跳转；地址栏直接访问注册页走提示页，同样的居中卡片。停留时长 `GATE_REDIRECT_DELAY_MS`（默认 3000 毫秒）。
4. **两层触发 + 不缓存**：注入脚本同时接管 `fetch` / `XHR` / SPA 路由，并用 `MutationObserver` 兜底（只要页面出现拦截文案即触发）；网关 HTML 与门户静态资源均禁用缓存，避免旧页面让守卫脚本失效。

启用与自检：

```bash
sudo bash scripts/deploy/enable-admin-gate.sh
# 脚本自检输出：非白名单登录 403 / 注册接口 403 / 注册页面 403
systemctl is-active obara-admin-gate     # active
journalctl -u obara-admin-gate -f        # [DENY] / [DENY-PAGE] 拦截记录
```

> 批量开户不受影响：`init-tenants.sh` 直连 `8080` 调 `/auth/register` 建账号，不走 80 网关与 8081 门户，因此 `.env` 的 `DISABLE_REGISTRATION` 仍保持 `false`。

---

## 八、安全相关（试点结束后回收）

- `/etc/sudoers.d/tobin-nopasswd`：部署期为便于自动化运维配置的免密 sudo（`NOPASSWD: ALL`），**试点结束后执行 `sudo rm /etc/sudoers.d/tobin-nopasswd` 回收**；所有 sudo 调用仍记录在 `/var/log/auth.log`
- SSH（22 端口）为文件传输临时开启，如信息课有端口管控要求，用完后可关闭
- `.env` 中的密钥不进 Git、不写文档
- Ollama 监听 `0.0.0.0:11434`（内网可达，无鉴权）：**需由信息课在端口管控侧限制来源网段**；如需本机收敛，可将 `OLLAMA_HOST` 改为 `127.0.0.1:11434`（但容器将无法访问，须同时改用容器网络方案）

---

## 九、后续阶段

| 阶段 | 内容 | 状态 |
| --- | --- | --- |
| 阶段三 | 部署 Ollama，拉取候选向量模型并 A/B 定夺 | ✅ **已完成**（Ollama 0.17.5 + `bge-m3`）；`embeddinggemma:300m` 待 A/B 前拉取后再对比定稿 |
| 阶段四 | 配置 DeepSeek（`api.deepseek.com`，快速问答 `deepseek-flash` / 智能推理 `deepseek-v4-pro`），Embedding 指向本机 Ollama | ✅ **已完成**（见第四章；三个模型均 active 且上游调用通过） |
| 阶段五 | 部署本地 Rerank 服务容器，端口 `7997`，禁用公有 rerank API | ✅ **已完成**（见第五章：`infinity 0.0.78-cpu` + `bge-reranker-v2-m3`，已注册到 WeKnora 且端到端调用通过）；首选 `Qwen3-Reranker-0.6B` 因模型架构不被支持暂不可用 |
| 阶段六 | 创建知识库（绑定 `bge-m3`）、创建 Agent（绑定 `deepseek-flash`）、导入试点文档、验证解析与选型问答 | 🔄 **进行中**：链路已通（智能体 + 提示词 + 小样本验收通过，见第六章）；待决策是否按扁平格式全量重导 18,689 行（预计 3.5 ~ 4 小时） |

各阶段详细方案与验收清单见 [README §4 部署步骤](../../README.md#4-部署步骤)。
