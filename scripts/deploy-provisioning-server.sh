#!/usr/bin/env bash
#
# EcoSynQ Provisioning Server Deployment
#
# Run this AS ROOT on the provisioning host. It pulls this repo, deploys the
# registration-api and provisioning-api services, provisions their secrets,
# installs the systemd units, and starts both services.
#
# Interactive by default (prompts with sensible defaults); fully unattended
# if every variable below is already exported, or when stdin is not a TTY.
#
# Usage:
#   sudo bash scripts/deploy-provisioning-server.sh
#   sudo REPO_REF=v1.4.0 bash scripts/deploy-provisioning-server.sh

set -euo pipefail

if [[ "$(id -u)" -ne 0 ]]; then
  echo "ERROR: run this script as root" >&2
  exit 1
fi

for command_name in git node npm systemctl openssl install curl rsync; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo "ERROR: required command not found: $command_name" >&2
    exit 1
  fi
done

prompt_with_default() {
  local var_name="$1" question="$2" default_value="$3"
  local current="${!var_name:-}"
  if [[ -n "$current" ]]; then
    return 0
  fi
  if [[ -t 0 ]]; then
    local answer
    read -rp "${question} [${default_value}]: " answer
    printf -v "$var_name" '%s' "${answer:-$default_value}"
  else
    printf -v "$var_name" '%s' "$default_value"
  fi
}

prompt_with_default REPO_URL "Repository to deploy" "https://github.com/slagout/node-provisioning-for-headscale.git"
prompt_with_default REPO_REF "Branch or tag to deploy" "main"
prompt_with_default HEADSCALE_URL "Public Headscale control URL" "https://headscale.tradingnations.cloud"
prompt_with_default PORTAL_BASE_URL "Public URL of this provisioning portal" "https://provisioning.tradingnations.cloud"
prompt_with_default HEADSCALE_ADOPTION_USER "Headscale user that owns adopted node tags" "provisioner"

readonly SRC_DIR="/opt/ecosynq-src"
readonly REGISTRATION_DIR="/opt/ecosynq-registration-api"
readonly PROVISIONING_DIR="/opt/ecosynq-provisioning-api"
readonly SECRETS_DIR="/etc/ecosynq"

echo "== Fetching ${REPO_URL} @ ${REPO_REF} =="
if [[ -d "${SRC_DIR}/.git" ]]; then
  git -C "$SRC_DIR" fetch --depth 1 origin "$REPO_REF"
  git -C "$SRC_DIR" checkout --force FETCH_HEAD
else
  rm -rf "$SRC_DIR"
  git clone --depth 1 --branch "$REPO_REF" "$REPO_URL" "$SRC_DIR"
fi

deploy_app() {
  local source_subdir="$1" target_dir="$2"
  echo "== Deploying ${source_subdir} to ${target_dir} =="
  install -d -m 0755 "$target_dir"
  rsync -a --delete --exclude 'node_modules' --exclude '.git' \
    "${SRC_DIR}/${source_subdir}/" "${target_dir}/"
  (cd "$target_dir" && npm ci --omit=dev --ignore-scripts --no-audit --no-fund)
}

deploy_app "registration-api" "$REGISTRATION_DIR"
deploy_app "provisioning-api" "$PROVISIONING_DIR"

echo "== Bundling eco-node-adopt.sh with the provisioning API (curl | bash target) =="
install -m 0755 "${SRC_DIR}/eco-node-adopt.sh" "${PROVISIONING_DIR}/eco-node-adopt.sh"

echo "== Provisioning secrets (existing secrets are left untouched) =="
install -d -m 0700 "$SECRETS_DIR" /var/lib/ecosynq

if [[ ! -e "${SECRETS_DIR}/registration-api-token" ]]; then
  install -m 0600 /dev/null "${SECRETS_DIR}/registration-api-token"
  openssl rand -hex 32 > "${SECRETS_DIR}/registration-api-token"
  chmod 0400 "${SECRETS_DIR}/registration-api-token"
  echo "Created ${SECRETS_DIR}/registration-api-token"
