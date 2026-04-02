#!/bin/bash

# Laravel Cluster Deployment Orchestration Script
# Deploys to all app servers in the cluster:
#   1. Deploy primary server first (runs migrations + scheduler)
#   2. Deploy all secondary servers in parallel
#   3. Health-check every server after deployment
#   4. Print final status table
#
# Config file: /etc/laravel-cluster/servers.conf
# Format per line: ROLE|IP|SSH_USER|SSH_KEY_PATH|PROJECT_PATH|BRANCH
# Example:
#   primary|10.0.0.2|root|~/.ssh/id_ed25519|/var/www/laravel-app|main
#   secondary|10.0.0.3|root|~/.ssh/id_ed25519|/var/www/laravel-app|main

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
    print_error "Script failed at step: $1"
    print_error "Please check the output above and re-run after fixing the issue."
    exit 1
}
trap 'handle_error "$BASH_COMMAND"' ERR

# ===============================
# Constants
# ===============================
CONFIG_FILE="/etc/laravel-cluster/servers.conf"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
START_TIME=$(date +%s)

# Arrays to hold server entries
# Each entry: "ROLE|IP|SSH_USER|SSH_KEY_PATH|PROJECT_PATH|BRANCH"
SERVERS=()

# ===============================
# Pre-flight Checks
# ===============================
print_section "Pre-flight Checks"

if [[ $EUID -ne 0 ]]; then
    print_error "This script must be run as root. Try using sudo."
    exit 1
fi

for cmd in ssh curl awk column; do
    if ! command -v "$cmd" &>/dev/null; then
        print_error "Required command not found: $cmd"
        exit 1
    fi
done
print_status "Required commands available"

# ===============================
# Step 1 — Load or Collect Server Config
# ===============================
print_section "Server Configuration"

