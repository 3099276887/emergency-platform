#!/usr/bin/env bash
# =============================================================================
# 应急安全综合平台 —— 离线迁移安装包导出脚本（系统全局 Python 版）
# 在"已部署好的 AI 盒子"上运行，导出一份能原样还原到同架构新盒子的安装包。
#
# 适用架构(已核实你的盒子):
#   - Sophgo BM1688 ARM (aarch64) 盒子, Debian/Ubuntu, Ubuntu 基础(可见 /etc/sophonOS)
#   - 依赖: 系统全局 python3.10 的 site-packages（无 venv / 无 conda）
#   - 模型: qwen.service(4B->8000) + qwen_chat.service(2B->8001), 均 /usr/bin/python3 server.py
#   - 后端: saferag.service, /usr/local/bin/uvicorn backend.main:app --host 127.0.0.1 --port 8081
#   - 前端: nginx 托管 /data2/www/emergency-platform/frontend
#
# 原理: 按【绝对路径】打包, 每份内容带环境变量开关; 新盒 root 解压到 / 即原样还原。
#       依赖走"整包带走"方案——整个 dist-packages 打进包, 避免在新盒 pip/编译。
#       模型服务按你的两个 systemd 服务原样还原。
#
# 用法:    sudo ./prep_offline_system.sh
# 产出:    ./emergency_offline.tar.gz
# =============================================================================
set -euo pipefail

log()  { printf '[打包] %s\n' "$*"; }
warn() { printf '[警告] %s\n' "$*"; }
die()  { printf '[错误] %s\n' "$*" >&2; exit 1; }

BASE="$(cd "$(dirname "$0")" && pwd)"
OUT="$BASE/emergency_offline"
# 产物为未压缩 tar(ARM SOC 上 gzip 压缩 11G 极慢/卡死, 故不打压缩; 目标机用 tar xpPf 解压)
PKG="$BASE/emergency_offline.tar"

# -------------------------------------------------------------------------
# 0. 可配置项（均已探测到实际默认；实施时可按需覆盖或关闭）
# -------------------------------------------------------------------------
INCLUDE_DEP="${INCLUDE_DEP:-1}"       # 打包 /usr/local/lib/python3.10/dist-packages (765M)
INCLUDE_BACKEND="${INCLUDE_BACKEND:-1}"  # /data/SafeRAG
INCLUDE_FRONT="${INCLUDE_FRONT:-1}"      # /data2/www/emergency-platform/frontend
INCLUDE_MODEL="${INCLUDE_MODEL:-1}"      # /data2/models/Qwen3_5 (bmodel + config)
INCLUDE_SVC="${INCLUDE_SVC:-1}"          # /etc/systemd/system/{qwen,qwen_chat,saferag}.service
INCLUDE_NGINX="${INCLUDE_NGINX:-1}"      # /etc/nginx (站点/反代配置; nginx 程序本体需新盒 apt 装)
INCLUDE_DATA="${INCLUDE_DATA:-1}"        # /data/SafeRAG/data (知识库/文档/账号, 运行时数据)
INCLUDE_SYSDEBS="${INCLUDE_SYSDEBS:-1}"  # 收集系统软件 .deb(nginx/python3及依赖)装进包, 目标机无需内网apt源

DIST_PKGS="/usr/local/lib/python3.10/dist-packages"
SAFERAG_DIR="/data/SafeRAG"
FRONT_DIR="/data2/www/emergency-platform/frontend"
MODEL_DIR="/data2/models/Qwen3_5"
SVC_FILES=(/etc/systemd/system/qwen.service /etc/systemd/system/qwen_chat.service /etc/systemd/system/saferag.service)

# requirements.txt（依赖清单）：打包时校验 dist-packages 是否已包含其中每一版，缺则告警。
# INCLUDE_DEP=1 时校验；若源盒无此文件或为空则自动跳过(整包 dist-packages 已是最完整形式)。
REQ_FILE="${REQ_FILE:-$SAFERAG_DIR/backend/requirements.txt}"

# 目标机需要的系统软件(依赖会随 --download-only 自动带齐); 输出到包内 /opt/sysdebs
SYSDEB_PACKAGES="nginx python3"
SYSDEB_DIR="/opt/sysdebs"     # 包内绝对位置

# 无 Docker 前端版的 nginx 站点配置(打包时覆盖包内 /etc/nginx/sites-enabled/SafeRAG)。
# 目标机 D方案: 不再依赖 18081 docker 容器, 宿主 nginx 直接托管前端静态页。
NGINX_NODOCKER_CONF="$BASE/nginx-frontend-nodocker.conf"

