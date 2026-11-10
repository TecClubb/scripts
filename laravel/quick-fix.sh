#!/bin/bash

# Quick Fix Script for ERR_CONNECTION_REFUSED
# Fixes common issues after Laravel installation

echo "=========================================="
echo "Laravel Quick Fix - Connection Refused"
echo "=========================================="
echo ""

# Check if Nginx is running
echo "[1] Checking Nginx status..."
if systemctl is-active --quiet nginx; then
    echo "✓ Nginx is running"
else
    echo "✗ Nginx is NOT running - attempting to start..."
    systemctl start nginx
    if systemctl is-active --quiet nginx; then
        echo "✓ Nginx started successfully"
    else
        echo "✗ Failed to start Nginx - checking logs..."
        journalctl -u nginx -n 50 --no-pager
        exit 1
    fi
fi
echo ""

# Check firewall status
echo "[2] Checking firewall status..."
if command -v ufw &> /dev/null; then
    UFW_STATUS=$(ufw status | grep -i "Status: active")
    if [ ! -z "$UFW_STATUS" ]; then
        echo "⚠ UFW Firewall is ACTIVE"
        echo ""
        echo "Current UFW rules:"
        ufw status numbered
        echo ""
        read -p "Allow HTTP (80) and HTTPS (443) ports? (y/n): " ALLOW_PORTS
        if [[ "$ALLOW_PORTS" =~ ^[Yy]$ ]]; then
            ufw allow 80/tcp
            ufw allow 443/tcp
            ufw allow 'Nginx Full'
            echo "✓ Firewall rules added"
            ufw status
        fi
    else
        echo "✓ UFW Firewall is inactive"
    fi
else
    echo "✓ UFW not installed"
fi
echo ""

# Check if ports are listening
echo "[3] Checking if Nginx is listening on ports 80/443..."
netstat -tlnp | grep -E ':(80|443)' || ss -tlnp | grep -E ':(80|443)'
echo ""

# Remove broken symlinks
echo "[4] Cleaning up broken Nginx symlinks..."
find /etc/nginx/sites-enabled/ -xtype l -delete 2>/dev/null && echo "✓ Removed broken symlinks" || echo "No broken symlinks found"
echo ""

# Show current Nginx configuration
echo "[5] Current Nginx enabled sites:"
ls -la /etc/nginx/sites-enabled/
echo ""

# Fix Nginx configuration
echo "[6] Ensuring correct Nginx configuration..."
read -p "Enter project name [e.g., panel.safeprovpn]: " PROJECT_NAME

if [ -f "/etc/nginx/sites-available/$PROJECT_NAME" ]; then
    echo "Found config: /etc/nginx/sites-available/$PROJECT_NAME"
    
    # Create/update symlink
    ln -sf /etc/nginx/sites-available/$PROJECT_NAME /etc/nginx/sites-enabled/
    echo "✓ Symlink created"
    
    # Test Nginx config
    echo ""
    echo "Testing Nginx configuration..."
    if nginx -t; then
        echo "✓ Nginx config is valid"
        echo ""
        echo "Restarting Nginx..."
        systemctl restart nginx
        echo "✓ Nginx restarted"
    else
        echo "✗ Nginx config test failed!"
        exit 1
    fi
else
    echo "✗ Config file not found: /etc/nginx/sites-available/$PROJECT_NAME"
    echo ""
    echo "Available configs:"
    ls -la /etc/nginx/sites-available/
    exit 1
fi
echo ""

# Check SSL certificates
echo "[7] Checking SSL certificates..."
read -p "Enter primary domain [e.g., panel.safeprovpn.com]: " PRIMARY_DOMAIN
if [ -d "/etc/letsencrypt/live/$PRIMARY_DOMAIN" ]; then
    echo "✓ SSL certificate found for $PRIMARY_DOMAIN"
    certbot certificates | grep "$PRIMARY_DOMAIN" -A 5
else
    echo "⚠ No SSL certificate found for $PRIMARY_DOMAIN"
    echo ""
    read -p "Install SSL certificate now? (y/n): " INSTALL_SSL
    if [[ "$INSTALL_SSL" =~ ^[Yy]$ ]]; then
        read -p "Enter email for SSL: " SSL_EMAIL
        certbot --nginx -d $PRIMARY_DOMAIN --non-interactive --agree-tos --redirect --email $SSL_EMAIL
    fi
fi
echo ""

# Final checks
echo "=========================================="
echo "Final System Check"
echo "=========================================="
echo ""
echo "Nginx Status:"
systemctl status nginx --no-pager -l | head -10
echo ""
echo "Open Ports:"
netstat -tlnp | grep -E ':(80|443)' || ss -tlnp | grep -E ':(80|443)'
echo ""
echo "Recent Nginx Errors:"
tail -n 10 /var/log/nginx/error.log
echo ""
echo "=========================================="
echo "Try accessing your site now!"
echo "If still not working, check:"
echo "1. DNS is pointing to your server IP"
echo "2. Server firewall allows ports 80 and 443"
echo "3. Your hosting provider's firewall settings"
echo "=========================================="
