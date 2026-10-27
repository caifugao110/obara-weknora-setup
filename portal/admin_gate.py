#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
OBARA 知识问答平台 — 80 端口（WeKnora 原生后台）登录守卫网关

背景：
  WeKnora 原生后台（前端容器）默认直接对外暴露 80 端口，任何员工都能登录并操作
  知识库 / 模型 / 智能体等高权限功能。按 OBARA 的部署约定：
    - 80  端口  = WeKnora 原生后台，仅超级管理员 admin@obara.local 可用
    - 8081 端口 = OBARA 门户，供全体员工问答与部门内管理使用

职责：
  1. 对外监听 80 端口，把请求反向代理到「已挪到内部端口」的 WeKnora 前端
     （默认 http://127.0.0.1:8088）
  2. 拦截登录类接口：非白名单邮箱直接 403，不落到后端
  3. 拦截已登录身份：带 Bearer 令牌的请求会校验令牌归属邮箱，非白名单一律 403
     （防止拿到令牌后绕过登录直接调用原生后台 API）

用法：
  python3 portal/admin_gate.py                       # 默认 0.0.0.0:80 → 127.0.0.1:8088
  GATE_PORT=8089 GATE_UPSTREAM=http://127.0.0.1:8088 python3 portal/admin_gate.py
  python3 portal/admin_gate.py --port 80 --upstream http://127.0.0.1:8088

环境变量：
  GATE_PORT          对外监听端口（默认 80）
  GATE_UPSTREAM      WeKnora 原生前端地址（默认 http://127.0.0.1:8088）
  GATE_ADMIN_EMAILS  允许登录原生后台的邮箱白名单，逗号分隔（默认 admin@obara.local）
  GATE_ENFORCE       是否开启守卫（默认 true；置 false 仅做透明代理，便于排障）
