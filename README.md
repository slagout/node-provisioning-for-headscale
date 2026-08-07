# EcoSynQ Node Provisioning for Headscale

Role-governed Ubuntu node adoption for a Headscale 0.29.3 evidence network.
Headscale supplies identity and least-privilege connectivity; application-level
signatures and receipts establish evidence provenance.

## Security Invariants

- Headscale policy is deny-by-default through explicit Grants.
- Every service node has exactly one canonical role tag.
- Pre-auth keys are one-use, short-lived, and role-tagged by the issuer.
- Nodes reject DNS, subnet routes, and exit-node behavior by default.
- Reenrollment and role changes require explicit operator approval.
- DERP is an encrypted connectivity fallback, not an evidence observer.
- Role workloads are deployed separately and expose only required ports.

Canonical roles:

- `observation`
- `causal-inference`
- `independent-validation`
- `regional-qsa`
- `quantumvm`
- `q-topology`
- `surrealdb-projection`
- `immudb-evidence-authority`
- `checkout-registry`

## Repository Layout

- `eco-node-adopt.sh`: hardened role-aware node adoption.
- `headscale/config.yaml`: Headscale 0.29.3 server baseline.
- `policies/node-role-policy.json`: enforceable Headscale Grants policy.
- `scripts/install-headscale-hardening.sh`: transactional server config installer.
- `scripts/local-provisioning-smoke.sh`: self-contained local test of the whole login-to-adoption flow.
- `ansible/site.yml`: fleet enrollment with role-tag verification.
- `provisioning-api/`: login-gated portal that issues one-time node install commands.
- `registration-api/`: authenticated registry with Ed25519 receipts.
- `docs/derp-hardening.md`: DERP constraints and verification.
- `docs/trust-network-scheme.md`: evidence-network trust model.

## Headscale Server Hardening

The supplied policy grants tag ownership to `provisioner@`. Create that
Headscale user or replace it with the actual provisioning identity:

```bash
sudo headscale users create provisioner
```

Review `server_url`, `trusted_proxies`, `dns.base_domain`, and DERP settings in
`headscale/config.yaml`, then install the config and policy transactionally:

```bash
sudo bash scripts/install-headscale-hardening.sh
```

The installer backs up current files, runs `headscale configtest`, restarts the
service, checks health, and restores previous files on failure.

```bash
sudo headscale --config /etc/headscale/config.yaml configtest
sudo journalctl -u headscale --since '5 minutes ago'
sudo headscale nodes list
```

## DERP and Cloudflare

Cloudflare Tunnel can front the Headscale control endpoint and registration API.
It must not front a custom DERP server. DERP requires direct public ingress,
original client source addresses, TCP 80/443, UDP 3478, and ICMP.

The default baseline leaves embedded DERP disabled and retains the public DERP
map for resilient fallback. Only enable sovereign DERP after direct DNS-only
ingress is available and external probes pass. See `docs/derp-hardening.md`.

`cloudflare/config.yml.example` tunnels only the Headscale control endpoint and
registration API to their loopback listeners. Validate and test it before
installing the service:

```bash
sudo cloudflared tunnel ingress validate
sudo cloudflared tunnel ingress rule https://headscale.tradingnations.cloud
sudo cloudflared tunnel ingress rule https://register.tradingnations.cloud
```

Do not place an interactive Cloudflare Access policy in front of the Headscale
control hostname because machine clients cannot complete that challenge. Apply
Access to the registration hostname, and keep its bearer authentication enabled.
WebSocket/HTTP upgrade traffic must remain allowed for Headscale. Do not add a
DERP hostname to this tunnel.

## Simplified Rollout: Provisioning Portal

For day-to-day node onboarding, a node owner does not need to know Headscale
concepts, pre-auth keys, or CLI flags. The `provisioning-api` app is a small,
login-gated portal that turns adoption into three steps:

1. The node owner signs in at the portal with an admin-issued username and
   temporary password.
2. They pick the node's region and role from two dropdowns and click
   **Generate Install Command**.
3. They paste the resulting one-line `curl | sudo env ... bash` command into
   their Ubuntu Server node. Everything after that (dependency install,
   Headscale enrollment, verification) proceeds automatically via the
   existing `eco-node-adopt.sh` script, unchanged.

The generated command is single-use and expires quickly. The portal issues a
short-lived bootstrap token (not a shared, long-lived secret) that is bound to
the chosen role/region and is consumed the first time `eco-node-adopt.sh` calls
back to `POST /api/key/generate` &mdash; the exact `PROVISIONING_API_URL` /
`PROVISIONING_API_TOKEN` contract the script already supports. On redemption,
the portal shells out to the `headscale` CLI to mint a real, non-reusable,
3600-second pre-auth key tagged with the chosen role, so Headscale remains the
source of truth for adoption and tag ownership.

Admin setup:

```bash
sudo install -d -m 0700 /etc/ecosynq /var/lib/ecosynq
sudo sh -c 'openssl rand -hex 32 > /etc/ecosynq/provisioning-session-secret'
sudo chmod 0400 /etc/ecosynq/provisioning-session-secret

cd /opt/ecosynq-provisioning-api
npm ci --omit=dev --ignore-scripts --no-audit --no-fund
USERS_FILE=/var/lib/ecosynq/provisioning-users.json \
  node scripts/create-user.js <node-owner-username> --expires-in-hours 24

sudo install -m 0644 ecosynq-provisioning-api.service \
  /etc/systemd/system/ecosynq-provisioning-api.service
sudo systemctl daemon-reload
sudo systemctl enable --now ecosynq-provisioning-api
```

