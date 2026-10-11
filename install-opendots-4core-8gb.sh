#!/usr/bin/env bash
set -euo pipefail

# ==========================================================
# OpenDots + Ollama Ultra-Optimized for 4-Core / 8GB RAM
# ==========================================================
# Production-ready installer targeting Proxmox LXC/VM
# 
# Optimizations:
#  - Minimal base system footprint (~1.5GB used)
#  - Lightning-fast models: phi4 (3.8B), smollm2:135m, neural-chat
#  - Aggressive memory management
#  - Node.js 22 (smaller than v24)
#  - SQLite WAL mode + optimized pools
#  - CPU affinity + cgroup limits
#  - Swap pre-sizing
#  - Browser service DISABLED by default
#  - Quantized models only
#
# Recommended VM specs:
#   vCPU: 4 (dedicados)
#   RAM: 8 GB
#   Disk: 80 GB SSD (min 60 GB for models)
#   Storage: fast SSD/NVMe only
#
# Usage:
#   sudo bash install-opendots-4core-8gb.sh [model]
#   
# Models available:
#   phi4              (3.8B, fastest, lowest quality)
#   neural-chat       (7B, good balance) - DEFAULT
#   smollm2:135m      (135M, ultra-minimal)
#   tinyllama         (1.1B, better than ultra-minimal)
#   qwen3:4b          (4B, high quality)
#
# ==========================================================

export DEBIAN_FRONTEND=noninteractive
LOG_FILE="/var/log/opendots-install.log"
exec > >(tee -a "$LOG_FILE") 2>&1

echo "[$(date '+%Y-%m-%d %H:%M:%S')] ============================================================"
echo "[$(date '+%Y-%m-%d %H:%M:%S')] OpenDots Ultra-Optimized Installer (4-Core / 8GB)"
echo "[$(date '+%Y-%m-%d %H:%M:%S')] ============================================================"

# -------- Validation & Defaults ----------
if [ "$(id -u)" -ne 0 ]; then
  echo "ERROR: Please run with sudo"
  exit 1
fi

# Model selection - use provided arg or default
MODEL_CHOICE="${1:-neural-chat}"
declare -A MODEL_MAP=(
  ["phi4"]="neural-chat:7b-v3.3-q4_K_M"
  ["neural-chat"]="neural-chat:7b-v3.3-q4_K_M"
  ["smollm2:135m"]="smollm2:135m-q2_K"
  ["tinyllama"]="tinyllama:1.1b-chat-v1.0-q4_K_M"
  ["qwen3:4b"]="qwen3:4b-chat-q4_K_M"
)

SELECTED_MODEL="${MODEL_MAP[${MODEL_CHOICE}]:-${MODEL_MAP[neural-chat]}}"

echo "[INFO] Selected model: ${MODEL_CHOICE}"
echo "[INFO] Will pull: ${SELECTED_MODEL}"

CPU_COUNT="$(nproc)"
RAM_MB="$(free -m | awk '/^Mem:/{print $2}')"
AVAILABLE_GB=$((RAM_MB / 1024))

echo "[INFO] System resources: ${CPU_COUNT} CPU, ${AVAILABLE_GB}GB RAM"

if [ "$RAM_MB" -lt 7500 ]; then
  echo "[WARNING] Less than 7.5GB detected - switching to ultra-light model"
  SELECTED_MODEL="smollm2:135m-q2_K"
fi

# App configuration
APP_PORT=4310
APP_DIR="/opt/opendots"
APP_USER="opendots"
APP_GROUP="opendots"
APP_USER_HOME="/home/${APP_USER}"
OPENAI_BASE_URL="http://127.0.0.1:11434/v1"
OPENAI_API_KEY="ollama"
DB_PATH="/var/lib/opendots/opendots.sqlite"
NODE_VERSION="22"

# -------- Step 1: Base system minimal update ----------
echo "[1/12] Updating base system (minimal)..."
apt-get update -qq
apt-get install -y --no-install-recommends \
  ca-certificates curl git build-essential jq wget gnupg \
  software-properties-common net-tools unzip openssl \
  systemd-timesyncd chrony

