#!/usr/bin/env bash
#
# Local, offline smoke test for the EcoSynQ provisioning portal.
#
# Spins up a throwaway local Headscale server and the provisioning-api against
# it, then walks through the exact simplified rollout flow end to end:
#   login -> pick region/role -> one-time curl command -> redeem bootstrap
#   token -> real Headscale pre-auth key issued -> token cannot be reused.
#
# Requires: node >= 18, curl, a Linux environment (WSL is fine). No sudo
# required; headscale runs as a plain user process with no network changes.
#
# Usage: bash scripts/local-provisioning-smoke.sh

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
HEADSCALE_VERSION="0.29.3"

WORKDIR="$(mktemp -d)"
trap 'cleanup' EXIT

cleanup() {
  [[ -f "${WORKDIR}/provisioning-api.pid" ]] && kill "$(cat "${WORKDIR}/provisioning-api.pid")" 2>/dev/null || true
  [[ -f "${WORKDIR}/headscale.pid" ]] && kill "$(cat "${WORKDIR}/headscale.pid")" 2>/dev/null || true
  rm -rf "${WORKDIR}"
}

echo "== Work directory: ${WORKDIR} =="

echo "== Fetching headscale ${HEADSCALE_VERSION} =="
mkdir -p "${WORKDIR}/hs/bin" "${WORKDIR}/hs/data"
curl -fsSL -o "${WORKDIR}/hs/bin/headscale" \
  "https://github.com/juanfont/headscale/releases/download/v${HEADSCALE_VERSION}/headscale_${HEADSCALE_VERSION}_linux_amd64"
chmod +x "${WORKDIR}/hs/bin/headscale"

cat > "${WORKDIR}/hs/policy.json" <<'EOF'
{
  "tagOwners": { "tag:observation": ["provisioner@"] },
  "grants": [],
  "ssh": [],
  "randomizeClientPort": true
}
EOF

cat > "${WORKDIR}/hs/config.yaml" <<EOF
server_url: http://127.0.0.1:8091
listen_addr: 127.0.0.1:8091
metrics_listen_addr: 127.0.0.1:9092
grpc_listen_addr: 127.0.0.1:50444
grpc_allow_insecure: true
trusted_proxies: ["127.0.0.1/32"]
noise:
  private_key_path: ${WORKDIR}/hs/data/noise_private.key
prefixes:
  v4: 100.64.0.0/10
  v6: fd7a:115c:a1e0::/48
  allocation: random
derp:
  server:
    enabled: false
    region_id: 999
    region_code: smoke
    region_name: smoke
    stun_listen_addr: 0.0.0.0:3478
    private_key_path: ${WORKDIR}/hs/data/derp_private.key
  urls:
    - https://controlplane.tailscale.com/derpmap/default
  paths: []
  auto_update_enabled: false
disable_check_updates: true
node:
  expiry: 720h
database:
  type: sqlite
  sqlite:
    path: ${WORKDIR}/hs/data/db.sqlite
tls_cert_path: ""
tls_key_path: ""
log:
  level: info
  format: text
policy:
  mode: file
  path: ${WORKDIR}/hs/policy.json
dns:
  magic_dns: false
  override_local_dns: false
  base_domain: nodes.test.internal
  nameservers:
    global: []
    split: {}
unix_socket: ${WORKDIR}/hs/data/headscale.sock
unix_socket_permission: "0770"
EOF

echo "== Starting local headscale =="
nohup "${WORKDIR}/hs/bin/headscale" --config "${WORKDIR}/hs/config.yaml" serve \
  > "${WORKDIR}/hs/headscale.log" 2>&1 &
echo $! > "${WORKDIR}/headscale.pid"

for _ in $(seq 1 20); do
  curl -fsS "http://127.0.0.1:8091/health" >/dev/null 2>&1 && break
  sleep 1
done
curl -fsS "http://127.0.0.1:8091/health" >/dev/null

"${WORKDIR}/hs/bin/headscale" --config "${WORKDIR}/hs/config.yaml" users create provisioner >/dev/null

