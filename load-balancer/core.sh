#!/bin/bash

# VPS4 Core Server Setup Script
# Installs and configures MySQL, Redis, and MinIO for the core data layer
# Part of a 4-VPS Laravel production architecture

set -e

# ===============================
# Colors for terminal output
# ===============================
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

print_status()  { echo -e "${GREEN}[INFO]${NC} $1"; }
print_error()   { echo -e "${RED}[ERROR]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
print_section() { echo -e "\n${BLUE}=== $1 ===${NC}\n"; }

# ===============================
# Error Handler
# ===============================
handle_error() {
    print_error "Setup failed at step: $1"
    print_error "Please check the output above and re-run after fixing the issue."
    exit 1
}
trap 'handle_error "$BASH_COMMAND"' ERR

# ===============================
# Pre-flight Checks
# ===============================
print_section "Pre-flight Checks"

if [[ $EUID -ne 0 ]]; then
    print_error "This script must be run as root. Try using sudo."
    exit 1
fi

if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS=$NAME
    OS_VERSION=$VERSION_ID
else
    print_error "Cannot detect OS. This script requires Ubuntu/Debian."
    exit 1
fi

print_status "Detected OS: $OS $OS_VERSION"

if [[ ! "$OS" =~ (Ubuntu|Debian) ]]; then
    print_warning "This script is designed for Ubuntu/Debian. Proceeding anyway..."
fi

# ===============================
# Configuration
# ===============================
print_section "Configuration"

read -p "Enter this server's Private IP address: " PRIVATE_IP
if [ -z "$PRIVATE_IP" ]; then
    print_error "Private IP is required."
    exit 1
fi
print_status "Private IP: $PRIVATE_IP"

echo ""
echo "MySQL Configuration:"
if command -v mysql &>/dev/null && (systemctl is-active --quiet mysql 2>/dev/null || systemctl is-active --quiet mariadb 2>/dev/null); then
    print_warning "MySQL is already installed on this server."
    print_warning "Enter the EXISTING root password so the script can configure the database."
    print_warning "If you need to reset it first, press Ctrl+C and run:"
    print_warning "  systemctl stop mysql"
    print_warning "  echo -e '[mysqld]\nskip-grant-tables\nskip-networking' > /etc/mysql/conf.d/reset-temp.cnf"
    print_warning "  systemctl start mysql && sleep 2"
    print_warning "  mysql -e \"FLUSH PRIVILEGES; ALTER USER 'root'@'localhost' IDENTIFIED WITH caching_sha2_password BY 'YourNewPass';\""
    print_warning "  rm /etc/mysql/conf.d/reset-temp.cnf && systemctl restart mysql"
    echo ""
    read -sp "Enter EXISTING MySQL root password: " MYSQL_ROOT_PASSWORD
    echo
    if [ -z "$MYSQL_ROOT_PASSWORD" ]; then
        print_error "Root password is required when MySQL is already installed."
        exit 1
    fi
else
    read -sp "Enter MySQL root password (leave empty to auto-generate): " MYSQL_ROOT_PASSWORD
    echo
    if [ -z "$MYSQL_ROOT_PASSWORD" ]; then
        MYSQL_ROOT_PASSWORD="$(openssl rand -base64 12 | tr -d '=+/' | cut -c1-16)"
        print_warning "Auto-generated MySQL root password: $MYSQL_ROOT_PASSWORD"
    fi
fi

read -p "Enter Database Name [default: laravel_db]: " DB_NAME
DB_NAME=${DB_NAME:-laravel_db}

read -p "Enter Database Username [default: laravel_user]: " DB_USER
DB_USER=${DB_USER:-laravel_user}

read -sp "Enter Database Password (leave empty to auto-generate): " DB_PASSWORD
echo
if [ -z "$DB_PASSWORD" ]; then
    DB_PASSWORD="$(openssl rand -base64 12 | tr -d '=+/' | cut -c1-16)"
    print_warning "Auto-generated DB user password: $DB_PASSWORD"
fi

echo ""
echo "Redis Configuration:"
read -sp "Enter Redis password (leave empty to auto-generate): " REDIS_PASSWORD
echo
if [ -z "$REDIS_PASSWORD" ]; then
    REDIS_PASSWORD="$(openssl rand -base64 12 | tr -d '=+/' | cut -c1-16)"
    print_warning "Auto-generated Redis password: $REDIS_PASSWORD"
fi

echo ""
echo "MinIO Configuration:"
read -p "Enter MinIO admin username [default: minioadmin]: " MINIO_USER
MINIO_USER=${MINIO_USER:-minioadmin}

read -sp "Enter MinIO admin password (leave empty to auto-generate): " MINIO_PASSWORD
echo
if [ -z "$MINIO_PASSWORD" ]; then
    MINIO_PASSWORD="$(openssl rand -base64 12 | tr -d '=+/' | cut -c1-16)"
    print_warning "Auto-generated MinIO password: $MINIO_PASSWORD"
fi

read -p "Enter MinIO storage path [default: /mnt/data]: " MINIO_PATH
MINIO_PATH=${MINIO_PATH:-/mnt/data}

read -p "Enter MinIO bucket name to create [default: laravel-bucket]: " MINIO_BUCKET
MINIO_BUCKET=${MINIO_BUCKET:-laravel-bucket}

echo ""
echo "Firewall Configuration:"
echo "Enter the private IP of each app server that needs access to MySQL, Redis, and MinIO."
echo "At least one IP is required. Press Enter with an empty value when done."
APP_SERVER_IPS=()
while true; do
    read -p "  App server IP #$((${#APP_SERVER_IPS[@]} + 1)) [press Enter to finish]: " APP_IP
    if [ -z "$APP_IP" ]; then
        if [ ${#APP_SERVER_IPS[@]} -eq 0 ]; then
            print_error "At least one app server IP is required."
            continue
        fi
        break
    fi
    APP_SERVER_IPS+=("$APP_IP")
    print_status "Added: $APP_IP"
done
print_status "${#APP_SERVER_IPS[@]} app server(s) registered: ${APP_SERVER_IPS[*]}"

# ===============================
# Install Base Dependencies
# ===============================
print_section "Installing Base Dependencies"

print_status "Updating package lists..."
apt-get update -qq

BASE_PACKAGES=(
    "curl"
    "wget"
    "unzip"
    "software-properties-common"
    "apt-transport-https"
    "ca-certificates"
    "gnupg"
    "lsb-release"
    "ufw"
)

for pkg in "${BASE_PACKAGES[@]}"; do
    if ! dpkg -l | grep -q "^ii  $pkg "; then
        print_status "Installing $pkg..."
        apt-get install -y $pkg -qq
    else
        print_status "$pkg is already installed"
    fi
done

# ===============================
# Install and Configure MySQL
# ===============================
print_section "Installing MySQL"

if command -v mysql &> /dev/null; then
    print_status "MySQL is already installed"
else
    print_status "Installing MySQL Server..."
    DEBIAN_FRONTEND=noninteractive apt-get install -y mysql-server
fi

systemctl enable mysql 2>/dev/null || systemctl enable mariadb 2>/dev/null || true
systemctl start mysql 2>/dev/null || systemctl start mariadb 2>/dev/null || true

if systemctl is-active --quiet mysql || systemctl is-active --quiet mariadb; then
    print_status "MySQL is running"
else
    print_error "MySQL failed to start!"
    exit 1
fi

# -----------------------------------------------
# Probe which MySQL auth method works
# -----------------------------------------------
print_status "Probing MySQL root authentication..."
MYSQL_CMD=""

if mysql -e "SELECT 1;" 2>/dev/null; then
    # auth_socket is active — set a real password now
    print_status "Connected via auth_socket (OS root). Setting root password..."
    if mysql -e "ALTER USER 'root'@'localhost' IDENTIFIED WITH caching_sha2_password BY '${MYSQL_ROOT_PASSWORD}';" 2>/dev/null; then
        print_status "Root password set using caching_sha2_password"
        mysql -e "FLUSH PRIVILEGES;" 2>/dev/null || true
        MYSQL_CMD="mysql -u root -p${MYSQL_ROOT_PASSWORD}"
    elif mysql -e "ALTER USER 'root'@'localhost' IDENTIFIED BY '${MYSQL_ROOT_PASSWORD}';" 2>/dev/null; then
        print_status "Root password set"
        mysql -e "FLUSH PRIVILEGES;" 2>/dev/null || true
        MYSQL_CMD="mysql -u root -p${MYSQL_ROOT_PASSWORD}"
    else
        print_warning "Could not set root password — continuing with auth_socket for this session"
        MYSQL_CMD="mysql"
    fi
elif mysql -u root -p"${MYSQL_ROOT_PASSWORD}" -e "SELECT 1;" 2>/dev/null; then
    print_status "Connected with provided root password"
    MYSQL_CMD="mysql -u root -p${MYSQL_ROOT_PASSWORD}"
else
    print_error "Cannot connect to MySQL as root."
    print_error "The root account may have a different password. To fix, run on this server:"
    print_error "  sudo mysql                            # if auth_socket is available"
    print_error "  ALTER USER 'root'@'localhost' IDENTIFIED BY '${MYSQL_ROOT_PASSWORD}';"
    print_error "Then re-run this script."
    exit 1
fi

print_status "MySQL auth established (cmd: ${MYSQL_CMD%%-p*})"

# -----------------------------------------------
# Create database and remote-access user
# -----------------------------------------------
print_status "Creating database '$DB_NAME' and user '$DB_USER'..."
$MYSQL_CMD -e "CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\`;"
$MYSQL_CMD -e "DROP USER IF EXISTS '${DB_USER}'@'%';" 2>/dev/null || true
$MYSQL_CMD -e "CREATE USER '${DB_USER}'@'%' IDENTIFIED BY '${DB_PASSWORD}';"
$MYSQL_CMD -e "GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'%';"
$MYSQL_CMD -e "FLUSH PRIVILEGES;"
print_status "Database and user created with remote access (GRANT from '%')"

# Bind MySQL to private IP only
print_status "Binding MySQL to private IP: $PRIVATE_IP"
MYSQL_CONF="/etc/mysql/mysql.conf.d/mysqld.cnf"
if [ ! -f "$MYSQL_CONF" ]; then
    MYSQL_CONF="/etc/mysql/my.cnf"
fi

if grep -q "^bind-address" "$MYSQL_CONF"; then
    sed -i "s/^bind-address.*/bind-address = $PRIVATE_IP/" "$MYSQL_CONF"
else
    echo "bind-address = $PRIVATE_IP" >> "$MYSQL_CONF"
fi

# Also disable mysqlx bind to private IP if present
if grep -q "^mysqlx-bind-address" "$MYSQL_CONF"; then
    sed -i "s/^mysqlx-bind-address.*/mysqlx-bind-address = $PRIVATE_IP/" "$MYSQL_CONF"
fi

systemctl restart mysql 2>/dev/null || systemctl restart mariadb 2>/dev/null

if systemctl is-active --quiet mysql || systemctl is-active --quiet mariadb; then
    print_status "MySQL restarted and bound to $PRIVATE_IP:3306"
else
    print_error "MySQL failed to restart after reconfiguration!"
    exit 1
fi

# ===============================
# Install and Configure Redis
# ===============================
print_section "Installing Redis"

if command -v redis-server &> /dev/null; then
    print_status "Redis is already installed"
else
    print_status "Installing Redis..."
    apt-get install -y redis-server
fi

print_status "Configuring Redis for private IP binding..."
REDIS_CONF="/etc/redis/redis.conf"

# Bind to private IP only
if grep -q "^bind " "$REDIS_CONF"; then
    sed -i "s/^bind .*/bind $PRIVATE_IP/" "$REDIS_CONF"
else
    echo "bind $PRIVATE_IP" >> "$REDIS_CONF"
fi

# Set password
if grep -q "^# requirepass foobared" "$REDIS_CONF"; then
    sed -i "s/^# requirepass foobared/requirepass $REDIS_PASSWORD/" "$REDIS_CONF"
elif grep -q "^requirepass" "$REDIS_CONF"; then
    sed -i "s/^requirepass .*/requirepass $REDIS_PASSWORD/" "$REDIS_CONF"
else
    echo "requirepass $REDIS_PASSWORD" >> "$REDIS_CONF"
fi

# Set maxmemory 512mb
if grep -q "^# maxmemory <bytes>" "$REDIS_CONF"; then
    sed -i "s/^# maxmemory <bytes>/maxmemory 512mb/" "$REDIS_CONF"
elif grep -q "^maxmemory " "$REDIS_CONF"; then
    sed -i "s/^maxmemory .*/maxmemory 512mb/" "$REDIS_CONF"
else
    echo "maxmemory 512mb" >> "$REDIS_CONF"
fi

# Set maxmemory-policy allkeys-lru
if grep -q "^# maxmemory-policy noeviction" "$REDIS_CONF"; then
    sed -i "s/^# maxmemory-policy noeviction/maxmemory-policy allkeys-lru/" "$REDIS_CONF"
elif grep -q "^maxmemory-policy " "$REDIS_CONF"; then
    sed -i "s/^maxmemory-policy .*/maxmemory-policy allkeys-lru/" "$REDIS_CONF"
else
    echo "maxmemory-policy allkeys-lru" >> "$REDIS_CONF"
fi

# Set supervised systemd
if grep -q "^supervised no" "$REDIS_CONF"; then
    sed -i "s/^supervised no/supervised systemd/" "$REDIS_CONF"
elif grep -q "^supervised " "$REDIS_CONF"; then
    sed -i "s/^supervised .*/supervised systemd/" "$REDIS_CONF"
else
    echo "supervised systemd" >> "$REDIS_CONF"
fi

systemctl enable redis-server
systemctl restart redis-server

if systemctl is-active --quiet redis-server; then
    print_status "Redis is running on $PRIVATE_IP:6379"
else
    print_error "Redis failed to start!"
    systemctl status redis-server --no-pager
    exit 1
fi

# ===============================
# Install and Configure MinIO
# ===============================
print_section "Installing MinIO"

# Create MinIO storage directory
print_status "Creating MinIO storage directory: $MINIO_PATH"
mkdir -p "$MINIO_PATH"

# Create minio system user if it doesn't exist
if ! id "minio-user" &>/dev/null; then
    useradd -r -s /sbin/nologin minio-user
    print_status "Created minio-user system account"
fi
chown -R minio-user:minio-user "$MINIO_PATH"

# Download MinIO binary
if [ -f /usr/local/bin/minio ]; then
    print_status "MinIO binary already exists at /usr/local/bin/minio"
else
    print_status "Downloading MinIO binary..."
    wget -q https://dl.min.io/server/minio/release/linux-amd64/minio -O /usr/local/bin/minio
    chmod +x /usr/local/bin/minio
    print_status "MinIO binary installed at /usr/local/bin/minio"
fi

# Create MinIO environment file
print_status "Writing MinIO environment file..."
cat > /etc/default/minio <<EOF
MINIO_ROOT_USER=${MINIO_USER}
MINIO_ROOT_PASSWORD=${MINIO_PASSWORD}
MINIO_VOLUMES=${MINIO_PATH}
MINIO_OPTS="--address ${PRIVATE_IP}:9000 --console-address ${PRIVATE_IP}:9001"
EOF
chmod 640 /etc/default/minio

# Create MinIO systemd service
print_status "Creating MinIO systemd service..."
cat > /etc/systemd/system/minio.service <<EOF
[Unit]
Description=MinIO Object Storage
After=network.target
Documentation=https://docs.min.io

[Service]
Type=notify
User=minio-user
Group=minio-user
EnvironmentFile=/etc/default/minio
ExecStart=/usr/local/bin/minio server \$MINIO_OPTS \$MINIO_VOLUMES
Restart=always
RestartSec=10
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable minio
systemctl start minio

sleep 3

if systemctl is-active --quiet minio; then
    print_status "MinIO is running on ${PRIVATE_IP}:9000 (API) and ${PRIVATE_IP}:9001 (Console)"
else
    print_error "MinIO failed to start!"
    systemctl status minio --no-pager
    exit 1
fi

# Download mc (MinIO client) and create the bucket
print_status "Downloading MinIO client (mc)..."
if [ ! -f /usr/local/bin/mc ]; then
    wget -q https://dl.min.io/client/mc/release/linux-amd64/mc -O /usr/local/bin/mc
    chmod +x /usr/local/bin/mc
    print_status "mc client installed at /usr/local/bin/mc"
else
    print_status "mc client already exists"
fi

print_status "Creating MinIO bucket: $MINIO_BUCKET"
mc alias set local_minio http://${PRIVATE_IP}:9000 "${MINIO_USER}" "${MINIO_PASSWORD}" --quiet
if mc mb --ignore-existing local_minio/${MINIO_BUCKET} 2>/dev/null; then
    print_status "Bucket '${MINIO_BUCKET}' created successfully"
else
    print_warning "Could not create bucket via mc — create it manually at http://${PRIVATE_IP}:9001"
fi

# ===============================
# Configure UFW Firewall
# ===============================
print_section "Configuring UFW Firewall"

print_status "Resetting UFW and applying restrictive rules..."
ufw --force reset
ufw default deny incoming
ufw default allow outgoing

# Allow SSH from everywhere
ufw allow 22/tcp comment 'SSH'

# MySQL, Redis, MinIO: allow from all registered app servers
for APP_IP in "${APP_SERVER_IPS[@]}"; do
    ufw allow from "$APP_IP" to any port 3306 proto tcp comment "MySQL from $APP_IP"
    ufw allow from "$APP_IP" to any port 6379 proto tcp comment "Redis from $APP_IP"
    ufw allow from "$APP_IP" to any port 9000 proto tcp comment "MinIO API from $APP_IP"
done

ufw --force enable

if systemctl is-active --quiet ufw 2>/dev/null || ufw status | grep -q "Status: active"; then
    print_status "UFW firewall is active"
else
    print_warning "UFW may not be active — run: ufw status"
fi

ufw status verbose

# ===============================
# Final Summary
# ===============================
echo ""
echo -e "${BLUE}============================================================${NC}"
echo -e "${GREEN}  VPS4 Core Server Setup Complete!${NC}"
echo -e "${BLUE}============================================================${NC}"
echo ""
print_status "=== Server ==="
print_status "  Private IP:                $PRIVATE_IP"
echo ""
print_status "=== MySQL ==="
print_status "  Root Password:             $MYSQL_ROOT_PASSWORD"
print_status "  Database:                  $DB_NAME"
print_status "  Username:                  $DB_USER"
print_status "  Password:                  $DB_PASSWORD"
print_status "  Bind Address:              $PRIVATE_IP:3306"
print_status "  Remote Grant:              '${DB_USER}'@'%' on \`${DB_NAME}\`.*"
echo ""
print_status "=== Redis ==="
print_status "  Password:                  $REDIS_PASSWORD"
print_status "  Bind Address:              $PRIVATE_IP:6379"
print_status "  Max Memory:                512mb (allkeys-lru)"
print_status "  Supervised:                systemd"
echo ""
print_status "=== MinIO ==="
print_status "  Admin User:                $MINIO_USER"
print_status "  Admin Password:            $MINIO_PASSWORD"
print_status "  API Endpoint:              http://${PRIVATE_IP}:9000"
print_status "  Console Endpoint:          http://${PRIVATE_IP}:9001"
print_status "  Storage Path:              $MINIO_PATH"
print_status "  Bucket Created:            $MINIO_BUCKET"
echo ""
print_status "=== Firewall ==="
print_status "  Port 22 (SSH):             open to all"
for APP_IP in "${APP_SERVER_IPS[@]}"; do
    print_status "  Ports 3306/6379/9000:      $APP_IP"
done
echo ""
print_status "=== .env Values for App Servers ==="
print_status "  DB_HOST=$PRIVATE_IP"
print_status "  DB_DATABASE=$DB_NAME"
print_status "  DB_USERNAME=$DB_USER"
print_status "  DB_PASSWORD=$DB_PASSWORD"
print_status "  REDIS_HOST=$PRIVATE_IP"
print_status "  REDIS_PASSWORD=$REDIS_PASSWORD"
print_status "  AWS_ENDPOINT=http://${PRIVATE_IP}:9000"
print_status "  AWS_ACCESS_KEY_ID=$MINIO_USER"
print_status "  AWS_SECRET_ACCESS_KEY=$MINIO_PASSWORD"
print_status "  AWS_BUCKET=$MINIO_BUCKET"
echo ""
print_status "=== Useful Commands ==="
print_status "  MySQL status:     systemctl status mysql"
print_status "  MySQL connect:    mysql -u root -p"
print_status "  Redis status:     systemctl status redis-server"
print_status "  Redis connect:    redis-cli -h $PRIVATE_IP -a '$REDIS_PASSWORD' ping"
print_status "  MinIO status:     systemctl status minio"
print_status "  MinIO logs:       journalctl -u minio -f"
print_status "  UFW status:       ufw status verbose"
echo -e "${BLUE}============================================================${NC}"
