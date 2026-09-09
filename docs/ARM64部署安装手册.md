# 应急安全综合平台 —— ARM64 (aarch64) 安装部署操作手册

> 版本：v2.0　　适用环境：Sophgo BM1688 ARM 盒子（Debian/Ubuntu，aarch64）
> 部署方式：**离线整包迁移**——从一台已稳定运行的盒子导出，原样还原到同架构新盒子
> 配套脚本：`deploy/prep_offline_system.sh`（源盒打包）、`deploy/nginx-frontend-nodocker.conf`（B 方案 nginx 配置）

---

## 1. 架构总览

| 组件 | 技术栈 | 进程（systemd 单元） | 端口 | 说明 |
|------|--------|----------------------|------|------|
| 模型服务 | Qwen3.5 | `server.py`（`qwen.service`，4B） | **8000** | TPU 推理，`/usr/bin/python3 server.py` |
| 模型服务 | Qwen3.5 | `server.py`（`qwen_chat.service`，2B） | **8001** | TPU 推理，多模态 |
| 后端 | SafeRAG FastAPI + SQLite + ChromaDB | `uvicorn`（`saferag.service`） | **8081** | `uvicorn backend.main:app` |
| 前端 | nginx 静态托管 + 反向代理 | `nginx`（宿主，80） | **80** | 直接托 `/data2/www/emergency-platform/frontend` |

```
浏览器 ──> 宿主 nginx:80 (静态页面 /data2/www/.../frontend)
               │
               ├── /api/*  ──> FastAPI:8081 (后端)
               ├── /v1/*   ──> Qwen:8000 (模型, SSE 流式)
               └── /docs   ──> FastAPI:8081
```

**关键点（与 v1 差异）**：
- 前端**不再使用 Docker 容器（18081）**，改由宿主 nginx 在 80 端口直接静态托管 + 反代。
- 依赖为**系统全局 python3.10**（`/usr/local/lib/python3.10/dist-packages`），**无 venv、无 conda**。
- 数据库为 SQLite，**无需 MySQL / Docker**。

---

## 2. 部署方式概述

本方案的核心思路是**「把已部署盒子的整个环境原样打包，迁移到同架构新盒子」**，而不是在新盒子重新下载/编译依赖。

| 步骤 | 在哪执行 | 做什么 |
|------|---------|--------|
| ① 导出安装包 | **源盒**（已部署的盒子） | 运行 `prep_offline_system.sh` → 产出 `emergency_offline.tar.gz` |
| ② 传输 | 任意离线方式 | U 盘等把包拷到目标盒 |
| ③ 部署 | **目标盒**（新 aarch64） | 解压 → 本地装系统软件 → 起服务 → 起 nginx → 验证 |

> 前提：**源盒目标盒为同架构 aarch64、同 Ubuntu/Debian 大版本、python3.10**（多为同款 Sophgo 盒子，天然满足）。
> 目标盒**无需**网络、内网 apt 源、pip、gcc、Docker。

---

## 3. 源盒：导出离线安装包

### 3.1 准备脚本

把 `deploy/` 下这两个文件放到源盒**同一目录**（如 `/root/deploy/`）：

```
prep_offline_system.sh
nginx-frontend-nodocker.conf
```

> 两者必须同目录：脚本按自身路径查找 `nginx-frontend-nodocker.conf`（见 `NGINX_NODOCKER_CONF`）。缺它则退化为保留源盒 docker 反代，目标机将仍依赖 18081 容器。

### 3.2 打包内容（默认全包含）

| 绝对路径（源盒） | 内容 |
|------------------|------|
| `/usr/local/lib/python3.10/dist-packages` | 全部 Python 依赖（整包带走，免 pip/编译） |
| `/data/SafeRAG` | 后端 + 模型源码 + `chat.so` +（可选）运行时数据 |
| `/data2/www/emergency-platform/frontend` | 前端静态页面 |
| `/data2/models/Qwen3_5` | 两个 bmodel + config |
| `/etc/systemd/system/{qwen,qwen_chat,saferag}.service` | 三个自启单元 |
| `/etc/nginx` | nginx 配置（站点用 B 方案覆盖） |
| `/opt/sysdebs` | nginx/python3 及依赖的 `.deb` + `install.sh`（目标机离线装系统软件） |

启动依赖的开关（默认全 `1`，用环境变量覆盖，例如 `INCLUDE_DATA=0 sudo ...`）：

