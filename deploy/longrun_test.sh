#!/usr/bin/env bash
# longrun_test.sh —— 连续推理长跑压测（走 SafeRAG 后端全链路）
# 对应《硬件测试报告》T04「长跑」用例：连续推理, 验证无 OOM / 无服务崩溃 / 温度不持续攀升。
#
# 原理: 先用账号登录拿 JWT, 再循环 POST /api/v1/chat/completions(SSE),
#       一轮结束才发下一轮, 形成连续负载; 由 monitor.sh 另开终端记录资源/温度。
#
# 用法:
#   bash longrun_test.sh                 # 默认 1800s, 走后端对话模型
#   DURATION=600 bash longrun_test.sh    # 覆盖时长(秒)
#   USER=sysadmin PWD=xxx bash longrun_test.sh   # 覆盖账号/密码
#   RAG=1 bash longrun_test.sh           # enable_rag=true, 顺带压 RAG 检索
#   PORT=8000 DURATION=600 bash longrun_test.sh  # 改直连引擎(不需密码)
#   OUT=/data/longrun.log bash longrun_test.sh   # 改结果落盘路径
#   MAX_FAIL=3 bash longrun_test.sh      # 连续失败 N 次即退出(防空转干烧)
set -uo pipefail

# ---- 可覆盖参数 ----
BASE="${BASE:-http://127.0.0.1}"
USER="${USER:-user}"
PWD="${PWD:-}"
DURATION="${DURATION:-1800}"          # 秒, 默认 30 分钟
RAG="${RAG:-0}"                       # 1 = enable_rag 检索法规, 负载更重
PORT="${PORT:-0}"                     # 0=后端; 8000/8001=直连引擎
OUT="${OUT:-/tmp/longrun.log}"         # 结果落盘(tee 实时写)
MAX_FAIL="${MAX_FAIL:-3}"             # 连续失败阈值, 防空转

[ -n "$PWD" ] || { echo "!! 需账号密码: USER=xxx PWD=xxx bash longrun_test.sh"; exit 1; }
command -v python3 >/dev/null || { echo "!! 缺 python3"; exit 1; }
command -v curl   >/dev/null || { echo "!! 缺 curl"; exit 1; }

ENABLE_RAG="false"; [ "$RAG" = "1" ] && ENABLE_RAG="true"
ts() { date '+%F %T'; }

# 发起一轮 SSE 请求, 输出两列(制表符分隔):  字数 <TAB> 耗时秒  或  ERR <TAB> 错误信息
run_one() {
  local ip="$1" body="$2"
  python3 - "$ip" "$body" "${3:-}" <<'PYEOF'
import sys, json, time, urllib.request, urllib.error
url, body, token = sys.argv[1], sys.argv[2], sys.argv[3] if len(sys.argv) > 3 else ""
t0 = time.monotonic()
h = {"Content-Type": "application/json"}
if token: h["Authorization"] = "Bearer " + token
n = 0
try:
    req = urllib.request.Request(url, data=body.encode(), headers=h)
    with urllib.request.urlopen(req, timeout=120) as r:
        for line in r:
            line = line.decode("utf-8", "ignore").strip()
            if not line or not line.startswith("data:"):
                continue
            p = line[5:].strip()
            if p == "[DONE]":
                break
            try:
                n += len(json.loads(p)["choices"][0]["delta"].get("content", ""))
            except Exception:
                pass
    print(f"{n}\t{time.monotonic()-t0:.2f}")
except urllib.error.HTTPError as e:
    print(f"ERR\tHTTP {e.code}: {e.read()[:200]}")
except Exception as e:
    print(f"ERR\t{e}")
PYEOF
}

# 组装 body。用 python 生成 JSON, 避免手工拼接引号/特殊字符出错
BODY="$(python3 - "$ENABLE_RAG" "$RAG" <<'PYEOF'
import sys
enable_rag, rag = sys.argv[1], sys.argv[2]
fts = ['国家法律', '行政法规', '地方法规'] if rag == "1" else []
sys.stdout.write(json.dumps({
    "messages": [{"role": "user",
                  "content": "请用不少于500字说明应急联动平台火灾处置流程,分步骤。"}],
    "stream": True, "enable_rag": enable_rag == "true", "file_types": fts,
}, ensure_ascii=False))
PYEOF
)"
BODY_ENGINE='{"messages":[{"role":"user","content":"请用不少于500字说明应急联动平台火灾处置流程,分步骤。"}],"stream":true,"max_tokens":512}'

# 决定端点与鉴权
if [ "$PORT" != "0" ]; then
  URL="$BASE:$PORT/v1/chat/completions"
  TOKEN=""
else
  URL="$BASE/api/v1/chat/completions"
  TOKEN="$(curl -s -X POST "$BASE/api/v1/auth/login" -H 'Content-Type: application/json' \
    -d "$(USER="$USER" PWD="$PWD" python3 - <<'PYEOF'
import os, json
sys.stdout.write(json.dumps({"username": os.environ["USER"], "password": os.environ["PWD"]}))
PYEOF
)" \
    | python3 -c 'import sys,json
try: print(json.load(sys.stdin)["access_token"])
except Exception:
    sys.stderr.write("!! 登录响应非预期 JSON\n"); sys.exit(1)' )" \
    || { echo "!! 登录失败(账号/密码或网络)"; exit 1; }
  echo "[$(ts)] 登录成功: $USER  token 前20: ${TOKEN:0:20}..."
fi

# 中断/退出时也打印汇总
i=0; total_chars=0; n_fail=0
fini() {
  echo "===================================================="
  echo "[$(ts)] 结果: 完成 $i 轮 / 共输出约 $total_chars 字 / 时长 ${DURATION}s / 失败 $n_fail 次"
  echo "日志: $OUT   请核对 docker ps 四容器仍 Up + monitor 最高温度/内存"
  exit 0
}
trap fini EXIT

echo "== 连续推理长跑: ${DURATION}s, 端点 $URL, RAG=$ENABLE_RAG =="
echo "结果将实时写入: $OUT  (并行监控: bash monitor.sh -l 30 60 > /tmp/longrun_monitor.log)"
echo "===================================================="

deadline=$(( $(date +%s) + DURATION ))
while [ "$(date +%s)" -lt "$deadline" ]; do
  if [ "$PORT" != "0" ]; then
    r="$(run_one "$URL" "$BODY_ENGINE")"
  else
    r="$(run_one "$URL" "$BODY" "$TOKEN")"
  fi

  if [ "$(echo "$r" | cut -f1)" = "ERR" ]; then
    msg="[$(ts)] 轮$i 失败: $(echo "$r" | cut -f2-)"
    echo "$msg" | tee -a "$OUT"
    n_fail=$(( n_fail + 1 ))
    # 连续失败超阈值 → 防空转干烧
    if [ "$n_fail" -ge "$MAX_FAIL" ]; then
      echo "[$(ts)] 连续失败 ${MAX_FAIL} 次, 提前结束(检查服务/网络)" | tee -a "$OUT"
      break
    fi
  else
    n_fail=0
    n="$(echo "$r" | cut -f1)"; t="$(echo "$r" | cut -f2)"
    total_chars=$(( total_chars + n ))
    line="[$(ts)] 轮$i  耗时 ${t}s  输出 ${n} 字"
    echo "$line" | tee -a "$OUT"
  fi
  i=$(( i + 1 ))
  sleep 1
done