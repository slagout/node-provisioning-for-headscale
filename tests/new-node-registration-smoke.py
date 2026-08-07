#!/usr/bin/env python3
"""Registration API smoke test for adding a new node.

This test always performs unauthenticated reachability checks.
If REGISTRATION_API_TOKEN is provided, it also attempts an authenticated
new-node registration and verifies the signed receipt shape.
"""

from __future__ import annotations

import json
import os
import ssl
import time
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass
from typing import Optional


TIMEOUT_SECONDS = float(os.getenv("SMOKE_TIMEOUT_SECONDS", "15"))


@dataclass
class HttpResult:
    status: Optional[int]
    body: str
    error: Optional[str]


def http_json(url: str, method: str = "GET", payload: dict | None = None, headers: dict | None = None) -> HttpResult:
    data = None
    if payload is not None:
        data = json.dumps(payload).encode("utf-8")

    request = urllib.request.Request(url=url, method=method, data=data)
    if payload is not None:
        request.add_header("Content-Type", "application/json")
    for key, value in (headers or {}).items():
        request.add_header(key, value)

    try:
        with urllib.request.urlopen(request, timeout=TIMEOUT_SECONDS, context=ssl.create_default_context()) as response:
            return HttpResult(response.getcode(), response.read(4096).decode("utf-8", errors="replace"), None)
    except urllib.error.HTTPError as error:
        body = error.read(4096).decode("utf-8", errors="replace")
        return HttpResult(error.code, body, None)
    except Exception as error:  # pragma: no cover - network/runtime variability
        return HttpResult(None, "", str(error))


def join_url(base: str, path: str) -> str:
    return urllib.parse.urljoin(base.rstrip("/") + "/", path.lstrip("/"))


def parse_json_maybe(text: str) -> dict | list | None:
    try:
        return json.loads(text)
    except Exception:
        return None


def main() -> int:
    registration_url = os.getenv("REGISTRATION_API_URL", "https://register.tradingnations.cloud")
    token = os.getenv("REGISTRATION_API_TOKEN", "")

    print("New node registration smoke test")
    print(f"REGISTRATION_API_URL={registration_url}")
    print("")

    failures: list[str] = []

    health = http_json(join_url(registration_url, "/healthz"))
    print(f"healthz status={health.status} error={health.error or '-'}")
    if health.status not in {200, 403}:
        failures.append(f"Unexpected /healthz status: {health.status}, error={health.error}")

    pubkey = http_json(join_url(registration_url, "/api/public-key"))
    print(f"public-key status={pubkey.status} error={pubkey.error or '-'}")
    if pubkey.status not in {200, 403}:
        failures.append(f"Unexpected /api/public-key status: {pubkey.status}, error={pubkey.error}")

    unauth_payload = {
        "node_name": "observation-vi-smoke-unauth",
        "region": "Virgin Islands (U.S.) (VI)",
        "datacenter": "hq",
        "role": "observation",
        "vogon_id": "b58:123456789ABCDEFGHJKLMNPQ",
    }
    unauth = http_json(join_url(registration_url, "/api/register-node"), method="POST", payload=unauth_payload)
    print(f"register-unauth status={unauth.status} error={unauth.error or '-'}")
    if unauth.status not in {401, 403}:
        failures.append(f"Unexpected unauth /api/register-node status: {unauth.status}, error={unauth.error}")

    if token:
        ts = int(time.time())
        auth_payload = {
            "node_name": f"observation-vi-smoke-{ts}",
            "region": "Virgin Islands (U.S.) (VI)",
            "datacenter": "hq",
            "role": "observation",
            "vogon_id": "b58:123456789ABCDEFGHJKLMNPQ",
        }
        auth_headers = {"Authorization": f"Bearer {token}"}
        auth = http_json(join_url(registration_url, "/api/register-node"), method="POST", payload=auth_payload, headers=auth_headers)
        print(f"register-auth status={auth.status} error={auth.error or '-'}")

        if auth.status != 200:
            failures.append(f"Authenticated register-node failed with status={auth.status}, error={auth.error}")
        else:
            body_json = parse_json_maybe(auth.body)
            if not isinstance(body_json, dict):
                failures.append("Authenticated register-node response is not valid JSON object")
            else:
                for key in ["success", "hash", "signature", "public_key_fingerprint", "canonical", "node_name"]:
                    if key not in body_json:
                        failures.append(f"Authenticated register-node response missing key: {key}")
    else:
        print("REGISTRATION_API_TOKEN not set, skipping authenticated new-node registration step.")

    print("")
    if failures:
        print("New node smoke test FAILED")
        for failure in failures:
            print(f"- {failure}")
        return 1

    print("New node smoke test PASSED")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
