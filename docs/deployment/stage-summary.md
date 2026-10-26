# OBARA 知识库系统 — 阶段总结（截至 2026-10-25）

> 面向汇报与交接的**精简阶段总结**，覆盖已完成的阶段一～阶段五。
> 命令级执行细节见 [`docs/deployment-log.md`](deployment-log.md)，完整方案与验收清单见顶层 [`README.md`](../../README.md)。
>
> 最后更新：2026-10-26（新增门户开机自启与一键启停）

---

## 1. 总体进度

```text
[✅] 阶段一  虚机与 Docker 环境        —— 完成
[✅] 阶段二  WeKnora v0.8.3 部署       —— 完成
[✅] 阶段三  Ollama + 本地向量模型      —— 完成（服务与模型可用，A/B 定稿待导库前完成）
[✅] 阶段四  DeepSeek 对话模型配置      —— 完成
[✅] 阶段五  本地 Rerank 重排服务       —— 完成（服务 + 注册 + 端到端验证通过）
[🔄] 阶段六  知识库初始化与验收         —— 链路已通；扁平格式重导待决策
[✅] 运维    门户开机自启与一键启停      —— 完成（8081 已 enabled，重启后自动恢复）
```

| 阶段 | 交付结果 | 状态 |
| --- | --- | --- |
| 一、Docker 环境 | Docker CE 28.1.1 + Compose v2.35.1，`overlay2` + systemd cgroup，四组镜像加速器，日志轮转 100m×3 | ✅ |
| 二、WeKnora | `v0.8.3` 五容器运行（app / frontend / docreader / postgres / redis），健康检查 `{"status":"ok"}` | ✅ |
| 三、Ollama | `0.17.5` systemd 服务，`bge-m3` 1024 维向量可用，容器到宿主连通已验证 | ✅ |
| 四、DeepSeek | `deepseek-flash`（快速问答）+ `deepseek-v4-pro`（智能推理）已注册且 `active`，上游调用验证通过；Embedding 指向本机 `bge-m3` | ✅ |
| 五、Rerank | `infinity 0.0.78-cpu` 容器 `weknora-rerank`（7997）+ `bge-reranker-v2-m3`，已注册且端到端调用通过（`ok=true`，1.3s / 3 条候选） | ✅ |
| 六、知识库 | 知识库与「焊枪选型助手」智能体已建好并完成端到端验收（随机抽样 10/10、延迟 20 s）；发现 `num_ctx=511` 截断缺陷，已给出扁平重导方案，全量导入待决策 | 🔄 |
| 运维、启动 | 门户（8081）已安装 `obara-portal.service` 开机自启；新增 `start-all.sh` 一键启停；虚机重启后 Ollama / WeKnora / Rerank / 门户自动恢复 | ✅ |

---

## 2. 阶段一：虚机与 Docker 环境

**环境基线**：Ubuntu 22.04.5 LTS / x86_64

| 组件 | 版本 |
| --- | --- |
| docker-ce | 5:28.1.1 |
| containerd.io | 1.7.27 |
| docker-compose-plugin | 2.35.1 |
| storage-driver / cgroup | overlay2 / systemd |

**关键处置**：`daemon.json` 配置多加速器降级、`live-restore`、`max-concurrent-downloads: 16`（单流限速 200KB/s → 多流约 2.5MB/s）；普通用户免 sudo；`hello-world` 拉取通过。

**交付脚本**：`scripts/deploy/install-docker.sh`、`scripts/deploy/fix-docker-env.sh`、`scripts/deploy/configure-mirrors.sh`

---

## 3. 阶段二：WeKnora v0.8.3

| 项 | 结果 |
| --- | --- |
| 源码目录 | `/opt/obara/weknora`（Tag `v0.8.3`，commit `3e22822`） |
| 镜像本地化 | `weknora-app`、`weknora-docreader`、`paradedb`、`weknora-ui`、`redis` 共 5 个（约 6.7 GB） |
| 运行容器 | `WeKnora-app`、`WeKnora-frontend`、`WeKnora-docreader`、`WeKnora-postgres`、`WeKnora-redis` |
| 端口 | 前端 `80`、后端 `8080` |
| 健康检查 | `curl http://localhost:8080/health` → `{"status":"ok"}` |
| 存储 | `STORAGE_TYPE=local`，数据卷 `postgres-data` / `data-files` / `docreader-tmp` |

