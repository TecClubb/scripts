#!/bin/bash

# ============================================================
#  Termix VPS Setup Script
#  By TecClub Technology
# ============================================================

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

print_banner() {
  echo -e "${CYAN}"
  echo "  ████████╗███████╗ ██████╗███╗   ███╗██╗██╗  ██╗"
  echo "     ██╔══╝██╔════╝██╔════╝████╗ ████║██║╚██╗██╔╝"
  echo "     ██║   █████╗  ██║     ██╔████╔██║██║ ╚███╔╝ "
  echo "     ██║   ██╔══╝  ██║     ██║╚██╔╝██║██║ ██╔██╗ "
  echo "     ██║   ███████╗╚██████╗██║ ╚═╝ ██║██║██╔╝ ██╗"
  echo "     ╚═╝   ╚══════╝ ╚═════╝╚═╝     ╚═╝╚═╝╚═╝  ╚═╝"
  echo -e "${NC}"
  echo -e "${BOLD}  Termix VPS Setup Script${NC}"
  echo -e "  ${BLUE}https://termix.site${NC}"
  echo ""
}

print_step() {
  echo -e "\n${BLUE}${BOLD}==>${NC} ${BOLD}$1${NC}"
}

print_success() {
  echo -e "${GREEN}  ✔ $1${NC}"
}

print_warning() {
  echo -e "${YELLOW}  ⚠ $1${NC}"
}

print_error() {
  echo -e "${RED}  ✘ $1${NC}"
}

ask() {
  echo -e "${CYAN}  → $1${NC}"
  read -r "$2"
}

ask_yn() {
  while true; do
    echo -e "${CYAN}  → $1 (y/n):${NC} \c"
    read -r yn
    case $yn in
      [Yy]*) return 0 ;;
      [Nn]*) return 1 ;;
      *) echo -e "${YELLOW}  Please enter y or n.${NC}" ;;
    esac
  done
}

# ============================================================
print_banner

echo -e "${BOLD}This script will:${NC}"
echo "  - Install Docker (if not installed)"
echo "  - Set up Termix with Docker Compose"
echo "  - Optionally configure Nginx + SSL"
echo ""

if ! ask_yn "Continue with setup?"; then
  echo "Aborted."
  exit 0
fi

# ============================================================
print_step "Configuration"

ask "Enter the port to run Termix on (default: 8080):" TERMIX_PORT
TERMIX_PORT=${TERMIX_PORT:-8080}

if ask_yn "Do you want to set up Nginx reverse proxy with SSL?"; then
  SETUP_NGINX=true
  ask "Enter your domain (e.g. termix.yourdomain.com):" TERMIX_DOMAIN
  ask "Enter your email for SSL certificate:" SSL_EMAIL
else
  SETUP_NGINX=false
fi

if ask_yn "Enable Guacamole (RDP/VNC remote desktop support)?"; then
  ENABLE_GUACD=true
else
  ENABLE_GUACD=false
fi

echo ""
echo -e "${BOLD}  Summary:${NC}"
echo "  Port        : $TERMIX_PORT"
echo "  Nginx + SSL : $SETUP_NGINX"
if [ "$SETUP_NGINX" = true ]; then
  echo "  Domain      : $TERMIX_DOMAIN"
  echo "  SSL Email   : $SSL_EMAIL"
fi
echo "  Guacamole   : $ENABLE_GUACD"
echo ""

if ! ask_yn "Looks good? Start setup?"; then
  echo "Aborted."
  exit 0
fi

# ============================================================
print_step "Installing Docker"

if command -v docker &>/dev/null; then
  print_success "Docker already installed ($(docker --version))"
else
  curl -fsSL https://get.docker.com | sh
  print_success "Docker installed"
fi

# ============================================================
print_step "Creating Termix directory"

mkdir -p /opt/termix
cd /opt/termix
print_success "Directory: /opt/termix"

# ============================================================
print_step "Writing docker-compose.yml"

