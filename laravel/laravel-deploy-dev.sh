#!/bin/bash

# Laravel Development Deployment Script
# Safely deploys new code with development-specific optimizations
# Includes dev dependencies and debugging features

set -e  # Exit on any error

# ===============================
# Configuration
# ===============================
PROJECT_PATH="/var/www/safeprovpn"  # Default development path
BRANCH="develop"  # Default development branch
PROJECT_NAME="safeprovpn"
BACKUP_PATH="/var/backups/safeprovpn-dev"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)

# Colors for output
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# ===============================
# Helper Functions
# ===============================
print_status() { echo -e "${GREEN}[✓]${NC} $1"; }
print_error() { echo -e "${RED}[✗]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[! ]${NC} $1"; }
print_info() { echo -e "${BLUE}[ℹ]${NC} $1"; }

# Error handler
handle_error() {
    print_error "Deployment failed at step: $1"
    print_warning "Rolling back changes..."
    
    # Restore from backup if exists
    if [ -d "$BACKUP_PATH/code_$TIMESTAMP" ]; then
        cd $PROJECT_PATH
        git reset --hard HEAD@{1} 2>/dev/null || true
        print_warning "Code rolled back to previous version"
    fi
    
    # Bring site back up
    php artisan up 2>/dev/null || true
    
    print_error "Deployment aborted. Please check the logs."
    exit 1
}

# Trap errors
trap 'handle_error "$BASH_COMMAND"' ERR

# ===============================
# Pre-Deployment Checks
# ===============================
echo ""
echo "======================================"
echo "   Laravel Development Deployment"
echo "======================================"
echo ""

# Allow user to configure project path
read -p "Enter project path [default: $PROJECT_PATH]: " INPUT_PATH
PROJECT_PATH=${INPUT_PATH:-$PROJECT_PATH}

# Allow user to configure branch
read -p "Enter branch to deploy [default: $BRANCH]: " INPUT_BRANCH
BRANCH=${INPUT_BRANCH:-$BRANCH}

# Extract project name from path
PROJECT_NAME=$(basename $PROJECT_PATH)

print_info "Project: $PROJECT_NAME"
print_info "Path: $PROJECT_PATH"
print_info "Branch: $BRANCH"
print_info "Time: $(date)"
echo ""

# Check if we're in the right directory
if [ ! -f "$PROJECT_PATH/artisan" ]; then
    print_error "Laravel project not found at $PROJECT_PATH"
    exit 1
fi

cd $PROJECT_PATH

# Check for uncommitted changes
if [[ -n $(git status -s) ]]; then
    print_warning "Warning: You have uncommitted changes in the working directory"
    git status -s
    read -p "Continue anyway? (y/n): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        print_error "Deployment cancelled"
        exit 1
    fi
fi

# ===============================
# Backup
# ===============================
print_info "Creating backup..."
mkdir -p $BACKUP_PATH

# Backup database
print_status "Backing up database..."
DB_NAME=$(grep DB_DATABASE .env | cut -d '=' -f2)
DB_USER=$(grep DB_USERNAME .env | cut -d '=' -f2)
DB_PASS=$(grep DB_PASSWORD .env | cut -d '=' -f2)

if [ ! -z "$DB_NAME" ]; then
    mysqldump -u"$DB_USER" -p"$DB_PASS" "$DB_NAME" > "$BACKUP_PATH/db_backup_$TIMESTAMP.sql" 2>/dev/null || print_warning "Database backup failed (continuing anyway)"
    print_status "Database backed up to: $BACKUP_PATH/db_backup_$TIMESTAMP.sql"
fi

# ===============================
# Deployment Steps
# ===============================

# Step 1: Enable maintenance mode (optional for dev)
print_info "Enable maintenance mode? (Recommended for production-like deployments)"
read -p "Enable maintenance mode? (y/n): " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    php artisan down --retry=60 --secret="dev-deploy-$(date +%s)" || true
    print_status "Maintenance mode enabled"
    MAINTENANCE_ENABLED=true
else
    print_status "Skipping maintenance mode (development mode)"
    MAINTENANCE_ENABLED=false
fi

# Step 2: Pull latest code
print_info "Pulling latest code from GitHub..."
CURRENT_COMMIT=$(git rev-parse HEAD)
print_info "Current commit: $CURRENT_COMMIT"

git fetch origin $BRANCH
git pull origin $BRANCH

NEW_COMMIT=$(git rev-parse HEAD)
print_info "New commit: $NEW_COMMIT"

if [ "$CURRENT_COMMIT" = "$NEW_COMMIT" ]; then
    print_warning "No new changes detected"
else
    print_status "Code updated successfully"
    print_info "Changes:"
    git log --oneline $CURRENT_COMMIT..$NEW_COMMIT
fi

# Step 3: Install/Update Composer dependencies (including dev)
print_info "Installing Composer dependencies with dev packages..."
export COMPOSER_ALLOW_SUPERUSER=1
composer install --no-interaction --prefer-dist --optimize-autoloader
print_status "Composer dependencies updated (including dev)"

# Step 4: Run database migrations
print_info "Running database migrations..."
php artisan migrate --force
print_status "Database migrations completed"

