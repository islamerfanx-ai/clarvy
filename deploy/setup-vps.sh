#!/usr/bin/env bash
# One-time setup for dxrooms.com on a plain Ubuntu/Debian VPS (203.161.38.34 since 2026-11-05). Run as root:
#   bash setup-vps.sh
# Installs Node 22, nginx and certbot; creates the clarvy user and service (names kept so the GitHub deploy
# key and workflow work unchanged); nginx serves HTTPS and sends www and plain HTTP to https://dxrooms.com;
# the app listens on 127.0.0.1 only; the firewall lets in SSH, HTTP and HTTPS. DNS must already point here.
# Secrets go in /etc/clarvy.env (root only); copy them from the old server, never retype them.
set -euo pipefail

DOMAIN=dxrooms.com
APP_DIR=/opt/clarvy
ACME=/var/www/acme
DEPLOY_KEY='ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAILvi3GFIUY9Pe/naAJPNPFdFeEBdDSVBjK7QYo4oLjpN clarvy-github-deploy'

export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y curl ca-certificates rsync nginx certbot ufw
if ! command -v node >/dev/null || [ "$(node -p 'process.versions.node.split(".")[0]')" -lt 22 ]; then
  curl -fsSL https://deb.nodesource.com/setup_22.x | bash -
  apt-get install -y nodejs
fi

# App user: owns the code, can restart only its own service
id clarvy >/dev/null 2>&1 || useradd --create-home --shell /bin/bash clarvy
install -d -o clarvy -g clarvy "$APP_DIR"
install -d -m 700 -o clarvy -g clarvy /home/clarvy/.ssh
grep -qF "$DEPLOY_KEY" /home/clarvy/.ssh/authorized_keys 2>/dev/null || echo "$DEPLOY_KEY" >> /home/clarvy/.ssh/authorized_keys
chown clarvy:clarvy /home/clarvy/.ssh/authorized_keys && chmod 600 /home/clarvy/.ssh/authorized_keys
echo "clarvy ALL=(root) NOPASSWD: /usr/bin/systemctl restart clarvy, /bin/systemctl restart clarvy" > /etc/sudoers.d/clarvy
chmod 440 /etc/sudoers.d/clarvy

# Secrets live here, readable by root only (systemd loads them for the app)
[ -f /etc/clarvy.env ] || printf 'PORT=3000\nHOST=127.0.0.1\nPUBLIC_URL=https://%s\n' "$DOMAIN" > /etc/clarvy.env
chmod 600 /etc/clarvy.env

cat > /etc/systemd/system/clarvy.service <<EOF
[Unit]
Description=Clarvy
After=network.target

[Service]
User=clarvy
WorkingDirectory=$APP_DIR
EnvironmentFile=/etc/clarvy.env
ExecStart=/usr/bin/node server.js
Restart=always
RestartSec=2
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable clarvy

# Firewall: SSH, HTTP and HTTPS only (the app's port 3000 stays closed)
ufw allow OpenSSH
ufw allow 'Nginx Full'
ufw --force enable

# nginx, step 1: HTTP only, so Let's Encrypt can check both names
SITE=/etc/nginx/sites-available/dxrooms
install -d "$ACME"
rm -f /etc/nginx/sites-enabled/default
http_block() {
  cat <<EOF
# dxrooms.com (written by deploy/setup-vps.sh)
server {
  listen 80;
  server_name $DOMAIN www.$DOMAIN;
  location ^~ /.well-known/acme-challenge/ { root $ACME; }
  location / { return 301 https://$DOMAIN\$request_uri; }
}
EOF
}
http_block > "$SITE"
ln -sf "$SITE" /etc/nginx/sites-enabled/dxrooms
nginx -t && systemctl reload nginx

# Step 2: one certificate for both names; renewals (certbot's timer) reload nginx
certbot certonly --webroot -w "$ACME" -d "$DOMAIN" -d "www.$DOMAIN" --non-interactive --agree-tos --register-unsafely-without-email \
  --deploy-hook "systemctl reload nginx"

# Step 3: HTTPS; www goes to the bare domain, everything else to the app
CERT=/etc/letsencrypt/live/$DOMAIN
{ http_block; cat <<EOF

server {
  listen 443 ssl http2;
  server_name www.$DOMAIN;
  ssl_certificate $CERT/fullchain.pem;
  ssl_certificate_key $CERT/privkey.pem;
  return 301 https://$DOMAIN\$request_uri;
}

server {
  listen 443 ssl http2;
  server_name $DOMAIN;
  ssl_certificate $CERT/fullchain.pem;
  ssl_certificate_key $CERT/privkey.pem;
  ssl_protocols TLSv1.2 TLSv1.3;
  client_max_body_size 10m;
  gzip on;
  gzip_types text/css text/javascript application/javascript application/json application/manifest+json image/svg+xml;

  location / {
    proxy_pass http://127.0.0.1:3000;
    proxy_http_version 1.1;
    proxy_set_header Host \$host;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$remote_addr;
    proxy_set_header X-Forwarded-Proto https;
    proxy_read_timeout 300s;
  }
}
EOF
} > "$SITE"
nginx -t && systemctl reload nginx

echo
echo "Done. Copy /etc/clarvy.env and /home/clarvy/.clarvy-vapid.json from the old server, deploy the app to $APP_DIR, then: systemctl restart clarvy"