| 开关 | 含义 |
|------|------|
| `INCLUDE_DEP` | 打包 dist-packages（依赖） |
| `INCLUDE_BACKEND` | 后端源码 |
| `INCLUDE_FRONT` | 前端页面 |
| `INCLUDE_MODEL` | 模型 bmodel + config |
| `INCLUDE_SVC` | 三个 systemd 服务 |
| `INCLUDE_NGINX` | nginx 配置 |
| `INCLUDE_DATA` | 后端运行时数据（默认带；`0` 则新盒重建空库） |
| `INCLUDE_SYSDEBS` | 收集系统软件 .deb |

### 3.3 运行

```bash
cd /root/deploy
chmod +x prep_offline_system.sh
sudo ./prep_offline_system.sh
```

**预期输出**：
1. `预检通过 ✅`
2. `装配安装包(镜像绝对路径)` → 逐项 `已收集/已写入` 日志
3. `[依赖校验] 对照 requirements.txt 核查 dist-packages` → `全部依赖均已在 dist-packages ✅`（或黄字告警缺某项）
4. `收集系统软件 .deb: nginx python3` → `已收集系统软件 deb N 个 → /opt/sysdebs/`
5. `完成 ✅ 交付文件: /root/deploy/emergency_offline.tar.gz`

**输出文件**：`emergency_offline.tar.gz`（含包内部署说明 `/root/README_INSTALL.txt`，目标盒解压后可直接查看）。

---

## 4. 传输到目标盒

完全隔离环境，用 U 盘即可：

```bash
# 源盒
lsblk
mkdir -p /mnt/usb && mount /dev/sda1 /mnt/usb
cp /root/deploy/emergency_offline.tar.gz /mnt/usb/
sync && umount /mnt/usb
```

---

## 5. 目标盒：部署

### 5.1 解压到根（**必须 `-P` 保留绝对路径**）

```bash
mkdir -p /mnt/usb && mount /dev/sda1 /mnt/usb
sudo tar xzpPf /mnt/usb/emergency_offline.tar.gz -C /
sync && umount /mnt/usb
```

**校验关键路径到位**：
```bash
ls -l /usr/local/lib/python3.10/dist-packages | head
ls -l /data/SafeRAG/Qwen3_5/python_demo/chat.cpython-310-aarch64-linux-gnu.so
ls -d /data2/models/Qwen3_5/config
```

### 5.2 安装系统软件（离线，不需内网 apt 源）

```bash
cd /opt/sysdebs && chmod +x install.sh && sudo ./install.sh
```
> install.sh 用包内已带的 `.deb` 本地 `dpkg` 安装并 `apt-get -f install -y` 补依赖，全程不联网。
> 若你有内网 apt 源，也可直接 `apt install -y python3 python3.10 python3-venv nginx`。

### 5.3 启动后端 + 两个模型服务

```bash
systemctl daemon-reload
systemctl enable --now qwen.service qwen_chat.service saferag.service
```

### 5.4 启动 nginx（B 方案配置已就位）

```bash
systemctl enable --now nginx
nginx -t && systemctl restart nginx
```

> 包内 `/etc/nginx/sites-enabled/SafeRAG` 已替换为「无 Docker 前端版」：宿主 nginx 直接静态托管前端，`/api /v1 /docs` 反代到后端/模型（`proxy_buffering off` 已配，SSE 流式正常）。

### 5.5 验证

```bash
# 端口在监听
ss -tlnp | grep -E ':8000|:8001|:8081|:80 '

# 模型 / 后端 / 前端
curl -s http://127.0.0.1:8000/health            # {"status":"ok","busy":false}
curl -s http://127.0.0.1:8001/health            # qwen_chat(2B)
curl -s http://127.0.0.1:8081/                  # {"service":"SafeRAG API",...}
curl -s -o /dev/null -w "%{http_code}\n" http://127.0.0.1/login.html   # 200
curl -s -o /dev/null -w "%{http_code}\n" http://127.0.0.1/api/v1/auth/me   # 401(反代通)
```

### 5.6 浏览器验收

访问 `http://<目标盒IP>/login.html`，用 `sysadmin` 登录，进业务台并发一句 AI 对话。

---

## 6. 端到端联调验证

```bash
# 三个 systemd 服务活跃
systemctl is-active qwen qwen_chat saferag nginx

# 模型 → 后端 → 前端 全链路（带 token 访问健康检查）
TOKEN=$(curl -s -X POST http://127.0.0.1:8081/api/v1/auth/login \
  -H "Content-Type: application/json" \
  -d '{"username":"sysadmin","password":"<sysadmin密码>"}' | python3 -c 'import sys,json;print(json.load(sys.stdin)["access_token"])')
curl -s http://127.0.0.1/api/v1/health -H "Authorization: Bearer $TOKEN"
# 预期 qwen=true qwen_chat=true chroma=true status=ok
```