# Step 5: Ask about seeding
read -p "Run database seeders? (y/n): " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    print_info "Running database seeders..."
    php artisan db:seed --force
    print_status "Database seeders completed"
fi

# Step 6: Clear all caches (development mode)
print_info "Clearing all caches..."
php artisan config:clear
php artisan cache:clear
php artisan route:clear
php artisan view:clear
php artisan event:clear
php artisan queue:clear 2>/dev/null || print_warning "Queue clear not available"
print_status "All caches cleared (development mode)"

# Step 7: Storage link (if needed)
if [ ! -L "$PROJECT_PATH/public/storage" ]; then
    print_info "Creating storage symlink..."
    php artisan storage:link
    print_status "Storage symlink created"
fi

# Step 8: Reload services (Queue workers, Horizon, etc.)
print_info "Reloading services..."
php artisan reload 2>/dev/null || print_warning "php artisan reload not available (Laravel 11+ only)"

# Alternative: Restart queue workers with Supervisor
if command -v supervisorctl &> /dev/null; then
    print_info "Restarting Supervisor queue workers..."
    sudo supervisorctl restart ${PROJECT_NAME}-worker:* 2>/dev/null && print_status "Queue workers restarted" || print_warning "No queue workers found"
fi

# Step 9: Fix permissions
print_info "Setting proper permissions..."
# Only change ownership of directories that need www-data, not the entire project
sudo chown -R www-data:www-data $PROJECT_PATH/storage $PROJECT_PATH/bootstrap/cache
# Set permissions faster using xargs instead of exec
sudo find $PROJECT_PATH -type f -print0 | sudo xargs -0 chmod 644
sudo find $PROJECT_PATH -type d -print0 | sudo xargs -0 chmod 755
sudo chmod -R 775 $PROJECT_PATH/storage $PROJECT_PATH/bootstrap/cache
# Make artisan executable
sudo chmod +x $PROJECT_PATH/artisan
print_status "Permissions set"

# Step 10: Development optimizations
print_info "Applying development optimizations..."
# Ensure debug is enabled
sed -i 's/APP_DEBUG=.*/APP_DEBUG=true/' .env
# Set log level to debug
sed -i 's/LOG_LEVEL=.*/LOG_LEVEL=debug/' .env
print_status "Development optimizations applied"

# Step 11: Restart PHP-FPM (user choice)
print_info "PHP-FPM restart is only needed for PHP configuration changes"
read -p "Restart PHP-FPM? (y/n): " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    print_info "Restarting PHP-FPM..."
    PHP_VERSION=$(php -r "echo PHP_MAJOR_VERSION.'.'.PHP_MINOR_VERSION;")
    sudo systemctl restart php${PHP_VERSION}-fpm 2>/dev/null && print_status "PHP-FPM restarted" || print_warning "Could not restart PHP-FPM"
else
    print_status "PHP-FPM restart skipped"
fi

# Step 12: Test application health
print_info "Testing application health..."
HTTP_CODE=$(curl -o /dev/null -s -w "%{http_code}" http://localhost 2>/dev/null || echo "000")
if [ "$HTTP_CODE" = "503" ] || [ "$HTTP_CODE" = "200" ]; then
    print_status "Application responding (HTTP $HTTP_CODE)"
else
    print_warning "Unexpected HTTP code: $HTTP_CODE"
fi

# Step 13: Disable maintenance mode
if [ "$MAINTENANCE_ENABLED" = true ]; then
    print_info "Disabling maintenance mode..."
    php artisan up
    print_status "Maintenance mode disabled"
fi

# ===============================
# Post-Deployment
# ===============================
echo ""
echo "======================================"
print_status "Development deployment completed successfully!"
echo "======================================"
echo ""
print_info "Summary:"
print_info "  • Previous commit: $CURRENT_COMMIT"
print_info "  • New commit: $NEW_COMMIT"
print_info "  • Database backup: $BACKUP_PATH/db_backup_$TIMESTAMP.sql"
print_info "  • Deployment time: $(date)"
print_info "  • Environment: Development (DEBUG enabled)"
echo ""

# Development-specific information
echo ""
print_info "Development Features Active:"
print_info "  • Debug mode: ENABLED"
print_info "  • Log level: DEBUG"
print_info "  • Dev dependencies: INSTALLED"
print_info "  • Caches: CLEARED for easy debugging"
echo ""

print_status "Your development application is ready! 🚀"
echo ""

# Optional: Clean old backups (keep last 10)
print_info "Cleaning old backups..."
cd $BACKUP_PATH
ls -t db_backup_*.sql 2>/dev/null | tail -n +11 | xargs rm -f 2>/dev/null || true
print_status "Old backups cleaned (kept last 10)"

echo ""
print_info "Useful development commands:"
echo "  • View logs: tail -f $PROJECT_PATH/storage/logs/laravel.log"
echo "  • Check queue: php artisan queue:work --once"
echo "  • View schedule: php artisan schedule:list"
echo "  • Clear caches: php artisan optimize:clear"
echo "  • Run tests: php artisan test"
echo "  • Tinker: php artisan tinker"
echo ""
