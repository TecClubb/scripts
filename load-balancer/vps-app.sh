#!/bin/bash

# Laravel App Server Setup Script (Consolidated)
# Role 1 — Primary:   PHP + Nginx + Laravel + Queue Workers + Scheduler + Migrations
# Role 2 — Secondary: PHP + Nginx + Laravel + Queue Workers (no scheduler, no migrations)
# Secondary mode also supports adding new servers to an existing running cluster.

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
# Configuration — Server Role
# ===============================
print_section "Server Role"

echo "Select server role:"
echo "1) Primary   — runs migrations + sets up Laravel scheduler (use this for your first/main app server)"
echo "2) Secondary — no migrations, no scheduler (use this for all additional app servers)"
read -p "Enter choice (1-2) [default: 1]: " SERVER_ROLE_CHOICE
SERVER_ROLE_CHOICE=${SERVER_ROLE_CHOICE:-1}

if [ "$SERVER_ROLE_CHOICE" = "1" ]; then
    SERVER_ROLE="primary"
else
    SERVER_ROLE="secondary"
fi
print_status "Server role: $SERVER_ROLE"

read -p "Enter a label for this server (used in summary only, e.g. VPS2, app-server-3) [default: ${SERVER_ROLE}-server]: " SERVER_LABEL
SERVER_LABEL=${SERVER_LABEL:-${SERVER_ROLE}-server}

ADDING_TO_CLUSTER=false
THIS_PRIVATE_IP=""
if [ "$SERVER_ROLE" = "secondary" ]; then
    echo ""
    read -p "Is this being added to an existing running cluster? (y/n) [default: n]: " CLUSTER_INPUT
    if [[ "${CLUSTER_INPUT:-n}" =~ ^[Yy]$ ]]; then
        ADDING_TO_CLUSTER=true
        read -p "Enter THIS server's private IP (used in the post-setup reminder): " THIS_PRIVATE_IP
        if [ -z "$THIS_PRIVATE_IP" ]; then
            THIS_PRIVATE_IP="<THIS_SERVER_PRIVATE_IP>"
            print_warning "No IP entered — reminder block will show a placeholder."
        fi
    fi
fi

# ===============================
# Configuration — Application
# ===============================
print_section "Configuration"

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
print_status "Selected PHP version: $PHP_VERSION"

read -p "Enter Project Name [default: laravel-app]: " PROJECT_NAME
PROJECT_NAME=${PROJECT_NAME:-laravel-app}

read -p "Enter Web Root Directory [default: /var/www]: " WEB_ROOT
WEB_ROOT=${WEB_ROOT:-/var/www}

read -p "Enter Domain or IP for server_name (use _ for catch-all) [default: _]: " SERVER_DOMAIN
SERVER_DOMAIN=${SERVER_DOMAIN:-_}

echo ""
echo "VPS4 Core Server:"
read -p "Enter VPS4 private IP: " VPS4_PRIVATE_IP
if [ -z "$VPS4_PRIVATE_IP" ]; then
    print_error "VPS4 private IP is required."
    exit 1
fi

echo ""
echo "Database (on VPS4 MySQL):"
read -p "Enter Database Name [default: laravel_db]: " DB_NAME
DB_NAME=${DB_NAME:-laravel_db}

read -p "Enter Database Username [default: laravel_user]: " DB_USER
DB_USER=${DB_USER:-laravel_user}

read -sp "Enter Database Password: " DB_PASSWORD
echo
if [ -z "$DB_PASSWORD" ]; then
    print_error "Database password is required (configured on VPS4)."
    exit 1
fi

echo ""
echo "Redis (on VPS4):"
read -sp "Enter Redis Password: " REDIS_PASSWORD
echo
if [ -z "$REDIS_PASSWORD" ]; then
    print_error "Redis password is required (configured on VPS4)."
    exit 1
fi