---

## 4. 阶段三：Ollama + 本地向量模型

| 项 | 结果 |
| --- | --- |
| Ollama 版本 | `0.17.5`，原生 systemd 服务（`active` + `enabled`） |
| 监听 / 模型目录 | `0.0.0.0:11434` / `/opt/ollama/models` |
| 向量模型 | `bge-m3:latest` 1.2 GB（566.70M 参数 / 8192 上下文 / **1024 维** / F16 / `embedding`） |
| 调用延迟 | 单条短句 **0.34 ~ 0.45 s**（热模型，纯 CPU） |
| 容器连通性 | WeKnora-app 内 `curl http://192.168.227.133:11434/api/version` → `{"version":"0.17.5"}` |

**跨语种能力实测**（余弦相似度，本项目关键验收前提）

| 句对 | 相似度 |
| --- | --- |
| 中「电极的使用寿命是多久？」↔ 日「電極の使用寿命は…」 | **0.9578** |
| 中 ↔ 英「What is the service life of the electrode?」 | **0.7291** |
| 中 ↔ 中「员工报销流程管理办法」（无关句） | 0.3192 |

> 跨语种（0.73~0.96）与无关句（0.32）区分度明显，`bge-m3` 满足"中文提问命中英文/日文原版规范"的要求。

**交付脚本**：`scripts/deploy/install-ollama.sh`（幂等，多下载源自动回退）

---

## 5. 阶段四：DeepSeek 对话模型配置

**执行日期**：2026-10-25

| 项 | 结果 |
| --- | --- |
| 供应商 | `deepseek`（底层 `api=openai-completions`，即 OpenAI 兼容） |
| API Base | `https://api.deepseek.com/v1` |
| 快速问答模型 | `deepseek-flash`（DeepSeek-V4.1-Flash，榜单智能推理 #5 / 快速问答 #5） |
| 智能推理模型 | `deepseek-v4-pro` |
| 向量模型 | `bge-m3`（`source=local`，指向本机 Ollama，1024 维） |
| 模型状态 | 三个均 `active` |
| 密钥存放 | `/opt/obara/weknora/.secrets/deepseek.env`（700/600，属主 root），库中为 AES 加密密文 |
| 上游验证 | `deepseek-flash` 0.99~1.47s、`deepseek-v4-pro` 1.23~1.40s、`bge-m3` 0.48~6.93s（冷加载） |
| 交付脚本 | `scripts/deploy/configure-deepseek.sh`（幂等） |

**三个关键坑**

| # | 现象 | 根因 / 处理 |
| --- | --- | --- |
| 1 | `Base URL 未通过安全校验：direct IP address is not allowed` | SSRF 校验禁裸 IP → `.env` 追加 `SSRF_WHITELIST_EXTRA=<本机IP>,127.0.0.1,localhost,host.docker.internal,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16` |
| 2 | 模型状态 `download_failed` | `source` 填厂商名会走"本地模型"分支触发 Ollama 下载 → 远程 API 必须填 `source=remote`，厂商填 `provider` |
| 3 | `.env` 新变量不生效 | `env_file` 仅建容器时注入 → 用 `docker compose up -d --force-recreate app` |

**两个更正 / 结论**

- **更正**：此前记录"容器内未自动解析 `host.docker.internal`"有误。实测可正常解析（`docker-compose.yml` 的 `app` 服务已内置 `extra_hosts`），`OLLAMA_BASE_URL` 保持默认即可，无需改动。
- **结论**：v0.8.3 的模型记录**没有独立的"设为默认"接口**，`is_default` 字段运行时不参与选择。模型绑定实际发生在阶段六（知识库绑 `embedding_model_id`、Agent 绑 `chat_model_id`）。阶段四只需保证注册成功且连通。

---

## 6. 阶段五：本地 Rerank 重排服务

**执行日期**：2026-10-25（期间虚机由 4 核 / 8GB 扩容为 12 核 / 15GB）

