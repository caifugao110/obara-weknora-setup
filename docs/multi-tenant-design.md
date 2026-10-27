# OBARA 多租户部门隔离方案

> 基于方案一（一个部门 = 一个工作空间 / Tenant），配合 WeKnora 原生多租户 + RBAC 能力，实现"部门人员只能使用本部门文档进行对话问答"。

## 1. 设计目标

| 目标 | 实现方式 |
| --- | --- |
| 十几个部门相互隔离 | 每个部门 = 一个 WeKnora 工作空间（Tenant），所有实体（知识库、文档、会话、智能体）均带 `TenantID`，数据查询自动按租户过滤 |
| 部门管理员 | **平台超管 `admin` 默认就是所有部门的管理员**（建空间时自动 Owner，另有幂等脚本兜底）；各部门的文档管理员 `Owner` 由超管指派 |
| 部门人员只能用本部门文档 | Tenant 级硬隔离：A 部门成员检索不到 B 部门任何文档，无需额外配置 |
| 人员统一接入 | 邀请制：管理员发起邀请，成员通过邀请链接注册并加入部门工作空间 |
| 统一管理入口 | 新门户（端口 8081）提供精美简洁的问答 + 管理界面 |

## 2. 组织架构映射

### 2.1 部门清单（共 16 个工作空间）

| 基地 | 部门 | 工作空间编码 | 负责人（由超管指派） | 成员数 |
| --- | --- | --- | --- | --- |
| NJG（南京） | 总经理室 | `NJG-GM` | 周泽健 | 2 |
| NJG | 经理部 | `NJG-MGR` | 李婷 | 4 |
| NJG | 管理部 | `NJG-ADM` | 常青 | 7 |
| NJG | 品质保证部 | `NJG-QA` | 马筱丰 | 9 |
| NJG | 营业部 | `NJG-SALES` | 陆方明 | 25 |
| NJG | 制造部 | `NJG-MFG` | 冯爱国 | 15 |
| NJG | 技术开发一部 | `NJG-DEV1` | 张杰 | 34 |
| NJG | 购买部 | `NJG-PUR` | 马晏陟 | 10 |
| NJG | 技术开发二部 | `NJG-DEV2` | 张杰 | 31 |
| SHA（上海） | 总经理室 | `SHA-GM` | 周泽健 | 2 |
| SHA | 经理部 | `SHA-MGR` | 李婷 | 4 |
| SHA | 管理部 | `SHA-ADM` | 常青 | 7 |
| SHA | 购买部 | `SHA-PUR` | 马晏陟 | 6 |
| SHA | 品质保证部 | `SHA-QA` | 马筱丰 | 3 |
| SHA | 营业部 | `SHA-SALES` | 陆方明 | 14 |
| SHA | 制造部 | `SHA-MFG` | 冯爱国 | 13 |

> 完整人员清单见 [`data/departments-personnel.json`](../data/departments-personnel.json)。
>
> 「负责人」列仅供人工核对：**初始化脚本不会据此授予 `Owner`**。所有成员先以 `contributor`
> 加入，实际 `Owner` 由超管在初始化后逐个指派（见 6.3 节）。

### 2.2 角色矩阵

| 角色 | 对应人群 | 权限 |
| --- | --- | --- |
| `owner` | 文档管理员（由超管手动指派）；平台超管 `admin` 在**所有部门**自动持有该角色 | 门户全部功能：人员、智能体、文档/知识库管理 + 问答 |
| `contributor` | 普通部门成员 | 仅问答与切换所属部门，**看不到也调不动**人员/智能体/文档管理 |
| 系统管理员（超管） | 平台运维人员 | 跨租户管理、创建部门工作空间、全局配置（代理层放行） |

