# 脚本索引

本目录按用途分为四类。**部署流程**脚本放在 `deploy/`，**非部署流程**脚本放在 `kb/`（知识库初始化与验收）、`docs-site/`（文档站构建）和 `multi-tenant/`（多租户部门初始化）。

```
scripts/
├── deploy/        # 部署流程：环境与组件部署（README 阶段一～五）
├── kb/            # 非部署：知识库初始化、验收与数据转换（README 阶段六）
├── multi-tenant/  # 非部署：多租户部门工作空间与人员初始化（邀请制）
└── docs-site/     # 非部署：文档站构建（GitHub Pages）
```

## 一、部署流程脚本（`deploy/`）

对应主文档《README》阶段一、阶段三、阶段四与阶段五。

| 脚本 | 适用场景 | 执行命令 |
| --- | --- | --- |
| `deploy/install-docker.sh` | 全新虚机首次安装 Docker | `sudo bash scripts/deploy/install-docker.sh` |
| `deploy/fix-docker-env.sh` | Docker 已安装，但配置未生效、APT 源或镜像加速器异常 | `sudo bash scripts/deploy/fix-docker-env.sh` |
| `deploy/configure-mirrors.sh` | 重新探测国内镜像加速器 | `sudo bash scripts/deploy/configure-mirrors.sh` |
| `deploy/install-ollama.sh` | 阶段三：安装 Ollama 服务并拉取 Embedding 模型 | `sudo bash scripts/deploy/install-ollama.sh` |
| `deploy/configure-deepseek.sh` | 阶段四：注册 DeepSeek 对话模型与本地 Ollama 向量模型并验证连通性 | `sudo DEEPSEEK_API_KEY='sk-xxxxx' bash scripts/deploy/configure-deepseek.sh` |
| `deploy/install-rerank.sh` | 阶段五：部署本地 Rerank 服务容器并注册到 WeKnora | `sudo bash scripts/deploy/install-rerank.sh` |

### 通用前提

- 系统：Ubuntu 20.04 / 22.04 / 24.04，架构 `amd64` 或 `arm64`
- 权限：root（通过 `sudo` 执行）
- 网络：可访问清华镜像站或 Docker 官方源；受限时先按主文档 1.4 节配置代理
- 依赖：`curl`、`python3`（`configure-deepseek.sh` 依赖 `python3` 解析 JSON 与构造请求体）
- 可重复执行；脚本会先备份将被覆盖的配置（`*.bak.<时间戳>`）

### install-docker.sh

用途：安装 Docker 引擎与 Compose 插件，并完成基础调优，替代手工执行 `get.docker.com` 脚本。

```bash
sudo bash scripts/deploy/install-docker.sh
```

主要步骤：

1. 安装依赖（`ca-certificates`、`curl`、`gnupg` 等）并创建 `/etc/apt/keyrings`
2. 导入 Docker GPG 公钥：清华源优先，失败时重试并回退 `download.docker.com`
3. 写入 Docker APT 源：代号支持 `focal` / `jammy` / `noble`，其他代号回退 `jammy`；清华源不可用时自动回退官方源
4. 安装 `docker-ce`、`docker-ce-cli`、`containerd.io`、`docker-buildx-plugin`、`docker-compose-plugin`
5. 生成 `/etc/docker/daemon.json`：镜像加速器、systemd cgroup、`overlay2`、日志轮转（100m × 3）、`live-restore`、DNS
6. 将执行用户加入 `docker` 组，输出版本/服务状态，并用 `hello-world` 验证镜像拉取

执行后：

- 当前终端运行 `newgrp docker` 或重新登录，才能免 `sudo` 使用 `docker`
- 若 `hello-world` 拉取失败，见下方"常见问题"，或执行 `fix-docker-env.sh`

### fix-docker-env.sh

用途：修复首次安装后常见的环境问题。出现以下任一情况时执行。

```bash
sudo bash scripts/deploy/fix-docker-env.sh
```

适用场景：

- `apt update` 提示 `cn.mirrors.tuna.tsinghua.edu.cn` 无法解析
- `docker info` 中看不到 `registry-mirrors`，或修改 `daemon.json` 后未生效（安装 Docker 包时守护进程已先启动）
- Docker Hub 直连不通，需要重新探测可用的镜像加速器

主要步骤：

