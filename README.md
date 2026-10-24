# OBARA 知识库系统（WeKnora）部署指南

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
| 重排模型（Rerank） | **启用**：本地 `Qwen/Qwen3-Reranker-0.6B`（首选）或 `BAAI/bge-reranker-v2-m3`（备选） | 榜单显示精排可将 `NDCG@10` 由 0.8011 提升至 0.8361（+4.4%），弱 Embedding 收益更大。Ollama **不提供** rerank 能力，需单独起本地 rerank 服务容器（见阶段五）；**禁用公有 rerank API** |

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

### 3.2 网络策略（信息课侧）

- [ ] 内网网段部署，分配内网域名 / IP
- [ ] 端口访问管控，不直接暴露公网
- [ ] 临时出站权限：HuggingFace / Ollama 模型下载源（拉取完成后可收紧）
- [ ] DeepSeek API 出站白名单（`api.deepseek.com`）
- [ ] 公司代理（如有）：内网访问 HuggingFace 可走 `127.0.0.1:7897` 类代理，需在 Docker/系统层面配置

---

## 4. 部署步骤

> 以下为整体流程概览，每一步的详细操作将在后续章节/文档中补充完善。

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
sudo bash scripts/install-docker.sh

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
sudo bash scripts/fix-docker-env.sh
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

### 阶段三：部署本地向量模型（Ollama）

```bash
# 1. 安装 Ollama（或以容器方式运行）
curl -fsSL https://ollama.com/install.sh | sh

# 2. 拉取两个候选向量模型（均为小模型，8 核 CPU 可跑）
ollama pull bge-m3                  # 1024 维 / 8K 上下文 / 100+ 语种，跨语种检索强
ollama pull embeddinggemma:300m     # 768 维 / 2K 上下文，榜单 NDCG@10 更高、更省资源

# 3. 验证
ollama list
curl http://localhost:11434/api/embeddings -d '{"model":"bge-m3","prompt":"测试"}'
```

> 选型依据见 2.1 节；`nomic-embed-text`（768 维）中文效果偏弱，`bge-large-zh-v1.5` 仅支持 512 token 且仅中文，均不采用。

**⚠️ 导库前必须完成 A/B 定稿（换 Embedding = 全量重向量化，代价高）**

1. 建两个测试知识库（如 `AB-bge-m3`、`AB-gemma300m`），分别绑定不同 Embedding 模型
2. 导入同一批 20~30 份真实规范文档，`chunk_size` / `chunk_overlap` 按 2.2 节设为一致
3. 用同一组真实问题评测，**必须包含"中文提问命中英文/日文原版规范"的跨语种用例**
4. 判定：中文为主且跨语种差异不明显 → 选 `embeddinggemma:300m`；跨语种召回 `bge-m3` 明显占优 → 保留 `bge-m3`，并走"大 `embedding_top_k` + rerank"路线
5. 定稿后再导入全量文档，避免二次重建索引

### 阶段四：配置 DeepSeek 对话模型

1. 在 WeKnora 管理后台 → 模型管理，添加模型供应商
2. 类型选择 OpenAI 兼容 API，填入：
   - API Base：`https://api.deepseek.com`（Anthropic 格式可用 `https://api.deepseek.com/anthropic`）
   - API Key：DeepSeek 密钥（**密钥仅存服务器 `.env` 或后台，不入 Git、不入文档**）
   - 模型名：
     - 快速问答模式 → **`deepseek-flash`**（即 DeepSeek-V4.1-Flash，榜单智能推理 #5 / 快速问答 #5）
     - 智能推理模式 → **`deepseek-v4-pro`**（复杂多跳问题）

   > ⚠️ 旧模型名 `deepseek-chat`（V3 系列）已过时，不要再填；`deepseek-v4-flash`、`deepseek-v4-flash-vision-exp` 等旧别名对应模型已下线。
3. 连通性测试通过后，把 `deepseek-flash` 设为默认对话模型；简单问题走"快速问答"、复杂问题走"智能推理"
4. Embedding 模型选择阶段三 A/B 定稿的 Ollama 本地模型（地址 `http://<本机IP>:11434`）

### 阶段五：部署本地 Rerank 重排服务（推荐启用）

