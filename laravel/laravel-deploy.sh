#!/bin/bash

# Laravel Deployment Script
# Safely deploys new code with automatic rollback on failure

# Temporarily disable exit on error for debugging
# set -e  # Exit on any error

# ===============================
# Configuration
# ===============================
# Set these variables or pass as arguments
PROJECT_PATH="${1:-/var/www/safeprovpn}"
BRANCH="${2:-main}"  # Change to 'master' or your branch name
PROJECT_NAME=$(basename "$PROJECT_PATH")
BACKUP_PATH="/var/backups/laravel/${PROJECT_NAME}"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
PHP_VERSION=$(php -r "echo PHP_MAJOR_VERSION.'.'.PHP_MINOR_VERSION;" 2>/dev/null || echo "8.3")

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
    
    # Ensure we're in the project directory
    cd "$PROJECT_PATH" 2>/dev/null || true
    
    # Try to rollback git changes
    if [ -d "$PROJECT_PATH/.git" ]; then
        git reset --hard HEAD@{1} 2>/dev/null && print_warning "Code rolled back to previous version" || print_warning "Could not rollback git changes"
    else
        print_warning "Not a git repository, cannot rollback code changes"
    fi
    
    # Restore composer dependencies if vendor backup exists
    if [ -d "$BACKUP_PATH/vendor_$TIMESTAMP" ]; then
        rm -rf "$PROJECT_PATH/vendor" 2>/dev/null || true
        mv "$BACKUP_PATH/vendor_$TIMESTAMP" "$PROJECT_PATH/vendor" 2>/dev/null || true
        print_warning "Vendor directory restored"
    fi
    
    # Clear any cached config that might be broken
    php artisan config:clear 2>/dev/null || true
    php artisan cache:clear 2>/dev/null || true
    
    # Bring site back up
    php artisan up 2>/dev/null || true
    
    print_error "Deployment aborted. Please check the logs."
    print_info "Log file: $PROJECT_PATH/storage/logs/laravel.log"
    exit 1
}

# Trap errors
trap 'handle_error "$BASH_COMMAND"' ERR

# ===============================
# Pre-Deployment Checks
# ===============================
echo ""
echo "======================================"
echo "   Laravel Deployment Script"
echo "======================================"
echo ""

print_info "Project: $PROJECT_NAME"
print_info "Path: $PROJECT_PATH"
print_info "Branch: $BRANCH"
print_info "PHP Version: $PHP_VERSION"
print_info "Time: $(date)"
echo ""

# Check if we're in the right directory
if [ ! -f "$PROJECT_PATH/artisan" ]; then
    print_error "Laravel project not found at $PROJECT_PATH"
    print_info "Usage: $0 [project_path] [branch]"
    print_info "Example: $0 /var/www/myapp main"
    exit 1
fi

# Change to project directory
print_info "Changing to directory: $PROJECT_PATH"
cd "$PROJECT_PATH" || {
    print_error "Failed to change to directory: $PROJECT_PATH"
    exit 1
}

# Debug: Show current directory and git status
print_info "Current directory: $(pwd)"
print_info "Checking for .git directory..."

# Check if this is a git repository
if [ ! -d ".git" ]; then
    print_error "This directory is not a git repository"
    print_info "Please initialize git or deploy from a git repository"
    print_info "Directory contents:"
    ls -la | head -10
    exit 1
fi

print_status "Git repository found"

# Disable git file mode tracking (prevents permission changes from showing as modifications)
# Use || true to prevent script exit if this fails
git config core.fileMode false || {
    print_warning "Could not set git config (continuing anyway)"
}

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

if [ -n "$DB_NAME" ] && [ -n "$DB_USER" ]; then
    if mysqldump -u"$DB_USER" -p"$DB_PASS" "$DB_NAME" > "$BACKUP_PATH/db_backup_$TIMESTAMP.sql" 2>/dev/null; then
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

# Step 1: Enable maintenance mode
print_info "Enabling maintenance mode..."
php artisan down --retry=60 --secret="deployment-$(date +%s)" || true
print_status "Maintenance mode enabled"