> 注：`viewer` 角色仅查看，`admin` 介于 owner 与 contributor 之间。本方案文档管理员用 `owner`，普通成员用 `contributor`；**初始化时不自动授予 `owner`**，需由超管指派。
>
> **提权保护**：把成员设为 `admin`（管理员）或 `owner`（文档管理员）的操作**仅系统管理员可执行**。
> 部门文档管理员只能指派 / 调整为 `contributor`、`viewer`，且不能调整 admin / owner 本人的角色；
> 前端不给出这些选项，代理层（`portal/server.py` 的 `check_role_elevation`）也会对
> `POST/PUT /tenants/{id}/members`、`POST /tenants/{id}/invitations`、`POST /tenants/{id}/invite-links`
> 中携带 `role=admin|owner` 的请求返回 403（超管放行）。

**门户权限分级（前端 + 代理双层控制）**

| 页面 | Contributor | Owner |
| --- | --- | --- |
| 智能问答 | ✅ | ✅ |
| 部门管理（查看/切换） | ✅ | ✅ |
| 人员管理 | ❌ 侧边栏隐藏、跳回问答页 | ✅ |
| 智能体管理 | ❌ | ✅ |
| 文档管理 | ❌ | ✅ |

实现位置：
- 前端 `portal/app.js`：`MANAGE_ROLES` / `MANAGE_PAGES` 常量 + `applyPermissionUI()` / `showPage()` 越权拦截（顶栏同时显示当前部门内的角色徽标）；系统管理员按 `/auth/me` 的 `user.is_system_admin` / `can_access_all_tenants` 额外放行，并可切换管理任意部门。
- 代理层 `portal/server.py`：对 `POST/PUT/DELETE` 的成员/邀请、智能体、知识库与文档接口做 Owner 角色校验（带 60s 缓存），非 Owner 直接返回 403；系统超管按 `can_access_all_tenants` 放行。可用 `PORTAL_ENFORCE_ROLE=false` 关闭（不推荐）。只读的 `GET /agents`、`GET /knowledge-bases` 仍需保留给普通成员用于问答，不受此限制。

### 2.3 跨部门人员处理

部分人员同时属于多个部门（如周泽健同时是 NJG 和 SHA 总经理室管理员）。WeKnora 支持一个用户加入多个工作空间，登录后通过顶部「当前部门」切换器切换，切换时系统会复核成员资格；门户会随切换重新计算该部门内的角色（管理入口的显隐同步变化）。

### 2.4 超管跨部门管理与智能体分配

系统管理员（`is_system_admin` / `can_access_all_tenants`）在门户中的行为：

- **管理部门**：顶栏「当前部门」下拉会列出全部部门（`/tenants/all` 补全），选中后所有管理请求带上该部门的 `X-Tenant-ID`。
- **默认就是所有部门的管理员**：这是本方案的一条硬约束——`admin@obara.local`（具备 `is_system_admin` / `can_access_all_tenants`）在每个部门空间的成员表里都持有最高的 `owner` 角色：

  | 保障点 | 机制 |
  | --- | --- |
  | 新建部门 | WeKnora 后端在创建工作空间时为创建者写入 Owner 成员记录（`TenantHandler.CreateTenant` → `EnsureOwner`），门户「新建部门」因此天然满足 |
  | 历史 / 被误改的部门 | `scripts/multi-tenant/ensure-admin-all-departments.sh` 逐部门补齐缺失的成员记录、把低于目标的角色提升为 `owner`，幂等可反复执行；`init-tenants.sh` 第 5c 步会自动调用它 |
  | 门户代理层 | `portal/server.py` 对 `privileged`（超管）一律放行管理类写操作，即便某部门成员记录缺失也不受影响 |

  核对 / 修复命令：

  ```bash
  sudo bash scripts/multi-tenant/ensure-admin-all-departments.sh --dry-run   # 只体检
  sudo bash scripts/multi-tenant/ensure-admin-all-departments.sh             # 补齐并提升
  sudo bash scripts/multi-tenant/ensure-admin-all-departments.sh --role admin  # 目标角色改为 admin
  ```
