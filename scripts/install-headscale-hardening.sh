#!/usr/bin/env bash
set -euo pipefail

readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
readonly SOURCE_CONFIG="${REPO_ROOT}/headscale/config.yaml"
readonly SOURCE_POLICY="${REPO_ROOT}/policies/node-role-policy.json"
readonly TARGET_DIR="/etc/headscale"
readonly TARGET_CONFIG="${TARGET_DIR}/config.yaml"
readonly TARGET_POLICY="${TARGET_DIR}/policy.json"

if [[ "$(id -u)" -ne 0 ]]; then
  echo "ERROR: run this script as root" >&2
  exit 1
fi

for command_name in headscale jq install systemctl; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo "ERROR: required command not found: $command_name" >&2
    exit 1
  fi
done

if [[ ! -r "$SOURCE_CONFIG" || ! -r "$SOURCE_POLICY" ]]; then
  echo "ERROR: hardened config or policy source is missing" >&2
  exit 1
fi

if ! getent group headscale >/dev/null 2>&1; then
  echo "ERROR: the headscale system group does not exist" >&2
  exit 1
fi

installed_version="$(headscale version 2>/dev/null | head -n 1)"
if [[ "$installed_version" != *"0.29.3"* && "${ALLOW_HEADSCALE_VERSION_MISMATCH:-false}" != "true" ]]; then
  echo "ERROR: this baseline targets Headscale 0.29.3; found: $installed_version" >&2
  echo "Set ALLOW_HEADSCALE_VERSION_MISMATCH=true only after reviewing the target schema." >&2
  exit 1
fi

jq -e '
  (.grants | type == "array") and
  (.tagOwners | type == "object") and
  (.ssh | type == "array" and length == 0) and
  (all(.grants[]; (.src | index("*") | not) and (.dst | index("*") | not) and (.ip | index("*") | not)))
' "$SOURCE_POLICY" >/dev/null

backup_dir="$(mktemp -d "${TMPDIR:-/tmp}/headscale-hardening.XXXXXX")"
had_config=false
had_policy=false

cleanup() {
  rm -rf "$backup_dir"
}
trap cleanup EXIT

install -d -o root -g headscale -m 0750 "$TARGET_DIR"

if [[ -e "$TARGET_CONFIG" ]]; then
  cp -a "$TARGET_CONFIG" "${backup_dir}/config.yaml"
  had_config=true
fi
if [[ -e "$TARGET_POLICY" ]]; then
  cp -a "$TARGET_POLICY" "${backup_dir}/policy.json"
  had_policy=true
fi

restore_previous() {
  if [[ "$had_config" == true ]]; then
    cp -a "${backup_dir}/config.yaml" "$TARGET_CONFIG"
  else
    rm -f "$TARGET_CONFIG"
  fi

  if [[ "$had_policy" == true ]]; then
    cp -a "${backup_dir}/policy.json" "$TARGET_POLICY"
  else
    rm -f "$TARGET_POLICY"
  fi
}

install -o root -g headscale -m 0640 "$SOURCE_POLICY" "$TARGET_POLICY"
install -o root -g headscale -m 0640 "$SOURCE_CONFIG" "$TARGET_CONFIG"

if ! headscale --config "$TARGET_CONFIG" configtest; then
  echo "ERROR: Headscale rejected the hardened configuration; restoring previous files" >&2
  restore_previous
  exit 1
fi

if ! systemctl restart headscale || ! systemctl is-active --quiet headscale; then
  echo "ERROR: Headscale did not start; restoring previous files" >&2
  restore_previous
  systemctl restart headscale || true
  exit 1
fi

echo "Hardened Headscale configuration installed and service verified."
echo "Inspect policy processing with: journalctl -u headscale --since '5 minutes ago'"