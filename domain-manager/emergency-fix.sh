#!/bin/bash

# Emergency SSL Fix
# Use when SSL certificates are broken or missing

set -e

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

print_status() { echo -e "${GREEN}[✓]${NC} $1"; }
print_error() { echo -e "${RED}[✗]${NC} $1"; }
print_info() { echo -e "${BLUE}[i]${NC} $1"; }

if [[ $EUID -ne 0 ]]; then
   print_error "Run as root: sudo $0"
   exit 1
fi

echo -e "${RED}╔════════════════════════════════════════╗${NC}"
echo -e "${RED}║       Emergency SSL Fix Tool           ║${NC}"
echo -e "${RED}╚════════════════════════════════════════╝${NC}"
echo ""

print_info "Available projects:"
ls -1 /etc/nginx/sites-available/ | grep -v default | grep -v backup | nl
echo ""

read -p "Project name: " PROJECT_NAME
NGINX_CONFIG="/etc/nginx/sites-available/$PROJECT_NAME"

if [ ! -f "$NGINX_CONFIG" ]; then
    print_error "Not found: $NGINX_CONFIG"
    exit 1
fi

# Backup
BACKUP="${NGINX_CONFIG}.emergency.$(date +%Y%m%d_%H%M%S)"
cp "$NGINX_CONFIG" "$BACKUP"
print_status "Backup: $BACKUP"

# Extract info
ALL_DOMAINS=$(grep -m 1 "^\s*server_name" "$NGINX_CONFIG" | sed 's/.*server_name \(.*\);/\1/' | xargs)
WEB_ROOT=$(grep -m 1 "^\s*root" "$NGINX_CONFIG" | sed 's/.*root \(.*\);/\1/' | xargs)
PHP_VERSION=$(grep -oP 'php\K[0-9.]+' "$NGINX_CONFIG" | head -1)
PHP_VERSION=${PHP_VERSION:-8.4}

print_info "Domains: $ALL_DOMAINS"
print_info "Web root: $WEB_ROOT"
print_info "PHP version: $PHP_VERSION"

# Create clean HTTP config
print_info "Creating clean HTTP-only config..."

cat > "$NGINX_CONFIG" <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name $ALL_DOMAINS;
    root $WEB_ROOT;

    index index.php index.html;
    
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-Content-Type-Options "nosniff" always;
    
    client_max_body_size 100M;
    charset utf-8;

    location ^~ /livewire/ {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    location ~* \.(?:css|js|gif|png|jpg|jpeg|webp|ico|cur|bmp|svg|woff2|woff|ttf|eot|otf)$ {
        add_header 'Access-Control-Allow-Origin' '*' always;
        add_header 'Access-Control-Allow-Methods' 'GET, OPTIONS' always;
        add_header 'Access-Control-Allow-Headers' '*' always;
        add_header 'Access-Control-Max-Age' '86400' always;
        expires 1M;
        access_log off;
        try_files \$uri =404;
    }

    location ~ ^/logs/ {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    location = /favicon.ico { access_log off; log_not_found off; }
    location = /robots.txt  { access_log off; log_not_found off; }

    error_page 404 /index.php;

    location ~ ^/index\.php(/|$) {
        fastcgi_pass unix:/var/run/php/php${PHP_VERSION}-fpm.sock;
        fastcgi_param SCRIPT_FILENAME \$realpath_root\$fastcgi_script_name;
        include fastcgi_params;
        fastcgi_hide_header X-Powered-By;
    }

    location ~ /\.(?!well-known).* {
        deny all;
        access_log off;
        log_not_found off;
    }

    location ~* \.(env|log|ini|sql|bak|old|sh)$ {
        location ~ ^/(logs|api)/ {
            try_files \$uri \$uri/ /index.php?\$query_string;
        }
        deny all;
        access_log off;
        log_not_found off;
    }
}
EOF

if ! nginx -t 2>&1; then
    print_error "Nginx test failed! Restoring backup..."
    cp "$BACKUP" "$NGINX_CONFIG"
    exit 1
fi

systemctl reload nginx
print_status "Nginx reloaded (HTTP-only)"

# Get SSL
read -ra DOMAIN_ARRAY <<< "$ALL_DOMAINS"
CERTBOT_DOMAINS=""
for domain in "${DOMAIN_ARRAY[@]}"; do
    CERTBOT_DOMAINS="$CERTBOT_DOMAINS -d $domain"
done

print_info "Obtaining SSL certificates..."

if certbot --nginx $CERTBOT_DOMAINS --non-interactive --agree-tos --redirect; then
    print_status "SSL configured!"
    systemctl reload nginx
    
    echo ""
    echo -e "${GREEN}All domains with HTTPS:${NC}"
    for domain in "${DOMAIN_ARRAY[@]}"; do
        echo "  ✓ https://$domain"
    done
    
    echo ""
    print_info "Testing URLs..."
    for domain in "${DOMAIN_ARRAY[@]}"; do
        CODE=$(curl -s -o /dev/null -w "%{http_code}" -L --max-time 10 "https://$domain" 2>/dev/null || echo "000")
        if [ "$CODE" = "200" ] || [ "$CODE" = "302" ] || [ "$CODE" = "301" ]; then
            echo -e "  https://$domain - ${GREEN}OK ($CODE)${NC}"
        else
            echo -e "  https://$domain - ${YELLOW}$CODE${NC}"
        fi
    done
    
    echo ""
    print_status "Emergency fix complete!"
else
    print_error "Certbot failed! Check DNS and firewall."
    exit 1
fi
