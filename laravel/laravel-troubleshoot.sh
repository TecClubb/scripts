#!/bin/bash

# Laravel Installation Troubleshooting Script
# Run this to diagnose 404 errors after installation

echo "==================================================="
echo "Laravel Installation Troubleshooting"
echo "==================================================="
echo ""

# 1. Check Nginx configuration
echo "[1] Checking Nginx configuration..."
echo "---------------------------------------------------"
nginx -t
echo ""

# 2. List enabled sites
echo "[2] Nginx enabled sites:"
echo "---------------------------------------------------"
ls -la /etc/nginx/sites-enabled/
echo ""

# 3. Show Nginx configuration for your project
echo "[3] Nginx site configuration:"
echo "---------------------------------------------------"
echo "Available sites:"
ls -la /etc/nginx/sites-available/
echo ""
read -p "Enter your project name to view config [e.g., panel.safeprovpn]: " PROJECT_NAME
if [ -f "/etc/nginx/sites-available/$PROJECT_NAME" ]; then
    cat /etc/nginx/sites-available/$PROJECT_NAME
else
    echo "Config file not found for: $PROJECT_NAME"
    echo "Showing all available configs:"
    cat /etc/nginx/sites-available/* 2>/dev/null
fi
echo ""

# 4. Check if project directory exists
echo "[4] Checking project directory..."
echo "---------------------------------------------------"
read -p "Enter project path [e.g., /var/www/panel.safeprovpn]: " PROJECT_PATH
if [ -d "$PROJECT_PATH" ]; then
    echo "✓ Project directory exists: $PROJECT_PATH"
    echo ""
    echo "Public directory contents:"
    ls -la "$PROJECT_PATH/public/" 2>/dev/null || echo "Public directory not found!"
    echo ""
    echo "Index.php exists:"
    ls -la "$PROJECT_PATH/public/index.php" 2>/dev/null || echo "✗ index.php NOT FOUND!"
else
    echo "✗ Project directory NOT FOUND: $PROJECT_PATH"
fi
echo ""

# 5. Check file permissions
echo "[5] Checking file permissions..."
echo "---------------------------------------------------"
if [ -d "$PROJECT_PATH" ]; then
    ls -ld "$PROJECT_PATH"
    ls -ld "$PROJECT_PATH/public" 2>/dev/null
    ls -la "$PROJECT_PATH/public/index.php" 2>/dev/null
else
    echo "Cannot check - directory doesn't exist"
fi
echo ""

# 6. Check PHP-FPM status
echo "[6] Checking PHP-FPM status..."
echo "---------------------------------------------------"
systemctl status php8.4-fpm --no-pager -l | head -20
echo ""

# 7. Check Nginx error logs
echo "[7] Recent Nginx error logs:"
echo "---------------------------------------------------"
tail -n 50 /var/log/nginx/error.log
echo ""

# 8. Check Nginx access logs
echo "[8] Recent Nginx access logs:"
echo "---------------------------------------------------"
tail -n 20 /var/log/nginx/access.log
echo ""

# 9. Test DNS resolution
echo "[9] Testing DNS resolution..."
echo "---------------------------------------------------"
read -p "Enter domain to test [e.g., panel.safeprovpn.com]: " TEST_DOMAIN
if [ ! -z "$TEST_DOMAIN" ]; then
    echo "DNS resolution for $TEST_DOMAIN:"
    nslookup "$TEST_DOMAIN" || dig "$TEST_DOMAIN" +short
    echo ""
    echo "Server's public IP:"
    curl -s ifconfig.me
fi
echo ""

echo "==================================================="
echo "Quick Fixes to Try:"
echo "==================================================="
echo "1. Restart Nginx:"
echo "   systemctl restart nginx"
echo ""
echo "2. Restart PHP-FPM:"
echo "   systemctl restart php8.4-fpm"
echo ""
echo "3. Check Nginx symlink:"
echo "   ln -sf /etc/nginx/sites-available/YOUR_PROJECT /etc/nginx/sites-enabled/"
echo ""
echo "4. Clear Laravel cache:"
echo "   cd YOUR_PROJECT_PATH"
echo "   php artisan config:clear"
echo "   php artisan cache:clear"
echo "   php artisan route:clear"
echo "   php artisan view:clear"
echo ""
echo "5. Fix permissions:"
echo "   chown -R www-data:www-data YOUR_PROJECT_PATH"
echo "   chmod -R 755 YOUR_PROJECT_PATH"
echo "==================================================="