fi

if [[ ! -e "${SECRETS_DIR}/registration-signing-key.pem" ]]; then
  openssl genpkey -algorithm Ed25519 -out "${SECRETS_DIR}/registration-signing-key.pem"
  chmod 0400 "${SECRETS_DIR}/registration-signing-key.pem"
  echo "Created ${SECRETS_DIR}/registration-signing-key.pem"
fi

if [[ ! -e "${SECRETS_DIR}/provisioning-session-secret" ]]; then
  install -m 0600 /dev/null "${SECRETS_DIR}/provisioning-session-secret"
  openssl rand -hex 32 > "${SECRETS_DIR}/provisioning-session-secret"
  chmod 0400 "${SECRETS_DIR}/provisioning-session-secret"
  echo "Created ${SECRETS_DIR}/provisioning-session-secret"
fi

if [[ ! -e "${SECRETS_DIR}/provisioning-api.env" ]]; then
  cat > "${SECRETS_DIR}/provisioning-api.env" <<'EOF'
# Filled in after running scripts/deploy-headscale-server.sh on the Headscale
# control-plane host. Restart ecosynq-provisioning-api after editing this file.
#HEADSCALE_CLI_ADDRESS=headscale.internal:50443
#HEADSCALE_CLI_API_KEY=
EOF
  chmod 0600 "${SECRETS_DIR}/provisioning-api.env"
  echo "Created ${SECRETS_DIR}/provisioning-api.env (placeholder, needs Headscale API key)"
fi

echo "== Installing systemd units =="
install -m 0644 "${REGISTRATION_DIR}/ecosynq-registration-api.service" \
  /etc/systemd/system/ecosynq-registration-api.service
install -m 0644 "${PROVISIONING_DIR}/ecosynq-provisioning-api.service" \
  /etc/systemd/system/ecosynq-provisioning-api.service

install -d -m 0755 /etc/systemd/system/ecosynq-provisioning-api.service.d
cat > /etc/systemd/system/ecosynq-provisioning-api.service.d/override.conf <<EOF
[Service]
Environment=HEADSCALE_URL=${HEADSCALE_URL}
Environment=PORTAL_BASE_URL=${PORTAL_BASE_URL}
Environment=HEADSCALE_ADOPTION_USER=${HEADSCALE_ADOPTION_USER}
EOF

systemctl daemon-reload
systemctl enable --now ecosynq-registration-api
systemctl enable --now ecosynq-provisioning-api

echo "== Waiting for services to report healthy =="
for service_port in 3000 8080; do
  for _ in $(seq 1 15); do
    curl -fsS "http://127.0.0.1:${service_port}/healthz" >/dev/null 2>&1 && break
    sleep 1
  done
  if ! curl -fsS "http://127.0.0.1:${service_port}/healthz" >/dev/null 2>&1; then
    echo "ERROR: service on port ${service_port} did not become healthy; check:" >&2
    echo "  journalctl -u ecosynq-registration-api -u ecosynq-provisioning-api --since '5 minutes ago'" >&2
    exit 1
  fi
done

echo ""
echo "== Provisioning server deployment complete =="
echo "Next steps:"
echo "1. On the Headscale control-plane host, run scripts/deploy-headscale-server.sh"
echo "   and copy the printed HEADSCALE_CLI_ADDRESS / HEADSCALE_CLI_API_KEY into:"
echo "     ${SECRETS_DIR}/provisioning-api.env"
echo "   then: systemctl restart ecosynq-provisioning-api"
echo "   and verify: curl -fsS http://127.0.0.1:8080/readyz"
echo "2. Create the first node-owner login:"
echo "     cd ${PROVISIONING_DIR} && USERS_FILE=/var/lib/ecosynq/provisioning-users.json \\"
echo "       node scripts/create-user.js <username> --expires-in-hours 24"
echo "3. Point Cloudflare Tunnel at http://127.0.0.1:3000 (registration) and"
echo "   http://127.0.0.1:8080 (provisioning), per README.md."
