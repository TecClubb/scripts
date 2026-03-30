#!/bin/bash

# Laravel Deployment Script (Consolidated)
# Usage: deploy.sh [project_path] [branch] [role]
#   role: primary | secondary  (prompted interactively if not provided)
#
# primary   — runs migrations + restarts scheduler cron
# secondary — skips migrations and scheduler

set -e

# ===============================
# Configuration
# ===============================
PROJECT_PATH="${1:-/var/www/laravel-app}"
BRANCH="${2:-main}"
ROLE="${3:-}"
PROJECT_NAME=$(basename "$PROJECT_PATH")
BACKUP_PATH="/var/backups/laravel/${PROJECT_NAME}"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
PHP_VERSION=$(php -r "echo PHP_MAJOR_VERSION.'.'.PHP_MINOR_VERSION;" 2>/dev/null || echo "8.3")

# Colors for output
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# ===============================
# Helper Functions
# ===============================
print_status()  { echo -e "${GREEN}[✓]${NC} $1"; }
print_error()   { echo -e "${RED}[✗]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[! ]${NC} $1"; }
print_info()    { echo -e "${BLUE}[ℹ]${NC} $1"; }

# ===============================
# Error Handler
# ===============================
handle_error() {
    print_error "Deployment failed at step: $1"
    print_warning "Rolling back changes..."

    cd "$PROJECT_PATH" 2>/dev/null || true

    if [ -d "$PROJECT_PATH/.git" ]; then
        git reset --hard HEAD@{1} 2>/dev/null && print_warning "Code rolled back to previous version" || print_warning "Could not rollback git changes"
    fi

    if [ -d "$BACKUP_PATH/vendor_$TIMESTAMP" ]; then
        rm -rf "$PROJECT_PATH/vendor" 2>/dev/null || true
        mv "$BACKUP_PATH/vendor_$TIMESTAMP" "$PROJECT_PATH/vendor" 2>/dev/null || true
        print_warning "Vendor directory restored"
    fi

    php artisan config:clear 2>/dev/null || true
    php artisan cache:clear 2>/dev/null || true
    php artisan up 2>/dev/null || true

    print_error "Deployment aborted. Please check the logs."
    print_info "Log file: $PROJECT_PATH/storage/logs/laravel.log"
    exit 1
}

trap 'handle_error "$BASH_COMMAND"' ERR

# ===============================
# Role Selection
# ===============================
echo ""
echo "======================================"
echo "   Laravel Deployment Script"
echo "======================================"
echo ""

if [ -z "$ROLE" ]; then
    echo "Select deployment role:"
    echo "1) Primary   — runs migrations + restarts scheduler cron"
    echo "2) Secondary — skips migrations and scheduler"
    read -p "Enter (1-2) [default: 2]: " ROLE_CHOICE
    case "${ROLE_CHOICE:-2}" in
        1) ROLE="primary" ;;
        *) ROLE="secondary" ;;
    esac
fi

if [[ "$ROLE" != "primary" && "$ROLE" != "secondary" ]]; then
    print_error "Invalid role '$ROLE'. Use: primary | secondary"
    exit 1
fi

# ===============================
# Pre-Deployment Checks
# ===============================
print_info "Project:     $PROJECT_NAME"
print_info "Path:        $PROJECT_PATH"
print_info "Branch:      $BRANCH"
print_info "Role:        $ROLE"
print_info "PHP Version: $PHP_VERSION"
print_info "Time:        $(date)"
echo ""

if [ ! -f "$PROJECT_PATH/artisan" ]; then
    print_error "Laravel project not found at $PROJECT_PATH"
    print_info "Usage: $0 [project_path] [branch] [primary|secondary]"
    exit 1
fi

cd "$PROJECT_PATH" || {
    print_error "Failed to change to directory: $PROJECT_PATH"
    exit 1
}

if [ ! -d ".git" ]; then
    print_error "This directory is not a git repository"
    exit 1
fi

print_status "Git repository found"

git config core.fileMode false || true

if [[ -n $(git status -s) ]]; then
    print_warning "Uncommitted changes detected in working directory:"
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

DB_NAME_ENV=$(grep DB_DATABASE .env | cut -d '=' -f2)
DB_USER_ENV=$(grep DB_USERNAME .env | cut -d '=' -f2)
DB_PASS_ENV=$(grep DB_PASSWORD .env | cut -d '=' -f2)
DB_HOST_ENV=$(grep DB_HOST .env | cut -d '=' -f2)

