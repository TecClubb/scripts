# Scripts Collection

A collection of bash scripts for automating Laravel deployment and troubleshooting on Ubuntu/Debian servers.

## 📁 Repository Structure

```
├── laravel/
│   ├── laravel.sh              # Main Laravel auto-installer
│   ├── laravel-deploy.sh       # Production deployment script with rollback
│   ├── laravel-quick-fix.sh    # Quick fix for connection issues
│   └── laravel-troubleshoot.sh # Diagnostic troubleshooting script
```

---

## 🚀 Laravel Scripts

### 1. Laravel Auto-Installer (`laravel/laravel.sh`)

A comprehensive, interactive script that automates the complete Laravel deployment process on a fresh Ubuntu/Debian server.

#### Features

- **PHP Installation** - Supports PHP 8.2, 8.3, and 8.4 with essential extensions
- **Web Server** - Nginx configuration with optimized settings
- **Database** - MySQL setup with automatic user/database creation
- **SSL Certificates** - Let's Encrypt SSL via Certbot with auto-renewal
- **Git Integration** - Clone from private/public repos via SSH or HTTPS (PAT)
- **Redis Support** - Optional Redis for cache, queue, and sessions
- **Queue Workers** - Supervisor-managed Laravel queue workers
- **Task Scheduler** - Automated cron setup for Laravel scheduler
- **Multi-Domain Support** - Configure multiple domains/subdomains

#### Usage

```bash
# Download and run as root
sudo bash laravel.sh
```

#### Interactive Configuration

The script will prompt you for:

| Configuration | Description | Default |
|---------------|-------------|---------|
| PHP Version | 8.2, 8.3, or 8.4 | 8.3 |
| Project Name | Your Laravel project name | laravel-app |
| Server Domain(s) | Comma-separated domains | Required |
| Database Name | MySQL database name | laravel_db |
| Database User | MySQL username | laravel_user |
| Database Password | MySQL password | Auto-generated |
| Web Root | Installation directory | /var/www |
| Enable SSL | Setup Let's Encrypt | Yes |
| Environment | Production or Development | Production |
| Git Method | SSH or HTTPS (PAT) | SSH |
| Redis | Install and configure Redis | No |
| Queue Workers | Setup Supervisor workers | No |
| Scheduler | Setup Laravel cron | No |

#### What Gets Installed