> Ollama 不提供 rerank 能力，需单独起一个本地 rerank 服务容器；**禁止使用公有 rerank API**（检索片段同样属于内部资料，与"数据不出内网"要求冲突）。

```bash
# 以 infinity 为例（OpenAI 兼容 /rerank 接口，CPU 可跑 0.6B 级模型）
docker run -d --name rerank -p 7997:7997 \
  michaelfeil/infinity:<固定版本tag> \
  --model Qwen/Qwen3-Reranker-0.6B --port 7997

# 备选：BAAI/bge-reranker-v2-m3（568M，社区验证最多，榜单 NDCG@10 0.8075）
```

1. 首次拉取模型需临时出站 HF 权限（同 3.2 节网络策略，拉完收紧）
2. WeKnora 管理后台 → Rerank 配置：勾选"启用 Rerank 重排模型"，Base URL 填 `http://<本机IP>:7997`，模型名填实际加载的模型
3. 参数按 2.2 节设置；若 CPU 延迟不可接受，先把候选池压到 20~30、`rerank_top_k=8`
4. 记录开启 / 关闭 rerank 两组 P50 延迟与召回质量差异，作为是否保留的依据

### 阶段六：知识库初始化与验证

1. 创建首个知识库（如"设计规范库"）
2. 导入试点文档（如《电极使用规范.pdf》等技术开发二部常用规范）
3. 等待解析、切片、向量化完成
4. 创建自定义 Agent（system_prompt 按知识库逐个配置，完全覆盖默认提示词）
5. 端到端验证：
   - [ ] 文档解析正确（表格、图片、标题层级）
   - [ ] 语义检索召回准确，答案带溯源引用
   - [ ] **跨语种检索**：中文提问能命中英文 / 日文原版规范（本项目关键验收点）
   - [ ] 跨文档问答表现可接受
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

---

## 6. 实施节奏

| 阶段 | 内容 | 状态 |
| --- | --- | --- |
| 1. 需求评审 & 资源开通 | 方案对齐、虚机开通、网络与账号对接 | ⏳ 进行中（虚机配置已确认） |
| 2. 试点部署与调试 | 系统部署、导入设计规范、权限、RAG、模型连通调试 | ⏸️ 待开始 |
| 3. 部门灰度试用 | 内部收集反馈、问题整改、安全复测 | ⏸️ 待开始 |
| 4. 试点验收 | 联合信息课评审稳定性、安全、审计能力，出具试点报告 | ⏸️ 待开始 |
| 5. 二期推广 | 评估扩容（含 GPU 推理节点、公有 API 许可），开放至全公司 | ⏸️ 视试点结果 |

---

## 7. 待确认事项（TODO）

- [ ] 虚机内网 IP / 域名（信息课分配后填入本文档）
- [x] Embedding 模型最终选型 → 导库前在 `bge-m3` / `embeddinggemma:300m` 间 A/B 定夺（含跨语种用例），定稿后方可全量导入
- [x] 是否启用本地 Rerank 模型 → **启用**，本地部署 `Qwen3-Reranker-0.6B`；CPU 延迟超标再评估关闭或换 `bge-reranker-v2-m3`
- [ ] WeKnora 部署端口规划（避免与内网已占用端口冲突，需预留 rerank 服务端口）
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

| 文件 | 用途 |
| --- | --- |
| `README.md` | 部署方案、实施计划与验收清单（本文件） |
| `scripts/install-docker.sh` | 一键安装 Docker CE + Compose 插件，配置镜像加速器、日志轮转并验证 |
| `scripts/fix-docker-env.sh` | 修复 APT 源域名、重新探测加速器、重启 Docker 使 `daemon.json` 生效 |
| `scripts/README.md` | 脚本的使用前提、执行步骤与常见问题 |
| `LICENSE` | MIT 开源协议 |

脚本速查：

```bash
sudo bash scripts/install-docker.sh   # 首次安装
sudo bash scripts/fix-docker-env.sh   # 配置未生效 / 源或加速器异常
```

---

## 10. 开源协议

本项目以 [MIT License](LICENSE) 开源发布，© 2026 TOBIN。

---

*最后更新：2026-10-24*
