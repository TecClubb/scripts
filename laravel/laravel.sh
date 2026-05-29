#!/bin/bash

# Laravel Project Auto-installer Script (Private Repo Supported)
# Installs Laravel, PHP 8.2/8.3/8.4, Nginx, MySQL, Certbot
# Supports cloning private GitHub repos with PAT/SSH authentication
# Works on fresh VPS servers - installs all required dependencies

set -e

# ===============================
# Colors for terminal output
# ===============================
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

print_status() { echo -e "${GREEN}[INFO]${NC} $1"; }
print_error() { echo -e "${RED}[ERROR]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
print_section() { echo -e "\n${BLUE}=== $1 ===${NC}\n"; }

# ===============================
# Pre-flight Checks & Base Dependencies
# ===============================
print_section "Pre-flight Checks"

# Must run as root
if [[ $EUID -ne 0 ]]; then
   print_error "This script must be run as root. Try using sudo."
   exit 1
fi

# Detect OS
if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS=$NAME
    OS_VERSION=$VERSION_ID
else
    print_error "Cannot detect OS. This script requires Ubuntu/Debian."
    exit 1
fi

print_status "Detected OS: $OS $OS_VERSION"

# Check if Ubuntu/Debian
if [[ ! "$OS" =~ (Ubuntu|Debian) ]]; then
    print_warning "This script is designed for Ubuntu/Debian. Proceeding anyway..."
fi

# ===============================
# Install Base Dependencies First
# ===============================
print_section "Installing Base Dependencies"

print_status "Updating package lists..."
apt-get update -qq

# Essential packages that must be installed first
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
    "cron"
)

print_status "Installing essential packages..."
for pkg in "${BASE_PACKAGES[@]}"; do
    if ! dpkg -l | grep -q "^ii  $pkg "; then
        print_status "Installing $pkg..."
        apt-get install -y $pkg -qq
    else
        print_status "$pkg is already installed"
    fi
done

# Ensure cron service is running
print_status "Ensuring cron service is enabled and running..."
systemctl enable cron 2>/dev/null || true
systemctl start cron 2>/dev/null || true
if systemctl is-active --quiet cron; then
    print_status "Cron service is running"
else
    print_warning "Cron service may not be running properly"
fi

# ===============================
# User Input Section
# ===============================
print_section "Configuration"

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

print_status "Selected PHP version: $PHP_VERSION"

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

# Database backup import option
echo ""
read -p "Import database from a SQL backup file instead of running migrations? (y/n) [default: n]: " IMPORT_DB
IMPORT_DB=${IMPORT_DB:-n}
BACKUP_FILE_PATH=""