**页面验收清单**
- [ ] 登录页可打开，`sysadmin`/`secadmin`/`audadmin` 可登录
- [ ] 业务台首页正常渲染，菜单可展开/收起无闪烁
- [ ] 知识库分类标签（全部/国家法律/行政法规/地方法规/暂定）可切换并即时刷新
- [ ] 知识库可上传（必选分类）、敏感标记（secadmin）、删除
- [ ] 用户管理（sysadmin）可查用户
- [ ] AI 对话开启 RAG 时可得到带**参考检索材料**的答案（验证模型+检索链路）
- [ ] 敏感操作越权时出现权限提示（验证三权分立权限控制）

---

## 7. 常用运维操作

| 操作 | 命令 |
|------|------|
| 模型(4B)状态/日志 | `systemctl status qwen` / `journalctl -u qwen -f` |
| 模型(2B)状态/日志 | `systemctl status qwen_chat` / `journalctl -u qwen_chat -f` |
| 后端状态/日志 | `systemctl status saferag` / `journalctl -u saferag -f` |
| 重启模型 | `systemctl restart qwen qwen_chat`（加载模型需几分钟） |
| 重启后端 | `systemctl restart saferag` |
| 改前端 nginx 配置后 | `nginx -t && nginx -s reload` |
| 查看端口 | `ss -tlnp \| grep -E '8000\|8001\|8081\|:80 '` |
| 备份数据 | 备份 `/data/SafeRAG/data`（`saferag.db` + `kb/` + `kb_source/` + `documents/`） |

---

## 8. 安全建议

- `saferag.service` 的 `Environment=...` 中已指定模型 ID（`QWEN_DOC_MODEL=tpu-qwen3.5-4B`、`QWEN_CHAT_MODEL=tpu-qwen3.5-2B`），无需额外配置。
- 后端 `.env` 中 `JWT_SECRET` 及三个种子账号密码：迁移方案沿用了源盒数据；若需重置，在源盒 `.env`/数据库改过再导出，或新盒在建空库（`INCLUDE_DATA=0`）时用后端首次启动逻辑生成。
- 前端 80、后端 8081 均**仅建议内网访问**；如需外网，在 nginx 层加 TLS 与访问控制。
- `.env` 权限 600，禁止提交到仓库。

---

## 9. 故障排查

| 现象 | 排查命令 / 方向 |
|------|----------------|
| 健康检查 `qwen=qwen_chat=false` | 模型服务未起：`curl -s 127.0.0.1:8000/health`；日志 `journalctl -u qwen -f` |
| 健康检查 `chroma=false` | 检查 `/data/SafeRAG/data/kb` 是否可写、权限正确 |
| 前端 `502 Bad Gateway` | 后端 8081 未起：`systemctl status saferag` |
| 上传大文件失败 | nginx `client_max_body_size`（B 方案配置已设较大值） |
| AI 对话无流式输出 | 确认 nginx 已 `proxy_buffering off`；查后端日志 |
| 首次启动慢 | BM25 预热与模型加载均耗时，属正常；`journalctl -f` 观察 |
| `Cannot import chat` | `chat.cpython-310-aarch64-linux-gnu.so` 缺失或 Python 版本非 3.10 |
| 目标盒 `install.sh` 卡在依赖 | 包内 `.deb` 有缺口，`apt-get` 尝试联网失败；从源盒补拷对应 `.deb` 再跑 |
| nginx 报 duplicate default server | `sites-enabled/` 下存在多份 `listen 80 default_server`；备份移出 `sites-enabled/` |

---

## 10. 附：部署脚本清单

| 文件 | 作用 | 状态 |
|------|------|------|
| `deploy/prep_offline_system.sh` | **源盒导出安装包（当前方案）** | ✅ 使用 |
| `deploy/nginx-frontend-nodocker.conf` | B 方案 nginx 站点配置（目标机免 Docker） | ✅ 配合使用 |
| `prep_offline.sh` / `deploy_model.sh` / `deploy_frontend_backend.sh` | 旧 venv 方案脚本 | ❌ 已废弃/删除 |

> 部署顺序：**先在源盒导出包，再到目标盒解压 → 装系统软件 → 起服务 → 起 nginx → 验证**。
> 目标盒全程**无需**网络、内网 apt 源、pip、gcc、Docker。