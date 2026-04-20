#!/usr/bin/env bash
# =============================================================================
#  Minecraft VPS Setup Script
#  Ubuntu 22.04 / 24.04  |  2 vCPU / 2 GB RAM optimised
#  Panel:  MCSManager  (Node.js, ~80 MB RAM — lightweight Pterodactyl alternative)
#  Server: Paper Minecraft  (systemd-managed)
#  Proxy:  Nginx + Let's Encrypt
# =============================================================================
set -euo pipefail

# ── Colours ───────────────────────────────────────────────────────────────────
RED='\033[0;31m';  GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m';  BOLD='\033[1m';    NC='\033[0m'

# ── Default configuration (override via env vars before running) ──────────────
PANEL_DOMAIN="${PANEL_DOMAIN:-}"
PLAY_DOMAIN="${PLAY_DOMAIN:-}"
ADMIN_EMAIL="${ADMIN_EMAIL:-}"
PAPER_VERSION="${PAPER_VERSION:-}"
MC_PORT="${MC_PORT:-25565}"
MC_USER="minecraft"
MC_DIR="/opt/minecraft"
PANEL_DIR="/opt/mcsmanager"
PANEL_PORT=23333          # MCSManager web UI default
SWAP_SIZE=2               # GB
NODE_VERSION=20

# ── Logging ───────────────────────────────────────────────────────────────────
log()    { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()   { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()  { echo -e "${RED}[ERROR]${NC} $*" >&2; }
die()    { error "$*"; exit 1; }
header() {
    echo -e "\n${CYAN}${BOLD}════════════════════════════════════════════${NC}"
    echo -e "${CYAN}${BOLD}  $*${NC}"
    echo -e "${CYAN}${BOLD}════════════════════════════════════════════${NC}"
}

# ── Guards ────────────────────────────────────────────────────────────────────
check_root()   { [[ $EUID -eq 0 ]] || die "Run as root:  sudo bash setup.sh"; }
check_ubuntu() {
    . /etc/os-release 2>/dev/null || true
    [[ "${ID:-}" == "ubuntu" ]] || die "This script requires Ubuntu 22.04 or 24.04."
    [[ "${VERSION_ID:-}" =~ ^(22|24)\.04$ ]] || \
        warn "Tested on 22.04/24.04 — current: ${VERSION_ID:-unknown}. Proceeding anyway."
}

# ── Idempotency helpers ───────────────────────────────────────────────────────
pkg_installed() { dpkg -l "$1" 2>/dev/null | grep -q '^ii'; }
cmd_exists()    { command -v "$1" &>/dev/null; }


# =============================================================================
# 1. SYSTEM SETUP
# =============================================================================
setup_system() {
    header "1 / 7  System Setup"

    export DEBIAN_FRONTEND=noninteractive

    log "Updating package index and upgrading..."
    apt-get update -qq
    apt-get upgrade -y -qq

    log "Installing base packages..."
    apt-get install -y -qq \
        curl wget git ufw fail2ban cron \
        nginx certbot python3-certbot-nginx \
        ca-certificates gnupg lsb-release \
        software-properties-common apt-transport-https \
        python3 tar gzip

    # ── Docker ──
    if ! cmd_exists docker; then
        log "Installing Docker..."
        curl -fsSL https://get.docker.com | sh
        systemctl enable --now docker
    else
        log "Docker: already installed."
    fi

    # ── Node.js ──
    if ! node --version 2>/dev/null | grep -q "^v${NODE_VERSION}"; then
        log "Installing Node.js ${NODE_VERSION}..."
        curl -fsSL "https://deb.nodesource.com/setup_${NODE_VERSION}.x" | bash - >/dev/null
        apt-get install -y -qq nodejs
    else
        log "Node.js ${NODE_VERSION}: already installed."
    fi

    # ── Java 21 ──
    if ! java -version 2>&1 | grep -q '"21'; then
        log "Installing Java 21..."
        apt-get install -y -qq openjdk-21-jre-headless
    else
        log "Java 21: already installed."
    fi

    # ── minecraft system user ──
    if ! id "$MC_USER" &>/dev/null; then
        log "Creating system user: $MC_USER"
        useradd -r -m -d "$MC_DIR" -s /bin/bash "$MC_USER"
    else
        log "User $MC_USER: already exists."
    fi

    _setup_swap
    _disable_unused_services
}

_setup_swap() {
    if swapon --show 2>/dev/null | grep -q '/swapfile'; then
        log "Swap: already configured."
        return
    fi
    log "Creating ${SWAP_SIZE}G swap file..."
    fallocate -l "${SWAP_SIZE}G" /swapfile
    chmod 600 /swapfile
    mkswap /swapfile  >/dev/null
    swapon /swapfile
    grep -q '/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >>/etc/fstab
    sysctl -w vm.swappiness=10 >/dev/null
    grep -q 'vm.swappiness' /etc/sysctl.conf || echo 'vm.swappiness=10' >>/etc/sysctl.conf
    log "Swap: ${SWAP_SIZE}G created, swappiness=10."
}

_disable_unused_services() {
    log "Disabling unused services to free RAM..."
    local svcs=(snapd apport whoopsie ModemManager avahi-daemon bluetooth)
    for svc in "${svcs[@]}"; do
        if systemctl is-active --quiet "$svc" 2>/dev/null; then
            systemctl disable --now "$svc" 2>/dev/null || true
            log "  Disabled: $svc"
        fi
    done
}

# =============================================================================
# 2. MINECRAFT SERVER  (Paper)
# =============================================================================
install_minecraft() {
    header "2 / 7  Minecraft Server  (Paper ${PAPER_VERSION})"

    mkdir -p "$MC_DIR"

    # ── Validate version format ──
    if ! [[ "$PAPER_VERSION" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]]; then
        die "Invalid Paper version: '${PAPER_VERSION}'. Expected format like 1.21.4"
    fi

    # ── Download Paper ──
    local api_url="https://api.papermc.io/v2/projects/paper/versions/${PAPER_VERSION}"
    log "Resolving latest Paper build for ${PAPER_VERSION}..."

    local api_response
    api_response=$(curl -fsS --retry 3 -w "\n%{http_code}" "$api_url" 2>/dev/null || true)

    local http_code body
    http_code=$(echo "$api_response" | tail -n1)
    body=$(echo "$api_response" | head -n -1)

    if [[ "$http_code" != "200" || -z "$body" ]]; then
        error "Paper version '${PAPER_VERSION}' not found (HTTP ${http_code:-???})."
        error "Available versions: https://api.papermc.io/v2/projects/paper"
        local versions
        versions=$(curl -fsSL "https://api.papermc.io/v2/projects/paper" \
            | python3 -c "import sys,json; d=json.load(sys.stdin); print(', '.join(d['versions'][-10:]))" 2>/dev/null || true)
        [[ -n "$versions" ]] && error "Recent valid versions: ${versions}"
        die "Fix: re-run the script and enter a valid version (e.g. 1.21.4)"
    fi

    local build
    build=$(echo "$body" \
        | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['builds'][-1])")

    local jar="paper-${PAPER_VERSION}-${build}.jar"
    local dl_url="${api_url}/builds/${build}/downloads/${jar}"

    if [[ ! -f "$MC_DIR/$jar" ]]; then
        log "Downloading $jar ..."
        curl -fsSL -o "$MC_DIR/$jar" "$dl_url"
        log "Download complete."
    else
        log "Paper jar already present — skipping download."
    fi

    ln -sf "$MC_DIR/$jar" "$MC_DIR/server.jar"

    # ── EULA ──
    echo "eula=true" > "$MC_DIR/eula.txt"

    # ── server.properties (only written once; edit manually after first run) ──
    if [[ ! -f "$MC_DIR/server.properties" ]]; then
        cat > "$MC_DIR/server.properties" <<EOF
server-port=${MC_PORT}
view-distance=6
simulation-distance=4
online-mode=false
white-list=true
max-players=20
difficulty=normal
spawn-protection=16
enable-command-block=false
motd=\u00A76Minecraft Server
EOF
        log "server.properties written."
    else
        log "server.properties: already exists, not overwritten."
    fi

    # ── JVM start script — Aikar's flags trimmed for 1.5 GB heap ──
    cat > "$MC_DIR/start.sh" <<'STARTSCRIPT'
#!/bin/bash
exec java \
  -Xms1G -Xmx1500M \
  -XX:+UseG1GC \
  -XX:+ParallelRefProcEnabled \
  -XX:MaxGCPauseMillis=200 \
  -XX:+UnlockExperimentalVMOptions \
  -XX:+DisableExplicitGC \
  -XX:G1NewSizePercent=30 \
  -XX:G1MaxNewSizePercent=40 \
  -XX:G1HeapRegionSize=8M \
  -XX:G1ReservePercent=20 \
  -XX:G1HeapWastePercent=5 \
  -XX:G1MixedGCCountTarget=4 \
  -XX:InitiatingHeapOccupancyPercent=15 \
  -XX:G1MixedGCLiveThresholdPercent=90 \
  -XX:G1RSetUpdatingPauseTimePercent=5 \
  -XX:SurvivorRatio=32 \
  -XX:+PerfDisableSharedMem \
  -XX:MaxTenuringThreshold=1 \
  -Dusing.aikars.flags=https://mcflags.emc.gs \
  -Daikars.new.flags=true \
  -jar server.jar nogui
STARTSCRIPT
    chmod +x "$MC_DIR/start.sh"

    # ── Fix ownership ──
    chown -R "$MC_USER:$MC_USER" "$MC_DIR"

    # ── systemd service ──
    cat > /etc/systemd/system/minecraft.service <<SVCEOF
[Unit]
Description=Paper Minecraft Server
After=network.target

[Service]
User=${MC_USER}
WorkingDirectory=${MC_DIR}
ExecStart=${MC_DIR}/start.sh
ExecStop=/bin/bash -c 'kill -s SIGTERM \$MAINPID'
Restart=on-failure
RestartSec=30
SuccessExitStatus=0 1
TimeoutStopSec=60
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
SVCEOF

    systemctl daemon-reload
    systemctl enable minecraft
    log "Minecraft systemd service installed and enabled."
}

# =============================================================================
# 3. MCSMANAGER PANEL
# =============================================================================
install_panel() {
    header "3 / 7  MCSManager Panel"

    if [[ -d "$PANEL_DIR/web" && -d "$PANEL_DIR/daemon" ]]; then
        log "MCSManager already installed at $PANEL_DIR — skipping."
    else
        local installer="/tmp/mcsm-setup.sh"
        local installer_url="https://script.mcsmanager.com/setup.sh"

        log "Downloading MCSManager installer..."
        # wget without -q so any HTTP error is visible in the terminal
        if ! wget -O "$installer" "$installer_url"; then
            die "Failed to download MCSManager installer from ${installer_url}"
        fi

        # Guard: make sure we got a shell script, not an HTML error page
        if ! head -1 "$installer" | grep -q '^#!'; then
            error "Downloaded file does not look like a shell script (missing shebang)."
            error "Content preview:"; head -3 "$installer" >&2
            rm -f "$installer"
            die "MCSManager download returned unexpected content."
        fi

        chmod +x "$installer"
        log "Running MCSManager installer (this may take a minute)..."

        # Temporarily suspend set -e so the external installer can't kill our script
        set +e
        bash "$installer"
        local rc=$?
        set -e

        rm -f "$installer"

        if [[ $rc -ne 0 ]]; then
            die "MCSManager installer exited with code ${rc}."
        fi
    fi

    # Verify services were created by the installer
    for svc in mcsm-daemon mcsm-web; do
        if ! systemctl list-unit-files "$svc.service" &>/dev/null; then
            die "Service ${svc}.service not found after installation — installer may have failed silently."
        fi
    done

    # Ensure services are enabled and running (idempotent)
    systemctl daemon-reload
    for svc in mcsm-daemon mcsm-web; do
        systemctl enable "$svc" 2>/dev/null || true
        if ! systemctl is-active --quiet "$svc"; then
            systemctl restart "$svc"
        fi
        log "Service $svc: $(systemctl is-active "$svc")"
    done

    log "MCSManager panel running on port ${PANEL_PORT}."
    log "Add your Minecraft instance in the web UI after setup."
}

# =============================================================================
# 4. NGINX + SSL
# =============================================================================
setup_nginx() {
    header "4 / 7  Nginx + SSL"

    # ── Panel reverse proxy ──
    cat > /etc/nginx/sites-available/mc-panel <<NGINXEOF
server {
    listen 80;
    server_name ${PANEL_DOMAIN};

    location / {
        proxy_pass         http://127.0.0.1:${PANEL_PORT};
        proxy_http_version 1.1;
        proxy_set_header   Upgrade \$http_upgrade;
        proxy_set_header   Connection "upgrade";
        proxy_set_header   Host \$host;
        proxy_set_header   X-Real-IP \$remote_addr;
        proxy_set_header   X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_read_timeout 86400;
        proxy_buffering    off;
    }
}
NGINXEOF

    # ── Play domain — static info page ──
    cat > /etc/nginx/sites-available/mc-play <<NGINXEOF
server {
    listen 80;
    server_name ${PLAY_DOMAIN};
    root /var/www/mc-play;
    index index.html;
    location / { try_files \$uri \$uri/ =404; }
}
NGINXEOF

    # ── Static info page content ──
    mkdir -p /var/www/mc-play
    cat > /var/www/mc-play/index.html <<HTMLEOF
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>Minecraft Server — ${PLAY_DOMAIN}</title>
  <style>
    *{box-sizing:border-box;margin:0;padding:0}
    body{font-family:'Segoe UI',sans-serif;background:#0d1117;color:#c9d1d9;
         display:flex;align-items:center;justify-content:center;min-height:100vh}
    .card{background:#161b22;border:1px solid #30363d;border-radius:12px;
          padding:2.5rem 3rem;text-align:center;max-width:480px;width:90%}
    h1{color:#58a6ff;font-size:1.8rem;margin-bottom:.5rem}
    .sub{color:#8b949e;margin-bottom:2rem;font-size:.95rem}
    .badge{display:inline-block;background:#238636;color:#fff;border-radius:20px;
           padding:.25rem .9rem;font-size:.8rem;margin-bottom:1.5rem}
    .addr{background:#0d1117;border:1px solid #30363d;border-radius:8px;
          padding:1rem 1.5rem;font-size:1.2rem;font-family:monospace;
          letter-spacing:.05em;color:#79c0ff;margin-bottom:1rem}
    .note{color:#8b949e;font-size:.85rem;margin-top:1.5rem}
  </style>
</head>
<body>
  <div class="card">
    <h1>&#9935; Minecraft Server</h1>
    <p class="sub">Paper ${PAPER_VERSION} &mdash; Survival</p>
    <span class="badge">&#9679; Online</span>
    <p>Connect using:</p>
    <div class="addr">${PLAY_DOMAIN}:${MC_PORT}</div>
    <p class="note">Java Edition &bull; Cracked / Offline mode supported</p>
  </div>
</body>
</html>
HTMLEOF

    # ── Enable sites ──
    ln -sf /etc/nginx/sites-available/mc-panel /etc/nginx/sites-enabled/mc-panel
    ln -sf /etc/nginx/sites-available/mc-play  /etc/nginx/sites-enabled/mc-play
    rm -f /etc/nginx/sites-enabled/default

    nginx -t
    systemctl enable --now nginx
    systemctl reload nginx
    log "Nginx configured."

    # ── SSL via Certbot ──
    log "Requesting Let's Encrypt certificates (requires DNS to point here)..."
    certbot --nginx \
        -d "$PANEL_DOMAIN" -d "$PLAY_DOMAIN" \
        --non-interactive --agree-tos \
        --email "$ADMIN_EMAIL" \
        --redirect \
        && log "SSL certificates installed." \
        || warn "Certbot failed — DNS may not be pointing here yet.
         Re-run after DNS propagation:
         certbot --nginx -d ${PANEL_DOMAIN} -d ${PLAY_DOMAIN} \\
           --non-interactive --agree-tos --email ${ADMIN_EMAIL} --redirect"
}

# =============================================================================
# 5. FIREWALL  (UFW)
# =============================================================================
setup_firewall() {
    header "5 / 7  Firewall (UFW)"

    ufw --force reset
    ufw default deny incoming
    ufw default allow outgoing
    ufw allow 22/tcp    comment 'SSH'
    ufw allow 80/tcp    comment 'HTTP'
    ufw allow 443/tcp   comment 'HTTPS'
    ufw allow "${MC_PORT}/tcp" comment 'Minecraft TCP'
    ufw allow "${MC_PORT}/udp" comment 'Minecraft UDP'
    ufw --force enable
    log "UFW enabled. Open ports: 22, 80, 443, ${MC_PORT}."
}

# =============================================================================
# 6. BACKUP SYSTEM
# =============================================================================
setup_backups() {
    header "6 / 7  Backup System"

    mkdir -p /opt/mc-backups

    cat > /usr/local/bin/mc-backup <<'BKPEOF'
#!/bin/bash
# Minecraft world backup — keeps 7 most-recent archives
set -euo pipefail
BACKUP_DIR="/opt/mc-backups"
MC_DIR="/opt/minecraft"
DATE=$(date +%Y-%m-%d_%H-%M)
ARCHIVE="${BACKUP_DIR}/world-${DATE}.tar.gz"

STOPPED=false
if systemctl is-active --quiet minecraft; then
    echo "[backup] Stopping server for consistent snapshot..."
    systemctl stop minecraft
    STOPPED=true
fi

# Compress world directories (world, world_nether, world_the_end if present)
declare -a WORLDS=()
for d in world world_nether world_the_end; do
    [[ -d "${MC_DIR}/${d}" ]] && WORLDS+=("$d")
done

if [[ ${#WORLDS[@]} -eq 0 ]]; then
    echo "[backup] No world directories found — skipping tar."
else
    tar -czf "$ARCHIVE" -C "$MC_DIR" "${WORLDS[@]}"
    echo "[backup] Created: $ARCHIVE"
fi

if [[ "$STOPPED" == "true" ]]; then
    systemctl start minecraft
    echo "[backup] Server restarted."
fi

# Prune — keep newest 7
ls -t "${BACKUP_DIR}"/world-*.tar.gz 2>/dev/null | tail -n +8 | xargs -r rm --
echo "[backup] Done."
BKPEOF

    chmod +x /usr/local/bin/mc-backup

    # Daily at 03:00
    echo "0 3 * * * root /usr/local/bin/mc-backup >> /var/log/mc-backup.log 2>&1" \
        > /etc/cron.d/mc-backup

    log "Daily backup cron installed (03:00 AM, retains 7 days)."
    log "Run manually: sudo mc-backup"
}

# =============================================================================
# 7. START SERVICES
# =============================================================================
start_services() {
    header "7 / 7  Starting Services"

    # MCSManager (should already be running)
    for svc in mcsm-daemon mcsm-web; do
        systemctl is-active --quiet "$svc" || systemctl restart "$svc"
    done

    # Minecraft
    if ! systemctl is-active --quiet minecraft; then
        log "Starting Minecraft server (first run may take ~30 s to generate world)..."
        systemctl start minecraft
    else
        log "Minecraft already running."
    fi
}

# =============================================================================
# SUMMARY
# =============================================================================
print_summary() {
    echo -e "\n${GREEN}${BOLD}"
    cat <<'BANNER'
  ╔═══════════════════════════════════════════════════════╗
  ║           MINECRAFT VPS  —  SETUP COMPLETE            ║
  ╚═══════════════════════════════════════════════════════╝
BANNER
    echo -e "${NC}"

    echo -e "${CYAN}${BOLD}URLs${NC}"
    echo -e "  Web Panel    →  https://${PANEL_DOMAIN}"
    echo -e "  Server       →  ${PLAY_DOMAIN}:${MC_PORT}"
    echo -e "  Panel (LAN)  →  http://127.0.0.1:${PANEL_PORT}"
    echo

    echo -e "${CYAN}${BOLD}First-Time Panel Login${NC}"
    echo -e "  Open https://${PANEL_DOMAIN} in a browser."
    echo -e "  MCSManager will prompt you to create an admin account on first visit."
    echo -e "  Then add the Minecraft server as a new instance:"
    echo -e "    Working dir : ${MC_DIR}"
    echo -e "    Start cmd   : bash start.sh"
    echo

    echo -e "${CYAN}${BOLD}Service Commands${NC}"
    echo -e "  sudo systemctl start|stop|restart minecraft"
    echo -e "  sudo systemctl start|stop|restart mcsm-web"
    echo -e "  sudo systemctl start|stop|restart mcsm-daemon"
    echo -e "  sudo journalctl -fu minecraft"
    echo

    echo -e "${CYAN}${BOLD}Whitelist${NC}"
    echo -e "  Edit ${MC_DIR}/whitelist.json  OR  run in-game: /whitelist add <player>"
    echo

    echo -e "${CYAN}${BOLD}Backups${NC}"
    echo -e "  Location : /opt/mc-backups"
    echo -e "  Schedule : daily at 03:00 AM  (7 days retained)"
    echo -e "  Manual   : sudo mc-backup"
    echo

    echo -e "${CYAN}${BOLD}Resource Budget  (2 GB VPS)${NC}"
    echo -e "  Paper JVM      ~  800 – 1 200 MB"
    echo -e "  MCSManager     ~   80 –   120 MB"
    echo -e "  Nginx          ~   20 MB"
    echo -e "  OS + misc      ~  200 MB"
    echo -e "  Swap buffer    ~ 2 048 MB (on-disk)"
    echo -e "  ──────────────────────────────────"
    echo -e "  Peak usage     ~ 1.1 – 1.5 GB / 2 GB"
    echo

    echo -e "${YELLOW}${BOLD}NOTE:${NC} If SSL failed, re-run certbot after DNS propagation:"
    echo -e "  certbot --nginx -d ${PANEL_DOMAIN} -d ${PLAY_DOMAIN} \\"
    echo -e "    --non-interactive --agree-tos --email ${ADMIN_EMAIL} --redirect"
    echo
}

# =============================================================================
# INTERACTIVE CONFIGURATION
# =============================================================================
configure_vars() {
    echo -e "\n${BOLD}Enter your server details:${NC}\n"

    read -rp "  Panel domain   (e.g. panel.example.com): " PANEL_DOMAIN
    read -rp "  Play domain    (e.g. play.example.com):  " PLAY_DOMAIN
    read -rp "  Admin e-mail   (e.g. admin@example.com): " ADMIN_EMAIL
    read -rp "  Paper version  (e.g. 1.21.4):            " PAPER_VERSION

    PANEL_DOMAIN="${PANEL_DOMAIN:-mcpanel.xeloras.store}"
    PLAY_DOMAIN="${PLAY_DOMAIN:-play.xeloras.store}"
    ADMIN_EMAIL="${ADMIN_EMAIL:-tecclubx@gmail.com}"
    PAPER_VERSION="${PAPER_VERSION:-1.21.11}"

    echo
}

# =============================================================================
# MAIN MENU
# =============================================================================
show_menu() {
    echo -e "${CYAN}${BOLD}"
    cat <<'BANNER'
  ╔══════════════════════════════════════════════════╗
  ║       MINECRAFT VPS SETUP — MAIN MENU           ║
  ║   Ubuntu 22.04 / 24.04  |  Low-RAM Optimised    ║
  ╚══════════════════════════════════════════════════╝
BANNER
    echo -e "${NC}"
    echo -e "  ${BOLD}1)${NC} Install full system  ${YELLOW}(recommended)${NC}"
    echo -e "  ${BOLD}2)${NC} Install panel only   (MCSManager + Nginx)"
    echo -e "  ${BOLD}3)${NC} Install Minecraft server only"
    echo -e "  ${BOLD}4)${NC} Run backup now"
    echo -e "  ${BOLD}5)${NC} Exit"
    echo

    read -rp "  Choose [1-5]: " choice
    case "$choice" in
        1)
            setup_system
            install_minecraft
            install_panel
            setup_nginx
            setup_firewall
            setup_backups
            start_services
            print_summary
            ;;
        2)
            setup_system
            install_panel
            setup_nginx
            setup_firewall
            print_summary
            ;;
        3)
            setup_system
            install_minecraft
            setup_firewall
            setup_backups
            start_services
            print_summary
            ;;
        4)
            /usr/local/bin/mc-backup
            ;;
        5)
            exit 0
            ;;
        *)
            die "Invalid choice: $choice"
            ;;
    esac
}

# =============================================================================
# ENTRYPOINT
# =============================================================================
check_root
check_ubuntu
configure_vars
show_menu
