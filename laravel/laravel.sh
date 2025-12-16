#!/bin/bash

# Laravel Project Auto-installer Script (Private Repo Supported)
# Installs Laravel, PHP 8.3, Nginx, MySQL, Certbot
# Supports cloning private GitHub repos with PAT authentication

set -e

# ===============================
# User Input Section
# ===============================

# PHP Version Selection
echo "Select PHP Version:"
echo "1) PHP 8.2"
echo "2) PHP 8.3"
echo "3) PHP 8.4"
read -p "Enter your choice (1-3) [default: 2]: " PHP_CHOICE
PHP_CHOICE=${PHP_CHOICE:-2}

case $PHP_CHOICE in
    1) PHP_VERSION="8.2" ;;
    2) PHP_VERSION="8.3" ;;
    3) PHP_VERSION="8.4" ;;
    *) PHP_VERSION="8.3" ;;
esac

echo -e "\033[0;32m[INFO]\033[0m Selected PHP version: $PHP_VERSION"

# Project Configuration
read -p "Enter Project Name [default: laravel-app]: " PROJECT_NAME
PROJECT_NAME=${PROJECT_NAME:-laravel-app}

read -p "Enter Server Domain(s) (comma-separated for multiple, e.g., example.com,www.example.com): " SERVER_DOMAINS_INPUT
if [ -z "$SERVER_DOMAINS_INPUT" ]; then
    echo "Error: At least one domain is required."
    exit 1
fi

