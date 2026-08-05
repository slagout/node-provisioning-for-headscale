#!/usr/bin/env bash
#
# EcoSynQ Node Adoption Script
# Generates STTS hostnames, assigns roles, and registers on Headscale mesh.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/slagout/node-provisioning-for-headscale/main/eco-node-adopt.sh \
#     | sudo HEADSCALE_URL="https://headscale.tradingnations.cloud" \
#            PRE_AUTH_KEY="hskey_xxxxxxxx" \
#            NODE_ROLE="observation" \
#            NODE_REGION="usvi_atlantic" \
#            NODE_DATACENTER="hq" \
#            bash

set -euo pipefail

readonly SCRIPT_VERSION="2.0.0-ecosynq"
readonly CONFIG_DIR="/etc/ecosynq"
readonly NODE_IDENTITY_FILE="${CONFIG_DIR}/node-identity.json"
readonly LOG_FILE="/var/log/ecosynq-adoption.log"

# Valid roles from the EcoSynQ architecture specification.
declare -ra VALID_ROLES=(
  "observation"
  "causal-inference"
  "independent-validation"
  "regional-qsa"
  "quantumvm"
  "q-topology"
  "surrealdb-projection"
  "immudb-evidence-authority"
  "checkout-registry"
)

# Role-to-service-port mapping for downstream policy/ACL use.
declare -A ROLE_PORTS=(
  ["observation"]="9001"
  ["causal-inference"]="9002"
  ["independent-validation"]="9003"
  ["regional-qsa"]="9004"
  ["quantumvm"]="9005"
  ["q-topology"]="9006"
  ["surrealdb-projection"]="9007"
  ["immudb-evidence-authority"]="9008"
  ["checkout-registry"]="9009"
)

RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()  { echo -e "${BLUE}[ECOSYNQ]${NC} $(date -u '+%Y-%m-%dT%H:%M:%SZ') $1" | tee -a "$LOG_FILE"; }
ok()   { echo -e "${GREEN}[OK]${NC} $1" | tee -a "$LOG_FILE"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1" | tee -a "$LOG_FILE"; }
err()  { echo -e "${RED}[ERROR]${NC} $1" | tee -a "$LOG_FILE" >&2; }

require_root() {
  if [[ "$(id -u)" -ne 0 ]]; then
    err "This script must run as root (use sudo)."
    exit 1
  fi
}

generate_stts_timestamp() {
  # Format: DDHHMMSSz-MMM-YYYY
  date -u '+%d%H%M%Sz-%b-%Y' | tr '[:upper:]' '[:lower:]'
}

generate_short_hash() {
  # 4-character hex fragment for collision reduction.
  head -c 4 /dev/urandom | od -An -tx1 | tr -d ' \n' | head -c 4
}

generate_node_name() {
  local role="$1"
  local cc="$2"

  # Timestamp: DDHHMMSSzMMYYYY — all numeric, no separators
  local timestamp
  timestamp="$(date -u '+%d%H%M%Sz%m%Y')"

  # Short random hash for collision resistance
  local hash
  hash="$(generate_short_hash)"

  echo "${role}-${cc}-${timestamp}-${hash}"
}

validate_role() {
  local role="$1"
  local valid

  for valid in "${VALID_ROLES[@]}"; do
    if [[ "$role" == "$valid" ]]; then
      return 0
    fi
  done

  err "Invalid role: $role"
  echo "Valid roles:"
  printf '  - %s\n' "${VALID_ROLES[@]}"
  return 1
}

validate_environment() {
  local missing=0

  : "${HEADSCALE_URL:?HEADSCALE_URL is required}"
  : "${PRE_AUTH_KEY:?PRE_AUTH_KEY is required}"
  : "${NODE_ROLE:?NODE_ROLE is required}"
  : "${NODE_REGION:?NODE_REGION is required}"

  if [[ "$PRE_AUTH_KEY" == "REPLACE_WITH_HEADSCALE_PREAUTH_KEY" ]]; then
    err "PRE_AUTH_KEY is still set to placeholder value."
    ((missing++))
  fi

  validate_role "$NODE_ROLE" || ((missing++))

  if [[ $missing -gt 0 ]]; then
    err "Environment validation failed."
    exit 1
  fi
}

prepare_system() {
  log "Preparing system for EcoSynQ node adoption"

  mkdir -p "$CONFIG_DIR"
  chmod 700 "$CONFIG_DIR"
  touch "$LOG_FILE"
  chmod 600 "$LOG_FILE"

  export DEBIAN_FRONTEND=noninteractive

  if ! command -v curl >/dev/null 2>&1; then
    apt-get update -qq
    apt-get install -y -qq curl ca-certificates
  fi

  if ! command -v jq >/dev/null 2>&1; then
    apt-get update -qq
    apt-get install -y -qq jq
  fi

  if ! command -v tailscale >/dev/null 2>&1; then
    log "Installing Tailscale"
    curl -fsSL https://tailscale.com/install.sh | sh
    ok "Tailscale installed"
  else
    ok "Tailscale already installed"
  fi

  if ! systemctl is-active --quiet tailscaled 2>/dev/null; then
    log "Starting tailscaled service"
    systemctl enable --now tailscaled
  fi
}

set_hostname() {
  local node_name="$1"

  log "Setting hostname to: $node_name"
  hostnamectl set-hostname "$node_name"
  ok "Hostname set"

  local self_ip
  self_ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
  if [[ -n "${self_ip}" ]] && ! grep -q "[[:space:]]${node_name}$" /etc/hosts; then
    echo "$self_ip $node_name" >> /etc/hosts
  fi
}

register_with_headscale() {
  local node_name="$1"
  local role="$2"
  local region="$3"

  log "Registering node with Headscale"
  log "Control URL: $HEADSCALE_URL"
  log "Node: $node_name"
  log "Role: $role"
  log "Region: $region"

  tailscale up \
    --login-server="$HEADSCALE_URL" \
    --auth-key="$PRE_AUTH_KEY" \
    --hostname="$node_name" \
    --accept-dns=false \
    --accept-routes=false \
    --advertise-tags="tag:${role}" \
    --reset 2>&1 | tee -a "$LOG_FILE"

  log "Waiting for mesh connection"
  sleep 5

  local online
  online="$(tailscale status --json 2>/dev/null | jq -r '.Self.Online // false')"
  if [[ "$online" != "true" ]]; then
    err "Failed to register with Headscale mesh"
    err "Check: tailscale status and journalctl -u tailscaled"
    exit 1
  fi

  local node_ip
  node_ip="$(tailscale ip -4 2>/dev/null | head -n1 || echo "unknown")"
  local node_id
  node_id="$(tailscale status --json 2>/dev/null | jq -r '.Self.ID // "unknown"')"

  ok "Node registered on Headscale mesh"
  log "Mesh IP: $node_ip"
  log "Node ID: $node_id"
}

write_identity_file() {
  local node_name="$1"
  local role="$2"
  local region="$3"
  local datacenter="${4:-unset}"

  local node_ip
  node_ip="$(tailscale ip -4 2>/dev/null | head -n1 || echo "pending")"

  local node_id
  node_id="$(tailscale status --json 2>/dev/null | jq -r '.Self.ID // "pending"')"

  local os_info
  os_info="$(uname -srm)"

  local kernel_version
  kernel_version="$(uname -r)"

  local hardware
  hardware="$(hostnamectl 2>/dev/null | awk -F: '/Hardware Vendor/{gsub(/^ +/,"",$2); print $2; exit}' || true)"
  hardware="${hardware:-unknown}"

  local service_port="${ROLE_PORTS[$role]:-9999}"

  log "Writing identity file: $NODE_IDENTITY_FILE"

  jq -n \
    --arg name "$node_name" \
    --arg role "$role" \
    --arg region "$region" \
    --arg datacenter "$datacenter" \
    --arg mesh_ip "$node_ip" \
    --arg node_id "$node_id" \
    --arg os "$os_info" \
    --arg kernel "$kernel_version" \
    --arg hardware "$hardware" \
    --arg service_port "$service_port" \
    --arg adopted_at "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
    --arg script_version "$SCRIPT_VERSION" \
    --arg headscale_url "$HEADSCALE_URL" \
    '{
      node_name: $name,
      node_role: $role,
      node_region: $region,
      node_datacenter: $datacenter,
      mesh_ip: $mesh_ip,
      node_id: $node_id,
      os: $os,
      kernel: $kernel,
      hardware_vendor: $hardware,
      service_port: $service_port,
      adopted_at_utc: $adopted_at,
      script_version: $script_version,
      headscale_server: $headscale_url,
      identity_proof_pending: true,
      evidence_chain_enabled: true
    }' > "$NODE_IDENTITY_FILE"

  chmod 600 "$NODE_IDENTITY_FILE"
  ok "Identity file written"
}

