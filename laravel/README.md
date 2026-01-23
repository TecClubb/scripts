# Laravel Deployment Scripts

A collection of bash scripts for deploying and managing Laravel applications on Ubuntu/Debian servers.

## 📁 Scripts Overview

| Script | Description |
|--------|-------------|
| `laravel.sh` | **Full Installation** - Sets up a complete Laravel environment on a fresh VPS (PHP, Nginx, MySQL, Redis, SSL, etc.) |
| `laravel-deploy.sh` | **Deploy Updates** - Safely deploys new code with automatic rollback on failure |
| `laravel-dev.sh` | **Development Setup** - Sets up a development environment |
| `laravel-deploy-dev.sh` | **Dev Deployment** - Deploys code in development mode |
| `laravel-quick-fix.sh` | **Quick Fixes** - Common quick fixes (permissions, cache clear, etc.) |
| `laravel-troubleshoot.sh` | **Troubleshooting** - Diagnose common Laravel issues |

---

## 🚀 Quick Start

### Moving Scripts from Windows to Linux

When transferring scripts from Windows to Linux, you **must** convert line endings from CRLF (Windows) to LF (Linux), otherwise you'll get errors like:
```
-bash: ./script.sh: /bin/bash^M: bad interpreter: No such file or directory
```

#### Method 1: Using `dos2unix` (Recommended)
```bash
# Install dos2unix
sudo apt-get install dos2unix

# Convert a single script
dos2unix laravel.sh

# Convert all scripts in the folder
dos2unix *.sh
```

#### Method 2: Using `sed`
```bash
# Convert line endings
sed -i 's/\r$//' laravel.sh

# For all scripts
sed -i 's/\r$//' *.sh
```

#### Method 3: Using `tr`
```bash
tr -d '\r' < laravel.sh > laravel-fixed.sh
mv laravel-fixed.sh laravel.sh
```

### Make Scripts Executable
```bash
chmod +x *.sh
```

---

## 📋 Script Details

### 1. `laravel.sh` - Full Installation

Installs a complete Laravel environment on a fresh VPS server.

**What it installs:**
- PHP 8.2/8.3/8.4 with all required extensions
- Nginx with optimized configuration
- MySQL Server
- Composer
- Redis (optional)
- SSL certificates via Certbot
- Supervisor for queue workers (optional)
- Cron job for Laravel scheduler (optional)

**Usage:**
```bash
sudo ./laravel.sh
```

**Interactive prompts will ask for:**
- PHP version
- Project name
- Domain(s)
- Database credentials
- GitHub repository URL
- SSL setup
- Redis setup
- Queue workers setup
- Scheduler setup

---

### 2. `laravel-deploy.sh` - Deploy Updates

Safely deploys new code with automatic rollback on failure.

**Features:**
- Automatic database backup before deployment
- Maintenance mode during deployment
- Git pull with rollback capability
- Composer dependency updates
- Database migrations
- Cache optimization
- Queue worker restart
- Health check verification

**Usage:**
```bash
# Default (uses configured path)
sudo ./laravel-deploy.sh

# With custom path and branch
sudo ./laravel-deploy.sh /var/www/myapp main

# With different branch
sudo ./laravel-deploy.sh /var/www/myapp develop
```

---

### 3. `laravel-quick-fix.sh` - Quick Fixes

Quick fixes for common Laravel issues.

**Usage:**
```bash
sudo ./laravel-quick-fix.sh
```

---

### 4. `laravel-troubleshoot.sh` - Troubleshooting

Diagnoses common Laravel deployment issues.

**Usage:**
```bash
sudo ./laravel-troubleshoot.sh
```

---

## 🔧 Common Commands Reference

### Permissions Fix
```bash
sudo chown -R www-data:www-data /var/www/yourproject/storage /var/www/yourproject/bootstrap/cache
sudo chmod -R 775 /var/www/yourproject/storage /var/www/yourproject/bootstrap/cache
```

### Clear All Caches
```bash
cd /var/www/yourproject
php artisan optimize:clear
php artisan cache:clear
```

### Rebuild Caches
```bash
php artisan optimize
```

### Restart Services
```bash
# PHP-FPM
sudo systemctl restart php8.4-fpm

# Nginx
sudo systemctl restart nginx

# Queue Workers
sudo supervisorctl restart yourproject-worker:*

# Redis
sudo systemctl restart redis-server
```

### View Logs
```bash
# Laravel logs
tail -f /var/www/yourproject/storage/logs/laravel.log

# Nginx error log
tail -f /var/log/nginx/error.log

# PHP-FPM log
tail -f /var/log/php8.4-fpm.log
```

### Database Operations
```bash
# Run migrations
php artisan migrate --force

# Rollback last migration
php artisan migrate:rollback

# Fresh migration (WARNING: drops all tables)
php artisan migrate:fresh --seed
```

### Queue Management
```bash
# Process one job
php artisan queue:work --once

# Check failed jobs
php artisan queue:failed

# Retry failed jobs
php artisan queue:retry all

# Clear failed jobs
php artisan queue:flush
```

### Scheduler
```bash
# View scheduled tasks
php artisan schedule:list

# Run scheduler manually
php artisan schedule:run

# Check crontab
crontab -l -u www-data
```

---

## 🛠️ Customization

### Editing Default Configuration

Each script has a configuration section at the top. Edit these values to match your setup:

```bash
# Example from laravel-deploy.sh
PROJECT_PATH="/var/www/yourproject"
BRANCH="main"
```

### Creating Project-Specific Deploy Scripts

```bash
# Copy and customize for each project
cp laravel-deploy.sh myproject-deploy.sh

# Edit the configuration
nano myproject-deploy.sh
```

---

## ⚠️ Troubleshooting

### Script won't run: "Permission denied"
```bash
chmod +x script.sh
```

### Script fails: "bad interpreter"
```bash
dos2unix script.sh
# or
sed -i 's/\r$//' script.sh
```

### "Command not found" errors
Make sure you're running as root or with sudo:
```bash
sudo ./laravel.sh
```

### Nginx configuration test fails
```bash
sudo nginx -t
# Check the specific error and fix the config file
sudo nano /etc/nginx/sites-available/yourproject
```

### PHP-FPM socket not found
```bash
# Check PHP-FPM is running
sudo systemctl status php8.4-fpm

# Check socket exists
ls -la /var/run/php/
```

### Cron job not running
```bash
# Verify cron service is running
sudo systemctl status cron

# Check crontab was set
crontab -l -u www-data

# Check cron logs
grep CRON /var/log/syslog
```

### Queue workers not processing
```bash
# Check supervisor status
sudo supervisorctl status

# Restart workers
sudo supervisorctl restart all

# Check worker logs
tail -f /var/www/yourproject/storage/logs/worker.log
```

---

## 📝 License

These scripts are provided as-is for personal and commercial use.

---

## 🔄 Version History

- **v1.0** - Initial release with full installation and deployment scripts
- **v1.1** - Added Redis support, improved cron job setup, better Nginx config
- **v1.2** - Added Laravel 12.x support, `php artisan optimize` command, improved error handling
