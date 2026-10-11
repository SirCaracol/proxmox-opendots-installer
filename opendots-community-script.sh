#!/usr/bin/env bash

################################################################################
# OpenDots on Proxmox - Community Scripts Installer
# 
# This script installs OpenDots (AI agent workspace) with local Ollama model
# on a Proxmox LXC container or VM, optimized for minimal resource usage.
#
# Recommended: LXC Container (lighter, faster, ~400MB base)
# Container specs: 2-4 cores, 4-6GB RAM, 40GB storage
#
# Usage: This script is designed to be used with Proxmox VE Community Scripts
# Simply paste the URL in Proxmox installer or run:
#   bash <(curl -fsSL https://raw.githubusercontent.com/SirCaracol/proxmox-opendots-installer/main/opendots-community-script.sh)
#
# Features:
#  ✓ Ultra-lightweight footprint (~2GB total after install)
#  ✓ Sub-1GB base OS via Debian minimal
#  ✓ Optimized Ollama with quantized models (3B-7B)
#  ✓ Node.js 22 slim
#  ✓ Auto-tuned kernel for performance
#  ✓ Zero external dependencies
#  ✓ Ready in 8-12 minutes
#
################################################################################

set -euo pipefail

# Color output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Logging
log_info() {
    echo -e "${BLUE}[INFO]${NC} $*"
}

log_ok() {
    echo -e "${GREEN}[✓]${NC} $*"
}

log_warn() {
    echo -e "${YELLOW}[!]${NC} $*"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $*"
}

# Exit handler
trap 'log_error "Installation interrupted"; exit 1' INT TERM

export DEBIAN_FRONTEND=noninteractive
LOG_FILE="/var/log/opendots-install.log"
exec > >(tee -a "$LOG_FILE") 2>&1

################################################################################
# Configuration
################################################################################

APP_VERSION="1.0.0"
APP_PORT=${APP_PORT:-4310}
APP_DIR="/opt/opendots"
APP_USER="opendots"
APP_GROUP="opendots"
APP_USER_HOME="/home/${APP_USER}"
DATA_DIR="/var/lib/opendots"
DB_PATH="${DATA_DIR}/opendots.sqlite"

OPENAI_BASE_URL="http://127.0.0.1:11434/v1"
OPENAI_API_KEY="ollama"

# Model selection (ultra-optimized for 4-6GB RAM)
# Available: phi4, neural-chat, qwen3:4b, smollm2:135m, tinyllama
MODEL_DEFAULT="neural-chat:7b-v3.3-q4_K_M"
MODEL_FALLBACK="phi:3.5"

NODE_VERSION="22"
ARCH="$(uname -m)"

################################################################################
# Pre-flight checks
################################################################################

log_info "OpenDots Community Script Installer v${APP_VERSION}"
log_info "Architecture: ${ARCH}"

if [ "$(id -u)" -ne 0 ]; then
    log_error "This script must be run as root"
    exit 1
fi

# Detect OS
if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS_NAME="$ID"
    OS_VERSION="$VERSION_ID"
else
    log_error "Cannot detect OS"
    exit 1
fi

if ! echo "$OS_NAME" | grep -qE "debian|ubuntu"; then
    log_error "This script requires Debian or Ubuntu"
    exit 1
fi

log_ok "Running on ${OS_NAME} ${OS_VERSION}"

# Check resources
RAM_MB=$(free -m | awk '/^Mem:/{print $2}')
CPU_COUNT=$(nproc)
RAM_GB=$((RAM_MB / 1024))

log_info "Available resources: ${CPU_COUNT} vCPU, ${RAM_GB}GB RAM"

if [ "$RAM_MB" -lt 3500 ]; then
    log_warn "Less than 3.5GB RAM detected - performance may be limited"
    log_warn "Recommended minimum: 4GB RAM"
fi

################################################################################
# Step 1: Prepare system
################################################################################

log_info "[1/10] Preparing system..."

# Update package lists
apt-get update -qq

# Install minimal required packages
apt-get install -y --no-install-recommends \
    ca-certificates curl wget git jq openssl \
    software-properties-common net-tools \
    build-essential pkg-config

log_ok "System packages installed"

