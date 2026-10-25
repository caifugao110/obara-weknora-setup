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
"""
import os
import sys
import json
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

    # ---------- API 反向代理 ----------
    def proxy(self):
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
    print(f"  按 Ctrl+C 停止")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\n[OBARA Portal] 已停止")
        server.server_close()


if __name__ == "__main__":
    main()
