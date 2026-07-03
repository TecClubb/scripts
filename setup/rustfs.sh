#!/bin/bash

# =============================================================================
#  RustFS Setup Script (Final)
#  Sets up RustFS (S3-compatible object storage) on a fresh Ubuntu VPS with
#  Nginx reverse proxy + SSL (Let's Encrypt)
#  API port: 9000  |  Console port: 9001 (separate, confirmed via official installer)
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

# ── Auto-generate a random string (SIGPIPE-safe under set -euo pipefail) ─────
gen_random() {
    local len="${1:-16}"
    local mode="${2:-alnum}"
    local out=""
    case "$mode" in
        alpha)  out="$(cat /dev/urandom | tr -dc 'a-zA-Z' 2>/dev/null | head -c "$len" || true)" ;;
        hex)    out="$(cat /dev/urandom | tr -dc 'a-f0-9' 2>/dev/null | head -c "$len" || true)" ;;
        secret) out="$(cat /dev/urandom | tr -dc 'a-zA-Z0-9!@%^*_+-' 2>/dev/null | head -c "$len" || true)" ;;
        *)      out="$(cat /dev/urandom | tr -dc 'a-zA-Z0-9' 2>/dev/null | head -c "$len" || true)" ;;
    esac
    echo "$out"
}

# ── Root check ────────────────────────────────────────────────────────────────
[[ "$EUID" -ne 0 ]] && error "Please run this script as root (sudo bash rustfs.sh)"

# ── Port pre-flight check ─────────────────────────────────────────────────────
# RustFS needs 9000 (API) and 9001 (Console) free. Same detection order as the
# official install_rustfs.sh (lsof > netstat > ss), but we also name the
# offending process so the error is actionable.
find_port_check_cmd() {
    for cmd in lsof netstat ss; do
        if command -v "$cmd" >/dev/null 2>&1; then
            echo "$cmd"
            return
        fi
    done
}

port_occupied() {
    local cmd="$1" port="$2"
    case "$cmd" in
        lsof)    lsof -i :"$port" -sTCP:LISTEN >/dev/null 2>&1 ;;
        netstat) netstat -ltn 2>/dev/null | grep -q ":${port}[[:space:]]" ;;
        ss)      ss -ltn 2>/dev/null | grep -q ":${port}[[:space:]]" ;;
    esac
}

port_process_detail() {
    local cmd="$1" port="$2"
    local detail=""
    case "$cmd" in
        lsof)
            detail="$(lsof -i :"$port" -sTCP:LISTEN 2>/dev/null | awk 'NR==2 {printf "%s (PID %s, user %s)", $1, $2, $3}')"
            ;;
        netstat)
            detail="$(netstat -ltnp 2>/dev/null | grep ":${port}[[:space:]]" | head -n1 | awk '{print $NF}')"
            [[ -n "$detail" ]] && detail="process $detail"
            ;;
        ss)
            detail="$(ss -ltnp 2>/dev/null | grep ":${port}[[:space:]]" | head -n1 | grep -oP 'users:\(\("[^"]+",pid=[0-9]+' | sed -E 's/users:\(\("([^"]+)",pid=([0-9]+)/process \1 (PID \2)/')"
            ;;
    esac
    [[ -z "$detail" ]] && detail="an unknown process (inspect manually with '$cmd')"
    echo "$detail"
}

PORT_CHECK_CMD="$(find_port_check_cmd)"
[[ -z "$PORT_CHECK_CMD" ]] && error "No port check command found (lsof/netstat/ss). Install one of these and re-run."

for port in 9000 9001; do
    if port_occupied "$PORT_CHECK_CMD" "$port"; then
        error "Port $port is already in use by $(port_process_detail "$PORT_CHECK_CMD" "$port"). RustFS needs ports 9000 (API) and 9001 (Console) free — stop the conflicting service and re-run this script."
    fi
done

# ── Banner ────────────────────────────────────────────────────────────────────
clear
echo -e "${CYAN}${BOLD}"
echo "  ____            _   _____ ____  "
echo " |  _ \ _   _ ___| |_|  ___/ ___| "
echo " | |_) | | | / __| __| |_  \___ \ "
echo " |  _ <| |_| \__ \ |_|  _|  ___) |"
echo " |_| \_\\__,_|___/\__|_|   |____/ "
echo -e "${NC}"
echo -e "${BOLD}  RustFS + Nginx + SSL Automated Installer${NC}"
echo -e "  Ubuntu 20.04 / 22.04 / 24.04"
echo ""