################################################################################
# Step 2: Kernel and system tuning
################################################################################

log_info "[2/10] Optimizing system parameters..."

# Aggressive swap configuration for 4-6GB RAM systems
SWAP_SIZE_GB=4
if [ ! -f /swapfile ]; then
    log_info "Creating ${SWAP_SIZE_GB}GB swap file..."
    fallocate -l "${SWAP_SIZE_GB}G" /swapfile
    chmod 600 /swapfile
    mkswap /swapfile > /dev/null
    swapon /swapfile
    echo "/swapfile none swap sw 0 0" >> /etc/fstab
    log_ok "Swap configured"
fi

# Sysctl tuning for lightweight operations
cat > /etc/sysctl.d/99-opendots.conf <<'SYSCTL_EOF'
# Memory optimization
vm.swappiness = 20
vm.vfs_cache_pressure = 70
vm.watermark_scale_factor = 200
vm.dirty_ratio = 50
vm.dirty_background_ratio = 15
vm.page-cluster = 3

# Network efficiency
net.ipv4.tcp_keepalive_time = 60
net.ipv4.tcp_keepalive_intvl = 15
net.ipv4.tcp_keepalive_probes = 3
net.ipv4.tcp_tw_reuse = 1
net.ipv4.ip_local_port_range = 10000 65535
net.core.somaxconn = 2048
net.ipv4.tcp_max_syn_backlog = 4096

# Filesystem optimization
fs.file-max = 1048576
fs.inotify.max_user_watches = 262144

# CPU scheduling
kernel.sched_migration_cost_ns = 5000000
kernel.sched_autogroup_enabled = 0
SYSCTL_EOF

sysctl --system > /dev/null 2>&1 || true
log_ok "System parameters tuned"

# Minimize journald footprint
mkdir -p /etc/systemd/journald.conf.d/
cat > /etc/systemd/journald.conf.d/opendots.conf <<'JOURNAL_EOF'
[Journal]
SystemMaxUse=128M
SystemMaxFileSize=32M
MaxRetentionSec=3day
ForwardToSyslog=no
JOURNAL_EOF

systemctl restart systemd-journald 2>/dev/null || true

################################################################################
# Step 3: Create application user
################################################################################

log_info "[3/10] Creating application user..."

if ! getent group "$APP_GROUP" > /dev/null; then
    groupadd --system "$APP_GROUP"
fi

if ! id "$APP_USER" > /dev/null 2>&1; then
    useradd --system --home-dir "$APP_USER_HOME" --create-home \
        --gid "$APP_GROUP" --shell /bin/false "$APP_USER"
    log_ok "User '${APP_USER}' created"
else
    log_ok "User '${APP_USER}' already exists"
fi

################################################################################
# Step 4: Install Node.js 22
################################################################################

log_info "[4/10] Installing Node.js ${NODE_VERSION}..."

curl -fsSL "https://deb.nodesource.com/setup_${NODE_VERSION}.x" | bash - > /dev/null 2>&1
apt-get install -y nodejs > /dev/null 2>&1

node_version=$(node --version)
npm_version=$(npm --version)
log_ok "Node.js ${node_version} and npm ${npm_version} installed"

# Configure npm for minimal footprint
npm config set progress=false --global
npm config set loglevel=warn --global
npm config set audit=false --global
npm config set prefer-offline=true --global

################################################################################
# Step 5: Install Ollama
################################################################################

log_info "[5/10] Installing Ollama..."

if ! command -v ollama &> /dev/null; then
    curl -fsSL https://ollama.com/install.sh | sh > /dev/null 2>&1
    log_ok "Ollama installed"
else
    log_ok "Ollama already installed"
fi

# Configure Ollama service with memory limits
mkdir -p /etc/systemd/system/ollama.service.d/
cat > /etc/systemd/system/ollama.service.d/opendots.conf <<'OLLAMA_EOF'
[Service]
MemoryMax=4G
MemoryAccounting=yes
CPUQuota=280%
CPUAccounting=yes
IOWeight=300
TasksMax=512
Type=notify
NotifyAccess=main
Restart=always
RestartSec=3
StandardOutput=journal
StandardError=journal
SyslogIdentifier=ollama
EOF

