#!/usr/bin/env bash
# package.sh —— 打包应急安全综合平台离线安装包(源盒以 root 运行)
# 用法: sudo ./package.sh    产出: ./emergency_offline.tar(未压缩, 含绝对路径, 目标机 sudo tar xpPf 解压)
set -euo pipefail

log()  { printf '[打包] %s\n' "$*"; }
warn() { printf '[警告] %s\n' "$*"; }
die()  { printf '[错误] %s\n' "$*" >&2; exit 1; }

BASE="$(cd "$(dirname "$0")" && pwd)"
OUT="$BASE/emergency_offline"
# 未压缩 tar: ARM 上 gzip 压缩 11G 极慢/卡死, 故不用 tar czf
PKG="$BASE/emergency_offline.tar"

# ---- 打包范围开关(可按需覆盖, 如 INCLUDE_DATA=0 排除运行数据) ----
INCLUDE_DEP="${INCLUDE_DEP:-1}"       # 依赖 /usr/local/lib/python3.10/dist-packages(整包带走)
INCLUDE_BACKEND="${INCLUDE_BACKEND:-1}"  # 后端 /data/SafeRAG
INCLUDE_FRONT="${INCLUDE_FRONT:-1}"   # 前端 /data2/www/emergency-platform/frontend
INCLUDE_MODEL="${INCLUDE_MODEL:-1}"   # 模型 /data2/models/Qwen3_5(bmodel+config)
INCLUDE_SVC="${INCLUDE_SVC:-1}"       # 3 个 systemd 服务
INCLUDE_NGINX="${INCLUDE_NGINX:-1}"   # nginx 配置 /etc/nginx
INCLUDE_DATA="${INCLUDE_DATA:-1}"     # 运行数据 /data/SafeRAG/data(可排除)
INCLUDE_SYSDEBS="${INCLUDE_SYSDEBS:-1}" # 系统软件 deb → 包内 /opt/sysdebs

DIST_PKGS="/usr/local/lib/python3.10/dist-packages"
SAFERAG_DIR="/data/SafeRAG"
FRONT_DIR="/data2/www/emergency-platform/frontend"
MODEL_DIR="/data2/models/Qwen3_5"
SVC_FILES=(/etc/systemd/system/qwen.service /etc/systemd/system/qwen_chat.service /etc/systemd/system/saferag.service)
SYSDEB_PACKAGES="nginx python3"
SYSDEB_DIR="/opt/sysdebs"