- **分配智能体**：智能体天然归属某一部门；跨部门使用通过「共享组织」实现，门户「智能体管理 → 分配到部门」弹窗完成三步：

  | 步骤 | 接口 | 说明 |
  | --- | --- | --- |
  | 管理部门成员 | `GET/POST /organizations/{id}/members`、`POST /organizations/{id}/invite` | 把其它部门加入共享组织（编辑者/管理员），未加入的部门看不到共享智能体 |
  | 分配智能体 | `POST /agents/{id}/shares`（`{organization_id, permission}`） | 分享到组织；门户会先自动把智能体所属部门加入组织，避免"仅编辑者可共享"的 403 |
  | 取消分配 | `GET/DELETE /agents/{id}/shares`、`/shares/{share_id}` | 移除后各部门问答页不再显示该智能体 |

  内置智能体（快速问答等）不支持共享，列表中的「分配到部门」按钮会自动隐藏。
- **使用智能体**：被分配部门的成员在问答页左侧即可看到带「共享」标签的智能体（由 `/organizations/{id}/shared-agents` 汇总）。

### 2.5 系统管理员专属功能

门户顶栏右上角显示登录人员**姓名 + 部门内角色徽标**，点击头像 / 下拉箭头打开账号菜单
（修改登录邮箱、修改密码、退出登录）。

| 功能 | 入口 | 实现 |
| --- | --- | --- |
| 修改登录邮箱 | 账号菜单「修改登录邮箱」（本人）；「人员管理」行内「改邮箱」（超管可改任何人） | WeKnora 未提供该 API，门户自有接口 `POST /api/v1/portal/users/email` 直连 Postgres 更新 `users.email`，并 `DELETE auth_tokens` 撤销该用户会话，强制用新邮箱重新登录 |
| 随机重置成员密码 | 「人员管理」行内「重置密码」（仅超管，不能重置自己） | 前端生成合规随机密码 → `POST /system/admin/users/reset-password`（后端仅 SystemAdmin 可用），成功后把新密码展示给管理员复制，对方全部会话被撤销 |
| 内置智能体按部门启停 | 侧边栏「内置智能体」（仅超管可见） | 状态持久化在 `data/builtin-agent-toggles.json`（`POST /api/v1/portal/builtin-agents` 写入）；代理层给 `GET /agents` 中被本部门停用的条目加 `disabled_in_tenant` 标记，问答页不显示，`POST /knowledge-chat/{session_id}` 带该 `agent_id` 时返回 403 |
| 授予管理员 / 文档管理员 | 「人员管理」角色下拉、邀请成员（见 2.2 提权保护） | 非超管的下拉里不出现 Admin / Owner；代理层 `check_role_elevation` 二次拦截 |
| 自身在所有部门的管理员身份 | `scripts/multi-tenant/ensure-admin-all-departments.sh`（也可由 `init-tenants.sh` 自动调用） | 逐部门 UPSERT `tenant_members`：缺失则补建为 `owner`，角色不足则提升；幂等 |

> 代理层同步收紧：跨部门分配涉及的组织写操作（建/改/删组织、邀请部门、移除成员）也纳入 Owner 校验，加入类接口（`join` / `join-by-id` / `join-request`）不拦截。

## 3. 隔离机制详解

### 3.1 数据层隔离（硬隔离）

WeKnora 几乎所有业务实体（知识库、文档、会话、智能体、消息）均携带 `TenantID` 字段。请求经认证中间件后，当前用户的激活租户 ID 写入请求上下文（`X-Tenant-ID` 头或 JWT 内），所有数据库查询自动追加 `WHERE tenant_id = ?` 条件。

**效果**：即使前端传错知识库 ID，服务端也会因租户不匹配而拒绝访问，从根本上杜绝跨部门数据泄露。

### 3.2 权限层隔离（RBAC）

- 默认环境变量 `WEKNORA_TENANT_ENABLE_RBAC` 为空时，角色守卫放行（仅打日志）。
- 上线多部门前**必须开启 RBAC**：在 `.env` 中设置 `WEKNORA_TENANT_ENABLE_RBAC=true`，并 `docker compose up -d --force-recreate app` 重建容器。
- 开启后，角色守卫严格生效：`Viewer` 只能读，`Contributor` 可上传但不能管理成员，`Admin`/`Owner` 可管理。

