#!/usr/bin/env bash
# hwtest.sh —— 硬件测试一键编排脚本, 对照《硬件测试报告-BM1688 / BM1684X.docx》通用
# 覆盖 T01/T02/T03/T04/T05 中凡能用命令/curl 测的项; 断电/重启( T06) 留末尾清单手动处理。
# 复用同目录 stress_test.sh(压测) / monitor.sh(监控)。
# 用法(在盒子上执行):
#   sudo bash hwtest.sh                # 完整一轮(建议在非业务高峰跑)
#   bash hwtest.sh --skip-data         # 跳过真实数据盘 /data /data2 的 dd 写压测
#   bash hwtest.sh --no-perf           # 跳过 T03 推理性能测速
#   DURATION=15 sudo bash hwtest.sh    # 覆盖压测时长(秒, 默认 10)
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STRESS="$SCRIPT_DIR/stress_test.sh"
MONITOR="$SCRIPT_DIR/monitor.sh"

DURATION="${DURATION:-10}"
DATA_DIRS="${DATA_DIRS:-/data /data2}"
BACKEND_DATA_DIRS="${BACKEND_DATA_DIRS:-/data/SafeRAG/backend/data}"
SKIP_DATA=0
NO_PERF=0
RUN_ID="$(date '+%Y%m%d_%H%M%S')"
LOG="/tmp/hwtest_${RUN_ID}.log"
SAMPLER_LOG="/tmp/hwtest_sampler_${RUN_ID}.log"

log()  { printf '%-16s %s\n' "[$1]" "$2" | tee -a "$LOG"; }
sep()  { echo "----------------------------------------" | tee -a "$LOG"; }
shot() { echo "    >> 截图/记录: $1" | tee -a "$LOG"; }

usage() {
  echo "用法: sudo bash $0 [--skip-data] [--no-perf]"
  echo "  --skip-data  跳过真实数据盘(/data /data2) dd 写压测"
  echo "  --no-perf    跳过 T03 推理性能测速"
  echo "  DURATION=秒  覆盖压测时长(默认 10)"
  exit 1
}

case "${1:-}" in
  "") ;;
  --skip-data) SKIP_DATA=1 ;;
  --no-perf) NO_PERF=1 ;;
  *) usage ;;
esac

> "$LOG"
log "RUN" "开始硬件测试 日志=$LOG (压测=${DURATION}s, 数据盘=$DATA_DIRS)"
sep

# ================= 后台采样 & 极值汇总 =================
start_sampler() {
  : > "$SAMPLER_LOG"
  ( while :; do
      ts="$(date '+%T')"
      load="$(cut -d' ' -f1 /proc/loadavg)"
      mem="$(free -m | awk '/^Mem:/{print $3"/"$2}')"
      tmax="$(for z in /sys/class/thermal/thermal_zone*/temp; do [ -r "$z" ] && cat "$z"; done | sort -n | tail -1)"
      if [ -n "$tmax" ]; then
        temp="$(awk -v v="$tmax" 'BEGIN{printf "%.1f", v/1000}')C"
      else
        temp="N/A"
      fi
      echo "$ts load=$load mem=${mem}M temp=$temp"
      sleep 1
    done >> "$SAMPLER_LOG" ) &
  SAMPLER_PID=$!
}
stop_sampler() {
  kill "$SAMPLER_PID" 2>/dev/null || true
  wait "$SAMPLER_PID" 2>/dev/null || true
}
peak_report() {
  local tmax tload
  tmax="$(grep -o 'temp=[0-9.]*C' "$SAMPLER_LOG" | sort -t= -k2 -nr | head -1)"
  tload="$(grep -o 'load=[0-9.]*' "$SAMPLER_LOG" | sort -t= -k2 -nr | head -1)"
  log "RECORD" "温度峰值: ${tmax} ; load 峰值: ${tload}"
  log "RECORD" "压测后 CPU 占用 Top5:"
  ps -eo pcpu,pmem,comm --sort=-pcpu | head -6 | sed 's/^/    /' | tee -a "$LOG"
}
temp_final() {
  log "RECORD" "最终温度:"
  for z in /sys/class/thermal/thermal_zone*/temp; do
    [ -r "$z" ] || continue
    printf '    %s: %.1fC\n' "$z" "$(awk -v v="$(cat "$z")" 'BEGIN{printf "%.1f", v/1000}')" | tee -a "$LOG"
  done
}

