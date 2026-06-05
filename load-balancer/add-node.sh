#!/bin/bash

# Add App Server Script
# Registers a new Laravel app server into the existing running cluster.
# - Adds the new server's IP to VPS1 Nginx upstream (load balancer)
# - Opens UFW ports on VPS3 (core server) for MySQL, Redis, MinIO
# Must be run from a machine that has SSH access to both VPS1 and VPS3.

set -e

# ===============================
# Colors for terminal output
# ===============================
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

print_status()  { echo -e "${GREEN}[INFO]${NC} $1"; }
print_error()   { echo -e "${RED}[ERROR]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
print_section() { echo -e "\n${BLUE}=== $1 ===${NC}\n"; }

# ===============================
# Error Handler
# ===============================
handle_error() {
    print_error "Script failed at step: $1"
    print_error "Please check the output above and re-run after fixing the issue."
    exit 1
}
trap 'handle_error "$BASH_COMMAND"' ERR

# ===============================
# Pre-flight Checks
# ===============================
print_section "Pre-flight Checks"

if [[ $EUID -ne 0 ]]; then
    print_error "This script must be run as root. Try using sudo."
    exit 1
fi

for cmd in ssh sed grep; do
    if ! command -v "$cmd" &>/dev/null; then
        print_error "Required command not found: $cmd"
        exit 1
    fi
done
print_status "Required commands available"

# ===============================
# Configuration
# ===============================
print_section "Configuration"

read -p "Enter the new app server's private IP: " NEW_APP_IP
if [ -z "$NEW_APP_IP" ]; then
    print_error "New app server IP is required."
    exit 1
fi
print_status "New app server IP: $NEW_APP_IP"

read -p "SSH user for VPS1 and VPS3 [default: root]: " SSH_USER
SSH_USER=${SSH_USER:-root}

read -p "SSH key path [default: ~/.ssh/id_ed25519]: " SSH_KEY
SSH_KEY=${SSH_KEY:-~/.ssh/id_ed25519}
# Expand tilde manually so it works in ssh -i
SSH_KEY="${SSH_KEY/#\~/$HOME}"

read -p "VPS1 (Load Balancer) private IP: " VPS1_IP
if [ -z "$VPS1_IP" ]; then
    print_error "VPS1 IP is required."
    exit 1
fi

read -p "VPS3 (Core Server) private IP: " VPS3_IP
if [ -z "$VPS3_IP" ]; then
    print_error "VPS3 IP is required."
    exit 1
fi

read -p "Nginx config path on VPS1 [default: /etc/nginx/sites-available/loadbalancer.conf]: " NGINX_CONF
NGINX_CONF=${NGINX_CONF:-/etc/nginx/sites-available/loadbalancer.conf}

print_status "SSH user:        $SSH_USER"
print_status "SSH key:         $SSH_KEY"
print_status "VPS1 (LB):       $VPS1_IP"
print_status "VPS3 (Core):     $VPS3_IP"
print_status "Nginx conf:      $NGINX_CONF"

# ===============================
# Verify SSH Key Exists
# ===============================
if [ ! -f "$SSH_KEY" ]; then
    print_error "SSH key not found: $SSH_KEY"
    exit 1
fi
print_status "SSH key found"

SSH_OPTS="-i $SSH_KEY -o StrictHostKeyChecking=no -o ConnectTimeout=10 -o BatchMode=yes"

# ===============================
# Test SSH Connectivity
# ===============================
print_section "Testing SSH Connectivity"

print_status "Testing SSH to VPS1 ($VPS1_IP)..."
if ! ssh $SSH_OPTS "${SSH_USER}@${VPS1_IP}" "echo OK" &>/dev/null; then
    print_error "Cannot SSH into VPS1 at ${SSH_USER}@${VPS1_IP}"
    print_error "Check the SSH key, user, and that VPS1 is reachable."
    exit 1
fi
print_status "VPS1 SSH connection: OK"

print_status "Testing SSH to VPS3 ($VPS3_IP)..."
if ! ssh $SSH_OPTS "${SSH_USER}@${VPS3_IP}" "echo OK" &>/dev/null; then
    print_error "Cannot SSH into VPS3 at ${SSH_USER}@${VPS3_IP}"
    print_error "Check the SSH key, user, and that VPS3 is reachable."
    exit 1
fi
print_status "VPS3 SSH connection: OK"

# ===============================
# Step 2 — Add to VPS1 Nginx Upstream
# ===============================
print_section "Adding New Server to VPS1 Nginx Upstream"

print_status "Checking if $NEW_APP_IP is already in the upstream block..."
ALREADY_IN_UPSTREAM=$(ssh $SSH_OPTS "${SSH_USER}@${VPS1_IP}" \
    "grep -c 'server ${NEW_APP_IP}:80;' '${NGINX_CONF}' 2>/dev/null || echo 0")

if [ "$ALREADY_IN_UPSTREAM" -gt 0 ]; then
    print_warning "$NEW_APP_IP is already present in the Nginx upstream — skipping insertion"
else
    print_status "Inserting 'server ${NEW_APP_IP}:80;' into upstream laravel_app block..."

    # Use sed to insert the new server line after the "least_conn;" line inside the upstream block.
    # This is safe for repeated runs because we already checked for duplicates above.
    ssh $SSH_OPTS "${SSH_USER}@${VPS1_IP}" \
        "sed -i '/upstream laravel_app {/{n; /least_conn;/{a\\    server ${NEW_APP_IP}:80;
}}' '${NGINX_CONF}'"

    # Verify insertion
    VERIFY=$(ssh $SSH_OPTS "${SSH_USER}@${VPS1_IP}" \
        "grep -c 'server ${NEW_APP_IP}:80;' '${NGINX_CONF}' 2>/dev/null || echo 0")
    if [ "$VERIFY" -eq 0 ]; then
        print_error "Insertion verification failed — 'server ${NEW_APP_IP}:80;' not found after edit."
        print_error "Please manually add it to the upstream block in ${NGINX_CONF} on VPS1."
        exit 1
    fi
    print_status "Upstream entry added: server ${NEW_APP_IP}:80;"
