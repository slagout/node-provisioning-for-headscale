# Node Provisioning for Headscale

Ubuntu bootstrap for registering sovereign edge nodes with Headscale (via Tailscale), Ubuntu Landscape, and Podman-based EcoSynQ runtime services.

## Contents

- `eco-headscale-landscape-install.sh`: Main installer with STTS naming, Podman deployment, and Landscape registration
- `install_headscale_node.sh`: Legacy single-node bootstrap script
- `ansible/site.yml`: Fleet automation playbook

## STTS Canonical Naming

Installer-generated node names include Spatial, Temporal, Thematic, and Semantic elements:

- Format: `node-<role>-<region>-<ddhhmmmmm>-<sequencer>-<mm>-<yyyy>`
- Example: `node-witness-usvi-27180650092-9f3a2b1c-50-2026`

## Installer Usage

Run directly from the repository:

```bash
sudo bash ./eco-headscale-landscape-install.sh
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

With deployment variables:

```bash
curl -fsSL https://raw.githubusercontent.com/slagout/node-provisioning-for-headscale/main/eco-headscale-landscape-install.sh \
	| sudo NODE_REGION="usvi" NODE_DATACENTER="charleston" NODE_ROLE="witness" \
		HEADSCALE_URL="https://headscale.ecosynq.local" \
		PRE_AUTH_KEY="hskey_xxxxxxxx" \
		LANDSCAPE_SERVER_URL="https://landscape.ecosynq.local" \
		LANDSCAPE_PUBLIC_KEY="$(cat /path/to/landscape.pub)" \
		LANDSCAPE_PRIVATE_KEY="$(cat /path/to/landscape.pem)" \
		bash
```

## Required and Optional Environment Variables

Required:

- `HEADSCALE_URL`: Headscale URL, for example `https://headscale.ecosynq.local`
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