# Convert comma-separated domains to array
IFS=',' read -ra DOMAIN_ARRAY <<< "$SERVER_DOMAINS_INPUT"
SERVER_DOMAIN="${DOMAIN_ARRAY[0]}"  # Primary domain
echo -e "\033[0;32m[INFO]\033[0m Primary domain: $SERVER_DOMAIN"
if [ ${#DOMAIN_ARRAY[@]} -gt 1 ]; then
    echo -e "\033[0;32m[INFO]\033[0m Additional domains: ${DOMAIN_ARRAY[@]:1}"
fi

# Detect if this is a multi-subdomain setup and extract root domain
ROOT_DOMAIN=""
if [ ${#DOMAIN_ARRAY[@]} -gt 1 ]; then
    # Check if all domains share the same root domain (subdomain setup)
    FIRST_ROOT=$(echo "$SERVER_DOMAIN" | rev | cut -d'.' -f1-2 | rev)
    ALL_SAME_ROOT=true
    for domain in "${DOMAIN_ARRAY[@]}"; do
        CURRENT_ROOT=$(echo "$domain" | rev | cut -d'.' -f1-2 | rev)
        if [ "$CURRENT_ROOT" != "$FIRST_ROOT" ]; then
            ALL_SAME_ROOT=false
            break
        fi
    done
    
    if [ "$ALL_SAME_ROOT" = true ]; then
        ROOT_DOMAIN="$FIRST_ROOT"
        echo -e "\033[0;32m[INFO]\033[0m Detected multi-subdomain setup. Root domain: $ROOT_DOMAIN"
    fi
fi

# Database Configuration
read -p "Enter Database Name [default: laravel_db]: " DB_NAME
DB_NAME=${DB_NAME:-laravel_db}

read -p "Enter Database Username [default: laravel_user]: " DB_USER
DB_USER=${DB_USER:-laravel_user}

read -sp "Enter Database Password (leave empty to auto-generate): " DB_PASSWORD
echo
if [ -z "$DB_PASSWORD" ]; then
    DB_PASSWORD="$(openssl rand -base64 12 | tr -d "=+/" | cut -c1-16)"
    echo -e "\033[0;33m[INFO]\033[0m Auto-generated database password: $DB_PASSWORD"
fi

read -p "Enter Web Root Directory [default: /var/www]: " WEB_ROOT
WEB_ROOT=${WEB_ROOT:-/var/www}

read -p "Enable SSL with Certbot? (y/n) [default: y]: " ENABLE_SSL_INPUT
ENABLE_SSL_INPUT=${ENABLE_SSL_INPUT:-y}
if [[ "$ENABLE_SSL_INPUT" =~ ^[Yy]$ ]]; then
    ENABLE_SSL=true
else
    ENABLE_SSL=false
fi

# ===============================
# Production Environment Setup
# ===============================
echo ""
echo "Environment Configuration:"
read -p "Is this a PRODUCTION deployment? (y/n) [default: y]: " IS_PRODUCTION
IS_PRODUCTION=${IS_PRODUCTION:-y}

if [[ "$IS_PRODUCTION" =~ ^[Yy]$ ]]; then
    APP_ENV="production"
    APP_DEBUG="false"
    echo -e "\033[0;32m[INFO]\033[0m Production mode: APP_ENV=production, APP_DEBUG=false"
else
    read -p "Enter APP_ENV [default: local]: " APP_ENV
    APP_ENV=${APP_ENV:-local}
    read -p "Enable APP_DEBUG? (y/n) [default: y]: " APP_DEBUG_INPUT
    APP_DEBUG_INPUT=${APP_DEBUG_INPUT:-y}
    if [[ "$APP_DEBUG_INPUT" =~ ^[Yy]$ ]]; then
        APP_DEBUG="true"
    else
        APP_DEBUG="false"
    fi
    echo -e "\033[0;32m[INFO]\033[0m Development mode: APP_ENV=$APP_ENV, APP_DEBUG=$APP_DEBUG"
fi

# ===============================
# Git Clone Method Selection
# ===============================
echo ""
echo "Select Git Clone Method:"
echo "1) SSH (recommended for VPS - uses SSH keys)"
echo "2) HTTPS (uses Personal Access Token)"
read -p "Enter your choice (1-2) [default: 1]: " GIT_METHOD
GIT_METHOD=${GIT_METHOD:-1}

if [ "$GIT_METHOD" = "1" ]; then
    # SSH Method
    read -p "Enter your GitHub SSH URL (e.g., git@github.com:OWNER/REPO.git): " GITHUB_REPO_URL
    
    # Verify SSH key exists
    if [ ! -f ~/.ssh/id_rsa ] && [ ! -f ~/.ssh/id_ed25519 ]; then
        echo -e "\033[0;33m[WARNING]\033[0m No SSH key found. Generating new SSH key..."
        read -p "Enter your email for SSH key: " SSH_EMAIL
        ssh-keygen -t ed25519 -C "$SSH_EMAIL" -f ~/.ssh/id_ed25519 -N ""
        echo -e "\033[0;32m[INFO]\033[0m SSH public key generated. Add this to your GitHub account:"
        cat ~/.ssh/id_ed25519.pub
        read -p "Press Enter after adding the SSH key to GitHub..."
    fi
    
    # Add GitHub to known hosts
    ssh-keyscan github.com >> ~/.ssh/known_hosts 2>/dev/null
    
else
    # HTTPS Method
    read -p "Enter your GitHub Username: " GITHUB_USER
    read -sp "Enter your GitHub Token (PAT): " GITHUB_TOKEN
    echo
    read -p "Enter your GitHub Repo URL (e.g., https://github.com/OWNER/REPO): " GITHUB_REPO_URL_INPUT
    
    # Construct Authenticated Repo URL
    GITHUB_REPO_URL="https://$GITHUB_USER:$GITHUB_TOKEN@${GITHUB_REPO_URL_INPUT#https://}"
    [[ "$GITHUB_REPO_URL" != *.git ]] && GITHUB_REPO_URL="${GITHUB_REPO_URL}.git"
fi

echo -e "\033[0;32m[INFO]\033[0m Repository URL configured"

# ===============================
# Colors for terminal output
# ===============================
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
NC='\033[0m'

print_status() { echo -e "${GREEN}[INFO]${NC} $1"; }
print_error() { echo -e "${RED}[ERROR]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }

# Function to extract root domain from subdomain
# e.g., panel.safeprovpn.com -> safeprovpn.com
extract_root_domain() {
    local domain="$1"
    # Count dots in domain
    local dot_count=$(echo "$domain" | tr -cd '.' | wc -c)
    
    if [ "$dot_count" -ge 2 ]; then
        # Has subdomain, extract root domain (last two parts)
        echo "$domain" | rev | cut -d'.' -f1-2 | rev
    else
        # Already a root domain
        echo "$domain"
    fi
}

# ===============================
# Verify Repository Access
# ===============================
print_status "Verifying repository access..."

if [ "$GIT_METHOD" = "1" ]; then
    # Test SSH connection to GitHub
    if ! ssh -T git@github.com 2>&1 | grep -q "successfully authenticated"; then
        print_error "SSH connection to GitHub failed!"
        print_error "Please ensure your SSH key is added to your GitHub account."
        exit 1
    fi
    print_status "SSH connection to GitHub verified!"
    
    # Test repository access with ls-remote
    if ! git ls-remote "$GITHUB_REPO_URL" HEAD &>/dev/null; then
        print_error "Cannot access repository: $GITHUB_REPO_URL"
        print_error "Please verify the repository URL and your access permissions."
        exit 1
    fi
else
    # Test HTTPS repository access
    if ! git ls-remote "$GITHUB_REPO_URL" HEAD &>/dev/null; then
        print_error "Cannot access repository!"
        print_error "Please verify:"
        print_error "  1. Repository URL is correct"
        print_error "  2. GitHub token has proper permissions (repo scope)"
        print_error "  3. Token is not expired"
        exit 1
    fi
fi

print_status "Repository access verified successfully!"
echo ""

# ===============================
# Script logic
# ===============================

# Must run as root
if [[ $EUID -ne 0 ]]; then
   print_error "This script must be run as root. Try using sudo."
   exit 1
fi

# Update system
print_status "Updating system packages..."
apt-get update
apt-get upgrade -y

# Add PHP repo
print_status "Adding PHP repository..."
apt-get install -y software-properties-common
add-apt-repository -y ppa:ondrej/php
apt-get update

# Core PHP extensions required for Laravel
# Note: json, tokenizer, pdo are built into PHP 8.0+ and should not be installed separately
CORE_EXTENSIONS=("cli" "common" "curl" "mbstring" "mysql" "xml" "zip" "fpm" "bcmath")

# Optional PHP extensions
OPTIONAL_EXTENSIONS=("gd" "intl" "soap" "redis" "memcached" "imagick" "ldap" "imap")

print_status "Installing PHP $PHP_VERSION with core extensions..."

# Build core installation command
PHP_PACKAGES="php${PHP_VERSION}"
for ext in "${CORE_EXTENSIONS[@]}"; do
    PHP_PACKAGES="$PHP_PACKAGES php${PHP_VERSION}-${ext}"
done

apt-get install -y $PHP_PACKAGES unzip curl git

# Ask for additional extensions
echo ""
echo "Available optional PHP extensions: ${OPTIONAL_EXTENSIONS[*]}"
read -p "Enter additional extensions to install (space-separated, or press Enter to skip): " EXTRA_EXTENSIONS

if [ ! -z "$EXTRA_EXTENSIONS" ]; then
    print_status "Installing additional PHP extensions..."
    for ext in $EXTRA_EXTENSIONS; do
        apt-get install -y php${PHP_VERSION}-${ext} 2>/dev/null || echo -e "${YELLOW}[WARNING]${NC} Extension php${PHP_VERSION}-${ext} not available"
    done
fi

# Install Composer
print_status "Installing Composer..."
curl -sS https://getcomposer.org/installer | php
mv composer.phar /usr/local/bin/composer
chmod +x /usr/local/bin/composer

# Install MySQL
print_status "Installing MySQL..."
apt-get install -y mysql-server
systemctl enable --now mysql

# Create database and user
print_status "Setting up database..."
mysql -e "CREATE DATABASE IF NOT EXISTS \`$DB_NAME\`;"

# Drop user if exists to avoid conflicts, then create with proper password
mysql -e "DROP USER IF EXISTS '$DB_USER'@'localhost';"
mysql -e "CREATE USER '$DB_USER'@'localhost' IDENTIFIED BY '$DB_PASSWORD';"
mysql -e "GRANT ALL PRIVILEGES ON \`$DB_NAME\`.* TO '$DB_USER'@'localhost';"
mysql -e "FLUSH PRIVILEGES;"

# Test database connection
print_status "Testing database connection..."
if mysql -u"$DB_USER" -p"$DB_PASSWORD" -e "USE \`$DB_NAME\`;" 2>/dev/null; then
    print_status "Database connection successful!"
else
    print_error "Database connection failed! Please check credentials."
    exit 1
fi

# Install Nginx + Certbot
print_status "Installing Nginx & Certbot..."
apt-get install -y nginx certbot python3-certbot-nginx

# ===============================
# Redis Setup
# ===============================
read -p "Install and configure Redis? (y/n) [default: n]: " INSTALL_REDIS
REDIS_ENABLED=false

if [[ "$INSTALL_REDIS" =~ ^[Yy]$ ]]; then
    print_status "Installing Redis..."
    apt-get install -y redis-server
    
    # Install PHP Redis extension if not already installed
    apt-get install -y php${PHP_VERSION}-redis 2>/dev/null || print_status "PHP Redis extension already installed"
    
    # Configure Redis for production
    print_status "Configuring Redis..."
    sed -i 's/^supervised no/supervised systemd/' /etc/redis/redis.conf
    sed -i 's/^# maxmemory <bytes>/maxmemory 256mb/' /etc/redis/redis.conf
    sed -i 's/^# maxmemory-policy noeviction/maxmemory-policy allkeys-lru/' /etc/redis/redis.conf
    
    systemctl enable redis-server
    systemctl restart redis-server
    
    REDIS_ENABLED=true
    
    # Ask what to use Redis for
    echo ""
    echo "Configure Redis for:"
    read -p "  Use Redis for Cache? (y/n) [default: y]: " REDIS_CACHE
    REDIS_CACHE=${REDIS_CACHE:-y}
    
    read -p "  Use Redis for Queue? (y/n) [default: y]: " REDIS_QUEUE
    REDIS_QUEUE=${REDIS_QUEUE:-y}
    
    read -p "  Use Redis for Sessions? (y/n) [default: y]: " REDIS_SESSION
    REDIS_SESSION=${REDIS_SESSION:-y}
    
    print_status "Redis installed and configured!"
fi

# Clone repo
print_status "Cloning your GitHub repository..."
mkdir -p $WEB_ROOT
cd $WEB_ROOT
rm -rf $PROJECT_NAME 2>/dev/null || true
git clone $GITHUB_REPO_URL $PROJECT_NAME
cd $PROJECT_NAME

# Laravel setup
print_status "Installing Laravel dependencies..."
export COMPOSER_ALLOW_SUPERUSER=1
composer install --no-interaction --prefer-dist --optimize-autoloader --no-dev

# Permissions
print_status "Setting up file permissions..."
chown -R www-data:www-data $WEB_ROOT/$PROJECT_NAME
chmod -R 755 $WEB_ROOT/$PROJECT_NAME
chmod -R 775 $WEB_ROOT/$PROJECT_NAME/storage $WEB_ROOT/$PROJECT_NAME/bootstrap/cache

# Configure .env
print_status "Configuring .env file..."
cp .env.example .env

# Escape special characters for sed
ESC_DB_PASSWORD=$(printf '%s\n' "$DB_PASSWORD" | sed 's/[[\/.*^$]/\\&/g')
ESC_DB_NAME=$(printf '%s\n' "$DB_NAME" | sed 's/[[\/.*^$]/\\&/g')
ESC_DB_USER=$(printf '%s\n' "$DB_USER" | sed 's/[[\/.*^$]/\\&/g')

# Determine APP_URL - use root domain if multi-subdomain setup detected
if [ ! -z "$ROOT_DOMAIN" ]; then
    SUGGESTED_APP_URL="https://${ROOT_DOMAIN}"
    echo ""
    echo "Multi-subdomain setup detected."
    echo "Suggested APP_URL: $SUGGESTED_APP_URL"
    read -p "Use this APP_URL? (y/n) [default: y]: " USE_ROOT_URL
    USE_ROOT_URL=${USE_ROOT_URL:-y}
    if [[ "$USE_ROOT_URL" =~ ^[Yy]$ ]]; then
        FINAL_APP_URL="$SUGGESTED_APP_URL"
    else
        read -p "Enter custom APP_URL [default: https://${SERVER_DOMAIN}]: " CUSTOM_URL
        FINAL_APP_URL=${CUSTOM_URL:-https://${SERVER_DOMAIN}}
    fi
else
    FINAL_APP_URL="https://${SERVER_DOMAIN}"
fi
print_status "Setting APP_URL to: $FINAL_APP_URL"

# Set environment variables
sed -i "s|APP_NAME=.*|APP_NAME=$PROJECT_NAME|g" .env
sed -i "s|APP_ENV=.*|APP_ENV=$APP_ENV|g" .env
sed -i "s|APP_DEBUG=.*|APP_DEBUG=$APP_DEBUG|g" .env
sed -i "s|APP_URL=.*|APP_URL=$FINAL_APP_URL|g" .env

# Database configuration
sed -i "s|DB_DATABASE=.*|DB_DATABASE=$ESC_DB_NAME|g" .env
sed -i "s|DB_USERNAME=.*|DB_USERNAME=$ESC_DB_USER|g" .env
sed -i "s|DB_PASSWORD=.*|DB_PASSWORD=$ESC_DB_PASSWORD|g" .env

# Additional production optimizations
if [[ "$IS_PRODUCTION" =~ ^[Yy]$ ]]; then
    print_status "Applying production optimizations..."
    # Set log channel to daily for production
    sed -i "s|LOG_CHANNEL=.*|LOG_CHANNEL=daily|g" .env
    sed -i "s|LOG_LEVEL=.*|LOG_LEVEL=warning|g" .env
fi

# Configure Redis in .env if enabled
if [ "$REDIS_ENABLED" = true ]; then
    print_status "Configuring Redis in .env..."
    
    # Set Redis connection details
    sed -i "s|REDIS_HOST=.*|REDIS_HOST=127.0.0.1|g" .env
    sed -i "s|REDIS_PASSWORD=.*|REDIS_PASSWORD=null|g" .env
    sed -i "s|REDIS_PORT=.*|REDIS_PORT=6379|g" .env
    
    # Configure cache driver
    if [[ "$REDIS_CACHE" =~ ^[Yy]$ ]]; then
        sed -i "s|CACHE_DRIVER=.*|CACHE_DRIVER=redis|g" .env
        sed -i "s|CACHE_STORE=.*|CACHE_STORE=redis|g" .env
        print_status "  - Cache driver set to Redis"
    fi
    
    # Configure queue driver
    if [[ "$REDIS_QUEUE" =~ ^[Yy]$ ]]; then
        sed -i "s|QUEUE_CONNECTION=.*|QUEUE_CONNECTION=redis|g" .env
        print_status "  - Queue driver set to Redis"
    fi
    
    # Configure session driver
    if [[ "$REDIS_SESSION" =~ ^[Yy]$ ]]; then
        sed -i "s|SESSION_DRIVER=.*|SESSION_DRIVER=redis|g" .env
        print_status "  - Session driver set to Redis"
    fi
fi

# Laravel key + migrations
print_status "Generating Laravel application key..."
php artisan key:generate

print_status "Creating storage symbolic link..."
php artisan storage:link

print_status "Running database migrations..."
php artisan migrate --force

read -p "Run database seeders? (y/n) [default: n]: " RUN_SEEDERS
if [[ "$RUN_SEEDERS" =~ ^[Yy]$ ]]; then
    print_status "Running database seeders..."
    php artisan db:seed --force
fi

# ===============================
# Queue & Scheduler Setup
# ===============================
read -p "Set up Laravel Queue Workers with Supervisor? (y/n) [default: n]: " SETUP_QUEUE
read -p "Set up Laravel Scheduler (cron job)? (y/n) [default: n]: " SETUP_SCHEDULER

if [[ "$SETUP_QUEUE" =~ ^[Yy]$ ]] || [[ "$SETUP_SCHEDULER" =~ ^[Yy]$ ]]; then
    print_status "Installing Supervisor..."
    apt-get install -y supervisor
    systemctl enable supervisor
fi

if [[ "$SETUP_QUEUE" =~ ^[Yy]$ ]]; then
    print_status "Configuring Queue Workers with Supervisor..."
    
    # Clean up old supervisor config for this project
    if [ -f "/etc/supervisor/conf.d/${PROJECT_NAME}-worker.conf" ]; then
        print_status "Removing old supervisor configuration..."
        supervisorctl stop ${PROJECT_NAME}-worker:* 2>/dev/null || true
        rm -f /etc/supervisor/conf.d/${PROJECT_NAME}-worker.conf
        supervisorctl reread 2>/dev/null || true
        supervisorctl update 2>/dev/null || true
    fi
    
    read -p "Enter number of queue workers [default: 2]: " NUM_WORKERS
    NUM_WORKERS=${NUM_WORKERS:-2}
    
    # Determine default queue connection based on Redis setup
    if [ "$REDIS_ENABLED" = true ] && [[ "$REDIS_QUEUE" =~ ^[Yy]$ ]]; then
        DEFAULT_QUEUE="redis"
    else
        DEFAULT_QUEUE="database"
    fi
    
    read -p "Enter queue connection [default: $DEFAULT_QUEUE]: " QUEUE_CONNECTION
    QUEUE_CONNECTION=${QUEUE_CONNECTION:-$DEFAULT_QUEUE}
    
    # Create supervisor configuration for Laravel queue
    cat > /etc/supervisor/conf.d/${PROJECT_NAME}-worker.conf <<EOF
[program:${PROJECT_NAME}-worker]
process_name=%(program_name)s_%(process_num)02d
command=php ${WEB_ROOT}/${PROJECT_NAME}/artisan queue:work ${QUEUE_CONNECTION} --sleep=3 --tries=3 --max-time=3600
autostart=true
autorestart=true
stopasgroup=true
killasgroup=true
user=www-data
numprocs=${NUM_WORKERS}
redirect_stderr=true
stdout_logfile=${WEB_ROOT}/${PROJECT_NAME}/storage/logs/worker.log
stopwaitsecs=3600
EOF

    # Update .env with queue configuration
    sed -i "s|QUEUE_CONNECTION=.*|QUEUE_CONNECTION=${QUEUE_CONNECTION}|g" ${WEB_ROOT}/${PROJECT_NAME}/.env
    
    # Create queue table if using database driver
    if [ "$QUEUE_CONNECTION" = "database" ]; then
        echo ""
        echo "Database queue driver selected."
        read -p "Create queue tables? (Skip if already exists) (y/n) [default: y]: " CREATE_QUEUE_TABLE
        CREATE_QUEUE_TABLE=${CREATE_QUEUE_TABLE:-y}
        
        if [[ "$CREATE_QUEUE_TABLE" =~ ^[Yy]$ ]]; then
            print_status "Creating queue tables..."
            cd ${WEB_ROOT}/${PROJECT_NAME}
            php artisan queue:table 2>/dev/null || print_warning "Queue migration already exists"
            php artisan migrate --force
        else
            print_status "Skipping queue table creation"
        fi
    fi
    
    # Reload supervisor
    supervisorctl reread
    supervisorctl update
    supervisorctl start ${PROJECT_NAME}-worker:*
    
    print_status "Queue workers configured and started!"
fi

if [[ "$SETUP_SCHEDULER" =~ ^[Yy]$ ]]; then
    print_status "Setting up Laravel Scheduler..."
    
    # Clean up old cron jobs for this project first
    print_status "Cleaning up old scheduler entries..."
    EXISTING_CRON=$(crontab -u www-data -l 2>/dev/null || echo "")
    
    # Add cron job for Laravel scheduler
    CRON_COMMAND="* * * * * cd ${WEB_ROOT}/${PROJECT_NAME} && php artisan schedule:run >> /dev/null 2>&1"
    
    # Remove old entries for this project and add new one
    (echo "$EXISTING_CRON" | grep -v "${WEB_ROOT}/${PROJECT_NAME}/artisan schedule:run" | grep -v "^$"; echo "$CRON_COMMAND") | crontab -u www-data -
    
    print_status "Laravel Scheduler configured! Cron job added for www-data user."
    print_status "Current crontab for www-data:"
    crontab -u www-data -l 2>/dev/null || echo "(empty)"
fi

# Configure Nginx
print_status "Configuring Nginx..."

# Clean up old/conflicting Nginx configurations
print_status "Cleaning up old Nginx configurations..."
# Remove any existing symlinks in sites-enabled (except default which we handle separately)
find /etc/nginx/sites-enabled/ -type l ! -name "default" -delete 2>/dev/null || true
# Remove old config files that might conflict with our domains
for domain in "${DOMAIN_ARRAY[@]}"; do
    rm -f /etc/nginx/sites-available/$domain 2>/dev/null || true
done

# Build server_name directive with all domains
ALL_DOMAINS=$(IFS=' '; echo "${DOMAIN_ARRAY[*]}")

cat > /etc/nginx/sites-available/$PROJECT_NAME <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name ${ALL_DOMAINS};
    root $WEB_ROOT/$PROJECT_NAME/public;

    add_header X-Frame-Options "SAMEORIGIN";
    add_header X-Content-Type-Options "nosniff";

    index index.php;

    charset utf-8;
    
    # Upload size limit
    client_max_body_size 100M;

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
    }
}
EOF

ln -sf /etc/nginx/sites-available/$PROJECT_NAME /etc/nginx/sites-enabled/
rm -f /etc/nginx/sites-enabled/default

# Verify Nginx configuration before restarting
print_status "Testing Nginx configuration..."
if ! nginx -t; then
    print_error "Nginx configuration test failed!"
    print_error "Please check the configuration:"
    cat /etc/nginx/sites-available/$PROJECT_NAME
    exit 1
fi

print_status "Restarting Nginx..."
systemctl restart nginx

# Verify Nginx started successfully
if ! systemctl is-active --quiet nginx; then
    print_error "Nginx failed to start!"
    print_error "Checking Nginx status..."
    systemctl status nginx --no-pager
    exit 1
fi

print_status "Nginx is running successfully!"

# SSL setup
if [ "$ENABLE_SSL" = true ]; then
    print_status "Setting up SSL with Certbot for domains: $ALL_DOMAINS"
    
    # Build domain arguments for certbot
    CERTBOT_DOMAINS=""
    for domain in "${DOMAIN_ARRAY[@]}"; do
        CERTBOT_DOMAINS="$CERTBOT_DOMAINS -d $domain"
    done
    
    read -p "Enter email for SSL certificates [default: webmaster@$SERVER_DOMAIN]: " SSL_EMAIL
    SSL_EMAIL=${SSL_EMAIL:-webmaster@$SERVER_DOMAIN}
    
    # Run Certbot with error handling
    if certbot --nginx --non-interactive --agree-tos --redirect \
        --email $SSL_EMAIL $CERTBOT_DOMAINS; then
        print_status "SSL certificates installed successfully!"
        
        # Verify SSL certificates were created
        if [ -d "/etc/letsencrypt/live/$SERVER_DOMAIN" ]; then
            print_status "SSL certificate verified for $SERVER_DOMAIN"
            
            # Restart Nginx to ensure SSL is active
            systemctl restart nginx
            
            # Test SSL auto-renew
            print_status "Testing SSL auto-renew..."
            certbot renew --dry-run || echo -e "${YELLOW}[WARNING]${NC} SSL auto-renew test failed, but certificates are installed"
        else
            echo -e "${YELLOW}[WARNING]${NC} SSL certificate directory not found, but Certbot reported success"
        fi
    else
        echo -e "${YELLOW}[WARNING]${NC} SSL certificate installation failed!"
        echo -e "${YELLOW}[WARNING]${NC} Your site is accessible via HTTP only."
        echo -e "${YELLOW}[WARNING]${NC} Common causes:"
        echo -e "${YELLOW}[WARNING]${NC}   1. DNS not pointing to this server yet"
        echo -e "${YELLOW}[WARNING]${NC}   2. Port 80 not accessible from internet"
        echo -e "${YELLOW}[WARNING]${NC}   3. Firewall blocking connections"
        echo -e "${YELLOW}[WARNING]${NC} You can retry SSL setup later with:"
        echo -e "${YELLOW}[WARNING]${NC}   certbot --nginx -d ${ALL_DOMAINS// / -d }"
        ENABLE_SSL=false
    fi
fi

# Restart PHP-FPM
systemctl enable php${PHP_VERSION}-fpm
systemctl restart php${PHP_VERSION}-fpm

# Laravel optimize
print_status "Optimizing Laravel..."
php artisan config:cache
php artisan route:cache
php artisan view:cache

print_status "====================================================="
print_status "Installation completed successfully!"
print_status "====================================================="
print_status "Access your Laravel app at:"
for domain in "${DOMAIN_ARRAY[@]}"; do
    if [ "$ENABLE_SSL" = true ]; then
        print_status "  - https://$domain"
    else
        print_status "  - http://$domain"
    fi
done

if [ ! -z "$ROOT_DOMAIN" ]; then
    print_status ""
    print_status "APP_URL: $FINAL_APP_URL"
fi
print_status ""
print_status "Environment: $APP_ENV (DEBUG: $APP_DEBUG)"

if [ "$REDIS_ENABLED" = true ]; then
    print_status ""
    print_status "Redis: Enabled"
    [[ "$REDIS_CACHE" =~ ^[Yy]$ ]] && print_status "  - Cache: Redis"
    [[ "$REDIS_QUEUE" =~ ^[Yy]$ ]] && print_status "  - Queue: Redis"
    [[ "$REDIS_SESSION" =~ ^[Yy]$ ]] && print_status "  - Session: Redis"
    print_status "  - Status: systemctl status redis-server"
fi
print_status "Database Details:"
print_status "  Name: $DB_NAME"
print_status "  User: $DB_USER"
print_status "  Password: $DB_PASSWORD"
print_status ""
print_status "PHP Version: $PHP_VERSION"
print_status "Project Path: $WEB_ROOT/$PROJECT_NAME"

if [[ "$SETUP_QUEUE" =~ ^[Yy]$ ]]; then
    print_status ""
    print_status "Queue Workers: Enabled ($NUM_WORKERS workers)"
    print_status "  Connection: $QUEUE_CONNECTION"
    print_status "  Status: supervisorctl status ${PROJECT_NAME}-worker:*"
    print_status "  Logs: $WEB_ROOT/$PROJECT_NAME/storage/logs/worker.log"
fi

if [[ "$SETUP_SCHEDULER" =~ ^[Yy]$ ]]; then
    print_status ""
    print_status "Laravel Scheduler: Enabled"
    print_status "  Cron: Every minute as www-data user"
fi

print_status "====================================================="
