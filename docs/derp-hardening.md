# DERP Hardening

DERP is a connectivity fallback. It relays WireGuard-encrypted packets and
cannot inspect application evidence or establish causal provenance.

## Cloudflare Tunnel Baseline

Keep the embedded DERP disabled when Headscale is reached through Cloudflare
Tunnel. A DERP server requires direct public connectivity and the original
client source address; it cannot sit behind a tunnel, NAT gateway, firewall
proxy, or load balancer.

The default `headscale/config.yaml` therefore:

- Binds Headscale, metrics, and gRPC to loopback.
- Loads the default public DERP map for resilient fallback connectivity.
- Keeps the embedded DERP disabled.
- Enables client verification in case embedded DERP is later enabled.

## Direct Sovereign DERP

Only enable embedded DERP after the Headscale host has a DNS-only hostname and
direct public ingress. The host must permit:

- TCP 80 for connectivity checks.
- TCP 443 for DERP HTTPS traffic.
- UDP 3478 for STUN.
- Inbound and outbound ICMP.

Set public IPv4 and IPv6 addresses in the `derp.server` section, change
`enabled` to `true`, and keep `verify_clients: true`. Do not proxy the DERP
hostname through Cloudflare.

Retain the public DERP URL until at least two directly reachable custom regions
have passed sustained probes. Removing public relays while only one custom
region exists creates a control-plane-independent single point of failure.

## Verification

Run these checks from at least two external node networks:

```bash
tailscale netcheck
tailscale debug derp-map
tailscale debug derp ecosynq
```

For a standalone custom `derper`, monitor its map continuously with
`derpprobe`. Failed verification or probe checks must block removing the public
DERP fallback.

References:

- [DERP servers](https://tailscale.com/docs/reference/derp-servers)
- [Custom DERP servers](https://tailscale.com/docs/reference/derp-servers/custom-derp-servers)
- [Headscale DERP](https://headscale.net/stable/ref/derp/)
