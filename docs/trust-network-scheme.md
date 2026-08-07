# EcoSynQ Trust Network Scheme

This network is an evidence and causality fabric, not a general-purpose VPN.

## Core Controls

- Deny all unlisted communication.
- Allow only explicit role-to-role ports through Headscale Grants.
- Assign exactly one canonical role tag with a role-tagged pre-auth key.
- Record policy, identity, binary, and receipt hashes with each evidence epoch.
- Treat storage and projections as custodians, not independent witnesses.

## Governed Roles

- `observation`
- `causal-inference`
- `independent-validation`
- `regional-qsa`
- `quantumvm`
- `q-topology`
- `surrealdb-projection`
- `immudb-evidence-authority`
- `checkout-registry`

The same spelling is used by adoption scripts, Headscale tags, Ansible, and the
registration API. The effective Headscale tag, not a local label, is the network
authorization identity.

## Headscale Evidence Boundary

Headscale can establish:

- Which WireGuard identity was registered.
- Which role tag and policy were effective.
- Which network path and port were authorized.
- When enrollment or policy state changed in Headscale logs.

Headscale and DERP cannot prove application payload meaning or correctness.
DERP blindly relays encrypted packets and provides no causal telemetry.

Each application observation therefore also needs:

- Source and receiver node IDs.
- Monotonic sequence and event time.
- Payload and parent hashes.
- Binary and policy-version hashes.
- Replay and duplicate detection.
- Source signature and receiver custody receipt.

## Enforcement Workflow

1. Issue a one-use, one-hour pre-auth key bound to one canonical role tag.
2. Generate or reuse the persisted STTS node identity.
3. Enroll with DNS, routes, and exit-node behavior disabled.
4. Verify the node is online and the expected Headscale role tag is effective.
5. Atomically persist local identity and executable hashes.
6. Register an Ed25519-signed external receipt.
7. Probe allowed paths and confirm representative denied paths fail.
8. Record policy changes as separately signed change events.

## Policy Deployment

`policies/node-role-policy.json` is a Headscale-compatible policy containing
`tagOwners`, explicit `grants`, and an empty `ssh` list. Headscale must be
configured with:

```yaml
policy:
  mode: file
  path: /etc/headscale/policy.json
```

An omitted policy or a policy without `grants` or `acls` permits broad traffic.
Use `scripts/install-headscale-hardening.sh` to validate and install the policy.

## DERP Boundary

Cloudflare Tunnel may front Headscale but not DERP. A sovereign DERP requires
direct public TCP 80/443, UDP 3478, ICMP, and client verification. Keep resilient
fallback relays until multiple directly reachable custom regions pass sustained
external probes.
