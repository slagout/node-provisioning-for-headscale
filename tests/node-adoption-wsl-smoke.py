#!/usr/bin/env python3
"""WSL smoke checks for node adoption dependencies and public reachability."""

from __future__ import annotations

import json
import os
import ssl
import sys
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass
from typing import Optional


DEFAULT_TIMEOUT = float(os.getenv("SMOKE_TIMEOUT_SECONDS", "10"))


@dataclass
class CheckResult:
    name: str
    url: str
    method: str
    ok: bool
    status: Optional[int]
    detail: str


def request_url(name: str, url: str, method: str = "GET", data: bytes | None = None, headers: dict | None = None) -> CheckResult:
    req = urllib.request.Request(url=url, method=method, data=data)
    for key, value in (headers or {}).items():
        req.add_header(key, value)

    try:
        with urllib.request.urlopen(req, timeout=DEFAULT_TIMEOUT, context=ssl.create_default_context()) as resp:
            status = resp.getcode()
            body = resp.read(512).decode("utf-8", errors="replace")
            return CheckResult(name=name, url=url, method=method, ok=True, status=status, detail=body.strip())
    except urllib.error.HTTPError as exc:
        body = exc.read(512).decode("utf-8", errors="replace")
        return CheckResult(name=name, url=url, method=method, ok=True, status=exc.code, detail=body.strip())
    except Exception as exc:
        return CheckResult(name=name, url=url, method=method, ok=False, status=None, detail=str(exc))


def join_url(base: str, path: str) -> str:
    return urllib.parse.urljoin(base.rstrip("/") + "/", path.lstrip("/"))


def main() -> int:
    headscale_url = os.getenv("HEADSCALE_URL", "https://headscale.tradingnations.cloud")
    registration_api_url = os.getenv("REGISTRATION_API_URL", "https://register.tradingnations.cloud")
    provisioning_api_url = os.getenv("PROVISIONING_API_URL", "https://provisioning.tradingnations.cloud")
    provisioning_api_key_path = os.getenv("PROVISIONING_API_KEY_PATH", "/api/key/generate")

    checks: list[CheckResult] = []

    # Cloudflare Access can gate endpoints with 403 while still proving public reachability.
    checks.append(request_url("headscale-health", join_url(headscale_url, "/health"), method="GET"))
    checks.append(request_url("registration-healthz", join_url(registration_api_url, "/healthz"), method="GET"))
    checks.append(request_url("registration-public-key", join_url(registration_api_url, "/api/public-key"), method="GET"))
    checks.append(
        request_url(
            "registration-register-node-unauth",
            join_url(registration_api_url, "/api/register-node"),
            method="POST",
            data=json.dumps({"node_name": "smoke-test-node"}).encode("utf-8"),
            headers={"Content-Type": "application/json"},
        )
    )
    checks.append(
        request_url(
            "provisioning-health",
            join_url(provisioning_api_url, "/health"),
            method="GET",
        )
    )
    checks.append(
        request_url(
            "provisioning-generate-key-unauth",
            join_url(provisioning_api_url, provisioning_api_key_path),
            method="POST",
            data=json.dumps({"node_role": "observation", "node_region_code": "VI"}).encode("utf-8"),
            headers={"Content-Type": "application/json"},
        )
    )

    expected = {
        "headscale-health": {200, 403},
        "registration-healthz": {200, 403},
        "registration-public-key": {200, 403},
        "registration-register-node-unauth": {401, 403},
        "provisioning-health": {200, 403},
        "provisioning-generate-key-unauth": {401, 403, 404, 405},
    }

    failures: list[str] = []

    print("Node adoption WSL smoke test")
    print(f"HEADSCALE_URL={headscale_url}")
    print(f"REGISTRATION_API_URL={registration_api_url}")
    print(f"PROVISIONING_API_URL={provisioning_api_url}")
    print("")

    for result in checks:
        status_text = "n/a" if result.status is None else str(result.status)
        print(f"[{ 'OK' if result.ok else 'FAIL' }] {result.name} {result.method} {result.url} -> {status_text}")

        if not result.ok:
            failures.append(f"{result.name}: unreachable ({result.detail})")
            continue

        if result.name in expected and result.status not in expected[result.name]:
            failures.append(
                f"{result.name}: unexpected HTTP status {result.status}, expected one of {sorted(expected[result.name])}"
            )

    print("")
    if failures:
        print("Smoke test FAILED")
        for item in failures:
            print(f"- {item}")
        return 1

    print("Smoke test PASSED")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
