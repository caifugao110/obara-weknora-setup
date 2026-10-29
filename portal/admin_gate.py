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
  2. 只允许管理员登录：登录接口按邮箱白名单判定，非白名单直接 403，不落到后端
  3. 拦截已登录身份：带 Bearer 令牌的请求会校验令牌归属邮箱，非白名单一律 403
     （防止拿到令牌后绕过登录直接调用原生后台 API）
  4. 任何人都不能注册：注册 / 找回密码 / 重置密码类接口，以及注册类页面
     （/register、/signup 等 SPA 路由）一律 403，不落到上游
  5. 被拦截后的提示：向返回的 HTML 注入脚本，接管 fetch / XHR / SPA 路由，
     并用 MutationObserver 兜底；只弹一个居中卡片（隐藏原生 TDesign 提示条），
     倒计时结束跳转 8081 门户
  6. HTML 响应强制 Cache-Control: no-store，避免浏览器用旧页面导致守卫脚本失效

用法：
  python3 portal/admin_gate.py                       # 默认 0.0.0.0:80 → 127.0.0.1:8088
  GATE_PORT=8089 GATE_UPSTREAM=http://127.0.0.1:8088 python3 portal/admin_gate.py
  python3 portal/admin_gate.py --port 80 --upstream http://127.0.0.1:8088

环境变量：
  GATE_PORT          对外监听端口（默认 80）
  GATE_UPSTREAM      WeKnora 原生前端地址（默认 http://127.0.0.1:8088）
  GATE_ADMIN_EMAILS  允许登录原生后台的邮箱白名单，逗号分隔（默认 admin@obara.local）
  GATE_ENFORCE       是否开启守卫（默认 true；置 false 仅做透明代理，便于排障）
  GATE_PORTAL_URL    被拦截后跳转的门户登录页（默认 http://<请求Host>:8081/）
  GATE_PORTAL_PORT   未显式指定 GATE_PORTAL_URL 时使用的门户端口（默认 8081）
  GATE_REDIRECT_DELAY_MS  提示出现后停留多久再跳转（毫秒，默认 3000）

被拦截后的表现：非管理员登录 / 任何人进注册页时，原生后台自己弹出的提示（如
「账号 xxx 无权限登录原生后台…」）**不再重复弹窗**，右上角额外显示「N 秒后跳转到
8081 门户」的倒计时浮层，到时自动跳转；地址栏直接访问注册页时走提示页，同样倒计时跳转。
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
from html import escape

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
# 注册 / 自助开通类接口前缀：任何方法、任何人都禁止（员工账号一律由管理员开通）
BLOCK_PREFIXES = (
    "/api/v1/auth/register",
    "/api/v1/auth/forgot-password",
    "/api/v1/auth/reset-password",
    "/api/v1/auth/verify",
    "/api/v1/auth/activate",
)
# 注册 / 找回密码类页面（原生前端是 SPA，路由不走 /api）：直接返回提示页，不代理上游
BLOCK_PAGE_PREFIXES = ("/register", "/signup", "/forgot-password", "/reset-password")

REGISTER_BLOCK_MESSAGE = "系统不开放自助注册，账号由系统管理员统一开通；如需账号请联系管理员"

# 被拦截后跳转到的 OBARA 门户登录页：
#   GATE_PORTAL_URL 显式指定（如 http://192.168.1.10:8081/）；
#   未指定时按请求的 Host 拼 http://<host>:<GATE_PORTAL_PORT>/
PORTAL_URL = os.environ.get("GATE_PORTAL_URL", "").strip()
PORTAL_PORT_DEFAULT = int(os.environ.get("GATE_PORTAL_PORT", "8081"))

# 提示出现后停留多久再跳转（毫秒，默认 3 秒，够看清原生后台弹出的提示）
REDIRECT_DELAY_MS = int(os.environ.get("GATE_REDIRECT_DELAY_MS", "3000"))

