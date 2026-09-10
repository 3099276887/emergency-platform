#!/usr/bin/env bash
# monitor.sh —— 系统性能/资源快照(只读)
# 对应《硬件测试报告》T06 资源监控, 配合 stress_test.sh 观察
# 用法:
#   bash monitor.sh            # 单次快照
#   bash monitor.sh -l 5 3     # 每5秒采样1次,共3次
set -uo pipefail

log() { printf '[监控] %s\n' "$*"; }

OPT_LIST=0
OPT_INTERVAL=5
OPT_COUNT=1

usage() {
  echo "用法: bash monitor.sh [-l 间隔秒 次数]"
  echo "  -l 间隔 次数   循环采样(默认: 间隔5 次数1=单次)"
  exit 1
}

while [ $# -gt 0 ]; do
  case "$1" in
    -l) OPT_LIST=1
        OPT_INTERVAL="${2:-5}"; OPT_COUNT="${3:-3}"
        shift 3 2>/dev/null || shift 2 2>/dev/null || shift ;;
    -h|--help) usage ;;
    *) usage ;;
  esac
done

snapshot() {
  local ts; ts="$(date '+%F %T')"
  echo "===== $ts ====="
  # CPU 负载与核心数
  echo "-- 负载 loadavg: $(cut -d' ' -f1-3 /proc/loadavg)  核心数: $(nproc)"
  # 内存
  echo "-- 内存:"
  free -h | awk 'NR==1 || /^Mem:/ {print}'
  # 磁盘
  echo "-- 磁盘:"
  df -h / /data /data2 2>/dev/null | awk 'NR==1 {print $1"\t"$2"\t"$3"\t"$4"\t"$5"\t"$6}'
  df -h / /data /data2 2>/dev/null | awk 'NR>1 {print $1"\t"$2"\t"$3"\t"$4"\t"$5"\t"$6}'
  # 温度
  echo "-- 温度(℃):"
  for z in /sys/class/thermal/thermal_zone*/temp; do
    [ -r "$z" ] && echo "  $z: $(awk -v v="$(cat "$z")" 'BEGIN{printf "%.1f", v/1000}')"
  done
  # 占用最高 CPU 的进程 top5
  echo "-- 占用CPU Top5:"
  ps -eo pcpu,pmem,comm --sort=-pcpu | head -6
}

if [ "$OPT_LIST" = "1" ]; then
  for i in $(seq 1 "$OPT_COUNT"); do
    snapshot
    [ "$i" -lt "$OPT_COUNT" ] && sleep "$OPT_INTERVAL"
  done
else
  snapshot
fi