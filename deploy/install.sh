#!/usr/bin/env bash
# install.sh —— 在目标机部署应急安全综合平台(以 root 运行, 含解压)
# 用法: sudo ./install.sh /路径/emergency_offline.tar
# 变量: ETH_CIDR=内网网段(默认 192.168.0.0/16), FIREWALL_SKIP=1 跳过防火墙
set -euo pipefail

log()  { printf '[部署] %s\n' "$*"; }
warn() { printf '[警告] %s\n' "$*"; }
die()  { printf '[错误] %s\n' "$*" >&2; exit 1; }

TAR="${1:-$(pwd)/emergency_offline.tar}"
ETH_CIDR="${ETH_CIDR:-192.168.0.0/16}"
FIREWALL_SKIP="${FIREWALL_SKIP:-0}"
# 安置根: 打包含内容落在哪个前缀下必须与打包时 PREFIX 一致(默认 /data)
PREFIX="${PREFIX:-/data}"

preflight() {
  log "==== 前置校验 ===="
  [ "$(id -u)" = "0" ] || die "请用 sudo 运行"
  [ "$(uname -m)" = "aarch64" ] || die "目标机非 aarch64"
  [ -f "$TAR" ] || die "找不到 tar: $TAR"
}

unpack() {
  log "==== 解压(恢复绝对路径; 源盒 /data2 已整体落到 $PREFIX) ===="
  # -P 保留绝对路径; 本包为未压缩 tar, 用 xpPf 不带 z
  # 可用空间: 若 $PREFIX 是独立挂载点则查它, 否则查根分区
  local disk="$PREFIX"; mountpoint -q "$PREFIX" 2>/dev/null || disk="/"
  local av; av="$(df -k --output=avail "$disk" 2>/dev/null | awk 'NR==2{print $1}')"
  if [ -n "$av" ] && [ "$((av/1024/1024))" -lt 14 ]; then
    warn "可用空间不足 14G(当前 ~$((av/1024/1024))G, 挂载点 $disk), 解压 ~11G 可能失败。请扩容后再跑。"
  fi
  tar xpPf "$TAR" -C /
}

install_sysdebs() {
  log "==== 安装系统软件 (nginx/python3) ===="
  if [ -x /opt/sysdebs/install.sh ]; then
    /opt/sysdebs/install.sh
  elif command -v apt-get >/dev/null 2>&1; then
    log "包内无 sysdebs, 改用 apt(需内网 apt 源):"
    apt-get install -y python3 python3.10 nginx \
      || warn "apt 安装失败, 请手工确认 nginx/python3"
  else
    warn "无 install.sh 也无 apt, 请手工确认 nginx/python3"
  fi
}

setup_firewall() {
  if [ "$FIREWALL_SKIP" = "1" ]; then log "跳过防火墙(FIREWALL_SKIP=1)"; return 0; fi
  log "==== 防火墙(复现源盒 ufw 策略) ===="
  if ! command -v ufw >/dev/null 2>&1; then warn "未装 ufw, 跳过(可另配 iptables)"; return 0; fi
  # ⚠ 默认拒绝入站: 若管理端 IP 不在 ETH_CIDR 内, 先用 ETH_CIDR=<网段> 覆盖再跑以免锁死 SSH
  ufw default deny incoming
  ufw default allow outgoing
  ufw allow from "$ETH_CIDR" to any port 22 proto tcp
  ufw allow from "$ETH_CIDR" to any port 80 proto tcp
  ufw --force enable
  ufw status verbose
}

start_services() {
  log "==== 启动后端/模型自启 ===="
  systemctl daemon-reload
  systemctl enable --now qwen.service qwen_chat.service saferag.service
  log "==== 启动 nginx ===="
  systemctl enable --now nginx
  nginx -t && systemctl restart nginx
}

verify() {
  log "==== 验证 ===="
  for u in http://127.0.0.1:8000/health http://127.0.0.1:8001/health; do
    printf '  %s -> %s\n' "$u" "$(curl -s -o /dev/null -w '%{http_code}' "$u" || echo ERR)"
  done
  printf '  后端 127.0.0.1:8081 -> %s\n' "$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:8081/ || echo ERR)"
  printf '  前端 / -> %s\n' "$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1/ || echo ERR)"
}

main() {
  preflight
  unpack
  install_sysdebs
  setup_firewall
  start_services
  verify
  log "部署完成 ✅ 前端 http://<目标机IP>/login.html"
}
main "$@"