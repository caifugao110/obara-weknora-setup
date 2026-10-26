#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
OBARA 知识问答平台 — 门户构建版本号打标

规则（写入 portal/index.html 左下角 #build-version）：
  · 当天首次构建      → 当前版本 YY-MM-DD
  · 当天第 2 次构建   → 当前版本 YY-MM-DD-V2
  · 当天第 N 次构建   → 当前版本 YY-MM-DD-VN
每当日期跨天则重新从 -V1（即不带后缀）开始计数。

日期与序号记录在 index.html 的属性上（data-date / data-build），
因此换机器、重新克隆仓库后仍能接着当天的序号递增。

用法：
  python3 scripts/portal/build-version.py                # 递增一次并写入
  python3 scripts/portal/build-version.py --check        # 只查看，不写入
  python3 scripts/portal/build-version.py --file <path>  # 指定 index.html
"""

import argparse
import os
import re
import sys
from datetime import datetime

DEFAULT_INDEX = os.path.join(
    os.path.dirname(os.path.abspath(__file__)), "..", "..", "portal", "index.html"
)

SPAN_RE = re.compile(r'(<span[^>]*id="build-version"[^>]*>)(.*?)(</span>)', re.S)


def read_version(path):
    """返回 (当前展示文案, 日期, 序号)；未标注时返回 (None, '', 0)。"""
    with open(path, "r", encoding="utf-8") as f:
        text = f.read()
    m = SPAN_RE.search(text)
    if not m:
        return None, "", 0
    tag = m.group(1)
    date_attr = re.search(r'data-date="([^"]*)"', tag)
    build_attr = re.search(r'data-build="(\d+)"', tag)
    return (
        m.group(2).strip(),
        date_attr.group(1) if date_attr else "",
        int(build_attr.group(1)) if build_attr else 0,
    )


def next_version(cur_date, cur_build, today):
    """按日期判定下一次构建的序号与文案。"""
    build = cur_build + 1 if cur_date == today else 1
    label = today if build == 1 else "{}-V{}".format(today, build)
    return build, "当前版本 " + label


def write_version(path, today, build, label):
    with open(path, "r", encoding="utf-8") as f:
        text = f.read()

    new_tag = '<span class="version" id="build-version" data-date="{}" data-build="{}">'.format(today, build)
    new_span = new_tag + label + "</span>"
    new_text, n = SPAN_RE.subn(lambda m: new_span, text, count=1)
    if n == 0:
        raise SystemExit("❌ 未在 {} 中找到 id=\"build-version\" 的版本节点".format(path))

    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        f.write(new_text)
    os.replace(tmp, path)


def main():
    ap = argparse.ArgumentParser(description="门户构建版本号打标")
    ap.add_argument("--file", default=os.path.normpath(DEFAULT_INDEX), help="index.html 路径")
    ap.add_argument("--check", action="store_true", help="只查看当前版本，不写入")
    args = ap.parse_args()

    path = os.path.normpath(args.file)
    if not os.path.isfile(path):
        print("❌ 未找到文件：{}".format(path), file=sys.stderr)
        return 1

    today = datetime.now().strftime("%y-%m-%d")
    cur_label, cur_date, cur_build = read_version(path)

    if cur_label is None:
        print("⚠️  {} 中没有版本节点，跳过打标".format(path), file=sys.stderr)
        return 1

    if args.check:
        print("当前版本：{}（data-date={} build={}）".format(cur_label or "未标注", cur_date or "-", cur_build))
        print("今天日期：{}".format(today))
        return 0

    build, label = next_version(cur_date, cur_build, today)
    write_version(path, today, build, label)
    print("✅ 门户构建版本号已更新：{}（第 {} 次构建，写入 {}）".format(label, build, path))
    return 0


if __name__ == "__main__":
    sys.exit(main())
