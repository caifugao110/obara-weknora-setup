#!/usr/bin/env bash
#
# 阶段六：焊枪选型知识库**端到端验收**
#
# 做什么：
#   从知识库已解析的记录里抽取若干真实行，自动生成「用户口吻」的选型提问，
#   调用绑定了答复约束提示词的智能体做问答，核对返回的图号是否为期望值。
#
# 为什么这样做：
#   - 期望答案来自真实记录，不需要人工维护答案清单
#   - 每个用例都走完整链路：检索 → 重排 → LLM → 提示词约束输出
#   - 一个用例可重复多次，用来观察 LLM 输出是否稳定（同一提问多次请求）
#
# 用法：
#   sudo ADMIN_PASSWORD='<后台密码>' bash scripts/kb/verify-welding-gun-kb.sh
#   sudo bash scripts/kb/verify-welding-gun-kb.sh --kb-id <kb> --agent-id <agent> --cases 5
#   sudo bash scripts/kb/verify-welding-gun-kb.sh --cases 3 --repeat 2 --file X2C-V3-C
#
# 参数：
#   --kb-id        知识库 ID（默认读 /tmp/kbid.txt）
#   --agent-id     智能体 ID（默认在库里按名称「焊枪选型助手」查找）
#   --agent-name   智能体名称（配合 KB_NAME 场景使用）
#   --file         只抽取文件名含该关键字的记录做用例（如 X2C-V3-C）
#   --cases        用例数量（默认 5）
#   --repeat       每个用例重复次数（默认 1，用于观察稳定性）
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

BASE_URL="${BASE_URL:-http://127.0.0.1:8080}"
ADMIN_EMAIL="${ADMIN_EMAIL:-admin@obara.local}"
ADMIN_PASSWORD="${ADMIN_PASSWORD:-}"

KB_ID="${KB_ID:-}"; [ -z "${KB_ID}" ] && [ -f /tmp/kbid.txt ] && KB_ID="$(cat /tmp/kbid.txt)"
AGENT_ID="${AGENT_ID:-}"
AGENT_NAME="${AGENT_NAME:-焊枪选型助手}"
FILE_FILTER="${FILE_FILTER:-}"
CASES="${CASES:-5}"
REPEAT="${REPEAT:-1}"
PG_CONTAINER="${PG_CONTAINER:-WeKnora-postgres}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --base-url)       BASE_URL="${2}"; shift 2 ;;
    --admin-password) ADMIN_PASSWORD="${2}"; shift 2 ;;
    --admin-email)    ADMIN_EMAIL="${2}"; shift 2 ;;
    --kb-id)          KB_ID="${2}"; shift 2 ;;
    --agent-id)       AGENT_ID="${2}"; shift 2 ;;
    --agent-name)     AGENT_NAME="${2}"; shift 2 ;;
    --file)           FILE_FILTER="${2}"; shift 2 ;;
    --cases)          CASES="${2}"; shift 2 ;;
    --repeat)         REPEAT="${2}"; shift 2 ;;
    -h|--help)        sed -n '2,28p' "$0"; exit 0 ;;
    *) echo "❌ 未知参数：$1（--help 查看用法）" >&2; exit 1 ;;
  esac
done

export BASE_URL ADMIN_EMAIL ADMIN_PASSWORD KB_ID AGENT_ID AGENT_NAME FILE_FILTER CASES REPEAT PG_CONTAINER
python3 -u - <<'PY'
# -*- coding: utf-8 -*-
import csv, json, os, random, re, subprocess, sys, time, urllib.request

E = os.environ.get
API = E("BASE_URL") + "/api/v1"
KB_ID, AGENT_ID = E("KB_ID"), E("AGENT_ID")
CASES, REPEAT = int(E("CASES")), int(E("REPEAT"))
FILE_FILTER, PG = E("FILE_FILTER"), E("PG_CONTAINER")


