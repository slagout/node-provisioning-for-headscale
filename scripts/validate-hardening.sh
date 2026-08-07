#!/usr/bin/env bash
set -euo pipefail

readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"

cd "$REPO_ROOT"

for command_name in bash grep; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo "ERROR: required validation command not found: $command_name" >&2
    exit 1
  fi
done

bash -n eco-node-adopt.sh
bash -n scripts/install-headscale-hardening.sh
bash tests/eco-node-adopt-test.sh

if command -v jq >/dev/null 2>&1; then
  jq -e '
    (.grants | type == "array" and length > 0) and
    (.tagOwners | type == "object" and length == 9) and
    (.ssh | type == "array" and length == 0) and
    (all(.grants[];
      (.src | index("*") | not) and
      (.dst | index("*") | not) and
      (.ip | index("*") | not) and
      (all(.src[]; startswith("tag:"))) and
      (all(.dst[]; startswith("tag:")))
    ))
  ' policies/node-role-policy.json >/dev/null

  while IFS= read -r tag; do
    jq -e --arg tag "$tag" '.tagOwners | has($tag)' policies/node-role-policy.json >/dev/null
  done < <(jq -r '.grants[] | .src[], .dst[]' policies/node-role-policy.json | sort -u)

  jq -e '
    .dependencies == {express: "4.22.2"} and
    .overrides == {"path-to-regexp": "0.1.13"}
  ' registration-api/package.json >/dev/null
else
  python_command="$(command -v python || command -v python3 || true)"
  if [[ -z "$python_command" ]]; then
    echo "ERROR: jq or Python is required for structured JSON validation" >&2
    exit 1
  fi

  "$python_command" - <<'PY'
import json

with open("policies/node-role-policy.json", encoding="utf-8") as policy_file:
    policy = json.load(policy_file)

grants = policy.get("grants")
tag_owners = policy.get("tagOwners")
assert isinstance(grants, list) and grants
assert isinstance(tag_owners, dict) and len(tag_owners) == 9
assert policy.get("ssh") == []

for grant in grants:
    assert "*" not in grant["src"]
    assert "*" not in grant["dst"]
    assert "*" not in grant["ip"]
    assert all(value.startswith("tag:") for value in grant["src"])
    assert all(value.startswith("tag:") for value in grant["dst"])
    assert all(value in tag_owners for value in grant["src"] + grant["dst"])

with open("registration-api/package.json", encoding="utf-8") as package_file:
    package = json.load(package_file)
assert package.get("dependencies") == {"express": "4.22.2"}
assert package.get("overrides") == {"path-to-regexp": "0.1.13"}
PY
fi

grep -Fxq 'listen_addr: 127.0.0.1:8080' headscale/config.yaml
grep -Fxq 'grpc_allow_insecure: false' headscale/config.yaml
grep -Fxq '    enabled: false' headscale/config.yaml
grep -Fxq '    verify_clients: true' headscale/config.yaml
grep -Fxq '  path: /etc/headscale/policy.json' headscale/config.yaml
grep -Fxq '  enabled: false' headscale/config.yaml
grep -Fxq '    service: http://127.0.0.1:8080' cloudflare/config.yml.example
grep -Fxq '    service: http://127.0.0.1:3000' cloudflare/config.yml.example
grep -Fxq '  - service: http_status:404' cloudflare/config.yml.example

if grep -Eqi 'derp' cloudflare/config.yml.example; then
  echo "ERROR: DERP must not be routed through Cloudflare Tunnel" >&2
  exit 1
fi

if grep -Eq -- '--auth-key=|CHANGE_ME_IN_PRODUCTION|podman run|app\.use\(cors\(\)\)' \
  eco-node-adopt.sh registration-api/app.js; then
  echo "ERROR: prohibited hardening pattern found" >&2
  exit 1
fi

for obsolete_file in \
  install_headscale_node.sh \
  eco-headscale-landscape-install.sh \
  eco-node-naming-poc.sh \
  scripts/generate-batch-qr-codes.sh; do
  if [[ -e "$obsolete_file" ]]; then
    echo "ERROR: obsolete enrollment artifact remains: $obsolete_file" >&2
    exit 1
  fi
done

if command -v node >/dev/null 2>&1; then
  node --check registration-api/app.js
fi

echo "Hardening validation passed."