| 项 | 结果 |
| --- | --- |
| 服务框架 | `michaelf34/infinity:0.0.78-cpu`（Cohere 兼容 `/rerank`，与 WeKnora 默认协议完全对齐） |
| 模型 | `BAAI/bge-reranker-v2-m3`（568M 参数 / fp32 / 榜单 `NDCG@10` 0.8075） |
| 容器 / 端口 | `weknora-rerank`，`7997`，`--cpus 6 --memory 4g --batch-size 8`，常驻约 2 GB |
| 权重目录 | `/opt/obara/rerank-models/models/bge-reranker-v2-m3`（2.2 GB，只读挂载 + 离线加载） |
| WeKnora 注册 | `bge-reranker-v2-m3`：`type=Rerank` / `source=remote` / `provider=generic`，`active` |
| 端到端验证 | `/models/{id}/debug` → `ok=true`，1.3 s（3 条候选） |
| 交付脚本 | `scripts/deploy/install-rerank.sh`（幂等、可断点续传、可重复执行） |

**排序质量**（中文查询「电极的使用寿命是多久？」）：相关片段 **0.9926** > 英文相关 0.6336 > 无关句 **0.0000**；候选池扩到 50 条时 Top1 仍稳定命中相关片段。

**延迟基线**（6 核 / batch 8）：10 条 3.9 s、**20 条 6.8 s**、30 条 9.8 s、50 条 16.2 s（约 0.33 s/条；同为 2 核时慢约 35%）。
→ **阶段六建议：候选池 ≤ 20、`rerank_top_k=8`**。

**三个关键决策**：

1. 首选的 `Qwen3-Reranker-0.6B` **暂不可用**：镜像内置 transformers 不识别 `qwen3` 架构，而加速器上该镜像最高只到 `0.0.78-cpu`
2. ONNX（optimum）加速路线**暂不可用**：v2-m3 仓库无 ONNX 文件；改用自带 ONNX 的 `bge-reranker-base` 则反复重启无法就绪
3. 权重改为**宿主机预下载 + 只读挂载**，避免容器重建重复下载（约 2.2 GB / 每次 5 分钟）

---

## 7. 交付资产清单

| 文件 | 用途 |
| --- | --- |
| `scripts/deploy/install-docker.sh` | 阶段一：Docker CE + Compose 安装与调优 |
| `scripts/deploy/fix-docker-env.sh` | 阶段一：APT 源 / daemon 配置 / 加速器修复 |
| `scripts/deploy/configure-mirrors.sh` | 阶段一：镜像加速器自动探测 |
| `scripts/deploy/install-ollama.sh` | 阶段三：Ollama 服务安装 + Embedding 模型拉取 |
| `scripts/deploy/configure-deepseek.sh` | 阶段四：注册 DeepSeek 对话模型与本地 Ollama 向量模型，并做上游连通性验证（幂等） |
| `scripts/deploy/install-rerank.sh` | 阶段五：部署本地 Rerank 服务容器（infinity）并注册到 WeKnora，含权重下载、就绪判定与端到端验证（幂等） |
| `scripts/deploy/install-autostart.sh` | 运维：安装/卸载门户（8081）systemd 开机自启，并确认 Docker、Ollama 自启（幂等） |
| `scripts/start-all.sh` | 运维：一键启动/停止/重启/查看全部服务（Ollama + WeKnora 容器 + Rerank + 门户），含健康检查 |
| `scripts/kb/init-welding-gun-kb.sh` | 阶段六：建库 + 绑定模型 + 导入文档 + 创建受管智能体 + 写入检索参数（幂等，支持 `--no-wait` / `--status`） |
| `scripts/kb/verify-welding-gun-kb.sh` | 阶段六：端到端验收，抽取真实记录自动生成提问并按容差规则回溯校验答案 |
| `scripts/kb/build-flat-kb.py` | 阶段六：把宽表重建为"一行一段"自然语言短句，消除 `num_ctx=511` 截断 |
| `docs/deployment/deployment-log.md` | 各阶段的实际执行记录、踩坑与运维手册 |
| `docs/deployment/stage-summary.md` | 本文件：阶段精简总结 |

**服务启动与自启**：虚拟机重启后，Docker 按 `restart: unless-stopped` 拉起 WeKnora 容器（含 `weknora-rerank`），Ollama 与门户 `obara-portal.service` 由 systemd 自启，直接访问 `http://<虚拟机IP>:8081`；日常可用 `bash scripts/start-all.sh` 一键启停。详见 README §5.1 与 [`deployment-log.md`](deployment-log.md) §七之三。