# =============================================================================
#  COLLECT USER INPUT
# =============================================================================
section "Configuration"

while true; do
    read -rp "$(echo -e "${BOLD}Enter your CDN/API domain (for S3 file access, e.g. cdn.example.com):${NC} ")" RUSTFS_API_DOMAIN
    RUSTFS_API_DOMAIN="${RUSTFS_API_DOMAIN// /}"
    if [[ "$RUSTFS_API_DOMAIN" =~ ^[a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?)+$ ]]; then
        break
    fi
    warn "Invalid domain format. Please enter a valid domain like cdn.example.com"
done

while true; do
    read -rp "$(echo -e "${BOLD}Enter your Console domain (for admin UI, e.g. rustfs.example.com):${NC} ")" RUSTFS_CONSOLE_DOMAIN
    RUSTFS_CONSOLE_DOMAIN="${RUSTFS_CONSOLE_DOMAIN// /}"
    if [[ "$RUSTFS_CONSOLE_DOMAIN" =~ ^[a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?)+$ ]]; then
        break
    fi
    warn "Invalid domain format. Please enter a valid domain like rustfs.example.com"
done

while true; do
    read -rp "$(echo -e "${BOLD}Enter your email (for SSL certificate):${NC} ")" CERTBOT_EMAIL
    if [[ "$CERTBOT_EMAIL" =~ ^[^@]+@[^@]+\.[^@]+$ ]]; then
        break
    fi
    warn "Invalid email address. Please try again."
done

echo ""
SERVER_IP_PRECHECK=$(curl -s https://api.ipify.org 2>/dev/null || hostname -I | awk '{print $1}')
warn "Before proceeding, both domains MUST already be DNS A-record pointed to this VPS's IP: ${BOLD}${SERVER_IP_PRECHECK}${NC}"
echo -e "  ${BOLD}${RUSTFS_API_DOMAIN}${NC}     → ${SERVER_IP_PRECHECK}"
echo -e "  ${BOLD}${RUSTFS_CONSOLE_DOMAIN}${NC} → ${SERVER_IP_PRECHECK}"
echo ""
read -rp "$(echo -e "${BOLD}Confirm both domains are already DNS-pointed to this VPS? (y/n):${NC} ")" DNS_CONFIRM
[[ "$DNS_CONFIRM" =~ ^[Yy]$ ]] || { info "Aborted. Point your DNS records and re-run this script."; exit 0; }

echo ""
echo -e "${BOLD}┌──────────────────────────────────────────────────┐${NC}"
echo -e "${BOLD}│              Installation Summary                │${NC}"
echo -e "${BOLD}├──────────────────────────────────────────────────┤${NC}"
echo -e "${BOLD}│${NC} API Domain    : ${GREEN}https://${RUSTFS_API_DOMAIN}${NC} (port 9000)"
echo -e "${BOLD}│${NC} Console Domain: ${GREEN}https://${RUSTFS_CONSOLE_DOMAIN}${NC} (port 9001)"
echo -e "${BOLD}│${NC} Data Dir      : /data/rustfs0"
echo -e "${BOLD}│${NC} Log Dir       : /var/logs/rustfs"
echo -e "${BOLD}└──────────────────────────────────────────────────┘${NC}"
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
apt-get install -y -qq curl wget unzip nginx certbot python3-certbot-nginx ufw
success "Dependencies installed"

section "Creating Directories"
mkdir -p /data/rustfs0 /var/logs/rustfs /opt/tls
chmod 750 /data/rustfs0 /var/logs/rustfs /opt/tls
success "Directories created: /data/rustfs0, /var/logs/rustfs, /opt/tls (750)"

section "Downloading RustFS Binary"
RUSTFS_BIN="/usr/local/bin/rustfs"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

ARCH="$(uname -m)"
case "$ARCH" in
    x86_64)  PKG_URL="https://dl.rustfs.com/artifacts/rustfs/release/rustfs-linux-x86_64-musl-latest.zip" ;;
    aarch64) PKG_URL="https://dl.rustfs.com/artifacts/rustfs/release/rustfs-linux-aarch64-musl-latest.zip" ;;
    *) error "Unsupported CPU architecture: $ARCH" ;;
esac

