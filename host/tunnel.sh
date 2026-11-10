#!/usr/bin/env bash
# tunnel.sh — run this host as a connector of the weaver Cloudflare tunnel.
# Expects /opt/weaver/tunnel.env (TUNNEL_TOKEN=...); moves it to /etc/cloudflared.
# Every host runs the same tunnel; Cloudflare spreads requests over them.
set -euo pipefail
command -v cloudflared >/dev/null || {
  curl -fsSL -o /tmp/cloudflared.deb https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb
  sudo dpkg -i /tmp/cloudflared.deb >/dev/null && rm /tmp/cloudflared.deb
}
sudo install -d -m 700 /etc/cloudflared
[ -f /opt/weaver/tunnel.env ] && sudo install -m 600 /opt/weaver/tunnel.env /etc/cloudflared/weaver.env && rm /opt/weaver/tunnel.env
sudo tee /etc/systemd/system/weaver-tunnel.service >/dev/null <<U
[Unit]
Description=Cloudflare tunnel connector for Weaver
After=network-online.target weaver.service
[Service]
EnvironmentFile=/etc/cloudflared/weaver.env
ExecStart=/usr/bin/cloudflared --no-autoupdate tunnel run
Restart=always
[Install]
WantedBy=multi-user.target
U
sudo systemctl daemon-reload && sudo systemctl enable -q weaver-tunnel && sudo systemctl restart weaver-tunnel
sleep 4; echo "$(cloudflared --version | head -1); weaver-tunnel $(systemctl is-active weaver-tunnel)"
