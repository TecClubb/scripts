#!/bin/bash

# VPS1 Load Balancer Setup Script
# Installs Nginx as a reverse proxy / load balancer with least_conn upstream
# Optionally installs SSL via Certbot
# Proxies traffic to any number of app servers via private IPs

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
    print_error "Setup failed at step: $1"
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

if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS=$NAME
    OS_VERSION=$VERSION_ID
else
    print_error "Cannot detect OS. This script requires Ubuntu/Debian."
    exit 1
fi

print_status "Detected OS: $OS $OS_VERSION"

if [[ ! "$OS" =~ (Ubuntu|Debian) ]]; then
    print_warning "This script is designed for Ubuntu/Debian. Proceeding anyway..."
fi

# ===============================
# Configuration
# ===============================
print_section "Configuration"

read -p "Enter Domain(s) (comma-separated, e.g., example.com,www.example.com): " SERVER_DOMAINS_INPUT
if [ -z "$SERVER_DOMAINS_INPUT" ]; then
    print_error "At least one domain is required."
    exit 1
fi

IFS=',' read -ra DOMAIN_ARRAY <<< "$SERVER_DOMAINS_INPUT"
SERVER_DOMAIN="${DOMAIN_ARRAY[0]}"
print_status "Primary domain: $SERVER_DOMAIN"
if [ ${#DOMAIN_ARRAY[@]} -gt 1 ]; then
    print_status "Additional domains: ${DOMAIN_ARRAY[@]:1}"
fi

echo "Enter the private IP of each app server to include in the upstream pool."
echo "At least one is required. Press Enter with an empty value when done."
APP_SERVER_IPS=()
while true; do
    read -p "  App server IP #$((${#APP_SERVER_IPS[@]} + 1)) [press Enter to finish]: " APP_IP
    if [ -z "$APP_IP" ]; then
        if [ ${#APP_SERVER_IPS[@]} -eq 0 ]; then
            print_error "At least one app server IP is required."
            continue
        fi
        break
    fi
    APP_SERVER_IPS+=("$APP_IP")
    print_status "Added: $APP_IP"
done
print_status "${#APP_SERVER_IPS[@]} app server(s) registered: ${APP_SERVER_IPS[*]}"

read -p "Enable SSL with Certbot? (y/n) [default: y]: " ENABLE_SSL_INPUT
ENABLE_SSL_INPUT=${ENABLE_SSL_INPUT:-y}
if [[ "$ENABLE_SSL_INPUT" =~ ^[Yy]$ ]]; then
    ENABLE_SSL=true
else
    ENABLE_SSL=false
fi

if [ "$ENABLE_SSL" = true ]; then
    read -p "Enter email for SSL certificates [default: webmaster@$SERVER_DOMAIN]: " SSL_EMAIL
    SSL_EMAIL=${SSL_EMAIL:-webmaster@$SERVER_DOMAIN}
fi

# ===============================
# Install Base Dependencies
# ===============================
print_section "Installing Base Dependencies"

print_status "Updating package lists..."
apt-get update -qq

BASE_PACKAGES=(
    "curl"
    "wget"
    "software-properties-common"
    "apt-transport-https"
    "ca-certificates"
    "gnupg"
    "lsb-release"
    "ufw"
)

for pkg in "${BASE_PACKAGES[@]}"; do
    if ! dpkg -l | grep -q "^ii  $pkg "; then
        print_status "Installing $pkg..."
        apt-get install -y $pkg -qq
    else
        print_status "$pkg is already installed"
    fi
done

# ===============================
# Install Nginx
# ===============================
print_section "Installing Nginx"

if command -v nginx &> /dev/null; then
    print_status "Nginx is already installed"
else
    print_status "Installing Nginx..."
    apt-get install -y nginx
fi

systemctl enable nginx
systemctl start nginx 2>/dev/null || true

if systemctl is-active --quiet nginx; then
    print_status "Nginx is running"
else
    print_error "Nginx failed to start!"
    exit 1
fi

# ===============================
# Install Certbot (if SSL enabled)
# ===============================
if [ "$ENABLE_SSL" = true ]; then
    print_section "Installing Certbot"

    if command -v certbot &> /dev/null; then
        print_status "Certbot is already installed"
    else
        print_status "Installing Certbot..."
        apt-get install -y certbot python3-certbot-nginx
    fi
fi

# ===============================
# Configure Nginx Load Balancer
# ===============================
print_section "Configuring Nginx Load Balancer"

print_status "Cleaning up old Nginx configurations..."
find /etc/nginx/sites-enabled/ -type l ! -name "default" -delete 2>/dev/null || true

# Build server_name directive with all domains
ALL_DOMAINS=$(IFS=' '; echo "${DOMAIN_ARRAY[*]}")

# Build upstream server entries for Nginx config
UPSTREAM_ENTRIES=""
for APP_IP in "${APP_SERVER_IPS[@]}"; do
    UPSTREAM_ENTRIES="${UPSTREAM_ENTRIES}    server ${APP_IP}:80;"$'\n'
done

print_status "Writing load balancer configuration..."
cat > /etc/nginx/sites-available/loadbalancer.conf <<EOF
upstream laravel_app {
    least_conn;
${UPSTREAM_ENTRIES}}

server {
    listen 80;
    listen [::]:80;
    server_name ${ALL_DOMAINS};

    client_max_body_size 100M;

    # Proxy headers
    proxy_set_header Host \$host;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto \$scheme;

    # Proxy timeouts
    proxy_connect_timeout 60s;
    proxy_send_timeout 60s;
    proxy_read_timeout 60s;

    location / {
        proxy_pass http://laravel_app;
    }
}
EOF

ln -sf /etc/nginx/sites-available/loadbalancer.conf /etc/nginx/sites-enabled/loadbalancer.conf
rm -f /etc/nginx/sites-enabled/default

print_status "Testing Nginx configuration..."
if ! nginx -t; then
    print_error "Nginx configuration test failed!"
    cat /etc/nginx/sites-available/loadbalancer.conf
    exit 1
fi

systemctl reload nginx
print_status "Nginx load balancer configuration applied"

# ===============================
# SSL Setup via Certbot
# ===============================
if [ "$ENABLE_SSL" = true ]; then
    print_section "Setting Up SSL with Certbot"

    print_status "Requesting SSL certificates for: $ALL_DOMAINS"

    # Build domain arguments for certbot
    CERTBOT_DOMAINS=""
    for domain in "${DOMAIN_ARRAY[@]}"; do
        CERTBOT_DOMAINS="$CERTBOT_DOMAINS -d $domain"
    done

    # Run Certbot dry-run first to verify everything is correct
    print_status "Running Certbot dry-run to verify configuration..."
    if certbot certonly --nginx --dry-run --non-interactive --agree-tos \
        --email "$SSL_EMAIL" $CERTBOT_DOMAINS 2>/dev/null; then
        print_status "Certbot dry-run passed — proceeding with real certificate..."

        if certbot --nginx --non-interactive --agree-tos --redirect \
            --email "$SSL_EMAIL" $CERTBOT_DOMAINS; then
            print_status "SSL certificates installed successfully!"

            if [ -d "/etc/letsencrypt/live/$SERVER_DOMAIN" ]; then
                print_status "SSL certificate verified for $SERVER_DOMAIN"
                systemctl restart nginx

                print_status "Testing SSL auto-renew..."
                certbot renew --dry-run || print_warning "SSL auto-renew test failed, but certificates are installed"
            else
                print_warning "SSL certificate directory not found, but Certbot reported success"
            fi
        else
            print_warning "SSL certificate installation failed!"
            print_warning "Your site is accessible via HTTP only."
            print_warning "Common causes:"
            print_warning "  1. DNS not yet pointing to this server's public IP"
            print_warning "  2. Port 80 not accessible from the internet"
            print_warning "  3. Firewall blocking connections"
            print_warning "Retry later with:"
            print_warning "  certbot --nginx -d ${ALL_DOMAINS// / -d }"
            ENABLE_SSL=false
        fi
    else
        print_warning "Certbot dry-run failed — skipping SSL installation"
        print_warning "Ensure DNS is pointing to this server's public IP, then run:"
        print_warning "  certbot --nginx -d ${ALL_DOMAINS// / -d }"
        ENABLE_SSL=false
    fi
fi

# ===============================
# Configure UFW Firewall
# ===============================
print_section "Configuring UFW Firewall"

print_status "Setting up UFW firewall rules..."
ufw --force reset
ufw default deny incoming
ufw default allow outgoing

ufw allow 22/tcp comment 'SSH'
ufw allow 80/tcp comment 'HTTP'
ufw allow 443/tcp comment 'HTTPS'

ufw --force enable
print_status "UFW firewall configured"
ufw status verbose

# ===============================
# Final Summary
# ===============================
echo ""
echo -e "${BLUE}============================================================${NC}"
echo -e "${GREEN}  VPS1 Load Balancer Setup Complete!${NC}"
echo -e "${BLUE}============================================================${NC}"
echo ""
print_status "=== Load Balancer ==="
print_status "  Nginx config:              /etc/nginx/sites-available/loadbalancer.conf"
print_status "  Algorithm:                 least_conn"
for APP_IP in "${APP_SERVER_IPS[@]}"; do
    print_status "  Upstream:                  ${APP_IP}:80"
done
echo ""
print_status "=== Domains ==="
for domain in "${DOMAIN_ARRAY[@]}"; do
    if [ "$ENABLE_SSL" = true ]; then
        print_status "  https://$domain"
    else
        print_status "  http://$domain"
    fi
done
echo ""
print_status "=== SSL ==="
if [ "$ENABLE_SSL" = true ]; then
    print_status "  Status:                    Enabled"
    print_status "  Certificate:               /etc/letsencrypt/live/$SERVER_DOMAIN/"
    print_status "  Auto-renew:                systemctl status certbot.timer"
    print_status "  Manual renew:              certbot renew"
else
    print_warning "  Status:                    Disabled (HTTP only)"
    print_warning "  Enable later:              certbot --nginx -d ${ALL_DOMAINS// / -d }"
fi
echo ""
print_status "=== Firewall ==="
print_status "  Port 22 (SSH):             open to all"
print_status "  Port 80 (HTTP):            open to all"
print_status "  Port 443 (HTTPS):          open to all"
echo ""
print_status "=== Scaling: Adding More App Servers ==="
print_status "  Edit /etc/nginx/sites-available/loadbalancer.conf"
print_status "  Add to upstream laravel_app block:"
print_status "      server NEW_VPS_PRIVATE_IP:80;"
print_status "  Then reload: nginx -t && systemctl reload nginx"
echo ""
print_status "=== Useful Commands ==="
print_status "  Nginx status:   systemctl status nginx"
print_status "  Nginx reload:   nginx -t && systemctl reload nginx"
print_status "  Nginx restart:  systemctl restart nginx"
print_status "  Access logs:    tail -f /var/log/nginx/access.log"
print_status "  Error logs:     tail -f /var/log/nginx/error.log"
print_status "  SSL renew:      certbot renew --dry-run"
print_status "  UFW status:     ufw status verbose"
echo -e "${BLUE}============================================================${NC}"
