#!/bin/bash

# Coolify Setup Script
# Installs and configures Coolify on a fresh Ubuntu 22.04/24.04 LTS VPS
# Optionally configures a custom domain with SSL via Traefik + Let's Encrypt
#
# Usage:
#   ./setup-coolify.sh [--email admin@example.com] [--username admin] \
#                      [--password secret123ABC] [--domain coolify.example.com]

set -e

# ===============================
# Colors & Output Helpers
# ===============================
BLUE='\033[0;34m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
BOLD='\033[1m'
NC='\033[0m'

print_info()    { echo -e "${BLUE}[INFO]${NC} $1"; }
print_success() { echo -e "${GREEN}[OK]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
print_error()   { echo -e "${RED}[ERROR]${NC} $1"; }

print_step() {
    echo ""
    echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BOLD}  $1${NC}"
    echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
}

# ===============================
# Argument Parsing
# ===============================
ARG_EMAIL=""
ARG_USERNAME=""
ARG_PASSWORD=""
ARG_DOMAIN=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --email)    ARG_EMAIL="$2";    shift 2 ;;
        --username) ARG_USERNAME="$2"; shift 2 ;;
        --password) ARG_PASSWORD="$2"; shift 2 ;;
        --domain)   ARG_DOMAIN="$2";   shift 2 ;;
        *)
            print_error "Unknown argument: $1"
            echo "Usage: $0 [--email EMAIL] [--username USERNAME] [--password PASSWORD] [--domain DOMAIN]"
            exit 1
            ;;
    esac
done

# ===============================
# Pre-flight: Root Check
# ===============================
if [[ $EUID -ne 0 ]]; then
    print_error "This script must be run as root. Try: sudo $0"
    exit 1
fi

# ===============================
# Pre-flight: OS Detection
# ===============================
if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS_NAME="$NAME"
    OS_VERSION_ID="$VERSION_ID"
else
    print_error "Cannot detect OS. This script requires Ubuntu."
    exit 1
fi

print_info "Detected OS: $OS_NAME $OS_VERSION_ID"

case "$OS_VERSION_ID" in
    20.04|22.04|24.04)
        print_success "Ubuntu $OS_VERSION_ID LTS — fully supported"
        ;;
    *)
        print_warning "Ubuntu $OS_VERSION_ID is not a tested LTS release."
        print_warning "Coolify officially supports Ubuntu 20.04, 22.04, and 24.04 LTS."
        print_warning "Proceeding, but issues may arise."
        ;;
esac

# ===============================
# Helper: Validate Email
# ===============================
validate_email() {
    local email="$1"
    if [[ "$email" =~ ^[a-zA-Z0-9._%+\-]+@[a-zA-Z0-9.\-]+\.[a-zA-Z]{2,}$ ]]; then
        return 0
    fi
    return 1
}

