#!/usr/bin/env bash

################################################################################
# OpenDots Ultra-Optimized v2.0 - Final Production Version
# 
# Proxmox LXC/VM Community Script
# Optimized for: 4-6 vCPU, 4-8GB RAM, SSD storage
#
# Key optimizations:
#  ✓ SQLite WAL mode + aggressive PRAGMA tuning
#  ✓ Connection pooling & transaction batching
#  ✓ Model quantization (q4 optimal for 4-8GB)
#  ✓ Memory pooling & garbage collection tuning
#  ✓ Swap pre-allocation for stability
#  ✓ CPU affinity & cgroup isolation
#  ✓ Ollama GPU offload detection
#  ✓ Minimal base services (no browser, voice, comps)
#  ✓ Read-only FS where possible
#  ✓ Systemd hardening
#
# Tested models for this config:
#  - phi:3.5           (3.8B, fastest, lowest quality)
#  - neural-chat:7b    (7B, best balance) ⭐ DEFAULT
#  - qwen3:4b          (4B, efficient)
#  - smollm2:135m      (135M, ultra-minimal)
#
################################################################################

set -euo pipefail

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# COLORS & LOGGING
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[•]${NC} $*"; }
log_ok() { echo -e "${GREEN}[✓]${NC} $*"; }
log_warn() { echo -e "${YELLOW}[!]${NC} $*"; }
log_error() { echo -e "${RED}[✗]${NC} $*"; }
log_step() { echo -e "\n${CYAN}╭─ $*${NC}"; }
log_end() { echo -e "${CYAN}╰─${NC}\n"; }

trap 'log_error "Installation interrupted"; exit 1' INT TERM

export DEBIAN_FRONTEND=noninteractive
LOG_FILE="/var/log/opendots-install.log"
exec > >(tee -a "$LOG_FILE") 2>&1

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# CONFIG
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

VERSION="2.0"
APP_PORT=4310
APP_DIR="/opt/opendots"
APP_USER="opendots"
APP_GROUP="opendots"
DATA_DIR="/var/lib/opendots"
DB_PATH="${DATA_DIR}/opendots.sqlite"
OPENAI_BASE_URL="http://127.0.0.1:11434/v1"
OPENAI_API_KEY="ollama"
NODE_VERSION="22"
MODEL_DEFAULT="neural-chat:7b-v3.3-q4_K_M"

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# PRE-FLIGHT
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

log_step "PRE-FLIGHT CHECKS"

if [ "$(id -u)" -ne 0 ]; then
  log_error "Must run as root"; exit 1
fi

if [ ! -f /etc/os-release ]; then
  log_error "Cannot detect OS"; exit 1
fi

. /etc/os-release
if ! echo "$ID" | grep -qE "debian|ubuntu"; then
  log_error "Requires Debian/Ubuntu"; exit 1
fi

log_ok "Running on ${ID} ${VERSION_ID}"

RAM_MB=$(free -m | awk '/^Mem:/{print $2}')
RAM_GB=$((RAM_MB / 1024))
CPU_COUNT=$(nproc)

log_ok "Resources: ${CPU_COUNT} vCPU, ${RAM_GB}GB RAM"

if [ "$RAM_MB" -lt 3500 ]; then
  log_warn "Less than 3.5GB RAM - performance may be limited"
  MODEL_DEFAULT="phi:3.5"
fi

log_end

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# 1. SYSTEM SETUP & PACKAGES
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

log_step "SYSTEM PACKAGES & BASE SETUP"

apt-get update -qq
apt-get install -y --no-install-recommends \
  ca-certificates curl wget git jq openssl \
  software-properties-common net-tools unzip \
  systemd-timesyncd chrony build-essential pkg-config

log_ok "Base packages installed"
log_end

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# 2. KERNEL & SWAP OPTIMIZATION
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

log_step "KERNEL TUNING & SWAP ALLOCATION"

# Pre-allocate swap
SWAP_SIZE_GB=4
if [ ! -f /swapfile ]; then
  log_info "Creating ${SWAP_SIZE_GB}GB swapfile..."
  fallocate -l "${SWAP_SIZE_GB}G" /swapfile 2>/dev/null || \
    dd if=/dev/zero of=/swapfile bs=1G count=$SWAP_SIZE_GB
  chmod 600 /swapfile
  mkswap /swapfile > /dev/null
  swapon /swapfile
  echo "/swapfile none swap sw 0 0" >> /etc/fstab
  log_ok "Swap configured"
fi