"""
import os
import sys
import json
import time
import threading
import urllib.request
import urllib.error
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler
from urllib.parse import urlparse

GATE_PORT = int(os.environ.get("GATE_PORT", "80"))
UPSTREAM = os.environ.get("GATE_UPSTREAM", "http://127.0.0.1:8088").rstrip("/")
ENFORCE = os.environ.get("GATE_ENFORCE", "true").lower() not in ("0", "false", "no")

# 允许登录 80 端口原生后台的邮箱（小写比较）
ADMIN_EMAILS = {
    e.strip().lower()
    for e in os.environ.get("GATE_ADMIN_EMAILS", "admin@obara.local").split(",")
    if e.strip()
}

# 登录类接口：直接按请求体里的邮箱判定
LOGIN_PATHS = ("/api/v1/auth/login",)
# 注册 / 自助开通类接口：原生后台不开放给普通员工
BLOCK_PATHS = (
    "/api/v1/auth/register",
    "/api/v1/auth/register-by-invite",
    "/api/v1/auth/forgot-password",
    "/api/v1/auth/reset-password",
)

# 令牌 -> (过期时间戳, 邮箱)
_TOKEN_CACHE = {}
_TOKEN_TTL = 120
_TOKEN_LOCK = threading.Lock()

BLOCK_MESSAGE = "80 端口为系统管理员专用后台；普通用户请使用 8081 端口的 OBARA 门户登录"


def deny_message(email=""):
    if email:
        return "账号 %s 无权限登录原生后台（%s）" % (email, BLOCK_MESSAGE)
    return BLOCK_MESSAGE


def resolve_token_email(token):
    """查询令牌归属邮箱；返回 None 表示无法确定（放行，由后端鉴权兜底）。"""
    now = time.time()
    with _TOKEN_LOCK:
        hit = _TOKEN_CACHE.get(token)
    if hit and hit[0] > now:
        return hit[1]
    req = urllib.request.Request(
        UPSTREAM + "/api/v1/auth/me",
        method="GET",
        headers={
            "Authorization": "Bearer " + token,
            "Accept": "application/json",
            "Accept-Encoding": "identity",
        },
    )
    email = None
    try:
        with urllib.request.urlopen(req, timeout=10) as resp:
            raw = json.loads(resp.read().decode("utf-8") or "{}")
    except urllib.error.HTTPError as e:
        if e.code in (401, 403):
            email = ""      # 令牌无效：身份未知，按邮箱为空处理（放行给后端返回 401）
        else:
            return None
    except Exception:
        return None          # 上游不可达：放行，避免误伤
    else:
        data = raw.get("data") or raw
        user = data.get("user") or {}
        email = (user.get("email") or data.get("email") or "").strip().lower()
    with _TOKEN_LOCK:
        _TOKEN_CACHE[token] = (now + _TOKEN_TTL, email)
    return email


class GateHandler(BaseHTTPRequestHandler):

    def log_message(self, format, *args):
        sys.stderr.write("[%s] %s\n" % (self.log_date_time_string(), format % args))

    # ---------- 工具 ----------
    def path_only(self):
        return urlparse(self.path).path

    def read_body(self):
        length = int(self.headers.get("Content-Length", 0) or 0)
        return self.rfile.read(length) if length > 0 else b""

    def bearer_token(self):
        auth = self.headers.get("Authorization", "")
        if not auth.lower().startswith("bearer "):
            return ""
        return auth.split(" ", 1)[1].strip()

    def deny(self, reason, status=403):
        sys.stderr.write("[DENY] %s %s (%s)\n" % (self.command, self.path_only(), reason))
        body = json.dumps({"success": False, "error": {"message": reason}},
                          ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    # ---------- 守卫 ----------
    def check_login(self, body):
        """登录接口：仅白名单邮箱可登录。"""
        path = self.path_only()
        if self.command != "POST" or path not in LOGIN_PATHS:
            return True, ""
        try:
            payload = json.loads(body.decode("utf-8")) if body else {}
        except (ValueError, UnicodeDecodeError):
            return True, ""   # 非 JSON：交给后端返回参数错误
        email = str((payload or {}).get("email", "")).strip().lower()
        if not email:
            return True, ""
        if email in ADMIN_EMAILS:
            return True, ""
        return False, deny_message(email)

    def check_blocked_paths(self):
        path = self.path_only()
        if self.command == "POST" and path in BLOCK_PATHS:
            return False, "原生后台不开放注册 / 自助找回密码；请联系系统管理员"
        return True, ""

    def check_token(self):
        """已登录身份：非白名单邮箱的令牌不允许访问原生后台 API。"""
        if not self.path_only().startswith("/api/"):
            return True, ""
        token = self.bearer_token()
        if not token:
            return True, ""
        email = resolve_token_email(token)
        if not email:
            return True, ""   # 无法确定身份（含令牌无效）时交由后端处理
        if email in ADMIN_EMAILS:
            return True, ""
        return False, deny_message(email)

    # ---------- 代理 ----------
    def proxy(self):
        body = self.read_body()

        if ENFORCE:
            for check in (self.check_blocked_paths,
                          lambda: self.check_login(body),
                          self.check_token):
                allowed, reason = check()
                if not allowed:
                    self.deny(reason)
                    return

        url = UPSTREAM + self.path
        headers = {}
        for k, v in self.headers.items():
            if k.lower() in ("host", "content-length", "connection", "accept-encoding"):
                continue
            headers[k] = v
        headers["Accept-Encoding"] = "identity"

        req = urllib.request.Request(url, data=body or None, method=self.command, headers=headers)
        try:
            with urllib.request.urlopen(req, timeout=300) as resp:
                self.send_response(resp.status)
                for k, v in resp.getheaders():
                    if k.lower() in ("transfer-encoding", "connection", "content-encoding"):
                        continue
                    self.send_header(k, v)
                self.end_headers()
                # 流式转发（问答走 SSE，需要边收边发）
                while True:
                    chunk = resp.read(8192)
                    if not chunk:
                        break
                    self.wfile.write(chunk)
        except urllib.error.HTTPError as e:
            err_body = e.read()
            self.send_response(e.code)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_header("Content-Length", str(len(err_body)))
            self.end_headers()
            self.wfile.write(err_body)
        except Exception as e:
            msg = json.dumps({"error": "Upstream error: %s" % e}, ensure_ascii=False).encode("utf-8")
            self.send_response(502)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_header("Content-Length", str(len(msg)))
            self.end_headers()
            self.wfile.write(msg)

    # ---------- 路由 ----------
    def do_GET(self): self.proxy()
    def do_POST(self): self.proxy()
    def do_PUT(self): self.proxy()
    def do_PATCH(self): self.proxy()
    def do_DELETE(self): self.proxy()
    def do_HEAD(self): self.proxy()

    def do_OPTIONS(self):
        self.send_response(204)
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET,POST,PUT,PATCH,DELETE,OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Authorization,Content-Type,X-Tenant-ID,X-API-Key,Accept")
        self.end_headers()


def main():
    args = sys.argv[1:]
    i = 0
    while i < len(args):
        if args[i] == "--port" and i + 1 < len(args):
            global GATE_PORT
            GATE_PORT = int(args[i + 1])
            i += 2
        elif args[i] == "--upstream" and i + 1 < len(args):
            global UPSTREAM
            UPSTREAM = args[i + 1].rstrip("/")
            i += 2
        else:
            i += 1

    server = ThreadingHTTPServer(("0.0.0.0", GATE_PORT), GateHandler)
    print("[OBARA Admin Gate] 启动成功")
    print("  对外端口: http://0.0.0.0:%d" % GATE_PORT)
    print("  上游前端: %s（WeKnora 原生后台，已移至内部端口）" % UPSTREAM)
    print("  登录守卫: %s" % ("开启" if ENFORCE else "关闭（透明代理）"))
    print("  允许登录: %s" % ", ".join(sorted(ADMIN_EMAILS)))
    print("  按 Ctrl+C 停止")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\n[OBARA Admin Gate] 已停止")
        server.server_close()


if __name__ == "__main__":
    main()
