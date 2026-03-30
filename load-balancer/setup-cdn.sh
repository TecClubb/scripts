#!/bin/bash

# CDN Setup Script
# Run on VPS4 first, then on VPS1
#
# VPS4 role: opens MinIO port to VPS1, makes bucket publicly readable
# VPS1 role: splits cdn subdomain into its own nginx block proxying to MinIO, adds SSL

set -e

# ===============================
# Colors
# ===============================
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

print_status()  { echo -e "${GREEN}[✓]${NC} $1"; }
print_error()   { echo -e "${RED}[✗]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[!]${NC} $1"; }
print_info()    { echo -e "${BLUE}[ℹ]${NC} $1"; }
print_section() { echo -e "\n${BLUE}=== $1 ===${NC}\n"; }

handle_error() {
    print_error "Script failed at: $1"
    print_error "Fix the issue above and re-run."
    exit 1
}
trap 'handle_error "$BASH_COMMAND"' ERR

# ===============================
# Pre-flight
# ===============================
if [[ $EUID -ne 0 ]]; then
    print_error "Run as root (sudo)."
    exit 1
fi

# ===============================
# Role selection
# ===============================
echo ""
echo "======================================"
echo "   CDN Setup Script"
echo "======================================"
echo ""
echo "Select which server you are running this on:"
echo "  1) VPS4 — Core server  (opens firewall + makes MinIO bucket public)"
echo "  2) VPS1 — Load balancer (splits cdn subdomain → nginx proxy + SSL)"
read -p "Enter (1-2): " ROLE_CHOICE

case "$ROLE_CHOICE" in
    1) ROLE="vps4" ;;
    2) ROLE="vps1" ;;
    *)
        print_error "Invalid choice."
        exit 1
        ;;
esac

# ======================================================
# VPS4 ROLE
# ======================================================
if [ "$ROLE" = "vps4" ]; then

    print_section "VPS4 — Firewall + MinIO bucket policy"

    # -----------------------------------------------
    # Inputs
    # -----------------------------------------------
    read -p "Enter VPS1 (load balancer) public/private IP: " VPS1_IP
    if [ -z "$VPS1_IP" ]; then
        print_error "VPS1 IP is required."
        exit 1
    fi

    read -p "Enter MinIO private IP (this server's private IP) [default: 127.0.0.1]: " MINIO_IP
    MINIO_IP=${MINIO_IP:-127.0.0.1}

    read -p "Enter MinIO admin username [default: minioadmin]: " MINIO_USER
    MINIO_USER=${MINIO_USER:-minioadmin}

    read -sp "Enter MinIO admin password: " MINIO_PASSWORD
    echo
    if [ -z "$MINIO_PASSWORD" ]; then
        print_error "MinIO password is required."
        exit 1
    fi

    read -p "Enter MinIO bucket name [default: laravel-bucket]: " MINIO_BUCKET
    MINIO_BUCKET=${MINIO_BUCKET:-laravel-bucket}

    # -----------------------------------------------
    # UFW rule for VPS1
    # -----------------------------------------------
    print_section "Opening MinIO port to VPS1"

    if ! command -v ufw &>/dev/null; then
        print_error "UFW is not installed."
        exit 1
    fi

    ufw allow from "$VPS1_IP" to any port 9000 proto tcp comment 'VPS1 MinIO CDN access'
    print_status "UFW: port 9000 open to $VPS1_IP"
    ufw status verbose

    # -----------------------------------------------
    # Install mc if not present
    # -----------------------------------------------
    print_section "Setting bucket policy via mc"

    if ! command -v mc &>/dev/null; then
        print_info "Installing mc (MinIO client)..."
        curl -fsSL https://dl.min.io/client/mc/release/linux-amd64/mc -o /usr/local/bin/mc
        chmod +x /usr/local/bin/mc
        print_status "mc installed"
    else
        print_status "mc already installed"
    fi

    # -----------------------------------------------
    # Set alias and bucket policy
    # -----------------------------------------------
    mc alias set myminio "http://${MINIO_IP}:9000" "$MINIO_USER" "$MINIO_PASSWORD" --api S3v4

    if mc ls "myminio/${MINIO_BUCKET}" &>/dev/null; then
        print_status "Bucket '${MINIO_BUCKET}' found"
    else
        print_warning "Bucket '${MINIO_BUCKET}' not found — creating it..."
        mc mb "myminio/${MINIO_BUCKET}"
        print_status "Bucket created"
    fi

    mc anonymous set download "myminio/${MINIO_BUCKET}"
    print_status "Bucket '${MINIO_BUCKET}' set to public read (anonymous download)"

    # -----------------------------------------------
    # Summary
    # -----------------------------------------------
    echo ""
    echo "======================================"
    print_status "VPS4 CDN setup complete!"
    echo "======================================"
    echo ""
    print_info "  UFW port 9000:   open to $VPS1_IP"
    print_info "  Bucket policy:   anonymous download on ${MINIO_BUCKET}"
    echo ""
    print_info "Now run this script on VPS1 with role '2'."
    echo ""
fi

