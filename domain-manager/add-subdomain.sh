#!/bin/bash

# Add Subdomain to Laravel App with SSL
# Simple, reliable script for adding new subdomains

set -e

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

print_status() { echo -e "${GREEN}[✓]${NC} $1"; }
print_error() { echo -e "${RED}[✗]${NC} $1"; }
print_info() { echo -e "${BLUE}[i]${NC} $1"; }

# Check root
if [[ $EUID -ne 0 ]]; then
   print_error "Run as root: sudo $0"
   exit 1
fi

echo -e "${BLUE}╔════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║   Add Subdomain to Laravel App        ║${NC}"
echo -e "${BLUE}╚════════════════════════════════════════╝${NC}"
echo ""

# List projects
print_info "Available projects:"
ls -1 /etc/nginx/sites-available/ | grep -v default | grep -v backup | nl
echo ""

read -p "Project name: " PROJECT_NAME
NGINX_CONFIG="/etc/nginx/sites-available/$PROJECT_NAME"

if [ ! -f "$NGINX_CONFIG" ]; then
    print_error "Config not found: $NGINX_CONFIG"
    exit 1
fi

# Get current domains
CURRENT_DOMAINS=$(grep -m 1 "^\s*server_name" "$NGINX_CONFIG" | sed 's/.*server_name \(.*\);/\1/' | xargs)
print_info "Current domains: $CURRENT_DOMAINS"

# Get new subdomains
echo ""
read -p "New subdomain(s) (comma-separated): " NEW_INPUT

if [ -z "$NEW_INPUT" ]; then
    print_error "No subdomains provided!"
    exit 1
fi

# Convert to array and trim
IFS=',' read -ra NEW_SUBS <<< "$NEW_INPUT"
for i in "${!NEW_SUBS[@]}"; do
    NEW_SUBS[$i]=$(echo "${NEW_SUBS[$i]}" | xargs)
done

# Combine all domains
ALL_DOMAINS="$CURRENT_DOMAINS ${NEW_SUBS[*]}"
print_info "Updated domains: $ALL_DOMAINS"

# Backup
BACKUP="${NGINX_CONFIG}.backup.$(date +%Y%m%d_%H%M%S)"
cp "$NGINX_CONFIG" "$BACKUP"
print_status "Backup created: $BACKUP"

# Update all server_name directives in the config
awk -v domains="$ALL_DOMAINS" '
    /^\s*server_name/ {
        print "    server_name " domains ";"
        next
    }
    { print }
' "$NGINX_CONFIG" > "${NGINX_CONFIG}.tmp" && mv "${NGINX_CONFIG}.tmp" "$NGINX_CONFIG"

print_status "Updated nginx configuration"

# Test nginx
if ! nginx -t 2>&1; then
    print_error "Nginx test failed! Restoring backup..."
    cp "$BACKUP" "$NGINX_CONFIG"
    exit 1
fi

systemctl reload nginx
print_status "Nginx reloaded"

# SSL setup
echo ""
read -p "Add SSL certificates? (y/n) [default: y]: " ADD_SSL
ADD_SSL=${ADD_SSL:-y}

if [[ "$ADD_SSL" =~ ^[Yy]$ ]]; then
    # Build certbot command
    read -ra ALL_DOMAIN_ARRAY <<< "$ALL_DOMAINS"
    CERTBOT_DOMAINS=""
    for domain in "${ALL_DOMAIN_ARRAY[@]}"; do
        CERTBOT_DOMAINS="$CERTBOT_DOMAINS -d $domain"
    done
    
    print_info "Obtaining SSL for all domains..."
    
    if certbot --nginx $CERTBOT_DOMAINS --non-interactive --agree-tos --redirect --force-renewal; then
        print_status "SSL configured successfully!"
        systemctl reload nginx
    else
        print_error "SSL setup failed!"
        print_info "You can manually run: certbot --nginx $CERTBOT_DOMAINS"
        exit 1
    fi
fi

# Summary
echo ""
echo -e "${GREEN}╔════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║          Setup Complete!               ║${NC}"
echo -e "${GREEN}╚════════════════════════════════════════╝${NC}"
echo ""

echo "Added subdomains:"
for sub in "${NEW_SUBS[@]}"; do
    if [[ "$ADD_SSL" =~ ^[Yy]$ ]]; then
        echo "  ✓ https://$sub"
    else
        echo "  ✓ http://$sub"
    fi
done

echo ""
echo "All configured domains:"
read -ra ALL_DOMAIN_ARRAY <<< "$ALL_DOMAINS"
for domain in "${ALL_DOMAIN_ARRAY[@]}"; do
    if [[ "$ADD_SSL" =~ ^[Yy]$ ]]; then
        echo "  • https://$domain"
    else
        echo "  • http://$domain"
    fi
done

# Test URLs
if [[ "$ADD_SSL" =~ ^[Yy]$ ]]; then
    echo ""
    print_info "Testing URLs..."
    for domain in "${ALL_DOMAIN_ARRAY[@]}"; do
        CODE=$(curl -s -o /dev/null -w "%{http_code}" -L --max-time 10 "https://$domain" 2>/dev/null || echo "000")
        if [ "$CODE" = "200" ] || [ "$CODE" = "302" ] || [ "$CODE" = "301" ]; then
            echo -e "  https://$domain - ${GREEN}OK ($CODE)${NC}"
        else
            echo -e "  https://$domain - ${YELLOW}$CODE${NC}"
        fi
    done
fi

echo ""
print_status "Done!"