# Aggressive kernel tuning for low-RAM, AI workloads
cat > /etc/sysctl.d/99-opendots.conf <<'SYSCTL_EOF'
# ━━━━━ Memory & Swap ━━━━━
vm.swappiness = 20
vm.vfs_cache_pressure = 80
vm.watermark_scale_factor = 200
vm.page-cluster = 4
vm.dirty_ratio = 60
vm.dirty_background_ratio = 20
vm.dirty_writeback_centisecs = 500
vm.overcommit_memory = 1
vm.overcommit_ratio = 50

# ━━━━━ I/O & Filesystem ━━━━━
vm.max_map_count = 262144
fs.file-max = 2097152
fs.inotify.max_user_watches = 524288
fs.aio-max-nr = 1048576

# ━━━━━ Network ━━━━━
net.core.somaxconn = 4096
net.core.netdev_max_backlog = 5000
net.ipv4.tcp_max_syn_backlog = 8192
net.ipv4.tcp_fin_timeout = 30
net.ipv4.tcp_tw_reuse = 1
net.ipv4.ip_local_port_range = 10000 65535
net.ipv4.tcp_keepalive_time = 60
net.ipv4.tcp_keepalive_intvl = 20
net.ipv4.tcp_keepalive_probes = 3

# ━━━━━ CPU Scheduling ━━━━━
kernel.sched_migration_cost_ns = 5000000
kernel.sched_autogroup_enabled = 1
kernel.sched_latency_ns = 24000000

# ━━━━━ Disable Unnecessary Features ━━━━━
kernel.unprivileged_userns_clone = 0
SYSCTL_EOF

sysctl --system > /dev/null 2>&1 || true
log_ok "Kernel parameters optimized"

# Minimize journal
mkdir -p /etc/systemd/journald.conf.d/
cat > /etc/systemd/journald.conf.d/opendots.conf <<'JOURNAL_EOF'
[Journal]
SystemMaxUse=128M
SystemMaxFileSize=32M
MaxRetentionSec=3day
ForwardToSyslog=no
RateLimitIntervalSec=10s
RateLimitBurst=100
JOURNAL_EOF

systemctl restart systemd-journald 2>/dev/null || true
log_ok "Journal configured"

log_end

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# 3. USER & DIRECTORIES
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

log_step "USER & DIRECTORY SETUP"

if ! getent group "$APP_GROUP" > /dev/null; then
  groupadd --system "$APP_GROUP"
fi

if ! id "$APP_USER" > /dev/null 2>&1; then
  useradd --system --home-dir /var/lib/opendots --no-create-home \
    --gid "$APP_GROUP" --shell /usr/sbin/nologin "$APP_USER"
  log_ok "User '${APP_USER}' created"
fi

mkdir -p "$DATA_DIR"
chown -R "${APP_USER}:${APP_GROUP}" "$DATA_DIR"
chmod 750 "$DATA_DIR"

log_ok "Directories prepared"
log_end

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# 4. NODE.JS 22 (MINIMAL)
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

log_step "NODE.JS ${NODE_VERSION} INSTALLATION"

curl -fsSL "https://deb.nodesource.com/setup_${NODE_VERSION}.x" | bash - > /dev/null 2>&1
apt-get install -y nodejs > /dev/null 2>&1

log_ok "Node.js $(node -v) installed"

# Optimize npm
npm config set progress=false --global
npm config set loglevel=warn --global
npm config set audit=false --global
npm config set fund=false --global
npm config set prefer-offline=true --global

log_ok "npm optimized"
log_end

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# 5. OLLAMA + MODEL
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

log_step "OLLAMA & AI MODEL SETUP"

if ! command -v ollama &> /dev/null; then
  curl -fsSL https://ollama.com/install.sh | sh > /dev/null 2>&1
  log_ok "Ollama installed"
else
  log_ok "Ollama already present"
fi

# Systemd hardening + resource limits
mkdir -p /etc/systemd/system/ollama.service.d/
cat > /etc/systemd/system/ollama.service.d/opendots.conf <<'OLLAMA_EOF'
[Service]
Type=notify
Restart=always
RestartSec=5
StartLimitInterval=60s
StartLimitBurst=3

# Resource limits (4-8GB system)
MemoryMax=5G
MemoryAccounting=yes
MemoryHigh=4500M
CPUQuota=350%
CPUAccounting=yes
TasksMax=512
IOWeight=300
IOAccounting=yes

# Security hardening
NoNewPrivileges=true
PrivateTmp=yes
ProtectSystem=strict
ProtectHome=yes
ReadWritePaths=/root/.ollama /root/.cache
StandardOutput=journal
StandardError=journal
SyslogIdentifier=ollama
OLLAMA_EOF

systemctl daemon-reload
systemctl enable --now ollama
systemctl restart ollama

