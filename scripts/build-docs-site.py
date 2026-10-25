#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
build-docs-site.py — 将仓库内的 Markdown 文档构建成一个精美的单页文档站。

特性：
  * 自动收集 README.md / docs/**/*.md / scripts/**/*.md 等文档
  * Markdown → HTML（表格、任务列表、脚注、代码高亮），自动生成页内目录
  * 仓库内的 .md 互链自动改写为站内路由，图片等资源复制到输出目录
  * 输出自包含静态页面（site/index.html + assets/），可直接双击打开或部署
  * 从 git 历史读取每篇文档的最后更新时间

用法：
  python3 scripts/build-docs-site.py                     # 默认输出到 ./site
  python3 scripts/build-docs-site.py --output public
  python3 scripts/build-docs-site.py --exclude scripts

依赖：markdown（必需），Pygments（可选，用于代码高亮）
  pip install markdown Pygments
"""

from __future__ import annotations

import argparse
import datetime as _dt
import html as _html
import json
import os
import posixpath
import re
import shutil
import subprocess
import sys
import urllib.parse
from pathlib import Path

try:
    import markdown
except ImportError:
    sys.stderr.write(
        "缺少依赖：请先执行  pip install markdown Pygments\n"
        "（GitHub Actions 中已自动安装）\n"
    )
    raise SystemExit(1)

try:
    from pygments.formatters import HtmlFormatter

    HAS_PYGMENTS = True
except ImportError:
    HAS_PYGMENTS = False


# --------------------------------------------------------------------------- #
# 基础工具
# --------------------------------------------------------------------------- #
INLINE_MD_RE = re.compile(
    r"!\[[^\]]*\]\([^)]*\)|"          # 图片
    r"\[([^\]]*)\]\([^)]*\)|"         # 链接
    r"`([^`]*)`|"                     # 行内代码
    r"(\*\*|__|\*|_|~~)"              # 强调
)
CN_RE = re.compile(r"[一-鿿]")


def slugify(value: str, separator: str = "-") -> str:
    """保留中文的 slugify（Python-Markdown 默认会丢弃中文字符）。"""
    value = _html.unescape(value or "").strip()
    value = re.sub(r"[<>/\\|?*\"']", "", value)
    value = re.sub(r"[^\w\s\u4e00-\u9fff-]", "", value, flags=re.UNICODE)
    value = re.sub(r"[\s]+", separator, value)
    value = re.sub(r"-{2,}", separator, value).strip(separator)
    return value or "section"


def strip_md(text: str) -> str:
    """去掉行内 Markdown 标记，用于生成标题与摘要。"""
    def _sub(m: re.Match) -> str:
        if m.group(1):
            return m.group(1)
        if m.group(2):
            return m.group(2)
        return ""
    text = INLINE_MD_RE.sub(_sub, text or "")
    text = re.sub(r"^[#>\-\*\s]+", "", text)
    return text.strip()


def run_git(root: Path, args: list) -> str:
    try:
        out = subprocess.run(
            ["git", "-C", str(root)] + args,
            capture_output=True, text=True, timeout=30,
        )
        if out.returncode == 0:
            return out.stdout.strip()
    except Exception:
        pass
    return ""


def git_updated(root: Path, rel: str) -> str:
    iso = run_git(root, ["log", "-1", "--format=%cI", "--", rel])
    if iso:
        return iso[:10]
    try:
        ts = (root / rel).stat().st_mtime
        return _dt.datetime.fromtimestamp(ts).strftime("%Y-%m-%d")
    except OSError:
        return ""


def detect_repo(root: Path) -> tuple:
    """返回 (owner/repo, branch, 站点 URL)。"""
    repo = os.environ.get("GITHUB_REPOSITORY", "")
    branch = os.environ.get("GITHUB_REF_NAME", "") or run_git(root, ["rev-parse", "--abbrev-ref", "HEAD"])
    if not repo:
        url = run_git(root, ["remote", "get-url", "origin"])
        m = re.search(r"[:/]([\w.\-]+/[\w.\-]+?)(?:\.git)?$", url or "")
        if m:
            repo = m.group(1)
    site = "https://github.com/" + repo if repo else ""
    return repo, branch or "main", site


# --------------------------------------------------------------------------- #
# 文档收集
# --------------------------------------------------------------------------- #
DEFAULT_INCLUDE = ["README.md", "docs/**/*.md", "scripts/**/*.md"]


def collect_docs(root: Path, patterns: list, excludes: list) -> list:
    found = {}
    for pat in patterns:
        for p in root.glob(pat):
            if not p.is_file() or p.suffix.lower() != ".md":
                continue
            rel = p.relative_to(root).as_posix()
            if rel in found:
                continue
            found[rel] = p
    out = []
    for rel in sorted(found):
        if any(rel == e or rel.startswith(e.rstrip("/") + "/") or Path(rel).match(e) for e in excludes):
            continue
        out.append(rel)
    return out


def group_of(rel: str) -> str:
    parts = rel.split("/")
    if len(parts) == 1:
        return "开始"
    if parts[0] == "docs":
        if len(parts) == 2:
            return "文档"
        return " / ".join(parts[1:-1])
    if parts[0] == "scripts":
        return "脚本说明"
    return parts[0]


def group_rank(rel: str) -> int:
    parts = rel.split("/")
    if len(parts) == 1:
        return 0
    if parts[0] == "docs":
        return 1
    if parts[0] == "scripts":
        return 2
    return 3


def parse_title_desc(text: str, rel: str) -> tuple:
    title, desc = "", ""
    for raw in text.splitlines():
        line = raw.strip()
        if not line:
            continue
        if line.startswith("#"):
            candidate = strip_md(line.lstrip("#").strip())
            if candidate and not title:
                title = candidate
            continue
        if not desc:
            if line.startswith(">") or line.startswith("|"):
                continue
            if line.startswith("---") or line.startswith("```"):
                continue
            candidate = strip_md(line)
            if candidate:
                desc = candidate
        if title and desc:
            break
    if not title:
        title = Path(rel).stem.replace("-", " ").replace("_", " ").strip() or rel
    if len(desc) > 140:
        desc = desc[:140].rstrip() + "…"
    return title, desc


# --------------------------------------------------------------------------- #
# Markdown 渲染
# --------------------------------------------------------------------------- #
def build_renderer() -> markdown.Markdown:
    exts = ["extra", "toc", "sane_lists"]
    configs = {
        "toc": {
            "slugify": slugify,
            "permalink": True,
            "permalink_class": "anchor",
            "permalink_title": "本段链接",
            "toc_depth": "2-3",
        }
    }
    if HAS_PYGMENTS:
        exts.append("codehilite")
        configs["codehilite"] = {
            "guess_lang": False,
            "linenums": False,
            "use_pygments": True,
            "css_class": "highlight",
            "noclasses": False,
        }
    return markdown.Markdown(extensions=exts, extension_configs=configs)


def prefix_anchors(html_text: str, slugs: list, prefix: str) -> str:
    """为标题 id 与锚点链接加文档前缀，避免多篇文档 id 冲突。"""
    if not slugs:
        return html_text
    alt = "|".join(re.escape(s) for s in sorted(set(slugs), key=len, reverse=True))
    pat = re.compile(r'(id="|href="#)(' + alt + r')(")')
    return pat.sub(lambda m: m.group(1) + prefix + "-" + m.group(2) + m.group(3), html_text)


def pygments_css() -> str:
    if not HAS_PYGMENTS:
        return "/* Pygments 未安装，代码块不做语法高亮 */\n.doc-body .highlight{background:transparent!important}"
    try:
        light = HtmlFormatter(style="default").get_style_defs(".highlight")
    except Exception:
        light = ""
    dark = ""
    for name in ("github-dark", "monokai", "native"):
        try:
            dark = HtmlFormatter(style=name).get_style_defs('[data-theme="dark"] .highlight')
            break
        except Exception:
            continue
    return (
        light
        + "\n"
        + dark
        + "\n.doc-body .highlight{background:transparent!important}\n"
        + ".doc-body .highlight pre{margin:0;padding:0;background:transparent;border:0}"
    )


# --------------------------------------------------------------------------- #
# 链接 / 资源重写
# --------------------------------------------------------------------------- #
class Rewriter:
    def __init__(self, root: Path, out_dir: Path, doc_map: dict, repo: str, branch: str):
        self.root = root
        self.out_dir = out_dir
        self.doc_map = doc_map
        self.repo = repo
        self.branch = branch

    def blob_url(self, rel: str) -> str:
        if not self.repo:
            return ""
        return "https://github.com/%s/blob/%s/%s" % (self.repo, self.branch, urllib.parse.quote(rel))

    def raw_url(self, rel: str) -> str:
        if not self.repo:
            return ""
        return "https://raw.githubusercontent.com/%s/%s/%s" % (
            self.repo, self.branch, urllib.parse.quote(rel),
        )

    def resolve(self, url: str, doc_rel: str) -> tuple:
        """返回 (新地址, 是否站内文档路由)。"""
        if not url or url.startswith(("#", "mailto:", "tel:", "data:", "http://", "https://")):
            return url, False
        path, _, anchor = url.partition("#")
        path = urllib.parse.unquote(path)
        if path.startswith("/"):
            target = path.lstrip("/")
        else:
            target = posixpath.normpath(posixpath.join(posixpath.dirname(doc_rel), path))
        if target in self.doc_map:
            new = "#/" + urllib.parse.quote(target)
            if anchor:
                new += "#" + anchor
            return new, True
        src = self.root / target
        if src.is_file():
            dst = self.out_dir / "assets" / target
            dst.parent.mkdir(parents=True, exist_ok=True)
            if not dst.exists():
                shutil.copy2(src, dst)
            new = "assets/" + urllib.parse.quote(target)
            if anchor:
                new += "#" + anchor
            return new, False
        if target.lower().endswith(".md"):
            return self.blob_url(target) or url, False
        return self.raw_url(target) or url, False

    def rewrite(self, html_text: str, doc_rel: str) -> str:
        def _href(m: re.Match) -> str:
            new, _ = self.resolve(_html.unescape(m.group(2)), doc_rel)
            return m.group(1) + _html.escape(new, quote=True) + m.group(3)

        def _src(m: re.Match) -> str:
            new, _ = self.resolve(_html.unescape(m.group(2)), doc_rel)
            return m.group(1) + _html.escape(new, quote=True) + m.group(3)

        html_text = re.sub(r'(<a\s[^>]*?href=")([^"]*)(")', _href, html_text, flags=re.I)
        html_text = re.sub(r'(<img\s[^>]*?src=")([^"]*)(")', _src, html_text, flags=re.I)
        # 外链新窗口打开
        html_text = re.sub(
            r'<a href="(https?://[^"]+)"',
            r'<a target="_blank" rel="noopener noreferrer" href="\1"',
            html_text,
        )
        return html_text


# --------------------------------------------------------------------------- #
# 构建主流程
# --------------------------------------------------------------------------- #
def build(args) -> int:
    root = Path(args.root).resolve()
    out_dir = Path(args.output).resolve() if args.output else (root / "site")
    template_path = Path(args.template).resolve() if args.template else (root / "scripts" / "docs-site-template.html")
    if not template_path.is_file():
        sys.stderr.write("找不到模板文件：%s\n" % template_path)
        return 1

    patterns = args.include or DEFAULT_INCLUDE
    excludes = [e for e in (args.exclude or []) if e]
    rels = collect_docs(root, patterns, excludes)
    if not rels:
        sys.stderr.write("没有找到任何 Markdown 文档（检查 --include / --exclude 参数）\n")
        return 1

    rels.sort(key=lambda r: (group_rank(r), r))
    docs = []
    used_ids = set()
    for rel in rels:
        base = slugify(Path(rel).with_suffix("").as_posix().replace("/", "-"))
        doc_id = base
        i = 2
        while doc_id in used_ids:
            doc_id = "%s-%d" % (base, i)
            i += 1
        used_ids.add(doc_id)
        text = (root / rel).read_text(encoding="utf-8", errors="replace")
        title, desc = parse_title_desc(text, rel)
        docs.append({
            "id": doc_id,
            "path": rel,
            "title": title,
            "desc": desc,
            "group": group_of(rel),
            "updated": git_updated(root, rel),
            "text": text,
        })

    repo, branch, site_url = detect_repo(root)
    doc_map = {d["path"]: d["id"] for d in docs}
    rewriter = Rewriter(root, out_dir, doc_map, repo, branch)
    renderer = build_renderer()

    if out_dir.exists():
        shutil.rmtree(out_dir)
    (out_dir / "assets").mkdir(parents=True, exist_ok=True)

    articles = []
    for d in docs:
        renderer.reset()
        body = renderer.convert(d["text"])
        toc = getattr(renderer, "toc", "") or ""
        # 收集本文档全部标题锚点（含 h1/h4，toc 只列出 2-3 级），统一加文档前缀避免跨文档冲突
        slugs = re.findall(r'<h[1-6][^>]*\sid="([^"]+)"', body) + re.findall(r'href="#([^"]+)"', toc)
        slugs = [s for s in slugs if "/" not in s]
        body = prefix_anchors(body, slugs, d["id"])
        toc = prefix_anchors(toc, slugs, d["id"])
        body = rewriter.rewrite(body, d["path"])
        blob = rewriter.blob_url(d["path"])
        articles.append(
            '<article class="doc" id="doc-%s" data-doc="%s" hidden>\n'
            '  <div class="doc-head">\n'
            '    <div class="crumb"><span class="badge">%s</span><code>%s</code>%s%s</div>\n'
            '    <h1 class="doc-title">%s</h1>\n'
            '    %s\n'
            '  </div>\n'
            '  <nav class="doc-toc"><strong>本页目录</strong>%s</nav>\n'
            '  <div class="doc-body">%s</div>\n'
            '</article>' % (
                d["id"], d["id"],
                _html.escape(d["group"]), _html.escape(d["path"]),
                '<span>更新于 %s</span>' % d["updated"] if d["updated"] else "",
                '<a href="%s" target="_blank" rel="noopener">在 GitHub 查看 ↗</a>' % _html.escape(blob) if blob else "",
                _html.escape(d["title"]),
                '<p class="doc-desc">%s</p>' % _html.escape(d["desc"]) if d["desc"] else "",
                toc,
                body.replace("</script", "<\\/script"),
            )
        )
        d.pop("text", None)

    template = template_path.read_text(encoding="utf-8")
    meta = [d for d in docs if d["updated"]]
    latest = max((d["updated"] for d in meta), default="")
    subtitle = "%d 篇文档%s" % (len(docs), (" · 最近更新 " + latest) if latest else "")
    footer_repo = ' · <a href="%s" target="_blank" rel="noopener">源码仓库 ↗</a>' % _html.escape(site_url) if site_url else ""

    data_json = json.dumps(docs, ensure_ascii=False).replace("</", "<\\/")
    html = template
    for key, val in {
        "{{SITE_TITLE}}": args.title,
        "{{SITE_DESC}}": (args.desc or (args.title + " — 自动生成的文档站")),
        "{{SITE_SUBTITLE}}": subtitle,
        "{{BUILD_TIME}}": _dt.datetime.now().strftime("%Y-%m-%d %H:%M"),
        "{{FOOTER_REPO}}": footer_repo,
        "{{DOCS_JSON}}": data_json,
        "{{ARTICLES}}": "\n".join(articles),
        "{{PYGMENTS_CSS}}": pygments_css(),
    }.items():
        html = html.replace(key, val)

    (out_dir / "index.html").write_text(html, encoding="utf-8")
    (out_dir / ".nojekyll").write_text("", encoding="utf-8")

    size = (out_dir / "index.html").stat().st_size
    print("已生成文档站：%s（%.1f KB，%d 篇文档）" % (out_dir, size / 1024, len(docs)))
    for d in docs:
        print("  · [%s] %s" % (d["group"], d["path"]))
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description="构建单页 Markdown 文档站")
    ap.add_argument("--root", default=str(Path(__file__).resolve().parent.parent), help="仓库根目录")
    ap.add_argument("--output", default="", help="输出目录（默认 <root>/site）")
    ap.add_argument("--template", default="", help="HTML 模板路径")
    ap.add_argument("--title", default="OBARA 部署文档中心", help="站点标题")
    ap.add_argument("--desc", default="", help="站点描述")
    ap.add_argument("--include", nargs="*", default=None, help="文档 glob（相对仓库根）")
    ap.add_argument("--exclude", nargs="*", default=None, help="排除的文档 glob")
    return build(ap.parse_args())


if __name__ == "__main__":
    raise SystemExit(main())