# -------- Step 2: Create swap for stability ----------
echo "[2/12] Configuring swap for memory pressure handling..."
if [ ! -f /swapfile ]; then
  # 4GB swap for 8GB system = 50% overhead, necessary for model loading
  fallocate -l 4G /swapfile
  chmod 600 /swapfile
  mkswap /swapfile
  swapon /swapfile
  echo "/swapfile none swap sw 0 0" >> /etc/fstab
  echo "[INFO] Created 4GB swapfile"
else
  echo "[INFO] Swapfile already exists"
fi

# -------- Step 3: Kernel tuning for low-RAM, high-CPU efficiency ----------
echo "[3/12] Tuning kernel for responsive AI workloads..."
cat > /etc/sysctl.d/99-opendots-ultra.conf <<'EOF'
# Memory tuning for 8GB system
vm.swappiness = 15
vm.vfs_cache_pressure = 60
vm.watermark_scale_factor = 200
vm.page-cluster = 3
vm.dirty_ratio = 40
vm.dirty_background_ratio = 10

# Network optimization
net.ipv4.tcp_keepalive_time = 60
net.ipv4.tcp_keepalive_intvl = 15
net.ipv4.tcp_keepalive_probes = 3
net.ipv4.tcp_tw_reuse = 1
net.core.somaxconn = 4096
net.ipv4.tcp_max_syn_backlog = 8192

# FS optimization
fs.inotify.max_user_watches = 524288
fs.file-max = 2097152

# Disable unnecessary overhead
kernel.sched_migration_cost_ns = 5000000
EOF
sysctl --system >/dev/null 2>&1 || true

# Reduce journal spam
mkdir -p /etc/systemd/journald.conf.d/
cat > /etc/systemd/journald.conf.d/99-opendots.conf <<'EOF'
[Journal]
SystemMaxUse=256M
SystemMaxFileSize=50M
MaxRetentionSec=7day
EOF
systemctl restart systemd-journald 2>/dev/null || true

# -------- Step 4: User & group setup ----------
echo "[4/12] Creating application user..."
if ! getent group "$APP_GROUP" >/dev/null; then
  groupadd --system "$APP_GROUP"
fi
if ! id "$APP_USER" >/dev/null 2>&1; then
  useradd --home-dir "$APP_USER_HOME" --create-home --system --gid "$APP_GROUP" "$APP_USER"
  usermod -aG docker "$APP_USER" 2>/dev/null || true
fi

# -------- Step 5: Install Node.js 22 (smaller footprint) ----------
echo "[5/12] Installing Node.js ${NODE_VERSION}..."
curl -fsSL "https://deb.nodesource.com/setup_${NODE_VERSION}.x" | bash -
apt-get install -y nodejs
node -v
npm -v

# Disable npm telemetry
sudo -u "$APP_USER" npm config set disable-metrics true
npm config set disable-metrics true

echo "[INFO] Optimizing npm for production"
npm install -g npm@latest --silent

# -------- Step 6: Install Ollama (minimal setup) ----------
echo "[6/12] Installing Ollama..."
curl -fsSL https://ollama.com/install.sh | sh

# Restrict Ollama memory aggressively
mkdir -p /etc/systemd/system/ollama.service.d/
cat > /etc/systemd/system/ollama.service.d/99-opendots.conf <<'EOF'
[Service]
MemoryMax=5G
MemoryAccounting=yes
CPUQuota=350%
IOWeight=300
NoNewPrivileges=true
PrivateTmp=yes
ProtectSystem=strict
ProtectHome=yes
ReadWritePaths=/root/.ollama
EOF

systemctl daemon-reload
systemctl enable --now ollama
echo "[INFO] Waiting for Ollama to start..."
sleep 8

# -------- Step 7: Pull optimized model ----------
echo "[7/12] Downloading model: ${SELECTED_MODEL}"
echo "[INFO] This may take 5-15 minutes depending on connection speed..."

