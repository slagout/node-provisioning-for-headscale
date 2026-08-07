#!/usr/bin/env bash
#
# EcoSynQ Headscale Server Deployment
#
# Run this AS ROOT on the Headscale control-plane host. It pulls this repo,
# applies the hardened Headscale config/policy, ensures the provisioner user
# exists, and issues a remote-CLI API key for the provisioning host.
#
# Assumes Headscale itself is already installed (apt/deb) and its systemd
# service and system group exist; this script applies this repo's config, it
# does not install Headscale.
#
# Usage:
#   sudo bash scripts/deploy-headscale-server.sh
#   sudo REPO_REF=v1.4.0 bash scripts/deploy-headscale-server.sh

set -euo pipefail

if [[ "$(id -u)" -ne 0 ]]; then
  echo "ERROR: run this script as root" >&2
  exit 1
fi

for command_name in git headscale systemctl jq curl; do
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
prompt_with_default HEADSCALE_ADOPTION_USER "Headscale user that owns adopted node tags" "provisioner"

readonly SRC_DIR="/opt/ecosynq-src"

echo "== Fetching ${REPO_URL} @ ${REPO_REF} =="
if [[ -d "${SRC_DIR}/.git" ]]; then
  git -C "$SRC_DIR" fetch --depth 1 origin "$REPO_REF"
  git -C "$SRC_DIR" checkout --force FETCH_HEAD
else
  rm -rf "$SRC_DIR"
  git clone --depth 1 --branch "$REPO_REF" "$REPO_URL" "$SRC_DIR"
fi

echo "== Applying hardened Headscale config and policy =="
bash "${SRC_DIR}/scripts/install-headscale-hardening.sh"

echo "== Ensuring the '${HEADSCALE_ADOPTION_USER}' Headscale user exists =="
existing_users="$(headscale users list --output json)"
if ! jq -e --arg name "$HEADSCALE_ADOPTION_USER" 'any(.[]; .name == $name)' <<<"$existing_users" >/dev/null; then
  headscale users create "$HEADSCALE_ADOPTION_USER"
else
  echo "User '${HEADSCALE_ADOPTION_USER}' already exists."
fi

echo "== Checking for an existing remote-CLI API key =="
existing_keys="$(headscale apikeys list --output json)"
key_count="$(jq 'length' <<<"$existing_keys")"

if [[ "$key_count" -eq 0 || "${FORCE_NEW_API_KEY:-false}" == "true" ]]; then
  echo ""
  echo "Creating a new Headscale API key for remote-CLI access."
  echo "This is shown ONCE. Copy it now; it cannot be retrieved again."
  echo ""
  new_api_key="$(headscale apikeys create)"
  echo "HEADSCALE_CLI_API_KEY=${new_api_key}"
else
  echo "An API key already exists (${key_count} on file). Not creating a new one."
  echo "Set FORCE_NEW_API_KEY=true to rotate."
fi

grpc_listen_addr="$(grep -E '^grpc_listen_addr:' "${SRC_DIR}/headscale/config.yaml" | awk '{print $2}')"

echo ""
echo "== Headscale server deployment complete =="
"$(command -v headscale)" nodes list || true
echo ""
echo "On the provisioning host, set in /etc/ecosynq/provisioning-api.env:"
echo "  HEADSCALE_CLI_ADDRESS=<this-host-reachable-address>:${grpc_listen_addr##*:}"
echo "  HEADSCALE_CLI_API_KEY=<the key printed above, if a new one was created>"
echo "Then: systemctl restart ecosynq-provisioning-api"
echo "Verify from the provisioning host: curl -fsS http://127.0.0.1:8080/readyz"