def http(path, payload=None, token=None, raw=False, timeout=300):
    data = json.dumps(payload).encode() if payload is not None else None
    req = urllib.request.Request(API + "/" + path.lstrip("/"), data=data, headers={
        "Content-Type": "application/json",
        **({"Authorization": "Bearer " + token} if token else {}),
    })
    r = urllib.request.urlopen(req, timeout=timeout)
    return r.read().decode() if raw else json.load(r)


print("==> [1/4] 登录")
token = http("auth/login", {"email": E("ADMIN_EMAIL"), "password": E("ADMIN_PASSWORD")})["token"]
auth = token          # http() 内部会拼 "Bearer "，这里保存裸 JWT

if not AGENT_ID:
    for a in http("agents", token=token)["data"]:
        if a["name"] == E("AGENT_NAME"):
            AGENT_ID = a["id"]; break
if not AGENT_ID:
    sys.exit(f"❌ 未找到智能体「{E('AGENT_NAME')}」，先用 init-welding-gun-kb.sh 创建")
print(f"    智能体 {AGENT_ID} / 知识库 {KB_ID}")

print("==> [2/4] 抽取真实记录构造用例")
file_clause = f" and k.file_name like '%%{FILE_FILTER}%%'" if FILE_FILTER else ""
sql = ("\\copy (select k.file_name, c.content from chunks c "
       f"join knowledges k on k.id=c.knowledge_id where c.knowledge_base_id='{KB_ID}'"
       f"{file_clause}) to stdout csv header")
out = subprocess.run(["docker", "exec", PG, "psql", "-U", "postgres", "-d", "WeKnora",
                      "-c", sql], capture_output=True, text=True)
if out.returncode != 0:
    sys.exit("❌ 读取分片失败：" + out.stderr[:200])


def rows_of(content):
    """分片 → [{列名: 值}]，兼容两种知识表示：

    1. Excel 直转的 Markdown 表格（docreader 会把换行吃掉，需还原 `||` 边界）
    2. build-flat-kb.py 生成的「【来源 枪型】字段：值；字段：值……」扁平行
    """
    if content.lstrip().startswith("【") and "：" in content:
        row = {}
        for seg in content.replace("；", ";").split(";"):
            if "：" in seg:
                k, v = seg.split("：", 1)
                # 首段形如「【X2C-V3-C C枪】图号」，要剥掉来源前缀才是字段名
                row[k.split("】")[-1].strip()] = v.strip()
        return [row] if row.get("图号") else []

    lines = [l.strip() for l in content.replace("||", "|\n|").splitlines()
             if l.strip().startswith("|")]
    if len(lines) < 3:
        return []
    head = [c.strip() for c in lines[0].strip("|").split("|")]
    res = []
    for line in lines[2:]:
        cells = [c.strip() for c in line.strip("|").split("|")]
        if len(cells) != len(head):
            continue
        res.append({k: v for k, v in zip(head, cells)
                    if v and v not in ("-", "—", "nan", "NaN", "None", "/")})
    return res


# 优先选用关键参数齐全的记录：这样的提问才有区分度
KEY = ["喉深", "喉宽", "加压力", "行程", "变压器", "客户"]
cands, seen = [], set()
for name, content in csv.reader(out.stdout.splitlines()):
    if name == "file_name" or (FILE_FILTER and FILE_FILTER not in name):
        continue
    for row in rows_of(content):
        if len([k for k in KEY if row.get(k)]) < 4:
            continue
        key = json.dumps(row, ensure_ascii=False, sort_keys=True)
        if key in seen:
            continue
        seen.add(key)
        cands.append((name, row))

if len(cands) < CASES:
    sys.exit(f"❌ 可用记录只有 {len(cands)} 条，少于用例数 {CASES}")
random.seed(20261025)
samples = random.sample(cands, CASES)
print(f"    候选 {len(cands)} 条，抽取 {CASES} 条作为用例")

TYPE_CN = {"小型": "小型", "大型": "大型"}


