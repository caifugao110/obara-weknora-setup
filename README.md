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
│  │  虚拟机 OBARA-WeKnora（Ubuntu 22.04 LTS）        │      │
│  │  8 vCPU / 32GB RAM / 500GB SSD                 │      │
│  │                                               │      │
│  │  ┌─────────────────────────────────────────┐  │      │
│  │  │  Docker 环境                            │  │      │
│  │  │  ├─ WeKnora 全套容器（Web/后端/中间件）    │  │      │
│  │  │  ├─ Ollama（本地向量模型 Embedding）       │  │      │
│  │  │  └─ Rerank（可选，本地重排模型）           │  │      │
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

| 用途 | 方案 | 说明 |
| --- | --- | --- |
| 向量模型（Embedding） | **本地 Ollama：`bge-m3`** | 567M / 1024 维 / 8K 上下文；支持 100+ 语种（中英日西德俄法等），跨语种检索强，无需指令前缀 |
| 对话模型（LLM） | **DeepSeek API** | 纯 CPU 本地推理过慢，对话走 API 保证可用性；问答时仅发送检索片段 |
| 重排模型（Rerank，可选） | 本地 Ollama | 提升检索精度，视资源情况决定是否启用 |

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
| 操作系统 | Ubuntu 22.04 LTS | 预装 Docker 环境 |
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
2. 安装 Ubuntu 22.04 LTS Server
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

```bash
# 安装 Docker（官方源）
curl -fsSL https://get.docker.com | sh
sudo systemctl enable --now docker

# 可选：配置国内镜像加速器（内网拉取镜像更稳）
sudo mkdir -p /etc/docker
# 编辑 /etc/docker/daemon.json 配置 registry-mirrors
sudo systemctl restart docker
```

#### 1.3 安装部署辅助 AI Agent（可选）

在虚机上安装 AI Agent 辅助部署与排障，下载安装包复制到虚拟机后在相应目录执行：

| 工具 | 下载地址 | 安装命令 |
| --- | --- | --- |
| Trae | https://www.trae.cn/download | `sudo dpkg -i TRAE_CN-linux-x64.deb` |
| CodeBuddy | https://www.codebuddy.cn/ide/#download-section | `sudo dpkg -i CodeBuddy-linux-x64.deb` |
| WorkBuddy | 暂无官方 Linux 包，社区打包方案：[xingwangzhe.fun/posts/workbuddy-linux-deb-rpm](https://xingwangzhe.fun/posts/workbuddy-linux-deb-rpm/) | `sudo dpkg -i WorkBuddy-linux-x64.deb` |

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

# 2. 拉取向量模型（Embedding 模型体积小，8 核 CPU 即可满足）
ollama pull bge-m3                  # 选型结论：1024 维，8K 上下文，中文效果好

# 3. 验证
ollama list
curl http://localhost:11434/api/embeddings -d '{"model":"bge-m3","prompt":"测试"}'
```

> 选型依据见 2.1 节；`nomic-embed-text`（768 维）中文效果偏弱，`bge-large-zh-v1.5` 仅支持 512 token 且仅中文，均不采用。

### 阶段四：配置 DeepSeek 对话模型

1. 在 WeKnora 管理后台 → 模型管理，添加模型供应商
2. 类型选择 OpenAI 兼容 API，填入：
   - API Base：`https://api.deepseek.com`
   - API Key：DeepSeek 密钥（**密钥仅存服务器 `.env` 或后台，不入 Git、不入文档**）
   - 模型名：`deepseek-chat`（V3 系列）
3. 连通性测试通过后，设为默认对话模型
4. Embedding 模型选择 Ollama 本地模型（地址 `http://<本机IP>:11434`）

### 阶段五：知识库初始化与验证

1. 创建首个知识库（如"设计规范库"）
2. 导入试点文档（如《电极使用规范.pdf》等技术开发二部常用规范）
3. 等待解析、切片、向量化完成
4. 创建自定义 Agent（system_prompt 按知识库逐个配置，完全覆盖默认提示词）
5. 端到端验证：
   - [ ] 文档解析正确（表格、图片、标题层级）
   - [ ] 语义检索召回准确，答案带溯源引用
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
- [x] Embedding 模型最终选型 → **`bge-m3`**（1024 维）
- [ ] WeKnora 部署端口规划（避免与内网已占用端口冲突）
- [ ] 是否启用本地 Rerank 模型
- [ ] SSO / LDAP 对接方案（一期可先用 WeKnora 独立账号，二期对接统一账号）
- [ ] 备份策略细节（频率、保留周期、恢复演练）
- [ ] DeepSeek API 用量预估与审批

---

## 8. 参考链接

- WeKnora 开源地址：https://github.com/Tencent/WeKnora
- WeKnora 官网：https://weknora.weixin.qq.com/
- Ollama：https://ollama.com/
- DeepSeek 开放平台：https://platform.deepseek.com/

---

## 9. 开源协议

本项目以 [MIT License](LICENSE) 开源发布，© 2026 TOBIN。

---

*最后更新：2026-10-24*