# ================= T03 推理性能: 首token延迟 + 吞吐 =================
perf_test() {
  local port="$1" label="$2"
  local body="/tmp/hwtest_perf_${port}_${RUN_ID}.sse"
  : > "$body"
  local payload='{"model":"tpu-qwen3.5","messages":[{"role":"user","content":"请用三句话介绍人工智能在应急安全领域的主要应用。"}],"max_tokens":256,"stream":true}'
  local t0 cpid t_ttft t_end tok ttft_ms gen_s per_s
  t0="$(date +%s.%N)"
  curl -sN -m120 -H 'Content-Type: application/json' -d "$payload" \
       -o "$body" "http://127.0.0.1:${port}/v1/chat/completions" 2>/dev/null &
  cpid=$!
  while ! grep -q '"content":"' "$body" 2>/dev/null; do
    if ! kill -0 "$cpid" 2>/dev/null; then break; fi
    sleep 0.02
  done
  t_ttft="$(date +%s.%N)"
  wait "$cpid" 2>/dev/null || true
  t_end="$(date +%s.%N)"
  tok="$(grep -o '"content":"' "$body" | wc -l)"
  ttft_ms="$(awk -v a="$t0" -v b="$t_ttft" 'BEGIN{printf "%.0f", (b-a)*1000}')"
  gen_s="$(awk -v a="$t_ttft" -v b="$t_end" 'BEGIN{d=b-a; if(d<=0) d=0.001; printf "%.2f", d}')"
  per_s="$(awk -v t="$tok" -v g="$gen_s" 'BEGIN{printf "%.1f", t/g}')"
  log "T03" "$label: 首token≈${ttft_ms}ms | ${tok}token / ${gen_s}s ≈ ${per_s} tok/s (SSE)"
  shot "$label 测速输出与 SSE 返回值(留作性能回填)"
  rm -f "$body"
}

# ================= 1/5 环境采集 T01 =================
log "1/5" "环境采集(T01):"
{
  echo "== uname -a          ==";  uname -a
  echo "== /etc/os-release   ==";  cat /etc/os-release
  echo "== lscpu(CPU)        ==";  lscpu | grep -Ei '^(架构|Architecture|CPU\(s\)|型号名|Model name|核?心|Thread|Core)' 
  echo "== nproc / free -h   ==";  nproc; free -h
  echo "== df -h / /data /data2 =="; df -h / /data /data2 2>/dev/null
  echo "== python3 --version ==";  python3 --version
  echo "== 内核 uname -r     ==";  uname -r
  echo "== NPU 节点          ==";  ls -l /dev/bmdev-ctl /dev/ion /dev/bm-tpu0 2>/dev/null
  echo "== docker images     ==";  docker images 2>/dev/null
} | tee -a "$LOG"
shot "环境确认界面整屏(或上面文本存档即可回填数值)"
sep

# ================= 2/5 服务运行状态 T02(压测与推理前置) =================
log "2/5" "服务运行状态(T02):"
{
  echo "== docker ps =="; docker ps
  echo "== 8000 引擎 /health =="; curl -s -m3 127.0.0.1:8000/health; echo
  echo "== 8001 引擎 /health =="; curl -s -m3 127.0.0.1:8001/health; echo
  echo "== 前端80 HTTP       =="; curl -s -m3 -o /dev/null -w 'HTTP %{http_code}\n' 127.0.0.1/
  echo "== 8081 /api/v1/health(需JWT) HTTP ==";  curl -s -m3 -o /dev/null -w '%{http_code}' 127.0.0.1:8081/api/v1/health; echo "  (401=JWT已生效,8081带鉴权不可裸测属预期)"
} | tee -a "$LOG"
shot "docker ps 全 Up、两引擎 health 回显、前端/8081 的 HTTP 码"
sep