echo ""
echo "MinIO (on VPS4):"
read -p "Enter MinIO Access Key (admin username) [default: minioadmin]: " MINIO_ACCESS_KEY
MINIO_ACCESS_KEY=${MINIO_ACCESS_KEY:-minioadmin}

read -sp "Enter MinIO Secret Key (admin password): " MINIO_SECRET_KEY
echo
if [ -z "$MINIO_SECRET_KEY" ]; then
    print_error "MinIO secret key is required."
    exit 1
fi

read -p "Enter MinIO Bucket Name [default: laravel-bucket]: " MINIO_BUCKET
MINIO_BUCKET=${MINIO_BUCKET:-laravel-bucket}

echo ""
echo "Queue Workers:"
read -p "Enter number of queue workers [default: 2]: " NUM_WORKERS
NUM_WORKERS=${NUM_WORKERS:-2}

read -p "Enter queue connection name [default: redis]: " QUEUE_CONNECTION
QUEUE_CONNECTION=${QUEUE_CONNECTION:-redis}

echo ""
echo "Load Balancer:"
read -p "Enter VPS1 (Load Balancer) private IP: " VPS1_PRIVATE_IP
if [ -z "$VPS1_PRIVATE_IP" ]; then
    print_error "VPS1 private IP is required for UFW rules."
    exit 1
fi

echo ""
echo "GitHub Repository:"
echo "Select Git Clone Method:"
echo "1) SSH (recommended for VPS - uses SSH keys)"
echo "2) HTTPS (uses Personal Access Token)"
read -p "Enter your choice (1-2) [default: 1]: " GIT_METHOD
GIT_METHOD=${GIT_METHOD:-1}

if [ "$GIT_METHOD" = "1" ]; then
    read -p "Enter your GitHub SSH URL (e.g., git@github.com:OWNER/REPO.git): " GITHUB_REPO_URL

    mkdir -p ~/.ssh
    chmod 700 ~/.ssh

    if [ ! -f ~/.ssh/id_ed25519 ] && [ ! -f ~/.ssh/id_rsa ]; then
        echo ""
        echo "No SSH key found on this server. Choose an option:"
        echo "1) Generate a new SSH key   (first server — then reuse on other servers)"
        echo "2) Paste an existing private key   (already added to GitHub on another server)"
        read -p "Enter choice (1-2) [default: 1]: " SSH_KEY_CHOICE
        SSH_KEY_CHOICE=${SSH_KEY_CHOICE:-1}

        if [ "$SSH_KEY_CHOICE" = "2" ]; then
            print_status "Paste your private key below."
            print_status "(Paste all lines including -----BEGIN/END-----, then press Ctrl+D on a new line)"
            cat > ~/.ssh/id_ed25519
            chmod 600 ~/.ssh/id_ed25519
            print_status "Private key saved to ~/.ssh/id_ed25519"
        else
            read -p "Enter your email for SSH key [default: deploy@server]: " SSH_EMAIL
            SSH_EMAIL=${SSH_EMAIL:-deploy@server}
            ssh-keygen -t ed25519 -C "$SSH_EMAIL" -f ~/.ssh/id_ed25519 -N ""
            chmod 600 ~/.ssh/id_ed25519
            print_status "SSH key generated. Add this public key to GitHub:"
            print_warning "  Repo → Settings → Deploy keys → Add deploy key (read-only is fine)"
            print_warning "  OR: GitHub account → Settings → SSH keys (access to all your repos)"
            echo ""
            echo "---------- PUBLIC KEY START ----------"
            cat ~/.ssh/id_ed25519.pub
            echo "---------- PUBLIC KEY END ------------"
            echo ""
            print_warning "To reuse this key on other servers, copy the PRIVATE key:"
            print_warning "  cat ~/.ssh/id_ed25519"
            echo ""
            read -p "Press Enter after adding the public key to GitHub..."
        fi
    else
        print_status "SSH key already exists at ~/.ssh/id_ed25519"
    fi

    ssh-keyscan github.com >> ~/.ssh/known_hosts 2>/dev/null