if [ -n "$DB_NAME_ENV" ] && [ -n "$DB_USER_ENV" ]; then
    if mysqldump -h"${DB_HOST_ENV:-127.0.0.1}" -u"$DB_USER_ENV" -p"$DB_PASS_ENV" "$DB_NAME_ENV" > "$BACKUP_PATH/db_backup_$TIMESTAMP.sql" 2>/dev/null; then
        print_status "Database backed up to: $BACKUP_PATH/db_backup_$TIMESTAMP.sql"
    else
        print_warning "Database backup failed (continuing anyway)"
    fi
else
    print_warning "Database credentials not found in .env, skipping backup"
fi

# ===============================
# Deployment Steps
# ===============================

# Step 1: Maintenance mode
print_info "Enabling maintenance mode..."
php artisan down --retry=60 --secret="deployment-$(date +%s)" || true
print_status "Maintenance mode enabled"

# Step 2: Pull latest code
print_info "Pulling latest code from GitHub..."
CURRENT_COMMIT=$(git rev-parse HEAD)
print_info "Current commit: $CURRENT_COMMIT"

if ! git remote get-url origin &>/dev/null; then
    print_error "No 'origin' remote configured"
    exit 1
fi

git fetch origin $BRANCH
git pull origin $BRANCH

NEW_COMMIT=$(git rev-parse HEAD)
print_info "New commit: $NEW_COMMIT"

if [ "$CURRENT_COMMIT" = "$NEW_COMMIT" ]; then
    print_warning "No new changes detected"
else
    print_status "Code updated successfully"
    git log --oneline $CURRENT_COMMIT..$NEW_COMMIT
fi

# Step 3: Composer install
print_info "Installing Composer dependencies..."
composer install --no-interaction --prefer-dist --optimize-autoloader --no-dev
print_status "Composer dependencies updated"

# Step 4: Migrations (primary only)
if [ "$ROLE" = "primary" ]; then
    print_info "Running database migrations (primary — always runs migrations)..."
    php artisan migrate --force
    print_status "Database migrations completed"
else
    print_info "[INFO] Migrations are managed by the primary server — skipping on this server"
fi

# Step 5: Clear caches
print_info "Clearing all caches..."
php artisan optimize:clear
php artisan cache:clear
print_status "Caches cleared"

# Step 6: Rebuild caches
print_info "Rebuilding optimized caches..."
php artisan optimize
print_status "Caches rebuilt"

# Step 7: Storage link
if [ ! -L "$PROJECT_PATH/public/storage" ]; then
    print_info "Creating storage symlink..."
    php artisan storage:link
    print_status "Storage symlink created"
else
    print_status "Storage symlink already exists"
fi

# Step 8: Restart services
print_info "Restarting services..."

# Supervisor queue workers
if command -v supervisorctl &> /dev/null; then
    if supervisorctl status ${PROJECT_NAME}-worker:* &>/dev/null || supervisorctl status ${PROJECT_NAME}-worker &>/dev/null; then
        print_info "Restarting Supervisor queue workers..."
        supervisorctl restart ${PROJECT_NAME}-worker:* 2>/dev/null \
            || supervisorctl restart ${PROJECT_NAME}-worker 2>/dev/null \
            || print_warning "Failed to restart queue workers"
        print_status "Queue workers restarted"
    else
        print_info "No Supervisor workers configured for: ${PROJECT_NAME}-worker"
    fi
fi

# Scheduler cron restart (primary only)
if [ "$ROLE" = "primary" ]; then
    CRON_FILE="/etc/cron.d/${PROJECT_NAME}-scheduler"
    if [ -f "$CRON_FILE" ]; then
        print_info "Restarting cron to apply scheduler..."
        systemctl restart cron 2>/dev/null || service cron restart 2>/dev/null || true
        print_status "Cron restarted (scheduler active via $CRON_FILE)"
    elif crontab -l -u www-data 2>/dev/null | grep -qF "$PROJECT_PATH"; then
        systemctl restart cron 2>/dev/null || service cron restart 2>/dev/null || true
        print_status "Cron restarted (scheduler active via www-data crontab)"
    else
        print_warning "No scheduler cron found for this project — is this actually the primary server?"
    fi
else
    print_info "Skipping scheduler restart — secondary server"
fi

# Horizon (if present)
if php artisan list 2>/dev/null | grep -q "horizon:terminate"; then
    if pgrep -f "horizon" > /dev/null; then
        print_info "Terminating Horizon workers..."
        php artisan horizon:terminate
        print_status "Horizon workers will restart automatically"
    fi