parse_config_file() {
    local file="$1"
    local line_num=0
    while IFS= read -r line || [ -n "$line" ]; do
        line_num=$((line_num + 1))
        # Skip blank lines and comments
        [[ "$line" =~ ^[[:space:]]*$ ]] && continue
        [[ "$line" =~ ^# ]] && continue

        IFS='|' read -ra PARTS <<< "$line"
        if [ ${#PARTS[@]} -ne 6 ]; then
            print_warning "Skipping malformed line $line_num in config: $line"
            continue
        fi

        local role="${PARTS[0]}"
        local ip="${PARTS[1]}"
        local user="${PARTS[2]}"
        local key="${PARTS[3]}"
        local path="${PARTS[4]}"
        local branch="${PARTS[5]}"

        # Validate role
        if [[ "$role" != "primary" && "$role" != "secondary" ]]; then
            print_warning "Skipping line $line_num — invalid role '$role' (must be primary|secondary)"
            continue
        fi

        # Expand tilde in key path
        key="${key/#\~/$HOME}"

        SERVERS+=("${role}|${ip}|${user}|${key}|${path}|${branch}")
        print_status "Loaded server: [$role] $ip  ($user  $path  branch=$branch)"
    done < "$file"
}

if [ -f "$CONFIG_FILE" ]; then
    print_status "Found config file: $CONFIG_FILE"
    parse_config_file "$CONFIG_FILE"

    if [ ${#SERVERS[@]} -eq 0 ]; then
        print_error "Config file exists but contains no valid server entries."
        exit 1
    fi
else
    print_warning "Config file not found: $CONFIG_FILE"
    print_warning "Entering interactive mode to collect server information."
    echo ""

    while true; do
        echo "Add server #$((${#SERVERS[@]} + 1)):"

        read -p "  Role (primary/secondary): " srv_role
        if [[ "$srv_role" != "primary" && "$srv_role" != "secondary" ]]; then
            print_error "Role must be 'primary' or 'secondary'"
            continue
        fi

        read -p "  IP address: " srv_ip
        if [ -z "$srv_ip" ]; then
            print_error "IP address is required"
            continue
        fi

        read -p "  SSH user [default: root]: " srv_user
        srv_user=${srv_user:-root}

        read -p "  SSH key path [default: ~/.ssh/id_ed25519]: " srv_key
        srv_key=${srv_key:-~/.ssh/id_ed25519}
        srv_key="${srv_key/#\~/$HOME}"

        read -p "  Project path [default: /var/www/laravel-app]: " srv_path
        srv_path=${srv_path:-/var/www/laravel-app}

        read -p "  Branch [default: main]: " srv_branch
        srv_branch=${srv_branch:-main}

        SERVERS+=("${srv_role}|${srv_ip}|${srv_user}|${srv_key}|${srv_path}|${srv_branch}")
        print_status "Added: [$srv_role] $srv_ip"
        echo ""

        read -p "Add another server? (y/n) [default: n]: " ADD_MORE
        ADD_MORE=${ADD_MORE:-n}
        [[ "$ADD_MORE" =~ ^[Yy]$ ]] || break
    done

    if [ ${#SERVERS[@]} -eq 0 ]; then
        print_error "No servers configured. Aborting."
        exit 1
    fi

    echo ""
    read -p "Save this configuration for future runs? (y/n) [default: y]: " SAVE_CONFIG
    SAVE_CONFIG=${SAVE_CONFIG:-y}
    if [[ "$SAVE_CONFIG" =~ ^[Yy]$ ]]; then
        mkdir -p "$(dirname "$CONFIG_FILE")"
        : > "$CONFIG_FILE"
        for entry in "${SERVERS[@]}"; do
            echo "$entry" >> "$CONFIG_FILE"
        done
        chmod 600 "$CONFIG_FILE"
        print_status "Config saved to: $CONFIG_FILE"
    fi
fi

# Validate exactly one primary exists
PRIMARY_COUNT=0
for entry in "${SERVERS[@]}"; do
    IFS='|' read -ra F <<< "$entry"
    [[ "${F[0]}" == "primary" ]] && PRIMARY_COUNT=$((PRIMARY_COUNT + 1))
done

if [ "$PRIMARY_COUNT" -eq 0 ]; then
    print_error "No primary server found in configuration. Exactly one is required."
    exit 1
fi

if [ "$PRIMARY_COUNT" -gt 1 ]; then
    print_error "Multiple primary servers found ($PRIMARY_COUNT). Exactly one is required."
    exit 1
fi

# ===============================
# Step 2 — Pre-flight: SSH Tests + Server Table
# ===============================
print_section "Pre-flight: SSH Connectivity"

declare -A SSH_STATUS

for entry in "${SERVERS[@]}"; do
    IFS='|' read -ra F <<< "$entry"
    role="${F[0]}"
    ip="${F[1]}"
    user="${F[2]}"
    key="${F[3]}"
    path="${F[4]}"
    branch="${F[5]}"

    if [ ! -f "$key" ]; then
        print_error "SSH key not found for $ip: $key"
        SSH_STATUS["$ip"]="NO_KEY"
        continue
    fi

    print_status "Testing SSH to [$role] $ip ..."
    if ssh -i "$key" -o StrictHostKeyChecking=no -o ConnectTimeout=10 -o BatchMode=yes \
           "${user}@${ip}" "echo OK" &>/dev/null; then
        SSH_STATUS["$ip"]="OK"
        print_status "  $ip — SSH OK"
    else
        SSH_STATUS["$ip"]="FAILED"
        print_error "  $ip — SSH FAILED"
    fi
done

# Check for any SSH failures
SSH_FAILURES=0
for ip in "${!SSH_STATUS[@]}"; do
    [[ "${SSH_STATUS[$ip]}" != "OK" ]] && SSH_FAILURES=$((SSH_FAILURES + 1))
done

if [ "$SSH_FAILURES" -gt 0 ]; then
    print_error "$SSH_FAILURES server(s) failed SSH connectivity check. Fix before deploying."
    exit 1
fi
print_status "All servers reachable via SSH"

# Print server table
echo ""
echo -e "${BLUE}Servers to be deployed:${NC}"
echo ""
printf "  %-12s %-18s %-10s %-30s %-8s\n" "ROLE" "IP" "USER" "PROJECT PATH" "BRANCH"
printf "  %-12s %-18s %-10s %-30s %-8s\n" "------------" "------------------" "----------" "------------------------------" "--------"
for entry in "${SERVERS[@]}"; do
    IFS='|' read -ra F <<< "$entry"
    printf "  %-12s %-18s %-10s %-30s %-8s\n" "${F[0]}" "${F[1]}" "${F[2]}" "${F[4]}" "${F[5]}"
done
echo ""

read -p "Proceed with deployment to all ${#SERVERS[@]} server(s)? (y/n) [default: n]: " CONFIRM
CONFIRM=${CONFIRM:-n}
if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
    print_warning "Deployment cancelled by user."
    exit 0
fi

# ===============================
# Helper: Run deploy.sh on a remote server
# ===============================
# Usage: run_deploy ROLE IP SSH_USER SSH_KEY PROJECT_PATH BRANCH LOG_FILE
run_deploy() {
    local role="$1"
    local ip="$2"
    local user="$3"
    local key="$4"
    local path="$5"
    local branch="$6"
    local log_file="$7"

    ssh -i "$key" \
        -o StrictHostKeyChecking=no \
        -o ConnectTimeout=30 \
        -o BatchMode=yes \
        -o ServerAliveInterval=30 \
        -o ServerAliveCountMax=10 \
        "${user}@${ip}" \
        "bash -s -- '$path' '$branch' '$role'" \
        < "$(dirname "$0")/deploy.sh" \
        2>&1 | tee "$log_file"

    return "${PIPESTATUS[0]}"
}

# ===============================
# Locate deploy.sh
# ===============================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_SCRIPT="$SCRIPT_DIR/deploy.sh"

if [ ! -f "$DEPLOY_SCRIPT" ]; then
    print_error "deploy.sh not found at: $DEPLOY_SCRIPT"
    print_error "deploy-all.sh must be in the same directory as deploy.sh"
    exit 1
fi
print_status "Using deploy script: $DEPLOY_SCRIPT"

# ===============================
# Step 3 — Deploy Primary Server
# ===============================
print_section "Deploying Primary Server"

PRIMARY_ENTRY=""
for entry in "${SERVERS[@]}"; do
    IFS='|' read -ra F <<< "$entry"
    [[ "${F[0]}" == "primary" ]] && PRIMARY_ENTRY="$entry" && break
done

IFS='|' read -ra PF <<< "$PRIMARY_ENTRY"
P_ROLE="${PF[0]}"
P_IP="${PF[1]}"
P_USER="${PF[2]}"
P_KEY="${PF[3]}"
P_PATH="${PF[4]}"
P_BRANCH="${PF[5]}"

P_LOG="/tmp/deploy-${P_IP}-${TIMESTAMP}.log"
print_status "Deploying to primary: $P_IP (branch=$P_BRANCH, path=$P_PATH)"
print_status "Log file: $P_LOG"
echo ""

# Deploy primary — output streamed live to terminal AND log file
declare -A DEPLOY_STATUS
declare -A DEPLOY_LOG

PRIMARY_DEPLOY_OK=true
if ssh -i "$P_KEY" \
       -o StrictHostKeyChecking=no \
       -o ConnectTimeout=30 \
       -o BatchMode=yes \
       -o ServerAliveInterval=30 \
       -o ServerAliveCountMax=10 \
       "${P_USER}@${P_IP}" \
       "bash -s -- '$P_PATH' '$P_BRANCH' '$P_ROLE'" \
       < "$DEPLOY_SCRIPT" \
       2>&1 | tee "$P_LOG"; then
    DEPLOY_STATUS["$P_IP"]="SUCCESS"
    print_status "Primary deployment succeeded: $P_IP"
else
    DEPLOY_STATUS["$P_IP"]="FAILED"
    PRIMARY_DEPLOY_OK=false
fi

DEPLOY_LOG["$P_IP"]="$P_LOG"

if [ "$PRIMARY_DEPLOY_OK" = false ]; then
    print_error "Primary server deployment FAILED at $P_IP"
    print_error "Aborting entire deployment — secondary servers were NOT touched."
    print_error "Review log: $P_LOG"
    exit 1
fi

# Capture the deployed commit hash from the primary log
DEPLOYED_COMMIT=$(grep -oP "New commit: \K[0-9a-f]+" "$P_LOG" | head -1 || echo "unknown")

# ===============================
# Step 4 — Deploy Secondary Servers in Parallel
# ===============================
print_section "Deploying Secondary Servers (Parallel)"

SECONDARY_ENTRIES=()
for entry in "${SERVERS[@]}"; do
    IFS='|' read -ra F <<< "$entry"
    [[ "${F[0]}" == "secondary" ]] && SECONDARY_ENTRIES+=("$entry")
done

if [ ${#SECONDARY_ENTRIES[@]} -eq 0 ]; then
    print_warning "No secondary servers configured — skipping parallel deployment."
else
    print_status "Launching deployment on ${#SECONDARY_ENTRIES[@]} secondary server(s) in parallel..."
    echo ""

    declare -A BG_PIDS

    for entry in "${SECONDARY_ENTRIES[@]}"; do
        IFS='|' read -ra SF <<< "$entry"
        s_role="${SF[0]}"
        s_ip="${SF[1]}"
        s_user="${SF[2]}"
        s_key="${SF[3]}"
        s_path="${SF[4]}"
        s_branch="${SF[5]}"
        s_log="/tmp/deploy-${s_ip}-${TIMESTAMP}.log"

        DEPLOY_LOG["$s_ip"]="$s_log"

        print_status "Starting deployment: $s_ip (log: $s_log)"

        (
            if ssh -i "$s_key" \
                   -o StrictHostKeyChecking=no \
                   -o ConnectTimeout=30 \
                   -o BatchMode=yes \
                   -o ServerAliveInterval=30 \
                   -o ServerAliveCountMax=10 \
                   "${s_user}@${s_ip}" \
                   "bash -s -- '$s_path' '$s_branch' '$s_role'" \
                   < "$DEPLOY_SCRIPT" \
                   >> "$s_log" 2>&1; then
                echo "DEPLOY_OK" >> "$s_log"
            else
                echo "DEPLOY_FAILED" >> "$s_log"
            fi
        ) &

        BG_PIDS["$s_ip"]=$!
    done

    print_status "Waiting for all secondary deployments to complete..."
    echo ""

    for entry in "${SECONDARY_ENTRIES[@]}"; do
        IFS='|' read -ra SF <<< "$entry"
        s_ip="${SF[1]}"
        s_log="${DEPLOY_LOG[$s_ip]}"

        wait "${BG_PIDS[$s_ip]}" 2>/dev/null || true

        # Check result marker written into the log
        if tail -1 "$s_log" 2>/dev/null | grep -q "DEPLOY_OK"; then
            DEPLOY_STATUS["$s_ip"]="SUCCESS"
            print_status "  $s_ip — deployment SUCCESS  (log: $s_log)"
        else
            DEPLOY_STATUS["$s_ip"]="FAILED"
            print_error "  $s_ip — deployment FAILED  (log: $s_log)"
        fi
    done
fi

# ===============================
# Step 5 — Post-deploy Health Checks
# ===============================
print_section "Post-Deploy Health Checks"

declare -A HEALTH_STATUS

for entry in "${SERVERS[@]}"; do
    IFS='|' read -ra F <<< "$entry"
    ip="${F[1]}"

    print_status "Health check: http://${ip}/up ..."
    HTTP_CODE=$(curl -o /dev/null -s -w "%{http_code}" \
        --max-time 15 \
        "http://${ip}/up" 2>/dev/null || echo "000")

    case "$HTTP_CODE" in
        200)
            HEALTH_STATUS["$ip"]="HEALTHY (200)"
            print_status "  $ip — HEALTHY (HTTP 200)"
            ;;
        503)
            HEALTH_STATUS["$ip"]="MAINTENANCE (503)"
            print_warning "  $ip — MAINTENANCE MODE (HTTP 503)"
            ;;
        000)
            HEALTH_STATUS["$ip"]="UNREACHABLE"
            print_warning "  $ip — UNREACHABLE (no response)"
            ;;
        *)
            HEALTH_STATUS["$ip"]="HTTP $HTTP_CODE"
            print_warning "  $ip — HTTP $HTTP_CODE"
            ;;
    esac
done

# ===============================
# Step 6 — Final Summary Table
# ===============================
END_TIME=$(date +%s)
ELAPSED=$((END_TIME - START_TIME))
ELAPSED_FMT=$(printf '%dm %ds' $((ELAPSED / 60)) $((ELAPSED % 60)))

echo ""
echo -e "${BLUE}============================================================${NC}"
echo -e "${GREEN}  Deployment Summary${NC}"
echo -e "${BLUE}============================================================${NC}"
echo ""
print_status "  Timestamp:                 $(date)"
print_status "  Total time:                $ELAPSED_FMT"
print_status "  Commit deployed:           $DEPLOYED_COMMIT"
echo ""

# Build the status table
printf "  ${BLUE}%-18s %-12s %-14s %-22s${NC}\n" "SERVER IP" "ROLE" "DEPLOY STATUS" "HEALTH CHECK"
printf "  ${BLUE}%-18s %-12s %-14s %-22s${NC}\n" "------------------" "------------" "--------------" "----------------------"

ANY_FAILED=false
for entry in "${SERVERS[@]}"; do
    IFS='|' read -ra F <<< "$entry"
    role="${F[0]}"
    ip="${F[1]}"

    d_status="${DEPLOY_STATUS[$ip]:-UNKNOWN}"
    h_status="${HEALTH_STATUS[$ip]:-NOT CHECKED}"

    # Color the deploy status
    if [ "$d_status" = "SUCCESS" ]; then
        d_colored="${GREEN}${d_status}${NC}"
    else
        d_colored="${RED}${d_status}${NC}"
        ANY_FAILED=true
    fi

    # Color the health status
    if [[ "$h_status" == "HEALTHY (200)" ]]; then
        h_colored="${GREEN}${h_status}${NC}"
    elif [[ "$h_status" == UNREACHABLE* || "$h_status" == FAILED* ]]; then
        h_colored="${RED}${h_status}${NC}"
        ANY_FAILED=true
    else
        h_colored="${YELLOW}${h_status}${NC}"
    fi

    printf "  %-18s %-12s " "$ip" "$role"
    echo -e "${d_colored}$(printf '%*s' $((14 - ${#d_status})) '')${h_colored}"
done

echo ""
if [ "$ANY_FAILED" = true ]; then
    print_error "One or more servers FAILED deployment or health check."
    echo ""
    print_warning "=== Failed Server Log Files ==="
    for entry in "${SERVERS[@]}"; do
        IFS='|' read -ra F <<< "$entry"
        ip="${F[1]}"
        d_status="${DEPLOY_STATUS[$ip]:-UNKNOWN}"
        h_status="${HEALTH_STATUS[$ip]:-NOT CHECKED}"
        if [[ "$d_status" != "SUCCESS" || "$h_status" != "HEALTHY (200)" ]]; then
            log_path="${DEPLOY_LOG[$ip]:-N/A}"
            print_warning "  $ip: $log_path"
        fi
    done
    echo ""
    echo -e "${BLUE}============================================================${NC}"
    exit 1
else
    print_status "All servers deployed and healthy!"
fi

echo ""
print_status "=== Useful Commands ==="
for entry in "${SERVERS[@]}"; do
    IFS='|' read -ra F <<< "$entry"
    ip="${F[1]}"
    path="${F[4]}"
    print_status "  Logs ($ip):  tail -f ${path}/storage/logs/laravel.log"
done
echo -e "${BLUE}============================================================${NC}"
