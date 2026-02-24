# Domain Manager Scripts

Simple tools for managing domains and SSL on your VPS.

## Scripts

### 1. `add-subdomain.sh` ⭐ Main Tool

Add new subdomains to your Laravel app with automatic SSL setup.

```bash
sudo ./add-subdomain.sh
```

**What it does:**
- Lists your nginx projects
- Adds new subdomain(s) to nginx config
- Updates all server blocks automatically
- Obtains/renews SSL certificates for all domains
- Tests each HTTPS URL

**Example:**
```bash
$ sudo ./add-subdomain.sh
Project name: myapp
New subdomain(s): api.example.com, cdn.example.com
Add SSL certificates? (y/n): y
✓ Done!
```

---

### 2. `emergency-fix.sh` 🚨 SSL Recovery

Use when SSL certificates are broken or nginx won't start.

```bash
sudo ./emergency-fix.sh
```

**What it does:**
- Removes broken SSL configuration
- Creates clean HTTP-only nginx config
- Obtains fresh SSL certificates
- Restores HTTPS for all domains

**When to use:**
- SSL certificate errors
- Nginx fails to start due to missing certificates
- After accidentally deleting certificates

---

## Quick Start

### First Time Setup

```bash
# Make scripts executable
chmod +x *.sh

# Copy to VPS
scp *.sh root@your-vps:/usr/local/bin/
```

### Adding Subdomains

1. **Point DNS A record** to your VPS IP
2. **Wait 5-10 minutes** for DNS propagation
3. **Run the script:**
   ```bash
   sudo ./add-subdomain.sh
   ```

### If Something Goes Wrong

```bash
sudo ./emergency-fix.sh
```

---

## Prerequisites

On your VPS, ensure these are installed:

```bash
sudo apt update
sudo apt install nginx certbot python3-certbot-nginx
```

---

## How It Works

### Adding Subdomains

1. Reads current domains from nginx config
2. Adds new subdomain(s) to `server_name` directive
3. Updates **all** server blocks (HTTP and HTTPS)
4. Runs certbot with `--force-renewal` to update certificate
5. Verifies each domain responds correctly

### Emergency Fix

1. Backs up current config
2. Removes all SSL-related lines
3. Creates clean HTTP-only config
4. Obtains fresh SSL certificates
5. Certbot automatically adds HTTPS configuration

---

## Troubleshooting

### DNS Not Resolving

```bash
# Check DNS
dig +short yourdomain.com

# Should return your VPS IP
```

### SSL Rate Limit

Let's Encrypt allows 5 certificates per week per domain. If you hit the limit:
- Wait a week, or
- Use `--staging` flag for testing

### Nginx Test Fails

```bash
# Check nginx config
sudo nginx -t

# View error logs
sudo tail -f /var/log/nginx/error.log
```

### Certificate Not Found

This means certificates were deleted. Use `emergency-fix.sh` to recover.

---

## File Locations

- **Nginx configs:** `/etc/nginx/sites-available/`
- **SSL certificates:** `/etc/letsencrypt/live/`
- **Backups:** Automatically created with timestamp

---

## Tips

- Always backup before making changes (scripts do this automatically)
- Test DNS before running scripts
- Use `emergency-fix.sh` if anything breaks
- Check `/var/log/letsencrypt/letsencrypt.log` for certbot errors

---

## Support

Common issues:

1. **"Certbot failed"** → Check DNS A records
2. **"Nginx test failed"** → Use emergency-fix.sh
3. **"Rate limit"** → Wait or use staging
4. **"404 response"** → Check Laravel routes and web root
