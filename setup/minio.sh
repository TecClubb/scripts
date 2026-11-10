#!/bin/bash

# =============================================================================
#  MinIO Setup Script
#  Sets up MinIO on a fresh Ubuntu VPS with Nginx reverse proxy + SSL (Let's Encrypt)
# =============================================================================

set -euo pipefail

# ── Colors ────────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# ── Helpers ───────────────────────────────────────────────────────────────────
info()    { echo -e "${BLUE}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }
section() { echo -e "\n${CYAN}${BOLD}═══ $* ═══${NC}\n"; }

# ── Auto-generate a random string ─────────────────────────────────────────────
# Usage: gen_random <length> [alnum|alpha|hex]
gen_random() {
    local len="${1:-16}"
    local mode="${2:-alnum}"
    case "$mode" in
        alpha)  cat /dev/urandom | tr -dc 'a-zA-Z'    | head -c "$len" ;;
        hex)    cat /dev/urandom | tr -dc 'a-f0-9'    | head -c "$len" ;;
        *)      cat /dev/urandom | tr -dc 'a-zA-Z0-9' | head -c "$len" ;;
    esac
    echo ""
}

# ── Root check ────────────────────────────────────────────────────────────────
[[ "$EUID" -ne 0 ]] && error "Please run this script as root (sudo bash setup-minio.sh)"

# ── Banner ────────────────────────────────────────────────────────────────────
clear
echo -e "${CYAN}${BOLD}"
echo "  __  __ _       _  ___     ____       _               "
echo " |  \/  (_)_ __ (_)/ _ \   / ___|  ___| |_ _   _ _ __  "
echo " | |\/| | | '_ \| | | | |  \___ \ / _ \ __| | | | '_ \ "
echo " | |  | | | | | | | |_| |   ___) |  __/ |_| |_| | |_) |"
echo " |_|  |_|_|_| |_|_|\___/   |____/ \___|\__|\__,_| .__/ "
echo "                                                  |_|    "
echo -e "${NC}"
echo -e "${BOLD}  MinIO + Nginx + SSL Automated Installer${NC}"
echo -e "  Ubuntu 20.04 / 22.04 / 24.04"
echo ""

# =============================================================================
#  COLLECT USER INPUT
# =============================================================================
section "Configuration"

# ── Domain ────────────────────────────────────────────────────────────────────
while true; do
    read -rp "$(echo -e "${BOLD}Enter your subdomain (e.g. storage.example.com):${NC} ")" MINIO_DOMAIN
    MINIO_DOMAIN="${MINIO_DOMAIN// /}"
    if [[ "$MINIO_DOMAIN" =~ ^[a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?)+$ ]]; then
        break
    fi
    warn "Invalid domain format. Please enter a valid domain like storage.example.com"
done

# ── Email for Let's Encrypt ───────────────────────────────────────────────────
while true; do
    read -rp "$(echo -e "${BOLD}Enter your email (for SSL certificate):${NC} ")" CERTBOT_EMAIL
    if [[ "$CERTBOT_EMAIL" =~ ^[^@]+@[^@]+\.[^@]+$ ]]; then
        break
    fi
    warn "Invalid email address. Please try again."
done

# ── MinIO root credentials ────────────────────────────────────────────────────
echo ""
info "Set MinIO admin credentials — press Enter to auto-generate"
echo ""

# Username
read -rp "$(echo -e "${BOLD}MinIO root username (min 3 chars) [Enter = auto-generate]:${NC} ")" MINIO_ROOT_USER
if [[ -z "$MINIO_ROOT_USER" ]]; then
    MINIO_ROOT_USER="admin_$(gen_random 6 alpha | tr '[:upper:]' '[:lower:]')"
    info "Auto-generated username: ${GREEN}${BOLD}${MINIO_ROOT_USER}${NC}"