fi

print_status "Testing Nginx configuration on VPS1..."
if ! ssh $SSH_OPTS "${SSH_USER}@${VPS1_IP}" "nginx -t 2>&1"; then
    print_error "Nginx config test failed on VPS1!"
    exit 1
fi

print_status "Reloading Nginx on VPS1..."
ssh $SSH_OPTS "${SSH_USER}@${VPS1_IP}" "systemctl reload nginx"

# Verify Nginx is still active after reload
NGINX_STATUS=$(ssh $SSH_OPTS "${SSH_USER}@${VPS1_IP}" \
    "systemctl is-active nginx 2>/dev/null || echo inactive")
if [ "$NGINX_STATUS" != "active" ]; then
    print_error "Nginx is not active after reload on VPS1!"
    exit 1
fi
print_status "Nginx reloaded successfully — $NEW_APP_IP is now in the upstream pool"

# ===============================
# Step 3 — Add UFW Rules on VPS3
# ===============================
print_section "Adding UFW Rules on VPS3 Core Server"

print_status "Opening port 3306 (MySQL) for $NEW_APP_IP on VPS3..."
ssh $SSH_OPTS "${SSH_USER}@${VPS3_IP}" \
    "ufw allow from '${NEW_APP_IP}' to any port 3306 proto tcp comment 'MySQL from ${NEW_APP_IP}'"

print_status "Opening port 6379 (Redis) for $NEW_APP_IP on VPS3..."
ssh $SSH_OPTS "${SSH_USER}@${VPS3_IP}" \
    "ufw allow from '${NEW_APP_IP}' to any port 6379 proto tcp comment 'Redis from ${NEW_APP_IP}'"

print_status "Opening port 9000 (MinIO API) for $NEW_APP_IP on VPS3..."
ssh $SSH_OPTS "${SSH_USER}@${VPS3_IP}" \
    "ufw allow from '${NEW_APP_IP}' to any port 9000 proto tcp comment 'MinIO API from ${NEW_APP_IP}'"

print_status "Verifying UFW rules on VPS3..."
UFW_OUTPUT=$(ssh $SSH_OPTS "${SSH_USER}@${VPS3_IP}" "ufw status")

MISSING_RULES=()
echo "$UFW_OUTPUT" | grep -q "${NEW_APP_IP}.*3306" || MISSING_RULES+=("3306/MySQL")
echo "$UFW_OUTPUT" | grep -q "${NEW_APP_IP}.*6379" || MISSING_RULES+=("6379/Redis")
echo "$UFW_OUTPUT" | grep -q "${NEW_APP_IP}.*9000" || MISSING_RULES+=("9000/MinIO")

if [ ${#MISSING_RULES[@]} -gt 0 ]; then
    print_warning "The following rules were not confirmed in ufw status output:"
    for r in "${MISSING_RULES[@]}"; do
        print_warning "  - $r"
    done
    print_warning "Run 'ufw status verbose' on VPS3 to check manually."
else
    print_status "All UFW rules confirmed for $NEW_APP_IP on VPS3"
fi

# ===============================
# Final Summary
# ===============================
echo ""
echo -e "${BLUE}============================================================${NC}"
echo -e "${GREEN}  Add App Server Complete!${NC}"
echo -e "${BLUE}============================================================${NC}"
echo ""
print_status "=== What Was Done ==="
print_status "  New App Server IP:         $NEW_APP_IP"
print_status "  VPS1 Nginx upstream:       server ${NEW_APP_IP}:80; added"
print_status "  VPS3 UFW port 3306:        allowed from $NEW_APP_IP"
print_status "  VPS3 UFW port 6379:        allowed from $NEW_APP_IP"
print_status "  VPS3 UFW port 9000:        allowed from $NEW_APP_IP"
echo ""
print_status "=== Next Steps ==="
print_status "  1. SSH into the new server ($NEW_APP_IP) and run setup-app.sh"
print_status "  2. When prompted, select role: Secondary"
print_status "  3. When prompted for VPS1 (Load Balancer) private IP, enter: $VPS1_IP"
print_status "  4. When prompted for VPS4/VPS3 (Core Server) private IP, enter: $VPS3_IP"
print_status "  5. After setup completes, run deploy-all.sh to deploy the application"
echo ""
print_status "=== Useful Commands ==="
print_status "  VPS1 upstream check:  ssh ${SSH_USER}@${VPS1_IP} 'grep -A10 upstream ${NGINX_CONF}'"
print_status "  VPS3 UFW check:       ssh ${SSH_USER}@${VPS3_IP} 'ufw status verbose'"
print_status "  Nginx reload:         ssh ${SSH_USER}@${VPS1_IP} 'nginx -t && systemctl reload nginx'"
echo -e "${BLUE}============================================================${NC}"
