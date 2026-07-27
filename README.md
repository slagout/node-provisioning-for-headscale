# Node Provisioning for Headscale

Portable Ubuntu 24.04 bootstrap for registering Tailscale clients against a Headscale control server using a UTC timestamp-based node naming scheme.

## Contents

- `install_headscale_node.sh`: Single-node bootstrap script
- `ansible/site.yml`: Fleet automation playbook

## Naming Scheme

- Human stamp: `DDHHMMSS.mmmZ MON YYYY`
- Hostname-safe stamp: `node-ddhhmmssmmmz-mon-yyyy`
- Example: `node-27180650092z-jul-2026`

## Script Usage

Set required variables and run as root:

```bash
export HEADSCALE_SERVER_URL="https://headscale.example.local"
export HEADSCALE_PRE_AUTH_KEY="tskey-auth-..."
sudo -E bash ./install_headscale_node.sh
```

## Ansible Variables

Define at inventory/group_vars level:

```yaml
headscale_server_url: "https://headscale.example.local"
headscale_pre_auth_key: "tskey-auth-..."
```

## Security Notes

- Keep pre-auth keys out of source control.
- Prefer short-lived keys and rotation.
- Restrict audit file permissions under `/var/lib/ecosynq`.