1. 将 `/etc/apt/sources.list` 及 `/etc/apt/sources.list.d/*.list` 中的 `cn.mirrors.tuna.tsinghua.edu.cn` 替换为 `mirrors.tuna.tsinghua.edu.cn`（原文件先备份）
2. 逐一探测候选加速器（daocloud / imgdb / 1panel / rat.dev），仅保留可用项
3. 重写 `/etc/docker/daemon.json` 并做 JSON 校验，随后 `systemctl restart docker`
4. 验证 Docker 状态、加速器生效情况、APT 源可达性、`hello-world` 拉取

> 注意：第 3 步会整体覆盖现有 `daemon.json`（已自动备份）。若此前手工配置了 `proxies` 等自定义项，需在执行后重新补回。

### install-ollama.sh

用途：安装 Ollama 本地模型服务（阶段三），为 WeKnora 提供 Embedding 向量能力。对应主文档《README》阶段三。

```bash
sudo bash scripts/deploy/install-ollama.sh                                       # 安装服务并拉取 bge-m3
sudo bash scripts/deploy/install-ollama.sh --models "bge-m3 embeddinggemma:300m" # A/B 前补齐候选模型
sudo bash scripts/deploy/install-ollama.sh --skip-models                         # 只装服务不拉模型
sudo bash scripts/deploy/install-ollama.sh --models-dir /data/ollama/models      # 自定义模型目录
```

主要步骤：

1. 安装依赖：`curl`、`zstd`、`jq`
2. 下载发行包，按序尝试三个源并自动切换：ModelScope 镜像（国内可达，实测 ~8MB/s）→ `ollama.com` → GitHub Release
3. 安装二进制到 `/usr/bin/ollama`，运行库到 `/usr/lib/ollama`
4. 创建系统账号 `ollama` 与模型目录（默认 `/opt/ollama/models`）
5. 写入 systemd 服务与 `override.conf` 环境变量，启动并等待 `/api/version` 就绪
6. 拉取模型（失败自动重试 3 次）
7. 输出 `ollama list` 并做 embedding 维度验证

默认环境变量（`override.conf`）：`OLLAMA_HOST=0.0.0.0:11434`、`OLLAMA_MODELS`、`OLLAMA_KEEP_ALIVE=10m`、`OLLAMA_MAX_LOADED_MODELS=2`、`OLLAMA_CONTEXT_LENGTH=8192`。内存充裕时可放宽 `KEEP_ALIVE`（如 `-1` 常驻，换取低延迟）。

常用运维命令：

```bash
sudo systemctl status ollama
sudo journalctl -u ollama -f
ollama list / ollama ps / ollama rm <model>
curl -s http://127.0.0.1:11434/api/tags
```

> 注意：下载约 1.8 GB + 模型 1.2 GB，实测全程约 8 分钟，建议用 `nohup ... > /tmp/ollama-install.log 2>&1 &` 后台执行并轮询日志。
> WeKnora 容器访问 Ollama 需使用宿主 IP（如 `http://192.168.227.133:11434`），不能填 `localhost`。

### configure-deepseek.sh

用途：阶段四，通过 WeKnora REST API 注册对话模型与向量模型，并做真实上游连通性验证。对应主文档《README》阶段四。

```bash
# 密钥优先从环境变量读取；未设置时脚本会交互式询问
sudo DEEPSEEK_API_KEY='sk-xxxxx' bash scripts/deploy/configure-deepseek.sh

sudo bash scripts/deploy/configure-deepseek.sh --api-key 'sk-xxxxx'   # 显式传参
sudo bash scripts/deploy/configure-deepseek.sh --skip-verify       # 只注册不验证（不产生费用）
sudo bash scripts/deploy/configure-deepseek.sh --ollama-url http://192.168.227.133:11434
sudo bash scripts/deploy/configure-deepseek.sh --embed-model bge-m3 --embed-dim 1024
```

主要步骤：

1. 检查 WeKnora `/health`；未就绪则提示先启动容器
2. 读取密钥：命令行 `--api-key` > 环境变量 `DEEPSEEK_API_KEY` > 服务器 `.secrets/deepseek.env` > 交互式输入
3. 登录获取 JWT；账号不存在时自动注册首个管理员（随机密码会在结束时打印）
4. 幂等注册三个模型（已存在则 PUT 更新）：`bge-m3`（Embedding/local）、`deepseek-flash`、`deepseek-v4-pro`（KnowledgeQA/remote）
5. 对每个模型调用 `/models/{id}/debug` 做真实调用验证