def gun_of(name):
    """从文件名判定枪型：X2C-V3-C-knowledge.xlsx / X2C-V3-C.md 都要识别为 C 枪。"""
    base = re.sub(r"\.md$|\.xlsx$", "", name)          # 去扩展名
    base = re.sub(r"-knowledge$", "", base)
    return "C 枪" if base.split("-")[-1].upper() == "C" else "X 枪"


def make_query(name, row):
    parts = []
    for k in ("喉深", "喉宽", "加压力", "行程", "变压器", "客户"):
        if row.get(k):
            parts.append(f"{k}{row[k]}")
    return "我要一把 " + gun_of(name) + "，" + "、".join(parts) + "，应该用哪个图号？"


def make_auth():
    """返回一个可用的 Authorization 头。

    注意：短期内重复登录会让先前签发的 token 立刻失效（服务端每个用户只
    认最新一次登录），所以这里在**确实用不了时**才重新登录 —— 频繁刷新反而
    会让刚拿到的 token 自己被判失效。
    """
    if token_alive(auth):
        return auth
    r = http("auth/login", {"email": E("ADMIN_EMAIL"),
                            "password": E("ADMIN_PASSWORD")})
    if "token" not in r:
        sys.exit(f"❌ 重新登录失败：{json.dumps(r, ensure_ascii=False)[:200]}")
    return r["token"]           # http() 内部会拼 "Bearer "，这里必须是裸 JWT


def token_alive(header):
    try:
        http("agents", token=header)
        return True
    except Exception:
        return False


def ask(query):
    auth = make_auth()
    try:
        sess = http("sessions", {"title": "验收用例"}, token=auth)["data"]["id"]
    except urllib.error.HTTPError as exc:
        body = exc.read().decode()[:200]
        try:                       # 同一 token 换个 GET 端点，判断是 token 本身还是该端点的问题
            http("agents", token=auth)
            probe = "GET agents 正常"
        except urllib.error.HTTPError as e2:
            probe = f"GET agents 同样 HTTP{e2.code} {e2.read().decode()[:120]}"
        raise RuntimeError(f"创建会话失败 HTTP{exc.code} {body} | token长度={len(auth)} | {probe}")
    try:
        raw = http(f"agent-chat/{sess}", {"query": query, "agent_enabled": True,
                                          "agent_id": AGENT_ID,
                                          "knowledge_base_ids": [KB_ID]},
                   token=auth, raw=True)
    except urllib.error.HTTPError as exc:
        # 把服务端返回的正文打出来，方便定位是鉴权还是会话归属问题
        raise RuntimeError(f"HTTP{exc.code} {exc.read().decode()[:200]}")
    ans = []
    for blk in raw.split("event:message"):
        if "data:" not in blk:
            continue
        try:
            d = json.loads(blk.split("data:", 1)[1].strip())
        except Exception:
            continue
        if d.get("response_type") == "answer":
            ans.append(d.get("content", ""))
    return re.sub(r"\s+", "", "".join(ans))


print("==> [3/4] 逐个用例问答")
hit = total = 0
for i, (name, row) in enumerate(samples, 1):
    expect = row.get("图号", "")
    q = make_query(name, row)
    print(f"\n  用例 {i}/{CASES}  期望图号：{expect}")
    print(f"    提问：{q}")
    for t in range(1, REPEAT + 1):
        t0 = time.time()
        try:
            got = ask(q)
        except Exception as exc:
            print(f"    第 {t} 次：❌ 调用失败 {exc}"); total += 1; continue
        ok = expect in got
        hit += ok; total += 1
        print(f"    第 {t} 次：{'✅' if ok else '❌'} {got or '(空)'}  "
              f"[{time.time()-t0:.1f}s]")
        if REPEAT > 1 and t < REPEAT:
            time.sleep(1)

print(f"\n==> [4/4] 结论：{hit}/{total} 命中，正确率 "
      f"{100.0*hit/total:.0f}%" if total else "\n没有可统计的用例")
PY