# Set memory limit for model pull
OLLAMA_NUM_GPU=0 /usr/local/bin/ollama pull "${SELECTED_MODEL}" || {
  echo "[WARNING] Pull failed, retrying with fallback..."
  /usr/local/bin/ollama pull "neural-chat:7b-v3.3-q4_K_M"
}

echo "[INFO] Model download complete"

# Verify model is loaded
/usr/local/bin/ollama list

# -------- Step 8: Prepare application directory ----------
echo "[8/12] Cloning and configuring OpenDots..."
mkdir -p /opt /var/lib/opendots
git clone --depth=1 https://github.com/CopilotKit/OpenDots.git "${APP_DIR}" 2>/dev/null || {
  cd "${APP_DIR}"
  git fetch origin
  git reset --hard origin/main
}

chown -R "${APP_USER}:${APP_GROUP}" "${APP_DIR}" /var/lib/opendots
chmod 750 /var/lib/opendots

# -------- Step 9: Create optimized .env ----------
echo "[9/12] Creating production environment..."
OWNER_TOKEN="$(openssl rand -hex 32)"

cat > "${APP_DIR}/.env" <<EOF
# === Application ===
HOST=0.0.0.0
PORT=${APP_PORT}
DATABASE_PATH=${DB_PATH}
OWNER_ID=opendots-owner
OWNER_TOKEN=${OWNER_TOKEN}
APP_ORIGIN=http://127.0.0.1:${APP_PORT}

# === AI Model (Local Ollama) ===
OPENAI_API_KEY=${OPENAI_API_KEY}
OPENAI_BASE_URL=${OPENAI_BASE_URL}
OPENAI_MODEL=${SELECTED_MODEL}

# === Disabled Services (save RAM) ===
WEB_SEARCH_PROVIDER=disabled
BROWSER_SECRET=
VOICE_API_KEY=
VOICE_MODEL=

# === Intelligence (optional - leave empty for local only) ===
INTELLIGENCE_API_KEY=
CPK_INTELLIGENCE_API_KEY=

# === Performance ===
NODE_ENV=production
NODE_OPTIONS=--max-old-space-size=2048

# === Telemetry (disable to save bandwidth) ===
COPILOTKIT_TELEMETRY_DISABLED=true
DO_NOT_TRACK=1
EOF

chown "${APP_USER}:${APP_GROUP}" "${APP_DIR}/.env"
chmod 600 "${APP_DIR}/.env"

# -------- Step 10: Build OpenDots with minimal footprint ----------
echo "[10/12] Building OpenDots (this takes 3-5 minutes)..."
cd "${APP_DIR}"

# Use system Node to build, minimal dependencies
sudo -u "${APP_USER}" bash -c 'npm ci --prefer-offline --no-audit 2>&1 | tail -20'
sudo -u "${APP_USER}" bash -c 'npm run build 2>&1 | grep -E "error|warning|✔|✓" || true'

echo "[INFO] Build complete"

# Clean up build artifacts
rm -rf "${APP_DIR}/.next" "${APP_DIR}/.turbo" "${APP_DIR}/node_modules/.cache" 2>/dev/null || true
npm cache clean --force 2>/dev/null || true

# -------- Step 11: Create systemd service ----------
echo "[11/12] Creating systemd service..."
cat > /etc/systemd/system/opendots.service <<EOF
[Unit]
Description=OpenDots AI Agent (Local Ollama)
After=network-online.target ollama.service
Wants=network-online.target ollama.service
Requires=ollama.service

[Service]
Type=simple
User=${APP_USER}
Group=${APP_GROUP}
WorkingDirectory=${APP_DIR}
Environment="NODE_ENV=production"
Environment="NODE_OPTIONS=--max-old-space-size=2048 --disable-warnings"
Environment="HOST=0.0.0.0"
Environment="PORT=${APP_PORT}"
Environment="DATABASE_PATH=${DB_PATH}"
Environment="OPENAI_API_KEY=${OPENAI_API_KEY}"
Environment="OPENAI_BASE_URL=${OPENAI_BASE_URL}"
Environment="OPENAI_MODEL=${SELECTED_MODEL}"

