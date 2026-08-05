# Node Provisioning for Headscale

Ubuntu bootstrap for registering sovereign edge nodes with Headscale (via Tailscale), Ubuntu Landscape, and Podman-based EcoSynQ runtime services.

## Contents

- `eco-headscale-landscape-install.sh`: Main installer with STTS naming, Podman deployment, and Landscape registration
- `eco-node-adopt.sh`: Minimal role-aware Headscale node adoption script with identity file output
- `install_headscale_node.sh`: Legacy single-node bootstrap script
- `ansible/site.yml`: Fleet automation playbook
- `registration-api/app.js`: Node registration API service for VOGON wallet binding
- `registration-api/public/index.html`: Registration portal page for `register.tradingnations.cloud`
- `scripts/generate-batch-qr-codes.sh`: Batch QR generation from node CSV

## STTS Canonical Naming

Installer-generated node names include Spatial, Temporal, Thematic, and Semantic elements:

- Format: `node-<role>-<region>-<ddhhmmmmm>-<sequencer>-<mm>-<yyyy>`
- Example: `node-witness-usvi-27180650092-9f3a2b1c-50-2026`

## Installer Usage

Run directly from the repository:

```bash
sudo bash ./eco-headscale-landscape-install.sh
```

Run register-only mode (generate QR payload URL and pending registration record):

```bash
sudo bash ./eco-headscale-landscape-install.sh register
```

Run with dry-run preview (no system changes):

```bash
sudo bash ./eco-headscale-landscape-install.sh --dry-run
```

Run safe uninstall mode (removes EcoSynQ containers/network and local audit record only):

```bash
sudo bash ./eco-headscale-landscape-install.sh --uninstall
```

One-liner from GitHub raw:

```bash
curl -fsSL https://raw.githubusercontent.com/slagout/node-provisioning-for-headscale/main/eco-headscale-landscape-install.sh | sudo bash
```

Minimal role-aware node adoption:

```bash
curl -fsSL https://raw.githubusercontent.com/slagout/node-provisioning-for-headscale/main/eco-node-adopt.sh \
	| sudo HEADSCALE_URL="https://headscale.tradingnations.cloud" \
				 PRE_AUTH_KEY="hskey_xxxxxxxx" \
				 NODE_ROLE="observation" \
				 NODE_REGION="usvi_atlantic" \
				 NODE_DATACENTER="hq" \
				 bash
```

With deployment variables:

```bash
curl -fsSL https://raw.githubusercontent.com/slagout/node-provisioning-for-headscale/main/eco-headscale-landscape-install.sh \
	| sudo NODE_REGION="usvi" NODE_DATACENTER="charleston" NODE_ROLE="witness" \
		HEADSCALE_URL="https://headscale.tradingnations.cloud" \
		PRE_AUTH_KEY="hskey_xxxxxxxx" \
		LANDSCAPE_SERVER_URL="https://landscape.tradingnations.cloud" \
		LANDSCAPE_PUBLIC_KEY="$(cat /path/to/landscape.pub)" \
		LANDSCAPE_PRIVATE_KEY="$(cat /path/to/landscape.pem)" \
		bash
```

Production deployment with deferred wallet binding:

```bash
curl -fsSL https://raw.githubusercontent.com/slagout/node-provisioning-for-headscale/main/eco-headscale-landscape-install.sh \
	| sudo NODE_REGION="austin_tx_usa" NODE_DATACENTER="hq" NODE_ROLE="witness" \
		HEADSCALE_URL="https://headscale.tradingnations.cloud" \
		PRE_AUTH_KEY="hskey_xxxxxxxx" \
		REGISTRATION_URL="https://register.tradingnations.cloud" \
		bash
```

## Required and Optional Environment Variables

Required:

- `HEADSCALE_URL`: Headscale URL, for example `https://headscale.tradingnations.cloud`
- `PRE_AUTH_KEY`: Headscale pre-auth key

Optional (recommended for Landscape auto-registration):

- `LANDSCAPE_SERVER_URL`: Landscape server URL
- `LANDSCAPE_ACCOUNT_NAME`: Landscape account name
- `LANDSCAPE_PUBLIC_KEY`: Landscape public key content
- `LANDSCAPE_PRIVATE_KEY`: Landscape private key content

Optional STTS metadata:

- `NODE_REGION`: Spatial region code, default `usvi`
- `NODE_DATACENTER`: Spatial facility code, default `charleston`
- `NODE_ROLE`: Semantic role, default `witness`
- `NODE_SEQUENCER`: Thematic sequencer value or `auto`

Registration variables:

- `REGISTRATION_URL`: Registration portal base URL, default `https://register.tradingnations.cloud`
- `VOGON_ID`: Optional wallet identity during deploy. If omitted, binding is deferred.

Cloudflare routing note:

- Ensure the public hostnames are routed through your tunnel to the correct origin services before provisioning:
	- `headscale.tradingnations.cloud` -> `https://headscale.ecosynq.local:8443`
	- `landscape.tradingnations.cloud` -> `https://landscape.ecosynq.local:4443`
	- `register.tradingnations.cloud` -> your registration API origin

## Registration API and Portal

The repository includes a minimal production starter API + portal under `registration-api`.

Run locally:

```bash
cd registration-api
npm install
npm start
```

The service hosts:

- `POST /api/register-node`: Register node-to-wallet binding with idempotent duplicate handling
- `GET /api/node/:node_name`: Verify a specific node binding
- `GET /api/nodes`: List all registered nodes (secure this endpoint in production)
- `/`: Static registration portal page

Default registry location:

- `/var/lib/ecosynq/node-registry.json`

Override with:

```bash
REGISTRY_FILE=/custom/path/node-registry.json npm start
```

## Batch QR Generation

Use `scripts/generate-batch-qr-codes.sh` with a CSV file:

```bash
chmod +x scripts/generate-batch-qr-codes.sh
scripts/generate-batch-qr-codes.sh node-list.csv
```

CSV format:

```csv
region,datacenter,role,node_name
austin_tx_usa,hq,witness,node-witness-austin_tx_usa-27180650092-a1b2c3d4-07-2026
```

## Uninstall Behavior

Safe uninstall mode intentionally preserves:

- Installed packages (`podman`, `tailscale`, `landscape-client`)
- Podman volumes (`immudb-data`, `postgres-data`, `redis-data`)
- Remote registrations (Headscale and Landscape)

It removes:

- Containers `ecosynq-immudb`, `ecosynq-postgres`, `ecosynq-redis`
- Podman network `ecosynq` (if removable)
- Local audit file `/var/lib/ecosynq/node-registration.json`

## Ansible Variables

Define at inventory/group_vars level:

```yaml
headscale_server_url: "https://headscale.example.local"
headscale_pre_auth_key: "tskey-auth-..."
```

## Security Notes

- Keep pre-auth and Landscape key material out of source control.
- Prefer short-lived Headscale pre-auth keys and rotate frequently.
- Keep `/var/lib/ecosynq/node-registration.json` restricted (`0600`).

## Trust Network Scheme

This project includes a simplified operating model for role-governed, evidentially trustworthy networking:

- `docs/trust-network-scheme.md`: concise architecture and adoption workflow
- `policies/node-role-policy.json`: default-deny role communication matrix

Use this model to keep Headscale as a controlled identity and connectivity layer for causal evidence analysis.
