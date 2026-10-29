#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
OBARA 知识问答平台 — 门户 HTTP 服务 + API 反向代理

职责：
  1. 服务静态文件（index.html / styles.css / app.js）
  2. 将 /api/* 反向代理到 WeKnora 后端（默认 127.0.0.1:8080），解决浏览器 CORS 问题
  3. 提供门户自有接口 /api/v1/portal/*（登录邮箱修改、内置智能体按部门启停、
     文档文件夹管理、文档上传限制配置）

用法：
  python3 portal/server.py                          # 默认 0.0.0.0:8081 → 127.0.0.1:8080
  PORTAL_PORT=8082 WEKNORA_URL=http://192.168.1.10:8080 python3 portal/server.py
  python3 portal/server.py --port 8081 --upstream http://127.0.0.1:8080

二次鉴权：
  门户会在代理层拦截部门管理类「写操作」（成员/邀请、智能体、知识库与文档），
  仅允许当前部门内的文档管理员（Owner）执行，防止绕过前端直接调 API；
  其中把成员提权为「管理员 Admin / 文档管理员 Owner」仅系统管理员可执行；
  部门文档管理员只能调整「权限比自己低」的成员（Owner 不可调整另一位 Owner，
  系统管理员在所有部门均为 Owner 且一律放行）。
  可用 PORTAL_ENFORCE_ROLE=false 关闭（不推荐）。

注册管控：
  不允许任何用户自助注册 —— POST /api/v1/auth/register 一律 403；
  凭管理员邀请链接的 /api/v1/auth/register-by-invite 默认允许，
  置 PORTAL_ALLOW_INVITE_REGISTER=false 后连邀请注册一并关闭（账号全部由管理员开通）。

门户自有接口（不走上游）：
  POST /api/v1/portal/users/email       修改登录邮箱（仅系统管理员可改他人，本人不可自助修改；
                                        WeKnora 原生 API 未提供该能力，门户直连其 Postgres 完成更新并撤销该用户会话）
  GET  /api/v1/portal/builtin-agents    查询内置智能体在当前部门内的停用列表（超管额外返回全部门映射）
  POST /api/v1/portal/builtin-agents    启用 / 禁用某部门的内置智能体（仅系统管理员，落在 data/builtin-agent-toggles.json）
  GET  /api/v1/portal/doc-folders       查询某知识库的文件夹树与文档归属（data/doc-folders.json）
  POST /api/v1/portal/doc-folders       文件夹增删改 / 文档移动 / 按路径自动建目录（仅本部门 Owner 或系统管理员）
  GET  /api/v1/portal/upload-limits     查询上传限制（单次文件数 / 单文件大小 / 合计大小）与可调区间
  POST /api/v1/portal/upload-limits     修改上传限制（仅系统管理员，取值受区间约束，落在 data/upload-limits.json）

系统管理员审计接口（仅超管，只读为主）：
  GET  /api/v1/portal/admin/conversations              全员会话列表（可按部门 / 成员 / 关键词过滤、分页）
  GET  /api/v1/portal/admin/conversations/{id}/messages 任一成员会话的完整对话内容
  POST /api/v1/portal/admin/conversations              删除某个成员的会话（软删除，语义同后端 /sessions/{id}）
  GET  /api/v1/portal/admin/uploads                    全平台文档上传记录（上传人 / 部门 / 知识库 / 时间）
    说明：WeKnora 原生没有「跨部门查看他人会话」的接口（/sessions 只返回本人会话），
    文档上传人也只存在于 audit_logs，因此这里沿用「修改登录邮箱」的通路，只读查询同一 Postgres。

文档上传限制在代理层生效：POST /api/v1/knowledge-bases/{id}/knowledge/file
会按上述配置校验文件数量、单文件大小与合计大小，绕过前端也会被拦截。
"""
import os
import re
import sys
import json
import time
import uuid
import threading
import subprocess
import urllib.request
import urllib.error
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler
from urllib.parse import urlparse, parse_qs

PORTAL_PORT = int(os.environ.get("PORTAL_PORT", "8081"))
UPSTREAM = os.environ.get("WEKNORA_URL", "http://127.0.0.1:8080").rstrip("/")
STATIC_DIR = os.path.dirname(os.path.abspath(__file__))

CONTENT_TYPES = {
    ".html": "text/html; charset=utf-8",
    ".css": "text/css; charset=utf-8",
    ".js": "application/javascript; charset=utf-8",
    ".json": "application/json; charset=utf-8",
    ".png": "image/png",
    ".jpg": "image/jpeg",
    ".svg": "image/svg+xml",
    ".ico": "image/x-icon",
}

# ------------------------------------------------------------------
# 门户二次鉴权：部门管理类写操作仅允许文档管理员（Owner）
# ------------------------------------------------------------------
ENFORCE_ROLE = os.environ.get("PORTAL_ENFORCE_ROLE", "true").lower() not in ("0", "false", "no")

# 具备部门内管理权限的角色
MANAGE_ROLES = {"owner"}

# 需要管理权限的 HTTP 方法
MANAGE_METHODS = {"POST", "PUT", "PATCH", "DELETE"}

# 需要管理权限的上游路径（只读请求如 GET /agents 需保留给普通成员用于问答选智能体）
MANAGE_PATH_RULES = (
    re.compile(r"^/api/v1/tenants/[^/]+/(members|invitations|invite-links)(/|$)"),
    re.compile(r"^/api/v1/agents(/|$)"),
    re.compile(r"^/api/v1/knowledge-bases(/|$)"),
    re.compile(r"^/api/v1/knowledge(/|$)"),
    # 跨部门分配用到的「共享组织」写操作（成员/邀请/建删组织），
    # 加入类接口（join / join-by-id / join-request / search / preview）不在此列
    re.compile(r"^/api/v1/organizations$"),
    re.compile(r"^/api/v1/organizations/(?!join|join-by-id|join-request|search|preview)[^/]+$"),
    re.compile(r"^/api/v1/organizations/[^/]+/(members|invite)(/|$)"),
)

# 管理员 / 文档管理员为「高权限角色」，授予这两种角色仅限系统管理员
ELEVATED_ROLES = {"owner", "admin"}

# 会携带 member role 的写接口：直接加成员、改成员角色、发邀请、生成邀请链接
ROLE_WRITE_PATHS = (
    re.compile(r"^/api/v1/tenants/[^/]+/members(/|$)"),
    re.compile(r"^/api/v1/tenants/[^/]+/invitations(/|$)"),
    re.compile(r"^/api/v1/tenants/[^/]+/invite-links(/|$)"),
)

# 部门内角色高低（数值越大权限越高）：owner > admin > contributor > viewer
ROLE_RANK = {"owner": 3, "admin": 2, "contributor": 1, "viewer": 0}

# 修改 / 移除指定成员：PUT/PATCH/DELETE /api/v1/tenants/{tid}/members/{user_id}
MEMBER_ROLE_PATH = re.compile(r"^/api/v1/tenants/([^/]+)/members/([^/]+)/?$")

# 超管重置成员密码：POST /api/v1/system/admin/users/reset-password
RESET_PASSWORD_PATH = re.compile(r"^/api/v1/system/admin/users/reset-password/?$")

# 问答流式接口：内置智能体被本部门禁用时拒绝提问
CHAT_PATH = re.compile(r"^/api/v1/(knowledge-chat|agent-chat)/")

# 智能体列表：给被本部门停用的内置智能体打标记，供前端渲染开关 / 隐藏
AGENT_LIST_PATH = re.compile(r"^/api/v1/agents/?$")

# 文档上传接口：门户在此按可配置限制拦截（文件数量 / 单文件大小 / 合计大小）
UPLOAD_PATH = re.compile(r"^/api/v1/knowledge-bases/[^/]+/knowledge/file/?$")

# ------------------------------------------------------------------
# 注册管控：不允许任何用户自助注册，账号只能由管理员开通
#   /api/v1/auth/register            无邀请的自助注册 —— 一律 403
#   /api/v1/auth/register-by-invite  凭管理员邀请链接加入 —— 默认允许，
#                                    置 PORTAL_ALLOW_INVITE_REGISTER=false 可一并关闭
# ------------------------------------------------------------------
SELF_REGISTER_PATH = re.compile(r"^/api/v1/auth/register/?$")
INVITE_REGISTER_PATH = re.compile(r"^/api/v1/auth/register-by-invite/?$")
ALLOW_INVITE_REGISTER = os.environ.get(
    "PORTAL_ALLOW_INVITE_REGISTER", "true").lower() not in ("0", "false", "no")

_ROLE_CACHE = {}          # token -> (过期时间戳, {roles: {...}, privileged: bool})
_ROLE_CACHE_TTL = 60      # 秒
_ROLE_LOCK = threading.Lock()

# ------------------------------------------------------------------
# 门户自有接口配置
# ------------------------------------------------------------------
PORTAL_API_PREFIX = "/api/v1/portal/"
DATA_DIR = os.environ.get("PORTAL_DATA_DIR") or os.path.join(os.path.dirname(STATIC_DIR), "data")
AGENT_TOGGLE_FILE = os.path.join(DATA_DIR, "builtin-agent-toggles.json")
DOC_FOLDER_FILE = os.path.join(DATA_DIR, "doc-folders.json")
UPLOAD_LIMIT_FILE = os.path.join(DATA_DIR, "upload-limits.json")

# 门户直连 WeKnora 的 Postgres 容器（邮箱变更无原生 API，只能写库）
PG_CONTAINER = os.environ.get("WEKNORA_PG_CONTAINER", "WeKnora-postgres")
PG_DB = os.environ.get("WEKNORA_PG_DB", "WeKnora")
PG_USER = os.environ.get("WEKNORA_PG_USER", "postgres")

EMAIL_RE = re.compile(r"^[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$")
SAFE_ID_RE = re.compile(r"^[A-Za-z0-9_-]{1,64}$")


class PortalError(Exception):
    """门户自有接口的业务错误（含 HTTP 状态码）。"""

    def __init__(self, status, message):
        super().__init__(message)
        self.status = status
        self.message = message


def fetch_upstream_roles(token):
    """向上游查询用户在其所属工作空间中的角色。"""
    req = urllib.request.Request(
        UPSTREAM + "/api/v1/auth/me",
        method="GET",
        headers={
            "Authorization": "Bearer " + token,
            "Accept": "application/json",
            "Accept-Encoding": "identity",
        },
    )
    with urllib.request.urlopen(req, timeout=10) as resp:
        raw = json.loads(resp.read().decode("utf-8") or "{}")

    data = raw.get("data") or raw
    user = data.get("user") or {}
    roles = {}
    for m in data.get("memberships") or []:
        tid = m.get("tenant_id") or m.get("tenant") or ""
        if tid:
            roles[str(tid)] = (m.get("role") or "").lower()
    privileged = bool(
        data.get("is_system_admin") or user.get("is_system_admin")
        or data.get("can_access_all_tenants") or user.get("can_access_all_tenants")
    )
    return {
        "roles": roles,
        "privileged": privileged,
        "user_id": str(user.get("id") or ""),
        "email": user.get("email") or "",
    }


def get_upstream_roles(token):
    """带短期缓存的角色查询；返回 None 表示无法确定（放行，由后端 RBAC 兜底）。"""
    now = time.time()
    with _ROLE_LOCK:
        hit = _ROLE_CACHE.get(token)
    if hit and hit[0] > now:
        return hit[1]
    try:
        info = fetch_upstream_roles(token)
    except urllib.error.HTTPError as e:
        if e.code in (401, 403):
            # 令牌无效/已过期：明确无权限
            return {"roles": {}, "privileged": False}
        return None
    except Exception:
        # 上游不可达等异常：不确定放行，避免门户误伤正常业务
        return None
    with _ROLE_LOCK:
        _ROLE_CACHE[token] = (now + _ROLE_CACHE_TTL, info)
    return info


# ------------------------------------------------------------------
# 部门成员角色表：用于判断「被改角色的人是否比操作者权限低」
# ------------------------------------------------------------------
_MEMBER_CACHE = {}          # (token, tenant_id) -> (过期时间戳, {user_id: role})
_MEMBER_CACHE_TTL = 60      # 秒
_MEMBER_LOCK = threading.Lock()


def fetch_member_roles(token, tenant_id):
    """向上游拉取部门成员角色表 {user_id: role}。"""
    req = urllib.request.Request(
        UPSTREAM + "/api/v1/tenants/%s/members?page=1&page_size=200" % tenant_id,
        method="GET",
        headers={
            "Authorization": "Bearer " + token,
            "Accept": "application/json",
            "Accept-Encoding": "identity",
            "X-Tenant-ID": str(tenant_id),
        },
    )
    with urllib.request.urlopen(req, timeout=10) as resp:
        raw = json.loads(resp.read().decode("utf-8") or "{}")
    data = raw.get("data") or raw
    out = {}
    for m in data.get("members") or []:
        uid = str(m.get("user_id") or m.get("id") or "")
        if uid:
            out[uid] = (m.get("role") or "").lower()
    return out


def get_member_roles(token, tenant_id):
    """带短期缓存的成员角色表；无法确定时返回 None（放行，由后端 RBAC 兜底）。"""
    key = (token, str(tenant_id))
    now = time.time()
    with _MEMBER_LOCK:
        hit = _MEMBER_CACHE.get(key)
        if hit and hit[0] > now:
            return hit[1]
    try:
        roles = fetch_member_roles(token, tenant_id)
    except Exception:
        return None
    with _MEMBER_LOCK:
        _MEMBER_CACHE[key] = (now + _MEMBER_CACHE_TTL, roles)
    return roles


def invalidate_member_roles(token, tenant_id):
    """成员角色发生写操作后清掉缓存，避免读到旧角色。"""
    if not token:
        return
    with _MEMBER_LOCK:
        _MEMBER_CACHE.pop((token, str(tenant_id)), None)


# ------------------------------------------------------------------
# 内置智能体「按部门启停」持久化（data/builtin-agent-toggles.json）
# ------------------------------------------------------------------
_AGENT_TOGGLE_CACHE = {"mtime": -1, "data": {"tenants": {}}}


def load_agent_toggles():
    """读取 {tenant_id: {agent_id: enabled}} 映射，按文件 mtime 做缓存。"""
    try:
        mtime = os.path.getmtime(AGENT_TOGGLE_FILE)
    except OSError:
        return {"tenants": {}}
    if _AGENT_TOGGLE_CACHE["mtime"] == mtime:
        return _AGENT_TOGGLE_CACHE["data"]
    try:
        with open(AGENT_TOGGLE_FILE, encoding="utf-8") as f:
            raw = json.load(f)
    except (ValueError, OSError):
        sys.stderr.write("[WARN] 读取内置智能体开关文件失败：%s\n" % AGENT_TOGGLE_FILE)
        raw = {}
    tenants = raw.get("tenants") if isinstance(raw, dict) else None
    data = {"tenants": {}}
    if isinstance(tenants, dict):
        for tid, agents in tenants.items():
            if isinstance(agents, dict):
                data["tenants"][str(tid)] = {str(k): bool(v) for k, v in agents.items()}
    _AGENT_TOGGLE_CACHE["mtime"] = mtime
    _AGENT_TOGGLE_CACHE["data"] = data
    return data


def save_agent_toggles(tenants):
    """原子写回开关文件，并刷新缓存。"""
    try:
        os.makedirs(DATA_DIR, exist_ok=True)
    except OSError:
        pass
    payload = {
        "_comment": "内置智能体在各部门（工作空间）内的启停状态：键为部门 tenant_id，值为 {agent_id: 是否启用}；未列出的智能体默认启用。",
        "tenants": tenants,
    }
    tmp = AGENT_TOGGLE_FILE + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(payload, f, ensure_ascii=False, indent=2)
    os.replace(tmp, AGENT_TOGGLE_FILE)
    try:
        _AGENT_TOGGLE_CACHE["mtime"] = os.path.getmtime(AGENT_TOGGLE_FILE)
        _AGENT_TOGGLE_CACHE["data"] = {"tenants": tenants}
    except OSError:
        pass


def is_agent_disabled(tenant_id, agent_id):
    """该内置智能体是否在指定部门内被停用（缺省即为启用）。"""
    toggles = load_agent_toggles()["tenants"].get(str(tenant_id or ""), {})
    return toggles.get(str(agent_id or "")) is False


def annotate_disabled_agents(raw, tenant_id):
    """给智能体列表响应中被本部门停用的条目加 disabled_in_tenant 标记。"""
    toggles = load_agent_toggles()["tenants"].get(str(tenant_id or ""), {})
    if not toggles:
        return raw
    try:
        obj = json.loads(raw.decode("utf-8"))
    except (ValueError, UnicodeDecodeError):
        return raw
    agents = obj.get("data") if isinstance(obj, dict) else obj
    if isinstance(obj, dict) and not isinstance(agents, list):
        return raw
    changed = False
    for agent in agents if isinstance(agents, list) else []:
        if isinstance(agent, dict) and toggles.get(str(agent.get("id", ""))) is False:
            agent["disabled_in_tenant"] = True
            changed = True
    if not changed:
        return raw
    return json.dumps(obj, ensure_ascii=False).encode("utf-8")


# ------------------------------------------------------------------
# 文档上传限制（data/upload-limits.json）
#   系统管理员可在门户页面调整，取值受 UPLOAD_LIMIT_RANGES 区间约束，
#   防止误改导致上传不可用或资源被大文件打满。
# ------------------------------------------------------------------
UPLOAD_LIMIT_DEFAULTS = {
    "max_files_per_upload": 50,     # 单次上传文件数量
    "max_file_size_mb": 50,         # 单个文件大小（MB）
    "max_total_size_mb": 200,       # 单次上传合计大小（MB）
}

# 允许调整的区间（含端点）
UPLOAD_LIMIT_RANGES = {
    "max_files_per_upload": (1, 500),
    "max_file_size_mb": (1, 200),
    "max_total_size_mb": (10, 2000),
}

UPLOAD_LIMIT_LABELS = {
    "max_files_per_upload": "单次上传文件数量上限",
    "max_file_size_mb": "单个文件大小上限",
    "max_total_size_mb": "单次上传合计大小上限",
}


def load_upload_limits():
    """读取上传限制，缺失或越界的值回落到默认值。"""
    limits = dict(UPLOAD_LIMIT_DEFAULTS)
    try:
        with open(UPLOAD_LIMIT_FILE, encoding="utf-8") as f:
            raw = json.load(f)
    except (ValueError, OSError):
        raw = {}
    if isinstance(raw, dict):
        saved = raw.get("limits") if isinstance(raw.get("limits"), dict) else raw
        for key in UPLOAD_LIMIT_DEFAULTS:
            v = saved.get(key)
            if isinstance(v, bool):
                continue
            lo, hi = UPLOAD_LIMIT_RANGES[key]
            if isinstance(v, (int, float)) and lo <= int(v) <= hi:
                limits[key] = int(v)
    # 兜底：合计上限不得小于单文件上限
    if limits["max_total_size_mb"] < limits["max_file_size_mb"]:
        limits["max_total_size_mb"] = limits["max_file_size_mb"]
    return limits


def save_upload_limits(limits):
    """原子写回上传限制。"""
    try:
        os.makedirs(DATA_DIR, exist_ok=True)
    except OSError:
        pass
    payload = {
        "_comment": "门户文档上传限制：系统管理员可在「文档管理 → 上传限制设置」中调整，取值须落在 ranges 区间内。",
        "limits": {k: int(limits[k]) for k in UPLOAD_LIMIT_DEFAULTS},
        "ranges": {k: {"min": lo, "max": hi} for k, (lo, hi) in UPLOAD_LIMIT_RANGES.items()},
    }
    tmp = UPLOAD_LIMIT_FILE + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(payload, f, ensure_ascii=False, indent=2)
    os.replace(tmp, UPLOAD_LIMIT_FILE)


def human_mb(size):
    return "%.1f MB" % (size / 1024.0 / 1024.0)


def multipart_file_sizes(body, content_type):
    """解析 multipart 请求体里的 file 部分，返回 [(文件名, 字节数)]。

    结构无法识别（非 multipart、缺 boundary、分片格式异常）时返回 None，
    表示「不拦截」，避免误伤正常上传。
    """
    m = re.search(r'boundary=(?:"([^"]+)"|([^;]+))', content_type or "", re.I)
    if not m:
        return None
    boundary = (m.group(1) or m.group(2) or "").strip()
    if not boundary:
        return None
    sep = ("--" + boundary).encode()
    if sep not in body:
        return None
    out = []
    for part in body.split(sep):
        if not part.startswith(b"\r\n"):
            continue                      # 前导内容 / 结束符
        head_end = part.find(b"\r\n\r\n")
        if head_end < 0:
            return None                   # 格式异常：不拦截
        head = part[:head_end].decode("utf-8", "replace")
        low = head.lower()
        if 'name="file"' not in low or "filename=" not in low:
            continue
        fn = re.search(r'filename="([^"]*)"', head)
        content = part[head_end + 4:]
        if content.endswith(b"\r\n"):
            content = content[:-2]
        out.append(((fn.group(1) if fn else "") or "文件", len(content)))
    return out


# ------------------------------------------------------------------
# 文档文件夹（data/doc-folders.json）
#   WeKnora 原生没有文件夹概念，这里由门户维护「知识库 → 文件夹树 + 文档归属」，
#   仅影响门户文档列表的分组展示与移动，不改动后端数据。
# ------------------------------------------------------------------
MAX_FOLDER_DEPTH = 8
MAX_FOLDERS_PER_KB = 300
MAX_FOLDER_NAME_LEN = 64

_DOC_FOLDER_CACHE = {"mtime": -1, "data": {"tenants": {}}}


def load_doc_folders():
    """读取 {tenant: {kbs: {kb_id: {folders: [...], docs: {doc_id: folder_id}}}}}。"""
    try:
        mtime = os.path.getmtime(DOC_FOLDER_FILE)
    except OSError:
        return {"tenants": {}}
    if _DOC_FOLDER_CACHE["mtime"] == mtime:
        return _DOC_FOLDER_CACHE["data"]
    try:
        with open(DOC_FOLDER_FILE, encoding="utf-8") as f:
            raw = json.load(f)
    except (ValueError, OSError):
        sys.stderr.write("[WARN] 读取文档文件夹文件失败：%s\n" % DOC_FOLDER_FILE)
        raw = {}
    data = {"tenants": {}}
    tenants = (raw or {}).get("tenants") if isinstance(raw, dict) else None
    if isinstance(tenants, dict):
        for tid, entry in tenants.items():
            kbs = {}
            for kb_id, kb in (entry or {}).get("kbs", {}).items() if isinstance(entry, dict) else []:
                if not isinstance(kb, dict):
                    continue
                folders = []
                for f in kb.get("folders") or []:
                    if isinstance(f, dict) and f.get("id") and f.get("name"):
                        folders.append({
                            "id": str(f["id"]),
                            "name": str(f["name"]),
                            "parent_id": str(f.get("parent_id") or ""),
                        })
                docs = {}
                for doc_id, folder_id in (kb.get("docs") or {}).items():
                    if isinstance(folder_id, str):
                        docs[str(doc_id)] = folder_id
                kbs[str(kb_id)] = {"folders": folders, "docs": docs}
            data["tenants"][str(tid)] = {"kbs": kbs}
    _DOC_FOLDER_CACHE["mtime"] = mtime
    _DOC_FOLDER_CACHE["data"] = data
    return data


def save_doc_folders(tenants):
    """原子写回文件夹数据，并刷新缓存。"""
    try:
        os.makedirs(DATA_DIR, exist_ok=True)
    except OSError:
        pass
    payload = {
        "_comment": "门户文档文件夹：按 部门 → 知识库 维度保存文件夹树与文档归属（folder_id 为空表示未分类）。",
        "tenants": tenants,
    }
    tmp = DOC_FOLDER_FILE + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(payload, f, ensure_ascii=False, indent=2)
    os.replace(tmp, DOC_FOLDER_FILE)
    try:
        _DOC_FOLDER_CACHE["mtime"] = os.path.getmtime(DOC_FOLDER_FILE)
        _DOC_FOLDER_CACHE["data"] = {"tenants": tenants}
    except OSError:
        pass


def clone_doc_folders(data):
    """拷贝一份可写的数据结构（避免污染缓存）。"""
    tenants = {}
    for tid, entry in (data.get("tenants") or {}).items():
        kbs = {}
        for kb_id, kb in (entry.get("kbs") or {}).items():
            kbs[kb_id] = {
                "folders": [dict(f) for f in kb.get("folders", [])],
                "docs": dict(kb.get("docs", {})),
            }
        tenants[tid] = {"kbs": kbs}
    return tenants


def folder_index(folders):
    return {f["id"]: f for f in folders}


def folder_path(folders, folder_id):
    """按父链拼出 '一级/二级' 形式的路径。"""
    idx = folder_index(folders)
    parts = []
    cur = idx.get(str(folder_id or ""))
    guard = 0
    while cur and guard <= MAX_FOLDER_DEPTH + 2:
        parts.append(cur["name"])
        cur = idx.get(cur.get("parent_id") or "")
        guard += 1
    return "/".join(reversed(parts))


def folder_depth(folders, folder_id):
    idx = folder_index(folders)
    depth = 0
    cur = idx.get(str(folder_id or ""))
    guard = 0
    while cur and guard <= MAX_FOLDER_DEPTH + 2:
        depth += 1
        cur = idx.get(cur.get("parent_id") or "")
        guard += 1
    return depth


def check_folder_name(name):
    """校验文件夹名：非空、不含路径分隔符与控制字符、长度受限。"""
    name = str(name or "").strip()
    if not name:
        raise PortalError(400, "文件夹名称不能为空")
    if len(name) > MAX_FOLDER_NAME_LEN:
        raise PortalError(400, "文件夹名称不能超过 %d 个字符" % MAX_FOLDER_NAME_LEN)
    if "/" in name or "\\" in name or "\x00" in name:
        raise PortalError(400, "文件夹名称不能包含 / 或 \\ 等字符")
    return name


def ensure_folder_path(folders, path):
    """按 'a/b/c' 逐级创建（已存在则复用），返回叶子文件夹 id。"""
    parts = [p.strip() for p in str(path or "").split("/") if p.strip()]
    if not parts:
        return ""
    if len(parts) > MAX_FOLDER_DEPTH:
        raise PortalError(400, "文件夹层级最多 %d 层：%s" % (MAX_FOLDER_DEPTH, path))
    parent_id = ""
    for name in parts:
        name = check_folder_name(name)
        found = None
        for f in folders:
            if (f.get("parent_id") or "") == parent_id and f["name"] == name:
                found = f
                break
        if not found:
            if len(folders) >= MAX_FOLDERS_PER_KB:
                raise PortalError(400, "单个知识库最多 %d 个文件夹" % MAX_FOLDERS_PER_KB)
            found = {"id": "f_" + uuid.uuid4().hex[:12], "name": name, "parent_id": parent_id}
            folders.append(found)
        parent_id = found["id"]
    return parent_id


def collect_folder_ids(folders, folder_id):
    """收集该文件夹及其全部子孙 id。"""
    ids = {str(folder_id)}
    changed = True
    while changed:
        changed = False
        for f in folders:
            pid = f.get("parent_id") or ""
            if pid in ids and f["id"] not in ids:
                ids.add(f["id"])
                changed = True
    return ids


# ------------------------------------------------------------------
# 登录邮箱变更：WeKnora 未提供该 API，门户直连其 Postgres 容器完成更新
# ------------------------------------------------------------------
def run_psql(sql):
    """在 WeKnora 的 Postgres 容器内执行一条 SQL。"""
    cmd = ["docker", "exec", "-i", PG_CONTAINER,
           "psql", "-U", PG_USER, "-d", PG_DB, "-tAc", sql]
    try:
        proc = subprocess.run(cmd, capture_output=True, timeout=25)
    except FileNotFoundError:
        raise PortalError(503, "未找到 docker 命令，门户无法直连数据库，请联系系统管理员")
    except subprocess.TimeoutExpired:
        raise PortalError(504, "数据库操作超时，请稍后重试")
    if proc.returncode != 0:
        detail = (proc.stderr.decode("utf-8", "replace") or "").strip().splitlines()
        raise PortalError(500, "数据库操作失败：" + (detail[-1][:200] if detail else str(proc.returncode)))
    return proc.stdout.decode("utf-8", "replace").strip()


def update_login_email(user_id, new_email):
    """改登录邮箱：唯一性校验 → 更新 users.email → 撤销该用户全部会话。"""
    # 取值已通过白名单正则，不含引号 / 分号，可直接拼进 SQL
    if not SAFE_ID_RE.match(user_id):
        raise PortalError(400, "用户 ID 不合法")
    if not EMAIL_RE.match(new_email) or len(new_email) > 254:
        raise PortalError(400, "邮箱格式不合法")
    row = run_psql(
        "SELECT (SELECT count(*) FROM users WHERE lower(email)=lower('%s') AND id <> '%s')"
        " || '|' || (SELECT count(*) FROM users WHERE id='%s' AND deleted_at IS NULL);"
        % (new_email, user_id, user_id)
    )
    dup, exists = (row.split("|") + ["0", "0"])[:2]
    if exists.strip() == "0":
        raise PortalError(404, "用户不存在")
    if dup.strip() != "0":
        raise PortalError(409, "该邮箱已被其它账号使用")
    run_psql("UPDATE users SET email='%s', updated_at=now() WHERE id='%s';" % (new_email, user_id))
    # 邮箱即登录账号：撤销会话，强制用新邮箱重新登录
    run_psql("DELETE FROM auth_tokens WHERE user_id='%s';" % user_id)
    return {"user_id": user_id, "email": new_email}


# ------------------------------------------------------------------
# 受保护的系统管理员账号（默认 admin@obara.local，与 admin_gate.py 的 GATE_ADMIN_EMAILS 一致）
#   任何人都不能改它的角色 / 登录邮箱 / 密码，包括它自己
# ------------------------------------------------------------------
PROTECTED_ADMIN_EMAILS = {
    e.strip().lower()
    for e in os.environ.get("PORTAL_ADMIN_EMAILS", "admin@obara.local").split(",")
    if e.strip()
}

_ADMIN_USER_CACHE = {}      # user_id -> (过期时间戳, 是否受保护)
_ADMIN_USER_TTL = 60        # 秒
_ADMIN_USER_LOCK = threading.Lock()
_ADMIN_FLAG_COL = {"checked": False, "exists": False}


def users_has_admin_flag():
    """探测 users 表是否有 is_system_admin 列（不同版本 WeKnora 可能没有）。"""
    if _ADMIN_FLAG_COL["checked"]:
        return _ADMIN_FLAG_COL["exists"]
    exists = False
    try:
        out = run_psql("SELECT count(*) FROM information_schema.columns"
                       " WHERE table_name='users' AND column_name='is_system_admin';")
        exists = (out or "0").strip().splitlines()[-1] == "1"
    except PortalError:
        exists = False
    _ADMIN_FLAG_COL["checked"] = True
    _ADMIN_FLAG_COL["exists"] = exists
    return exists


def fetch_protected_admin(user_id):
    """按 users 表判断该账号是否属于受保护的系统管理员（超管标识 / 邮箱 / 用户名）。"""
    uid = str(user_id or "")
    if not SAFE_ID_RE.match(uid):
        return False
    emails = " OR ".join("lower(coalesce(email, '')) = '%s'" % sql_lit(e)
                         for e in sorted(PROTECTED_ADMIN_EMAILS)) or "false"
    flag = "coalesce(is_system_admin, false)" if users_has_admin_flag() else "false"
    out = run_psql("SELECT (%s OR lower(coalesce(username, '')) = 'admin' OR %s)"
                   " FROM users WHERE id = '%s' AND deleted_at IS NULL;" % (emails, flag, uid))
    lines = (out or "").strip().splitlines()
    return bool(lines) and lines[-1].lower() in ("t", "true", "1")


def is_protected_admin_user(user_id):
    """带短期缓存的判定；无法确定时返回 None（调用方按场景决定是否放行）。"""
    uid = str(user_id or "")
    if not uid:
        return None
    now = time.time()
    with _ADMIN_USER_LOCK:
        hit = _ADMIN_USER_CACHE.get(uid)
        if hit and hit[0] > now:
            return hit[1]
    try:
        protected = fetch_protected_admin(uid)
    except PortalError as e:
        sys.stderr.write("[WARN] 判定受保护管理员账号失败：%s\n" % e.message)
        return None
    with _ADMIN_USER_LOCK:
        _ADMIN_USER_CACHE[uid] = (now + _ADMIN_USER_TTL, protected)
    return protected


def is_protected_admin_email(email):
    return str(email or "").strip().lower() in PROTECTED_ADMIN_EMAILS


# ------------------------------------------------------------------
# 系统管理员审计视图：全员会话 / 文档上传记录
#
# 为什么直连数据库：
#   /sessions 由后端按 user_id 过滤，只能查到自己；文档上传人也只存在于 audit_logs
#   （对外仅有按部门的 /tenants/{id}/audit-log）。要让超管在一个页面里看全平台，
#   只能走与「修改登录邮箱」相同的通路，对该库做只读查询 —— 不写业务数据，
#   唯一的写操作是「删除某个成员的会话」，语义与后端 /sessions/{id} 的软删除一致。
# ------------------------------------------------------------------
AUDIT_DEFAULT_PAGE_SIZE = 20
AUDIT_MAX_PAGE_SIZE = 100
AUDIT_MESSAGE_LIMIT = 500          # 单个会话最多返回的消息条数
AUDIT_CONTENT_LIMIT = 8000         # 单条消息正文最多返回的字符数


def sql_lit(value):
    """把用户输入放进 SQL 字符串常量：转义单引号，并剔掉 LIKE 通配符（避免误当通配谓语）。"""
    return str(value or "").replace("'", "''").replace("\\", "").replace("%", "").replace("_", "")


def sql_id(value):
    """校验 id 型过滤值（UUID / 纯数字），非法值返回空串。"""
    v = str(value or "").strip()
    return v if SAFE_ID_RE.match(v) else ""


def sql_int(value, lo, hi, default):
    """把分页等数值限制在 [lo, hi] 区间内，非法值回落到 default。"""
    try:
        v = int(str(value))
    except (TypeError, ValueError):
        return default
    return lo if v < lo else (hi if v > hi else v)


def query_json(sql, expect="list"):
    """执行一条返回单个 JSON 值的 SQL 并解析（list / object 两种形态）。"""
    out = (run_psql(sql) or "").strip()
    if not out:
        return [] if expect == "list" else {}
    try:
        return json.loads(out)
    except ValueError:
        raise PortalError(500, "数据库返回无法解析")


class PortalHandler(BaseHTTPRequestHandler):
    # 允许的上游路径前缀（白名单，避免代理到非 API 路径）
    API_PREFIX = "/api/"

    def log_message(self, format, *args):
        sys.stderr.write("[%s] %s\n" % (self.log_date_time_string(), format % args))

    # ---------- 静态文件 ----------
    def serve_static(self, path):
        if path in ("/", "/register"):
            # 门户是单页应用：/register?token=... 等路由回落到 index.html
            path = "/index.html"
        # 防止目录穿越
        safe = os.path.normpath(path).lstrip("/\\")
        full = os.path.join(STATIC_DIR, safe)
        if not full.startswith(STATIC_DIR) or not os.path.isfile(full):
            path_only = urlparse(path).path
            if "." not in os.path.basename(path_only):
                path = "/index.html"
            else:
                self.send_error(404, "Not Found")
                return
            safe = os.path.normpath(path).lstrip("/\\")
            full = os.path.join(STATIC_DIR, safe)
        ext = os.path.splitext(full)[1].lower()
        ctype = CONTENT_TYPES.get(ext, "application/octet-stream")
        with open(full, "rb") as f:
            data = f.read()
        self.send_response(200)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        # 前端资源每次校验：避免浏览器缓存旧版页面 / 脚本导致新功能不生效
        self.send_header("Cache-Control", "no-cache, must-revalidate")
        self.end_headers()
        self.wfile.write(data)

    # ---------- 角色守卫 ----------
    def is_manage_request(self):
        """是否为需要文档管理员权限的管理类写操作。"""
        if not ENFORCE_ROLE or self.command not in MANAGE_METHODS:
            return False
        path = urlparse(self.path).path
        return any(rule.match(path) for rule in MANAGE_PATH_RULES)

    def check_manage_role(self):
        """返回 (是否放行, 拒绝原因)。放行条件下原因为空字符串。"""
        auth = self.headers.get("Authorization", "")
        if not auth.lower().startswith("bearer "):
            # 未携带令牌：交给上游返回 401
            return True, ""
        token = auth.split(" ", 1)[1].strip()
        if not token:
            return True, ""

        info = get_upstream_roles(token)
        if info is None:
            # 角色无法确定，放行并依赖后端 RBAC
            return True, ""
        if info.get("privileged"):
            # 系统超管保留跨空间管理能力
            return True, ""

        tenant_id = (self.headers.get("X-Tenant-ID") or "").strip()
        if not tenant_id:
            # 无部门上下文时无法判定成员角色，交由后端处理
            return True, ""

        role = (info.get("roles") or {}).get(tenant_id, "")
        if role in MANAGE_ROLES:
            return True, ""
        return False, "仅本部门文档管理员（Owner）可执行该操作"

    def bearer_token(self):
        auth = self.headers.get("Authorization", "")
        if not auth.lower().startswith("bearer "):
            return ""
        return auth.split(" ", 1)[1].strip()

    def check_role_elevation(self, body):
        """成员/邀请类写入中把角色提为 Admin / Owner 的，仅系统管理员可执行。"""
        if not ENFORCE_ROLE or self.command not in MANAGE_METHODS or not body:
            return True, ""
        path = urlparse(self.path).path
        if not any(rule.match(path) for rule in ROLE_WRITE_PATHS):
            return True, ""
        try:
            payload = json.loads(body.decode("utf-8"))
        except (ValueError, UnicodeDecodeError):
            return True, ""
        role = str((payload or {}).get("role", "")).strip().lower()
        if role not in ELEVATED_ROLES:
            return True, ""
        token = self.bearer_token()
        if not token:
            return True, ""
        info = get_upstream_roles(token)
        # 上游不可达时放行，由后端 RBAC 兜底；系统管理员允许授予
        if info is None or info.get("privileged"):
            return True, ""
        return False, "仅系统管理员可将成员设置为管理员（Admin）或文档管理员（Owner）"

    def check_role_target(self):
        """改成员角色 / 移除成员时：只能操作「权限比自己低」的成员。

        权限等级 owner > admin > contributor > viewer：部门文档管理员（Owner）可
        调整 admin / contributor / viewer，同级（另一位 Owner，含在所有部门都是
        Owner 的系统管理员）不允许被改；系统管理员与身份不明的情况放行。
        """
        if not ENFORCE_ROLE or self.command not in MANAGE_METHODS:
            return True, ""
        m = MEMBER_ROLE_PATH.match(urlparse(self.path).path)
        if not m:
            return True, ""
        token = self.bearer_token()
        if not token:
            return True, ""
        # 受保护的系统管理员账号：任何人（含超管与它自己）都不可改其角色 / 移除它
        if is_protected_admin_user(m.group(2)):
            return False, "系统管理员（admin）的角色不可修改"
        info = get_upstream_roles(token)
        # 上游不可达时放行，由后端 RBAC 兜底；系统管理员不受限制
        if info is None or info.get("privileged"):
            return True, ""
        tenant_id, target_user = m.group(1), m.group(2)
        caller_rank = ROLE_RANK.get((info.get("roles") or {}).get(tenant_id, ""), -1)
        if caller_rank < 0:
            # 部门内角色未知：由管理类鉴权（仅 Owner 可执行）与后端 RBAC 兜底
            return True, ""
        members = get_member_roles(token, tenant_id)
        if not members:
            return True, ""
        target_rank = ROLE_RANK.get(members.get(target_user, ""), -1)
        if target_rank < 0 or target_rank < caller_rank:
            return True, ""
        return False, "只能修改权限比自己低的成员的角色（同级或更高权限的成员仅系统管理员可调整）"

    def check_reset_password(self, body):
        """重置密码：受保护的系统管理员账号任何人都不可重置，包括它自己。"""
        if self.command != "POST" or not body:
            return True, ""
        if not RESET_PASSWORD_PATH.match(urlparse(self.path).path):
            return True, ""
        try:
            payload = json.loads(body.decode("utf-8"))
        except (ValueError, UnicodeDecodeError):
            return True, ""
        target_id = str((payload or {}).get("user_id", "")).strip()
        email = str((payload or {}).get("email", "")).strip().lower()
        if (target_id and is_protected_admin_user(target_id)) or is_protected_admin_email(email):
            return False, "系统管理员（admin）的密码不可重置"
        return True, ""

    def check_register(self):
        """注册管控：自助注册一律禁止；邀请注册可用 PORTAL_ALLOW_INVITE_REGISTER 关闭。"""
        if self.command != "POST":
            return True, ""
        path = urlparse(self.path).path
        if SELF_REGISTER_PATH.match(path):
            return False, "系统不开放自助注册，账号由管理员统一开通，请联系系统管理员"
        if INVITE_REGISTER_PATH.match(path) and not ALLOW_INVITE_REGISTER:
            return False, "系统已关闭注册，账号由管理员统一开通，请联系系统管理员"
        return True, ""

    def check_disabled_agent(self, body):
        """本部门已停用的内置智能体不允许发起问答。"""
        if self.command != "POST" or not body:
            return True, ""
        if not CHAT_PATH.match(urlparse(self.path).path):
            return True, ""
        try:
            payload = json.loads(body.decode("utf-8"))
        except (ValueError, UnicodeDecodeError):
            return True, ""
        agent_id = str((payload or {}).get("agent_id", "")).strip()
        tenant_id = (self.headers.get("X-Tenant-ID") or "").strip()
        if not agent_id or not tenant_id:
            return True, ""
        if is_agent_disabled(tenant_id, agent_id):
            return False, "该内置智能体已在本部门停用，请联系系统管理员启用"
        return True, ""

    def read_body(self):
        length = int(self.headers.get("Content-Length", 0) or 0)
        return self.rfile.read(length) if length > 0 else b""

    # ---------- 门户自有接口（/api/v1/portal/*，不转发上游） ----------
    def caller_info(self):
        """解析调用者身份；无令牌返回 None，身份无法确定时抛 PortalError。"""
        token = self.bearer_token()
        if not token:
            return None
        info = get_upstream_roles(token)
        if info is None:
            raise PortalError(503, "暂时无法校验身份（上游不可用），请稍后重试")
        return info

    def require_authenticated(self):
        info = self.caller_info()
        if info is None:
            raise PortalError(401, "未携带有效令牌，请重新登录")
        return info

    def require_privileged(self):
        info = self.require_authenticated()
        if not info.get("privileged"):
            raise PortalError(403, "仅系统管理员可执行该操作")
        return info

    def request_tenant_id(self, info):
        """优先 query tenant_id / X-Tenant-ID，其次令牌所属的第一个空间。"""
        query = parse_qs(urlparse(self.path).query)
        tid = (query.get("tenant_id", [""])[0] or self.headers.get("X-Tenant-ID") or "").strip()
        if not tid:
            tid = next(iter((info.get("roles") or {})), "")
        return str(tid)

    def portal_get_builtin_agents(self, info):
        tid = self.request_tenant_id(info)
        tenants = load_agent_toggles()["tenants"]
        disabled = sorted([aid for aid, enabled in tenants.get(tid, {}).items() if enabled is False])
        data = {"tenant_id": tid, "disabled": disabled}
        # 系统管理员额外返回全量映射，便于一次查看各部门启停
        if info.get("privileged"):
            data["tenants"] = tenants
        self.send_json(200, {"success": True, "data": data})

    def portal_set_builtin_agent(self, info, payload):
        agent_id = str(payload.get("agent_id", "")).strip()
        enabled = payload.get("enabled")
        if not agent_id or not isinstance(enabled, bool) or not SAFE_ID_RE.match(agent_id):
            raise PortalError(400, "缺少或非法的 agent_id / enabled（enabled 需为布尔值）")
        tid = str(payload.get("tenant_id", "")).strip() or self.request_tenant_id(info)
        if not tid or not str(tid).isdigit():
            raise PortalError(400, "缺少或非法的 tenant_id")
        tenants = {k: dict(v) for k, v in load_agent_toggles()["tenants"].items()}
        entry = dict(tenants.get(tid, {}))
        if enabled:
            entry.pop(agent_id, None)
        else:
            entry[agent_id] = False
        if entry:
            tenants[tid] = entry
        else:
            tenants.pop(tid, None)
        save_agent_toggles(tenants)
        sys.stderr.write("[TOGGLE] tenant=%s agent=%s -> %s by %s\n"
                         % (tid, agent_id, "启用" if enabled else "禁用", info.get("email") or info.get("user_id")))
        self.send_json(200, {"success": True, "data": {"tenant_id": tid, "agent_id": agent_id, "enabled": enabled}})

    def portal_update_email(self, info, payload):
        target = str(payload.get("user_id", "")).strip()
        email = str(payload.get("email", "")).strip().lower()
        if not target or not email:
            raise PortalError(400, "缺少 user_id 或 email")
        # 任何人都不能修改自己的登录邮箱（门户已移除该入口，此处为接口层兜底）
        if target == (info.get("user_id") or ""):
            raise PortalError(403, "不支持自助修改登录邮箱，请联系系统管理员")
        # 改他人必须系统管理员
        if not info.get("privileged"):
            raise PortalError(403, "仅系统管理员可修改他人登录邮箱")
        # 受保护的系统管理员账号：任何人都不可修改，包括它自己
        if is_protected_admin_email(email) or is_protected_admin_user(target):
            raise PortalError(403, "系统管理员（admin）的登录邮箱不可修改")
        result = update_login_email(target, email)
        sys.stderr.write("[EMAIL] user=%s -> %s by %s\n" % (target, email, info.get("email") or info.get("user_id")))
        self.send_json(200, {"success": True, "data": result})

    # ---------- 文档文件夹（门户侧元数据） ----------
    def query_param(self, key):
        query = parse_qs(urlparse(self.path).query)
        return (query.get(key, [""])[0] or "").strip()

    def require_doc_manage(self, info, tenant_id):
        """文档文件夹的写操作：本部门文档管理员（Owner）或系统管理员。"""
        if info.get("privileged"):
            return
        role = (info.get("roles") or {}).get(str(tenant_id), "")
        if role in MANAGE_ROLES:
            return
        raise PortalError(403, "仅本部门文档管理员（Owner）可管理文档文件夹")

    def portal_get_doc_folders(self, info):
        kb_id = self.query_param("kb_id")
        if not kb_id:
            raise PortalError(400, "缺少 kb_id")
        tid = self.request_tenant_id(info)
        entry = load_doc_folders()["tenants"].get(tid, {}).get("kbs", {}).get(kb_id) or {}
        folders = entry.get("folders", [])
        self.send_json(200, {"success": True, "data": {
            "tenant_id": tid,
            "kb_id": kb_id,
            "folders": [{
                "id": f["id"],
                "name": f["name"],
                "parent_id": f["parent_id"],
                "path": folder_path(folders, f["id"]),
            } for f in folders],
            "docs": entry.get("docs", {}),
        }})

    def portal_write_doc_folders(self, info, payload):
        kb_id = str(payload.get("kb_id", "")).strip()
        if not kb_id:
            raise PortalError(400, "缺少 kb_id")
        tid = str(payload.get("tenant_id", "")).strip() or self.request_tenant_id(info)
        if not tid:
            raise PortalError(400, "缺少部门上下文")
        self.require_doc_manage(info, tid)

        action = str(payload.get("action", "")).strip()
        tenants = clone_doc_folders(load_doc_folders())
        tenant_entry = tenants.setdefault(tid, {"kbs": {}})
        kb_entry = tenant_entry["kbs"].setdefault(kb_id, {"folders": [], "docs": {}})
        folders = kb_entry["folders"]
        docs = kb_entry["docs"]
        result = {}

        if action == "create":
            name = check_folder_name(payload.get("name"))
            parent_id = str(payload.get("parent_id", "") or "")
            if parent_id:
                if parent_id not in folder_index(folders):
                    raise PortalError(404, "父文件夹不存在")
                if folder_depth(folders, parent_id) >= MAX_FOLDER_DEPTH:
                    raise PortalError(400, "文件夹层级最多 %d 层" % MAX_FOLDER_DEPTH)
            if any(f for f in folders
                   if (f.get("parent_id") or "") == parent_id and f["name"] == name):
                raise PortalError(409, "同级下已存在同名文件夹")
            if len(folders) >= MAX_FOLDERS_PER_KB:
                raise PortalError(400, "单个知识库最多 %d 个文件夹" % MAX_FOLDERS_PER_KB)
            folder = {"id": "f_" + uuid.uuid4().hex[:12], "name": name, "parent_id": parent_id}
            folders.append(folder)
            result = {"folder": {"id": folder["id"], "name": name,
                                 "parent_id": parent_id, "path": folder_path(folders, folder["id"])}}

        elif action == "rename":
            name = check_folder_name(payload.get("name"))
            folder_id = str(payload.get("id", "") or "")
            folder = folder_index(folders).get(folder_id)
            if not folder:
                raise PortalError(404, "文件夹不存在")
            parent_id = folder.get("parent_id") or ""
            if any(f for f in folders
                   if f["id"] != folder_id and (f.get("parent_id") or "") == parent_id and f["name"] == name):
                raise PortalError(409, "同级下已存在同名文件夹")
            folder["name"] = name

        elif action == "delete":
            folder_id = str(payload.get("id", "") or "")
            if folder_id not in folder_index(folders):
                raise PortalError(404, "文件夹不存在")
            removed = collect_folder_ids(folders, folder_id)
            kb_entry["folders"] = [f for f in folders if f["id"] not in removed]
            for doc_id, fid in list(docs.items()):
                if fid in removed:
                    docs[doc_id] = ""      # 文件夹删除后文档回到「未分类」
            result = {"removed": len(removed)}

        elif action == "ensure_paths":
            raw_paths = payload.get("paths")
            if not isinstance(raw_paths, list) or not raw_paths:
                raise PortalError(400, "缺少 paths")
            if len(raw_paths) > 200:
                raise PortalError(400, "一次最多创建 200 个文件夹路径")
            mapping = {}
            for p in raw_paths:
                path = "/".join([x.strip() for x in str(p or "").split("/") if x.strip()])
                if not path:
                    continue
                mapping[path] = ensure_folder_path(folders, path)
            result = {"paths": mapping}

        elif action == "move_docs":
            raw_ids = payload.get("doc_ids")
            if not isinstance(raw_ids, list) or not raw_ids:
                raise PortalError(400, "缺少 doc_ids")
            if len(raw_ids) > 1000:
                raise PortalError(400, "一次最多移动 1000 个文档")
            folder_id = str(payload.get("folder_id", "") or "")
            if folder_id and folder_id not in folder_index(folders):
                raise PortalError(404, "目标文件夹不存在")
            moved = 0
            for doc_id in raw_ids:
                did = str(doc_id).strip()
                if not did:
                    continue
                docs[did] = folder_id
                moved += 1
            result = {"moved": moved, "folder_id": folder_id}

        elif action == "prune":
            raw_ids = payload.get("doc_ids")
            if not isinstance(raw_ids, list):
                raise PortalError(400, "缺少 doc_ids")
            valid = {str(x) for x in raw_ids}
            for doc_id in list(docs.keys()):
                if doc_id not in valid:
                    docs.pop(doc_id, None)
            result = {"pruned": True}

        else:
            raise PortalError(400, "未知操作：" + (action or "(空)"))

        # 清理空条目，避免文件无限增长
        if not kb_entry["folders"] and not kb_entry["docs"]:
            tenant_entry["kbs"].pop(kb_id, None)
        if not tenant_entry["kbs"]:
            tenants.pop(tid, None)
        save_doc_folders(tenants)

        final_folders = kb_entry["folders"]
        self.send_json(200, {"success": True, "data": dict(result, **{
            "tenant_id": tid,
            "kb_id": kb_id,
            "folders": [{
                "id": f["id"],
                "name": f["name"],
                "parent_id": f["parent_id"],
                "path": folder_path(final_folders, f["id"]),
            } for f in final_folders],
            "docs": kb_entry["docs"],
        })})

    # ---------- 上传限制（读取全员可见，修改仅系统管理员） ----------
    def portal_get_upload_limits(self, info):
        self.send_json(200, {"success": True, "data": {
            "limits": load_upload_limits(),
            "defaults": dict(UPLOAD_LIMIT_DEFAULTS),
            "ranges": {k: {"min": lo, "max": hi} for k, (lo, hi) in UPLOAD_LIMIT_RANGES.items()},
            "labels": dict(UPLOAD_LIMIT_LABELS),
            "editable": bool(info.get("privileged")),
        }})

    def portal_set_upload_limits(self, info, payload):
        limits = load_upload_limits()
        for key in UPLOAD_LIMIT_DEFAULTS:
            if key not in payload:
                continue
            value = payload[key]
            if isinstance(value, bool) or not isinstance(value, (int, float)) or int(value) != value:
                raise PortalError(400, "%s 必须是整数" % UPLOAD_LIMIT_LABELS[key])
            value = int(value)
            lo, hi = UPLOAD_LIMIT_RANGES[key]
            if value < lo or value > hi:
                raise PortalError(400, "%s 需在 %d ~ %d 之间" % (UPLOAD_LIMIT_LABELS[key], lo, hi))
            limits[key] = value
        if limits["max_total_size_mb"] < limits["max_file_size_mb"]:
            raise PortalError(400, "单次上传合计上限不能小于单个文件大小上限")
        save_upload_limits(limits)
        sys.stderr.write("[LIMIT] upload limits -> %s by %s\n"
                         % (limits, info.get("email") or info.get("user_id")))
        self.send_json(200, {"success": True, "data": {
            "limits": limits,
            "ranges": {k: {"min": lo, "max": hi} for k, (lo, hi) in UPLOAD_LIMIT_RANGES.items()},
        }})

    # ---------- 系统管理员审计：全员会话 ----------
    def audit_page_args(self):
        """分页参数：(页码, 每页条数, 偏移量)，取值受 AUDIT_MAX_PAGE_SIZE 约束。"""
        page = sql_int(self.query_param("page"), 1, 100000, 1)
        size = sql_int(self.query_param("page_size"), 1, AUDIT_MAX_PAGE_SIZE, AUDIT_DEFAULT_PAGE_SIZE)
        return page, size, (page - 1) * size

    def audit_tenant_filter(self, alias="s"):
        """按 query 里的 tenant_id 生成部门过滤条件（留空表示全平台）。"""
        tid = str(self.query_param("tenant_id") or "").strip()
        return f" AND {alias}.tenant_id = {int(tid)}" if tid.isdigit() else ""

    def audit_user_filter(self, alias="s"):
        """按 query 里的 user_id 生成成员过滤条件。"""
        uid = sql_id(self.query_param("user_id"))
        return f" AND {alias}.user_id = '{uid}'" if uid else ""

    def portal_admin_conversations(self, info):
        """全员会话：按部门 / 成员 / 关键词检索，带会话数与人数统计。"""
        page, size, offset = self.audit_page_args()
        where = (" WHERE s.deleted_at IS NULL"
                 + self.audit_tenant_filter("s")
                 + self.audit_user_filter("s"))
        kw = sql_lit(self.query_param("keyword"))
        if kw:
            where += (f" AND (s.title ILIKE '%{kw}%'"
                      f" OR coalesce(u.username, '') ILIKE '%{kw}%'"
                      f" OR coalesce(u.email, '') ILIKE '%{kw}%')")
        base = (" FROM sessions s"
                " LEFT JOIN users u ON u.id = s.user_id"
                " LEFT JOIN tenants t ON t.id = s.tenant_id"
                + where)

        items = query_json(f"""
            SELECT coalesce(json_agg(row_to_json(q)), '[]'::json) FROM (
              SELECT s.id, s.tenant_id, coalesce(t.name, '空间 ' || s.tenant_id) AS tenant_name,
                     coalesce(s.user_id, '') AS user_id,
                     coalesce(u.username, u.email, '未知用户') AS user_name,
                     coalesce(u.email, '') AS user_email,
                     coalesce(s.title, '未命名会话') AS title,
                     coalesce(s.agent_id, '') AS agent_id,
                     s.created_at, s.updated_at,
                     (SELECT count(*) FROM messages m
                       WHERE m.session_id = s.id AND m.deleted_at IS NULL) AS message_count
              {base}
              ORDER BY s.updated_at DESC NULLS LAST
              LIMIT {size} OFFSET {offset}
            ) q
        """) or []
        stats = query_json(f"""
            SELECT coalesce(row_to_json(q), '{{}}'::json) FROM (
              SELECT count(*) AS sessions,
                     count(DISTINCT s.user_id) AS users,
                     count(DISTINCT s.tenant_id) AS tenants
              {base}
            ) q
        """, expect="object") or {}

        self.send_json(200, {"success": True, "data": {
            "items": items,
            "page": page,
            "page_size": size,
            "total": int(stats.get("sessions") or 0),
            "stats": stats,
        }})

    def portal_admin_conversation_detail(self, info, session_id):
        """任一成员的会话详情：会话归属 + 完整问答消息。"""
        sid = sql_id(session_id)
        if not sid:
            raise PortalError(400, "会话 ID 不合法")
        rows = query_json(f"""
            SELECT coalesce(json_agg(row_to_json(q)), '[]'::json) FROM (
              SELECT s.id, coalesce(s.title, '未命名会话') AS title, s.tenant_id,
                     coalesce(t.name, '空间 ' || s.tenant_id) AS tenant_name,
                     coalesce(s.user_id, '') AS user_id,
                     coalesce(u.username, u.email, '未知用户') AS user_name,
                     coalesce(u.email, '') AS user_email,
                     coalesce(s.agent_id, '') AS agent_id,
                     s.created_at, s.updated_at
              FROM sessions s
              LEFT JOIN users u ON u.id = s.user_id
              LEFT JOIN tenants t ON t.id = s.tenant_id
              WHERE s.id = '{sid}' AND s.deleted_at IS NULL
            ) q
        """) or []
        if not rows:
            raise PortalError(404, "会话不存在或已被删除")
        messages = query_json(f"""
            SELECT coalesce(json_agg(row_to_json(q)), '[]'::json) FROM (
              SELECT m.id, m.role,
                     left(coalesce(m.content, ''), {AUDIT_CONTENT_LIMIT}) AS content,
                     length(coalesce(m.content, '')) > {AUDIT_CONTENT_LIMIT} AS truncated,
                     m.created_at, coalesce(m.model_id, '') AS model_id,
                     coalesce(m.knowledge_references, '[]'::jsonb) AS knowledge_references
              FROM messages m
              WHERE m.session_id = '{sid}' AND m.deleted_at IS NULL
              ORDER BY m.created_at ASC, m.id ASC
              LIMIT {AUDIT_MESSAGE_LIMIT}
            ) q
        """) or []
        self.send_json(200, {"success": True, "data": {
            "session": rows[0],
            "messages": messages,
            "message_limit": AUDIT_MESSAGE_LIMIT,
        }})

    def portal_admin_delete_conversation(self, info, payload):
        """删除某个成员的会话：软删除，语义与后端 DELETE /sessions/{id} 一致。"""
        sid = sql_id(payload.get("session_id"))
        if not sid:
            raise PortalError(400, "缺少 session_id")
        out = run_psql("WITH gone AS (UPDATE sessions SET deleted_at = now(), updated_at = now()"
                       f" WHERE id = '{sid}' AND deleted_at IS NULL RETURNING 1)"
                       " SELECT count(*) FROM gone;")
        try:
            affected = int((out or "0").strip().splitlines()[-1])
        except ValueError:
            affected = 0
        if affected == 0:
            raise PortalError(404, "会话不存在或已被删除")
        sys.stderr.write("[ADMIN] session=%s deleted by %s\n"
                         % (sid, info.get("email") or info.get("user_id")))
        self.send_json(200, {"success": True, "data": {"session_id": sid}})

    # ---------- 系统管理员审计：文档上传记录 ----------
    def portal_admin_uploads(self, info):
        """文档上传记录：来自 audit_logs 的 knowledge.created，含上传人 / 部门 / 知识库 / 文档状态。"""
        page, size, offset = self.audit_page_args()
        where = (" WHERE a.action = 'knowledge.created'"
                 + self.audit_tenant_filter("a")
                 + self.audit_user_filter("a"))
        kw = sql_lit(self.query_param("keyword"))
        if kw:
            where += (f" AND (coalesce(a.details->>'title', '') ILIKE '%{kw}%'"
                      f" OR coalesce(k.file_name, '') ILIKE '%{kw}%'"
                      f" OR coalesce(kb.name, '') ILIKE '%{kw}%'"
                      f" OR coalesce(u.username, '') ILIKE '%{kw}%'"
                      f" OR coalesce(u.email, '') ILIKE '%{kw}%')")
        base = (" FROM audit_logs a"
                " LEFT JOIN users u ON u.id = a.actor_user_id"
                " LEFT JOIN tenants t ON t.id = a.tenant_id"
                " LEFT JOIN knowledges k ON k.id = a.target_id"
                " LEFT JOIN knowledge_bases kb ON kb.id = k.knowledge_base_id"
                " LEFT JOIN tenant_members tm ON tm.user_id = a.actor_user_id"
                " AND tm.tenant_id = a.tenant_id AND tm.deleted_at IS NULL"
                + where)

        items = query_json(f"""
            SELECT coalesce(json_agg(row_to_json(q)), '[]'::json) FROM (
              SELECT a.id AS log_id, coalesce(a.tenant_id, 0) AS tenant_id,
                     coalesce(t.name, '空间 ' || a.tenant_id) AS tenant_name,
                     coalesce(a.actor_user_id, '') AS user_id,
                     coalesce(u.username, u.email, '未知用户') AS user_name,
                     coalesce(u.email, '') AS user_email,
                     coalesce(tm.role, '') AS user_role,
                     coalesce(a.target_id, '') AS knowledge_id,
                     coalesce(a.details->>'title', k.file_name, '') AS file_name,
                     coalesce(a.details->>'file_type', k.file_type, '') AS file_type,
                     coalesce(a.details->>'source_type', '') AS source_type,
                     coalesce(k.knowledge_base_id, '') AS kb_id,
                     coalesce(kb.name, '') AS kb_name,
                     coalesce(k.file_size, 0) AS file_size,
                     coalesce(k.parse_status, '') AS parse_status,
                     (k.id IS NULL) AS removed,
                     (k.deleted_at IS NOT NULL) AS deleted,
                     a.created_at
              {base}
              ORDER BY a.created_at DESC
              LIMIT {size} OFFSET {offset}
            ) q
        """) or []
        stats = query_json(f"""
            SELECT coalesce(row_to_json(q), '{{}}'::json) FROM (
              SELECT count(*) AS uploads,
                     count(DISTINCT a.actor_user_id) AS uploaders,
                     coalesce(sum(coalesce(k.file_size, 0)), 0) AS total_size
              {base}
            ) q
        """, expect="object") or {}

        self.send_json(200, {"success": True, "data": {
            "items": items,
            "page": page,
            "page_size": size,
            "total": int(stats.get("uploads") or 0),
            "stats": stats,
        }})

    def portal_api(self, method):
        route = urlparse(self.path).path[len(PORTAL_API_PREFIX):].strip("/")
        body = self.read_body()
        try:
            payload = json.loads(body.decode("utf-8")) if body else {}
        except (ValueError, UnicodeDecodeError):
            self.send_json(400, {"error": {"message": "请求体不是合法 JSON"}})
            return
        try:
            if route == "builtin-agents" and method == "GET":
                self.portal_get_builtin_agents(self.require_authenticated())
                return
            if route == "builtin-agents" and method == "POST":
                self.portal_set_builtin_agent(self.require_privileged(), payload)
                return
            if route == "users/email" and method == "POST":
                self.portal_update_email(self.require_authenticated(), payload)
                return
            if route == "doc-folders" and method == "GET":
                self.portal_get_doc_folders(self.require_authenticated())
                return
            if route == "doc-folders" and method == "POST":
                self.portal_write_doc_folders(self.require_authenticated(), payload)
                return
            if route == "upload-limits" and method == "GET":
                self.portal_get_upload_limits(self.require_authenticated())
                return
            if route == "upload-limits" and method == "POST":
                self.portal_set_upload_limits(self.require_privileged(), payload)
                return
            # 系统管理员审计：全员会话 / 文档上传记录（权限由 require_privileged 校验）
            if route == "admin/conversations" and method == "GET":
                self.portal_admin_conversations(self.require_privileged())
                return
            if route == "admin/conversations" and method == "POST":
                self.portal_admin_delete_conversation(self.require_privileged(), payload)
                return
            if len(route.split("/")) == 4 and route.startswith("admin/conversations/") \
                    and route.endswith("/messages") and method == "GET":
                self.portal_admin_conversation_detail(self.require_privileged(), route.split("/")[2])
                return
            if route == "admin/uploads" and method == "GET":
                self.portal_admin_uploads(self.require_privileged())
                return
            self.send_json(404, {"error": {"message": "未知门户接口：" + route}})
        except PortalError as e:
            self.send_json(e.status, {"error": {"message": e.message}})
        except Exception as e:  # 兜底：单个请求异常不应打挂门户进程
            sys.stderr.write("[ERROR] portal api %s: %s\n" % (route, e))
            self.send_json(500, {"error": {"message": "门户内部错误：%s" % e}})

    def is_agent_list(self):
        return self.command == "GET" and AGENT_LIST_PATH.match(urlparse(self.path).path)

    def send_json(self, status, payload):
        body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    # ---------- API 反向代理 ----------
    def deny(self, reason):
        sys.stderr.write("[DENY] %s %s (%s)\n" % (self.command, self.path, reason))
        self.send_json(403, {"error": {"message": reason}})

    def deny_with(self, status, reason):
        sys.stderr.write("[DENY] %s %s (%s) -> %s\n" % (self.command, self.path, reason, status))
        self.send_json(status, {"error": {"message": reason}})

    def deny_redirect(self, reason, redirect="/"):
        """拒绝并让前端弹出提示后跳转到指定页面（如注册被拒 → 回到登录页）。"""
        sys.stderr.write("[DENY] %s %s (%s) -> 403 + redirect %s\n"
                         % (self.command, self.path, reason, redirect))
        self.send_json(403, {"error": {"message": reason, "redirect": redirect}})

    # ---------- 上传限制校验（代理层拦截，前端校验之外的兜底） ----------
    def check_upload_limits(self, body, content_type):
        limits = load_upload_limits()
        files = multipart_file_sizes(body, content_type)
        if not files:
            return True, ""
        if len(files) > limits["max_files_per_upload"]:
            return False, "单次上传文件数量 %d 个，超过限制（最多 %d 个）" % (
                len(files), limits["max_files_per_upload"])
        biggest_name, biggest = max(files, key=lambda x: x[1])
        if biggest > limits["max_file_size_mb"] * 1024 * 1024:
            return False, "文件「%s」大小 %s，超过单文件上限 %d MB" % (
                biggest_name, human_mb(biggest), limits["max_file_size_mb"])
        total = sum(size for _, size in files)
        if total > limits["max_total_size_mb"] * 1024 * 1024:
            return False, "本次上传合计 %s，超过单次上传上限 %d MB" % (
                human_mb(total), limits["max_total_size_mb"])
        return True, ""

    def proxy(self):
        body = self.read_body()

        # 注册管控：自助注册一律拒绝（前端无入口，此处为绕过前端调用接口的兜底）
        allowed, reason = self.check_register()
        if not allowed:
            self.deny_redirect(reason, "/")
            return

        # 文档上传：按系统管理员配置的限制拦截
        if self.command == "POST" and UPLOAD_PATH.match(urlparse(self.path).path):
            allowed, reason = self.check_upload_limits(body, self.headers.get("Content-Type", ""))
            if not allowed:
                self.deny_with(400, reason)
                return

        if self.is_manage_request():
            allowed, reason = self.check_manage_role()
            if not allowed:
                self.deny(reason)
                return

        allowed, reason = self.check_role_elevation(body)
        if not allowed:
            self.deny(reason)
            return

        allowed, reason = self.check_role_target()
        if not allowed:
            self.deny(reason)
            return

        # 成员角色即将变更：让本部门的成员角色缓存立即失效
        member_write = MEMBER_ROLE_PATH.match(urlparse(self.path).path)
        if member_write and self.command in MANAGE_METHODS:
            invalidate_member_roles(self.bearer_token(), member_write.group(1))

        allowed, reason = self.check_reset_password(body)
        if not allowed:
            self.deny(reason)
            return

        allowed, reason = self.check_disabled_agent(body)
        if not allowed:
            self.deny(reason)
            return

        method = self.command
        url = UPSTREAM + self.path

        headers = {}
        for k, v in self.headers.items():
            # accept-encoding 一并去掉：上游若返回 gzip，转发时会剥掉
            # content-encoding 头导致浏览器无法解压。
            if k.lower() in ("host", "content-length", "connection", "accept-encoding"):
                continue
            headers[k] = v
        headers["Accept-Encoding"] = "identity"

        req = urllib.request.Request(url, data=body or None, method=method, headers=headers)
        try:
            with urllib.request.urlopen(req, timeout=120) as resp:
                # 智能体列表需要按本部门启停标记重写，非流式 —— 读全量后一次性返回
                if self.is_agent_list():
                    payload = annotate_disabled_agents(resp.read(), self.headers.get("X-Tenant-ID", ""))
                    self.send_response(resp.status)
                    for k, v in resp.getheaders():
                        if k.lower() in ("transfer-encoding", "connection", "content-encoding",
                                         "content-length", "content-type"):
                            continue
                        self.send_header(k, v)
                    self.send_header("Content-Type", "application/json; charset=utf-8")
                    self.send_header("Content-Length", str(len(payload)))
                    self.end_headers()
                    self.wfile.write(payload)
                    return
                self.send_response(resp.status)
                for k, v in resp.getheaders():
                    if k.lower() in ("transfer-encoding", "connection", "content-encoding"):
                        continue
                    self.send_header(k, v)
                self.end_headers()
                # 流式转发（支持 SSE）
                while True:
                    chunk = resp.read(4096)
                    if not chunk:
                        break
                    self.wfile.write(chunk)
        except urllib.error.HTTPError as e:
            self.send_response(e.code)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            err_body = e.read()
            self.wfile.write(err_body if err_body else json.dumps({"error": str(e)}).encode())
        except Exception as e:
            self.send_response(502)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(json.dumps({"error": f"Upstream error: {e}"}).encode())

    # ---------- 路由分发 ----------
    def do_GET(self):
        if self.path.startswith(PORTAL_API_PREFIX):
            self.portal_api("GET")
        elif self.path.startswith(self.API_PREFIX):
            self.proxy()
        else:
            self.serve_static(self.path)

    def do_POST(self):
        if self.path.startswith(PORTAL_API_PREFIX):
            self.portal_api("POST")
        elif self.path.startswith(self.API_PREFIX):
            self.proxy()
        else:
            self.send_error(405)

    def do_PUT(self):
        if self.path.startswith(self.API_PREFIX):
            self.proxy()
        else:
            self.send_error(405)

    def do_DELETE(self):
        if self.path.startswith(self.API_PREFIX):
            self.proxy()
        else:
            self.send_error(405)

    def do_OPTIONS(self):
        # CORS 预检
        self.send_response(204)
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET,POST,PUT,DELETE,OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Authorization,Content-Type,X-Tenant-ID,X-API-Key,Accept")
        self.end_headers()


def main():
    # 解析命令行参数
    args = sys.argv[1:]
    i = 0
    while i < len(args):
        if args[i] == "--port" and i + 1 < len(args):
            global PORTAL_PORT
            PORTAL_PORT = int(args[i + 1])
            i += 2
        elif args[i] == "--upstream" and i + 1 < len(args):
            global UPSTREAM
            UPSTREAM = args[i + 1].rstrip("/")
            i += 2
        else:
            i += 1

    # 多线程：问答走 SSE 长连接，单线程会阻塞门户其它请求
    server = ThreadingHTTPServer(("0.0.0.0", PORTAL_PORT), PortalHandler)
    print(f"[OBARA Portal] 启动成功")
    print(f"  门户地址: http://0.0.0.0:{PORTAL_PORT}")
    print(f"  上游 API: {UPSTREAM}")
    print(f"  静态目录: {STATIC_DIR}")
    print(f"  管理类写操作鉴权: {'开启（仅文档管理员 Owner）' if ENFORCE_ROLE else '关闭'}")
    if ENFORCE_ROLE:
        print("  角色提权保护: 仅系统管理员可把成员设为 管理员 Admin / 文档管理员 Owner")
        print("  只能管理更低权限者: 部门文档管理员不可调整同级 / 更高权限成员")
    print("  受保护管理员账号: %s（角色 / 登录邮箱 / 密码任何人都不可改，含其本人）"
          % ", ".join(sorted(PROTECTED_ADMIN_EMAILS)))
    print("  自助改登录邮箱: 已关闭（仅系统管理员可改他人）")
    print("  自助注册: 已关闭（账号由管理员开通）")
    print("  邀请链接注册: %s（PORTAL_ALLOW_INVITE_REGISTER=%s）"
          % ("开启" if ALLOW_INVITE_REGISTER else "关闭", "true" if ALLOW_INVITE_REGISTER else "false"))
    print(f"  内置智能体启停文件: {AGENT_TOGGLE_FILE}")
    print(f"  邮箱变更直连数据库: docker exec {PG_CONTAINER} psql -d {PG_DB}")
    print(f"  按 Ctrl+C 停止")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\n[OBARA Portal] 已停止")
        server.server_close()


if __name__ == "__main__":
    main()
