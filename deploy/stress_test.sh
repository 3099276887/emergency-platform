#!/usr/bin/env bash
# stress_test.sh —— 硬件压测, 供《硬件测试报告》T03/T04 取数
# 用法:
#   bash stress_test.sh        # 一轮: CPU+内存+磁盘压测
#   bash stress_test.sh --cpu  # 仅 CPU 压测(10 秒)
set -uo pipefail

log() { printf '[压测] %s\n' "$*"; }
warn() { printf '[警告] %s\n' "$*"; }

DURATION=10
MODE="all"

usage() {
  echo "用法: bash stress_test.sh [--all|--cpu]"
  echo "  (默认 --all)  DURATION=秒 可覆盖压测时长"
  exit 1
}

case "${1:-all}" in
  --all) MODE=all ;;
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

case "$MODE" in
  all)
    cpu_stress
    mem_stress
    disk_stress
    log "一轮压测结束, 请配合 monitor.sh 记录 CPU/内存/温度峰值"
    ;;
  cpu)
    cpu_stress
    ;;
esac