if [[ "$IMPORT_DB" =~ ^[Yy]$ ]]; then
    BACKUP_SEARCH_DIRS=("/var/backups" "/root" "/tmp" "/home")
    SQL_FILES=()

    echo "Searching for SQL backup files..."
    for dir in "${BACKUP_SEARCH_DIRS[@]}"; do
        if [ -d "$dir" ]; then
            while IFS= read -r -d '' file; do
                SQL_FILES+=("$file")
            done < <(find "$dir" -maxdepth 3 \( -name "*.sql" -o -name "*.sql.gz" \) -type f -print0 2>/dev/null)
        fi
    done

    if [ ${#SQL_FILES[@]} -eq 0 ]; then
        print_warning "No SQL files found in: ${BACKUP_SEARCH_DIRS[*]}"
        read -p "Enter full path to your .sql or .sql.gz backup file: " BACKUP_FILE_PATH
    else
        echo ""
        echo "Found SQL backup files:"
        for i in "${!SQL_FILES[@]}"; do
            echo "  $((i+1))) ${SQL_FILES[$i]}"
        done
        CUSTOM_OPT=$((${#SQL_FILES[@]}+1))
        echo "  ${CUSTOM_OPT}) Enter a custom path"
        echo ""
        read -p "Select a file (1-${CUSTOM_OPT}): " FILE_CHOICE

        if [[ "$FILE_CHOICE" =~ ^[0-9]+$ ]] && [ "$FILE_CHOICE" -ge 1 ] && [ "$FILE_CHOICE" -lt "$CUSTOM_OPT" ]; then
            BACKUP_FILE_PATH="${SQL_FILES[$((FILE_CHOICE-1))]}"
        else
            read -p "Enter full path to your .sql or .sql.gz backup file: " BACKUP_FILE_PATH
        fi
    fi

    if [ -z "$BACKUP_FILE_PATH" ] || [ ! -f "$BACKUP_FILE_PATH" ]; then
        print_error "File not found: ${BACKUP_FILE_PATH:-<empty>}"
        print_warning "Will fall back to running migrations instead."
        IMPORT_DB=n
    else
        print_status "Backup file selected: $BACKUP_FILE_PATH"
    fi
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
    print_status "Development mode: APP_ENV=$APP_ENV, APP_DEBUG=$APP_DEBUG"
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
        print_warning "No SSH key found. Generating new SSH key..."
        read -p "Enter your email for SSH key: " SSH_EMAIL
        ssh-keygen -t ed25519 -C "$SSH_EMAIL" -f ~/.ssh/id_ed25519 -N ""
        print_status "SSH public key generated. Add this to your GitHub account:"
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

print_status "Repository URL configured"

# ===============================
# Function to extract root domain from subdomain
# ===============================
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
# Script logic
# ===============================

# ===============================
# Verify Repository Access
# ===============================
print_section "Verifying Repository Access"

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
# PHP Extensions Required by Laravel 12.x
# ===============================
# From Laravel docs: PHP >= 8.2 with these extensions:
# Ctype, cURL, DOM, Fileinfo, Filter, Hash, Mbstring, OpenSSL, PCRE, PDO, Session, Tokenizer, XML
# Note: Many of these are built into PHP core (ctype, fileinfo, filter, hash, openssl, pcre, session, tokenizer)
# We install the ones that need explicit packages

# Core PHP extensions required for Laravel
CORE_EXTENSIONS=(
    "cli"           # Command line interface
    "fpm"           # FastCGI Process Manager for Nginx
    "common"        # Common files (includes fileinfo, ctype, etc.)
    "curl"          # cURL extension
    "mbstring"      # Multibyte string support
    "xml"           # XML/DOM extension
    "dom"           # DOM extension (usually part of xml)
    "zip"           # ZIP archive support
    "bcmath"        # BCMath arbitrary precision
    "mysql"         # MySQL/MariaDB PDO driver
    "pdo"           # PDO database abstraction (if separate)
    "tokenizer"     # Tokenizer (usually built-in, but install if available)
    "opcache"       # OPcache for performance
)

# Optional PHP extensions (commonly used)
OPTIONAL_EXTENSIONS=("gd" "intl" "soap" "redis" "memcached" "imagick" "ldap" "imap" "sqlite3" "pgsql" "exif")

print_section "Installing PHP $PHP_VERSION"

# Add PHP repository
print_status "Adding PHP repository..."
if ! grep -q "ondrej/php" /etc/apt/sources.list.d/* 2>/dev/null; then
    add-apt-repository -y ppa:ondrej/php
    apt-get update -qq
else
    print_status "PHP repository already added"
fi

print_status "Installing PHP $PHP_VERSION with Laravel required extensions..."

# Build core installation command
PHP_PACKAGES="php${PHP_VERSION}"
for ext in "${CORE_EXTENSIONS[@]}"; do
    PHP_PACKAGES="$PHP_PACKAGES php${PHP_VERSION}-${ext}"
done

# Install PHP packages (ignore errors for built-in extensions)
apt-get install -y $PHP_PACKAGES 2>/dev/null || {
    print_warning "Some extensions may be built into PHP core, installing individually..."
    apt-get install -y php${PHP_VERSION} php${PHP_VERSION}-cli php${PHP_VERSION}-fpm php${PHP_VERSION}-common
    for ext in curl mbstring xml zip bcmath mysql opcache; do
        apt-get install -y php${PHP_VERSION}-${ext} 2>/dev/null || true
    done
}

# Verify PHP installation
if command -v php &> /dev/null; then
    INSTALLED_PHP=$(php -v | head -n 1)
    print_status "PHP installed: $INSTALLED_PHP"
else
    print_error "PHP installation failed!"
    exit 1
fi

# Ask for additional extensions
echo ""
echo "Available optional PHP extensions: ${OPTIONAL_EXTENSIONS[*]}"
read -p "Enter additional extensions to install (space-separated, or press Enter to skip): " EXTRA_EXTENSIONS

if [ ! -z "$EXTRA_EXTENSIONS" ]; then
    print_status "Installing additional PHP extensions..."
    for ext in $EXTRA_EXTENSIONS; do
        apt-get install -y php${PHP_VERSION}-${ext} 2>/dev/null || print_warning "Extension php${PHP_VERSION}-${ext} not available"
    done
fi

# Configure PHP for production
print_status "Configuring PHP for production..."
PHP_INI="/etc/php/${PHP_VERSION}/fpm/php.ini"
if [ -f "$PHP_INI" ]; then
    # Backup original
    cp "$PHP_INI" "${PHP_INI}.backup" 2>/dev/null || true
    
    # Production optimizations
    sed -i 's/^expose_php = On/expose_php = Off/' "$PHP_INI" 2>/dev/null || true
    sed -i 's/^;*upload_max_filesize.*/upload_max_filesize = 100M/' "$PHP_INI" 2>/dev/null || true
    sed -i 's/^;*post_max_size.*/post_max_size = 100M/' "$PHP_INI" 2>/dev/null || true
    sed -i 's/^;*memory_limit.*/memory_limit = 256M/' "$PHP_INI" 2>/dev/null || true
    sed -i 's/^;*max_execution_time.*/max_execution_time = 60/' "$PHP_INI" 2>/dev/null || true
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
# Install MySQL
# ===============================
print_section "Installing MySQL"

if command -v mysql &> /dev/null; then
    print_status "MySQL is already installed"
else
    print_status "Installing MySQL Server..."
    apt-get install -y mysql-server
fi

# Ensure MySQL is running
systemctl enable mysql 2>/dev/null || systemctl enable mariadb 2>/dev/null || true
systemctl start mysql 2>/dev/null || systemctl start mariadb 2>/dev/null || true

if systemctl is-active --quiet mysql || systemctl is-active --quiet mariadb; then
    print_status "MySQL/MariaDB is running"
else
    print_error "MySQL failed to start!"
    exit 1
fi

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

# ===============================
# Install Nginx & Certbot
# ===============================
print_section "Installing Nginx & Certbot"

if command -v nginx &> /dev/null; then
    print_status "Nginx is already installed"
else
    print_status "Installing Nginx..."
    apt-get install -y nginx
fi

if command -v certbot &> /dev/null; then
    print_status "Certbot is already installed"
else
    print_status "Installing Certbot..."
    apt-get install -y certbot python3-certbot-nginx
fi

# Ensure Nginx is running
systemctl enable nginx 2>/dev/null || true
systemctl start nginx 2>/dev/null || true

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

# ===============================
# Clone Repository
# ===============================
print_section "Cloning Repository"

print_status "Cloning your GitHub repository..."
mkdir -p $WEB_ROOT
cd $WEB_ROOT
rm -rf $PROJECT_NAME 2>/dev/null || true
git clone $GITHUB_REPO_URL $PROJECT_NAME
cd $PROJECT_NAME

# ===============================
# Laravel Setup
# ===============================
print_section "Setting Up Laravel"

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

IMPORT_FROM_BACKUP=false

if [[ "$IMPORT_DB" =~ ^[Yy]$ ]] && [ -n "$BACKUP_FILE_PATH" ] && [ -f "$BACKUP_FILE_PATH" ]; then
    print_status "Importing database from: $BACKUP_FILE_PATH"

    if [[ "$BACKUP_FILE_PATH" == *.sql.gz ]]; then
        print_status "Detected gzipped SQL — decompressing and importing..."
        if gunzip -c "$BACKUP_FILE_PATH" | mysql -u"$DB_USER" -p"$DB_PASSWORD" "$DB_NAME"; then
            print_status "Database imported successfully from gzipped backup!"
            IMPORT_FROM_BACKUP=true
        else
            print_error "Database import failed! Falling back to migrations..."
        fi
    else
        print_status "Importing SQL file..."
        if mysql -u"$DB_USER" -p"$DB_PASSWORD" "$DB_NAME" < "$BACKUP_FILE_PATH"; then
            print_status "Database imported successfully!"
            IMPORT_FROM_BACKUP=true
        else
            print_error "Database import failed! Falling back to migrations..."
        fi
    fi
fi

if [ "$IMPORT_FROM_BACKUP" = false ]; then
    print_status "Running database migrations..."
    php artisan migrate --force

    read -p "Run database seeders? (y/n) [default: n]: " RUN_SEEDERS
    if [[ "$RUN_SEEDERS" =~ ^[Yy]$ ]]; then
        print_status "Running database seeders..."
        php artisan db:seed --force
    fi
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

    # Ensure proper ownership on storage
    chown -R www-data:www-data ${WEB_ROOT}/${PROJECT_NAME}/storage
    
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
    
    # Ensure cron is installed and running
    if ! command -v crontab &> /dev/null; then
        print_status "Installing cron..."
        apt-get install -y cron
    fi
    
    # Enable and start cron service
    systemctl enable cron 2>/dev/null || true
    systemctl start cron 2>/dev/null || true
    
    # Verify cron is running
    if ! systemctl is-active --quiet cron; then
        print_warning "Cron service is not running, attempting to start..."
        service cron start 2>/dev/null || /etc/init.d/cron start 2>/dev/null || true
    fi
    
    # Define the cron command
    CRON_COMMAND="* * * * * cd ${WEB_ROOT}/${PROJECT_NAME} && php artisan schedule:run >> /dev/null 2>&1"
    
    # Create www-data crontab properly
    print_status "Setting up cron job for www-data user..."
    
    # Method 1: Direct crontab manipulation (most reliable)
    # First, ensure www-data has a valid shell for cron
    
    # Get existing crontab for www-data, strip any old entry for this project
    EXISTING_CRON=$(crontab -l -u www-data 2>/dev/null | grep -v "${WEB_ROOT}/${PROJECT_NAME}" || true)

    # Write new crontab using printf (reliable across all shells)
    {
        [ -n "$EXISTING_CRON" ] && printf "%s\n" "$EXISTING_CRON"
        printf "%s\n" "$CRON_COMMAND"
    } | crontab -u www-data -
    
    # Verify the crontab was set
    if crontab -l -u www-data 2>/dev/null | grep -qF "${WEB_ROOT}/${PROJECT_NAME}"; then
        print_status "Laravel Scheduler cron job added successfully!"
    else
        print_warning "Failed to add cron job via crontab command, trying alternative method..."
        
        # Method 2: Write to cron.d directory (alternative)
        CRON_FILE="/etc/cron.d/${PROJECT_NAME}-scheduler"
        echo "# Laravel Scheduler for ${PROJECT_NAME}" > "$CRON_FILE"
        echo "SHELL=/bin/bash" >> "$CRON_FILE"
        echo "PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin" >> "$CRON_FILE"
        echo "* * * * * www-data cd ${WEB_ROOT}/${PROJECT_NAME} && php artisan schedule:run >> /dev/null 2>&1" >> "$CRON_FILE"
        chmod 644 "$CRON_FILE"
        
        print_status "Created cron file at: $CRON_FILE"
    fi
    
    # Restart cron to ensure changes take effect
    systemctl restart cron 2>/dev/null || service cron restart 2>/dev/null || /etc/init.d/cron restart 2>/dev/null || true
    
    print_status "Current crontab for www-data:"
    crontab -l -u www-data 2>/dev/null || echo "(checking /etc/cron.d/)"
    
    if [ -f "/etc/cron.d/${PROJECT_NAME}-scheduler" ]; then
        print_status "Cron file content:"
        cat "/etc/cron.d/${PROJECT_NAME}-scheduler"
    fi
fi

# ===============================
# Configure Nginx
# ===============================
print_section "Configuring Nginx"

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

# Create optimized Nginx configuration (based on production-tested config)
cat > /etc/nginx/sites-available/$PROJECT_NAME <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name ${ALL_DOMAINS};
    root $WEB_ROOT/$PROJECT_NAME/public;

    index index.php index.html;
    
    # Security headers
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-Content-Type-Options "nosniff" always;
    
    # Upload size limit
    client_max_body_size 100M;

    charset utf-8;

    # Livewire routes - always go through Laravel (must be before static assets)
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

    # Main location block
    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    location = /favicon.ico { access_log off; log_not_found off; }
    location = /robots.txt  { access_log off; log_not_found off; }

    error_page 404 /index.php;

    # PHP-FPM configuration
    location ~ ^/index\.php(/|$) {
        fastcgi_pass unix:/var/run/php/php${PHP_VERSION}-fpm.sock;
        fastcgi_param SCRIPT_FILENAME \$realpath_root\$fastcgi_script_name;
        include fastcgi_params;
        fastcgi_hide_header X-Powered-By;
    }

    # Block hidden files (except .well-known for SSL verification)
    location ~ /\.(?!well-known).* {
        deny all;
        access_log off;
        log_not_found off;
    }

    # Block sensitive files (but allow Laravel routes like /api/logs)
    location ~* \.(env|log|ini|sql|bak|old|sh)$ {
        # Allow /logs and /api prefixes to go through Laravel
        location ~ ^/(logs|api)/ {
            try_files \$uri \$uri/ /index.php?\$query_string;
        }
        
        # Block all other direct file access
        deny all;
        access_log off;
        log_not_found off;
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
            certbot renew --dry-run || print_warning "SSL auto-renew test failed, but certificates are installed"
        else
            print_warning "SSL certificate directory not found, but Certbot reported success"
        fi
    else
        print_warning "SSL certificate installation failed!"
        print_warning "Your site is accessible via HTTP only."
        print_warning "Common causes:"
        print_warning "  1. DNS not pointing to this server yet"
        print_warning "  2. Port 80 not accessible from internet"
        print_warning "  3. Firewall blocking connections"
        print_warning "You can retry SSL setup later with:"
        print_warning "  certbot --nginx -d ${ALL_DOMAINS// / -d }"
        ENABLE_SSL=false
    fi
fi

# Restart PHP-FPM
print_status "Configuring PHP-FPM..."
systemctl enable php${PHP_VERSION}-fpm
systemctl restart php${PHP_VERSION}-fpm

# Verify PHP-FPM is running
if systemctl is-active --quiet php${PHP_VERSION}-fpm; then
    print_status "PHP-FPM is running"
else
    print_error "PHP-FPM failed to start!"
    exit 1
fi

# ===============================
# Laravel Optimization
# ===============================
print_section "Optimizing Laravel"

# Clear any existing caches first
print_status "Clearing existing caches..."
php artisan optimize:clear 2>/dev/null || true

# Run Laravel's optimize command (combines config:cache, route:cache, view:cache, event:cache)
print_status "Running Laravel optimization..."
php artisan optimize

# Additional production optimizations
if [[ "$IS_PRODUCTION" =~ ^[Yy]$ ]]; then
    print_status "Running additional production optimizations..."
    
    # Composer optimization (already done during install, but ensure autoloader is optimized)
    composer dump-autoload --optimize --no-dev 2>/dev/null || true
fi

print_status "Laravel optimization complete!"

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
    print_status "  Verify: crontab -l -u www-data"
    if [ -f "/etc/cron.d/${PROJECT_NAME}-scheduler" ]; then
        print_status "  Cron File: /etc/cron.d/${PROJECT_NAME}-scheduler"
    fi
fi

print_status ""
print_status "Useful Commands:"
print_status "  - Restart PHP-FPM: systemctl restart php${PHP_VERSION}-fpm"
print_status "  - Restart Nginx: systemctl restart nginx"
print_status "  - View Laravel logs: tail -f $WEB_ROOT/$PROJECT_NAME/storage/logs/laravel.log"
print_status "  - Clear all caches: cd $WEB_ROOT/$PROJECT_NAME && php artisan optimize:clear"
print_status "  - Re-optimize: cd $WEB_ROOT/$PROJECT_NAME && php artisan optimize"
print_status "====================================================="