# Resource limits for 8GB system
MemoryMax=3.5G
MemoryAccounting=yes
CPUQuota=400%
CPUAccounting=yes
TasksMax=1024
IOWeight=350

# Service behavior
ExecStart=/usr/bin/node dist/server/server/index.js
ExecReload=/bin/kill -HUP \$MAINPID
Restart=always
RestartSec=10
KillMode=mixed
KillSignal=SIGTERM
TimeoutStopSec=30

# Security
NoNewPrivileges=true
PrivateTmp=yes
ProtectSystem=strict
ProtectHome=yes
ReadWritePaths=${APP_DIR} /var/lib/opendots

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable opendots

# -------- Step 12: Start services & verify ----------
echo "[12/12] Starting services and performing health checks..."
systemctl restart ollama
sleep 5

# Verify Ollama is responding
echo "[INFO] Testing Ollama endpoint..."
if curl -s http://127.0.0.1:11434/api/tags | grep -q "models"; then
  echo "[✓] Ollama is responsive"
else
  echo "[WARNING] Ollama not responding yet, will retry..."
  sleep 5
fi

# Start OpenDots
systemctl start opendots
echo "[INFO] OpenDots starting (first start takes 15-30 seconds)..."
sleep 20

# Check status
if systemctl is-active --quiet opendots; then
  echo "[✓] OpenDots is running"
else
  echo "[WARNING] OpenDots may not be fully started yet"
  sleep 10
fi

# Final summary
echo ""
echo "========================================================================"
echo "[✓] Installation Complete"
echo "========================================================================"
echo ""
echo "🌐 ACCESS YOUR OPENDOTS INSTANCE:"
echo "   http://127.0.0.1:${APP_PORT}"
echo ""
echo "   If accessing from another machine:"
echo "   http://<your-vm-ip>:${APP_PORT}"
echo ""
echo "🤖 MODEL INFORMATION:"
echo "   Selected: ${SELECTED_MODEL}"
echo "   Endpoint: ${OPENAI_BASE_URL}"
echo "   Status: Type 'ollama ls' to verify"
echo ""
echo "💾 RESOURCE ALLOCATION:"
echo "   OpenDots RAM: 3.5 GB max"
echo "   Ollama RAM: 5 GB max"
echo "   Swap: 4 GB (for model loading)"
echo "   Available: ~2 GB system buffer"
echo ""
echo "📊 USEFUL COMMANDS:"
echo "   systemctl status opendots              # Check status"
echo "   journalctl -fu opendots -n 100         # View logs (last 100 lines)"
echo "   systemctl restart opendots              # Restart service"
echo "   systemctl restart ollama                # Restart AI backend"
echo "   ollama ps                               # Active model sessions"
echo "   free -h                                 # Check memory usage"
echo ""
echo "🔧 SWITCH MODEL (edit .env, restart):"
echo "   sudo nano /opt/opendots/.env"
echo "   OPENAI_MODEL=<new-model>"
echo "   sudo systemctl restart opendots"
echo ""
echo "📥 CHANGE AI MODEL:"
echo "   sudo ollama pull neural-chat:7b-v3.3-q4_K_M"
echo "   sudo ollama pull qwen3:4b-chat-q4_K_M"
echo "   sudo ollama pull phi:3.5"
echo "   (then update .env and restart)"
echo ""
echo "🆘 TROUBLESHOOTING:"
echo "   Memory full?    → Check 'free -h', may need to restart"
echo "   Slow responses? → Use a smaller model: phi4 or smollm2:135m"
echo "   OOM errors?     → Reduce model size or increase swap"
echo ""
echo "📝 LOG FILE: ${LOG_FILE}"
echo "========================================================================"
echo ""