# 令牌 -> (过期时间戳, 邮箱)
_TOKEN_CACHE = {}
_TOKEN_TTL = 120
_TOKEN_LOCK = threading.Lock()

BLOCK_MESSAGE = "80 端口为系统管理员专用后台；普通用户请使用 8081 端口的 OBARA 门户登录"

# ------------------------------------------------------------------
# 被拦截后的「居中弹窗 + 倒计时跳转」：提示页与注入脚本共用同一套样式与结构
# ------------------------------------------------------------------
REDIRECT_CSS = """
  body{margin:0;background:#f4f6fb}
  .obara-rd-mask{position:fixed;inset:0;z-index:2147483000;display:flex;align-items:center;
    justify-content:center;padding:24px;background:rgba(15,23,42,.55);
    font-family:'PingFang SC','Microsoft YaHei',Arial,sans-serif}
  .obara-rd-card{width:100%;max-width:440px;padding:32px 30px 26px;border-radius:18px;background:#fff;
    text-align:center;box-shadow:0 24px 60px rgba(15,23,42,.28);
    animation:obara-rd-in .18s ease-out}
  @keyframes obara-rd-in{from{opacity:0;transform:translateY(8px) scale(.98)}to{opacity:1;transform:none}}
  .obara-rd-icon{width:56px;height:56px;margin:0 auto 14px;border-radius:50%;display:flex;
    align-items:center;justify-content:center;color:#fff;
    background:linear-gradient(135deg,#2563eb,#1a56db);box-shadow:0 8px 20px rgba(37,99,235,.28)}
  .obara-rd-title{margin:0 0 10px;font-size:19px;color:#111827}
  .obara-rd-msg{margin:0 0 16px;font-size:14px;line-height:1.7;color:#4b5563;word-break:break-word}
  .obara-rd-count{font-size:13px;color:#6b7280}
  .obara-rd-count span{color:#2563eb;font-weight:700}
  .obara-rd-bar{margin:12px 0 18px;height:4px;border-radius:999px;background:#e5e7eb;overflow:hidden}
  .obara-rd-bar i{display:block;height:100%;width:100%;border-radius:999px;
    background:linear-gradient(90deg,#2563eb,#1a56db);transition:width 1s linear}
  .obara-rd-btn{display:block;padding:11px 16px;border-radius:10px;background:#2563eb;color:#fff;
    text-decoration:none;font-size:14px;font-weight:600;transition:background .15s}
  .obara-rd-btn:hover{background:#1a56db}
  .obara-rd-foot{margin:14px 0 0;font-size:12px;color:#9ca3af}
  /* 触发拦截时压掉原生前端自己的提示条（TDesign Message / Notification），只保留居中弹窗 */
  body.obara-blocked .t-message, body.obara-blocked .t-message__list,
  body.obara-blocked .t-notification, body.obara-blocked .t-notification-list,
  body.obara-blocked .t-notification__main{display:none !important}
"""

REDIRECT_CARD = """<div class="obara-rd-card" role="alertdialog" aria-modal="true">
  <div class="obara-rd-icon">
    <svg viewBox="0 0 24 24" width="26" height="26" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M10.3 3.9 1.8 18a2 2 0 0 0 1.7 3h17a2 2 0 0 0 1.7-3L13.7 3.9a2 2 0 0 0-3.4 0z"/><path d="M12 9v4"/><path d="M12 17h.01"/></svg>
  </div>
  <h2 class="obara-rd-title">无法继续</h2>
  <p class="obara-rd-msg" id="obara-rd-msg">{{MESSAGE}}</p>
  <div class="obara-rd-count"><span id="obara-rd-sec">3</span> 秒后自动跳转到 OBARA 门户（8081）</div>
  <div class="obara-rd-bar"><i id="obara-rd-bar-fill"></i></div>
  <a class="obara-rd-btn" href="{{PORTAL}}">立即前往 8081 门户</a>
  <p class="obara-rd-foot">OBARA 知识问答平台 · HTTP 403</p>
</div>"""