### 3.3 知识库归属

- 每个知识库归属于某个工作空间（Tenant），创建时绑定当前 `TenantID`。
- 智能体绑定到知识库，问答时只能检索绑定的知识库，进一步保证检索范围限定在本部门。

## 4. 人员接入流程（邀请制）

### 4.1 邀请流程

```
文档管理员（Owner）
    │
    ▼
在门户「人员管理」中输入成员姓名/邮箱 → 发起邀请
    │
    ▼
WeKnora 生成邀请链接（含邀请令牌）
    │
    ├── 若配置了 SMTP：自动发送邀请邮件
    └── 若未配置 SMTP：管理员复制邀请链接，通过企业微信/邮件手动分发
    │
    ▼
成员点击邀请链接 → 注册账号（或登录已有账号）→ 自动加入对应部门工作空间
```

### 4.2 邮箱生成规则

- 账号邮箱统一为「姓全拼 + 名各字首字母」@ `obara.com.cn`：
  - 高剑 → `gaoj@obara.com.cn`
  - 陈爱珍 → `chenaz@obara.com.cn`
  - O/NJG 管理部张杰为特例：`zhangj_adm@obara.com.cn`
  - 同名同人（身兼多部门，如技术开发一部 / 二部的张杰）：**共用一个账号**
  - 前缀撞号顺延数字：张娟 → `zhangj2@obara.com.cn`
- 邮箱写死在 `data/departments-personnel.json` 的 `email` 字段；新增人员可用
  `scripts/multi-tenant/gen-emails.py`（依赖 `pypinyin`）按同一规则生成，也可直接手写真实邮箱。
- 未配置 SMTP 时，邀请链接由管理员手动分发，邮箱字段仅作为登录账号使用。

### 4.3 批量初始化

执行 `scripts/multi-tenant/init-tenants.sh` 可一键完成：
1. 创建 16 个部门工作空间
2. 为每位成员生成邀请，**全部为 `contributor`**（不为普通成员设默认管理员）
3. 保证平台超管 `admin` 在**所有**部门都是管理员（第 5c 步，见 2.4 节）
4. 输出所有邀请链接汇总，便于管理员分发

初始化完成后，**各部门除平台超管 `admin`（默认已是 owner，见 2.4 节）外还没有文档管理员 Owner**，需由超管逐个指派（见 6.3.1 节）。在此之前，该部门的普通成员在门户中不会出现「人员 / 智能体 / 文档」管理入口。

## 5. 新门户设计（端口 8081）

### 5.1 定位

在 WeKnora 原生前端（端口 80）之外，新增一个**轻量门户**（端口 8081）——品牌标识统一为 **OBARA 知识问答平台**，面向普通员工和文档管理员，提供：

- 更精美、简洁的问答界面（默认首页，含智能体列表、推荐提问、引用来源卡片）
- 部门（工作空间）管理
- 人员（成员）管理：邀请、移除、改角色
- 智能体管理：创建、编辑、绑定知识库与模型
- 文档管理：知识库增删、文档上传/删除/重解析

### 5.2 技术架构

```
浏览器（员工/管理员）
    │
    ▼
门户静态站点（端口 8081）  ←  Python HTTP Server（portal/server.py）
    │                           ├── 服务静态文件（index.html / app.js / styles.css）
    │                           └── 反向代理 /api/* → WeKnora 后端（127.0.0.1:8080）
    ▼
WeKnora 后端 API（端口 8080）
    │
    ├── PostgreSQL（租户/知识库/文档/会话）
    ├── Redis（会话/限流/任务队列）
    └── docreader / Ollama / Rerank / DeepSeek API
```

**为什么用代理而非直连**：WeKnora 后端默认未开启跨域（CORS），门户通过同源代理转发 API 请求，避免浏览器 CORS 拦截；同时门户仅暴露必要 API，可在代理层做二次鉴权与审计。

### 5.3 页面结构