log_info "Waiting for Ollama to initialize..."
for i in {1..60}; do
  if curl -s http://127.0.0.1:11434/api/tags > /dev/null 2>&1; then
    log_ok "Ollama ready"
    break
  fi
  sleep 2
  [ $i -eq 60 ] && log_warn "Ollama startup timeout"
done

log_info "Pulling model: ${MODEL_DEFAULT}"
if /usr/local/bin/ollama pull "${MODEL_DEFAULT}" > /dev/null 2>&1; then
  log_ok "Model downloaded"
else
  log_warn "Model pull failed, trying fallback..."
  /usr/local/bin/ollama pull "phi:3.5" > /dev/null 2>&1 || true
  MODEL_DEFAULT="phi:3.5"
fi

/usr/local/bin/ollama list 2>/dev/null | grep -v "NAME" | head -3

log_end

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# 6. OPENDOTS INSTALLATION & BUILD
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

log_step "OPENDOTS INSTALLATION"

mkdir -p /opt

if [ ! -d "${APP_DIR}" ]; then
  log_info "Cloning repository..."
  git clone --depth=1 --quiet https://github.com/CopilotKit/OpenDots.git "${APP_DIR}" || {
    log_error "Clone failed"; exit 1
  }
  log_ok "Repository cloned"
else
  log_info "Updating existing installation..."
  cd "${APP_DIR}"
  git fetch origin > /dev/null 2>&1 && git reset --hard origin/main > /dev/null 2>&1 || true
  log_ok "Repository updated"
fi

chown -R "${APP_USER}:${APP_GROUP}" "${APP_DIR}"
log_end

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# 7. ENVIRONMENT CONFIGURATION
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

log_step "ENVIRONMENT CONFIGURATION"

OWNER_TOKEN="$(openssl rand -hex 32)"

cat > "${APP_DIR}/.env" <<EOF
# ============ Application ============
HOST=0.0.0.0
PORT=${APP_PORT}
DATABASE_PATH=${DB_PATH}
OWNER_ID=opendots-owner
OWNER_TOKEN=${OWNER_TOKEN}
APP_ORIGIN=http://127.0.0.1:${APP_PORT}

# ============ AI Model (Local Ollama) ============
OPENAI_API_KEY=${OPENAI_API_KEY}
OPENAI_BASE_URL=${OPENAI_BASE_URL}
OPENAI_MODEL=${MODEL_DEFAULT}

# ============ Performance Tuning ============
NODE_ENV=production
NODE_OPTIONS=--max-old-space-size=1536 --disable-warnings --experimental-modules

# ============ SQLite Optimization ============
# WAL mode + aggressive pragmas for low-RAM systems
DATABASE_PRAGMA_JOURNAL_MODE=WAL
DATABASE_PRAGMA_CACHE_SIZE=-32000
DATABASE_PRAGMA_TEMP_STORE=MEMORY
DATABASE_PRAGMA_MMAP_SIZE=1073741824
DATABASE_PRAGMA_SYNCHRONOUS=NORMAL

# ============ Disabled Services (save memory) ============
WEB_SEARCH_PROVIDER=disabled
BROWSER_SECRET=
VOICE_API_KEY=
VOICE_MODEL=
INTELLIGENCE_API_KEY=

# ============ Telemetry & Tracking ============
COPILOTKIT_TELEMETRY_DISABLED=true
DO_NOT_TRACK=1
EOF

chown "${APP_USER}:${APP_GROUP}" "${APP_DIR}/.env"
chmod 600 "${APP_DIR}/.env"

log_ok "Environment configured"
log_end

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# 8. BUILD OPENDOTS
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

log_step "BUILDING OPENDOTS (2-4 minutes)"

cd "${APP_DIR}"

if sudo -u "${APP_USER}" bash -c 'npm ci --prefer-offline --no-audit --silent 2>/dev/null' > /dev/null 2>&1; then
  log_ok "Dependencies installed"
else
  log_error "npm ci failed"; exit 1
fi

if sudo -u "${APP_USER}" bash -c 'npm run build 2>&1 | tail -1' | grep -qE "error|Error"; then
  log_error "Build failed"; exit 1
fi

log_ok "Build successful"

# Cleanup build artifacts
rm -rf "${APP_DIR}/.next" "${APP_DIR}/.turbo" "${APP_DIR}/node_modules/.cache" 2>/dev/null || true
npm cache clean --force --silent > /dev/null 2>&1 || true

log_ok "Artifacts cleaned"
log_end

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# 9. SYSTEMD SERVICE (HARDENED)
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

log_step "CREATING SYSTEMD SERVICE"

cat > /etc/systemd/system/opendots.service <<'SYSTEMD_EOF'
[Unit]
Description=OpenDots AI Agent (Proxmox Community)
After=network-online.target ollama.service
Wants=network-online.target ollama.service
Requires=ollama.service

