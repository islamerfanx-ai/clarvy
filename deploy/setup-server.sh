#!/usr/bin/env bash
# One-time setup for clarvy.tejarra.com on a fresh Ubuntu/Debian server. Run as root:
#   bash setup-server.sh you@example.com
# Installs Node, nginx and certbot, creates the clarvy user and service, and lets
# GitHub Actions deploy with the clarvy-github-deploy key.
set -euo pipefail

DOMAIN=clarvy.tejarra.com
APP_DIR=/opt/clarvy
EMAIL="${1:?usage: bash setup-server.sh you@example.com (for Let's Encrypt notices)}"
DEPLOY_KEY='ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAILvi3GFIUY9Pe/naAJPNPFdFeEBdDSVBjK7QYo4oLjpN clarvy-github-deploy'

export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y curl ca-certificates rsync nginx certbot python3-certbot-nginx
if ! command -v node >/dev/null || [ "$(node -p 'process.versions.node.split(".")[0]')" -lt 20 ]; then
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
if [ ! -f /etc/clarvy.env ]; then
  printf 'OPENAI_API_KEY=\nACCESS_CODE=\nOPENAI_MODEL=gpt-5.5\nRATE_LIMIT_PER_10_MIN=80\nPORT=3000\n' > /etc/clarvy.env
fi
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

cat > /etc/nginx/sites-available/clarvy <<'EOF'
server {
  listen 80;
  server_name clarvy.tejarra.com;
  client_max_body_size 10m;

  location / {
    proxy_pass http://127.0.0.1:3000;
    proxy_http_version 1.1;
    proxy_set_header Host $host;
    # Overwrite (not append) so visitors can't spoof their IP past the rate limit
    proxy_set_header X-Forwarded-For $remote_addr;
    proxy_set_header X-Forwarded-Proto $scheme;
    proxy_read_timeout 300s;
  }
}
EOF
ln -sf /etc/nginx/sites-available/clarvy /etc/nginx/sites-enabled/clarvy
nginx -t && systemctl reload nginx

if command -v ufw >/dev/null && ufw status | grep -q active; then ufw allow 'Nginx Full'; fi
certbot --nginx -d "$DOMAIN" --non-interactive --agree-tos -m "$EMAIL" --redirect

echo
echo "Done. Next: put your OpenAI key in /etc/clarvy.env (nano /etc/clarvy.env),"
echo "then push to main or run the Deploy workflow on GitHub."
