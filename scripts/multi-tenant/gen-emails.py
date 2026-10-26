#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
按姓名为部门人员生成企业邮箱与登录用户名，并写回 data/departments-personnel.json。

邮箱规则：
    邮箱 = 姓（全拼）+ 名（每个汉字的首字母） + @域名
    例：高剑    -> gaoj@obara.com.cn
        陈爱珍  -> chenaz@obara.com.cn

重名规则：
    - 同名且为同一人（身兼多个部门）：多个部门共用同一个账号、同一个邮箱。
    - 同名但是不同的人（见 DISTINCT_PEOPLE）：每人一个账号，第二条起邮箱加数字后缀，
      用户名加部门后缀，如 张杰(技术开发一部)。

特殊规则（部门 + 姓名 -> 自定义前缀）见 SPECIAL，例：
    O/NJG 管理部 的 张杰 -> zhangj_adm@obara.com.cn

依赖：pypinyin（pip install pypinyin）。JSON 中已写死的 email / username 不会被覆盖。

用法：
    python3 scripts/multi-tenant/gen-emails.py                 # 生成并写回
    python3 scripts/multi-tenant/gen-emails.py --dry-run       # 只打印不写文件
    python3 scripts/multi-tenant/gen-emails.py --force         # 覆盖已有的 email/username
    python3 scripts/multi-tenant/gen-emails.py --domain x.com  # 指定域名
