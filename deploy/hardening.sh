#!/usr/bin/env bash
# hardening.sh —— 安全加固(对应《ARM64安全合规手册》加固 Checklist)
# 用法: sudo ETH_CIDR=10.0.0.0/8 bash hardening.sh
# 变量: ETH_CIDR=内网管理网段(默认 192.168.0.0/16)
#       FIREWALL_SKIP=1 跳过防火墙
#       NOLOCK=1        跳过确认直接执行(须先手动备份)
# 注意: 本脚本会修改系统配置, 请先备份关键文件再执行。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

log()  { printf '[加固] %s\n' "$*"; }
warn() { printf '[警告] %s\n' "$*"; }
die()  { printf '[错误] %s\n' "$*" >&2; exit 1; }

ETH_CIDR="${ETH_CIDR:-192.168.0.0/16}"
FIREWALL_SKIP="${FIREWALL_SKIP:-0}"
NOLOCK="${NOLOCK:-0}"

[ "$(id -u)" = "0" ] || die "请用 sudo 运行"

# 重要配置文件先备份到 /root/backup_hardening_<时间戳>
TS="$(date '+%Y%m%d_%H%M%S')"
BK="/root/backup_hardening_$TS"
mkdir -p "$BK"
backup_file() { [ -e "$1" ] && cp -a "$1" "$BK/" 2>/dev/null || true; }

confirm() {
  if [ "$NOLOCK" = "1" ]; then return 0; fi
  printf "%s (若管理端IP不在%s内可能锁死SSH) [y/N]: " "是否继续加固?" "$ETH_CIDR"
  read -r ans || return 1
  [ "$ans" = "y" ] || [ "$ans" = "Y" ]
}

if ! confirm; then
  warn "已取消(可用 NOLOCK=1 强制执行, 请务必先手动备份)"
  exit 1
fi

log "==== 0. 备份关键文件到 $BK ===="
backup_file /etc/nginx/nginx.conf
backup_file /etc/ssh/sshd_config
backup_file /etc/dpkg/dpkg.cfg.d/01_norecommends
mkdir -p "$BK/apt"
find /etc/apt -type f 2>/dev/null | head -50 | xargs -r cp -a -t "$BK/apt" 2>/dev/null || true
log "   备份目录: $BK"

log "==== 1. 锁定系统软件源(禁用无网络时的自动更新) ===="
# 防 apt 自动更新; 失败不影响后续, 用 || true 包装
disable_auto_update() {
  systemctl stop apt-daily.timer apt-daily-upgrade.timer 2>/dev/null || true
  systemctl disable apt-daily.timer apt-daily-upgrade.timer 2>/dev/null || true
  if [ -d /etc/apt/apt.conf.d ]; then
    cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "0";
APT::Periodic::Unattended-Upgrade "0";
EOF
  fi
}
disable_auto_update
log "   已禁用自动更新"

log "==== 2. pip 禁联网/禁升级 ===="
if command -v pip3 >/dev/null 2>&1; then
  cat > /etc/pip.conf <<'EOF'
[global]
no-index = true
EOF
  log "   已写 /etc/pip.conf(no-index)"
else
  warn "   pip3 不存在, 跳过"
fi

log "==== 3. SSH 加固 ===="
SSHD=/etc/ssh/sshd_config
if [ -f "$SSHD" ]; then
  # 禁止 root 密码登录(保留密钥); 追加若不存在
  grep -q '^PermitRootLogin' "$SSHD" && sed -i 's/^PermitRootLogin.*/PermitRootLogin prohibit-password/' "$SSHD" \
    || echo 'PermitRootLogin prohibit-password' >> "$SSHD"
  log "   已设置 PermitRootLogin prohibit-password (请确保有密钥可登录, 谨慎重启 sshd)"
else
  warn "   无 $SSHD, 跳过SSH加固"
fi

log "==== 4. 防火墙(ufw 白名单仅入站) ===="
# 统一复用同事的 ufw_firewall.sh(与 install.sh 行为一致), 避免两处规则漂移
# ufw_firewall.sh 内部处理 FIREWALL_SKIP=1、未装 ufw 等情形
if [ -f "$SCRIPT_DIR/ufw_firewall.sh" ]; then
  bash "$SCRIPT_DIR/ufw_firewall.sh" "$ETH_CIDR"
else
  warn "   同目录无 ufw_firewall.sh, 跳过防火墙(可另配 iptables)"
fi

log "==== 5. 日志持久化(保证审计日志可查) ===="
log "   建议: journalctl --disk-usage 检查; 如需持久化可用 /var/log/journal 同步"

log "==== 完成 ===="
log "回滚: 若异常, 手工恢复 $BK 中文件后重启对应服务。"