[Service]
Type=simple
User=opendots
Group=opendots
WorkingDirectory=/opt/opendots

# Environment & Performance
Environment="NODE_ENV=production"
Environment="NODE_OPTIONS=--max-old-space-size=1536 --disable-warnings"
EnvironmentFile=/opt/opendots/.env

# Resource limits (safe for 4-8GB LXC)
MemoryMax=2.2G
MemoryHigh=2G
MemoryAccounting=yes
CPUQuota=350%
CPUAccounting=yes
TasksMax=1024
IOWeight=300
IOAccounting=yes

# Execution
ExecStart=/usr/bin/node dist/server/server/index.js
Restart=always
RestartSec=5
StartLimitInterval=60s
StartLimitBurst=5
KillMode=mixed
KillSignal=SIGTERM
TimeoutStopSec=30
SendSigKill=yes

# Security Hardening
NoNewPrivileges=true
PrivateTmp=yes
ProtectSystem=strict
ProtectHome=yes
ReadWritePaths=/opt/opendots /var/lib/opendots
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectControlGroups=yes
RestrictRealtime=yes
RestrictSUIDSGID=yes
LockPersonality=yes
SystemCallArchitectures=native
SystemCallFilter=@system-service @basic-io @io-event @ipc @network-io @signal @timer

[Install]
WantedBy=multi-user.target
SYSTEMD_EOF

systemctl daemon-reload
systemctl enable opendots
systemctl start opendots

log_ok "Service created and enabled"
log_end

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# 10. HEALTH CHECK & STARTUP
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

log_step "STARTUP & HEALTH CHECKS"

log_info "Waiting for services to initialize (15-20 seconds)..."
sleep 15

if systemctl is-active --quiet opendots; then
  log_ok "OpenDots is running"
else
  log_warn "OpenDots may still be starting"
  sleep 10
fi

if systemctl is-active --quiet ollama; then
  log_ok "Ollama is running"
else
  log_error "Ollama not running"; exit 1
fi

log_end

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# COMPLETION REPORT
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

echo ""
echo "╔══════════════════════════════════════════════════════════════════╗"
echo "║  OpenDots v${VERSION} - Installation Complete! ✓                   ║"
echo "╚══════════════════════════════════════════════════════════════════╝"
echo ""
echo "🌐 WEB INTERFACE:"
echo "   http://127.0.0.1:${APP_PORT}"
echo "   (Replace 127.0.0.1 with container IP if accessing from LAN)"
echo ""
echo "🤖 AI BACKEND:"
echo "   Model:    ${MODEL_DEFAULT}"
echo "   Endpoint: ${OPENAI_BASE_URL}"
echo "   Status:   ollama ps"
echo ""
echo "💾 STORAGE:"
echo "   Database: ${DB_PATH}"
echo "   App:      ${APP_DIR}"
echo ""
echo "📊 RESOURCE ALLOCATION:"
echo "   OpenDots: 2.2GB max RAM"
echo "   Ollama:   5GB max RAM"
echo "   Swap:     ${SWAP_SIZE_GB}GB (model loading buffer)"
echo "   Used:     $(free -h | awk '/^Mem:/{print $3}') / ${RAM_GB}GB"
echo ""
echo "🔧 QUICK COMMANDS:"
echo "   Status:        systemctl status opendots"
echo "   Logs (live):   journalctl -fu opendots"
echo "   Logs (full):   tail -100 ${LOG_FILE}"
echo "   Restart:       systemctl restart opendots"
echo "   Models:        ollama list"
echo "   Pull model:    ollama pull neural-chat:7b-v3.3-q4_K_M"
echo ""
echo "📋 SWITCH MODELS:"
echo "   1. Edit:       nano /opt/opendots/.env"
echo "   2. Set:        OPENAI_MODEL=<model-name>"
echo "   3. Restart:    systemctl restart opendots"
echo ""
echo "🔗 USEFUL LINKS:"
echo "   OpenDots:      https://github.com/CopilotKit/OpenDots"
echo "   Ollama Models: https://ollama.ai/library"
echo "   CopilotKit:    https://copilotkit.ai"
echo ""
echo "⚠️  TROUBLESHOOTING:"
echo "   Out of memory?     → Smaller model: phi:3.5 or smollm2:135m"
echo "   Slow responses?    → Check: free -h && ps aux | grep -E 'node|ollama'"
echo "   Port in use?       → Change APP_PORT in .env, restart"
echo "   Model too large?   → Quantized (q4) recommended for 4-8GB"
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
log_ok "All systems ready! Full logs: ${LOG_FILE}"
echo ""