> ⚠️ **第 5 步会发起真实上游请求并产生 DeepSeek 费用**，加 `--skip-verify` 可跳过。
> ⚠️ 远程 API 模型的 `source` 必须是 `remote`；填厂商名会被判定为本地模型并触发 Ollama 下载失败。
> ⚠️ 若模型 Base URL 使用裸 IP，需先在 `/opt/obara/weknora/.env` 配置 `SSRF_WHITELIST_EXTRA`，
>    并执行 `sudo docker compose up -d --force-recreate app` 才生效（`restart` 不重读 `env_file`）。

### install-rerank.sh

用途：阶段五，部署本地 Rerank 重排服务并把模型注册到 WeKnora。对应主文档《README》阶段五。

Ollama 不提供 rerank 能力，WeKnora 的 `docker-compose.yml` 也没有内置 rerank 服务，因此用 `infinity`（提供 WeKnora 期望的 Cohere 兼容 `/rerank` 接口）单独起容器；**禁止改用公有 rerank API**（检索片段同属内部资料）。

```bash
sudo bash scripts/deploy/install-rerank.sh                                   # 下载权重 + 起容器 + 注册 + 验证
sudo bash scripts/deploy/install-rerank.sh --no-register                     # 只部署服务，不注册到 WeKnora
sudo bash scripts/deploy/install-rerank.sh --skip-verify                     # 注册但跳过 WeKnora 侧调用验证
sudo bash scripts/deploy/install-rerank.sh --recreate --cpus 6 --memory 4g   # 改资源限制后重建容器
sudo bash scripts/deploy/install-rerank.sh --model BAAI/bge-reranker-base --engine optimum --container <名> --port 7998   # A/B 第二个实例
```

主要步骤：

1. 前置检查（root、docker、端口 `7997` 是否被占用）并推导宿主内网 IP（容器视角不能用 `localhost`）
2. 准备镜像（Docker Hub 直连失败时自动回退国内加速器）
3. 下载权重：自动挑选可达源（`hf-mirror.com` → `huggingface.co`），支持断点续传、5 次重试、按远端大小跳过已完成文件；已存在则整段跳过
4. 以只读方式把权重目录挂进容器，`HF_HUB_OFFLINE=1` 离线加载；容器限制 `--cpus/--memory`，`--restart unless-stopped`
5. 轮询 `GET /models` 直到出现 `capabilities:["rerank"]`（**不能只看 `/health`**，模型未加载完它也返回 `{"unix":...}`）
6. 冒烟测试：中文查询 + 相关/无关/英文候选，校验相关片段是否排在首位并计时
7. 幂等注册到 WeKnora：`type=Rerank` / `source=remote` / `provider=generic`，Base URL `http://<宿主IP>:7997`
8. 调用 `/api/v1/models/{id}/debug` 验证端到端链路

> ⚠️ 注册需要管理员凭据，推荐写在命令行里：`sudo bash scripts/deploy/install-rerank.sh --admin-password '<后台登录密码>'`；
>    也可 `sudo ADMIN_PASSWORD='xxx' bash scripts/deploy/install-rerank.sh`（脚本会读取同名环境变量，但某些 sudoers 配置下 `-E` 可能不生效）。
> ⚠️ 本机 12 核时推荐 `--cpus 6 --batch-size 8`；实测 2 核→6 核延迟下降约 35%，该服务对算力敏感。
> ⚠️ `Qwen/Qwen3-Reranker-0.6B` 目前**无法**在 `michaelf34/infinity:0.0.78-cpu` 上加载（内置 transformers 不识别 `qwen3` 架构），因此默认用 `BAAI/bge-reranker-v2-m3`。

## 二、非部署脚本（`kb/`）

知识库初始化、验收与数据转换，对应主文档《README》阶段六。这些脚本不改变部署环境，只在已部署完成的 WeKnora 上操作数据。

