#!/usr/bin/env bash
# =============================================================================
#  MCSManager Fresh Install Script
#  - Uninstalls existing MCSManager
#  - Cleans nginx configs
#  - Reinstalls MCSManager
#  - Configures nginx with SSL for both domains
#  - Sets up daemon WSS properly
#  SAFE: Does NOT touch /opt/minecraft (your world is safe!)
# =============================================================================
set -euo pipefail

# ── Colors ────────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

log()    { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()   { echo -e "${YELLOW}[WARN]${NC}  $*"; }
die()    { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }
header() {
    echo -e "\n${CYAN}${BOLD}════════════════════════════════════════${NC}"
    echo -e "${CYAN}${BOLD}  $*${NC}"
    echo -e "${CYAN}${BOLD}════════════════════════════════════════${NC}"
}

# ── Config ────────────────────────────────────────────────────────────────────
PANEL_DOMAIN="mcpanel.xeloras.store"
PLAY_DOMAIN="play.xeloras.store"
MC_DIR="/opt/minecraft"
PANEL_DIR="/opt/mcsmanager"
DAEMON_INTERNAL_PORT=24446   # Node.js daemon (internal only)
DAEMON_PUBLIC_PORT=24444     # Nginx SSL (browser connects here)
PANEL_PORT=23333

# ── Guards ────────────────────────────────────────────────────────────────────
[[ $EUID -eq 0 ]] || die "Run as root: sudo bash mcsm-fresh.sh"

# ── Safety check ──────────────────────────────────────────────────────────────
header "Safety Check"
if [[ -d "$MC_DIR" ]]; then
    log "Minecraft directory found at $MC_DIR — will NOT be touched."
    log "Your world, inventory, and player data are safe."
else
    warn "Minecraft directory not found at $MC_DIR — is this the right server?"
    read -rp "Continue anyway? [y/N]: " confirm
    [[ "$confirm" =~ ^[Yy]$ ]] || exit 0
fi

# =============================================================================
# 1. UNINSTALL MCSMANAGER
# =============================================================================
header "1 / 5  Uninstalling MCSManager"

# Stop and disable services
for svc in mcsm-daemon mcsm-web; do
    if systemctl list-unit-files "$svc.service" &>/dev/null 2>&1; then
        systemctl stop "$svc" 2>/dev/null || true
        systemctl disable "$svc" 2>/dev/null || true
        rm -f "/etc/systemd/system/$svc.service"
        log "Removed service: $svc"
    fi
done

systemctl daemon-reload

# Remove MCSManager directory
if [[ -d "$PANEL_DIR" ]]; then
    rm -rf "$PANEL_DIR"
    log "Removed $PANEL_DIR"
fi

log "MCSManager uninstalled."

# =============================================================================
# 2. CLEAN NGINX
# =============================================================================
header "2 / 5  Cleaning Nginx Configs"

# Remove all our custom configs
for conf in mc-panel mc-play mc-daemon; do
    rm -f "/etc/nginx/sites-enabled/$conf"
    rm -f "/etc/nginx/sites-available/$conf"
    log "Removed nginx config: $conf"
done

# Close daemon ports in UFW
ufw delete allow 24444/tcp 2>/dev/null || true
ufw delete allow 24445/tcp 2>/dev/null || true
ufw delete allow 24446/tcp 2>/dev/null || true
log "Cleaned UFW daemon ports."

# =============================================================================
# 3. INSTALL MCSMANAGER
# =============================================================================
header "3 / 5  Installing MCSManager (fresh)"

INSTALLER="/tmp/mcsm-setup.sh"
log "Downloading MCSManager installer..."
wget -O "$INSTALLER" "https://script.mcsmanager.com/setup.sh" || die "Download failed."

head -1 "$INSTALLER" | grep -q '^#!' || die "Downloaded file is not a shell script."

chmod +x "$INSTALLER"
log "Running installer..."

set +e
bash "$INSTALLER"
RC=$?
set -e

rm -f "$INSTALLER"
[[ $RC -eq 0 ]] || die "MCSManager installer failed with code $RC"

# Wait for services to start
log "Waiting for MCSManager to start..."
sleep 5

# Verify services exist
for svc in mcsm-daemon mcsm-web; do
    systemctl list-unit-files "$svc.service" &>/dev/null || die "$svc service not found after install."
    systemctl enable "$svc" 2>/dev/null || true
    systemctl is-active --quiet "$svc" || systemctl restart "$svc"
    log "Service $svc: $(systemctl is-active $svc)"
done

# =============================================================================
# 4. CONFIGURE DAEMON PORT & PANEL CONNECTION
# =============================================================================
header "4 / 5  Configuring Daemon & Panel"

# Wait for config files to be generated
sleep 3

# Get daemon API key
DAEMON_CONFIG="/opt/mcsmanager/daemon/data/Config/global.json"
[[ -f "$DAEMON_CONFIG" ]] || die "Daemon config not found at $DAEMON_CONFIG"

API_KEY=$(python3 -c "import json; d=json.load(open('$DAEMON_CONFIG')); print(d['key'])")
[[ -n "$API_KEY" ]] || die "Could not read API key from daemon config."
log "Daemon API key: $API_KEY"

# Set daemon to internal port 24446
python3 - <<PYEOF
import json
with open('$DAEMON_CONFIG', 'r') as f:
    cfg = json.load(f)
cfg['port'] = $DAEMON_INTERNAL_PORT
with open('$DAEMON_CONFIG', 'w') as f:
    json.dump(cfg, f, indent=4)
print("Daemon port set to $DAEMON_INTERNAL_PORT")
PYEOF

# Find the remote service config
REMOTE_CONFIG_DIR="/opt/mcsmanager/web/data/RemoteServiceConfig"
mkdir -p "$REMOTE_CONFIG_DIR"

# Get the UUID from existing config file if present
REMOTE_CONFIG=$(ls "$REMOTE_CONFIG_DIR"/*.json 2>/dev/null | head -1 || true)

if [[ -z "$REMOTE_CONFIG" ]]; then
    # Generate a UUID for new config
    UUID=$(cat /proc/sys/kernel/random/uuid | tr -d '-')
    REMOTE_CONFIG="$REMOTE_CONFIG_DIR/${UUID}.json"
fi

log "Writing panel remote service config..."
cat > "$REMOTE_CONFIG" <<EOF
{
    "ip": "localhost",
    "port": "$DAEMON_INTERNAL_PORT",
    "prefix": "",
    "remarks": "Main",
    "apiKey": "$API_KEY",
    "remoteMappings": [
        {
            "from": {
                "ip": "localhost",
                "port": "$DAEMON_INTERNAL_PORT",
                "prefix": ""
            },
            "to": {
                "ip": "$PANEL_DOMAIN",
                "port": "$DAEMON_PUBLIC_PORT",
                "prefix": ""
            }
        }
    ],
    "connectOpts": {
        "multiplex": false,
        "reconnectionDelayMax": 5000,
        "timeout": 10000,
        "reconnection": true,
        "reconnectionAttempts": 10,
        "rejectUnauthorized": false
    }
}
EOF

log "Panel configured to connect daemon via localhost:$DAEMON_INTERNAL_PORT"
log "Browser will be told to connect via $PANEL_DOMAIN:$DAEMON_PUBLIC_PORT"

# Restart daemon with new port, then panel
systemctl restart mcsm-daemon
sleep 3
systemctl restart mcsm-web
sleep 3

# =============================================================================
# 5. CONFIGURE NGINX
# =============================================================================
header "5 / 5  Configuring Nginx"

# ── Panel config ──
cat > /etc/nginx/sites-available/mc-panel <<EOF
server {
    server_name $PANEL_DOMAIN;

    location / {
        proxy_pass         http://127.0.0.1:$PANEL_PORT;
        proxy_http_version 1.1;
        proxy_set_header   Upgrade \$http_upgrade;
        proxy_set_header   Connection "upgrade";
        proxy_set_header   Host \$host;
        proxy_set_header   X-Real-IP \$remote_addr;
        proxy_set_header   X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_read_timeout 86400;
        proxy_buffering    off;
        client_max_body_size 0;
    }

    listen 443 ssl;
    ssl_certificate /etc/letsencrypt/live/$PANEL_DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$PANEL_DOMAIN/privkey.pem;
    include /etc/letsencrypt/options-ssl-nginx.conf;
    ssl_dhparam /etc/letsencrypt/ssl-dhparams.pem;
}

server {
    if (\$host = $PANEL_DOMAIN) {
        return 301 https://\$host\$request_uri;
    }
    listen 80;
    server_name $PANEL_DOMAIN;
    return 404;
}
EOF

# ── Play domain static page ──
mkdir -p /var/www/mc-play
cat > /etc/nginx/sites-available/mc-play <<EOF
server {
    server_name $PLAY_DOMAIN;
    root /var/www/mc-play;
    index index.html;
    location / { try_files \$uri \$uri/ =404; }

    listen 443 ssl;
    ssl_certificate /etc/letsencrypt/live/$PANEL_DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$PANEL_DOMAIN/privkey.pem;
    include /etc/letsencrypt/options-ssl-nginx.conf;
    ssl_dhparam /etc/letsencrypt/ssl-dhparams.pem;
}

server {
    if (\$host = $PLAY_DOMAIN) {
        return 301 https://\$host\$request_uri;
    }
    listen 80;
    server_name $PLAY_DOMAIN;
    return 404;
}
EOF

# ── Daemon SSL proxy ──
# Nginx listens on 24444 (SSL) → proxies to Node on 24446 (plain)
cat > /etc/nginx/sites-available/mc-daemon <<EOF
server {
    listen $DAEMON_PUBLIC_PORT ssl;
    listen [::]:$DAEMON_PUBLIC_PORT ssl;
    server_name $PANEL_DOMAIN;

    resolver 8.8.8.8;
    error_page 497 https://\$host:\$server_port\$request_uri;
    proxy_hide_header Upgrade;

    location / {
        proxy_set_header Host \$host;
        proxy_set_header X-Real-Ip \$remote_addr;
        proxy_set_header X-Forwarded-For \$remote_addr;
        proxy_set_header REMOTE-HOST \$remote_addr;
        proxy_pass http://127.0.0.1:$DAEMON_INTERNAL_PORT;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        client_max_body_size 0;
        proxy_request_buffering off;
        proxy_buffering off;
    }

    ssl_certificate /etc/letsencrypt/live/$PANEL_DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$PANEL_DOMAIN/privkey.pem;
    include /etc/letsencrypt/options-ssl-nginx.conf;
    ssl_dhparam /etc/letsencrypt/ssl-dhparams.pem;
}
EOF

# Enable sites
ln -sf /etc/nginx/sites-available/mc-panel  /etc/nginx/sites-enabled/mc-panel
ln -sf /etc/nginx/sites-available/mc-play   /etc/nginx/sites-enabled/mc-play
ln -sf /etc/nginx/sites-available/mc-daemon /etc/nginx/sites-enabled/mc-daemon
rm -f /etc/nginx/sites-enabled/default

# Open daemon port in UFW
ufw allow $DAEMON_PUBLIC_PORT/tcp comment 'MCSManager Daemon WSS'

nginx -t && systemctl reload nginx
log "Nginx configured."

# =============================================================================
# VERIFY
# =============================================================================
header "Verifying Setup"

sleep 3
echo ""
log "Port status:"
ss -tlnp | grep -E "2333|$DAEMON_PUBLIC_PORT|$DAEMON_INTERNAL_PORT" || true

echo ""
log "Service status:"
for svc in mcsm-daemon mcsm-web nginx; do
    echo "  $svc: $(systemctl is-active $svc)"
done

# =============================================================================
# SUMMARY
# =============================================================================
echo -e "\n${GREEN}${BOLD}"
cat <<'BANNER'
  ╔═══════════════════════════════════════════════════╗
  ║         MCSManager Fresh Install Complete!        ║
  ╚═══════════════════════════════════════════════════╝
BANNER
echo -e "${NC}"

echo -e "${CYAN}${BOLD}Next Steps:${NC}"
echo ""
echo -e "  1. Open panel:  ${BOLD}https://$PANEL_DOMAIN${NC}"
echo -e "     → Create admin account on first visit"
echo ""
echo -e "  2. Add your Minecraft server as an instance:"
echo -e "     → Go to Market → Create Directly"
echo -e "     → Instance Type: PaperMC Server"
echo -e "     → Startup Command: bash start.sh"
echo -e "     → Shutdown Command: stop"
echo -e "     → Server File Directory: ${BOLD}$MC_DIR${NC}"
echo ""
echo -e "  3. Stop systemd Minecraft (let MCSManager control it):"
echo -e "     ${BOLD}sudo systemctl stop minecraft && sudo systemctl disable minecraft${NC}"
echo ""
echo -e "  4. Start server from MCSManager panel"
echo ""
echo -e "${YELLOW}${BOLD}Your world data is untouched at: $MC_DIR${NC}"
echo -e "${YELLOW}World, inventory, player data — all safe!${NC}"
echo ""
echo -e "${CYAN}${BOLD}Daemon WSS URL (test in browser):${NC}"
echo -e "  https://$PANEL_DOMAIN:$DAEMON_PUBLIC_PORT/"
echo ""