```
┌─────────────────────────────────────────────────────────────┐
│  顶部栏：OBARA 知识问答平台 | [部门切换器▼] [用户 + 角色徽标 退出]│
├──────────┬──────────────────────────────────────────────────┤
│ 侧边栏    │  主内容区                                          │
│          │                                                    │
│ 💬 问答   │  问答页：智能体选择 + 对话流 + 输入框               │
│ 🏢 部门   │  部门管理：工作空间列表、创建、进入                  │
│ 👥 人员   │  人员管理：成员列表、邀请、改角色、移除   ← Owner   │
│ 🤖 智能体 │  智能体管理：列表、创建/编辑、绑定知识库   ← Owner  │
│ 📄 文档   │  文档管理：知识库列表、上传文档、解析状态  ← Owner  │
│          │                                                    │
└──────────┴──────────────────────────────────────────────────┘
```

### 5.4 视觉规范

| 元素 | 规范 |
| --- | --- |
| 主色调 | OBARA 蓝 `#1a56db`（科技感，适合企业知识平台） |
| 辅助色 | 浅灰 `#f8fafc` 背景、深灰 `#1e293b` 文字、中灰 `#64748b` 次要文字 |
| 圆角 | 卡片 `12px`、按钮 `8px`、消息气泡 `16px` |
| 字体 | 系统默认中文字体栈（PingFang SC / Microsoft YaHei / sans-serif） |
| 布局 | 左侧固定侧边栏 240px，主内容区自适应 |

### 5.5 版本号规则

侧边栏左下角显示门户的**构建版本号**（由 `scripts/portal/build-version.py` 写入 `portal/index.html` 的 `#build-version` 节点）：

| 场景 | 显示 | 说明 |
| --- | --- | --- |
| 当天第 1 次构建 | `当前版本 26-10-25` | `YY-MM-DD` 为 `index.html` 的构建日期 |
| 当天第 2 次构建 | `当前版本 26-10-25-V2` | 同一天后续构建依次 `-V3`、`-V4`… |
| 跨天 | 重新从无后缀开始 | 序号按日期归零 |

日期与序号保存在 `data-date` / `data-build` 属性上，换机器或重新克隆仓库后仍能接着当天序号递增；每次改动门户页面后执行一次：

```bash
python3 scripts/portal/build-version.py          # 递增并写入
python3 scripts/portal/build-version.py --check  # 只看不改
```

> `bash portal/start.sh` 启动时会自动调用；通过 systemd（`obara-portal.service`）重启不会递增，需手工执行。

## 6. 部署步骤

### 6.1 前置条件

- WeKnora v0.8.3 已部署并运行（端口 80 / 8080）
- 管理员账号已创建（如 `admin@obara.local`）
- 模型已注册（Embedding `bge-m3`、对话 `deepseek-flash`、重排 `bge-reranker-v2-m3`）

### 6.2 开启 RBAC

```bash
# 编辑 /opt/obara/weknora/.env，追加：
WEKNORA_TENANT_ENABLE_RBAC=true

# 重建 app 容器使环境变量生效
cd /opt/obara/weknora
docker compose up -d --force-recreate app
```

### 6.3 初始化部门与人员

```bash
cd /path/to/obara-weknora-setup
sudo ADMIN_PASSWORD='<管理员密码>' bash scripts/multi-tenant/init-tenants.sh
# 脚本会输出所有部门的邀请链接与账号汇总，保存后分发给各部门负责人
```

**初始化不为普通成员设默认管理员**：所有成员先以 `contributor` 加入本部门空间，`data/departments-personnel.json`
中的 `is_admin` / `admin_role` 配置已废弃（即使存在也会被脚本忽略）。
唯一例外是平台超管 `admin`——脚本第 5c 步会把它在每个部门的身份补齐为 `owner`（见 2.4 节）。

### 6.3.1 手动指派各部门文档管理员（必做）

初始化完成后，由超管在 **WeKnora 原生后台（端口 80）** 逐个指定：

