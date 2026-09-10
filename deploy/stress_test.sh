#!/usr/bin/env bash
# stress_test.sh —— 压力/并发测试, 供《硬件测试报告》T04/T05/T06 取数
# 用法:
#   bash stress_test.sh        # 一轮: CPU+内存+磁盘压测 + 后端并发
#   bash stress_test.sh --api  # 仅后端接口并发
#   bash stress_test.sh --cpu  # 仅 CPU 压测(10 秒)
set -uo pipefail

log() { printf '[压测] %s\n' "$*"; }
warn() { printf '[警告] %s\n' "$*"; }

API="http://127.0.0.1:8081"
DURATION=10
MODE="all"

usage() {
  echo "用法: bash stress_test.sh [--all|--api|--cpu]"
  echo "  (默认 --all)  DURATION=秒 可覆盖压测时长"
  exit 1
}

case "${1:-all}" in
  --all) MODE=all ;;
  --api) MODE=api ;;
  --cpu) MODE=cpu ;;
  *) usage ;;
esac

cpu_stress() {
  log "CPU 压测(${DURATION}秒) ..."
  # 用 bash 自旋近似 stress, 避免依赖 stress 工具
  local cores; cores="$(nproc)"
  local pids=()
  for i in $(seq "$cores"); do
    ( while true; do :; done ) &
    pids+=( $! )
  done
  sleep "$DURATION"
  for p in "${pids[@]}"; do kill "$p" 2>/dev/null || true; done
  wait 2>/dev/null || true
  log "CPU 压测结束 (占用最高进程请配合 monitor.sh 观察)"
}

mem_stress() {
  log "内存写压测(${DURATION}秒, 写大文件后释放) ..."
  # 尽量取系统内存的一半以下, 避免触发 OOM
  local total_kb; total_kb="$(awk '/MemTotal/{print $2}' /proc/meminfo)"
  local target_mb=$(( total_kb / 1024 / 4 ))
  log "  尝试写 ~${target_mb}MB 后立即释放"
  dd if=/dev/zero of=/tmp/.stress_mem bs=1M count="$target_mb" status=none 2>/dev/null \
    && sleep 2 && rm -f /tmp/.stress_mem
  log "内存压测结束"
}

disk_stress() {
  log "磁盘写压测 → /tmp/.stress_disk ..."
  dd if=/dev/zero of=/tmp/.stress_disk bs=1M count=1024 conv=fsync status=none 2>/dev/null
  log "  写入后读取效验:"
  dd if=/tmp/.stress_disk of=/dev/null bs=1M status=none 2>/dev/null
  rm -f /tmp/.stress_disk
  log "磁盘压测结束"
}

api_stress() {
  local n=20  # 并发连接数
  log "后端并发压测: ${n} 路同时请求 / 健康接口"
  log "  (T05 需真实对话/检索请改用浏览器多开或接真实接口)"
  local pids=()
  for i in $(seq "$n"); do
    curl -s -o /dev/null -m 15 "$API/health" &
    pids+=( $! )
  done
  wait "${pids[@]}" 2>/dev/null || true
  log "  ${n} 路健康请求完成"
}

case "$MODE" in
  all)
    cpu_stress
    mem_stress
    disk_stress
    api_stress
    log "一轮压测结束, 请配合 monitor.sh 记录 CPU/内存/温度峰值"
    ;;
  api)
    api_stress
    ;;
  cpu)
    cpu_stress
    ;;
esac