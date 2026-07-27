#!/usr/bin/env bash
#
# EcoSynQ Sovereign Edge Node Installer
# Target: Ubuntu Server 20.04 / 22.04 / 24.04 (x86_64 & ARM64)
# Purpose: Deploy Podman containers, adopt on Headscale + Ubuntu Landscape, STTS canonical naming
#
set -euo pipefail

DRY_RUN=0
UNINSTALL=0

# ======================================================================
# CONFIGURATION — EDIT THESE VALUES BEFORE DEPLOYMENT
# ======================================================================
HEADSCALE_URL="${HEADSCALE_URL:-https://headscale.ecosynq.local}"
PRE_AUTH_KEY="${PRE_AUTH_KEY:-REPLACE_WITH_HEADSCALE_PREAUTH_KEY}"

LANDSCAPE_SERVER_URL="${LANDSCAPE_SERVER_URL:-https://landscape.ecosynq.local}"
LANDSCAPE_ACCOUNT_NAME="${LANDSCAPE_ACCOUNT_NAME:-canonical}"
LANDSCAPE_PUBLIC_KEY="${LANDSCAPE_PUBLIC_KEY:-}"  # Paste Landscape public key here
LANDSCAPE_PRIVATE_KEY="${LANDSCAPE_PRIVATE_KEY:-}" # Paste Landscape private key here

# Geographic/Operational metadata for STTS naming (edit per deployment region)
NODE_REGION="${NODE_REGION:-usvi}"           # Spatial: geographic region code
NODE_DATACENTER="${NODE_DATACENTER:-charleston}"  # Spatial: facility identifier
NODE_ROLE="${NODE_ROLE:-witness}"             # Semantic: node function
NODE_SEQUENCER="${NODE_SEQUENCER:-auto}"      # Thematic: sequencer/index (auto generates unique)
AUDIT_DIR="/var/lib/ecosynq"
AUDIT_FILE="${AUDIT_DIR}/node-registration.json"
# ======================================================================

# --- Colors ---
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; BLUE='\033[0;34m'
NC='\033[0m'

log()  { echo -e "${GREEN}[$(date '+%H:%M:%S')]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
err()  { echo -e "${RED}[ERROR]${NC} $1" >&2; }

run_cmd() {
  if [ "${DRY_RUN}" -eq 1 ]; then
    log "[DRY-RUN] $*"
  else
    "$@"
  fi
}

usage() {
  cat << 'EOF'
Usage: eco-headscale-landscape-install.sh [options]

Options:
  --dry-run     Print actions without changing the system
  --uninstall   Safely remove EcoSynQ containers/network and local audit record
  -h, --help    Show this help
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run)
      DRY_RUN=1
      ;;
    --uninstall)
      UNINSTALL=1
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      err "Unknown option: $1"
      usage
      exit 1
      ;;
  esac
  shift
done

# --- Root check ---
if [ "$(id -u)" -ne 0 ]; then
  err "This script must be run as root. Try: sudo bash eco-headscale-landscape-install.sh"
  exit 1
fi

# --- Detect architecture ---
ARCH=$(dpkg --print-architecture 2>/dev/null || uname -m)
log "Detected architecture: ${ARCH}"

# --- Detect Ubuntu version ---
CODENAME=$(. /etc/os-release 2>/dev/null && echo "${VERSION_CODENAME:-noble}" || echo "noble")
log "OS codename: ${CODENAME}"

if [ "${UNINSTALL}" -eq 1 ]; then
  log "Running safe uninstall mode..."

  if command -v podman >/dev/null 2>&1; then
    for container in ecosynq-immudb ecosynq-postgres ecosynq-redis; do
      if podman container exists "${container}" 2>/dev/null; then
        run_cmd podman rm -f "${container}"
      else
        log "Container not present: ${container}"
      fi
    done

    if podman network exists ecosynq 2>/dev/null; then
      run_cmd podman network rm ecosynq || warn "Could not remove network 'ecosynq' (it may still be in use)."
    else
      log "Network not present: ecosynq"
    fi
  else
    warn "Podman not installed; skipping container and network cleanup."
  fi

  if [ -f "${AUDIT_FILE}" ]; then
    run_cmd rm -f "${AUDIT_FILE}"
    log "Removed local audit record: ${AUDIT_FILE}"
  else
    log "No local audit record found at: ${AUDIT_FILE}"
  fi

  warn "Safe uninstall preserves package installations, volumes, and remote registrations."
  warn "If desired, manually run: tailscale down and landscape-config --help"
  exit 0