---

## 8. 阶段六：知识库初始化与小样本验收

**执行日期**：2026-10-25

| 项 | 结果 |
| --- | --- |
| 知识库 | `焊枪选型知识库`，绑定 `bge-m3`；检索参数 `embedding_top_k=20 / rerank_top_k=8 / rerank_threshold=0.3 / vector_threshold=0.15` |
| 智能体 | `焊枪选型助手`，绑定 `deepseek-flash` + `bge-reranker-v2-m3`，答复约束提示词注入 `system_prompt` |
| 已解析 | `X2C-V3-C`、`X2C-V3-X` 完成；`X2C-V2-C`、`X2C-V2-X`、`X2C-C`、`X2C-X` 四个已暂停（`scripts/kb/init-welding-gun-kb.sh --pause`），文件保留，随时 `--resume` 恢复 |

**阻塞性质量问题：`num_ctx=511` 截断**

| 指标 | 数值 |
| --- | --- |
| Excel 分片平均长度 | 745 字符 |
| 超过 511 字符的比例 | 99.9% |
| 「图号」落在分片的位置 | 第 562 字符 |

`bge-m3` 只取前 511 token，**图号等数据字段几乎全部没进向量**；用图号本身检索，Top4 全是别的图号。

**A/B 验收（数据集 X2C-V3-C，148 条真实记录）**

| 知识表示 | 分片长度 | 随机抽样正确率 | 固定 5 题 | 平均延迟 |
| --- | --- | --- | --- | --- |
| Excel → Markdown 表格 | 745 字符（99.9% 截断） | 11/13 = 85% | 5/5 | 36 s |
| 一行一段「字段：值」 | ≤ 351 字符（不截断） | **10/10 = 100%** | 5/5 | **20 s** |

失败用例根因是**候选集漏召**（正确记录未进入 Top-N），不是模型编造；答案的图号本身真实存在且客户名匹配。
扁平行把端到端延迟压低约 45%，且彻底消除截断隐患，**推荐按扁平格式全量重导**。

详细过程、踩坑与命令见 [`docs/deployment-log.md`](deployment-log.md) 第六章。

---

## 9. 下一步计划

| 顺序 | 事项 | 说明 |
| --- | --- | --- |
| 1 | **扁平格式全量重导**（暂缓，数据已就绪） | `03-flat-knowledge/*.md`（18,689 行）随时可用，决定先用表格原样；需要时按 `docs/deployment/deployment-log.md` §6.6 的命令重建新库即可，现有库保留做对照 |
| 2 | Embedding A/B 定稿 | 若后续要换 Embedding 需全量重向量化，务必在重导前定稿；现阶段继续沿用 `bge-m3` |
| 3 | 扩大验收样本 | 全量导入后按 `--cases 20` 以上规模复验，并补"跨枪型不串台""无匹配时输出提示"两类边界用例 |
| 4 | Rerank 保留与否的决策 | 记录"开 / 关 rerank"两组的 P50 与召回质量差异；当前扁平库延迟已降到 20 s，可先压候选池观察 |

---

## 10. 遗留事项

- [ ] **Embedding A/B 定稿**（阻塞全量导库）
- [ ] **修改初始管理员密码**：阶段五为自动化注册在库内重置为 `Ob@raxGUgbyGr`，**需改为团队内部凭据并妥善保管**
- [ ] 检索参数按方案 2.2 节落地：`chunk_size=1000` / `overlap=200` / `top_k` / `vector_threshold` 需在真实召回中复核
- [ ] DeepSeek API 用量预估与审批
- [ ] 备份策略细节：频率、保留周期、**恢复演练**（重点含 `.env` 的 `SYSTEM_AES_KEY` 与数据卷）
- [ ] SSO / LDAP 对接方案（一期可先用 WeKnora 独立账号）
- [ ] 试点结束后安全回收：免密 sudo 配置、临时开启的 SSH 22 端口
- [ ] Rerank 服务（7997）与 Ollama（11434）同为内网无鉴权服务，需信息课在端口管控侧限制来源网段

---

*最后更新：2026-10-25*