# 倒计时与跳转（提示页与注入脚本共用）
REDIRECT_TIMER_JS = """
  var P = {{PORTAL_JSON}};
  var TOTAL = Math.max(1, Math.round({{DELAY_MS}} / 1000));
  var started = false;
  function obaraStart(msg) {
    if (started) return;
    started = true;
    if (document.body) document.body.classList.add('obara-blocked');
    var mask = document.getElementById('obara-rd-mask');
    if (mask) mask.style.display = 'flex';
    var m = document.getElementById('obara-rd-msg');
    if (msg && m) m.textContent = msg;
    var sec = document.getElementById('obara-rd-sec');
    var bar = document.getElementById('obara-rd-bar-fill');
    var left = TOTAL;
    if (sec) sec.textContent = left;
    if (bar) bar.style.width = '100%';
    var timer = window.setInterval(function () {
      left -= 1;
      if (left <= 0) { window.clearInterval(timer); window.location.replace(P); return; }
      if (sec) sec.textContent = left;
      if (bar) bar.style.width = (left / TOTAL * 100) + '%';
    }, 1000);
  }
"""

# 页面被拦截时的提示页（注册 / 找回密码等路由）：居中弹窗 + 倒计时跳转
DENY_PAGE_HTML = """<!DOCTYPE html>
<html lang="zh-CN"><head><meta charset="UTF-8" />
<meta name="viewport" content="width=device-width, initial-scale=1.0" />
<title>不可访问 — OBARA 知识问答平台</title>
<style>{{CSS}}</style></head>
<body>
<div class="obara-rd-mask" id="obara-rd-mask">{{CARD}}</div>
<script>(function () { {{TIMER}} obaraStart(''); })();</script>
</body></html>
"""