1. 用超管账号登录 `http://<虚拟机IP>:80`
2. 切换到目标部门工作空间 →「成员」（或「人员管理」）页面
3. 找到该部门负责人 → 把角色改为 **`owner`（文档管理员）** → 保存
4. 逐个部门重复，直到 16 个部门都有至少一名 `owner`

> 指派前该部门在门户中没有「人员 / 智能体 / 文档」管理入口；指派完成后，被指定的成员
> 刷新门户即可看到管理菜单，并可自行邀请本部门其他成员。
> 如需换人，把原负责人改回 `contributor`、再给新负责人 `owner` 即可。

### 6.4 启动门户与开机自启

```bash
cd /path/to/obara-weknora-setup

# 一键启动全部服务：Ollama → WeKnora 容器（含 Rerank）→ 8081 门户
bash scripts/start-all.sh

# 状态 / 重启 / 停止
bash scripts/start-all.sh status
bash scripts/start-all.sh restart
bash scripts/start-all.sh stop
```

首次部署或仓库目录变更后，安装门户开机自启：

```bash
sudo bash scripts/deploy/install-autostart.sh
# 卸载：sudo bash scripts/deploy/install-autostart.sh --uninstall
```

访问 `http://<虚拟机IP>:8081` 即可使用门户。虚拟机重启后无需手工启动：Docker 按 `restart: unless-stopped` 拉起 WeKnora 容器（含 `weknora-rerank`），Ollama 与 `obara-portal.service` 随 systemd 自启。

门户日志：`journalctl -u obara-portal -f`；前台调试仍可使用 `bash portal/start.sh`。

### 6.5 部门文档管理员操作

前提：已被超管指派为本部门 `owner`（见 6.3.1 节）。

1. 文档管理员登录门户
2. 在「文档管理」中创建本部门知识库、上传文档
3. 在「智能体管理」中创建问答智能体，绑定本部门知识库
4. 在「人员管理」中邀请本部门其他成员
5. 普通成员通过邀请链接加入后，即可在「问答」页面对本部门文档提问

## 7. 交付物清单

| 文件 | 用途 |
| --- | --- |
| `docs/multi-tenant-design.md` | 本设计方案文档 |
| `data/departments-personnel.json` | 16 个部门、全部人员的初始化数据 |
| `scripts/multi-tenant/init-tenants.sh` | 一键创建工作空间 + 批量邀请脚本 |
| `portal/index.html` | 门户主页面 |
| `portal/styles.css` | 门户样式 |
| `portal/app.js` | 门户前端逻辑（问答 + 四大管理模块；含 Owner 角色权限控制） |
| `portal/server.py` | 门户 HTTP 服务 + API 反向代理（端口 8081）；管理类写操作 Owner 二次鉴权、提权保护、内置智能体停用拦截、门户自有接口（邮箱变更 / 内置智能体启停） |
| `data/builtin-agent-toggles.json` | 内置智能体在各工作空间内的启停状态（由门户维护，缺省即启用） |
| `portal/start.sh` | 门户启动脚本 |
| `scripts/start-all.sh` | 一键启动/停止/重启/查看全部服务（Ollama + WeKnora + 门户） |
| `scripts/deploy/install-autostart.sh` | 安装/卸载门户（8081）systemd 开机自启 |

## 8. 注意事项

1. **RBAC 必须开启**：否则角色守卫放行，无法实现部门内权限分级。
2. **邀请链接有时效**：WeKnora 邀请令牌默认有有效期（通常 7 天），过期需重新邀请。
3. **跨部门文档共享**：如需跨部门共享某文档，可单独建一个"公司公共"工作空间，所有成员加入；或在源部门知识库中设置共享（WeKnora 支持跨组织共享 KB）。
4. **门户不替代 WeKnora 原生后台**：模型管理、系统配置、审计日志等仍在 WeKnora 原生后台（端口 80）操作；门户聚焦问答 + 部门日常管理。
5. **SMTP 可选**：未配置 SMTP 时邀请链接需手动分发；配置后可自动发邮件。

---

*最后更新：2026-10-25*
