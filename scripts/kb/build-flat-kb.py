#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""把宽表切片重建成「一行一段」的自然语言知识文件。

背景
----
Excel 直接导入后，Markdown 表格的每个分片里表头约占 200~300 token，
而 bge-m3 的 num_ctx 只有 511 —— 实测图号落在第 562 字符处，**完全没进入
向量**，导致"用图号本身检索也召不回"。

本脚本把每行数据改写为「字段: 值」的自然语言短句（约 120~180 字），
去掉重复表头、保留全部有值的字段、并把选型关键参数前置：

    【X2C-V3-C  C枪】图号：SDZC-3C30400L；客户：联恒沈阳G58项目；
    类型：小型；行程：182；加压力：6000；变压器：ITS85；喉深：380；喉宽：470 ……

数据来源是 WeKnora 已解析出的 chunks（Postgres），无需二次读取 Excel。

用法
----
    python3 scripts/kb/build-flat-kb.py                    # 生成全部 6 个文件
    python3 scripts/kb/build-flat-kb.py --only X2C-V3-C    # 只生成样本
    python3 scripts/kb/build-flat-kb.py --preview 3        # 只看前 3 行样例
"""

import argparse
import csv
import json
import os
import re
import subprocess
import sys

PG_CONTAINER = os.environ.get("PG_CONTAINER", "WeKnora-postgres")
PG_USER = os.environ.get("PG_USER", "postgres")
PG_DB = os.environ.get("PG_DB", "WeKnora")
KB_ID_FILE = "/tmp/kbid.txt"

OUT_DIR = os.path.join(
    os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))),
    "welding-gun-selection-kb", "03-flat-knowledge",
)

# 关键参数排在前面（与答复约束提示词 §3.1 一致），其余字段按原表顺序追加
PRIORITY_FIELDS = [
    "图号", "客户", "产品子分类类型", "行程", "加压力", "变压器", "喉深", "喉宽",
    "偏心距离", "齿轮箱行程", "电极臂端部", "MOTOR厂家", "法兰P.C.D",
    "托架方向", "齿轮箱型式", "托架材料", "换枪装置", "水路", "有无平衡",
    "变压器放置方向",
]

ROW_RE = re.compile(r"^\s*\|")


def gun_type(file_name):
    """从文件名判定 C 枪 / X 枪，供知识路由使用。"""
    base = file_name.replace("-knowledge.xlsx", "")
    parts = base.split("-")
    tail = parts[-1] if parts else ""
    if tail.upper() == "C":
        return "C枪"
    if tail.upper() == "X":
        return "X枪"
    return "未知枪型"


def parse_rows(content):
    """把 Markdown 表格文本解析成 [{列名: 值}]。

    content 形如：表头行 + |---| 分隔行 + 若干数据行（也可能只有表头）。
    注意：docreader 写出的分片里换行被吃掉了，表头/分隔行/数据行之间以
    `||` 首尾相连，这里先把行边界还原再解析。
    """
    text = content.replace("||", "|\n|")
    lines = [l.strip() for l in text.splitlines() if ROW_RE.match(l)]
    if len(lines) < 3:
        return []
    header = [c.strip() for c in lines[0].strip("|").split("|")]
    rows = []
    for line in lines[2:]:
        cells = [c.strip() for c in line.strip("|").split("|")]
        if len(cells) != len(header):
            continue
        # 空值不输出；Markdown/Excel 的常见空值一并归一
        item = {}
        for k, v in zip(header, cells):
            if v and v not in ("-", "—", "nan", "NaN", "NaN%", "None", "/"):
                item[k] = v
        rows.append(item)
    return rows


def flat_line(file_name, row):
    """一行数据 -> 自然语言短句。"""
    gtype = gun_type(file_name)
    src = re.sub(r"-knowledge\.xlsx$", "", file_name)
    keys = [k for k in PRIORITY_FIELDS if k in row]
    keys += [k for k in row if k not in keys]
    body = "；".join(f"{k}：{row[k]}" for k in keys)
    return f"【{src} {gtype}】{body}"


def fetch_chunks(kb_id):
    """从 Postgres 读取该知识库的全部已解析分片。

    分片内含换行，用 CSV 格式导出以免按行读时被截断。
    """
    copy_sql = (
        "\\copy ("
        "select k.file_name, c.content "
        "from chunks c join knowledges k on k.id = c.knowledge_id "
        f"where c.knowledge_base_id = '{kb_id}'"
        ") to stdout csv header"
    )
    cmd = ["docker", "exec", PG_CONTAINER, "psql", "-U", PG_USER, "-d", PG_DB,
           "-c", copy_sql]
    out = subprocess.run(cmd, capture_output=True, text=True)
    if out.returncode != 0:
        sys.exit(f"❌ 读取分片失败：{out.stderr.strip()[:300]}")
    buckets = {}
    for row in csv.reader(out.stdout.splitlines()):
        if len(row) != 2 or row[0] == "file_name":
            continue
        buckets.setdefault(row[0], []).append(row[1])
    return buckets


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--kb-id", default="")
    ap.add_argument("--only", default="", help="只处理文件名包含该关键字的文档")
    ap.add_argument("--out-dir", default=OUT_DIR)
    ap.add_argument("--preview", type=int, default=0, help="只打印前 N 行样例")
    args = ap.parse_args()

    kb_id = args.kb_id
    if not kb_id and os.path.exists(KB_ID_FILE):
        kb_id = open(KB_ID_FILE).read().strip()
    if not kb_id:
        sys.exit("❌ 需要 --kb-id 或 /tmp/kbid.txt")

    buckets = fetch_chunks(kb_id)
    if not buckets:
        sys.exit("❌ 未取到任何分片，请确认 kb-id 与容器名")

    os.makedirs(args.out_dir, exist_ok=True)
    summary = []
    for file_name in sorted(buckets):
        if args.only and args.only not in file_name:
            continue
        rows, seen = [], set()
        for content in buckets[file_name]:
            for row in parse_rows(content):
                key = json.dumps(row, ensure_ascii=False, sort_keys=True)
                if key in seen:          # 同一个表头分片 + 数据分片会重复
                    continue
                seen.add(key)
                lines = flat_line(file_name, row)
                rows.append(lines)
        if not rows:
            print(f"    跳过 {file_name}（无数据行）")
            continue
        src = re.sub(r"-knowledge\.xlsx$", "", file_name)
        out_file = os.path.join(args.out_dir, f"{src}.md")
        max_len = max(len(r) for r in rows)
        with open(out_file, "w", encoding="utf-8") as fh:
            fh.write(f"# {src} 焊枪选型记录\n\n")
            fh.write("> 每行一条选型记录，字段以「字段名：值」给出，"
                     "空字段已省略。\n\n")
            fh.write("\n\n".join(rows))
            fh.write("\n")
        summary.append((file_name, len(rows), max_len, out_file))
        print(f"    {file_name}: {len(rows)} 行 → {os.path.basename(out_file)}"
              f"（最长 {max_len} 字）")

    if args.preview:
        name, _, _, out_file = summary[0]
        print(f"\n--- {os.path.basename(out_file)} 前 {args.preview} 行 ---")
        for line in open(out_file, encoding="utf-8").read().split("\n\n")[3:
                                                        3 + args.preview]:
            print(line)

    print(f"\n输出目录：{args.out_dir}")
    print(f"合计 {sum(s[1] for s in summary)} 行")


if __name__ == "__main__":
    main()