wget -qO "$TMP_DIR/rustfs.zip" "$PKG_URL"
unzip -qo "$TMP_DIR/rustfs.zip" -d "$TMP_DIR"

RUSTFS_EXTRACTED="$(find "$TMP_DIR" -type f -name 'rustfs*' ! -name '*.zip' | head -n1)"
[[ -z "$RUSTFS_EXTRACTED" ]] && error "Could not find rustfs binary in downloaded archive"

install -m 755 "$RUSTFS_EXTRACTED" "$RUSTFS_BIN"
success "RustFS installed to $RUSTFS_BIN ($ARCH)"

section "Generating Secure Credentials"
RUSTFS_ACCESS_KEY="$(gen_random 16 alnum)"
RUSTFS_SECRET_KEY="$(gen_random 32 secret)"
[[ -z "$RUSTFS_ACCESS_KEY" || -z "$RUSTFS_SECRET_KEY" ]] && error "Credential generation failed."
success "Credentials generated"

section "Writing Environment File"
cat > /etc/default/rustfs <<EOF
# RustFS Environment Configuration
# Generated by rustfs.sh on $(date)

RUSTFS_ACCESS_KEY=${RUSTFS_ACCESS_KEY}
RUSTFS_SECRET_KEY=${RUSTFS_SECRET_KEY}
RUSTFS_VOLUMES="/data/rustfs0"
RUSTFS_ADDRESS=":9000"
RUSTFS_CONSOLE_ADDRESS=":9001"
RUSTFS_CONSOLE_ENABLE=true
RUSTFS_OBS_LOGGER_LEVEL=error
RUSTFS_OBS_LOG_DIRECTORY="/var/logs/rustfs/"
EOF
chmod 600 /etc/default/rustfs
chown root:root /etc/default/rustfs
success "Environment file written to /etc/default/rustfs"

section "Saving Admin Credentials"
cat > /root/rustfs-admin-creds.txt <<EOF
RustFS Admin Credentials
Generated on $(date)

Access Key : ${RUSTFS_ACCESS_KEY}
Secret Key : ${RUSTFS_SECRET_KEY}

API Domain     : https://${RUSTFS_API_DOMAIN}
Console Domain : https://${RUSTFS_CONSOLE_DOMAIN}
EOF
chmod 600 /root/rustfs-admin-creds.txt
chown root:root /root/rustfs-admin-creds.txt
success "Credentials saved to /root/rustfs-admin-creds.txt"

section "Creating systemd Service"
cat > /etc/systemd/system/rustfs.service <<EOF
[Unit]
Description=RustFS Object Storage Server
Documentation=https://rustfs.com/docs/
After=network-online.target
Wants=network-online.target
AssertFileIsExecutable=${RUSTFS_BIN}

[Service]
Type=notify
NotifyAccess=main
User=root
Group=root
WorkingDirectory=/usr/local
EnvironmentFile=-/etc/default/rustfs
ExecStartPre=/bin/bash -c "if [ -z \"\${RUSTFS_VOLUMES}\" ]; then echo 'Variable RUSTFS_VOLUMES not set in /etc/default/rustfs'; exit 1; fi"
ExecStart=${RUSTFS_BIN} \$RUSTFS_VOLUMES

Restart=always
RestartSec=10s
OOMScoreAdjust=-1000
SendSIGKILL=no
TimeoutStartSec=30s
TimeoutStopSec=30s

LimitNOFILE=1048576
LimitNPROC=32768
TasksMax=infinity

NoNewPrivileges=true
ProtectHome=true
PrivateTmp=true
PrivateDevices=true
ProtectClock=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
RestrictSUIDSGID=true
RestrictRealtime=true

StandardOutput=append:/var/logs/rustfs/rustfs.log
StandardError=append:/var/logs/rustfs/rustfs-err.log

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable rustfs
systemctl start rustfs
sleep 3

if systemctl is-active --quiet rustfs; then
    success "RustFS service started and enabled"
else
    error "RustFS failed to start. Check: journalctl -u rustfs -n 50"
fi

section "Configuring Firewall (UFW)"
ufw allow OpenSSH  > /dev/null
ufw allow 80/tcp   > /dev/null
ufw allow 443/tcp  > /dev/null
ufw --force enable > /dev/null
success "Firewall configured (SSH, HTTP, HTTPS allowed — 9000/9001 stay internal, reverse-proxied via Nginx)"

