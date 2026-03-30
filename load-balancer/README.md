# Laravel 4-VPS Production Architecture

A fully scripted setup for deploying a Laravel application across 4 VPS servers with load balancing, shared Redis sessions, MinIO object storage, and horizontal scaling support.

---

## Architecture Overview

```
                        ┌─────────────────────────────────────┐
                        │         Public Internet              │
                        └──────────────────┬──────────────────┘
                                           │ :80 / :443
                        ┌──────────────────▼──────────────────┐
                        │          VPS 1 — Load Balancer       │
                        │    Nginx (least_conn upstream)       │
                        │    Certbot SSL                       │
                        └──────────┬──────────────┬───────────┘
                     Private :80   │              │  Private :80
              ┌──────────────────── ┘              └────────────────────┐
              │                                                         │
┌─────────────▼────────────────┐              ┌──────────────────────── ▼──────────────┐
│     VPS 2 — App Server A     │              │      VPS 3 — App Server B              │
│  PHP-FPM + Nginx + Laravel   │              │   PHP-FPM + Nginx + Laravel            │
│  Supervisor queue workers    │              │   Supervisor queue workers             │
│  Laravel Scheduler (cron)    │              │   (no scheduler — VPS2 only)          │
│  Runs migrations             │              │   (no migrations — VPS2 only)         │
└──────────┬───────────────────┘              └────────────────┬───────────────────────┘
           │                                                   │
           │          Private network (DB/Redis/S3)            │
           └─────────────────────┬─────────────────────────────┘
                                 │
                ┌────────────────▼────────────────────┐
                │         VPS 4 — Core Server          │
                │  MySQL   (private IP :3306)          │
                │  Redis   (private IP :6379)          │
                │  MinIO   (private IP :9000)          │
                │  UFW: only VPS2+VPS3 can connect     │
                └─────────────────────────────────────┘
```

---

## Scripts

| Script | Server | Purpose |
|---|---|---|
| `vps4-core.sh` | VPS 4 | MySQL + Redis + MinIO + UFW (accepts unlimited app server IPs) |
| `vps-app.sh` | VPS 2, VPS 3, any additional | Single app server setup with **role selector** (primary / secondary) |
| `vps1-loadbalancer.sh` | VPS 1 | Nginx upstream + SSL via Certbot |
| `deploy.sh` | Any app server | Single deploy script with **role selector** (primary / secondary) |

---

## Setup Order

**Always follow this order.** VPS4 must be running before app servers can connect.

### Step 1 — VPS 4 (Core Server)

```bash
bash vps4-core.sh
```

You will be prompted for:
- Private IP to bind MySQL, Redis, and MinIO to
- MySQL root password, DB name, DB user, DB password
- Redis password
- MinIO admin credentials and storage path
- VPS2 and VPS3 private IPs (for UFW rules)

Save all credentials from the summary — you'll need them for VPS2 and VPS3.

---

### Step 2 — VPS 2 (Primary App Server)

```bash
bash vps-app.sh
```

Select role **`1) Primary`** when prompted.

You will be prompted for:
- PHP version, project name, web root, domain
- VPS4 private IP and all DB/Redis/MinIO credentials from Step 1
- GitHub repo URL and auth method (SSH or PAT)
- Number of queue workers, queue connection name
- VPS1 private IP (for UFW — allow HTTP from load balancer)

This server:
- Runs `php artisan migrate --force`
- Sets up the Laravel scheduler cron (every minute, as `www-data`)
- Starts Supervisor queue workers

---

### Step 3 — VPS 3 (Secondary App Server)

```bash
bash vps-app.sh
```

Select role **`2) Secondary`** when prompted.

Same inputs as VPS2. This server:
- **No migrations** — primary server handles this
- **No scheduler** — primary server handles this
- **No cluster prompt** — answer `n` (VPS3 is already included in `vps1-loadbalancer.sh` setup)

---

### Step 4 — VPS 1 (Load Balancer)

```bash
bash vps1-loadbalancer.sh
```

You will be prompted for:
- Domain name(s) (comma-separated)
- VPS2 and VPS3 private IPs
- SSL email for Certbot
- Whether to enable SSL (y/n)

The Nginx upstream uses `least_conn` and proxies to both app servers on port 80.

---

## Post-Setup Checklist

Run through this after all 4 servers are online:

- [ ] **Add TrustProxies** — Edit `App\Http\Middleware\TrustProxies.php` on both VPS2 and VPS3. Set `$proxies` to VPS1's private IP so that `$request->ip()` and HTTPS detection work correctly behind the load balancer.
  ```php
  protected $proxies = ['<VPS1_PRIVATE_IP>'];
  ```
  Or for Laravel 11+ in `bootstrap/app.php`:
  ```php
  ->withMiddleware(function (Middleware $middleware) {
      $middleware->trustProxies(at: '<VPS1_PRIVATE_IP>');
  })
  ```

- [ ] **Point DNS** — Set your domain's `A` record to VPS1's **public** IP address.

- [ ] **Test app servers directly** before enabling the load balancer. From a machine that can reach their private IPs (or temporarily open port 80), check that VPS2 and VPS3 serve the app correctly on their own.

- [ ] **Verify Redis session sharing** — Log in through VPS2's direct URL. Then hit VPS3 directly. You should still be logged in, confirming that sessions are stored in the shared Redis on VPS4.

- [ ] **Confirm MinIO bucket exists** — `vps4-core.sh` creates the bucket automatically using `mc`. Verify it was created:
  ```bash
  mc alias set myminio http://<VPS4_PRIVATE_IP>:9000 <MINIO_USER> <MINIO_PASSWORD>
  mc ls myminio
  ```
  If it's missing (e.g. `mc` download failed), create it manually:
  ```bash
  mc mb myminio/<BUCKET_NAME>
  ```