preflight() {
  log "==== 预检 ===="
  [ "$(uname -m)" = "aarch64" ] || warn "非 aarch64, 导出的包仅适用 aarch64 目标机"
  [ "$(id -u)" = "0" ] || die "请用 sudo 运行"

  if [ "$INCLUDE_DEP" = "1" ]; then [ -d "$DIST_PKGS" ] || die "缺依赖目录: $DIST_PKGS"; fi
  if [ "$INCLUDE_BACKEND" = "1" ]; then
    [ -d "$SAFERAG_DIR" ] || die "缺后端: $SAFERAG_DIR"
    # chat.so 只需存在(-f), 不需执行位(-x)
    [ -f "$SAFERAG_DIR/Qwen3_5/python_demo/chat.cpython-310-aarch64-linux-gnu.so" ] \
      || die "缺 TPU 扩展: chat.cpython-310-aarch64-linux-gnu.so"
  fi
  if [ "$INCLUDE_FRONT" = "1" ]; then [ -f "$FRONT_DIR/index.html" ] || die "缺前端: $FRONT_DIR"; fi
  if [ "$INCLUDE_MODEL" = "1" ]; then
    [ -d "$MODEL_DIR" ] || die "缺模型: $MODEL_DIR"
    ls "$MODEL_DIR"/*.bmodel >/dev/null 2>&1 || die "模型目录无 .bmodel"
  fi
  if [ "$INCLUDE_SVC" = "1" ]; then
    local s; for s in "${SVC_FILES[@]}"; do [ -f "$s" ] || die "缺服务单元: $s"; done
  fi
  if [ "$INCLUDE_NGINX" = "1" ] && [ ! -d /etc/nginx ]; then warn "缺 nginx 配置 /etc/nginx"; fi
  log "预检通过"
}

mirror() {  # 把 $1(绝对路径)镜像到装配目录同位置
  local abs="$1"
  local dst="$OUT$abs"
  mkdir -p "$(dirname "$dst")"
  cp -a "$abs" "$dst"
}

collect_sysdebs() {  # 收集系统软件 deb 到包内 /opt/sysdebs
  if [ "$INCLUDE_SYSDEBS" != "1" ]; then log "跳过系统软件收集(INCLUDE_SYSDEBS=0)"; return 0; fi
  log "==== 收集系统软件 deb: $SYSDEB_PACKAGES ===="
  timeout 30 apt-get update >/dev/null 2>&1 \
    || { warn "本机无 apt 源/超时, 跳过(目标机若自带 nginx/python3 可忽略)"; return 0; }
  if timeout 30 apt-get -y --download-only --reinstall install $SYSDEB_PACKAGES >/dev/null 2>&1; then
    mkdir -p "$OUT$SYSDEB_DIR"
    cp /var/cache/apt/archives/*.deb "$OUT$SYSDEB_DIR/" 2>/dev/null
    local n; n="$(ls "$OUT$SYSDEB_DIR"/*.deb 2>/dev/null | wc -l)"
    if [ "$n" -gt 0 ]; then
      log "  收集 deb $n 个 → $SYSDEB_DIR/"
      # 包内一键装系统软件脚本(防火墙由 deploy/install.sh 处理)
      cat > "$OUT$SYSDEB_DIR/install.sh" <<'EOF'
#!/usr/bin/env bash
set -e
cd "$(dirname "$0")"
dpkg -i *.deb 2>/dev/null || true
command -v apt-get >/dev/null 2>&1 && apt-get -f install -y
EOF
      chmod +x "$OUT$SYSDEB_DIR/install.sh"
    else
      warn "未收集到 deb(本机已装同类包或架构不匹配)"
    fi
  else
    warn "apt --download-only 失败(源盒常无网), deb 未收集"
  fi
}

collect() {
  log "==== 装配(镜像绝对路径) ===="
  rm -rf "$OUT"; mkdir -p "$OUT"
  if [ "$INCLUDE_DEP" = "1" ];     then mirror "$DIST_PKGS"; fi
  if [ "$INCLUDE_BACKEND" = "1" ]; then
    mirror "$SAFERAG_DIR"
    if [ "$INCLUDE_DATA" != "1" ]; then rm -rf "$OUT$SAFERAG_DIR/data"; fi
  fi
  if [ "$INCLUDE_FRONT" = "1" ];   then mirror "$FRONT_DIR"; fi
  if [ "$INCLUDE_MODEL" = "1" ];   then mirror "$MODEL_DIR"; fi
  if [ "$INCLUDE_SVC" = "1" ]; then
    mkdir -p "$OUT/etc/systemd/system"
    local s; for s in "${SVC_FILES[@]}"; do cp "$s" "$OUT/etc/systemd/system/"; done
  fi
  if [ "$INCLUDE_NGINX" = "1" ];   then mirror "/etc/nginx"; fi
  # 覆盖为"无 Docker 前端"版站点(宿主 nginx 静态托管前端并反代后端/模型, 目标机不需 18081 容器)
  if [ "$INCLUDE_NGINX" = "1" ] && [ "$INCLUDE_FRONT" = "1" ]; then
    cat > "$OUT/etc/nginx/sites-enabled/SafeRAG" <<'NN'
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name _;

    # 前端静态页面目录(与打包内容一致; 若实际路径不同请改 root)
    root /data2/www/emergency-platform/frontend;
    index index.html;

    # SafeRAG 业务 API (8081)
    location /api/ {
        proxy_pass http://127.0.0.1:8081;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_read_timeout 120s;
        proxy_send_timeout 120s;
        client_max_body_size 20m;
    }

    # Qwen3.5 大模型 API (8000) —— SSE 流式必须关缓冲
    location /v1/ {
        proxy_pass http://127.0.0.1:8000;
        proxy_http_version 1.1;
        proxy_buffering off;
        proxy_cache off;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_read_timeout 600s;
        proxy_send_timeout 600s;
    }

    location /health {
        proxy_pass http://127.0.0.1:8000/health;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
    }

    # 后端 API 文档 (8081)
    location /docs {
        proxy_pass http://127.0.0.1:8081;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    }

    location /openapi.json {
        proxy_pass http://127.0.0.1:8081/openapi.json;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    }

    # 静态资源缓存
    location ~* \.(js|css|png|jpg|jpeg|gif|ico|svg|woff2?)$ {
        expires 1d;
        add_header Cache-Control "public";
        try_files $uri =404;
    }
}
NN
    log "已写入无 Docker 前端版站点配置"
  fi
  log "装配完成"
}

make_tar() {
  log "==== 打包(未压缩 tar) ===="
  rm -f "$PKG"
  # 不打压缩(ARM 上 gzip 11G 极慢); 成员为字面绝对路径, 目标机解压后原样还原
  tar cf "$PKG" -C "$BASE" --transform 's#^emergency_offline/##' emergency_offline
  du -sh "$PKG"
  rm -rf "$OUT"
  log "完成 ✅ $PKG"
}

main() {
  preflight
  collect
  collect_sysdebs
  make_tar
  log "将 $PKG 拷贝到目标机, 解压后执行 deploy/install.sh 完成部署"
}
main "$@"