"""
import argparse
import json
import os
import sys
from collections import Counter

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
DATA_FILE = os.path.join(REPO_ROOT, "data", "departments-personnel.json")

# (部门编码, 姓名) -> 邮箱前缀（不含域名）
SPECIAL = {
    ("NJG-ADM", "张杰"): "zhangj_adm",   # O/NJG 管理部的张杰使用管理员专用邮箱
}

# 同名但是不同的人（各自独立账号）；其余重名视为同一人身兼多部门，共用账号
DISTINCT_PEOPLE = {"张杰"}

# 已知「同一人身兼这几个部门」：组内共用一个账号（优先于 DISTINCT_PEOPLE）
SHARED_GROUPS = [
    [("NJG-DEV1", "张杰"), ("NJG-DEV2", "张杰")],   # 技术开发一部 / 二部是同一位张杰
]

# 用户名覆盖（WeKnora 用户名全局唯一，重名者需要区分）
USERNAME_OVERRIDE = {
    ("NJG-DEV1", "张杰"): "张杰(技术开发部)",
    ("NJG-DEV2", "张杰"): "张杰(技术开发部)",
}

# pypinyin 对姓氏读音的误判（姓氏读音与常用读音不同）
SURNAME_PINYIN = {
    "翟": "zhai",   # 姓氏读 zhái，非 dí
    "藏": "zang",   # 姓氏读 zàng，非 cáng
}

# 名字用字的首字母（多音字按姓名中的常见读音）
CHAR_INITIAL = {
    "晟": "s",      # 晟：姓名中通常读 shèng
}


def load_pinyin():
    try:
        from pypinyin import lazy_pinyin
    except ImportError:
        sys.exit(
            "缺少依赖 pypinyin，请先安装：pip install pypinyin\n"
            "（或直接在 data/departments-personnel.json 中为成员手写 email 字段）"
        )
    return lazy_pinyin


def build_prefix(name, lazy_pinyin):
    """姓取全拼，名取每个字的首字母"""
    if not name:
        return ""
    py = lazy_pinyin(name)
    surname = SURNAME_PINYIN.get(name[0], py[0] if py else "")
    initials = []
    for ch in name[1:]:
        if ch in CHAR_INITIAL:
            initials.append(CHAR_INITIAL[ch])
        else:
            p = lazy_pinyin(ch)
            if p:
                initials.append(p[0][0])
    return surname + "".join(initials)


def short_dept(dept_name, dept_code):
    """去掉地点前缀的部门简称，如 NJG-技术开发一部 -> 技术开发一部"""
    prefix = dept_code.split("-")[0] + "-"
    if dept_name.startswith(prefix):
        return dept_name[len(prefix):]
    return dept_name


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--domain", default=None, help="邮箱域名，缺省取 JSON 中的 email_domain")
    ap.add_argument("--dry-run", action="store_true", help="只打印结果，不写回文件")
    ap.add_argument("--force", action="store_true", help="重新生成，覆盖已有的 email/username")
    args = ap.parse_args()

    with open(DATA_FILE, encoding="utf-8") as f:
        data = json.load(f)

    lazy_pinyin = load_pinyin()
    domain = args.domain or data.get("email_domain") or "obara.com.cn"
    data["email_domain"] = domain
    default_role = data.get("default_role") or "contributor"

    roster = [(dep, m) for loc in data.get("locations", [])
              for dep in loc.get("departments", []) for m in dep.get("members", [])]
    name_count = Counter(m.get("name", "") for _, m in roster)

    used = {}          # 邮箱前缀 -> 已占用次数
    email_of_name = {}  # 同一人的姓名 -> 邮箱（身兼多部门时复用）
    username_seen = {}  # 用户名 -> 次数
    rows = []

    # 同人分组：(部门编码, 姓名) -> 组号
    group_of = {}
    for i, group in enumerate(SHARED_GROUPS):
        for key in group:
            group_of[key] = i
    group_email = {}

    def alloc(prefix):
        n = used.get(prefix, 0) + 1
        used[prefix] = n
        return prefix if n == 1 else "%s%d" % (prefix, n)

    for dep, m in roster:
        code, dname = dep.get("code", ""), dep.get("name", "")
        name = m.get("name", "")
        key = (code, name)
        if not args.force and m.get("email"):
            email = m["email"]
        elif key in group_of:
            # 已知同一人身兼多部门：组内共用一个账号
            g = group_of[key]
            if g not in group_email:
                base = SPECIAL.get(key) or build_prefix(name, lazy_pinyin)
                group_email[g] = "%s@%s" % (alloc(base), domain)
            email = group_email[g]
        elif name in email_of_name and name_count[name] > 1 and name not in DISTINCT_PEOPLE:
            # 同一人身兼多个部门：复用同一账号
            email = email_of_name[name]
        else:
            base = SPECIAL.get((code, name)) or build_prefix(name, lazy_pinyin)
            email = "%s@%s" % (alloc(base), domain)
            if name_count[name] > 1 and name not in DISTINCT_PEOPLE:
                email_of_name[name] = email

        # 用户名全局唯一：同名的不同人，第二条起追加部门后缀
        username = m.get("username") or name
        if args.force or not m.get("username"):
            if key in USERNAME_OVERRIDE:
                username = USERNAME_OVERRIDE[key]
            elif name_count[name] > 1 and name in DISTINCT_PEOPLE and username_seen.get(name):
                cand = "%s(%s)" % (name, short_dept(dname, code))
                if cand in username_seen:
                    cand = "%s(%s)" % (name, dname)
                username = cand
        username_seen[username] = username_seen.get(username, 0) + 1
        username_seen.setdefault(name, 1)

        m["email"] = email
        if username != name:
            m["username"] = username
        elif args.force:
            m.pop("username", None)
        rows.append((code, dname, name, default_role, email, username))

    emails = [r[4] for r in rows]
    dup = {e for e in emails if emails.count(e) > 1 and
           len({r[5] for r in rows if r[4] == e}) > 1}
    if dup:
        sys.exit("同一邮箱对应了多个不同账号，请调整规则：%s" % ", ".join(sorted(dup)))

    # 不设默认管理员：全员按 default_role 加入，部门 Owner 由超管初始化后手动指派
    for code, dname, name, role, email, username in rows:
        print("%s\t%s\t%s\t%s\t%s\t%s" % (code, dname, name, role, email, username))

    print("\n人数 %d，账号（邮箱）%d 个，用户名 %d 个" %
          (len(rows), len(set(emails)), len({r[5] for r in rows})), file=sys.stderr)
    if not args.dry_run:
        with open(DATA_FILE, "w", encoding="utf-8") as f:
            json.dump(data, f, ensure_ascii=False, indent=2)
            f.write("\n")
        print("已写回：%s" % DATA_FILE, file=sys.stderr)
    else:
        print("[dry-run] 未写回文件", file=sys.stderr)


if __name__ == "__main__":
    main()