fi

# ======================================================================
# STEP 1: STTS Canonical Node Name Generation
# ======================================================================
log "Generating STTS canonical node name..."

# Get UTC timestamp components for Temporal element
TS_YYYY=$(date -u +%Y)
TS_MM=$(date -u +%m)
TS_DD=$(date -u +%d)
TS_HH=$(date -u +%H)
TS_MMN=$(date -u +%M)
TS_SSS=$(date -u +%3N)  # milliseconds

# Generate unique sequencer (Thematic element) - uses hardware entropy if available
if [ "$NODE_SEQUENCER" = "auto" ]; then
  # Use /dev/urandom for uniqueness across concurrent installations
  SEQUENCER=$(head -c 4 /dev/urandom | od -An -tx1 | tr -d ' \n' | head -c 8)
else
  SEQUENCER="$NODE_SEQUENCER"
fi

# Build the STTS canonical name:
# Format: {Semantic}-{Spatial}-{TemporalHex}-{Thematic}
# Example: witness-usvi-27180650-9f3a2b1c-jul-2026
NODE_NAME="node-${NODE_ROLE}-${NODE_REGION}-${TS_DD}${TS_HH}${TS_MMN}${TS_SSS}-${SEQUENCER}-${TS_MMN,,}-${TS_YYYY}"

