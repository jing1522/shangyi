#!/usr/bin/env bash
# ============================================================
# 闪衣 · AI 实时试衣 —— 一键部署到云服务器（Ubuntu 20.04+ / Debian 11+）
#
# 不需要域名：
#   sudo bash deploy.sh
#     → 自动取本机公网 IP，申请 Let's Encrypt「IP 证书」（6 天有效，自动续）
#     → 起服务 https://<公网IP>
#
# 以后买了域名：
#   sudo bash deploy.sh tryon.example.com
#     → 换成域名证书，https://tryon.example.com
# ============================================================
set -euo pipefail

TARGET="${1:-}"                 # 域名；留空则用公网 IP
APP_DIR=/opt/shanyi
APP_USER=shanyi
NODE_MAJOR=22

log()  { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
ok()   { printf '\033[1;32m    %s\033[0m\n' "$*"; }
die()  { printf '\n\033[1;31m[失败] %s\033[0m\n' "$*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "请用 sudo 运行：sudo bash deploy.sh"
[[ -f server.mjs ]] || die "请在部署包目录里运行（找不到 server.mjs）"
command -v apt-get >/dev/null || die "本脚本只支持 apt 系（Ubuntu/Debian）；CentOS/其他发行版请按文档里的 Docker 方式"
export DEBIAN_FRONTEND=noninteractive

# ---------- 1. 确定访问地址 ----------
if [[ -z "$TARGET" ]]; then
  log "获取本机公网 IP"
  for u in https://api.ip.sb/ip https://ifconfig.me/ip https://ipinfo.io/ip; do
    TARGET="$(curl -4 -fsS --max-time 8 "$u" 2>/dev/null | tr -d '[:space:]' || true)"
    [[ -n "$TARGET" ]] && break
  done
  [[ -n "$TARGET" ]] || die "取不到公网 IP，请手动指定：sudo bash deploy.sh <你的公网IP>"
  IP_MODE=1
  ok "公网 IP = $TARGET（将申请 IP 证书）"
else
  IP_MODE=0
  ok "使用域名 $TARGET"
fi

# ---------- 2. Node.js ----------
need_node=1
if command -v node >/dev/null; then
  [[ "$(node -p 'process.versions.node.split(".")[0]')" -ge 20 ]] && need_node=0
fi
if [[ $need_node -eq 1 ]]; then
  log "安装 Node.js ${NODE_MAJOR}"
  apt-get update -y
  apt-get install -y curl ca-certificates gnupg
  curl -fsSL "https://deb.nodesource.com/setup_${NODE_MAJOR}.x" | bash -
  apt-get install -y nodejs
else
  ok "已装 Node.js $(node -v)"
fi

# ---------- 3. certbot（snap 版，IP 证书要 >= 5.4）----------
if ! command -v certbot >/dev/null || ! certbot --version 2>/dev/null | grep -Eq 'certbot ([5-9]|[1-9][0-9])\.'; then
  log "安装 certbot（snap）"
  if ! command -v snap >/dev/null; then
    apt-get install -y snapd
    systemctl enable --now snapd.socket >/dev/null 2>&1 || true
    sleep 3
  fi
  snap install core >/dev/null 2>&1 || true
  snap refresh core >/dev/null 2>&1 || true
  snap install --classic certbot
  ln -sf /snap/bin/certbot /usr/bin/certbot
else
  ok "已装 $(certbot --version 2>&1)"
fi

# ---------- 4. 系统用户 + 目录 + 代码 ----------
log "部署代码到 $APP_DIR"
id -u "$APP_USER" >/dev/null 2>&1 || useradd --system --home "$APP_DIR" --shell /usr/sbin/nologin "$APP_USER"
install -d -o "$APP_USER" -g "$APP_USER" "$APP_DIR"
install -d -o "$APP_USER" -g "$APP_USER" "$APP_DIR/certs"
cp -f server.mjs package.json "$APP_DIR"/
rm -rf "$APP_DIR/src"
cp -r src "$APP_DIR"/
chown -R "$APP_USER:$APP_USER" "$APP_DIR"

# ---------- 5. API Key ----------
if [[ ! -f "$APP_DIR/.env" ]]; then
  printf 'Decart API Key（直接回车 = 不配置，由访问者在页面上自己填）: '
  read -r APIKEY
  if [[ -z "$APIKEY" ]]; then
    ok "未配置服务端 Key：访问者首次进入时填自己的（只存他的浏览器）"
  fi
  cat > "$APP_DIR/.env" <<EOF
DECART_API_KEY=$APIKEY
TLS_CERT=$APP_DIR/certs/fullchain.pem
TLS_KEY=$APP_DIR/certs/privkey.pem
PORT=443
HOST=0.0.0.0
TOKEN_TTL=300
EOF
  chmod 600 "$APP_DIR/.env"
  ok "已写入 $APP_DIR/.env"
else
  ok "沿用已有的 $APP_DIR/.env"
fi

# ---------- 6. 申请证书 ----------
log "申请 TLS 证书（$TARGET）"
systemctl stop shanyi >/dev/null 2>&1 || true   # 释放 80/443
EMAIL="${EMAIL:-}"
MAIL_ARG=(--register-unsafely-without-email)
[[ -n "$EMAIL" ]] && MAIL_ARG=(-m "$EMAIL")

CERT_FLAGS=(--standalone --non-interactive --agree-tos "${MAIL_ARG[@]}" \
            --keep-until-expiring --cert-name "$TARGET")
if [[ $IP_MODE -eq 1 ]]; then
  # IP 证书只支持 shortlived profile（6 天），必须自动续期
  CERT_FLAGS+=(--preferred-profile shortlived --ip-address "$TARGET")
else
  CERT_FLAGS+=(-d "$TARGET")
fi

if ! certbot certonly "${CERT_FLAGS[@]}"; then
  if [[ $IP_MODE -eq 1 ]]; then
    log "80 端口验证没过，改用 443（TLS-ALPN-01）重试"
    certbot certonly "${CERT_FLAGS[@]}" --preferred-challenges tls-alpn-01 || \
      die "证书申请失败：确认安全组已放行 80 和 443、该 IP 是公网 IP、且没有别的程序占着端口"
  else
    die "证书申请失败：确认域名已解析到本机、80/443 已放行"
  fi
fi

# ---------- 7. 证书拷到应用目录（应用以非 root 运行）----------
log "同步证书到 $APP_DIR/certs"
install -d -o "$APP_USER" -g "$APP_USER" "$APP_DIR/certs"
cp -f "/etc/letsencrypt/live/$TARGET/fullchain.pem" "$APP_DIR/certs/fullchain.pem"
cp -f "/etc/letsencrypt/live/$TARGET/privkey.pem"   "$APP_DIR/certs/privkey.pem"
chown "$APP_USER:$APP_USER" "$APP_DIR/certs/"*.pem
chmod 600 "$APP_DIR/certs/privkey.pem"

# ---------- 8. systemd ----------
log "安装 systemd 服务"
cat > /etc/systemd/system/shanyi.service <<'EOF'
[Unit]
Description=Shanyi AI Try-on
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=shanyi
Group=shanyi
WorkingDirectory=/opt/shanyi
EnvironmentFile=/opt/shanyi/.env
ExecStart=/usr/bin/node /opt/shanyi/server.mjs
Restart=always
RestartSec=3
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=/opt/shanyi

[Install]
WantedBy=multi-user.target
EOF

# 续期后自动更新证书并重启（域名 / IP 两种模式都要）
mkdir -p /etc/letsencrypt/renewal-hooks/deploy
cat > /etc/letsencrypt/renewal-hooks/deploy/shanyi.sh <<EOF
#!/usr/bin/env bash
set -e
cp -f /etc/letsencrypt/live/$TARGET/fullchain.pem $APP_DIR/certs/fullchain.pem
cp -f /etc/letsencrypt/live/$TARGET/privkey.pem   $APP_DIR/certs/privkey.pem
chown $APP_USER:$APP_USER $APP_DIR/certs/*.pem
chmod 600 $APP_DIR/certs/privkey.pem
systemctl restart shanyi
EOF
chmod +x /etc/letsencrypt/renewal-hooks/deploy/shanyi.sh

systemctl daemon-reload
systemctl enable --now shanyi
sleep 2

# ---------- 9. 续期演练（IP 证书只有 6 天，续期失败=几天后挂掉）----------
log "演练自动续期"
if certbot renew --dry-run --cert-name "$TARGET" >/tmp/shanyi-renew.log 2>&1; then
  ok "续期正常"
else
  printf '\033[1;33m[警告] 续期演练失败，6 天后证书会过期。日志：/tmp/shanyi-renew.log\033[0m\n'
  tail -20 /tmp/shanyi-renew.log || true
fi

# ---------- 10. 防火墙 ----------
if command -v ufw >/dev/null && ufw status 2>/dev/null | grep -q "Status: active"; then
  ufw allow 80/tcp  >/dev/null 2>&1 || true
  ufw allow 443/tcp >/dev/null 2>&1 || true
  ok "已放行 ufw 80/443"
fi

# ---------- 11. 自检 ----------
log "自检"
if curl -fsS --max-time 8 -k "https://$TARGET/api/health"; then
  printf '\n'
  ok "部署完成 → https://$TARGET"
  printf '   续期：certbot renew --dry-run   查看日志：journalctl -u shanyi -f\n'
else
  printf '\n'
  die "服务起来了但 https://$TARGET 访问不通，看：systemctl status shanyi / journalctl -u shanyi -n 50"
fi