else
    while [[ ${#MINIO_ROOT_USER} -lt 3 ]]; do
        warn "Username must be at least 3 characters."
        read -rp "$(echo -e "${BOLD}MinIO root username:${NC} ")" MINIO_ROOT_USER
    done
fi

# Password
read -rsp "$(echo -e "${BOLD}MinIO root password (min 8 chars) [Enter = auto-generate]:${NC} ")" MINIO_ROOT_PASSWORD
echo ""
if [[ -z "$MINIO_ROOT_PASSWORD" ]]; then
    # Generate a strong password: alnum + special suffix
    MINIO_ROOT_PASSWORD="$(gen_random 14 alnum)@$(gen_random 3 hex)"
    info "Auto-generated password: ${GREEN}${BOLD}${MINIO_ROOT_PASSWORD}${NC}"
else
    while [[ ${#MINIO_ROOT_PASSWORD} -lt 8 ]]; do
        warn "Password must be at least 8 characters."
        read -rsp "$(echo -e "${BOLD}MinIO root password:${NC} ")" MINIO_ROOT_PASSWORD
        echo ""
    done
fi

# ── Storage path ──────────────────────────────────────────────────────────────
echo ""
read -rp "$(echo -e "${BOLD}MinIO data directory [default: /mnt/minio-data]:${NC} ")" MINIO_DATA_DIR
MINIO_DATA_DIR="${MINIO_DATA_DIR:-/mnt/minio-data}"

# ── Ports ─────────────────────────────────────────────────────────────────────
read -rp "$(echo -e "${BOLD}MinIO API port [default: 9000]:${NC} ")" MINIO_API_PORT
MINIO_API_PORT="${MINIO_API_PORT:-9000}"

read -rp "$(echo -e "${BOLD}MinIO Console port [default: 9001]:${NC} ")" MINIO_CONSOLE_PORT
MINIO_CONSOLE_PORT="${MINIO_CONSOLE_PORT:-9001}"

# ── Optional Console subdomain ────────────────────────────────────────────────
echo ""
read -rp "$(echo -e "${BOLD}Expose MinIO Console under its own subdomain? (y/n) [default: n]:${NC} ")" EXPOSE_CONSOLE
EXPOSE_CONSOLE="${EXPOSE_CONSOLE:-n}"

CONSOLE_DOMAIN=""
if [[ "$EXPOSE_CONSOLE" =~ ^[Yy]$ ]]; then
    while true; do
        read -rp "$(echo -e "${BOLD}Console subdomain (e.g. console.example.com):${NC} ")" CONSOLE_DOMAIN
        CONSOLE_DOMAIN="${CONSOLE_DOMAIN// /}"
        if [[ "$CONSOLE_DOMAIN" =~ ^[a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?)+$ ]]; then
            break
        fi
        warn "Invalid domain format."
    done
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}┌──────────────────────────────────────────────────┐${NC}"
echo -e "${BOLD}│              Installation Summary                │${NC}"
echo -e "${BOLD}├──────────────────────────────────────────────────┤${NC}"
echo -e "${BOLD}│${NC} API Domain    : ${GREEN}https://${MINIO_DOMAIN}${NC}"
[[ -n "$CONSOLE_DOMAIN" ]] && \
echo -e "${BOLD}│${NC} Console       : ${GREEN}https://${CONSOLE_DOMAIN}${NC}"
echo -e "${BOLD}│${NC} Data Dir      : ${MINIO_DATA_DIR}"
echo -e "${BOLD}│${NC} API Port      : ${MINIO_API_PORT}"
echo -e "${BOLD}│${NC} Console Port  : ${MINIO_CONSOLE_PORT}"
echo -e "${BOLD}│${NC} Root User     : ${GREEN}${MINIO_ROOT_USER}${NC}"
echo -e "${BOLD}│${NC} Root Password : ${GREEN}${MINIO_ROOT_PASSWORD}${NC}"
echo -e "${BOLD}└──────────────────────────────────────────────────┘${NC}"
echo ""
warn "Save these credentials now — they won't be shown again after install!"
echo ""

read -rp "$(echo -e "${BOLD}Proceed with installation? (y/n):${NC} ")" CONFIRM
[[ "$CONFIRM" =~ ^[Yy]$ ]] || { info "Aborted."; exit 0; }

# =============================================================================
#  INSTALLATION
# =============================================================================

section "Updating System"
apt-get update -qq && apt-get upgrade -y -qq
success "System updated"

section "Installing Dependencies"
apt-get install -y -qq curl wget nginx certbot python3-certbot-nginx ufw
success "Dependencies installed"

section "Creating MinIO User & Directories"
if ! id -u minio-user &>/dev/null; then
    useradd -r -s /sbin/nologin minio-user
    success "Created system user: minio-user"
else
    info "User minio-user already exists, skipping."
fi

mkdir -p "$MINIO_DATA_DIR"
chown -R minio-user:minio-user "$MINIO_DATA_DIR"
chmod 750 "$MINIO_DATA_DIR"
success "Data directory ready: $MINIO_DATA_DIR"

section "Downloading MinIO Binary"
MINIO_BIN="/usr/local/bin/minio"
wget -qO "$MINIO_BIN" https://dl.min.io/server/minio/release/linux-amd64/minio
chmod +x "$MINIO_BIN"
MINIO_VERSION=$("$MINIO_BIN" --version | awk '{print $3}')
success "MinIO installed: $MINIO_VERSION"

section "Writing MinIO Environment File"
mkdir -p /etc/minio
cat > /etc/minio/minio.env <<EOF
# MinIO Environment Configuration
# Generated by setup-minio.sh on $(date)

MINIO_ROOT_USER=${MINIO_ROOT_USER}
MINIO_ROOT_PASSWORD=${MINIO_ROOT_PASSWORD}
MINIO_VOLUMES=${MINIO_DATA_DIR}
MINIO_OPTS="--address :${MINIO_API_PORT} --console-address :${MINIO_CONSOLE_PORT}"
MINIO_SITE_NAME=minio-$(hostname)
EOF
chmod 600 /etc/minio/minio.env
chown root:root /etc/minio/minio.env
success "Environment file written to /etc/minio/minio.env"

section "Creating systemd Service"
cat > /etc/systemd/system/minio.service <<EOF
[Unit]
Description=MinIO Object Storage
Documentation=https://min.io/docs
Wants=network-online.target
After=network-online.target
AssertFileIsExecutable=/usr/local/bin/minio

[Service]
Type=notify
WorkingDirectory=/usr/local

User=minio-user
Group=minio-user

EnvironmentFile=/etc/minio/minio.env

ExecStartPre=/bin/bash -c "if [ -z \"\${MINIO_VOLUMES}\" ]; then echo 'Variable MINIO_VOLUMES not set in /etc/minio/minio.env'; exit 1; fi"
ExecStart=/usr/local/bin/minio server \$MINIO_OPTS \$MINIO_VOLUMES

Restart=on-failure
RestartSec=5

LimitNOFILE=65536
TasksMax=infinity
TimeoutStopSec=infinity
SendSIGKILL=no

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable minio
systemctl start minio
sleep 3

if systemctl is-active --quiet minio; then
    success "MinIO service started and enabled"
else
    error "MinIO failed to start. Check: journalctl -u minio -n 50"
fi

section "Configuring Firewall (UFW)"
ufw allow OpenSSH  > /dev/null
ufw allow 80/tcp   > /dev/null
ufw allow 443/tcp  > /dev/null
ufw --force enable > /dev/null
success "Firewall configured (SSH, HTTP, HTTPS allowed)"

section "Configuring Nginx — API ($MINIO_DOMAIN)"
cat > /etc/nginx/sites-available/minio-api <<EOF
# MinIO API — ${MINIO_DOMAIN}
server {
    listen 80;
    server_name ${MINIO_DOMAIN};

    client_max_body_size 10240m;
    proxy_read_timeout 900;
    proxy_connect_timeout 900;
    proxy_send_timeout 900;

    location / {
        proxy_pass http://127.0.0.1:${MINIO_API_PORT};
        proxy_set_header Host \$http_host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_connect_timeout 300;
        proxy_http_version 1.1;
        chunked_transfer_encoding off;
        proxy_buffering off;
        proxy_request_buffering off;
    }
}
EOF

ln -sf /etc/nginx/sites-available/minio-api /etc/nginx/sites-enabled/minio-api

if [[ -n "$CONSOLE_DOMAIN" ]]; then
    info "Writing Nginx config for Console ($CONSOLE_DOMAIN)"
    cat > /etc/nginx/sites-available/minio-console <<EOF
# MinIO Console — ${CONSOLE_DOMAIN}
server {
    listen 80;
    server_name ${CONSOLE_DOMAIN};

    client_max_body_size 10240m;
    proxy_read_timeout 900;

    location / {
        proxy_pass http://127.0.0.1:${MINIO_CONSOLE_PORT};
        proxy_set_header Host \$http_host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
    }
}
EOF
    ln -sf /etc/nginx/sites-available/minio-console /etc/nginx/sites-enabled/minio-console
    success "Console Nginx config written"
fi

rm -f /etc/nginx/sites-enabled/default
nginx -t && systemctl reload nginx
success "Nginx configured and reloaded"

section "Obtaining SSL Certificates (Let's Encrypt)"
info "Make sure DNS A records for your domain(s) point to this server's IP."
echo ""
read -rp "$(echo -e "${BOLD}DNS is pointed and propagated. Proceed with SSL? (y/n):${NC} ")" SSL_CONFIRM

if [[ "$SSL_CONFIRM" =~ ^[Yy]$ ]]; then
    CERTBOT_DOMAINS="-d ${MINIO_DOMAIN}"
    [[ -n "$CONSOLE_DOMAIN" ]] && CERTBOT_DOMAINS+=" -d ${CONSOLE_DOMAIN}"

    certbot --nginx \
        $CERTBOT_DOMAINS \
        --email "$CERTBOT_EMAIL" \
        --agree-tos \
        --non-interactive \
        --redirect

    systemctl reload nginx
    success "SSL certificates issued and Nginx updated"

    (crontab -l 2>/dev/null; echo "0 3 * * * certbot renew --quiet && systemctl reload nginx") | sort -u | crontab -
    success "Auto-renewal cron added (daily at 3 AM)"
else
    warn "SSL skipped. Run manually:"
    warn "  certbot --nginx -d ${MINIO_DOMAIN} --email ${CERTBOT_EMAIL} --agree-tos --non-interactive --redirect"
fi

# =============================================================================
#  FINAL SUMMARY
# =============================================================================
section "Setup Complete"

SERVER_IP=$(curl -s https://api.ipify.org 2>/dev/null || hostname -I | awk '{print $1}')

echo -e "${GREEN}${BOLD}"
echo "  ✔ MinIO is running and configured!"
echo -e "${NC}"
echo -e "${BOLD}┌──────────────────────────────────────────────────┐${NC}"
echo -e "${BOLD}│                   Access Info                    │${NC}"
echo -e "${BOLD}├──────────────────────────────────────────────────┤${NC}"
echo -e "${BOLD}│${NC} Server IP     : ${SERVER_IP}"
echo -e "${BOLD}│${NC} MinIO API     : https://${MINIO_DOMAIN}"
[[ -n "$CONSOLE_DOMAIN" ]] && \
echo -e "${BOLD}│${NC} Console UI    : https://${CONSOLE_DOMAIN}"
[[ -z "$CONSOLE_DOMAIN" ]] && \
echo -e "${BOLD}│${NC} Console UI    : http://${SERVER_IP}:${MINIO_CONSOLE_PORT} (local only)"
echo -e "${BOLD}│${NC} Root User     : ${GREEN}${MINIO_ROOT_USER}${NC}"
echo -e "${BOLD}│${NC} Root Password : ${GREEN}${MINIO_ROOT_PASSWORD}${NC}"
echo -e "${BOLD}│${NC} Data Dir      : ${MINIO_DATA_DIR}"
echo -e "${BOLD}├──────────────────────────────────────────────────┤${NC}"
echo -e "${BOLD}│${NC} Env File      : /etc/minio/minio.env"
echo -e "${BOLD}│${NC} Nginx Config  : /etc/nginx/sites-available/minio-api"
echo -e "${BOLD}│${NC} Service       : systemctl {status|restart|stop} minio"
echo -e "${BOLD}│${NC} Logs          : journalctl -u minio -f"
echo -e "${BOLD}└──────────────────────────────────────────────────┘${NC}"

echo ""
echo -e "${YELLOW}${BOLD}⚠  Save your credentials above — this is the last time they are shown!${NC}"
echo ""
echo -e "${YELLOW}${BOLD}DNS Reminder:${NC}"
echo -e "  A record: ${BOLD}${MINIO_DOMAIN}${NC} → ${SERVER_IP}"
[[ -n "$CONSOLE_DOMAIN" ]] && \
echo -e "  A record: ${BOLD}${CONSOLE_DOMAIN}${NC} → ${SERVER_IP}"
echo ""
echo -e "${CYAN}Done! 🎉${NC}"