# ================= 3/5 推理性能 T03(安静环境测) =================
if [ "$NO_PERF" = "1" ]; then
  log "3/5" "已跳过 T03 推理性能测速(--no-perf)"
else
  log "3/5" "推理性能(T03) —— 建议在无压测占用时测:"
  perf_test 8000 "4B引擎(8000)"
  if curl -s -m3 -o /dev/null -w '%{http_code}' 127.0.0.1:8001/health 2>/dev/null | grep -q 200; then
    perf_test 8001 "2B引擎(8001)"
  else
    log "T03" "8001 未监听或无 2B bmodel, 跳过 2B 对照"
  fi
fi
sep

# ================= 4/5 压力与稳定性 T04(空闲基线+CPU+内存/磁盘压测) =================
log "4/5" "空闲基线(monitor.sh -l 30 4):"
bash "$MONITOR" -l 30 4 2>/dev/null | tee -a "$LOG"
shot "空闲 loadavg/内存/温度 一组数值"
sep

log "4/5" "CPU压测 ${DURATION}s(stress_test.sh --cpu):"
start_sampler
bash "$STRESS" --cpu 2>/dev/null | tee -a "$LOG"
stop_sampler; peak_report
shot "压测中峰值 / CPU Top5 / 压后回落"
sep

log "4/5" "内存+磁盘压测 ${DURATION}s(stress_test.sh --all):"
start_sampler
bash "$STRESS" --all 2>/dev/null | tee -a "$LOG"
stop_sampler; peak_report
echo "    (stress_test.sh 磁盘段写 /tmp overlay, 5/5 才对真实数据盘测)" | tee -a "$LOG"
shot "峰值与回落; 确认无 OOM"
sep

# ================= 5/5 真实数据盘 + 数据持久化 T05 =================
log "5/5" "真实数据盘 dd 写压测($DATA_DIRS):"
if [ "$SKIP_DATA" = "1" ]; then
  echo "    已跳过(--skip-data)" | tee -a "$LOG"
else
  for d in $DATA_DIRS; do
    if [ ! -d "$d" ]; then echo "    skip: $d 不存在" | tee -a "$LOG"; continue; fi
    echo "== 写前 df $d ==" | tee -a "$LOG"; df -h "$d" | tee -a "$LOG"
    dd if=/dev/zero of="$d/.hwtest_dd" bs=1M count=1024 conv=fsync status=progress 2>&1 | tee -a "$LOG"
    echo "== 写后 df $d ==" | tee -a "$LOG"; df -h "$d" | tee -a "$LOG"
    rm -f "$d/.hwtest_dd"
  done
  temp_final
  shot "每个数据盘 dd 写速 + df 前后对比 + 温度峰值"
fi
sep

log "5/5" "数据落盘检查(T05):"
echo "== 数据目录 /data/SafeRAG/backend/data ==";  ls -la "$BACKEND_DATA_DIRS" 2>/dev/null | tee -a "$LOG"
shot "数据目录文件列表(重启恢复项/断电自启见下方手动清单)"
sep

# ================= 完成汇总(手动项: T06 可靠性) =================
log "done" "完成。日志=$LOG  采样明细=$SAMPLER_LOG"
log "清单" "以下项脚本无法自动化, 请手动操作并截图(对应报告项):"
echo "    T05 重启恢复: docker restart saferag-backend 后重新登录, 验证数据完整"           | tee -a "$LOG"
echo "    T06 可靠性: 断电/重启 前后两张 docker ps 对比 + health 复通回显"               | tee -a "$LOG"
echo "    长跑(可选, T04): 终端A sudo bash longrun_test.sh, 终端B bash monitor.sh -l 30 60 > /tmp/longrun_monitor.log" | tee -a "$LOG"