if [ "$ENABLE_GUACD" = true ]; then
  cat > /opt/termix/docker-compose.yml <<EOF
services:

  termix:
    image: ghcr.io/lukegus/termix:latest
    container_name: termix
    restart: unless-stopped
    ports:
      - '${TERMIX_PORT}:8080'
    volumes:
      - termix-data:/app/data
    environment:
      PORT: '8080'
    depends_on:
      - guacd
    networks:
      - termix-net

  guacd:
    image: guacamole/guacd:1.6.0
    container_name: guacd
    restart: unless-stopped
    ports:
      - "4822:4822"
    networks:
      - termix-net

volumes:
  termix-data:
    driver: local

networks:
  termix-net:
    driver: bridge
EOF
else
  cat > /opt/termix/docker-compose.yml <<EOF
services:

  termix:
    image: ghcr.io/lukegus/termix:latest
    container_name: termix
    restart: unless-stopped
    ports:
      - '${TERMIX_PORT}:8080'
    volumes:
      - termix-data:/app/data
    environment:
      PORT: '8080'

volumes:
  termix-data:
    driver: local
EOF
fi

print_success "docker-compose.yml written"

# ============================================================
print_step "Starting Termix containers"

docker compose up -d
print_success "Containers started"

# ============================================================
if [ "$SETUP_NGINX" = true ]; then
  print_step "Installing Nginx and Certbot"

  apt-get update -qq
  apt-get install -y nginx certbot python3-certbot-nginx -qq
  print_success "Nginx and Certbot installed"

  print_step "Writing Nginx config"

  cat > /etc/nginx/sites-available/termix <<EOF
server {
    listen 80;
    server_name ${TERMIX_DOMAIN};

    location / {
        proxy_pass http://localhost:${TERMIX_PORT};
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
EOF

  ln -sf /etc/nginx/sites-available/termix /etc/nginx/sites-enabled/termix

  nginx -t && systemctl reload nginx
  print_success "Nginx configured"

  print_step "Obtaining SSL certificate"

  certbot --nginx -d "$TERMIX_DOMAIN" --email "$SSL_EMAIL" --agree-tos --non-interactive
  print_success "SSL certificate obtained"

  print_step "Configuring firewall"

  if command -v ufw &>/dev/null; then
    ufw allow 'Nginx Full' > /dev/null
    ufw delete allow "$TERMIX_PORT" > /dev/null 2>&1 || true
    print_success "Firewall updated (port $TERMIX_PORT closed, Nginx allowed)"
  else
    print_warning "ufw not found, skipping firewall config"
  fi

fi

# ============================================================
print_step "Verifying containers"

docker compose ps

# ============================================================
echo ""
echo -e "${GREEN}${BOLD}============================================================${NC}"
echo -e "${GREEN}${BOLD}  Termix setup complete!${NC}"
echo -e "${GREEN}${BOLD}============================================================${NC}"
echo ""

if [ "$SETUP_NGINX" = true ]; then
  echo -e "  ${BOLD}Access URL:${NC}   https://${TERMIX_DOMAIN}"
else
  SERVER_IP=$(curl -s ifconfig.me 2>/dev/null || hostname -I | awk '{print $1}')
  echo -e "  ${BOLD}Access URL:${NC}   http://${SERVER_IP}:${TERMIX_PORT}"
fi

echo ""
echo -e "  ${BOLD}Useful commands:${NC}"
echo "  docker compose -f /opt/termix/docker-compose.yml ps       # check status"
echo "  docker compose -f /opt/termix/docker-compose.yml restart  # restart"
echo "  docker compose -f /opt/termix/docker-compose.yml logs -f  # view logs"
echo ""
echo -e "  ${BOLD}Backup data:${NC}"
echo "  docker run --rm -v termix_termix-data:/data -v /opt/termix:/backup alpine \\"
echo "    tar czf /backup/termix-backup.tar.gz /data"
echo ""