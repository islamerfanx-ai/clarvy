#!/usr/bin/env bash
# Route clarvy.tejarra.com through the InstaRide edge nginx container (it owns ports 80/443).
# Run as root on the server after setup-server.sh:  bash edge-setup.sh
#
# Touches only:  /srv/instaride/edge/runtime/clarvy.conf, /srv/instaride/edge/certs/clarvy/,
#                /etc/clarvy.env (HOST), and a ufw rule for port 3000 on the Docker bridge.
# Every edge reload is preceded by `nginx -t`; if the test fails the Clarvy file is removed
# and InstaRide keeps running on its current config.
set -euo pipefail

DOMAIN=clarvy.tejarra.com
EDGE=instaride-deploy-edge-1
RUNTIME=/srv/instaride/edge/runtime
CERTS=/srv/instaride/edge/certs/clarvy
ACME=/srv/instaride/acme
CONF="$RUNTIME/clarvy.conf"

# Start Clarvy after Docker so the bridge address it binds to exists.
sed -i 's/^After=network.target$/After=network.target docker.service/' /etc/systemd/system/clarvy.service
systemctl daemon-reload

# Our earlier host nginx install could never start (port 80 is taken); keep it off.
systemctl disable --now nginx 2>/dev/null || true
rm -f /etc/nginx/sites-enabled/clarvy

# Clarvy listens on the edge network's gateway: reachable from the container, not from the internet.
GW=$(docker inspect "$EDGE" --format '{{range .NetworkSettings.Networks}}{{.Gateway}} {{end}}' | awk '{print $1}')
[ -n "$GW" ] || { echo "Could not find the edge network gateway"; exit 1; }
echo "Edge network gateway: $GW"
if grep -q '^HOST=' /etc/clarvy.env; then sed -i "s/^HOST=.*/HOST=$GW/" /etc/clarvy.env; else echo "HOST=$GW" >> /etc/clarvy.env; fi
if command -v ufw >/dev/null && ufw status | grep -q active; then
  BRIDGE=$(ip -o -4 addr show | awk -v gw="$GW" '$4 ~ "^"gw"/" {print $2}')
  [ -n "$BRIDGE" ] && ufw allow in on "$BRIDGE" to "$GW" port 3000 proto tcp
fi

echo "Existing files in $RUNTIME:"; ls -la "$RUNTIME"

edge_apply() {
  if docker exec "$EDGE" nginx -t; then
    docker exec "$EDGE" nginx -s reload
  else
    echo "nginx -t failed; removing $CONF so InstaRide is unaffected"
    rm -f "$CONF"
    exit 1
  fi
}

http_block() {
  cat <<EOF
# Clarvy (added by clarvy/deploy/edge-setup.sh). Safe to delete this file and reload to remove Clarvy.
server {
  listen 80;
  server_name $DOMAIN;
  location ^~ /.well-known/acme-challenge/ { root /var/www/acme; }
  location / { return 301 https://\$host\$request_uri; }
}
EOF
}

# Step 1: HTTP only, so Let's Encrypt can verify the domain through the edge.
http_block > "$CONF"
edge_apply

# Step 2: certificate. The renewal hook copies it where the edge can read it and reloads.
install -d -m 700 "$CERTS"
cat > /etc/letsencrypt/renewal-hooks/deploy/clarvy-edge.sh <<EOF
#!/bin/sh
[ "\$RENEWED_DOMAINS" = "$DOMAIN" ] || exit 0
cp -L /etc/letsencrypt/live/$DOMAIN/fullchain.pem /etc/letsencrypt/live/$DOMAIN/privkey.pem $CERTS/
docker exec $EDGE nginx -t && docker exec $EDGE nginx -s reload
EOF
chmod 755 /etc/letsencrypt/renewal-hooks/deploy/clarvy-edge.sh
certbot certonly --webroot -w "$ACME" -d "$DOMAIN" --non-interactive --agree-tos --register-unsafely-without-email
cp -L /etc/letsencrypt/live/$DOMAIN/fullchain.pem /etc/letsencrypt/live/$DOMAIN/privkey.pem "$CERTS/"

# Step 3: HTTPS server proxying to Clarvy.
{ http_block; cat <<EOF

server {
  listen 443 ssl;
  server_name $DOMAIN;
  ssl_certificate /etc/nginx/certs/clarvy/fullchain.pem;
  ssl_certificate_key /etc/nginx/certs/clarvy/privkey.pem;
  client_max_body_size 10m;

  location / {
    proxy_pass http://$GW:3000;
    proxy_http_version 1.1;
    proxy_set_header Host \$host;
    proxy_set_header X-Forwarded-For \$remote_addr;
    proxy_set_header X-Forwarded-Proto https;
    proxy_read_timeout 300s;
  }
}
EOF
} > "$CONF"
edge_apply

systemctl restart clarvy || true
echo
echo "Done. https://$DOMAIN is routed to Clarvy on $GW:3000."
echo "Remember to set OPENAI_API_KEY in /etc/clarvy.env, then: systemctl restart clarvy"