echo "== Installing provisioning-api dependencies =="
(cd "${REPO_ROOT}/provisioning-api" && npm install --no-audit --no-fund --silent)

echo "== Starting provisioning-api against the local headscale =="
openssl rand -hex 32 > "${WORKDIR}/session-secret"
chmod 600 "${WORKDIR}/session-secret"

export USERS_FILE="${WORKDIR}/users.json"
export BOOTSTRAP_TOKENS_FILE="${WORKDIR}/bootstrap-tokens.json"
export SESSION_SECRET_FILE="${WORKDIR}/session-secret"
export HEADSCALE_URL="https://headscale.tradingnations.cloud"
export PORTAL_BASE_URL="https://provisioning.tradingnations.cloud"
export INSTALL_SCRIPT_PATH="${REPO_ROOT}/eco-node-adopt.sh"
export HEADSCALE_ADOPTION_USER="provisioner"
export HEADSCALE_BIN="${WORKDIR}/hs/bin/headscale"
export HEADSCALE_CONFIG_PATH="${WORKDIR}/hs/config.yaml"
export PORT="8098"
export HOST="127.0.0.1"

node "${REPO_ROOT}/provisioning-api/scripts/create-user.js" smoke-test-user > "${WORKDIR}/create-user.out"
TEMP_PASSWORD="$(grep 'Temporary password' "${WORKDIR}/create-user.out" | sed 's/.*: //')"

nohup node "${REPO_ROOT}/provisioning-api/app.js" > "${WORKDIR}/provisioning-api.log" 2>&1 &
echo $! > "${WORKDIR}/provisioning-api.pid"

BASE="http://127.0.0.1:8098"
for _ in $(seq 1 10); do
  curl -fsS "${BASE}/healthz" >/dev/null 2>&1 && break
  sleep 1
done

echo "== Logging in =="
COOKIE_JAR="${WORKDIR}/cookies.txt"
curl -fsS -c "${COOKIE_JAR}" -H 'Content-Type: application/json' \
  -d "{\"username\":\"smoke-test-user\",\"password\":\"${TEMP_PASSWORD}\"}" \
  "${BASE}/api/auth/login" >/dev/null

echo "== Generating one-time install command =="
BOOTSTRAP="$(curl -fsS -b "${COOKIE_JAR}" -H 'Content-Type: application/json' \
  -d '{"role":"observation","region":"Virgin Islands (U.S.) (VI)"}' \
  "${BASE}/api/bootstrap")"
TOKEN="$(node -e 'console.log(JSON.parse(process.argv[1]).token)' "${BOOTSTRAP}")"
echo "Curl command a node owner would paste:"
node -e 'console.log(JSON.parse(process.argv[1]).curl_command)' "${BOOTSTRAP}"

echo "== Redeeming the token for a real Headscale pre-auth key =="
KEY_RESPONSE="$(curl -fsS -H "Authorization: Bearer ${TOKEN}" -H 'Content-Type: application/json' \
  -d '{"node_role":"observation","node_region_code":"VI"}' \
  "${BASE}/api/key/generate")"
echo "${KEY_RESPONSE}"
node -e 'if (!JSON.parse(process.argv[1]).pre_auth_key) { process.exit(1) }' "${KEY_RESPONSE}"

echo "== Confirming the key exists in headscale =="
"${WORKDIR}/hs/bin/headscale" --config "${WORKDIR}/hs/config.yaml" preauthkeys list

echo "== Confirming the token cannot be replayed =="
REPLAY_STATUS="$(curl -s -o /dev/null -w '%{http_code}' -H "Authorization: Bearer ${TOKEN}" \
  -H 'Content-Type: application/json' -d '{"node_role":"observation","node_region_code":"VI"}' \
  "${BASE}/api/key/generate")"
if [[ "${REPLAY_STATUS}" != "401" ]]; then
  echo "FAIL: replayed bootstrap token returned ${REPLAY_STATUS}, expected 401" >&2
  exit 1
fi

echo ""
echo "Local provisioning smoke test PASSED."