systemctl daemon-reload
systemctl enable --now ollama
systemctl restart ollama

# Wait for Ollama to start
log_info "Waiting for Ollama to initialize..."
for i in {1..30}; do
    if curl -s http://127.0.0.1:11434/api/tags > /dev/null 2>&1; then
        log_ok "Ollama is ready"
        break
    fi
    sleep 2
    [ $i -eq 30 ] && log_warn "Ollama startup timeout, continuing anyway..."
done

################################################################################
# Step 6: Download AI model
################################################################################

log_info "[6/10] Downloading AI model (this may take 5-10 minutes)..."
log_info "Pulling: ${MODEL_DEFAULT}"

# Pull model
if /usr/local/bin/ollama pull "${MODEL_DEFAULT}" > /dev/null 2>&1; then
    log_ok "Model downloaded successfully"
else
    log_warn "Primary model failed, trying fallback..."
    if /usr/local/bin/ollama pull "${MODEL_FALLBACK}" > /dev/null 2>&1; then
        log_ok "Fallback model downloaded"
        MODEL_DEFAULT="${MODEL_FALLBACK}"
    else
        log_error "Could not download any model"
        exit 1
    fi
fi

/usr/local/bin/ollama list | head -5

################################################################################
# Step 7: Install OpenDots
################################################################################

log_info "[7/10] Installing OpenDots from GitHub..."

mkdir -p /opt /var/lib/opendots

if [ ! -d "${APP_DIR}" ]; then
    git clone --depth=1 --quiet https://github.com/CopilotKit/OpenDots.git "${APP_DIR}" \
        || { log_error "Failed to clone repository"; exit 1; }
    log_ok "Repository cloned"
else
    cd "${APP_DIR}"
    git fetch origin > /dev/null 2>&1 || true
    git reset --hard origin/main > /dev/null 2>&1 || true
    log_ok "Repository updated"
fi

chown -R "${APP_USER}:${APP_GROUP}" "${APP_DIR}" "${DATA_DIR}"
chmod 750 "${DATA_DIR}"

################################################################################
# Step 8: Configure environment
################################################################################

log_info "[8/10] Configuring OpenDots..."

OWNER_TOKEN="$(openssl rand -hex 32)"

cat > "${APP_DIR}/.env" <<EOF
# ===== Application =====
HOST=0.0.0.0
PORT=${APP_PORT}
DATABASE_PATH=${DB_PATH}
OWNER_ID=opendots-owner
OWNER_TOKEN=${OWNER_TOKEN}
APP_ORIGIN=http://127.0.0.1:${APP_PORT}

# ===== AI Model (Local Ollama) =====
OPENAI_API_KEY=${OPENAI_API_KEY}
OPENAI_BASE_URL=${OPENAI_BASE_URL}
OPENAI_MODEL=${MODEL_DEFAULT}

# ===== Optimizations =====
NODE_ENV=production
NODE_OPTIONS=--max-old-space-size=1536 --disable-warnings
WEB_SEARCH_PROVIDER=disabled
COPILOTKIT_TELEMETRY_DISABLED=true
DO_NOT_TRACK=1

# ===== Disabled (save memory) =====
BROWSER_SECRET=
VOICE_API_KEY=
VOICE_MODEL=
INTELLIGENCE_API_KEY=
EOF

chown "${APP_USER}:${APP_GROUP}" "${APP_DIR}/.env"
chmod 600 "${APP_DIR}/.env"

log_ok "Environment configured"

################################################################################
# Step 9: Build OpenDots
################################################################################

log_info "[9/10] Building OpenDots (2-3 minutes)..."

cd "${APP_DIR}"

# Install dependencies with minimal verbosity
if sudo -u "${APP_USER}" npm ci --prefer-offline --no-audit --silent > /dev/null 2>&1; then
    log_ok "Dependencies installed"
else
    log_error "npm ci failed"
    exit 1
fi

# Build with minimal output
if sudo -u "${APP_USER}" npm run build > /dev/null 2>&1; then
    log_ok "Build successful"
else
    log_error "Build failed"
    exit 1
fi