- [ ] **Verify queue workers** on both VPS2 and VPS3:
  ```bash
  supervisorctl status
  ```

- [ ] **Verify scheduler** (VPS2 only):
  ```bash
  crontab -l -u www-data
  ```

- [ ] **Check UFW rules** on VPS4 only allow connections from VPS2 and VPS3:
  ```bash
  ufw status verbose
  ```

---

## Deployment Workflow

Deploy to **all app servers on every release**, always starting with the primary (migrations run first).

### Recommended sequence:

```bash
# On VPS2 (primary) — runs migrations + restarts scheduler
bash deploy.sh /var/www/my-app main primary

# On VPS3 and any additional servers — skips migrations, skips scheduler
bash deploy.sh /var/www/my-app main secondary
```

Or omit the role argument and you'll be prompted interactively:
```bash
bash deploy.sh /var/www/my-app main
```

> Both servers share the same MySQL database on VPS4. Migrations only need to run once — always on the primary. All other servers pick up the schema automatically.

### Deploy script features:

- Puts site in maintenance mode (`php artisan down`) before starting
- Creates a timestamped database backup before pulling code
- Runs `composer install --no-dev`
- Runs `php artisan optimize:clear` then `php artisan optimize`
- Restarts Supervisor queue workers
- Auto-rollback on failure via `trap ERR` (reverts git, restores vendor)
- Health check via HTTP after deployment
- Brings site back up (`php artisan up`) at the end
- Cleans old DB backups (keeps last 10)

---

## Useful Commands Per Server

### VPS 1 — Load Balancer

```bash
nginx -t && systemctl reload nginx     # Reload config gracefully (no downtime)
systemctl restart nginx                 # Full restart
tail -f /var/log/nginx/access.log      # Watch incoming traffic
tail -f /var/log/nginx/error.log       # Watch errors
certbot renew --dry-run                # Test SSL renewal
ufw status verbose                     # Check firewall
cat /etc/nginx/sites-available/loadbalancer.conf
```

### VPS 2 — Primary App Server

```bash
supervisorctl status                                # Queue worker status
supervisorctl restart <project>-worker:*           # Restart workers
crontab -l -u www-data                             # Check scheduler cron
systemctl restart php8.3-fpm                       # Restart PHP-FPM
tail -f /var/www/<project>/storage/logs/laravel.log
tail -f /var/www/<project>/storage/logs/worker.log
cd /var/www/<project> && php artisan schedule:list
cd /var/www/<project> && php artisan queue:work --once
```

### VPS 3 — Secondary App Server

```bash
supervisorctl status                                # Queue worker status
supervisorctl restart <project>-worker:*           # Restart workers
systemctl restart php8.3-fpm
tail -f /var/www/<project>/storage/logs/laravel.log
tail -f /var/www/<project>/storage/logs/worker.log
```

### VPS 4 — Core Server

```bash
systemctl status mysql                             # MySQL status
systemctl status redis-server                      # Redis status
systemctl status minio                             # MinIO status
mysql -u root -p                                   # MySQL root console
redis-cli -h <PRIVATE_IP> -a <PASSWORD> ping       # Redis connectivity test
journalctl -u minio -f                             # MinIO live logs
ufw status verbose                                 # Firewall rules
```

---

## Scaling: Adding More App Servers

Use `vps-app.sh` in **secondary** mode whenever you need to add a new app server beyond VPS2 and VPS3.

### Steps:

1. **Provision a new VPS** with Ubuntu/Debian.

2. **Run `vps-app.sh`** on the new server:
   ```bash
   bash vps-app.sh
   ```
   - Select role: **`2) Secondary`**
   - When asked *"Adding to an existing running cluster?"* — answer **`y`**
   - Enter this server's private IP when prompted
   - Provide the same credentials used on VPS2/VPS3 (same DB, Redis, MinIO)

3. **SSH into VPS1** and update the Nginx upstream:
   ```bash
   nano /etc/nginx/sites-available/loadbalancer.conf
   ```
   Add the new server inside the `upstream laravel_app` block:
   ```nginx
   upstream laravel_app {
       least_conn;
       server <VPS2_PRIVATE_IP>:80;
       server <VPS3_PRIVATE_IP>:80;
       server <NEW_VPS_PRIVATE_IP>:80;   # <-- add this line
   }
   ```

4. **Reload Nginx** (graceful, zero downtime):
   ```bash
   nginx -t && systemctl reload nginx
   ```

5. **Update VPS4 UFW rules** to allow the new server:
   ```bash
   ufw allow from <NEW_VPS_PRIVATE_IP> to any port 3306 proto tcp
   ufw allow from <NEW_VPS_PRIVATE_IP> to any port 6379 proto tcp
   ufw allow from <NEW_VPS_PRIVATE_IP> to any port 9000 proto tcp
   ```

6. **Verify** the new server is receiving traffic:
   ```bash
   tail -f /var/log/nginx/access.log   # on VPS1 — look for requests hitting the new upstream
   supervisorctl status                 # on new VPS — confirm queue workers are RUNNING
   ```

### Notes:
- VPS2, VPS3, and VPS4 require **no changes** when adding a new app server.
- The new server runs **no migrations** and **no scheduler** — both remain on VPS2.
- Nginx `reload` is graceful — in-flight requests are not dropped.
- The new server automatically shares sessions with existing app servers via Redis on VPS4.
