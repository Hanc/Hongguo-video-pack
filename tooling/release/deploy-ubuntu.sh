#!/usr/bin/env bash
# 红葡萄分发服务 · Ubuntu 一键部署（幂等，可重复执行）
#
#   sudo bash deploy-ubuntu.sh --domain dl.example.com
#   sudo bash deploy-ubuntu.sh --domain dl.example.com --port 8099 --keep 5 --rate 20
#   sudo bash deploy-ubuntu.sh --port 8099 --host 0.0.0.0        # 无域名：直接 IP:端口 对外（临时联调）
#
# 做的事：检查 Node → 装脚本到 /opt/hongguo → 建发布目录 → 生成/保留令牌 →
#         注册 systemd → 起服务 → 本机健康检查 → 打印后续 nginx/证书步骤。
# 不做的事：不碰 nginx 站点（宝塔或手写都行，示例见 nginx-dl.conf.example）、不申请证书。
set -euo pipefail

DOMAIN=""
PORT=8099
ROOT_DIR=/var/www/hongguo/dl
INSTALL_DIR=/opt/hongguo
ENV_FILE=/etc/hongguo.env
MAX_MB=400
KEEP=5
RATE=20
RUN_USER=www-data
HOST_BIND=127.0.0.1
SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

while [ $# -gt 0 ]; do
  case "$1" in
    --domain) DOMAIN="$2"; shift 2 ;;
    --port) PORT="$2"; shift 2 ;;
    --host) HOST_BIND="$2"; shift 2 ;;
    --root) ROOT_DIR="$2"; shift 2 ;;
    --max-mb) MAX_MB="$2"; shift 2 ;;
    --keep) KEEP="$2"; shift 2 ;;
    --rate) RATE="$2"; shift 2 ;;
    --user) RUN_USER="$2"; shift 2 ;;
    -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
    *) echo "未知参数：$1" >&2; exit 2 ;;
  esac
done

if [ "$(id -u)" -ne 0 ]; then
  echo "请用 root 运行（sudo bash $0 ...）" >&2
  exit 1
fi

if ! command -v node >/dev/null 2>&1; then
  echo "缺少 Node：apt-get install -y nodejs（要求 18+）" >&2
  exit 1
fi
NODE_VERSION="$(node -v)"
NODE_MAJOR="$(printf '%s' "$NODE_VERSION" | sed 's/^v\([0-9]*\).*/\1/')"
if [ "$NODE_MAJOR" -lt 18 ]; then
  echo "Node 版本过低：$NODE_VERSION（需要 18+）" >&2
  exit 1
fi

echo "[1/6] 安装脚本 → $INSTALL_DIR"
install -d -m 755 "$INSTALL_DIR"
install -m 755 "$SRC_DIR/dl-server.mjs" "$INSTALL_DIR/dl-server.mjs"

echo "[2/6] 发布目录 → $ROOT_DIR"
install -d -m 755 "$ROOT_DIR"
if id "$RUN_USER" >/dev/null 2>&1; then
  chown -R "$RUN_USER":"$RUN_USER" "$ROOT_DIR"
else
  echo "  未找到用户 $RUN_USER，改用 root 运行（可用 --user 指定）"
  RUN_USER=root
fi

echo "[3/6] 令牌 → $ENV_FILE"
if [ -f "$ENV_FILE" ] && grep -q '^DL_TOKEN=' "$ENV_FILE"; then
  echo "  已存在，保留原令牌（轮换见 UPGRADE-NOTES.md）"
else
  TOKEN="$(head -c 32 /dev/urandom | base64 | tr -d '/+=' | head -c 40)"
  umask 077
  printf 'DL_TOKEN=%s\n' "$TOKEN" > "$ENV_FILE"
  chmod 600 "$ENV_FILE"
  echo "  已生成新令牌，写入 $ENV_FILE（600）"
fi

echo "[4/6] systemd 单元"
cat > /etc/systemd/system/hongguo-dl.service <<EOF
[Unit]
Description=Hongputao artifact server
After=network.target

[Service]
EnvironmentFile=$ENV_FILE
ExecStart=$(command -v node) $INSTALL_DIR/dl-server.mjs --root $ROOT_DIR --port $PORT --host $HOST_BIND --max-mb $MAX_MB --keep $KEEP --rate $RATE
Restart=always
RestartSec=3
User=$RUN_USER
Group=$RUN_USER
NoNewPrivileges=yes
PrivateTmp=yes
ProtectSystem=strict
ReadWritePaths=$ROOT_DIR

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload

echo "[5/6] 启动并设开机自启"
systemctl enable hongguo-dl >/dev/null
systemctl restart hongguo-dl

echo "[6/6] 本机健康检查"
sleep 1
HEALTH="$(curl -sS -m 5 "http://127.0.0.1:$PORT/health" || true)"
case "$HEALTH" in
  *'"ok":true'*)
    echo "  通过：$HEALTH"
    ;;
  *)
    echo "  失败：$HEALTH" >&2
    echo "  查日志：journalctl -u hongguo-dl -n 50 --no-pager" >&2
    exit 1
    ;;
esac

TOKEN="$(grep '^DL_TOKEN=' "$ENV_FILE" | cut -d= -f2-)"
cat <<EOF

部署完成。服务监听 $HOST_BIND:$PORT。

下一步：
1) 对外访问：
   - 有域名（推荐）：nginx 站点（示例见 nginx-dl.conf.example），两处必须调：
       client_max_body_size 500m;
       proxy_request_buffering off;
     证书：certbot --nginx -d ${DOMAIN:-<你的域名>}
   - 无域名（临时）：已在 $HOST_BIND 上直接对外，确认放行端口：
       ufw allow $PORT/tcp   # 云控制台的安全组也要放行 $PORT/tcp
     ip addr | grep 'inet '  # 确认公网 IP 属于本机
2) 发布脚本/命令用这个令牌（只放进发布机的环境变量，别进仓库）：

   export HONGGUO_SERVER_BASE='http://$(hostname -I 2>/dev/null | awk '{print $1}'):$PORT'
   export HONGGUO_UPLOAD_TOKEN='$TOKEN'

3) 自检：bash selfcheck.sh http://127.0.0.1:$PORT <安装包文件名>
   （临时用 http 时加 SELFCHECK_LOCAL=1 豁免"必须 https"这一项）
4) 轮换令牌：改 $ENV_FILE → systemctl restart hongguo-dl → 更新发布机环境变量
5) 查日志：journalctl -u hongguo-dl -n 50 --no-pager
EOF
