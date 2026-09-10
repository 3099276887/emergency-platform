#!/usr/bin/env bash
# backup_data.sh —— 备份平台运行数据(SQLite + 向量库 + 文档)
# 对应《运维排错手册》备份恢复章节
# 用法: sudo bash backup_data.sh
# 变量: DATA_DIR=数据源(默认 /data/SafeRAG/data)
#       BK_DIR=备份目录(默认 /data/SafeRAG/backup)
#       KEEP=保留备份份数(默认 5)
# 建议配合 cron 定时执行: 0 2 * * * /data2/www/emergency-platform/deploy/backup_data.sh
set -euo pipefail

log()  { printf '[备份] %s\n' "$*"; }
warn() { printf '[警告] %s\n' "$*"; }
die()  { printf '[错误] %s\n' "$*" >&2; exit 1; }

SRC="${DATA_DIR:-/data/SafeRAG/data}"
BK="${BK_DIR:-/data/SafeRAG/backup}"
KEEP="${KEEP:-5}"

# 非 root 时建议提示(但仍允许普通权限备份只读数据)
own=$(stat -c %U "$SRC" 2>/dev/null || echo "")
if [ "$(id -u)" != "0" ] && [ "$own" = "root" ]; then
  warn "数据属主为 root, 建议 sudo 运行以避免权限问题"
fi

[ -d "$SRC" ] || die "数据目录不存在: $SRC"

STAMP="$(date '+%Y%m%d_%H%M%S')"
DEST="$BK/platform_data_$STAMP.tar.gz"

mkdir -p "$BK"
log "备份 $SRC → $DEST"

# 建议在业务低峰执行; -z gzip 只对数据(~几百MB)可接受
tar -czf "$DEST" -C "$(dirname "$SRC")" "$(basename "$SRC")"
log "完成: $(du -h "$DEST" | cut -f1)"

# 清理旧备份, 只留最近 KEEP 份
count=0
for f in $(ls -1t "$BK"/platform_data_*.tar.gz 2>/dev/null); do
  count=$((count+1))
  if [ "$count" -gt "$KEEP" ]; then
    log "清理旧备份: $f"
    rm -f "$f"
  fi
done

log "保留最近 ${KEEP} 份, 当前共 ${count} 份"
log "恢复: tar xzf <备份> -C /data/SafeRAG"