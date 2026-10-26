#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
OBARA 知识问答平台 — 门户 HTTP 服务 + API 反向代理

职责：
  1. 服务静态文件（index.html / styles.css / app.js）
  2. 将 /api/* 反向代理到 WeKnora 后端（默认 127.0.0.1:8080），解决浏览器 CORS 问题

用法：
  python3 portal/server.py                          # 默认 0.0.0.0:8081 → 127.0.0.1:8080
  PORTAL_PORT=8082 WEKNORA_URL=http://192.168.1.10:8080 python3 portal/server.py
  python3 portal/server.py --port 8081 --upstream http://127.0.0.1:8080

二次鉴权：
  门户会在代理层拦截部门管理类「写操作」（成员/邀请、智能体、知识库与文档），
  仅允许当前部门内的文档管理员（Owner）执行，防止绕过前端直接调 API。
  可用 PORTAL_ENFORCE_ROLE=false 关闭（不推荐）。
"""
import os
import re
import sys
import json
import time
import threading
import urllib.request
import urllib.error
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler
from urllib.parse import urlparse

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

_ROLE_CACHE = {}          # token -> (过期时间戳, {roles: {...}, privileged: bool})
_ROLE_CACHE_TTL = 60      # 秒
_ROLE_LOCK = threading.Lock()


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
    return {"roles": roles, "privileged": privileged}


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

    def send_json(self, status, payload):
        body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    # ---------- API 反向代理 ----------
    def proxy(self):
        if self.is_manage_request():
            allowed, reason = self.check_manage_role()
            if not allowed:
                sys.stderr.write(
                    "[DENY] %s %s (%s)\n" % (self.command, self.path, reason)
                )
                self.send_json(403, {"error": {"message": reason}})
                return

        method = self.command
        url = UPSTREAM + self.path
        length = int(self.headers.get("Content-Length", 0) or 0)
        body = self.rfile.read(length) if length > 0 else None

        headers = {}
        for k, v in self.headers.items():
            # accept-encoding 一并去掉：上游若返回 gzip，转发时会剥掉
            # content-encoding 头导致浏览器无法解压。
            if k.lower() in ("host", "content-length", "connection", "accept-encoding"):
                continue
            headers[k] = v
        headers["Accept-Encoding"] = "identity"

        req = urllib.request.Request(url, data=body, method=method, headers=headers)
        try:
            with urllib.request.urlopen(req, timeout=120) as resp:
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
        if self.path.startswith(self.API_PREFIX):
            self.proxy()
        else:
            self.serve_static(self.path)

    def do_POST(self):
        if self.path.startswith(self.API_PREFIX):
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
    print(f"  按 Ctrl+C 停止")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\n[OBARA Portal] 已停止")
        server.server_close()


if __name__ == "__main__":
    main()