# -------------------------------------------------------------------------
# 1. 前置检查
# -------------------------------------------------------------------------
preflight() {
  log "==== 检查已部署盒子 ===="
  [ "$(uname -m)" = "aarch64" ] || warn "本机非 aarch64, 导出的包仅适用于 aarch64, 请确认目标机同架构。"

  [ "$(id -u)" = "0" ] || die "请以 root 运行本脚本 (sudo ./prep_offline_system.sh)。"

  if [ "$INCLUDE_DEP" = "1" ]; then
    [ -d "$DIST_PKGS" ] || die "未找到全局依赖目录: $DIST_PKGS"
    log "  全局依赖: $DIST_PKGS ($(du -sh "$DIST_PKGS" 2>/dev/null | awk '{print $1}'))"
  fi
  if [ "$INCLUDE_BACKEND" = "1" ]; then
    [ -d "$SAFERAG_DIR" ] || die "未找到后端源码: $SAFERAG_DIR"
    # chat.so 只需 Python 可读加载(源盒为 644, 不需执行位), 故用 -f 而非 -x
    [ -f "$SAFERAG_DIR/Qwen3_5/python_demo/chat.cpython-310-aarch64-linux-gnu.so" ] \
      || die "缺少 TPU 推理扩展: $SAFERAG_DIR/Qwen3_5/python_demo/chat.cpython-310-aarch64-linux-gnu.so"
  fi
  if [ "$INCLUDE_FRONT" = "1" ]; then
    [ -f "$FRONT_DIR/index.html" ] || die "未找到前端入口: $FRONT_DIR/index.html"
  fi
  if [ "$INCLUDE_MODEL" = "1" ]; then
    [ -d "$MODEL_DIR" ] || die "未找到模型目录: $MODEL_DIR"
    ls "$MODEL_DIR"/*.bmodel >/dev/null 2>&1 || die "模型目录下无 .bmodel: $MODEL_DIR"
    [ -d "$MODEL_DIR/config" ] || die "模型目录缺少 config: $MODEL_DIR/config"
  fi
  if [ "$INCLUDE_SVC" = "1" ]; then
    local s
    for s in "${SVC_FILES[@]}"; do [ -f "$s" ] || die "未找到自启单元: $s"; done
  fi
  if [ "$INCLUDE_NGINX" = "1" ]; then
    [ -d /etc/nginx ] || die "未找到 nginx 配置目录: /etc/nginx"
    [ -f /etc/nginx/sites-enabled/SafeRAG ] || warn "未找到反代配置 /etc/nginx/sites-enabled/SafeRAG (前端/模型入口可能不完整)"
  fi
  log "预检通过 ✅"
}

# 校验 requirements.txt 中的依赖在 dist-packages 中是否已具备；缺则告警(不阻断)
verify_requirements() {
  if [ "$INCLUDE_DEP" != "1" ]; then return 0; fi
  [ -f "$REQ_FILE" ] || { log "[依赖校验] 未找到 requirements.txt($REQ_FILE), 跳过(整包 dist-packages 已含全部依赖)"; return 0; }
  log "[依赖校验] 对照 $(basename "$REQ_FILE") 核查 dist-packages..."
  # 一次性建立现有包名索引: 取 *.dist-info/*.egg-info 的"纯包名"(去掉版本号), 小写并归一化 _/-
  local idx; idx="$(mktemp)"
  ls -1 "$DIST_PKGS" 2>/dev/null | sed -n 's/^\(.*\)\.\(dist-info\|egg-info\)$/\1/p' \
    | sed -E 's/-[0-9][0-9.v]*$//' | tr 'A-Z' 'a-z' | tr '_-' '__' | sort -u > "$idx"
  local missing=0 line name key
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    case "$line" in \#*) continue ;; esac
    name="${line%%==*}"; name="${name%%>=*}"; name="${name%%\[*}"  # 去extra/版本
    key="$(printf '%s' "$name" | tr 'A-Z' 'a-z' | tr '_-' '__')"   # 统一小写、_ 与 - 归一
    if ! grep -qx "$key" "$idx"; then
      echo "  [缺] $line"
      missing=$((missing+1))
    fi
  done < "$REQ_FILE"
  rm -f "$idx"
  if [ "$missing" -eq 0 ]; then
    log "[依赖校验] 全部依赖均已在 dist-packages ✅"
  else
    warn "[依赖校验] dist-packages 缺少 $missing 个条目(见上)。dist-packages 仍整包带走, 目标盒若报缺对应模块需另补。"
  fi
}

# 把指定绝对路径镜像到临时装配目录($OUT + 真实绝对路径)
mirror() {
  local abs="$1"
  local dst="$OUT$abs"
  mkdir -p "$(dirname "$dst")"
  cp -r "$abs" "$dst"
}

# 收集目标机系统软件 .deb 及其依赖(用 --download-only, 自动带齐依赖, 无需手算)
collect_sysdebs() {
  if [ "$INCLUDE_SYSDEBS" != "1" ]; then log "已跳过系统软件 deb 收集(INCLUDE_SYSDEBS=0), 目标盒若自带 nginx/python3 可忽略"; return 0; fi
  log "==== (可选)收集系统软件 .deb: $SYSDEB_PACKAGES ===="
  # apt 联网超限 30s, 失败即跳过(源盒常无网)。目标盒若已自带 nginx/python3, 本项非必需。
  timeout 30 apt-get update >/dev/null 2>&1 || { warn "本机无可用 apt 源/超时, 跳过系统软件收集(INCLUDE_SYSDEBS=0 可关闭)。如目标盒自带 nginx/python3 可忽略。"; return 0; }
  if timeout 30 apt-get -y --download-only --reinstall install $SYSDEB_PACKAGES >/dev/null 2>&1; then
    mkdir -p "$OUT$SYSDEB_DIR"
    cp /var/cache/apt/archives/*.deb "$OUT$SYSDEB_DIR/" 2>/dev/null
    local n; n="$(ls "$OUT$SYSDEB_DIR"/*.deb 2>/dev/null | wc -l)"
    if [ "$n" -gt 0 ]; then
      log "  已收集系统软件 deb $n 个 → $SYSDEB_DIR/"
      # 目标机一键安装脚本
      cat > "$OUT$SYSDEB_DIR/install.sh" <<'EOF'
#!/usr/bin/env bash
set -e
cd "$(dirname "$0")"
echo "本地安装系统软件(不依赖网络/apt源)..."
dpkg -i *.deb 2>/dev/null || true
# 修复依赖缺口
if command -v apt-get >/dev/null 2>&1; then apt-get -f install -y; fi
EOF
      chmod +x "$OUT$SYSDEB_DIR/install.sh"
    else
      warn "  未收集到 .deb(本机已有同类已装包或架构不匹配), 目标盒可能仍需自备。"
    fi
  else
    warn "apt --download-only 失败(stiimes为源盒无网), 系统软件 deb 未收集。可用 INCLUDE_SYSDEBS=0 关闭。"
  fi
}

collect() {
  log "==== 装配安装包(镜像绝对路径) ===="
  rm -rf "$OUT"; mkdir -p "$OUT"

  [ "$INCLUDE_DEP" = "1" ]     && mirror "$DIST_PKGS" 
  if [ "$INCLUDE_BACKEND" = "1" ]; then
    mirror "$SAFERAG_DIR"
    if [ "$INCLUDE_DATA" != "1" ]; then
      rm -rf "$OUT$SAFERAG_DIR/data"
      log "  已排除运行时数据: $SAFERAG_DIR/data"
    fi
  fi
  [ "$INCLUDE_FRONT" = "1" ]   && mirror "$FRONT_DIR"
  [ "$INCLUDE_MODEL" = "1" ]   && mirror "$MODEL_DIR"

  if [ "$INCLUDE_SVC" = "1" ]; then
    mkdir -p "$OUT/etc/systemd/system"
    local s
    for s in "${SVC_FILES[@]}"; do cp "$s" "$OUT/etc/systemd/system/"; done
  fi
  [ "$INCLUDE_NGINX" = "1" ] && mirror "/etc/nginx"

  # B方案(Docker 前端): 用"无 Docker 前端"配置覆盖包内站点, 目标机即不依赖 18081 容器
  if [ "$INCLUDE_NGINX" = "1" ] && [ "$INCLUDE_FRONT" = "1" ]; then
    local dst="$OUT/etc/nginx/sites-enabled/SafeRAG"
    if [ -f "$NGINX_NODOCKER_CONF" ]; then
      cp "$NGINX_NODOCKER_CONF" "$dst"
      log "已写入无 Docker 前端版站点配置: $dst (前端由宿主 nginx 静态托管)"
    else
      warn "未找到 $NGINX_NODOCKER_CONF, 保留源盒 docker 反代配置(目标机将依赖 18081 容器)"
    fi
  fi

  # 部署说明
  mkdir -p "$OUT/root"
  write_readme > "$OUT/root/README_INSTALL.txt"
  log "装配完成"
}

write_readme() {
  cat <<EOF
应急安全综合平台 —— 离线迁移安装包（系统全局 Python 版）
==========================================================
来源: 已部署的 aarch64 盒子（Sophgo BM1688）。
目标: 另一台【同架构 aarch64】盒子, 系统为 Ubuntu/Debian 且已装 python3.10。

本包内目录均带【绝对路径】。以 root 解压到根即可还原到与源盒子一致的位置。
依赖已整包带走(/usr/local/lib/python3.10/dist-packages), 无需 pip / 网络 / gcc。

--- 1) 安装系统软件(nginx/python3 解释器) ---
  【离线情形】本包已附带系统软件 deb 于 /opt/sysdebs (INCLUDE_SYSDEBS=1 时):
    解压后执行(无需内网 apt 源):
      cd /opt/sysdebs && chmod +x install.sh && sudo ./install.sh
  【有 apt 源情形】亦可直接:
    apt install -y python3 python3.10 python3-venv nginx
  # 注意: 源盒子依赖是全局 python3.10, 不再需要 gcc(不现场编译)

--- 2) 以 root 解压到根(务必 -P 保留绝对路径; 本包为未压缩 tar, 用 xpPf 而不带 z) ---
  sudo tar xpPf emergency_offline.tar -C /

--- 3) 校验关键路径 ---
  ls -l /usr/local/lib/python3.10/dist-packages | head
  ls -l /data/SafeRAG/Qwen3_5/python_demo/chat.cpython-310-aarch64-linux-gnu.so
  ls -d /data2/models/Qwen3_5/config

--- 4) 启动后端/模型自启 ---
  systemctl daemon-reload
  systemctl enable --now qwen.service qwen_chat.service saferag.service

--- 5) 配置并启动 nginx(宿主 nginx 统一入口; 目标机不需要 Docker/18081) ---
  本包已把 /etc/nginx/sites-enabled/SafeRAG 换成"无 Docker 前端版":
    - 前端页面: 由宿主 nginx 直接静态托管 /data2/www/emergency-platform/frontend
    - /api -> 8081, /v1 -> 8000(SSE), /docs -> 8081
  执行:
    systemctl enable --now nginx
    nginx -t && systemctl restart nginx   # 配置校验通过后重启套用

--- 6) 验证 ---
  curl -s http://127.0.0.1:8000/health                      # qwen(4B)
  curl -s http://127.0.0.1:8001/health                      # qwen_chat(2B)
  curl -s http://127.0.0.1:8081/                            # 后端 "SafeRAG API"
  curl -s -o /dev/null -w "%{http_code}\n" "http://127.0.0.1/"   # 前端(预期 200)
  curl -s -o /dev/null -w "%{http_code}\n" "http://127.0.0.1/login.html"  # (预期 200)

--- 说明 ---
- 前端拓扑(B方案): 目标机不再使用 docker 前端容器(18081)。
  宿主 nginx(80) 直接静态托管 /data2/www/emergency-platform/frontend,
  并把 /api /v1 /docs 反代到后端/模型 —— 目标机无需安装 docker。
- 模型 ID: 后端 saferag.service 已用 Environment 指定 QWEN_DOC_MODEL=tpu-qwen3.5-4B /
  QWEN_CHAT_MODEL=tpu-qwen3.5-2B, 服务自启后无需再配。
- 若 INCLUDE_DATA=0(未含运行数据), 后端首次启动会重建空库, 知识库/文档需另行拷入。
EOF
}

make_tar() {
  log "==== 打包(成员带绝对路径, 未压缩 tar) ===="
  # 不压缩: ARM SOC 上 gzip 压缩 11G 极慢甚至卡死, 故直接打未压缩 tar(快)。
  # 产物为 .tar, 目标机解压命令为: sudo tar xpPf emergency_offline.tar -C /  (无需 z)
  local tmp_tar="$BASE/emergency_offline.tar"
  rm -f "$tmp_tar" "$PKG"
  # 在装配目录的上级($BASE)把"整个装配目录"打进去, 并把前缀 emergency_offline/ 去掉,
  # 使成员即字面绝对路径(如 usr/local/..., data/..., etc/...), 解压到 / 即还原到对应绝对位置。
  tar cf "$PKG" -C "$BASE" --transform 's#^emergency_offline/##' emergency_offline
  du -sh "$PKG"
  rm -rf "$OUT"
  log "完成 ✅  交付文件: $PKG"
}

main() {
  preflight
  collect
  collect_sysdebs
  verify_requirements
  make_tar
  log "把 $PKG 拷到新 aarch64 盒子, sudo tar xpPf 到 / 后按 /root/README_INSTALL.txt 操作即可。"
}
main "$@"