# Step 2: Pull latest code
print_info "Pulling latest code from GitHub..."
CURRENT_COMMIT=$(git rev-parse HEAD)
print_info "Current commit: $CURRENT_COMMIT"

# Check if remote exists before trying to fetch
if ! git remote get-url origin &>/dev/null; then
    print_error "No 'origin' remote configured"
    print_info "Please add a remote: git remote add origin <repository-url>"
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
    print_info "Changes:"
    git log --oneline $CURRENT_COMMIT..$NEW_COMMIT
fi

# Step 3: Install/Update Composer dependencies
print_info "Installing Composer dependencies..."
composer install --no-interaction --prefer-dist --optimize-autoloader --no-dev
print_status "Composer dependencies updated"

# Step 4: Run database migrations
print_info "Running database migrations..."
php artisan migrate --force
print_status "Database migrations completed"

# Step 5: Clear all caches
print_info "Clearing all caches..."
php artisan optimize:clear
php artisan cache:clear
print_status "Caches cleared"

# Step 6: Rebuild optimized caches (config, routes, views, events)
print_info "Rebuilding optimized caches..."
php artisan optimize
print_status "Caches rebuilt"

# Step 7: Storage link (if needed)
if [ ! -L "$PROJECT_PATH/public/storage" ]; then
    print_info "Creating storage symlink..."
    php artisan storage:link
    print_status "Storage symlink created"
else
    print_status "Storage symlink already exists"
fi

# Step 8: Reload services (Queue workers, Horizon, Octane, etc.)
print_info "Reloading services..."

# Try Laravel 11+ reload command first
if php artisan list 2>/dev/null | grep -q "reload"; then
    php artisan reload
    print_status "Services reloaded via artisan"
else
    print_info "artisan reload not available, restarting services manually..."
fi

# Restart queue workers with Supervisor
if command -v supervisorctl &> /dev/null; then
    if supervisorctl status ${PROJECT_NAME}-worker:* &>/dev/null; then
        print_info "Restarting Supervisor queue workers..."
        sudo supervisorctl restart ${PROJECT_NAME}-worker:* 2>/dev/null && print_status "Queue workers restarted" || print_warning "Failed to restart queue workers"
    else
        print_info "No Supervisor queue workers configured for this project"
    fi
fi

# Restart Horizon if running
if php artisan list 2>/dev/null | grep -q "horizon:terminate"; then
    if pgrep -f "horizon" > /dev/null; then
        print_info "Terminating Horizon workers..."
        php artisan horizon:terminate
        print_status "Horizon workers will restart automatically"
    fi
fi

# Step 9: Fix permissions (only for directories that need write access)
print_info "Setting proper permissions..."

# IMPORTANT: We only change permissions on storage and bootstrap/cache
# Changing permissions on all files causes git to show them as modified!

# Set ownership for web-writable directories only
sudo chown -R www-data:www-data "$PROJECT_PATH/storage" "$PROJECT_PATH/bootstrap/cache"

# Set writable permissions for storage and cache (the only dirs that need special permissions)
sudo chmod -R 775 "$PROJECT_PATH/storage" "$PROJECT_PATH/bootstrap/cache"

# Ensure storage subdirectories exist and are writable
mkdir -p "$PROJECT_PATH/storage/app/public" 2>/dev/null || true
mkdir -p "$PROJECT_PATH/storage/framework/cache" 2>/dev/null || true
mkdir -p "$PROJECT_PATH/storage/framework/sessions" 2>/dev/null || true
mkdir -p "$PROJECT_PATH/storage/framework/views" 2>/dev/null || true
mkdir -p "$PROJECT_PATH/storage/logs" 2>/dev/null || true

# Make artisan executable (this is typically already set in the repo)
sudo chmod +x "$PROJECT_PATH/artisan" 2>/dev/null || true

# Reset any permission changes that git might have tracked
# This prevents "modified" files from appearing after deployment
git config core.fileMode false
# Reset file permissions to what git expects (without changing content)
git diff --name-only 2>/dev/null | while read file; do
    if [ -f "$file" ]; then
        git checkout --quiet -- "$file" 2>/dev/null || true
    fi
done

print_status "Permissions set (storage & cache only)"