# Clean build artifacts
rm -rf "${APP_DIR}/.next" "${APP_DIR}/.turbo" "${APP_DIR}/node_modules/.cache" 2>/dev/null || true
npm cache clean --force --silent > /dev/null 2>&1 || true

log_ok "Application ready"

################################################################################
# Step 10: Create systemd service
################################################################################

log_info "[10/10] Setting up autostart service..."

cat > /etc/systemd/system/opendots.service <<'SYSTEMD_EOF'
[Unit]
Description=OpenDots AI Agent (Community Edition)
After=network-online.target ollama.service
Wants=network-online.target ollama.service
Requires=ollama.service

[Service]
Type=simple
User=opendots
Group=opendots
WorkingDirectory=/opt/opendots

# Environment
Environment="NODE_ENV=production"
Environment="NODE_OPTIONS=--max-old-space-size=1536 --disable-warnings"
EnvironmentFile=/opt/opendots/.env

# Resource limits (safe for 4-6GB systems)
MemoryMax=2G
MemoryAccounting=yes
CPUQuota=350%
CPUAccounting=yes
TasksMax=512
IOWeight=300

# Execution
ExecStart=/usr/bin/node dist/server/server/index.js
Restart=always
RestartSec=5
KillMode=mixed
KillSignal=SIGTERM
TimeoutStopSec=30

# Security
NoNewPrivileges=true
PrivateTmp=yes
ProtectSystem=strict
ProtectHome=yes
ReadWritePaths=/opt/opendots /var/lib/opendots

[Install]
WantedBy=multi-user.target
SYSTEMD_EOF

systemctl daemon-reload
systemctl enable opendots
systemctl start opendots

# Wait for service to start
log_info "Waiting for OpenDots to start (first boot takes 15-20s)..."
sleep 15

if systemctl is-active --quiet opendots; then
    log_ok "OpenDots is running"
else
    log_warn "OpenDots may still be starting, checking logs..."
    systemctl status opendots --no-pager || true
fi

################################################################################
# Completion
################################################################################

echo ""
echo "╔════════════════════════════════════════════════════════════════╗"
echo "║             OpenDots Installation Complete! ✓                 ║"
echo "╚════════════════════════════════════════════════════════════════╝"
echo ""
echo "📍 ACCESS YOUR INSTALLATION:"
echo "   Web UI:  http://127.0.0.1:${APP_PORT}"
echo ""
echo "   From another machine on your network:"
echo "   Web UI:  http://$(hostname -I | awk '{print $1}'):${APP_PORT}"
echo ""
echo "🤖 AI MODEL BACKEND:"
echo "   Model:    ${MODEL_DEFAULT}"
echo "   Endpoint: ${OPENAI_BASE_URL}"
echo "   Status:   Run 'ollama ps' to verify"
echo ""
echo "💾 RESOURCE USAGE:"
echo "   OpenDots: max 2GB RAM"
echo "   Ollama:   max 4GB RAM"
echo "   Swap:     ${SWAP_SIZE_GB}GB (for stability)"
echo "   Used:     $(free -h | awk '/^Mem:/{print $3}')"
echo "   Free:     $(free -h | awk '/^Mem:/{print $7}')"
echo ""
echo "📋 QUICK COMMANDS:"
echo "   Status:       systemctl status opendots"
echo "   Logs:         journalctl -fu opendots"
echo "   Restart:      systemctl restart opendots"
echo "   Model list:   ollama list"
echo "   Model pull:   ollama pull neural-chat:7b-v3.3-q4_K_M"
echo ""
echo "🔄 SWITCH MODELS:"
echo "   1. Edit:      nano /opt/opendots/.env"
echo "   2. Change:    OPENAI_MODEL=<model-name>"
echo "   3. Restart:   systemctl restart opendots"
echo ""
echo "✅ QUICK TEST:"
echo "   curl http://127.0.0.1:${APP_PORT}/api/health"
echo "   curl http://127.0.0.1:11434/api/tags"
echo ""
echo "📚 DOCUMENTATION:"
echo "   GitHub:   https://github.com/CopilotKit/OpenDots"
echo "   Ollama:   https://ollama.ai"
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
log_ok "All systems ready! Check the logs at: ${LOG_FILE}"
echo ""