section "Configuring Nginx — API/CDN ($RUSTFS_API_DOMAIN → :9000)"
cat > /etc/nginx/sites-available/rustfs-api <<EOF
server {
    listen 80;
    server_name ${RUSTFS_API_DOMAIN};

    client_max_body_size 10240m;
    proxy_read_timeout 900;
    proxy_connect_timeout 900;
    proxy_send_timeout 900;

    location / {
        proxy_pass http://127.0.0.1:9000;
        proxy_set_header Host \$http_host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_http_version 1.1;
        chunked_transfer_encoding off;
        proxy_buffering off;
        proxy_request_buffering off;
    }
}
EOF
ln -sf /etc/nginx/sites-available/rustfs-api /etc/nginx/sites-enabled/rustfs-api
success "API Nginx config written (proxies to :9000)"

section "Configuring Nginx — Console ($RUSTFS_CONSOLE_DOMAIN → :9001)"
cat > /etc/nginx/sites-available/rustfs-console <<EOF
server {
    listen 80;
    server_name ${RUSTFS_CONSOLE_DOMAIN};

    client_max_body_size 10240m;
    proxy_read_timeout 900;

    location / {
        proxy_pass http://127.0.0.1:9001;
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
ln -sf /etc/nginx/sites-available/rustfs-console /etc/nginx/sites-enabled/rustfs-console
success "Console Nginx config written (proxies to :9001)"

rm -f /etc/nginx/sites-enabled/default
nginx -t && systemctl reload nginx
success "Nginx configured and reloaded"

section "Obtaining SSL Certificates (Let's Encrypt)"
certbot --nginx \
    -d "$RUSTFS_API_DOMAIN" \
    -d "$RUSTFS_CONSOLE_DOMAIN" \
    --email "$CERTBOT_EMAIL" \
    --agree-tos \
    --non-interactive \
    --redirect

systemctl reload nginx
success "SSL certificates issued and Nginx updated"

(crontab -l 2>/dev/null; echo "0 3 * * * certbot renew --quiet && systemctl reload nginx") | sort -u | crontab -
success "Auto-renewal cron added (daily at 3 AM)"

# =============================================================================
#  FINAL SUMMARY
# =============================================================================
section "Setup Complete"

SERVER_IP=$(curl -s https://api.ipify.org 2>/dev/null || hostname -I | awk '{print $1}')

echo -e "${GREEN}${BOLD}"
echo "  ✔ RustFS is running and configured!"
echo -e "${NC}"
echo -e "${BOLD}┌──────────────────────────────────────────────────┐${NC}"
echo -e "${BOLD}│                   Access Info                    │${NC}"
echo -e "${BOLD}├──────────────────────────────────────────────────┤${NC}"
echo -e "${BOLD}│${NC} Server IP     : ${SERVER_IP}"
echo -e "${BOLD}│${NC} API/CDN URL   : https://${RUSTFS_API_DOMAIN}"
echo -e "${BOLD}│${NC} Console URL   : https://${RUSTFS_CONSOLE_DOMAIN}"
echo -e "${BOLD}│${NC} Access Key    : ${GREEN}${RUSTFS_ACCESS_KEY}${NC}"
echo -e "${BOLD}│${NC} Secret Key    : ${GREEN}${RUSTFS_SECRET_KEY}${NC}"
echo -e "${BOLD}│${NC} Data Dir      : /data/rustfs0"
echo -e "${BOLD}├──────────────────────────────────────────────────┤${NC}"
echo -e "${BOLD}│${NC} Env File      : /etc/default/rustfs"
echo -e "${BOLD}│${NC} Creds File    : /root/rustfs-admin-creds.txt"
echo -e "${BOLD}│${NC} Nginx Config  : /etc/nginx/sites-available/rustfs-{api,console}"
echo -e "${BOLD}│${NC} Service       : systemctl {status|restart|stop} rustfs"
echo -e "${BOLD}│${NC} Logs          : journalctl -u rustfs -f"
echo -e "${BOLD}└──────────────────────────────────────────────────┘${NC}"

echo ""
echo -e "${YELLOW}${BOLD}⚠  Credentials are saved to /root/rustfs-admin-creds.txt (chmod 600)${NC}"
echo -e "${YELLOW}${BOLD}⚠  Create a non-root bucket/access key from the console for your Laravel .env — don't use root creds in production.${NC}"
echo ""
echo -e "${CYAN}Done! 🎉${NC}"