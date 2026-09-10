#!/usr/bin/env bash
# health_check.sh —— 应急平台健康巡检(只读,不修改系统)
# 对应《硬件测试报告》T01/T02 + 《运维排错手册》例行巡检
# 用法: bash health_check.sh
# 退出码: 0=全部通过; 非0=存在故障(逐项输出)
set -uo pipefail

log()  { printf '[巡检] %s\n' "$*"; }
warn() { printf '[警告] %s\n' "$*"; }
die()  { printf '[错误] %s\n' "$*" >&2; }

FAIL=0
note_fail() { FAIL=1; }

# 服务 -> 应 active 清单
SERVICES=(qwen qwen_chat saferag nginx)
# 后端健康端口
API_BASE="http://127.0.0.1:8081"
# 关键路径
KEY_PATHS=(
  "/data/SafeRAG"
  "/data2/www/emergency-platform/frontend"
  "/data2/models/Qwen3_5"
  "/data/SafeRAG/Qwen3_5/python_demo/chat.cpython-310-aarch64-linux-gnu.so"
  "/data/SafeRAG/data/saferag.db"
)

echo "==== T01/T02 健康巡检 ===="

log "1. Python 版本"
if command -v python3 >/dev/null 2>&1; then
  python3 --version || note_fail
else
  warn "未找到 python3"; note_fail
fi

log "2. 关键路径存在性"
for p in "${KEY_PATHS[@]}"; do
  if [ -e "$p" ]; then
    log "   存在: $p"
  else
    warn "   缺失: $p"; note_fail
  fi
done

log "3. 核心依赖可导入"
if python3 -c "import fastapi, chromadb" >/dev/null 2>&1; then
  log "   fastapi/chromadb 导入正常"
else
  warn "   依赖导入失败(可能在校验机非全量环境)"; note_fail
fi

log "4. 服务 active 状态"
for s in "${SERVICES[@]}"; do
  st="$(systemctl is-active "$s" 2>/dev/null || echo inactive)"
  if [ "$st" = "active" ]; then
    log "   $s: active"
  else
    warn "   $s: $st"; note_fail
  fi
done

log "5. 健康接口"
http_code() { curl -s -o /dev/null -m 5 -w '%{http_code}' "$1" 2>/dev/null || echo ERR; }
c8000="$(http_code http://127.0.0.1:8000/health)"
c8001="$(http_code http://127.0.0.1:8001/health)"
c8081="$(http_code "$API_BASE/health")"
c80="$(http_code http://127.0.0.1/)"
printf "   8000模型(4B)=%s 8001模型(2B)=%s 8081后端=%s 80前端=%s\n" "$c8000" "$c8001" "$c8081" "$c80"
for c in "$c8000" "$c8001" "$c8081" "$c80"; do
  [ "$c" = "200" ] || note_fail
done

echo "==== 结果 ===="
if [ "$FAIL" = "0" ]; then
  log "全部通过 ✅"
  exit 0
else
  warn "存在异常, 请对照《运维排错手册》排查 ⚠"
  exit 1
fi