# ======================================================
# VPS1 ROLE
# ======================================================
if [ "$ROLE" = "vps1" ]; then

    print_section "VPS1 — nginx CDN proxy + SSL"

    # -----------------------------------------------
    # Inputs
    # -----------------------------------------------
    read -p "Enter CDN subdomain [default: cdn.example.com]: " CDN_DOMAIN
    if [ -z "$CDN_DOMAIN" ]; then
        print_error "CDN domain is required."
        exit 1
    fi

    read -p "Enter VPS4 private IP (MinIO host): " VPS4_IP
    if [ -z "$VPS4_IP" ]; then
        print_error "VPS4 IP is required."
        exit 1
    fi

    read -p "Enter SSL email for Certbot: " SSL_EMAIL
    if [ -z "$SSL_EMAIL" ]; then
        print_error "SSL email is required."
        exit 1
    fi

    # -----------------------------------------------
    # Check nginx is running
    # -----------------------------------------------
    print_section "Checking Nginx"

    if ! command -v nginx &>/dev/null; then
        print_error "Nginx is not installed. Run vps-loadbalancer.sh first."
        exit 1
    fi

    if ! systemctl is-active --quiet nginx; then
        systemctl start nginx
    fi
    print_status "Nginx is running"

    NGINX_CONF="/etc/nginx/sites-available/loadbalancer.conf"
    if [ ! -f "$NGINX_CONF" ]; then
        print_error "Load balancer config not found at $NGINX_CONF"
        print_error "Run vps-loadbalancer.sh first."
        exit 1
    fi

    # -----------------------------------------------
    # Remove cdn domain from existing server_name lines
    # -----------------------------------------------
    print_section "Removing $CDN_DOMAIN from main load balancer block"

    cp "$NGINX_CONF" "${NGINX_CONF}.bak.$(date +%Y%m%d_%H%M%S)"
    print_status "Backup created: ${NGINX_CONF}.bak.*"

    # Remove CDN domain only from server_name directives (not Certbot if-blocks)
    sed -i "/^\s*server_name/s/ \?${CDN_DOMAIN}//g" "$NGINX_CONF"
    print_status "$CDN_DOMAIN removed from existing server_name entries"

    # Also remove any Certbot-generated if ($host = CDN_DOMAIN) redirect block
    # (3-line block: if line, return line, closing brace + comment)
    sed -i "/if (\\\$host = ${CDN_DOMAIN})/{N;N;d}" "$NGINX_CONF"
    print_status "Certbot redirect block for $CDN_DOMAIN removed"

    # -----------------------------------------------
    # Write CDN server block
    # -----------------------------------------------
    print_section "Writing CDN proxy server block"

    CDN_CONF="/etc/nginx/sites-available/cdn-proxy.conf"

    cat > "$CDN_CONF" <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name ${CDN_DOMAIN};

    client_max_body_size 500M;
    proxy_buffering off;
    proxy_request_buffering off;

    location / {
        proxy_pass http://${VPS4_IP}:9000;
        proxy_set_header Host \$http_host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;

        # CORS headers for browser asset loading
        add_header Access-Control-Allow-Origin "*" always;
        add_header Access-Control-Allow-Methods "GET, HEAD, OPTIONS" always;
    }
}
EOF

    ln -sf "$CDN_CONF" /etc/nginx/sites-enabled/cdn-proxy.conf
    print_status "CDN proxy config written: $CDN_CONF"

    # -----------------------------------------------
    # Test and reload nginx
    # -----------------------------------------------
    print_info "Testing Nginx config..."
    nginx -t
    systemctl reload nginx
    print_status "Nginx reloaded"

    # -----------------------------------------------
    # Certbot SSL
    # -----------------------------------------------
    print_section "Installing SSL for $CDN_DOMAIN"

    if ! command -v certbot &>/dev/null; then
        print_info "Installing Certbot..."
        apt-get install -y certbot python3-certbot-nginx -qq
        print_status "Certbot installed"
    fi

    print_info "Running Certbot dry-run..."
    if certbot certonly --nginx --dry-run --non-interactive --agree-tos \
        --email "$SSL_EMAIL" -d "$CDN_DOMAIN" 2>/dev/null; then
        print_status "Dry-run passed — requesting real certificate..."
        certbot --nginx --non-interactive --agree-tos --redirect \
            --email "$SSL_EMAIL" -d "$CDN_DOMAIN"
        print_status "SSL certificate installed for $CDN_DOMAIN"
    else
        print_warning "Certbot dry-run failed."
        print_warning "Ensure DNS for $CDN_DOMAIN points to this server's public IP."
        print_warning "Retry later: certbot --nginx -d $CDN_DOMAIN"
    fi

    nginx -t && systemctl reload nginx

    # -----------------------------------------------
    # Summary
    # -----------------------------------------------
    echo ""
    echo "======================================"
    print_status "VPS1 CDN proxy setup complete!"
    echo "======================================"
    echo ""
    print_info "  CDN domain:   https://${CDN_DOMAIN}"
    print_info "  Proxies to:   http://${VPS4_IP}:9000"
    print_info "  Nginx config: $CDN_CONF"
    echo ""
    print_info "Update your app server .env:"
    echo ""
    echo "  CDN_URL=https://${CDN_DOMAIN}"
    echo "  AWS_ENDPOINT=https://${CDN_DOMAIN}"
    echo ""
    print_info "Then on the app server:"
    echo "  php artisan config:clear && php artisan optimize"
    echo ""
    print_info "Test a file URL:"
    echo "  curl -I https://${CDN_DOMAIN}/<your-bucket>/<any-file>"
    echo ""
fi
