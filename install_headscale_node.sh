#!/usr/bin/env bash
set -euo pipefail

# =========================
# Headscale Node Bootstrap
# Ubuntu Server 24.04 LTS
# =========================

# Required env vars:
#   HEADSCALE_SERVER_URL   e.g. https://headscale.tradingnations.cloud
#   HEADSCALE_PRE_AUTH_KEY pre-auth key value
#
# Optional env vars:
#   TAILSCALE_CHANNEL      stable (default) or unstable

: "${HEADSCALE_SERVER_URL:?HEADSCALE_SERVER_URL is required}"
: "${HEADSCALE_PRE_AUTH_KEY:?HEADSCALE_PRE_AUTH_KEY is required}"
TAILSCALE_CHANNEL="${TAILSCALE_CHANNEL:-stable}"

log() {
  printf '[%s] %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*"
}

fail() {
  log "ERROR: $*"
  exit 1
}

log "Generating UTC naming stamp"

# Human display stamp:
# DDHHMMSS.mmmZ MON YYYY
TIMESTAMP_RAW="$(date -u +'%d%H%M%S.%3NZ %b %Y' | tr '[:lower:]' '[:upper:]')"

# Hostname-safe stamp with milliseconds to reduce collision risk:
# node-ddhhmmssmmmz-mon-yyyy
HOSTNAME_SAFE="$(date -u +'%d%H%M%S%3Nz-%b-%Y' | tr '[:upper:]' '[:lower:]')"
HOSTNAME_SAFE="node-${HOSTNAME_SAFE}"

[[ ${#HOSTNAME_SAFE} -le 63 ]] || fail "Hostname exceeds 63 chars: ${HOSTNAME_SAFE}"

log "Raw stamp: ${TIMESTAMP_RAW}"
log "Hostname: ${HOSTNAME_SAFE}"

log "Installing dependencies"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq curl ca-certificates gnupg jq

log "Configuring Tailscale apt source"
install -d -m 0755 /usr/share/keyrings
curl -fsSL "https://pkgs.tailscale.com/${TAILSCALE_CHANNEL}/ubuntu/noble.noarmor.gpg" \
  -o /usr/share/keyrings/tailscale-archive-keyring.gpg
chmod 0644 /usr/share/keyrings/tailscale-archive-keyring.gpg

cat >/etc/apt/sources.list.d/tailscale.list <<EOF
deb [signed-by=/usr/share/keyrings/tailscale-archive-keyring.gpg] https://pkgs.tailscale.com/${TAILSCALE_CHANNEL}/ubuntu noble main
EOF

log "Installing tailscale"
apt-get update -qq
apt-get install -y -qq tailscale

log "Ensuring tailscaled service is running"
systemctl enable --now tailscaled

log "Bringing node up against Headscale"
TS_AUTHKEY="${HEADSCALE_PRE_AUTH_KEY}" tailscale up \
  --login-server="${HEADSCALE_SERVER_URL}" \
  --hostname="${HOSTNAME_SAFE}" \
  --accept-dns=false \
  --accept-routes=false \
  --advertise-exit-node=false \
  --reset

log "Waiting for node to come online"
ONLINE="false"
for _ in $(seq 1 20); do
  ONLINE="$(tailscale status --json | jq -r '.Self.Online // false')"
  if [[ "${ONLINE}" == "true" ]]; then
    break
  fi
  sleep 2
done

[[ "${ONLINE}" == "true" ]] || fail "Node did not come online. Check: journalctl -u tailscaled"

TAIL_IP="$(tailscale ip -4 | head -n1)"
REGISTERED_AT="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"

AUDIT_DIR="/var/lib/ecosynq"
AUDIT_FILE="${AUDIT_DIR}/node-registration-${HOSTNAME_SAFE}.json"

log "Writing audit record"
install -d -m 0700 "${AUDIT_DIR}"
umask 077
cat >"${AUDIT_FILE}" <<EOF
{
  "timestamp_raw": "${TIMESTAMP_RAW}",
  "hostname": "${HOSTNAME_SAFE}",
  "tailscale_ip": "${TAIL_IP}",
  "server_url": "${HEADSCALE_SERVER_URL}",
  "registered_at": "${REGISTERED_AT}",
  "status": "active"
}
EOF

log "SUCCESS: ${HOSTNAME_SAFE} online with IP ${TAIL_IP}"