start_role_service_marker() {
  local role="$1"
  local service_port="${ROLE_PORTS[$role]:-9999}"
  local service_marker="${CONFIG_DIR}/${role}.service-marker"

  log "Creating role marker for Landscape handoff"

  cat > "$service_marker" <<EOF
role=${role}
port=${service_port}
registered=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
status=awaiting-landscape-deployment
EOF

  chmod 600 "$service_marker"
  ok "Role marker created: $service_marker"
}

display_summary() {
  local node_name="$1"
  local role="$2"
  local region="$3"
  local node_ip

  node_ip="$(tailscale ip -4 2>/dev/null | head -n1 || echo "pending")"

  echo ""
  echo "=============================================="
  echo "EcoSynQ Node Adoption Summary"
  echo "=============================================="
  echo "Node Name:    $node_name"
  echo "Role:         $role"
  echo "Region:       $region"
  echo "Mesh IP:      $node_ip"
  echo "Service Port: ${ROLE_PORTS[$role]:-9999}"
  echo "Headscale:    $HEADSCALE_URL"
  echo "Identity:     $NODE_IDENTITY_FILE"
  echo "Status:       ADOPTED"
  echo "Next:         Landscape fleet registration"
  echo "=============================================="
  echo ""
}

main() {
  require_root

  validate_environment
  log "Role validated: $NODE_ROLE"
  log "Region: $NODE_REGION"

  local node_name
  node_name="$(generate_node_name "$NODE_ROLE" "$NODE_REGION")"
  ok "Generated STTS hostname: $node_name"

  prepare_system
  set_hostname "$node_name"
  register_with_headscale "$node_name" "$NODE_ROLE" "$NODE_REGION"
  write_identity_file "$node_name" "$NODE_ROLE" "$NODE_REGION" "${NODE_DATACENTER:-unset}"
  start_role_service_marker "$NODE_ROLE"
  display_summary "$node_name" "$NODE_ROLE" "$NODE_REGION"

  log "Node adoption complete"
}

main "$@"