# ===============================
# Helper: Validate Password
# ===============================
validate_password() {
    local pass="$1"
    if [ ${#pass} -lt 12 ]; then
        print_error "Password must be at least 12 characters."
        return 1
    fi
    if ! [[ "$pass" =~ [A-Z] ]]; then
        print_error "Password must contain at least one uppercase letter."
        return 1
    fi
    if ! [[ "$pass" =~ [0-9] ]]; then
        print_error "Password must contain at least one number."
        return 1
    fi
    return 0
}

# ===============================
# Helper: Validate Domain
# ===============================
validate_domain() {
    local domain="$1"
    # No http:// or https:// prefix, no trailing slash, valid hostname chars
    if [[ "$domain" =~ ^https?:// ]]; then
        print_error "Domain should not include http:// or https://. Enter just the hostname."
        return 1
    fi
    if [[ "$domain" =~ /$ ]]; then
        print_error "Domain should not have a trailing slash."
        return 1
    fi
    if ! [[ "$domain" =~ ^[a-zA-Z0-9]([a-zA-Z0-9.-]+)?[a-zA-Z0-9]$ ]]; then
        print_error "Domain format looks invalid: $domain"
        return 1
    fi
    return 0
}

# ===============================
# Helper: Spinner Poll for HTTP
# ===============================
# wait_for_http <url> <timeout_seconds> <label>
wait_for_http() {
    local url="$1"
    local timeout="${2:-90}"
    local label="${3:-service}"
    local elapsed=0
    local spin_chars='|/-\'
    local spin_idx=0

    print_info "Waiting for $label to become available at $url (timeout: ${timeout}s)..."

    while [ "$elapsed" -lt "$timeout" ]; do
        local http_code
        http_code=$(curl -sk -o /dev/null -w "%{http_code}" "$url" 2>/dev/null || echo "000")

        if [ "$http_code" = "200" ] || [ "$http_code" = "302" ] || [ "$http_code" = "301" ]; then
            echo ""
            print_success "$label is responding (HTTP $http_code)"
            return 0
        fi

        local spin_char="${spin_chars:$spin_idx:1}"
        printf "\r  ${spin_char} Waiting... ${elapsed}s elapsed (last HTTP: %s)" "$http_code"
        spin_idx=$(( (spin_idx + 1) % 4 ))
        sleep 5
        elapsed=$(( elapsed + 5 ))
    done

    echo ""
    print_error "$label did not respond within ${timeout} seconds."
    print_error "Check: docker ps | grep coolify"
    return 1
}

# ===============================
# Helper: upsert a key in a .env file
# ===============================
# upsert_env <file> <key> <value>
upsert_env() {
    local file="$1"
    local key="$2"
    local value="$3"

    if grep -q "^${key}=" "$file" 2>/dev/null; then
        # Key exists — update it (escape & and / in value for sed)
        local escaped_value
        escaped_value=$(printf '%s\n' "$value" | sed 's/[\/&]/\\&/g')
        sed -i "s|^${key}=.*|${key}=${escaped_value}|" "$file"
    else
        # Key missing — append it
        echo "${key}=${value}" >> "$file"
    fi
}

# ====================================================================
# STEP 1 — SYSTEM PREP
# ====================================================================
print_step "STEP 1 — SYSTEM PREP"

print_info "Updating package lists and upgrading packages..."
apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get upgrade -y -qq

PREREQ_PACKAGES=(curl wget git jq openssl ufw)
for pkg in "${PREREQ_PACKAGES[@]}"; do
    if dpkg -l "$pkg" 2>/dev/null | grep -q "^ii"; then
        print_info "$pkg is already installed"
    else
        print_info "Installing $pkg..."
        apt-get install -y "$pkg" -qq
    fi
done

print_success "System prep complete"

# ====================================================================
# STEP 2 — FIREWALL (UFW)
# ====================================================================
print_step "STEP 2 — FIREWALL (UFW)"

print_info "Configuring UFW firewall rules..."
ufw --force reset
ufw default deny incoming
ufw default allow outgoing

ufw allow 22/tcp    comment 'SSH'
ufw allow 8000/tcp  comment 'Coolify Dashboard'
ufw allow 80/tcp    comment 'HTTP'
ufw allow 443/tcp   comment 'HTTPS'

ufw --force enable
print_success "UFW enabled"
echo ""
ufw status verbose

# ====================================================================
# STEP 3 — SSH HARDENING
# ====================================================================
print_step "STEP 3 — SSH HARDENING"

SSHD_CONFIG="/etc/ssh/sshd_config"
SSH_CHANGED=false

# Helper: ensure a directive is set to the required value
# set_sshd_directive <key> <required_value>
set_sshd_directive() {
    local key="$1"
    local required_value="$2"

    # Check if the key exists (commented or uncommented)
    if grep -qiE "^\s*#?\s*${key}\s+" "$SSHD_CONFIG" 2>/dev/null; then
        local current_value
        current_value=$(grep -iE "^\s*${key}\s+" "$SSHD_CONFIG" | tail -1 | awk '{print $2}')

        if [ "$current_value" = "$required_value" ]; then
            print_info "SSH: $key is already set to $required_value"
            return 0
        fi

        if [ "$key" = "PermitRootLogin" ] && [ -n "$current_value" ] && [ "$current_value" != "$required_value" ]; then
            print_warning "SSH: PermitRootLogin was '$current_value' — changing to '$required_value' (required for Coolify)"
        fi

        # Remove any existing lines (commented or not) and append a clean one
        sed -i -E "s|^\s*#?\s*(${key})\s+.*|#\1 (managed by setup-coolify.sh)|i" "$SSHD_CONFIG"
        echo "${key} ${required_value}" >> "$SSHD_CONFIG"
    else
        print_info "SSH: Adding $key $required_value"
        echo "${key} ${required_value}" >> "$SSHD_CONFIG"
    fi

    SSH_CHANGED=true
    print_success "SSH: $key set to $required_value"
}

set_sshd_directive "PubkeyAuthentication"  "yes"
set_sshd_directive "AllowTcpForwarding"    "yes"
set_sshd_directive "GatewayPorts"          "yes"
set_sshd_directive "PermitRootLogin"       "yes"

if [ "$SSH_CHANGED" = true ]; then
    print_info "Restarting SSH service..."
    systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null || true
    print_success "SSH service restarted"
else
    print_success "SSH config unchanged — no restart needed"
fi

# ====================================================================
# STEP 4 — INSTALL COOLIFY
# ====================================================================
print_step "STEP 4 — INSTALL COOLIFY"

COOLIFY_ALREADY_INSTALLED=false

# Check if Coolify is already installed
if [ -d "/data/coolify" ] && docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^coolify$"; then
    print_warning "Coolify appears to be already installed and running."
    print_warning "Skipping reinstall. Continuing to domain configuration if --domain was provided."
    COOLIFY_ALREADY_INSTALLED=true
fi

if [ "$COOLIFY_ALREADY_INSTALLED" = false ]; then

    # --- Collect admin credentials ---
    if [ -n "$ARG_USERNAME" ]; then
        ROOT_USERNAME="$ARG_USERNAME"
    else
        read -p "  Admin username [default: admin]: " ROOT_USERNAME
        ROOT_USERNAME="${ROOT_USERNAME:-admin}"
    fi
    print_info "Admin username: $ROOT_USERNAME"

    if [ -n "$ARG_EMAIL" ]; then
        if ! validate_email "$ARG_EMAIL"; then
            print_error "Invalid email provided via --email: $ARG_EMAIL"
            exit 1
        fi
        ROOT_USER_EMAIL="$ARG_EMAIL"
    else
        while true; do
            read -p "  Admin email: " ROOT_USER_EMAIL
            if validate_email "$ROOT_USER_EMAIL"; then
                break
            fi
            print_error "Invalid email format. Try again."
        done
    fi
    print_info "Admin email: $ROOT_USER_EMAIL"

    if [ -n "$ARG_PASSWORD" ]; then
        if ! validate_password "$ARG_PASSWORD"; then
            print_error "Password provided via --password does not meet requirements."
            exit 1
        fi
        ROOT_USER_PASSWORD="$ARG_PASSWORD"
    else
        while true; do
            read -sp "  Admin password (min 12 chars, 1 uppercase, 1 number): " ROOT_USER_PASSWORD
            echo
            if validate_password "$ROOT_USER_PASSWORD"; then
                break
            fi
        done
    fi
    print_info "Password accepted"

    # --- Run official Coolify installer ---
    print_info "Running official Coolify installer..."
    print_info "This installs Docker and all Coolify components — please wait..."

    env ROOT_USERNAME="$ROOT_USERNAME" \
        ROOT_USER_EMAIL="$ROOT_USER_EMAIL" \
        ROOT_USER_PASSWORD="$ROOT_USER_PASSWORD" \
        bash -c 'curl -fsSL https://cdn.coollabs.io/coolify/install.sh | bash'

    print_success "Coolify installer finished"

else
    # If already installed, we still need credentials for the summary
    if [ -n "$ARG_USERNAME" ]; then
        ROOT_USERNAME="$ARG_USERNAME"
    else
        ROOT_USERNAME="(existing)"
    fi
    if [ -n "$ARG_EMAIL" ]; then
        ROOT_USER_EMAIL="$ARG_EMAIL"
    else
        ROOT_USER_EMAIL="(existing)"
    fi
fi

# ====================================================================
# STEP 5 — WAIT FOR COOLIFY
# ====================================================================
print_step "STEP 5 — WAIT FOR COOLIFY TO BE READY"

if ! wait_for_http "http://localhost:8000" 90 "Coolify dashboard"; then
    print_error "Coolify did not start in time. Check logs with: docker logs coolify"
    exit 1
fi

# ====================================================================
# STEP 6 — CUSTOM DOMAIN + SSL
# ====================================================================

configure_domain() {
    local domain="$1"
    local email="$2"

    print_step "STEP 6 — CUSTOM DOMAIN + SSL"

    # --- Validate domain format ---
    if ! validate_domain "$domain"; then
        print_error "Aborting domain configuration due to invalid domain."
        return 1
    fi

    # --- Get server's public IPv4 ---
    local server_ip
    server_ip=$(curl -4 -fsSL https://ifconfig.me 2>/dev/null || curl -4 -fsSL https://api.ipify.org 2>/dev/null || echo "unknown")

    # --- DNS pre-check ---
    print_info "Checking DNS resolution for $domain..."
    if command -v dig &>/dev/null; then
        local resolved_ip
        resolved_ip=$(dig +short "$domain" A 2>/dev/null | head -1)
        if [ -z "$resolved_ip" ]; then
            print_warning "Could not resolve $domain — DNS may not have propagated yet."
        elif [ "$resolved_ip" != "$server_ip" ]; then
            print_warning "DNS mismatch: $domain → $resolved_ip (expected $server_ip)."
            print_warning "SSL provisioning will fail until DNS propagates."
        else
            print_success "DNS check passed: $domain → $resolved_ip"
        fi
    else
        print_info "dig not available — skipping DNS pre-check"
    fi

    # --- Update Coolify .env (APP_URL controls link generation inside the app) ---
    local COOLIFY_ENV="/data/coolify/source/.env"
    if [ ! -f "$COOLIFY_ENV" ]; then
        print_error "Coolify .env not found at $COOLIFY_ENV. Is Coolify installed?"
        return 1
    fi

    print_info "Updating Coolify .env APP_URL and ACME email..."
    upsert_env "$COOLIFY_ENV" "APP_URL"            "https://${domain}"
    upsert_env "$COOLIFY_ENV" "TRAEFIK_ACME_EMAIL" "${email}"
    print_success ".env updated"

    # NOTE: We do NOT restart containers here or poll https://<domain>.
    #
    # Setting APP_URL only affects internal link generation. Traefik routing
    # for the Coolify dashboard domain is NOT driven by APP_URL — it is
    # configured through the Coolify UI (Settings → General → Instance's Domain).
    # Restarting the containers here would just cause a 503 "No Available Server"
    # because Traefik has no routing rule for the domain yet.
    #
    # The correct flow is:
    #   1. Access Coolify via http://<server-ip>:8000 and complete onboarding
    #   2. Go to Settings → General → Instance's Domain → enter https://<domain>
    #   3. Save — Coolify will configure Traefik + issue the SSL cert automatically

    echo ""
    echo -e "${YELLOW}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${YELLOW}║  DOMAIN SETUP — ACTION REQUIRED IN COOLIFY UI               ║${NC}"
    echo -e "${YELLOW}╠══════════════════════════════════════════════════════════════╣${NC}"
    echo -e "${YELLOW}║${NC}  .env updated with APP_URL and ACME email."
    echo -e "${YELLOW}║${NC}  To activate the domain + SSL via Traefik, you must set"
    echo -e "${YELLOW}║${NC}  the domain inside the Coolify dashboard:"
    echo -e "${YELLOW}║${NC}"
    echo -e "${YELLOW}║${NC}  1. Open:  ${BOLD}http://${server_ip}:8000${NC}"
    echo -e "${YELLOW}║${NC}  2. Complete the one-time onboarding (if not done yet)"
    echo -e "${YELLOW}║${NC}  3. Go to: Settings → General → Instance's Domain"
    echo -e "${YELLOW}║${NC}  4. Enter: ${BOLD}https://${domain}${NC}"
    echo -e "${YELLOW}║${NC}  5. Click Save"
    echo -e "${YELLOW}║${NC}"
    echo -e "${YELLOW}║${NC}  Coolify will configure Traefik and issue the SSL cert"
    echo -e "${YELLOW}║${NC}  automatically. The cert may take 1-2 minutes to provision."
    echo -e "${YELLOW}╚══════════════════════════════════════════════════════════════╝${NC}"
    echo ""

    CUSTOM_DOMAIN="$domain"
    INITIAL_ACCESS_IP="$server_ip"
}

# Determine if we should run domain config
CUSTOM_DOMAIN=""
INITIAL_ACCESS_IP=""
FINAL_EMAIL="${ROOT_USER_EMAIL:-}"

if [ -n "$ARG_DOMAIN" ]; then
    # Use email from args or from the install step
    DOMAIN_EMAIL="${ARG_EMAIL:-${ROOT_USER_EMAIL:-}}"
    if [ -z "$DOMAIN_EMAIL" ]; then
        read -p "  Enter email for SSL certificate (Let's Encrypt): " DOMAIN_EMAIL
    fi
    configure_domain "$ARG_DOMAIN" "$DOMAIN_EMAIL"
    FINAL_EMAIL="${DOMAIN_EMAIL}"
else
    echo ""
    read -p "Do you want to configure a custom domain with SSL now? (y/n) [default: n]: " DOMAIN_CHOICE
    if [[ "${DOMAIN_CHOICE:-n}" =~ ^[Yy]$ ]]; then
        while true; do
            read -p "  Enter your domain (e.g. coolify.example.com): " USER_DOMAIN
            if validate_domain "$USER_DOMAIN"; then
                break
            fi
        done
        DOMAIN_EMAIL="${ROOT_USER_EMAIL:-}"
        if [ -z "$DOMAIN_EMAIL" ]; then
            while true; do
                read -p "  Enter email for SSL certificate: " DOMAIN_EMAIL
                if validate_email "$DOMAIN_EMAIL"; then
                    break
                fi
                print_error "Invalid email. Try again."
            done
        fi
        configure_domain "$USER_DOMAIN" "$DOMAIN_EMAIL"
        FINAL_EMAIL="${DOMAIN_EMAIL}"
    fi
fi

# ====================================================================
# STEP 7 — FINAL SUMMARY
# ====================================================================
print_step "STEP 7 — FINAL SUMMARY"

# Determine dashboard URL
PUBLIC_IP=$(curl -4 -fsSL https://ifconfig.me 2>/dev/null || curl -4 -fsSL https://api.ipify.org 2>/dev/null || echo "<server-ip>")
if [ -n "$CUSTOM_DOMAIN" ]; then
    DASHBOARD_URL="https://${CUSTOM_DOMAIN}"
    INITIAL_URL="http://${PUBLIC_IP}:8000"
else
    DASHBOARD_URL="http://${PUBLIC_IP}:8000"
    INITIAL_URL="$DASHBOARD_URL"
fi

echo ""
echo -e "${GREEN}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║            COOLIFY SETUP COMPLETE                            ║${NC}"
echo -e "${GREEN}╠══════════════════════════════════════════════════════════════╣${NC}"
echo -e "${GREEN}║${NC}  Initial access: ${BOLD}${INITIAL_URL}${NC}"
if [ -n "$CUSTOM_DOMAIN" ]; then
echo -e "${GREEN}║${NC}  After UI setup: ${BOLD}${DASHBOARD_URL}${NC}"
fi
echo -e "${GREEN}║${NC}  Admin user:     ${BOLD}${ROOT_USERNAME}${NC}"
echo -e "${GREEN}║${NC}  Admin email:    ${BOLD}${FINAL_EMAIL}${NC}"
echo -e "${GREEN}╠══════════════════════════════════════════════════════════════╣${NC}"
echo -e "${GREEN}║  NEXT STEPS                                                  ║${NC}"
echo -e "${GREEN}╠══════════════════════════════════════════════════════════════╣${NC}"
if [ -n "$CUSTOM_DOMAIN" ]; then
echo -e "${GREEN}║${NC}  1. Open ${BOLD}${INITIAL_URL}${NC} and complete first-time setup"
echo -e "${GREEN}║${NC}     Then: Settings → General → Instance's Domain"
echo -e "${GREEN}║${NC}     Enter: ${BOLD}https://${CUSTOM_DOMAIN}${NC} → Save"
echo -e "${GREEN}║${NC}     Traefik will configure SSL automatically."
else
echo -e "${GREEN}║${NC}  1. Open the dashboard and complete first-time setup"
fi
echo -e "${GREEN}║${NC}  2. Go to Settings → Servers → Add Server"
echo -e "${GREEN}║${NC}     Add each of your existing VPS servers:"
echo -e "${GREEN}║${NC}       - safepro-lb    → Load Balancer VPS IP"
echo -e "${GREEN}║${NC}       - safepro-app   → Laravel App VPS IP"
echo -e "${GREEN}║${NC}       - safepro-core  → MySQL + Redis + MinIO VPS IP"
echo -e "${GREEN}║${NC}     For each: paste the server's SSH private key."
echo -e "${GREEN}║${NC}     Coolify will validate SSH connectivity automatically."
echo -e "${GREEN}║${NC}  3. Enable Sentinel on each server"
echo -e "${GREEN}║${NC}     (Server Settings → Enable Sentinel)"
echo -e "${GREEN}║${NC}     This activates CPU / RAM / disk monitoring."
echo -e "${GREEN}║${NC}  4. View real-time logs per server from the Logs tab."
echo -e "${GREEN}║${NC}  5. Use the Terminal tab for direct shell access."
echo -e "${GREEN}╚══════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "${BLUE}Useful commands:${NC}"
echo "  Coolify logs:     docker logs coolify -f"
echo "  All containers:   docker ps"
echo "  UFW status:       ufw status verbose"
echo "  SSH config:       cat /etc/ssh/sshd_config | grep -E 'Pubkey|TcpFwd|Gateway|RootLogin'"
if [ -n "$CUSTOM_DOMAIN" ]; then
    echo "  Traefik dashboard: http://localhost:8080 (if enabled in Coolify)"
    echo "  SSL certs:         Let's Encrypt via Traefik — check Coolify UI"
fi
echo ""
