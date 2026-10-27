# OBARA 知识库系统（WeKnora）部署指南

[![Docs Site](https://github.com/caifugao110/obara-weknora-setup/actions/workflows/docs-site.yml/badge.svg)](https://github.com/caifugao110/obara-weknora-setup/actions/workflows/docs-site.yml)

> 📖 **在线文档站**：<https://caifugao110.github.io/obara-weknora-setup/> —— 本仓库所有文档（README + `docs/` + 脚本文档）会被自动汇总成一个可检索、带目录的单页网站；**README 或 `docs/` 一有改动，GitHub Actions 会自动重建并发布**，详见 [9.4 文档站自动生成](#94-文档站自动生成)。
> 基于腾讯开源项目 [WeKnora](https://github.com/Tencent/WeKnora)（MIT 协议）搭建的企业内部知识库系统，用于公司内部文档、规范、技术资料的沉淀、语义检索与 AI RAG 智能问答。

| 项目信息 | 内容 |
| --- | --- |
| 项目名称 | OBARA 知识库系统 |
| 基座 | WeKnora v0.8.3（固定 Tag 版本，不使用 latest 浮动镜像） |
| 部署形态 | 本地私有化部署（内网隔离，Docker 容器化） |
| 业务负责 | 技术开发二部——应用部署、知识库维护、RAG 配置、用户答疑 |
| 基础设施支持 | 信息课——虚机、网络、备份、监控、安全审计 |
| 试点范围 | 一期：技术开发二部内部试点 → 二期：全公司推广 |

---

## 1. 项目背景与目标

- 设计部门日常需要频繁查阅各类设计、技术规范，存在文档多版本分散、查找慢的问题。
- 统一沉淀 PDF / Word / Markdown 等格式资料，支持向量检索与 AI 溯源问答，提升研发、设计人员查阅效率。
- 资料语种混合：中文为主，另有英文、日文、西班牙文、德文、俄文、法文等，**需支持跨语种检索**（如中文提问命中英文原版规范）。
- 数据闭环在内网，规避公有 API 方案的数据外发合规风险。

### 1.1 试点目标（重要）

> ⚠️ 8 核 32G **纯 CPU** 跑本地大模型速度会偏慢。**本次试点目标是验证流程、验证 RAG 检索与文档解析效果，不追求问答速度。**

- ✅ 验证 WeKnora 完整部署流程
- ✅ 验证文档解析（PDF/Word/Markdown）与向量入库
- ✅ 验证 RAG 语义检索与 AI 溯源问答效果
- ⏸️ 问答响应速度（GPU 推理节点二期再评估）
- ⏸️ 公有 API 接入许可（效果验证后再评估申请）

---

## 2. 系统架构

```
┌─────────────────────────────────────────────────────────┐
│  ESXi 主机 192.168.160.37（datastore2）                  │
│  ┌───────────────────────────────────────────────┐      │
│  │  虚拟机 OBARA-WeKnora（Ubuntu 22.04.5 LTS）      │      │
│  │  8 vCPU / 32GB RAM / 500GB SSD                 │      │
│  │                                               │      │
│  │  ┌─────────────────────────────────────────┐  │      │
│  │  │  Docker 环境                            │  │      │
│  │  │  ├─ WeKnora 全套容器（Web/后端/中间件）    │  │      │
│  │  │  ├─ Ollama（本地向量模型 Embedding）       │  │      │
│  │  │  └─ Rerank（本地重排服务容器）             │  │      │
│  │  └─────────────────────────────────────────┘  │      │
│  └───────────────────────────────────────────────┘      │
│                    │                                    │
└────────────────────│────────────────────────────────────┘
                     │
        内网用户浏览器访问（不直接暴露公网）
                     │
        临时出站权限：拉取 HuggingFace / Ollama 模型文件
        对话模型：DeepSeek API（密钥管控 + 调用审计）
```

### 2.1 模型选型

> 选型依据：WeKnora 官方模型评测榜（数据截至 2026-10-08，基于 WeKnora v0.8.0）：<https://weknora.weixin.qq.com/docs/models>
> 榜单 Top 方案（`Nemotron-3-Embed-8B-BF16` 8B、`KaLM-Embedding-Gemma3-12B` 12B、`Qwen3-Reranker-8B` 8B）需 GPU 推理，**本次 8C/32G 纯 CPU 试点不采用**，二期 GPU 节点再评估；LLM 榜前四（Grok 4.7 / GPT-6 Astra / Claude Opus 5 / GLM-5.3）均为公有 API，合规上已排除。

| 用途 | 方案 | 说明 |
| --- | --- | --- |
| 向量模型（Embedding） | **本地 Ollama：`embeddinggemma:300m` 与 `bge-m3` 二选一（导库前 A/B 定夺）** | `bge-m3`：567M / 1024 维 / 8K 上下文，100+ 语种、跨语种检索强（榜单 `NDCG@10` 0.7095，#16）；`embeddinggemma:300m`：300M / 768 维 / 2K 上下文（`NDCG@10` 0.7500，#8，较 bge-m3 高约 5.7%，CPU 更省）。最终以跨语种用例实测为准，流程见阶段三 |
| 对话模型（LLM） | **DeepSeek API：`deepseek-flash`（快速问答）/ `deepseek-v4-pro`（智能推理）** | 纯 CPU 本地推理过慢，对话走 API 保证可用性；问答时仅发送检索片段。`deepseek-flash` 即 DeepSeek-V4.1-Flash，智能推理榜 #5、快速问答榜 #5，为合规前提下可选最优档位 |
| 重排模型（Rerank） | **已启用**：本地 `BAAI/bge-reranker-v2-m3`（备选转正，阶段五已落地） | 榜单显示精排可将 `NDCG@10` 由 0.8011 提升至 0.8361（+4.4%），弱 Embedding 收益更大。首选的 `Qwen/Qwen3-Reranker-0.6B` 因服务镜像内置 transformers 不识别 `qwen3` 架构暂不可用（详见阶段五与部署记录）。Ollama **不提供** rerank 能力，本方案单独起本地 rerank 服务容器（阶段五）；**禁用公有 rerank API** |

### 2.2 检索参数（对齐榜单评测配置）

| 参数 | `bge-m3` | `embeddinggemma:300m` |
| --- | --- | --- |
| `chunk_size` / `chunk_overlap` | 1000 / 200 | 1000 / 200 |
| `embedding_top_k` | 100（未启用 rerank 时 10） | 50（未启用 rerank 时 8） |
| `vector_threshold` | 0.47（保守起见可先"不启用"） | 0.37 |
| `rerank_top_k` / `rerank_threshold` | 10 / 0.3 | 8 / 0.3 |
| `keyword_threshold` | 0.3 | 0.3 |

---

## 3. 基础设施配置

### 3.1 虚拟机规格

| 配置项 | 规格 | 备注 |
| --- | --- | --- |
| 虚拟机名称 | `OBARA-WeKnora` | — |
| 宿主机 | ESXi 192.168.160.37 | 由信息课管理 |
| vCPU | 8 核 | — |
| 内存 | 32 GB | 余量充足，为后续本地模型验证留基础 |
| 磁盘 | 500 GB SSD | 建议存放于 **datastore2**；预留二期本地模型/文档扩容空间 |
| 操作系统 | Ubuntu 22.04.5 LTS | 预装 Docker 环境 |
| 网络 | 内网固定 IP（待分配）+ 临时外网权限 | 外网仅用于拉取模型文件，验证完成后回收 |

> ⚠️ **实测资源与规划不一致**：部署机实测 CPU 仅 4 核在线（`nproc=4`，Xeon E5-2676 v3 @ 2.4GHz）、内存 8 GB（规划 8 核 / 32 GB）。内存余量有限，Ollama 已通过 `KEEP_ALIVE=10m`、`MAX_LOADED_MODELS=2` 限制常驻占用。**需与信息课核对虚机实际分配规格**，二期 GPU/大模型评估也依赖此项。

### 3.2 网络策略（信息课侧）

- [ ] 内网网段部署，分配内网域名 / IP
- [ ] 端口访问管控，不直接暴露公网
- [ ] 临时出站权限：HuggingFace / Ollama 模型下载源（拉取完成后可收紧）
- [ ] DeepSeek API 出站白名单（`api.deepseek.com`）
- [ ] 公司代理（如有）：内网访问 HuggingFace 可走 `127.0.0.1:7897` 类代理，需在 Docker/系统层面配置

---

## 4. 部署步骤

> 以下为整体流程概览，每一步的详细操作将在后续章节/文档中补充完善。
>
> 📄 **阶段一（Docker 环境）、阶段二（WeKnora 部署）与阶段三（Ollama 本地向量模型）的已实际执行记录**——含具体命令、踩坑原因与验证结果——见 [`docs/deployment/deployment-log.md`](docs/deployment/deployment-log.md)。

### 阶段一：虚机与系统准备（信息课 + 业务侧）

1. 信息课在 ESXi 上创建虚拟机 `OBARA-WeKnora`（8C/32G/500G SSD，datastore2）
2. 安装 Ubuntu 22.04.5 LTS Server
3. 配置内网 IP、SSH 访问、临时外网权限

#### 1.1 安装后必做优化

**① 安装 VMware Tools（至关重要！）**

安装 `open-vm-tools` 以获得自适应分辨率、剪贴板共享、拖拽文件等功能：

```bash
sudo apt update
sudo apt install open-vm-tools-desktop -y
sudo reboot
```

> 💡 推荐使用开源的 `open-vm-tools-desktop` 而非 VMware 自带的 "Install VMware Tools" 菜单项，前者与 Ubuntu 内核兼容性更好，且随系统更新。

**② 更换国内镜像源（加速软件下载）**

```bash
# 备份原始源
sudo cp /etc/apt/sources.list /etc/apt/sources.list.bak

# 替换为清华源（也可用阿里/中科大）
sudo sed -i 's/archive.ubuntu.com/mirrors.tuna.tsinghua.edu.cn/g' /etc/apt/sources.list
sudo sed -i 's/security.ubuntu.com/mirrors.tuna.tsinghua.edu.cn/g' /etc/apt/sources.list

# 更新缓存
sudo apt update && sudo apt upgrade -y
```

#### 1.2 安装 Docker 环境

推荐使用仓库自带脚本，自动完成 GPG 公钥、APT 源、镜像加速器和日志轮转配置。脚本详细说明见 [scripts/README.md](scripts/README.md)。

```bash
# 1) 安装 Docker CE + Compose 插件（清华源优先，失败回退官方源）
sudo bash scripts/deploy/install-docker.sh

# 2) 使 docker 组生效：重新登录，或当前终端执行
newgrp docker

# 3) 验证
docker --version && docker compose version
```

安装完成后若出现以下情况，执行修复脚本：

- APT 源 `cn.mirrors.tuna.tsinghua.edu.cn` 无法解析
- `docker info` 中看不到 `registry-mirrors`，修改 `daemon.json` 后未生效
- Docker Hub 直连不通，需重新探测镜像加速器

```bash
sudo bash scripts/deploy/fix-docker-env.sh
```

> 不使用脚本时，可手工执行 `curl -fsSL https://get.docker.com | sh` 安装，再自行配置 `/etc/docker/daemon.json` 并 `sudo systemctl restart docker`。

#### 1.3 安装部署辅助 AI Agent（可选）

在虚机上安装 AI Agent 辅助部署与排障，下载安装包复制到虚拟机后在相应目录执行：

| 工具 | 下载地址 | 安装命令 |
| --- | --- | --- |
| Trae | https://www.trae.cn/download | `sudo dpkg -i TRAE_CN-linux-x64.deb` |
| CodeBuddy | https://www.codebuddy.cn/ide/#download-section | `sudo dpkg -i CodeBuddy-linux-x64.deb` |
| WorkBuddy | 暂无官方 Linux 包，社区打包方案：[xingwangzhe.fun/posts/workbuddy-linux-deb-rpm](https://xingwangzhe.fun/posts/workbuddy-linux-deb-rpm/) | `sudo dpkg -i WorkBuddy-linux-x64.deb` |

#### 1.4 安装代理客户端（拉取 GitHub 资源用）

虚机仅有临时出站权限，国内直连 GitHub 不稳定。拉取 WeKnora 源码、模型或安装包前，可先安装代理客户端。以下两个二选一，均要求 **Ubuntu 22.04 LTS 及以上**（FlClash 0.9.2 需要 glibc ≥ 2.34；Clash Verge 需要 `libwebkit2gtk-4.1-0`，Ubuntu 20.04 均不满足）。

**FlClash 0.9.2**

```bash
wget https://github.com/chen08209/FlClash/releases/download/v0.9.2/FlClash-0.9.2-linux-amd64.deb
sudo dpkg -i FlClash-0.9.2-linux-amd64.deb
sudo apt -f install -y
```

虚机无 GPU 加速，**必须启用软件渲染**，否则无法启动或白屏：

```bash
LIBGL_ALWAYS_SOFTWARE=1 nohup FlClash >/tmp/flclash.log 2>&1 &
```

> 若希望从应用菜单启动也带软件渲染，可修改 `/usr/share/applications/FlClash.desktop` 的启动行：
> `Exec=env LIBGL_ALWAYS_SOFTWARE=1 FlClash %U`

**Clash Verge Rev 2.5.8**

```bash
wget https://github.com/clash-verge-rev/clash-verge-rev/releases/download/v2.5.8/Clash.Verge_2.5.8_amd64.deb
sudo apt install -y libwebkit2gtk-4.1-0
sudo dpkg -i Clash.Verge_2.5.8_amd64.deb
sudo apt -f install -y
```

**订阅与配置**

- 订阅管理页：<https://www.eevpn88.com/#/dashboard>（个人账号，勿外传、勿写入公开仓库）
- 客户端内进入 `Profiles`（配置），粘贴订阅链接并更新；选中配置后启动代理
- 需要 TUN / 虚拟网卡模式时，再按客户端提示安装辅助服务；普通代理模式不需要

**常见问题**

| 现象 | 原因 / 处理 |
| --- | --- |
| `dpkg: 依赖关系问题使得 flclash 的配置工作不能继续`，缺 `libayatana-appindicator3-1` | `sudo apt install -y libayatana-appindicator3-1 libayatana-ido3-0.4-0` |
| `libayatana-ido3-0.4.so.0: cannot open shared object file` | 安装 `libayatana-ido3-0.4-0` 后重试 |
| `GLIBC_2.34 not found` | 系统过旧（20.04 为 glibc 2.31），需升级到 Ubuntu 22.04/24.04 |
| `libwebkit2gtk-4.1-0 无法安装`（Clash Verge） | 同上，20.04 源内无此包 |
| 日志出现 `IPC Disconnected / core done / exit` | 是程序关闭时的正常收尾日志，不是崩溃；用 `nohup` 或应用菜单启动可保持运行 |
| `helper ping failed: /run/flclash/helper.sock` | 仅影响 TUN 模式，普通代理可忽略 |
| 界面白屏 / 无法启动 | 使用软件渲染：`LIBGL_ALWAYS_SOFTWARE=1 FlClash` |
| `rm: 无法删除 '/usr/bin/FlClash'` | deb 维护脚本清理旧路径，无害 |

> apt 若因其他损坏包拒绝安装（如残留的 `clash-verge`），先移除该包或执行 `sudo apt --fix-broken install`。

### 阶段二：部署 WeKnora

```bash
# 1. 克隆固定版本（锁定 Tag，不用 latest）
git clone https://github.com/Tencent/WeKnora.git
cd WeKnora
git checkout v0.8.3   # 固定版本，升级前评估变更内容

# 2. 配置环境变量（按 .env 配置端口、密钥等）
cp config.env.template .env

# 3. 启动
docker compose up -d

# 4. 验证
docker compose ps
curl -I http://localhost:8080   # 端口以 .env 中实际配置为准
```

**本次实际部署结果**

| 项 | 实际值 |
| --- | --- |
| 源码目录 | `/opt/obara/weknora`（Tag `v0.8.3`，commit `3e22822`） |
| 环境文件 | 由仓库自带的 `.env.example` 复制为 `.env`（非 `config.env.template`） |
| 端口 | 前端 `80`、后端 `8080`（`FRONTEND_PORT` / `APP_PORT`） |
| 启用服务 | `app`、`frontend`、`docreader`、`postgres`(paradedb)、`redis` 共 5 个 |
| 访问地址 | `http://192.168.227.133`，健康检查 `curl http://localhost:8080/health` → `{"status":"ok"}` |

> 📄 镜像清单、`.env` 关键项、踩坑与运维命令的完整记录见 [`docs/deployment/deployment-log.md`](docs/deployment/deployment-log.md)。

### 阶段三：部署本地向量模型（Ollama）

```bash
# 方式 A（本仓脚本，推荐）：安装 Ollama 服务 + 拉取模型，幂等可重跑
sudo bash scripts/deploy/install-ollama.sh                                  # 默认拉取 bge-m3
sudo bash scripts/deploy/install-ollama.sh --models "bge-m3 embeddinggemma:300m"   # A/B 前补齐候选
sudo bash scripts/deploy/install-ollama.sh --skip-models                    # 只装服务

# 方式 B（官方原命令，需直连 GitHub）：ollama.com/install.sh 会 307 跳到 GitHub Release，
#        本机 GitHub 直连超时，故作为备选，脚本内已自动尝试各下载源
curl -fsSL https://ollama.com/install.sh | sh

# 拉取候选向量模型（均为小模型，4~8 核 CPU 可跑）
ollama pull bge-m3                  # 1024 维 / 8K 上下文 / 100+ 语种，跨语种检索强
ollama pull embeddinggemma:300m     # 768 维 / 2K 上下文，榜单 NDCG@10 更高、更省资源

# 验证
ollama list
curl http://localhost:11434/api/embeddings -d '{"model":"bge-m3","prompt":"测试"}'
```

**本次实际部署结果**

| 项 | 实际值 |
| --- | --- |
| Ollama 版本 | `0.17.5`，原生 systemd 服务（`active` + `enabled`） |
| 安装路径 | 二进制 `/usr/bin/ollama`，运行库 `/usr/lib/ollama`（含 GPU runner，4.3 GB） |
| 模型目录 / 监听 | `/opt/ollama/models` / `0.0.0.0:11434` |
| 已拉取模型 | `bge-m3:latest` 1.2 GB（566.70M 参数 / 8192 上下文 / **1024 维** / F16） |
| 内存约束配置 | `OLLAMA_KEEP_ALIVE=10m`、`OLLAMA_MAX_LOADED_MODELS=2`（本机实测仅 8 GB 内存） |
| Embedding 性能 | 单条短句 0.34~0.45s（热模型，纯 CPU） |
| 跨语种实测 | 中↔日 0.9578、中↔英 0.7291、无关句 0.32（余弦相似度，见部署记录） |
| 容器连通性 | WeKnora-app 内 `curl http://192.168.227.133:11434/api/version` 通过 → 阶段四填宿主 IP |
| 未拉取 | `embeddinggemma:300m`（A/B 候选项，导库前按需补拉，见下方 A/B 流程） |

> 选型依据见 2.1 节；`nomic-embed-text`（768 维）中文效果偏弱，`bge-large-zh-v1.5` 仅支持 512 token 且仅中文，均不采用。
> 📄 执行过程、踩坑与完整验证数据见 [`docs/deployment/deployment-log.md` 三、阶段三](docs/deployment/deployment-log.md)。

**⚠️ 导库前必须完成 A/B 定稿（换 Embedding = 全量重向量化，代价高）**

1. 建两个测试知识库（如 `AB-bge-m3`、`AB-gemma300m`），分别绑定不同 Embedding 模型
2. 导入同一批 20~30 份真实规范文档，`chunk_size` / `chunk_overlap` 按 2.2 节设为一致
3. 用同一组真实问题评测，**必须包含"中文提问命中英文/日文原版规范"的跨语种用例**
4. 判定：中文为主且跨语种差异不明显 → 选 `embeddinggemma:300m`；跨语种召回 `bge-m3` 明显占优 → 保留 `bge-m3`，并走"大 `embedding_top_k` + rerank"路线
5. 定稿后再导入全量文档，避免二次重建索引

### 阶段四：配置 DeepSeek 对话模型

```bash
# 一键配置（幂等，可重复执行）：注册 DeepSeek 对话模型 + 本地 Ollama 向量模型，并验证连通性
sudo DEEPSEEK_API_KEY='sk-xxxxx' bash scripts/deploy/configure-deepseek.sh

# 常用参数
sudo bash scripts/deploy/configure-deepseek.sh --api-key 'sk-xxxxx'      # 显式传入密钥
sudo bash scripts/deploy/configure-deepseek.sh --skip-verify          # 只注册，不做上游调用
```

**手工配置要点**（在管理后台 → 模型管理 → 添加模型）：

1. 模型供应商选择 **DeepSeek**（底层为 OpenAI 兼容接口，`api=openai-completions`）
2. 填入：
   - API Base：`https://api.deepseek.com/v1`（Anthropic 格式可用 `https://api.deepseek.com/anthropic`）
   - API Key：DeepSeek 密钥（**密钥仅存服务器，不入 Git、不入文档**）
   - 模型名：
     - 快速问答模式 → **`deepseek-flash`**（即 DeepSeek-V4.1-Flash，榜单智能推理 #5 / 快速问答 #5）
     - 智能推理模式 → **`deepseek-v4-pro`**（复杂多跳问题）

   > ⚠️ 旧模型名 `deepseek-chat`（V3 系列）已过时，不要再填；`deepseek-v4-flash`、`deepseek-v4-flash-vision-exp` 等旧别名对应模型已下线。
3. Embedding 模型选择阶段三 A/B 定稿的 Ollama 本地模型：`source=local`，Base URL 填 **`http://192.168.227.133:11434`**（容器内已验证可达；不可填 `localhost`，容器视角指向自身），模型名 `bge-m3`，维度 `1024`
4. 连通性验证：后台模型详情页"调试"会发起真实上游调用（**产生费用**），返回 `ok=true` 即通过

**本次实际配置结果**

| 模型 | 类型 | source | provider | Base URL | 状态 |
| --- | --- | --- | --- | --- | --- |
| `deepseek-flash` | KnowledgeQA | `remote` | `deepseek` | `https://api.deepseek.com/v1` | ✅ active |
| `deepseek-v4-pro` | KnowledgeQA | `remote` | `deepseek` | `https://api.deepseek.com/v1` | ✅ active |
| `bge-m3` | Embedding | `local` | `generic` | `http://192.168.227.133:11434` | ✅ active（1024 维） |

> 阶段五注册的 Rerank 模型见下一节。

**三个关键坑（务必留意）**

| # | 现象 | 根因 | 处理 |
| --- | --- | --- | --- |
| 1 | 创建模型报 `Base URL 未通过安全校验：direct IP address is not allowed` | WeKnora 对模型 Base URL 做 SSRF 校验，默认禁止裸 IP | 在 `/opt/obara/weknora/.env` 追加 `SSRF_WHITELIST_EXTRA=<本机IP>,127.0.0.1,localhost,host.docker.internal,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16`，并 `docker compose up -d --force-recreate app` |
| 2 | 模型状态为 `download_failed` | `source` 填成厂商名（如 `deepseek`）会被判定为"本地模型"并触发 Ollama 下载 | 远程 API 模型的 `source` 必须填 **`remote`**，厂商写在 `provider` 字段 |
| 3 | 新加的 `.env` 变量不生效 | `env_file` 只在**创建容器**时注入，`restart` 不重新读取 | 必须用 `docker compose up -d --force-recreate app`（同上第 1 条） |

> 📌 **更正**：部署记录 3.4 节此前记载"容器内未自动解析 `host.docker.internal`"。本次复核实测**可正常解析**（`docker-compose.yml` 的 `app` 服务已内置 `extra_hosts: host.docker.internal:host-gateway`）。`OLLAMA_BASE_URL` 保持 `http://host.docker.internal:11434` 不变即可工作；表中向量模型行显式填写宿主 IP 仅为与文档口径一致，两者均可达。

> 📌 **关于"默认对话模型"**：WeKnora v0.8.3 的模型记录**没有独立的"设为默认"接口**，`is_default` 字段在建表后基本未被读取。实际的模型绑定发生在阶段六——创建知识库时指定 `embedding_model_id`，创建 Agent 时指定 `chat_model_id`。因此阶段四只需保证模型注册成功且连通，"默认"在阶段六落地。

### 阶段五：部署本地 Rerank 重排服务（推荐启用）

> Ollama 不提供 rerank 能力，需单独起一个本地 rerank 服务容器；**禁止使用公有 rerank API**（检索片段同样属于内部资料，与"数据不出内网"要求冲突）。

**实际选型（2026-10-25 落地）**

| 项 | 选型 | 说明 |
| --- | --- | --- |
| 服务框架 | `michaelf34/infinity:0.0.78-cpu` | 提供 Cohere 兼容的 `/rerank` 接口，与 WeKnora `internal/models/api/cohererank` 完全对齐 |
| 模型 | **`BAAI/bge-reranker-v2-m3`**（568M，fp32） | 榜单 `NDCG@10 0.8075`，中文/英文/日文跨语种能力好 |
| 首选模型未采用的原因 | `Qwen/Qwen3-Reranker-0.6B` | 该镜像内置的 transformers **不识别 `qwen3` 架构**（见部署记录第五章），需等待更新的 infinity 版本 |
| 部署形态 | 独立容器 `weknora-rerank`，端口 `7997` | 权重预先下载到本机目录后**只读挂载**，容器内离线加载，不依赖容器出站网络 |

**一键部署（含注册与验证）**

```bash
sudo bash scripts/deploy/install-rerank.sh                                  # 下载模型 → 起容器 → 注册 → 验证
sudo bash scripts/deploy/install-rerank.sh --no-register                    # 只部署服务
sudo bash scripts/deploy/install-rerank.sh --recreate --cpus 6 --memory 4g  # 调资源限制后重建
```

1. 首次执行需临时出站 HF 权限下载权重（脚本自动选 `hf-mirror.com` → `huggingface.co`，支持断点续传；拉完即收紧）
2. 脚本会把模型注册到 WeKnora（`type=Rerank`、`source=remote`、`provider=generic`、Base URL `http://<本机IP>:7997`），因此仍需保持 `.env` 的 `SSRF_WHITELIST_EXTRA` 含本机 IP
3. 参数按 2.2 节设置；**候选池建议压到 20 条以内**（本机实测见下表），`rerank_top_k=8`
4. 记录开启 / 关闭 rerank 两组 P50 延迟与召回质量差异，作为是否保留的依据

**WeKnora 注册结果**（本次实际）

| 模型 | 类型 | source | provider | Base URL | 状态 |
| --- | --- | --- | --- | --- | --- |
| `bge-reranker-v2-m3` | Rerank | `remote` | `generic` | `http://192.168.227.133:7997` | ✅ active（`/models/{id}/debug` → `ok=true`，1.3 s / 3 条候选） |

**延迟基线**（本机 x86_64 CPU，容器 6 核 / batch 8，含 HTTP 往返）

| 候选片段数 | 端到端耗时 | 折算每条 |
| --- | --- | --- |
| 5 | 1.81 s | 361 ms |
| 10 | 3.91 s | 391 ms |
| **20** | **6.77 s** | 339 ms |
| 30 | 9.78 s | 326 ms |
| 50 | 16.24 s | 325 ms |

> 同样的 2 核配置下吞吐低约 35%（20 条 ~10.3s），说明该服务是**算力敏感**型：扩核即线性提速。
> 若阶段六实测 P50 不可接受，优先把候选池压到 10~20 条，其次给容器加核；二期上 GPU 节点时换 `infinity:0.0.7x` GPU 镜像即可。

**运维要点**

```bash
docker logs -f weknora-rerank                       # 查看加载/推理日志
curl -s http://127.0.0.1:7997/models                # 能力列表（出现 capabilities:["rerank"] 即就绪）
docker stats weknora-rerank                         # 内存占用（实测约 2 GB）
curl -s -X POST http://127.0.0.1:7997/rerank -H 'Content-Type: application/json' \
  -d '{"model":"bge-reranker-v2-m3","query":"电极的使用寿命是多久？","documents":["电极需800小时更换","员工报销流程"]}'
```

> ⚠️ 只探 `/health` 会得到 `{"unix":...}` 的**假就绪**（模型尚未加载完也会返回），就绪判定请以 `/models` 为准。

### 阶段六：知识库初始化与验证

**试点知识库**：焊枪选型知识库（材料见 [`welding-gun-selection-kb/`](welding-gun-selection-kb/welding-gun-kb-overview.md)）

1. 创建知识库「焊枪选型知识库」，Embedding 模型绑定 `bge-m3`
2. 导入 [`welding-gun-selection-kb/01-knowledge-files/`](welding-gun-selection-kb/01-knowledge-files) 下的 **6 个 Excel 文件**（C 枪 3 个 + X 枪 3 个，共 18,701 行）
3. 等待解析、切片、向量化完成
4. 配置答复约束提示词：将 [`welding-gun-selection-prompt.md`](welding-gun-selection-kb/02-answer-prompt/welding-gun-selection-prompt.md) 全部内容粘贴到知识库的「答复约束提示词」面板并保存（需工作空间已配置 KnowledgeQA 模型，如 `deepseek-flash`）
5. 端到端验证：
   - [ ] 6 个 Excel 全部解析成功，行数与清单一致
   - [ ] **枪型路由正确**：C 枪提问只命中 C 文件图号，X 枪提问只命中 X 文件图号
   - [ ] **模糊范围生效**：喉深/喉宽 ±50、加压力 ±500、偏心距离 ±20
   - [ ] **变压器模糊匹配**：输入「85」命中 ITS85，输入「DB6」命中 DB6 / DB6-100R1
   - [ ] **输出格式合规**：仅图号逗号分隔（≤50 个），或「未找到符合要求的焊枪」
   - [ ] 无编造数据，图号均来自文档
   - [ ] 记录首字延迟 / 整体响应时间基线（CPU 环境预期偏慢，仅记录不作为验收项）

---

## 5. 安全与运维

| 事项 | 责任方 | 说明 |
| --- | --- | --- |
| 主机安全基线、漏洞扫描 | 信息课 | — |
| 定时备份（虚机快照 + 数据卷备份） | 信息课 | 至少覆盖 PostgreSQL/ES 数据卷 |
| 监控告警、日志留存审计 | 信息课 | — |
| 镜像版本固定（不使用 latest） | 业务侧 | 升级前通知信息课 |
| 知识库内容审核、涉密禁止上传 | 业务侧 | 敏感资料准入规则与信息课共同确认 |
| API 密钥管控 | 业务侧 | 密钥不落文档、不进代码仓库 |
| 问答日志、上传文件可审计追溯 | 双方 | 问答时仅发送检索片段，非全量文档 |

### 5.1 服务启动与开机自启（8081 门户）

虚拟机重启后无需手工操作：WeKnora 容器由 Docker `restart: unless-stopped` 自动拉起，Ollama 与门户由 systemd 自启，可直接访问 `http://<虚拟机IP>:8081`。

| 服务 | 管理方式 | 开机自启 | 端口 |
| --- | --- | --- | --- |
| WeKnora 五容器 | docker compose | ✅ Docker 服务 enabled + 容器重启策略 | 8088（前端，内部）/ 8080（后端 API） |
| Rerank 独立容器 `weknora-rerank` | `docker run`（非 compose） | ✅ `restart: unless-stopped` | 7997 |
| Ollama | systemd `ollama.service` | ✅ enabled | 11434 |
| 门户 | systemd `obara-portal.service` | ✅ enabled | 8081 |
| 80 端口登录守卫 | systemd `obara-admin-gate.service` | ✅ enabled | 80 → 8088（见 §5.2） |

```bash
# 一键启动全部服务：Ollama → WeKnora 容器（含 Rerank）→ 8081 门户
bash scripts/start-all.sh

# 状态 / 重启 / 停止
bash scripts/start-all.sh status
bash scripts/start-all.sh restart
bash scripts/start-all.sh stop

# 首次安装或仓库目录变更后，安装门户开机自启（幂等）
sudo bash scripts/deploy/install-autostart.sh
sudo bash scripts/deploy/install-autostart.sh --uninstall   # 卸载自启

# 门户日志
journalctl -u obara-portal -f
```

> 注意事项：
> - 门户服务以仓库目录属主身份运行，工作目录为 `portal/`；**移动仓库目录后需重新执行安装脚本**。
> - `start-all.sh stop` 会停止门户与 WeKnora 容器（Ollama 保持运行）；此时重启虚机后容器不会自动回来，需再执行 `bash scripts/start-all.sh`。
> - 若启用 `ufw` 或安全组，需放行 `8081`（门户）、`8080`（后端 API）、`80`（WeKnora 原生后台）。
> - Rerank 容器重启后需约 1～2 分钟加载模型，期间问答可用，重排能力稍后恢复。

### 5.2 端口分工与 80 端口登录守卫

| 端口 | 用途 | 使用对象 |
| --- | --- | --- |
| `80` | WeKnora 原生后台（知识库 / 模型 / 智能体的全量管理） | **仅超级管理员 `admin@obara.local`**，其余账号登录返回 403 |
| `8081` | OBARA 门户（智能问答、对话历史、部门内管理） | 全体员工 |

实现方式：WeKnora 原生前端容器改为监听内部端口 `8088`（`.env` 的 `FRONTEND_PORT`），80 端口由 `obara-admin-gate.service`（`portal/admin_gate.py`）接管并反向代理。网关在登录接口按邮箱白名单拦截，并对携带 Bearer 令牌的 API 请求校验令牌归属邮箱，非白名单一律拒绝，避免拿到令牌后绕过登录页直调原生后台 API。

```bash
# 启用守卫（幂等；会把前端挪到 8088 并安装 systemd 服务）
sudo bash scripts/deploy/enable-admin-gate.sh

# 自定义白名单（逗号分隔）
sudo GATE_ADMIN_EMAILS='admin@obara.local,ops@obara.local' bash scripts/deploy/enable-admin-gate.sh

# 撤除守卫，恢复原生后台直出 80 端口
sudo bash scripts/deploy/enable-admin-gate.sh --disable

# 状态与日志
systemctl status obara-admin-gate
journalctl -u obara-admin-gate -f
```

> 注意：`start-all.sh` 会一并启停该守卫；未安装时自动跳过，80 端口仍由 WeKnora 前端直出。
> 排障时可用 `GATE_ENFORCE=false` 临时把网关降级为透明代理。

### 5.3 对话历史（8081 门户）

门户侧边栏「对话历史」展示**当前登录人本人**的会话记录（`GET /api/v1/sessions` 由后端按 `user_id` 过滤，天然不含他人数据）：

- 左侧会话列表支持按标题搜索，显示更新时间与所用智能体；
- 右侧展示该会话的完整问答（含引用来源与消息时间）；
- 单条会话可删除，「清空全部」走批量删除接口，删除不可恢复。

会话按部门隔离：切换顶栏「当前部门」后列表会重新加载。

### 5.4 平台管理：全员对话 / 文档上传记录（仅超级管理员）

超级管理员在侧边栏「平台管理」下可跨部门查看并管理这两类记录，其余角色看不到该入口：

| 页面 | 内容 | 管理能力 |
| --- | --- | --- |
| 全员对话 | 全体成员在各部门的会话：会话标题、成员、部门、消息数、更新时间 | 查看任一会话的完整问答，**删除违规会话**（软删除，语义同本人删除） |
| 文档上传记录 | 全平台文档上传台账：文件名、上传人及其部门角色、部门、知识库、大小、解析状态、上传时间 | **重解析 / 删除**成员上传的文档（以该文档所属部门的权限执行） |

两页均支持按部门筛选、关键词检索、「只看该成员」下钻与分页，顶部给出「记录数 / 人数 / 占用空间」统计。

数据来源（后端为什么这么做）：WeKnora 原生 `/sessions` 只返回当前用户自己的会话，文档上传人也只存在于 `audit_logs`（对外仅有按部门的 `/tenants/{id}/audit-log`），因此门户以只读 SQL 查询同一 Postgres，与「修改登录邮箱」走同一条通路：

```
GET  /api/v1/portal/admin/conversations                 # 全员会话（可分页、可按部门 / 成员 / 关键词过滤）
GET  /api/v1/portal/admin/conversations/{id}/messages   # 任一成员会话的完整对话
POST /api/v1/portal/admin/conversations                 # 删除会话：{action:"delete", session_id}
GET  /api/v1/portal/admin/uploads                       # 文档上传记录
```

接口一律以 `/auth/me` 的 `is_system_admin` / `can_access_all_tenants` 校验，普通成员调用返回 403。

---

## 6. 实施节奏

| 阶段 | 内容 | 状态 |
| --- | --- | --- |
| 1. 需求评审 & 资源开通 | 方案对齐、虚机开通、网络与账号对接 | ⏳ 进行中（虚机配置已确认） |
| 2. 试点部署与调试 | 系统部署、导入设计规范、权限、RAG、模型连通调试 | ⏳ 进行中（Docker 环境 + WeKnora v0.8.3 + Ollama/`bge-m3` + DeepSeek 对话模型 + 本地 Rerank 服务已完成，见 [`docs/deployment/deployment-log.md`](docs/deployment/deployment-log.md)） |
| 3. 部门灰度试用 | 内部收集反馈、问题整改、安全复测 | ⏸️ 待开始 |
| 4. 试点验收 | 联合信息课评审稳定性、安全、审计能力，出具试点报告 | ⏸️ 待开始 |
| 5. 二期推广 | 评估扩容（含 GPU 推理节点、公有 API 许可），开放至全公司 | ⏸️ 视试点结果 |

> 📌 阶段一～阶段五的交付结果、实测数据与下一步计划汇总见 [`docs/deployment/stage-summary.md`](docs/deployment/stage-summary.md)。

---

## 7. 待确认事项（TODO）

- [x] 虚机内网 IP / 域名 → 已部署机 `192.168.227.133`（VMware NAT）；正式内网域名 / 固定 IP 仍待信息课分配
- [x] Embedding 模型最终选型 → 导库前在 `bge-m3` / `embeddinggemma:300m` 间 A/B 定夺（含跨语种用例），定稿后方可全量导入
- [x] 是否启用本地 Rerank 模型 → **已启用并完成部署**：`bge-reranker-v2-m3`（首选 `Qwen3-Reranker-0.6B` 因服务镜像内置 transformers 不识别 `qwen3` 架构暂不可用）；阶段六按 P50 决定保留与否
- [x] WeKnora 部署端口规划 → 已落地：前端 `80`、后端 `8080`、Ollama `11434`、Rerank 服务 `7997`（均未冲突）
- [x] Embedding 模型就位 → `bge-m3` 已拉取并验证可用（1024 维 / 8192 上下文）；**A/B 定稿（与 `embeddinggemma:300m` 对比）仍需在导库前完成**
- [x] DeepSeek 对话模型配置 → **已完成**：`deepseek-flash`（快速问答）+ `deepseek-v4-pro`（智能推理）均已注册并 `active`，上游调用验证通过；密钥存于服务器 `.secrets/`（不入 Git）
- [ ] 检索参数按 2.2 节落地（chunk_size=1000 / overlap=200 / top_k / threshold），建库时逐项核对
- [ ] SSO / LDAP 对接方案（一期可先用 WeKnora 独立账号，二期对接统一账号）
- [ ] 备份策略细节（频率、保留周期、恢复演练）
- [ ] DeepSeek API 用量预估与审批

---

## 8. 参考链接

- WeKnora 开源地址：https://github.com/Tencent/WeKnora
- WeKnora 官网：https://weknora.weixin.qq.com/
- WeKnora 模型评测榜（Chat / Embed / Rerank）：https://weknora.weixin.qq.com/docs/models
- DeepSeek API 文档（模型名 / 定价）：https://api-docs.deepseek.com/
- Ollama：https://ollama.com/
- DeepSeek 开放平台：https://platform.deepseek.com/

---

## 9. 仓库文件说明

仓库按 **部署流程** 与 **非部署流程** 分目录组织：

```text
obara-weknora-setup/
├── README.md                        # 主文档：方案、部署步骤、验收清单
├── docs/
│   ├── README.md                    # 文档导航（部署文档 / 非部署资料）
│   └── deployment/                  # 【部署流程】执行记录与阶段总结
│       ├── deployment-log.md
│       └── stage-summary.md
├── scripts/
│   ├── README.md                    # 脚本索引（部署 / 非部署 / 运维）
│   ├── portal/                      # 【非部署】门户构建工具（构建版本号打标）
│   ├── start-all.sh                 # 【运维】一键启动/停止/重启全部服务
│   ├── deploy/                      # 【部署流程】阶段一～五环境与组件部署 + 门户开机自启
│   ├── kb/                          # 【非部署】阶段六知识库初始化、验收、数据转换
│   └── docs-site/                   # 【非部署】文档站构建
├── data/                            # 【非部署】多租户部门与人员初始化数据
├── docs/multi-tenant-design.md      # 【非部署】多租户部门隔离方案（16 部门 + 新门户）
├── portal/                          # 【非部署】OBARA 知识问答平台门户（8081）：问答 + 部门/人员/智能体/文档管理
├── welding-gun-selection-kb/        # 【非部署】知识库源数据与答复提示词
├── .github/workflows/docs-site.yml  # 【非部署】文档站自动发布
├── site/                            # 构建产物（自动生成，不入库）
└── LICENSE
```

### 9.1 部署流程文件

| 文件 | 用途 |
| --- | --- |
| `README.md` | 部署方案、实施计划与验收清单（本文件） |
| `docs/deployment/deployment-log.md` | 阶段一～六的**实际执行记录**：环境基线、具体命令、踩坑根因、验证结果、运维与备份手册 |
| `docs/deployment/stage-summary.md` | 阶段一～六的**精简阶段总结**（进度、交付结果、实测数据、下一步与遗留事项），适合汇报与交接 |
| `scripts/README.md` | 脚本索引：部署脚本的使用前提、执行步骤与常见问题 |
| `scripts/deploy/install-docker.sh` | 一键安装 Docker CE + Compose 插件，配置镜像加速器、日志轮转并验证 |
| `scripts/deploy/fix-docker-env.sh` | 修复 APT 源域名、重新探测加速器、重启 Docker 使 `daemon.json` 生效 |
| `scripts/deploy/configure-mirrors.sh` | 国内镜像加速器自动探测与配置（默认只写配置，`--apply` 重启生效） |
| `scripts/deploy/install-ollama.sh` | 阶段三：安装 Ollama 服务（systemd）并拉取 Embedding 模型，内置多下载源回退 |
| `scripts/deploy/configure-deepseek.sh` | 阶段四：注册 DeepSeek 对话模型（快速问答 / 智能推理）与本地 Ollama 向量模型，并做上游连通性验证 |
| `scripts/deploy/install-rerank.sh` | 阶段五：部署本地 Rerank 服务（infinity + `bge-reranker-v2-m3`）并注册到 WeKnora |
| `scripts/deploy/install-autostart.sh` | 安装/卸载门户（8081）systemd 开机自启，并确认 Docker、Ollama 自启（幂等） |

### 9.2 非部署流程文件

| 文件 | 用途 |
| --- | --- |
| `scripts/multi-tenant/init-tenants.sh` | 多租户初始化：一键创建 16 个部门工作空间 + 批量接入成员（全部为 Contributor，不设默认管理员，Owner 由超管事后手动指派） |
| `data/departments-personnel.json` | 16 个部门（NJG×9 + SHA×7）及全部人员清单（仅邮箱与用户名，无管理员标记） |
| `docs/multi-tenant-design.md` | 多租户部门隔离方案：组织映射、隔离机制、邀请流程、新门户设计与部署步骤 |
| `portal/index.html` / `styles.css` / `app.js` | OBARA 知识问答平台门户（8081）前端：问答 + 部门/人员/智能体/文档管理（人员/智能体/文档仅 Owner 可见） |
| `portal/server.py` | 门户 HTTP 服务 + `/api/*` 反向代理到 WeKnora 后端（解决 CORS），并对管理类写操作做 Owner 二次鉴权 |
| `portal/start.sh` | 门户启动脚本（支持 `--port` / `--upstream` / `--daemon`），启动时自动执行构建版本号打标 |
| `scripts/portal/build-version.py` | 门户构建版本号打标：左下角「当前版本 YY-MM-DD」，当天多次构建追加 `-V2`/`-V3`（`--check` 只看不写） |
| `scripts/kb/init-welding-gun-kb.sh` | 阶段六：建库 + 绑定模型 + 导入文档 + 创建受管智能体 + 写入检索参数（幂等，支持 `--no-wait` / `--pause` / `--resume` / `--status`） |
| `scripts/kb/verify-welding-gun-kb.sh` | 阶段六：端到端验收，抽取真实记录自动生成提问并核对图号 |
| `scripts/kb/build-flat-kb.py` | 阶段六：把宽表重建为「一行一段」自然语言短句，规避 `num_ctx=511` 截断 |
| `scripts/docs-site/build-docs-site.py` | 文档站生成器：扫描仓库内 Markdown → 渲染为单页静态站点（输出到 `site/`） |
| `scripts/docs-site/docs-site-template.html` | 文档站页面模板（侧栏导航、页内目录、深浅色主题） |
| `welding-gun-selection-kb/` | 知识库源数据：6 个 Excel、答复约束提示词与概览（扁平知识文件由 `build-flat-kb.py` 生成，不入库） |
| `.github/workflows/docs-site.yml` | GitHub Actions：文档变更时自动构建文档站并发布到 GitHub Pages |
| `site/` | 构建产物（自动生成，**不入库**） |
| `LICENSE` | MIT 开源协议 |

脚本速查：

```bash
sudo bash scripts/deploy/install-docker.sh      # 首次安装
sudo bash scripts/deploy/fix-docker-env.sh      # 配置未生效 / 源或加速器异常
sudo bash scripts/deploy/configure-mirrors.sh   # 重新探测国内镜像加速器并写入配置
sudo bash scripts/deploy/install-ollama.sh      # 安装 Ollama 并拉取向量模型（阶段三）
sudo DEEPSEEK_API_KEY='sk-xxxxx' bash scripts/deploy/configure-deepseek.sh   # 配置对话模型（阶段四）
sudo bash scripts/deploy/install-autostart.sh   # 安装门户（8081）开机自启
bash scripts/start-all.sh                       # 一键启动全部服务
```

### 9.3 运维脚本（启动 / 自启）

| 文件 | 用途 |
| --- | --- |
| `scripts/deploy/install-autostart.sh` | 安装/卸载门户（8081）systemd 开机自启，并确认 `docker`、`ollama` 已启用（幂等） |
| `scripts/start-all.sh` | 一键启动全部服务：Ollama → WeKnora 容器（含独立 Rerank 容器）→ 8081 门户；自动等待 8080 健康检查并输出访问地址，支持 `start / status / restart / stop` |

```bash
# 首次安装或仓库目录变更后执行
sudo bash scripts/deploy/install-autostart.sh
sudo bash scripts/deploy/install-autostart.sh --uninstall   # 卸载自启

# 日常运维
bash scripts/start-all.sh            # 启动全部（默认）
bash scripts/start-all.sh status     # 状态与健康检查
bash scripts/start-all.sh restart    # 重启全部
bash scripts/start-all.sh stop       # 停止门户与 WeKnora 容器（Ollama 保持运行）
```

> `start-all.sh` 支持环境变量 `WEKNORA_DIR`（默认 `/opt/obara/weknora`）、`PORTAL_PORT`（默认 `8081`）、`WEKNORA_URL`（默认 `http://127.0.0.1:8080`）。

### 9.4 文档站自动生成

仓库内所有 Markdown（含 `README.md`、`docs/`、`scripts/`、`welding-gun-selection-kb/` 等任意目录下的 `.md`）会由 GitHub Actions 汇总成一个单页文档站：

- **触发时机**：任意 `.md` 文档发生变更并推送到 `main` 时自动重建；也可在 Actions 页面手动触发（另设每周一兜底重建）。Pull Request 只构建校验，不发布。
- **发布位置**：GitHub Pages，地址 <https://caifugao110.github.io/obara-weknora-setup/>（首次需在仓库 *Settings → Pages → Build and deployment* 把 Source 设为 **GitHub Actions**）。
- **页面能力**：左侧分组目录、右侧页内目录滚动高亮、代码高亮与一键复制、深浅色主题（`T` 切换）、响应式与打印友好；文档内的 `.md` 互链自动转成站内跳转，支持 `#/docs/xxx.md` 深链。

本地预览 / 调试：

```bash
pip install markdown Pygments
python3 scripts/docs-site/build-docs-site.py  # 生成到 ./site
python3 -m http.server 8000 -d site           # 打开 http://localhost:8000
```

常用参数：`--output public`（改输出目录）、`--exclude scripts`（排除某批文档）、`--title "XX 文档中心"`（改站点标题）。

---

## 10. 开源协议

本项目以 [MIT License](LICENSE) 开源发布，© 2026 TOBIN。

---

*最后更新：2026-10-25*