else
    read -p "Enter your GitHub Username: " GITHUB_USER
    read -sp "Enter your GitHub Token (PAT): " GITHUB_TOKEN
    echo
    read -p "Enter your GitHub Repo URL (e.g., https://github.com/OWNER/REPO): " GITHUB_REPO_URL_INPUT
    GITHUB_REPO_URL="https://$GITHUB_USER:$GITHUB_TOKEN@${GITHUB_REPO_URL_INPUT#https://}"
    [[ "$GITHUB_REPO_URL" != *.git ]] && GITHUB_REPO_URL="${GITHUB_REPO_URL}.git"
fi
print_status "Repository URL configured"

# ===============================
# Install Base Dependencies
# ===============================
print_section "Installing Base Dependencies"

print_status "Updating package lists..."
apt-get update -qq

BASE_PACKAGES=(
    "curl"
    "wget"
    "git"
    "unzip"
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
# Verify Repository Access
# ===============================
print_section "Verifying Repository Access"

if [ "$GIT_METHOD" = "1" ]; then
    if ! ssh -T git@github.com 2>&1 | grep -q "successfully authenticated"; then
        print_error "SSH connection to GitHub failed!"
        print_error "Please ensure your SSH key is added to your GitHub account."
        exit 1
    fi
    print_status "SSH connection to GitHub verified!"

    if ! git ls-remote "$GITHUB_REPO_URL" HEAD &>/dev/null; then
        print_error "Cannot access repository: $GITHUB_REPO_URL"
        exit 1
    fi
else
    if ! git ls-remote "$GITHUB_REPO_URL" HEAD &>/dev/null; then
        print_error "Cannot access repository. Check URL, token, and permissions."
        exit 1
    fi
fi
print_status "Repository access verified successfully!"

# ===============================
# Install PHP
# ===============================
print_section "Installing PHP $PHP_VERSION"

print_status "Adding PHP repository..."
if ! grep -q "ondrej/php" /etc/apt/sources.list.d/* 2>/dev/null; then
    add-apt-repository -y ppa:ondrej/php
    apt-get update -qq
else
    print_status "PHP repository already added"
fi

CORE_EXTENSIONS=(
    "cli"
    "fpm"
    "common"
    "curl"
    "mbstring"
    "xml"
    "dom"
    "zip"
    "bcmath"
    "mysql"
    "pdo"
    "tokenizer"
    "opcache"
    "redis"
)

print_status "Installing PHP $PHP_VERSION with Laravel required extensions..."
PHP_PACKAGES="php${PHP_VERSION}"
for ext in "${CORE_EXTENSIONS[@]}"; do
    PHP_PACKAGES="$PHP_PACKAGES php${PHP_VERSION}-${ext}"
done

apt-get install -y $PHP_PACKAGES 2>/dev/null || {
    print_warning "Some extensions may be built into PHP core, installing individually..."
    apt-get install -y php${PHP_VERSION} php${PHP_VERSION}-cli php${PHP_VERSION}-fpm php${PHP_VERSION}-common
    for ext in curl mbstring xml zip bcmath mysql opcache redis; do
        apt-get install -y php${PHP_VERSION}-${ext} 2>/dev/null || true
    done
}

if command -v php &> /dev/null; then
    INSTALLED_PHP=$(php -v | head -n 1)
    print_status "PHP installed: $INSTALLED_PHP"
else
    print_error "PHP installation failed!"
    exit 1
fi

echo ""
OPTIONAL_EXTENSIONS=("gd" "intl" "soap" "memcached" "imagick" "ldap" "imap" "sqlite3" "exif")
echo "Available optional PHP extensions: ${OPTIONAL_EXTENSIONS[*]}"
read -p "Enter additional extensions to install (space-separated, or press Enter to skip): " EXTRA_EXTENSIONS

if [ -n "$EXTRA_EXTENSIONS" ]; then
    print_status "Installing additional PHP extensions..."
    for ext in $EXTRA_EXTENSIONS; do
        apt-get install -y php${PHP_VERSION}-${ext} 2>/dev/null || print_warning "Extension php${PHP_VERSION}-${ext} not available"
    done
fi

print_status "Configuring PHP for production..."
PHP_INI="/etc/php/${PHP_VERSION}/fpm/php.ini"
if [ -f "$PHP_INI" ]; then
    cp "$PHP_INI" "${PHP_INI}.backup" 2>/dev/null || true
    sed -i 's/^expose_php = On/expose_php = Off/' "$PHP_INI" 2>/dev/null || true
    sed -i 's/^;*upload_max_filesize.*/upload_max_filesize = 100M/' "$PHP_INI" 2>/dev/null || true
    sed -i 's/^;*post_max_size.*/post_max_size = 100M/' "$PHP_INI" 2>/dev/null || true
    sed -i 's/^;*memory_limit.*/memory_limit = 256M/' "$PHP_INI" 2>/dev/null || true
    sed -i 's/^;*max_execution_time.*/max_execution_time = 60/' "$PHP_INI" 2>/dev/null || true
fi

systemctl enable php${PHP_VERSION}-fpm
systemctl restart php${PHP_VERSION}-fpm

if systemctl is-active --quiet php${PHP_VERSION}-fpm; then
    print_status "PHP-FPM ${PHP_VERSION} is running"
else
    print_error "PHP-FPM failed to start!"
    exit 1
fi

# ===============================
# Install Composer
# ===============================
print_section "Installing Composer"

if command -v composer &> /dev/null; then
    print_status "Composer is already installed"
    composer --version
else
    print_status "Installing Composer..."
    EXPECTED_CHECKSUM="$(php -r 'copy("https://composer.github.io/installer.sig", "php://stdout");')"
    php -r "copy('https://getcomposer.org/installer', 'composer-setup.php');"
    ACTUAL_CHECKSUM="$(php -r "echo hash_file('sha384', 'composer-setup.php');")"

    if [ "$EXPECTED_CHECKSUM" != "$ACTUAL_CHECKSUM" ]; then
        print_warning "Composer installer checksum mismatch, installing anyway..."
    fi

    php composer-setup.php --quiet
    rm composer-setup.php
    mv composer.phar /usr/local/bin/composer
    chmod +x /usr/local/bin/composer
    print_status "Composer installed successfully"
fi

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

systemctl enable nginx 2>/dev/null || true
systemctl start nginx 2>/dev/null || true

# ===============================
# Clone Repository
# ===============================
print_section "Cloning Repository"

print_status "Cloning repository to $WEB_ROOT/$PROJECT_NAME ..."
mkdir -p $WEB_ROOT
cd $WEB_ROOT
rm -rf $PROJECT_NAME 2>/dev/null || true
git clone $GITHUB_REPO_URL $PROJECT_NAME
cd $PROJECT_NAME

# ===============================
# Laravel Setup
# ===============================
print_section "Setting Up Laravel"

print_status "Installing Composer dependencies (production)..."
export COMPOSER_ALLOW_SUPERUSER=1
composer install --no-interaction --prefer-dist --optimize-autoloader --no-dev

print_status "Setting file permissions..."
chown -R www-data:www-data $WEB_ROOT/$PROJECT_NAME
chmod -R 755 $WEB_ROOT/$PROJECT_NAME
chmod -R 775 $WEB_ROOT/$PROJECT_NAME/storage $WEB_ROOT/$PROJECT_NAME/bootstrap/cache

print_status "Configuring .env file..."
cp .env.example .env

# Escape special characters for sed
ESC_DB_PASSWORD=$(printf '%s\n' "$DB_PASSWORD" | sed 's/[[\/.*^$]/\\&/g')
ESC_DB_NAME=$(printf '%s\n' "$DB_NAME" | sed 's/[[\/.*^$]/\\&/g')
ESC_DB_USER=$(printf '%s\n' "$DB_USER" | sed 's/[[\/.*^$]/\\&/g')
ESC_REDIS_PASSWORD=$(printf '%s\n' "$REDIS_PASSWORD" | sed 's/[[\/.*^$]/\\&/g')
ESC_MINIO_SECRET=$(printf '%s\n' "$MINIO_SECRET_KEY" | sed 's/[[\/.*^$]/\\&/g')
ESC_MINIO_ACCESS=$(printf '%s\n' "$MINIO_ACCESS_KEY" | sed 's/[[\/.*^$]/\\&/g')
ESC_MINIO_BUCKET=$(printf '%s\n' "$MINIO_BUCKET" | sed 's/[[\/.*^$]/\\&/g')

sed -i "s|APP_NAME=.*|APP_NAME=$PROJECT_NAME|g" .env
sed -i "s|APP_ENV=.*|APP_ENV=production|g" .env
sed -i "s|APP_DEBUG=.*|APP_DEBUG=false|g" .env

if [ "$SERVER_DOMAIN" != "_" ]; then
    sed -i "s|APP_URL=.*|APP_URL=https://${SERVER_DOMAIN}|g" .env
else
    sed -i "s|APP_URL=.*|APP_URL=http://localhost|g" .env
fi

# Database — connects to VPS4
sed -i "s|DB_HOST=.*|DB_HOST=${VPS4_PRIVATE_IP}|g" .env
sed -i "s|DB_DATABASE=.*|DB_DATABASE=${ESC_DB_NAME}|g" .env
sed -i "s|DB_USERNAME=.*|DB_USERNAME=${ESC_DB_USER}|g" .env
sed -i "s|DB_PASSWORD=.*|DB_PASSWORD=${ESC_DB_PASSWORD}|g" .env

# Redis — connects to VPS4
sed -i "s|REDIS_HOST=.*|REDIS_HOST=${VPS4_PRIVATE_IP}|g" .env
sed -i "s|REDIS_PASSWORD=.*|REDIS_PASSWORD=${ESC_REDIS_PASSWORD}|g" .env
sed -i "s|REDIS_PORT=.*|REDIS_PORT=6379|g" .env

# Session, Cache, and Queue via Redis
sed -i "s|SESSION_DRIVER=.*|SESSION_DRIVER=redis|g" .env
sed -i "s|CACHE_DRIVER=.*|CACHE_DRIVER=redis|g" .env
sed -i "s|CACHE_STORE=.*|CACHE_STORE=redis|g" .env
sed -i "s|QUEUE_CONNECTION=.*|QUEUE_CONNECTION=${QUEUE_CONNECTION}|g" .env

# MinIO / S3-compatible storage — connects to VPS4
sed -i "s|FILESYSTEM_DISK=.*|FILESYSTEM_DISK=s3|g" .env
if grep -q "^AWS_ACCESS_KEY_ID=" .env; then
    sed -i "s|AWS_ACCESS_KEY_ID=.*|AWS_ACCESS_KEY_ID=${ESC_MINIO_ACCESS}|g" .env
else
    echo "AWS_ACCESS_KEY_ID=${MINIO_ACCESS_KEY}" >> .env
fi
if grep -q "^AWS_SECRET_ACCESS_KEY=" .env; then
    sed -i "s|AWS_SECRET_ACCESS_KEY=.*|AWS_SECRET_ACCESS_KEY=${ESC_MINIO_SECRET}|g" .env
else
    echo "AWS_SECRET_ACCESS_KEY=${MINIO_SECRET_KEY}" >> .env
fi
if grep -q "^AWS_DEFAULT_REGION=" .env; then
    sed -i "s|AWS_DEFAULT_REGION=.*|AWS_DEFAULT_REGION=us-east-1|g" .env
else
    echo "AWS_DEFAULT_REGION=us-east-1" >> .env
fi
if grep -q "^AWS_BUCKET=" .env; then
    sed -i "s|AWS_BUCKET=.*|AWS_BUCKET=${ESC_MINIO_BUCKET}|g" .env
else
    echo "AWS_BUCKET=${MINIO_BUCKET}" >> .env
fi
if grep -q "^AWS_ENDPOINT=" .env; then
    sed -i "s|AWS_ENDPOINT=.*|AWS_ENDPOINT=http://${VPS4_PRIVATE_IP}:9000|g" .env
else
    echo "AWS_ENDPOINT=http://${VPS4_PRIVATE_IP}:9000" >> .env
fi
if grep -q "^AWS_USE_PATH_STYLE_ENDPOINT=" .env; then
    sed -i "s|AWS_USE_PATH_STYLE_ENDPOINT=.*|AWS_USE_PATH_STYLE_ENDPOINT=true|g" .env
else
    echo "AWS_USE_PATH_STYLE_ENDPOINT=true" >> .env
fi

# Production log settings
sed -i "s|LOG_CHANNEL=.*|LOG_CHANNEL=daily|g" .env
sed -i "s|LOG_LEVEL=.*|LOG_LEVEL=warning|g" .env

print_status "Generating Laravel application key..."
php artisan key:generate

# -----------------------------------------------
# Migrations (primary only)
# -----------------------------------------------
if [ "$SERVER_ROLE" = "primary" ]; then
    print_status "Running database migrations (primary server)..."
    php artisan migrate --force
    print_status "Migrations completed"
else
    print_status "Skipping migrations — primary server handles migrations"
fi

print_status "Creating storage symbolic link..."
php artisan storage:link

print_status "Running Laravel optimize..."
php artisan optimize

# ===============================
# Configure Nginx
# ===============================
print_section "Configuring Nginx"

print_status "Writing Nginx site configuration..."
find /etc/nginx/sites-enabled/ -type l ! -name "default" -delete 2>/dev/null || true

cat > /etc/nginx/sites-available/$PROJECT_NAME <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name ${SERVER_DOMAIN};
    root $WEB_ROOT/$PROJECT_NAME/public;

    index index.php index.html;

    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-Content-Type-Options "nosniff" always;

    client_max_body_size 100M;

    charset utf-8;

    # Livewire routes
    location ^~ /livewire/ {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    # Static assets with CORS support
    location ~* \.(?:css|js|gif|png|jpg|jpeg|webp|ico|cur|bmp|svg|woff2|woff|ttf|eot|otf)$ {
        add_header 'Access-Control-Allow-Origin' '*' always;
        add_header 'Access-Control-Allow-Methods' 'GET, OPTIONS' always;
        add_header 'Access-Control-Allow-Headers' '*' always;
        add_header 'Access-Control-Max-Age' '86400' always;
        expires 1M;
        access_log off;
        try_files \$uri =404;
    }

    # Allow /logs routes to go through Laravel
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

ln -sf /etc/nginx/sites-available/$PROJECT_NAME /etc/nginx/sites-enabled/
rm -f /etc/nginx/sites-enabled/default

print_status "Testing Nginx configuration..."
if ! nginx -t; then
    print_error "Nginx configuration test failed!"
    exit 1
fi

systemctl restart nginx

if systemctl is-active --quiet nginx; then
    print_status "Nginx is running"
else
    print_error "Nginx failed to start!"
    exit 1
fi

# ===============================
# Install Supervisor & Queue Workers
# ===============================
print_section "Configuring Supervisor Queue Workers"

print_status "Installing Supervisor..."
apt-get install -y supervisor
systemctl enable supervisor
systemctl start supervisor

if [ -f "/etc/supervisor/conf.d/${PROJECT_NAME}-worker.conf" ]; then
    print_status "Removing old supervisor configuration..."
    supervisorctl stop ${PROJECT_NAME}-worker:* 2>/dev/null || true
    rm -f /etc/supervisor/conf.d/${PROJECT_NAME}-worker.conf
    supervisorctl reread 2>/dev/null || true
    supervisorctl update 2>/dev/null || true
fi

print_status "Writing Supervisor queue worker config ($NUM_WORKERS workers)..."
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

supervisorctl reread
supervisorctl update
supervisorctl start ${PROJECT_NAME}-worker:*

if supervisorctl status ${PROJECT_NAME}-worker:* | grep -q "RUNNING"; then
    print_status "Queue workers are running"
else
    print_warning "Queue workers may not be running — check: supervisorctl status"
fi

# -----------------------------------------------
# Scheduler Cron (primary only)
# -----------------------------------------------
if [ "$SERVER_ROLE" = "primary" ]; then
    print_section "Configuring Laravel Scheduler"

    CRON_JOB="* * * * * cd $WEB_ROOT/$PROJECT_NAME && php artisan schedule:run >> /dev/null 2>&1"

    print_status "Adding scheduler to www-data crontab (primary method)..."
    TEMP_CRON=$(mktemp)
    crontab -l -u www-data 2>/dev/null > "$TEMP_CRON" || true
    if ! grep -qF "$WEB_ROOT/$PROJECT_NAME" "$TEMP_CRON"; then
        echo "$CRON_JOB" >> "$TEMP_CRON"
        crontab -u www-data "$TEMP_CRON"
        print_status "Scheduler added to www-data crontab"
    else
        print_status "Scheduler already exists in www-data crontab"
    fi
    rm "$TEMP_CRON"

    print_status "Adding scheduler to /etc/cron.d/ (fallback method)..."
    CRON_FILE="/etc/cron.d/${PROJECT_NAME}-scheduler"
    cat > "$CRON_FILE" <<EOF
* * * * * www-data cd $WEB_ROOT/$PROJECT_NAME && php artisan schedule:run >> /dev/null 2>&1
EOF
    chmod 644 "$CRON_FILE"
    systemctl restart cron 2>/dev/null || service cron restart 2>/dev/null || true
    print_status "Scheduler configured via /etc/cron.d/${PROJECT_NAME}-scheduler"
else
    print_status "Skipping scheduler — primary server handles scheduler"
fi

# ===============================
# Configure UFW Firewall
# ===============================
print_section "Configuring UFW Firewall"

print_status "Setting up UFW: allow SSH, allow HTTP from VPS1 only..."
ufw --force reset
ufw default deny incoming
ufw default allow outgoing

ufw allow 22/tcp comment 'SSH'
ufw allow from "$VPS1_PRIVATE_IP" to any port 80 proto tcp comment 'HTTP from VPS1 load balancer'

ufw --force enable
print_status "UFW firewall configured"
ufw status verbose

# ===============================
# Final Summary
# ===============================
echo ""
echo -e "${BLUE}============================================================${NC}"
echo -e "${GREEN}  App Server Setup Complete! [${SERVER_LABEL}]${NC}"
echo -e "${BLUE}============================================================${NC}"
echo ""
print_status "=== Server ==="
print_status "  Role:                      $SERVER_ROLE"
print_status "  Label:                     $SERVER_LABEL"
echo ""
print_status "=== Application ==="
print_status "  Project:                   $PROJECT_NAME"
print_status "  Path:                      $WEB_ROOT/$PROJECT_NAME"
print_status "  PHP Version:               $PHP_VERSION"
print_status "  Server Name:               $SERVER_DOMAIN"
print_status "  APP_ENV:                   production"
print_status "  APP_DEBUG:                 false"
echo ""
print_status "=== Core Server (VPS4) Connections ==="
print_status "  DB_HOST:                   $VPS4_PRIVATE_IP"
print_status "  DB_DATABASE:               $DB_NAME"
print_status "  DB_USERNAME:               $DB_USER"
print_status "  REDIS_HOST:                $VPS4_PRIVATE_IP"
print_status "  AWS_ENDPOINT:              http://${VPS4_PRIVATE_IP}:9000"
print_status "  AWS_BUCKET:                $MINIO_BUCKET"
echo ""
print_status "=== Queue Workers ==="
print_status "  Workers:                   $NUM_WORKERS"
print_status "  Connection:                $QUEUE_CONNECTION"
print_status "  Config:                    /etc/supervisor/conf.d/${PROJECT_NAME}-worker.conf"
print_status "  Logs:                      $WEB_ROOT/$PROJECT_NAME/storage/logs/worker.log"
print_status "  Status:                    supervisorctl status ${PROJECT_NAME}-worker:*"
echo ""
if [ "$SERVER_ROLE" = "primary" ]; then
    print_status "=== Migrations ==="
    print_status "  Status:                    ran successfully"
    echo ""
    print_status "=== Scheduler ==="
    print_status "  Crontab:                   crontab -l -u www-data"
    print_status "  Cron.d file:               /etc/cron.d/${PROJECT_NAME}-scheduler"
    print_status "  Schedule list:             php artisan schedule:list"
    echo ""
else
    print_status "=== Migrations & Scheduler ==="
    print_warning "  NOT configured here — both run on primary server only"
    echo ""
fi
print_status "=== Firewall ==="
print_status "  Port 22 (SSH):             open to all"
print_status "  Port 80 (HTTP):            $VPS1_PRIVATE_IP (VPS1 load balancer) only"
echo ""
print_status "=== TrustProxies Reminder ==="
print_warning "  Add VPS1 IP to TrustProxies middleware:"
print_warning "    protected \$proxies = ['$VPS1_PRIVATE_IP'];"
echo ""
print_status "=== Useful Commands ==="
print_status "  Nginx:        systemctl restart nginx"
print_status "  PHP-FPM:      systemctl restart php${PHP_VERSION}-fpm"
print_status "  Queue status: supervisorctl status ${PROJECT_NAME}-worker:*"
print_status "  Logs:         tail -f $WEB_ROOT/$PROJECT_NAME/storage/logs/laravel.log"
print_status "  Worker logs:  tail -f $WEB_ROOT/$PROJECT_NAME/storage/logs/worker.log"
print_status "  Artisan:      cd $WEB_ROOT/$PROJECT_NAME && php artisan"
echo -e "${BLUE}============================================================${NC}"

# -----------------------------------------------
# Cluster addition reminder block (secondary only, if adding to existing cluster)
# -----------------------------------------------
if [ "$ADDING_TO_CLUSTER" = true ]; then
    echo ""
    echo -e "${YELLOW}============================================================${NC}"
    echo -e "${YELLOW}  IMPORTANT: Manual steps required on VPS1 (Load Balancer)${NC}"
    echo -e "${YELLOW}============================================================${NC}"
    echo ""
    echo -e "  Edit /etc/nginx/sites-available/loadbalancer.conf"
    echo -e "  Find the upstream laravel_app { block and add:"
    echo ""
    echo -e "      server ${THIS_PRIVATE_IP}:80;"
    echo ""
    echo -e "  Then reload Nginx (graceful, no downtime):"
    echo -e "      nginx -t && systemctl reload nginx"
    echo -e "${YELLOW}============================================================${NC}"
    echo ""
    print_status "=== Also update VPS4 UFW rules ==="
    print_warning "  SSH into VPS4 and allow this server:"
    print_warning "    ufw allow from $THIS_PRIVATE_IP to any port 3306 proto tcp"
    print_warning "    ufw allow from $THIS_PRIVATE_IP to any port 6379 proto tcp"
    print_warning "    ufw allow from $THIS_PRIVATE_IP to any port 9000 proto tcp"
fi