# Step 10: Restart PHP-FPM (user choice)
print_info "PHP-FPM restart is only needed for PHP configuration or OPcache changes"
read -p "Restart PHP-FPM? (y/n) [default: n]: " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    print_info "Restarting PHP-FPM (version $PHP_VERSION)..."
    if sudo systemctl restart php${PHP_VERSION}-fpm 2>/dev/null; then
        print_status "PHP-FPM restarted"
    else
        # Try reloading instead (graceful)
        sudo systemctl reload php${PHP_VERSION}-fpm 2>/dev/null && print_status "PHP-FPM reloaded" || print_warning "Could not restart/reload PHP-FPM"
    fi
else
    # Clear OPcache via PHP if available (doesn't require Laravel package)
    if php -m | grep -qi opcache; then
        php -r "if(function_exists('opcache_reset')) { opcache_reset(); echo 'OPcache cleared'; }" 2>/dev/null || true
    fi
    print_status "PHP-FPM restart skipped"
fi

# Step 11: Test application health
print_info "Testing application health..."

# Try to get the APP_URL from .env for accurate health check
APP_URL=$(grep -E "^APP_URL=" .env | cut -d '=' -f2 | tr -d '"' | tr -d "'")
HEALTH_URL="${APP_URL:-http://localhost}"

# First check if the /up health route exists (Laravel 10+)
HTTP_CODE=$(curl -o /dev/null -s -w "%{http_code}" --max-time 10 "${HEALTH_URL}/up" 2>/dev/null || echo "000")

if [ "$HTTP_CODE" = "000" ]; then
    # Fallback to localhost if APP_URL didn't work
    HTTP_CODE=$(curl -o /dev/null -s -w "%{http_code}" --max-time 10 "http://127.0.0.1/up" 2>/dev/null || echo "000")
fi

if [ "$HTTP_CODE" = "000" ]; then
    # Try root URL
    HTTP_CODE=$(curl -o /dev/null -s -w "%{http_code}" --max-time 10 "http://127.0.0.1" 2>/dev/null || echo "000")
fi

case "$HTTP_CODE" in
    200) print_status "Application is healthy (HTTP 200)" ;;
    503) print_warning "Application in maintenance mode (HTTP 503) - will be live after artisan up" ;;
    302|301) print_status "Application responding with redirect (HTTP $HTTP_CODE)" ;;
    000) print_warning "Could not connect to application (this may be normal if using custom domain)" ;;
    *) print_warning "Unexpected HTTP code: $HTTP_CODE (application may still work)" ;;
esac

# Step 12: Disable maintenance mode
print_info "Disabling maintenance mode..."
php artisan up
print_status "Maintenance mode disabled"

# ===============================
# Post-Deployment
# ===============================
echo ""
echo "======================================"
print_status "Deployment completed successfully!"
echo "======================================"
echo ""
print_info "Summary:"
print_info "  • Project: $PROJECT_NAME"
print_info "  • Previous commit: ${CURRENT_COMMIT:0:8}"
print_info "  • New commit: ${NEW_COMMIT:0:8}"
if [ -f "$BACKUP_PATH/db_backup_$TIMESTAMP.sql" ]; then
    print_info "  • Database backup: $BACKUP_PATH/db_backup_$TIMESTAMP.sql"
fi
print_info "  • Deployment time: $(date)"
echo ""
print_status "Your application is now live! 🚀"
echo ""

# Optional: Clean old backups (keep last 10)
print_info "Cleaning old backups..."
if [ -d "$BACKUP_PATH" ]; then
    cd "$BACKUP_PATH"
    ls -t db_backup_*.sql 2>/dev/null | tail -n +11 | xargs rm -f 2>/dev/null || true
    print_status "Old backups cleaned (kept last 10)"
fi

echo ""
print_info "Useful commands:"
echo "  • View logs: tail -f $PROJECT_PATH/storage/logs/laravel.log"
echo "  • Check queue: php artisan queue:work --once"
echo "  • View schedule: php artisan schedule:list"
echo "  • Rollback: cd $PROJECT_PATH && git reset --hard HEAD~1"
echo ""