- PHP with extensions: cli, common, curl, mbstring, mysql, xml, zip, fpm, bcmath
- Optional PHP extensions: gd, intl, soap, redis, memcached, imagick, ldap, imap
- Composer (globally)
- MySQL Server
- Nginx
- Certbot (Let's Encrypt)
- Redis (optional)
- Supervisor (if queue workers enabled)

---

### 2. Laravel Deployment Script (`laravel/laravel-deploy.sh`)

A production-ready deployment script for existing Laravel applications with automatic rollback capabilities.

#### Features

- **Zero Downtime** - Maintenance mode during deployment only
- **Automatic Rollback** - Restores previous version on any failure
- **Database Backups** - Automatic MySQL backup before deployment
- **Composer Optimization** - Installs dependencies with optimized autoloader
- **Cache Management** - Clears and rebuilds all Laravel caches
- **Queue Workers** - Restarts Supervisor-managed workers
- **Permission Fix** - Sets proper ownership and permissions
- **Health Checks** - Tests application response after deployment
- **Backup Cleanup** - Maintains only 10 most recent database backups

#### Usage

```bash
# Make executable
chmod +x laravel-deploy.sh

# Run deployment
./laravel-deploy.sh
```

#### Deployment Steps

1. Enable maintenance mode
2. Pull latest code from Git
3. Install/update Composer dependencies
4. Run database migrations
5. Clear all Laravel caches
6. Rebuild optimized caches
7. Create storage symlink (if needed)
8. Reload queue services
9. Fix file permissions
10. Optional PHP-FPM restart (user choice)
11. Test application health
12. Disable maintenance mode

#### Configuration

Edit the script variables at the top:

```bash
PROJECT_PATH="/var/www/your-project"  # Path to Laravel project
BRANCH="main"                         # Git branch to deploy
PROJECT_NAME="your-project"           # Name for Supervisor workers
BACKUP_PATH="/var/backups/laravel"    # Database backup location
```

---

### 3. Quick Fix Script (`laravel/laravel-quick-fix.sh`)

Rapidly diagnose and fix `ERR_CONNECTION_REFUSED` errors after Laravel installation.

#### Features

- ✅ Check and start Nginx service
- ✅ Configure UFW firewall rules (ports 80/443)
- ✅ Verify port listening status
- ✅ Clean up broken Nginx symlinks
- ✅ Recreate Nginx site symlinks
- ✅ Test and restart Nginx configuration
- ✅ Check and install SSL certificates

#### Usage

```bash
sudo bash laravel-quick-fix.sh
```

#### Checks Performed

1. **Nginx Status** - Verifies Nginx is running, attempts restart if not
2. **Firewall** - Detects active UFW and offers to allow HTTP/HTTPS
3. **Port Listening** - Confirms Nginx is bound to ports 80/443
4. **Symlink Cleanup** - Removes broken configuration links
5. **Site Configuration** - Recreates proper Nginx symlinks
6. **SSL Certificates** - Validates or installs Let's Encrypt certs

---

### 4. Troubleshooting Script (`laravel/laravel-troubleshoot.sh`)

Comprehensive diagnostic tool for investigating 404 errors and other post-installation issues.

#### Features

- 🔍 Nginx configuration validation
- 🔍 Site configuration inspection
- 🔍 Project directory verification
- 🔍 File permission analysis
- 🔍 PHP-FPM status check
- 🔍 Nginx error/access log review
- 🔍 DNS resolution testing

#### Usage

```bash
sudo bash laravel-troubleshoot.sh
```

#### Diagnostics Provided

| Check | Description |
|-------|-------------|
| Nginx Config | Validates nginx.conf syntax |
| Enabled Sites | Lists active site configurations |
| Site Config | Displays full Nginx site configuration |
| Project Directory | Verifies Laravel files exist |
| Permissions | Checks ownership and permissions |
| PHP-FPM | Confirms PHP processor is running |
| Error Logs | Shows recent Nginx errors |
| Access Logs | Shows recent access attempts |
| DNS | Resolves domain to IP address |

#### Quick Fix Commands

The script also outputs helpful commands:

```bash
# Restart services
systemctl restart nginx
systemctl restart php8.4-fpm

# Fix Nginx symlink
ln -sf /etc/nginx/sites-available/YOUR_PROJECT /etc/nginx/sites-enabled/

# Clear Laravel caches
php artisan config:clear
php artisan cache:clear
php artisan route:clear
php artisan view:clear

# Fix permissions
chown -R www-data:www-data /var/www/YOUR_PROJECT
chmod -R 755 /var/www/YOUR_PROJECT
```

---

## 📋 Requirements

- **Operating System**: Ubuntu 20.04+ / Debian 10+
- **Access Level**: Root or sudo privileges
- **Network**: Outbound internet access for package installation
- **DNS**: Domain pointed to server IP (for SSL)

---

## 🔧 Recommended Workflow

1. **Fresh Server Setup**
   ```bash
   sudo bash laravel/laravel.sh
   ```

2. **Deploy Updates to Production**
   ```bash
   ./laravel/laravel-deploy.sh
   ```

3. **If Connection Refused**
   ```bash
   sudo bash laravel/laravel-quick-fix.sh
   ```

4. **If 404 or Other Issues**
   ```bash
   sudo bash laravel/laravel-troubleshoot.sh
   ```

---

## 📝 License

These scripts are provided as-is for automating Laravel deployments.

---

## 🤝 Contributing

Feel free to submit issues and pull requests to improve these scripts.