# Validate hostname length (Linux max = 63 chars)
if [ ${#NODE_NAME} -gt 63 ]; then
  # Truncate gracefully if too long
  NODE_NAME="${NODE_ROLE}-${NODE_REGION}-${TS_DD}${TS_HH}${TS_MMN}-${SEQUENCER}-${TS_YYYY: -4}"
  if [ ${#NODE_NAME} -gt 63 ]; then
    NODE_NAME="${NODE_ROLE}-${NODE_REGION}-${TS_DD}${TS_HH}${TS_MMN}-${TS_YYYY: -4}"
  fi
fi

log "Node name assigned: ${CYAN}${NODE_NAME}${NC}"
log "STTS Elements:"
log "  - Spatial: ${NODE_REGION}/${NODE_DATACENTER}"
log "  - Temporal: ${TS_YYYY}-${TS_MM}-${TS_DD}T${TS_HH}:${TS_MMN}:${TS_SSS}Z"
log "  - Thematic: ${SEQUENCER}"
log "  - Semantic: ${NODE_ROLE}"

# ======================================================================
# STEP 2: Dependency Detection & Installation
# ======================================================================
log "Checking for required dependencies..."

DEPS_MISSING=()

check_dep() {
  if command -v "$1" >/dev/null 2>&1; then
    log "  ✓ ${1} already installed"
  else
    warn "  ✗ ${1} missing — will install"
    DEPS_MISSING+=("$2")
  fi
}

# Tools we need
check_dep "curl"      "curl"
check_dep "wget"      "wget"
check_dep "jq"        "jq"
check_dep "gnupg"     "gnupg"
check_dep "ca-certificates" "ca-certificates"
check_dep "apt-get"   ""

if [ ${#DEPS_MISSING[@]} -gt 0 ]; then
  TO_INSTALL=()
  for pkg in "${DEPS_MISSING[@]}"; do
    [ -n "$pkg" ] && TO_INSTALL+=("$pkg")
  done

  if [ ${#TO_INSTALL[@]} -gt 0 ]; then
    log "Installing missing dependencies: ${TO_INSTALL[*]}"
    run_cmd apt-get update -qq
    run_cmd apt-get install -y -qq "${TO_INSTALL[@]}"
  fi
else
  log "All dependencies satisfied."
fi

# ======================================================================
# STEP 3: Install Podman Container Runtime
# ======================================================================
log "Installing Podman container runtime..."

PODMAN_INSTALLED=0

if command -v podman >/dev/null 2>&1; then
  CURRENT_VER=$(podman --version 2>/dev/null | head -1 || echo "unknown")
  log "Podman already installed (${CURRENT_VER})"
  PODMAN_INSTALLED=1
else
  # Add Podman repository
  case "${CODENAME}" in
    jammy|noble)
      run_cmd apt-get update -qq
      run_cmd apt-get install -y -qq software-properties-common
      if [ "${DRY_RUN}" -eq 1 ]; then
        log "[DRY-RUN] add-apt-repository -y ppa:projectatomic/podman-standalone"
      else
        add-apt-repository -y ppa:projectatomic/podman-standalone 2>/dev/null || true
      fi
      run_cmd apt-get update -qq
      ;;
    focal)
      # Older Ubuntu: use Snap or direct binary
      run_cmd snap install podman --classic 2>/dev/null || {
        log "Snap not available, trying alternative installation..."
        run_cmd wget -q https://github.com/containers/podman/releases/download/v4.9.4/podman_4.9.4_amd64.deb
        run_cmd dpkg -i podman_4.9.4_amd64.deb
        run_cmd rm -f podman_4.9.4_amd64.deb
      }
      ;;
  esac

  # Alternative: direct apt package
  if ! command -v podman >/dev/null 2>&1; then
    run_cmd apt-get update -qq
    run_cmd apt-get install -y -qq podman containernetworking-tools crun
  fi

  if command -v podman >/dev/null 2>&1; then
    log "Podman installed successfully."
    PODMAN_INSTALLED=1
  else
    err "Podman installation failed. Aborting."
    exit 1
  fi
fi

# Configure Podman to use systemd
run_cmd mkdir -p ~/.config/systemd/user/
log "Configuring Podman rootless mode..."

# ======================================================================
# STEP 4: Install Tailscale Client (Headscale compatible)
# ======================================================================
log "Installing Tailscale client for Headscale mesh..."

TS_INSTALLED=0

if command -v tailscale >/dev/null 2>&1; then
  CURRENT_VER=$(tailscale version 2>/dev/null | head -1 || echo "unknown")
  log "Tailscale already installed (${CURRENT_VER})"
  TS_INSTALLED=1
else
  log "Installing Tailscale client..."

  # Official Tailscale install script
  if [ "${DRY_RUN}" -eq 1 ]; then
    log "[DRY-RUN] curl -fsSL https://pkgs.tailscale.com/stable/ubuntu/${CODENAME}.noarmor.gpg | tee /usr/share/keyrings/tailscale-archive-keyring.gpg"
  else
    curl -fsSL "https://pkgs.tailscale.com/stable/ubuntu/${CODENAME}.noarmor.gpg" \
      | tee /usr/share/keyrings/tailscale-archive-keyring.gpg >/dev/null
  fi

  if [ "${DRY_RUN}" -eq 1 ]; then
    log "[DRY-RUN] curl -fsSL https://pkgs.tailscale.com/stable/ubuntu/${CODENAME}.tailscale-keyring.list | tee /etc/apt/sources.list.d/tailscale.list"
  else
    curl -fsSL "https://pkgs.tailscale.com/stable/ubuntu/${CODENAME}.tailscale-keyring.list" \
      | tee /etc/apt/sources.list.d/tailscale.list >/dev/null
  fi

  run_cmd apt-get update -qq
  run_cmd apt-get install -y -qq tailscale

  if command -v tailscale >/dev/null 2>&1; then
    log "Tailscale installed successfully."
    TS_INSTALLED=1
  else
    err "Tailscale installation failed."
    exit 1
  fi
fi

# Ensure tailscaled is running
if ! systemctl is-active --quiet tailscaled 2>/dev/null; then
  log "Starting tailscaled service..."
  run_cmd systemctl enable --now tailscaled
  [ "${DRY_RUN}" -eq 1 ] || sleep 2
fi

# ======================================================================
# STEP 5: Adopt Node on Headscale Server
# ======================================================================
log "Adopting node on Headscale server: ${HEADSCALE_URL}"

# Check if node already registered
EXISTING_STATUS=""
if command -v tailscale >/dev/null 2>&1; then
  EXISTING_STATUS=$(tailscale status --json 2>/dev/null | jq -r '.Self.Online // "unknown"' 2>/dev/null || echo "")
fi

if [ -n "$EXISTING_STATUS" ] && [ "$EXISTING_STATUS" != "unknown" ] && [ "$EXISTING_STATUS" != "false" ]; then
  warn "Node appears already registered with Headscale. Verifying hostname..."
  CURRENT_HOSTNAME=$(tailscale status --json 2>/dev/null | jq -r '.Self.DNSName // "unknown"' 2>/dev/null || echo "")
  if [[ "$CURRENT_HOSTNAME" != *"$NODE_NAME"* ]]; then
    warn "Hostname mismatch. Resetting tailscale configuration..."
    run_cmd tailscale down 2>/dev/null || true
  fi
fi

# Build the tailscale up command
TS_UP_CMD=(
  tailscale up
  --login-server="${HEADSCALE_URL}"
  --hostname="${NODE_NAME}"
  --auth-key="${PRE_AUTH_KEY}"
  --accept-dns=false
  --accept-routes=true
  --advertise-routes=""
  --reset
)

log "Executing Headscale adoption..."
if run_cmd "${TS_UP_CMD[@]}" 2>&1; then
  log "Headscale adoption command submitted successfully."
else
  warn "tailscale up returned non-zero — node may already be registered or needs manual approval."
  warn "Check with: tailscale status"
fi

# Wait for network convergence
log "Waiting for mesh convergence..."
[ "${DRY_RUN}" -eq 1 ] || sleep 4

# ======================================================================
# STEP 6: Install and Register with Ubuntu Landscape Server
# ======================================================================
log "Installing Ubuntu Landscape client..."

LANDSCAPE_INSTALLED=0

if command -v landscape-client >/dev/null 2>&1; then
  CURRENT_VER=$(landscape-client --version 2>/dev/null | head -1 || echo "unknown")
  log "Landscape already installed (${CURRENT_VER})"
  LANDSCAPE_INSTALLED=1
else
  run_cmd apt-get update -qq
  run_cmd apt-get install -y -qq landscape-client landscape-common
  LANDSCAPE_INSTALLED=1
fi

# Configure Landscape registration
if [ -n "$LANDSCAPE_PUBLIC_KEY" ] && [ -n "$LANDSCAPE_PRIVATE_KEY" ]; then
  log "Registering node with Landscape server..."

  # Register with Landscape using STTS node name
  REGISTER_CMD=(
    landscape-config
    --computer-title="${NODE_NAME}"
    --account-name="${LANDSCAPE_ACCOUNT_NAME}"
    --url="${LANDSCAPE_SERVER_URL}/message-system"
    --public-key-content="${LANDSCAPE_PUBLIC_KEY}"
    --private-key-content="${LANDSCAPE_PRIVATE_KEY}"
    --tags="ecosynq,${NODE_ROLE},${NODE_REGION},stts-canonical"
  )

  if run_cmd "${REGISTER_CMD[@]}" 2>&1; then
    log "Landscape registration successful."
  else
    warn "Landscape registration failed — check credentials and server URL."
    warn "Manual registration command saved to: /tmp/landscape-register.sh"
    if [ "${DRY_RUN}" -eq 1 ]; then
      log "[DRY-RUN] Would write fallback command to /tmp/landscape-register.sh"
    else
      cat > /tmp/landscape-register.sh << EOF
#!/bin/bash
landscape-config \\
  --computer-title="${NODE_NAME}" \\
  --account-name="${LANDSCAPE_ACCOUNT_NAME}" \\
  --url="${LANDSCAPE_SERVER_URL}/message-system" \\
  --public-key-content="${LANDSCAPE_PUBLIC_KEY}" \\
  --private-key-content="${LANDSCAPE_PRIVATE_KEY}" \\
  --tags="ecosynq,${NODE_ROLE},${NODE_REGION},stts-canonical"
EOF
      chmod +x /tmp/landscape-register.sh
    fi
  fi
else
  warn "Landscape keys not configured. Skipping automatic registration."
  warn "Provide LANDSCAPE_PUBLIC_KEY and LANDSCAPE_PRIVATE_KEY to enable auto-registration."
  warn "Or register manually with: landscape-config --help"
fi

# ======================================================================
# STEP 7: Verify Connectivity & Report
# ======================================================================
TS_STATUS_JSON=""
LANDSCAPE_STATUS="not_configured"

if command -v jq >/dev/null 2>&1; then
  TS_STATUS_JSON=$(tailscale status --json 2>/dev/null || echo "")
  if landscape-info 2>/dev/null | grep -qi "connected"; then
    LANDSCAPE_STATUS="connected"
  else
    LANDSCAPE_STATUS="not_connected"
  fi
fi

ONLINE="unknown"
TS_IP="unassigned"

if [ -n "$TS_STATUS_JSON" ]; then
  ONLINE=$(echo "$TS_STATUS_JSON" | jq -r '.Self.Online // "unknown"' 2>/dev/null || echo "unknown")
  TS_IP=$(echo "$TS_STATUS_JSON" | jq -r '.TailscaleIPs[0] // "unassigned"' 2>/dev/null || echo "unassigned")
fi

# ======================================================================
# STEP 8: Write Local Registration Record (Vogon-Style JSON)
# ======================================================================
run_cmd mkdir -p "$AUDIT_DIR"

if [ "${DRY_RUN}" -eq 1 ]; then
  log "[DRY-RUN] Would write local registration record to ${AUDIT_FILE}"
else
cat > "$AUDIT_FILE" << EOF
{
  "FormalVogonArtifact": {
    "ArtifactID": {
      "ProtocolDomain": {
        "utf8": "ECOSYNQ"
      },
      "utf8": "NODE-REGISTRATION"
    },
    "DynamicData": {
      "class": "EcoSynQEdgeNode",
      "payload": {
        "epochHeader": {
          "atomicDTG": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
          "version": "01.0",
          "concept": "EcoSynQ Sovereign Edge Node Registration",
          "spatial": {
            "region": "${NODE_REGION}",
            "datacenter": "${NODE_DATACENTER}",
            "jurisdiction": "USVI",
            "coordinate_reference_system": "EPSG:4326"
          },
          "temporal": {
            "clock_source": "NTP",
            "temporal_reference": "UTC",
            "epoch_group_id": "${NODE_NAME}"
          },
          "thematic": {
            "sequencer": "${SEQUENCER}",
            "analytics_tomograph_tags": [
              "NodeDeployment",
              "STTSCanonical",
              "ProofWitness"
            ],
            "temporal_authority_score": 0.98
          },
          "semantic": {
            "role": "${NODE_ROLE}",
            "description": "Sovereign edge node with Podscape + Landscape integration",
            "epoch_inference_scope": "Deterministic execution and proof generation"
          },
          "addresses": {
            "headscale": "${HEADSCALE_URL}",
            "landscape": "${LANDSCAPE_SERVER_URL}"
          }
        },
        "epochContent": {
          "title": "EcoSynQ Edge Node Registration Certificate",
          "node_name": "${NODE_NAME}",
          "architecture": "${ARCH}",
          "os_codename": "${CODENAME}",
          "tailscale_ip": "${TS_IP}",
          "podman_version": "$(podman --version 2>/dev/null | awk '{print $NF}' || echo "installed")",
          "registration_timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        },
        "epochFooter": {
          "validation_signatures": [
            {
              "role": "Local Auditor",
              "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
              "signature": "Installation verified locally"
            }
          ]
        }
      }
    },
    "address": "b58:${NODE_NAME}"
  }
}
EOF
run_cmd chmod 600 "$AUDIT_FILE"
fi

# ======================================================================
# STEP 9: Deploy EcoSynQ Podman Containers
# ======================================================================
log "Deploying EcoSynQ runtime containers via Podman..."

# Create Podman network for EcoSynQ services
PODMAN_NET_EXISTS=$(podman network ls --format '{{.Name}}' 2>/dev/null | grep -c "ecosynq" || echo "0")
if [ "$PODMAN_NET_EXISTS" -eq 0 ]; then
  log "Creating Podman network 'ecosynq'..."
  run_cmd podman network create ecosynq
fi

# Deploy immudb (immutable proof store)
log "Deploying immudb container..."
run_cmd podman run -d \
  --name ecosynq-immudb \
  --network ecosynq \
  --restart unless-stopped \
  -v immudb-data:/var/lib/immudb \
  -p 3322:3322 \
  -e IMMUDB_ADDRESS=0.0.0.0 \
  -e IMMUDB_PORT_NUMBER=3322 \
  ph21/immudb:latest

# Deploy PostgreSQL (operational facts layer)
log "Deploying PostgreSQL container..."
run_cmd podman run -d \
  --name ecosynq-postgres \
  --network ecosynq \
  --restart unless-stopped \
  -v postgres-data:/var/lib/postgresql/data \
  -e POSTGRES_USER=ecosynq \
  -e POSTGRES_PASSWORD=CHANGE_ME_IN_PRODUCTION \
  -e POSTGRES_DB=quantumvm \
  -p 5432:5432 \
  postgres:15-alpine

# Deploy Redis (caching and ephemeral state)
log "Deploying Redis container..."
run_cmd podman run -d \
  --name ecosynq-redis \
  --network ecosynq \
  --restart unless-stopped \
  -v redis-data:/data \
  -p 6379:6379 \
  redis:7-alpine

# Log container statuses
log "Podman container deployment status:"
run_cmd podman ps --filter "name=ecosynq" --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"

CONTAINERS_RUNNING="0"
if command -v podman >/dev/null 2>&1; then
  CONTAINERS_RUNNING=$(podman ps --filter "name=ecosynq" -q 2>/dev/null | wc -l | tr -d ' ' || echo "0")
fi

# ======================================================================
# REPORT
# ======================================================================
echo ""
echo -e "${CYAN}========================================${NC}"
echo -e "${CYAN}  EcoSynQ Edge Node — Adoption Report   ${NC}"
echo -e "${CYAN}========================================${NC}"
echo ""
echo -e "  Node Name:           ${GREEN}${NODE_NAME}${NC}"
echo -e "  STTS Elements:"
echo -e "    - Spatial:         ${NODE_REGION}/${NODE_DATACENTER}"
echo -e "    - Temporal:        ${TS_YYYY}-${TS_MM}-${TS_DD}T${TS_HH}:${TS_MMN}:${TS_SSS}Z"
echo -e "    - Thematic:        ${SEQUENCER}"
echo -e "    - Semantic:        ${NODE_ROLE}"
echo -e "  Architecture:        ${ARCH}"
echo -e "  OS:                  Ubuntu ${CODENAME}"
echo -e "  Headscale URL:       ${HEADSCALE_URL}"
echo -e "  Headscale Online:    ${ONLINE}"
echo -e "  Tailscale IP:        ${TS_IP}"
echo -e "  Landscape Server:    ${LANDSCAPE_SERVER_URL}"
echo -e "  Landscape Status:    ${LANDSCAPE_STATUS}"
echo -e "  Podman Net:          ecosynq"
echo -e "  Containers Running:  ${CONTAINERS_RUNNING}"
echo -e "  Audit file:          ${AUDIT_FILE}"
echo ""
echo -e "${CYAN}========================================${NC}"

if [ "$ONLINE" = "true" ]; then
  echo -e "${GREEN}✓ Node successfully adopted on Headscale and online.${NC}"
else
  echo -e "${YELLOW}! Headscale status: ${ONLINE}${NC}"
  echo -e "  Check: tailscale status"
fi

if [ "$LANDSCAPE_STATUS" = "connected" ]; then
  echo -e "${GREEN}✓ Node successfully registered with Ubuntu Landscape.${NC}"
else
  echo -e "${YELLOW}! Landscape status: ${LANDSCAPE_STATUS}${NC}"
  echo -e "  Check: landscape-info"
fi

echo -e "${CYAN}========================================${NC}"
echo ""