fi

# Step 9: Fix permissions
print_info "Setting permissions..."
chown -R www-data:www-data "$PROJECT_PATH/storage" "$PROJECT_PATH/bootstrap/cache"
chmod -R 775 "$PROJECT_PATH/storage" "$PROJECT_PATH/bootstrap/cache"
mkdir -p "$PROJECT_PATH/storage/app/public" "$PROJECT_PATH/storage/framework/cache" \
          "$PROJECT_PATH/storage/framework/sessions" "$PROJECT_PATH/storage/framework/views" \
          "$PROJECT_PATH/storage/logs" 2>/dev/null || true
chmod +x "$PROJECT_PATH/artisan" 2>/dev/null || true
git config core.fileMode false
print_status "Permissions set"

# Step 10: PHP-FPM (optional)
read -p "Restart PHP-FPM? Needed only for PHP config/OPcache changes (y/n) [default: n]: " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    systemctl restart php${PHP_VERSION}-fpm 2>/dev/null \
        || systemctl reload php${PHP_VERSION}-fpm 2>/dev/null \
        || print_warning "Could not restart PHP-FPM"
    print_status "PHP-FPM restarted"
else
    php -r "if(function_exists('opcache_reset')) { opcache_reset(); }" 2>/dev/null || true
    print_status "PHP-FPM restart skipped"
fi

# Step 11: Health check
print_info "Testing application health..."
APP_URL=$(grep -E "^APP_URL=" .env | cut -d '=' -f2 | tr -d '"' | tr -d "'")

HTTP_CODE=$(curl -o /dev/null -s -w "%{http_code}" --max-time 10 "${APP_URL:-http://localhost}/up" 2>/dev/null \
    || curl -o /dev/null -s -w "%{http_code}" --max-time 10 "http://127.0.0.1/up" 2>/dev/null \
    || curl -o /dev/null -s -w "%{http_code}" --max-time 10 "http://127.0.0.1" 2>/dev/null \
    || echo "000")

case "$HTTP_CODE" in
    200)     print_status "Application is healthy (HTTP 200)" ;;
    503)     print_warning "Application in maintenance mode (HTTP 503) — lifting now" ;;
    302|301) print_status "Application responding with redirect (HTTP $HTTP_CODE)" ;;
    000)     print_warning "Could not connect to application (may be normal if using custom domain)" ;;
    *)       print_warning "Unexpected HTTP code: $HTTP_CODE" ;;
esac

# Step 12: Lift maintenance mode
print_info "Disabling maintenance mode..."
php artisan up
print_status "Maintenance mode disabled"

# ===============================
# Post-Deployment Summary
# ===============================
echo ""
echo "======================================"
print_status "Deployment completed successfully!"
echo "======================================"
echo ""
print_info "Summary:"
print_info "  • Server role:     $ROLE"
print_info "  • Project:         $PROJECT_NAME"
print_info "  • Previous commit: ${CURRENT_COMMIT:0:8}"
print_info "  • New commit:      ${NEW_COMMIT:0:8}"
if [ "$ROLE" = "primary" ]; then
    print_info "  • Migrations:      ran"
    print_info "  • Scheduler:       cron restarted"
else
    print_info "  • Migrations:      skipped (primary server handles this)"
    print_info "  • Scheduler:       not managed here"
fi
[ -f "$BACKUP_PATH/db_backup_$TIMESTAMP.sql" ] && print_info "  • DB backup:       $BACKUP_PATH/db_backup_$TIMESTAMP.sql"
print_info "  • Deployed at:     $(date)"
echo ""
print_status "Application is live!"
echo ""

# Clean old backups (keep last 10)
if [ -d "$BACKUP_PATH" ]; then
    cd "$BACKUP_PATH"
    ls -t db_backup_*.sql 2>/dev/null | tail -n +11 | xargs rm -f 2>/dev/null || true
    cd "$PROJECT_PATH"
fi

print_info "Useful commands:"
echo "  • View logs:        tail -f $PROJECT_PATH/storage/logs/laravel.log"
echo "  • Worker status:    supervisorctl status ${PROJECT_NAME}-worker:*"
if [ "$ROLE" = "primary" ]; then
    echo "  • Scheduler check:  crontab -l -u www-data"
    echo "  • Schedule list:    php artisan schedule:list"
fi
echo "  • Rollback code:    cd $PROJECT_PATH && git reset --hard HEAD~1"
echo ""