# 注入原生前端页面的守卫脚本：
#   1. 登录 / 注册接口返回 403 → 不重复弹窗，在页面正中弹出卡片（原因 + 倒计时 + 立即前往），
#      倒计时结束后自动跳转到 8081 门户登录页
#   2. SPA 前端路由跳到 /register 等注册页 → 同样弹居中卡片并跳转
GUARD_SNIPPET = """<style>{{CSS}}</style>
<div class="obara-rd-mask" id="obara-rd-mask" style="display:none">{{CARD}}</div>
<script>
(function () {
  var MSG_REG = {{REGISTER_MESSAGE_JSON}};
  var API_RE = /\\/api\\/v1\\/auth\\/(login|register|register-by-invite|forgot-password|reset-password)(\\/|\\?|$)/;
  var PAGE_RE = /^\\/(register|signup|forgot-password|reset-password)(\\/|$)/;
  {{TIMER}}
  function message(text, fallback) {
    try {
      var d = JSON.parse(text || "{}");
      var e = d.error || {};
      return e.message || d.message || fallback;
    } catch (err) { return fallback; }
  }
  function watch(url, status, text) {
    if (status === 403 && API_RE.test(url || "")) obaraStart(message(text, MSG_REG));
  }
  var _fetch = window.fetch;
  if (_fetch) {
    window.fetch = function (input) {
      var url = typeof input === "string" ? input : (input && input.url) || "";
      return _fetch.apply(this, arguments).then(function (res) {
        if (res.status === 403 && API_RE.test(url)) {
          try { res.clone().text().then(function (t) { watch(url, 403, t); }); }
          catch (e) { watch(url, 403, ""); }
        }
        return res;
      });
    };
  }
  var XHR = window.XMLHttpRequest;
  if (XHR && XHR.prototype) {
    var _open = XHR.prototype.open, _send = XHR.prototype.send;
    XHR.prototype.open = function (method, url) { this.__obaraUrl = url; return _open.apply(this, arguments); };
    XHR.prototype.send = function () {
      var self = this;
      this.addEventListener("load", function () {
        if (self.status === 403 && API_RE.test(self.__obaraUrl || "")) {
          watch(self.__obaraUrl, 403, self.responseText || "");
        }
      });
      return _send.apply(this, arguments);
    };
  }
  // 兜底：不管前端用什么方式发请求 / 渲染提示，只要页面上出现了拦截文案就弹窗跳转
  // 只认网关注入的拦截文案，避免把后台里其它 403（如权限不足）也当成登录/注册被拒
  var WORDS = ['无权限登录原生后台', '系统不开放自助注册', '不开放自助注册', '系统已关闭注册'];
  function matchWords(text) {
    if (!text) return '';
    for (var i = 0; i < WORDS.length; i++) {
      if (text.indexOf(WORDS[i]) >= 0) return text;
    }
    return '';
  }
  // 原生前端自己弹的顶部提示条：找到承载该文案的最小元素并隐藏，只保留我们的居中弹窗
  function hideNativeToast(el) {
    if (!el || el.nodeType !== 1) return;
    if (el.closest && el.closest('#obara-rd-mask')) return;
    var msg = (el.textContent || '').trim();
    if (!msg) return;
    var target = el;
    // 只往上吞并「文本内容完全相同」的祖先（图标 + 文案的胶囊），不会误伤整个页面
    while (target.parentElement && target.parentElement !== document.body) {
      var p = target.parentElement;
      if ((p.textContent || '').trim() !== msg) break;
      target = p;
    }
    target.style.setProperty('display', 'none', 'important');
    // 如果外面还有一层纯定位容器（fixed/absolute + 高 z-index 且只装这条提示），一并隐藏
    var host = target.parentElement;
    if (host && host !== document.body) {
      var cs = window.getComputedStyle(host);
      if ((cs.position === 'fixed' || cs.position === 'absolute') &&
          (parseInt(cs.zIndex, 10) || 0) >= 1000 &&
          (host.textContent || '').trim() === msg) {
        host.style.setProperty('display', 'none', 'important');
      }
    }
  }
  function scanNode(node) {
    if (!node) return;
    var text = node.nodeType === 3 ? node.nodeValue : (node.textContent || '');
    var hit = matchWords(text);
    if (hit) {
      hideNativeToast(node.nodeType === 3 ? node.parentElement : node);
      obaraStart(hit.slice(0, 200));
      return;
    }
    var kids = node.childNodes || [];
    for (var k = 0; k < kids.length; k++) scanNode(kids[k]);
  }
  if (window.MutationObserver) {
    var mo = new MutationObserver(function (muts) {
      for (var i = 0; i < muts.length; i++) {
        var added = muts[i].addedNodes || [];
        for (var j = 0; j < added.length; j++) scanNode(added[j]);
      }
    });
    var startObserver = function () {
      mo.observe(document.body || document.documentElement, { childList: true, subtree: true });
    };
    if (document.body) startObserver();
    else window.addEventListener('DOMContentLoaded', startObserver);
  }

  function checkRoute() { if (PAGE_RE.test(location.pathname)) obaraStart(MSG_REG); }
  window.addEventListener("popstate", checkRoute);
  var _push = history.pushState, _replace = history.replaceState;
  if (_push) { history.pushState = function () { var r = _push.apply(this, arguments); setTimeout(checkRoute, 0); return r; }; }
  if (_replace) { history.replaceState = function () { var r = _replace.apply(this, arguments); setTimeout(checkRoute, 0); return r; }; }
  checkRoute();
})();
</script>
"""


def card_html(portal, message=""):
    """居中弹窗卡片（提示页与注入脚本共用）。"""
    return REDIRECT_CARD.replace("{{PORTAL}}", escape(portal, quote=True)) \
                        .replace("{{MESSAGE}}", escape(message))


def timer_js(portal):
    return REDIRECT_TIMER_JS.replace("{{PORTAL_JSON}}", json.dumps(portal)) \
                            .replace("{{DELAY_MS}}", str(REDIRECT_DELAY_MS))