The portal calls the local `headscale` binary, so the provisioning host needs
the remote-CLI setup described in [Headscale's gRPC API
docs](https://headscale.net/stable/ref/api/#grpc): an API key from
`headscale apikeys create` and `HEADSCALE_CLI_ADDRESS` /
`HEADSCALE_CLI_API_KEY` set in `/etc/ecosynq/provisioning-api.env` (referenced
by the systemd unit), reaching the control-plane host's gRPC port. `GET
/readyz` reports whether that path is currently working.

Test the whole flow locally, with no production servers and no sudo, using a
real throwaway Headscale instance:

```bash
bash scripts/local-provisioning-smoke.sh
```

## Node Adoption

Use a root-readable secret file instead of placing a pre-auth key in shell
history:

```bash
sudo install -m 0600 /dev/null /run/ecosynq-preauth-key
sudoedit /run/ecosynq-preauth-key

sudo env \
  HEADSCALE_URL="https://headscale.tradingnations.cloud" \
  PRE_AUTH_KEY_FILE="/run/ecosynq-preauth-key" \
  NODE_ROLE="observation" \
  NODE_REGION="Virgin Islands (U.S.) (VI)" \
  NODE_REGION_CODE="VI" \
  NODE_DATACENTER="hq" \
  bash ./eco-node-adopt.sh
```

For an external provisioning service:

```bash
sudo install -m 0600 /dev/null /run/ecosynq-provisioning-token
sudoedit /run/ecosynq-provisioning-token

sudo env \
  HEADSCALE_URL="https://headscale.tradingnations.cloud" \
  PROVISIONING_API_URL="https://provisioning.tradingnations.cloud" \
  PROVISIONING_API_TOKEN_FILE="/run/ecosynq-provisioning-token" \
  NODE_ROLE="observation" \
  NODE_REGION="Virgin Islands (U.S.) (VI)" \
  NODE_REGION_CODE="VI" \
  bash ./eco-node-adopt.sh
```

The default provisioning endpoint is `POST /api/key/generate`. It receives the
role, region, datacenter, `reusable: false`, and `expiration_seconds: 3600`, and
must return a nonempty `pre_auth_key` or `auth_key`. Override only the URL path
with `PROVISIONING_API_KEY_PATH`.

Interactive selection reads from `/dev/tty`, so it works when the script itself
is streamed. Downloading and reviewing a pinned revision before execution is
still preferred over executing mutable remote content.

An existing matching identity is reused. The script refuses silent identity or
role replacement. `ALLOW_REENROLL=true` is a break-glass control and must be
used only after decommission approval.

## Ansible Enrollment

Define these values in encrypted inventory or Ansible Vault:

```yaml
headscale_server_url: "https://headscale.tradingnations.cloud"
headscale_pre_auth_key: "one-use-role-tagged-key"
ecosynq_node_name: "observation-vi-06143000z082026-a1b2"
ecosynq_node_role: "observation"
```

The playbook suppresses secret-bearing task output and fails unless the expected
role tag is effective after enrollment.

## Registration API

The API binds to `127.0.0.1:3000`, requires a bearer token for protected API
operations, limits body size and request rate, validates canonical roles, and
persists version 2.0 records atomically with mode `0600`. Every receipt is signed
with Ed25519 and verified at startup.

Generate credentials without printing them:

```bash
sudo install -d -m 0700 /etc/ecosynq
sudo sh -c 'openssl rand -hex 32 > /etc/ecosynq/registration-api-token'
sudo openssl genpkey -algorithm Ed25519 \
  -out /etc/ecosynq/registration-signing-key.pem
sudo chmod 0400 \
  /etc/ecosynq/registration-api-token \
  /etc/ecosynq/registration-signing-key.pem
```

Deploy the API to `/opt/ecosynq-registration-api`, install production
dependencies under Node.js 22 from the lockfile with lifecycle scripts disabled,
and install the sandboxed unit:

```bash
cd /opt/ecosynq-registration-api
npm ci --omit=dev --ignore-scripts --no-audit --no-fund
sudo install -m 0644 ecosynq-registration-api.service \
  /etc/systemd/system/ecosynq-registration-api.service
sudo systemctl daemon-reload
sudo systemctl enable --now ecosynq-registration-api
```

Place Cloudflare Access in front of the tunnel in addition to the bearer token.
Tunnel only to `http://127.0.0.1:3000`.

Endpoints:

- `GET /healthz`: unauthenticated liveness only.
- `GET /api/public-key`: Ed25519 verification key and fingerprint.
- `POST /api/register-node`: authenticated registration.
- `GET /api/node/:node_name`: authenticated receipt lookup.
- `GET /api/nodes`: authenticated sanitized inventory.

Version 1.0 registry files are intentionally rejected because their hashes were
not independently verifiable. Archive them and re-register through version 2.0.

## Role Workloads

Node adoption no longer deploys generic immuDB, PostgreSQL, or Redis containers.
That behavior exposed every database on every role and used placeholder
credentials. Deploy each role workload separately with pinned image digests,
read-only filesystems where possible, systemd supervision, secret files, and
host bindings restricted to the node's Tailscale address.

## Local Validation

```bash
bash scripts/validate-hardening.sh

cd registration-api
npm ci --ignore-scripts --no-audit --no-fund
npm audit --omit=dev --audit-level=moderate
npm test

cd ../provisioning-api
npm ci --ignore-scripts --no-audit --no-fund
npm audit --omit=dev --audit-level=moderate
npm test
```