| 脚本 | 用途 | 执行命令 |
| --- | --- | --- |
| `kb/init-welding-gun-kb.sh` | 建库 + 绑定模型 + 导入文档 + 创建受管智能体 + 写入检索参数（幂等，支持 `--no-wait` / `--pause` / `--resume` / `--status`） | `sudo ADMIN_PASSWORD='<后台密码>' bash scripts/kb/init-welding-gun-kb.sh` |
| `kb/verify-welding-gun-kb.sh` | 端到端验收：抽取真实记录自动生成提问 → 调用智能体 → 核对图号 | `sudo ADMIN_PASSWORD='<后台密码>' bash scripts/kb/verify-welding-gun-kb.sh` |
| `kb/build-flat-kb.py` | 把宽表重建为「一行一段」自然语言短句，规避 `num_ctx=511` 截断（数据取自 Postgres chunks） | `python3 scripts/kb/build-flat-kb.py` |

## 三、非部署脚本（`multi-tenant/`）

多租户部门工作空间与人员初始化，对应主文档《README》多租户方案。这些脚本不改变部署环境，只在已部署完成的 WeKnora 上创建工作空间与邀请成员。

| 脚本 | 用途 | 执行命令 |
| --- | --- | --- |
| `multi-tenant/init-tenants.sh` | 读取 `data/departments-personnel.json`，一键创建 16 个部门工作空间并批量邀请成员（文档管理员=Owner，其余=Contributor），输出邀请链接汇总 | `sudo ADMIN_PASSWORD='<后台密码>' bash scripts/multi-tenant/init-tenants.sh` |

常用参数：

```bash
sudo bash scripts/multi-tenant/init-tenants.sh --dry-run            # 只打印计划，不调用 API
sudo bash scripts/multi-tenant/init-tenants.sh --only-dept NJG-DEV2 # 只处理指定部门
sudo bash scripts/multi-tenant/init-tenants.sh --base-url http://192.168.227.133:8080
```

> 前置条件：WeKnora 已运行、管理员账号已创建、建议先开启 RBAC（`.env` 中 `WEKNORA_TENANT_ENABLE_RBAC=true`）。
> 邀请链接汇总输出到 `output/invitations-<时间戳>.txt`，由管理员分发给各部门文档管理员。

## 四、非部署脚本（`docs-site/`）

文档站构建，与部署环境无关，仅用于本地预览与 GitHub Actions 发布。

| 脚本 | 用途 | 执行命令 |
| --- | --- | --- |
| `docs-site/build-docs-site.py` | 扫描仓库 Markdown → 渲染单页静态站点（输出到 `site/`） | `python3 scripts/docs-site/build-docs-site.py` |
| `docs-site/docs-site-template.html` | 文档站页面模板（侧栏导航、页内目录、深浅色主题） | 由 `build-docs-site.py` 读取 |

## 五、部署脚本常见问题

| 现象 | 处理 |
| --- | --- |
| 访问 `docker.sock` 报 `Permission denied` | 重新登录或执行 `newgrp docker`；用 `id -nG` 确认已包含 `docker` 组 |
| `hello-world` 拉取失败 | 确认代理可用后执行 `fix-docker-env.sh` 重新探测加速器；必要时在 `daemon.json` 中补充 `proxies` |
| 修改 `daemon.json` 后不生效 | 执行 `sudo systemctl restart docker`，或直接运行 `fix-docker-env.sh` |
| APT 源报 404 / 无法解析 | 执行 `fix-docker-env.sh` 第 1 步逻辑，或按主文档 1.1 节重新配置镜像源 |
| 脚本中途失败 | 可直接重跑；已有配置均有备份 |
| `install-rerank.sh` 权重下载慢或中断 | 脚本已支持断点续传，直接重跑即可；也可先手工下载再放为 `--model-dir` |
| `install-rerank.sh` 卡在"等待模型加载就绪" | 查看 `docker logs -f weknora-rerank`；内存不足时下调 `--batch-size`，或给容器加核/加内存后 `--recreate` |
| `install-rerank.sh` 报"登录失败" | 用 `--admin-password` 传入后台实际密码；或先 `--no-register` 完成部署，再到后台手工注册 |

## 相关文档

- 主文档：[../README.md](../README.md)（部署方案、阶段一～六与验收清单）
- 部署执行记录：[../docs/deployment/deployment-log.md](../docs/deployment/deployment-log.md)
- 阶段总结：[../docs/deployment/stage-summary.md](../docs/deployment/stage-summary.md)