def inject_guard(page, portal):
    """把守卫脚本注入上游返回的 HTML 页面（原生前端是 SPA，只能这样接管它的交互）。"""
    snippet = GUARD_SNIPPET.replace("{{CSS}}", REDIRECT_CSS) \
                           .replace("{{CARD}}", card_html(portal)) \
                           .replace("{{TIMER}}", timer_js(portal)) \
                           .replace("{{REGISTER_MESSAGE_JSON}}", json.dumps(REGISTER_BLOCK_MESSAGE))
    idx = page.lower().rfind("</body>")
    if idx >= 0:
        return page[:idx] + snippet + page[idx:]
    return page + snippet


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

    def portal_url(self):
        """被拦截后要跳转的门户登录页地址。"""
        if PORTAL_URL:
            return PORTAL_URL
        host = (self.headers.get("Host") or "").strip().split(":")[0]
        if not host:
            host = "127.0.0.1"
        return "http://%s:%d/" % (host, PORTAL_PORT_DEFAULT)

    def deny_page(self, reason, status=403):
        """页面类拦截：弹出提示后跳转到 8081 门户登录页。"""
        sys.stderr.write("[DENY-PAGE] %s %s (%s)\n" % (self.command, self.path_only(), reason))
        page = DENY_PAGE_HTML.replace("{{CSS}}", REDIRECT_CSS) \
                             .replace("{{CARD}}", card_html(self.portal_url(), reason)) \
                             .replace("{{TIMER}}", timer_js(self.portal_url()))
        body = page.encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "text/html; charset=utf-8")
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
        """注册 / 找回密码 / 重置密码类接口：任何方法、任何人都禁止。"""
        path = self.path_only()
        for prefix in BLOCK_PREFIXES:
            if path == prefix or path.startswith(prefix + "/"):
                return False, REGISTER_BLOCK_MESSAGE
        return True, ""

    def check_blocked_page(self):
        """注册 / 找回密码类页面：不代理上游，直接返回提示页。"""
        path = self.path_only().rstrip("/") or "/"
        for prefix in BLOCK_PAGE_PREFIXES:
            if path == prefix or path.startswith(prefix + "/"):
                return False, REGISTER_BLOCK_MESSAGE
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
            allowed, reason = self.check_blocked_page()
            if not allowed:
                self.deny_page(reason)
                return
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
                # 页面响应：注入守卫脚本，登录被拒 / 进注册页时弹提示并跳门户
                ctype = (resp.headers.get("Content-Type") or "").lower()
                if ENFORCE and self.command in ("GET", "HEAD") and "text/html" in ctype:
                    raw = resp.read()
                    page = inject_guard(raw.decode("utf-8", "replace"), self.portal_url())
                    out = page.encode("utf-8")
                    self.send_response(resp.status)
                    for k, v in resp.getheaders():
                        # 页面必须每次回源：否则浏览器用缓存的旧页面，守卫脚本不生效
                        if k.lower() in ("transfer-encoding", "connection",
                                         "content-encoding", "content-length",
                                         "etag", "last-modified", "expires",
                                         "cache-control", "pragma"):
                            continue
                        self.send_header(k, v)
                    self.send_header("Cache-Control", "no-store, no-cache, must-revalidate")
                    self.send_header("Pragma", "no-cache")
                    self.send_header("Content-Length", str(len(out)))
                    self.end_headers()
                    if self.command != "HEAD":
                        self.wfile.write(out)
                    return

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
    print("  自助注册: 已关闭（注册接口与 /register 页面一律 403）")
    print("  拦截后跳转: %s（提示停留 %.1f 秒，GATE_REDIRECT_DELAY_MS 可调）"
          % (PORTAL_URL or "http://<请求 Host>:%d/" % PORTAL_PORT_DEFAULT, REDIRECT_DELAY_MS / 1000.0))
    print("  按 Ctrl+C 停止")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\n[OBARA Admin Gate] 已停止")
        server.server_close()


if __name__ == "__main__":
    main()
