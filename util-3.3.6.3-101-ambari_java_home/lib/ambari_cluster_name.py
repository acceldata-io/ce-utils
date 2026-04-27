#!/usr/bin/env python3.11
"""
GET Ambari /api/v1/clusters and print the sole cluster_name to stdout.

Exit codes:
  0  One cluster; name on stdout only.
  1  No cluster, bad JSON, or unexpected response.
  2  Multiple clusters; comma-separated names on stderr (set CLUSTER=...).
  3  HTTP error from Ambari.
  4  Network / TLS / URL error.
"""
from __future__ import annotations

import argparse
import base64
import json
import ssl
import sys
import urllib.error
import urllib.request

EXIT_OK = 0
EXIT_NO_CLUSTER = 1
EXIT_MULTI = 2
EXIT_HTTP = 3
EXIT_NET = 4


def eprint(*args: object) -> None:
    print(*args, file=sys.stderr)


def hint_http_tls(protocol: str, port: int) -> None:
    if protocol == "http" and port in (443, 8443, 8446, 9443):
        eprint("Hint: this port often uses TLS; use --protocol https (and --insecure if needed).")


def main(argv: list[str]) -> int:
    p = argparse.ArgumentParser(description="Print Ambari cluster_name when exactly one cluster exists.")
    p.add_argument("--host", required=True)
    p.add_argument("--port", type=int, default=8080)
    p.add_argument("--protocol", choices=["http", "https"], default="http")
    p.add_argument("--user", required=True)
    p.add_argument("--password", required=True)
    p.add_argument("--insecure", action="store_true", help="Skip TLS certificate verification (HTTPS).")
    args = p.parse_args(argv)

    url = f"{args.protocol}://{args.host}:{args.port}/api/v1/clusters"
    req = urllib.request.Request(url, method="GET")
    token = base64.b64encode(f"{args.user}:{args.password}".encode()).decode().replace("\n", "")
    req.add_header("Authorization", f"Basic {token}")
    req.add_header("X-Requested-By", "ambari")

    ctx = None
    if args.protocol == "https" and args.insecure:
        ctx = ssl.create_default_context()
        ctx.check_hostname = False
        ctx.verify_mode = ssl.CERT_NONE

    try:
        with urllib.request.urlopen(req, context=ctx, timeout=60) as resp:
            body = resp.read().decode("utf-8", errors="replace")
            status = resp.status
    except urllib.error.HTTPError as exc:
        snippet = exc.read().decode("utf-8", errors="replace")[:500]
        eprint(f"HTTP {exc.code} from {url}: {snippet}")
        hint_http_tls(args.protocol, args.port)
        return EXIT_HTTP
    except urllib.error.URLError as exc:
        eprint(f"Connection error ({url}): {exc.reason!r}")
        hint_http_tls(args.protocol, args.port)
        return EXIT_NET

    if status != 200:
        eprint(f"Unexpected HTTP {status} from {url}")
        eprint(body[:500])
        hint_http_tls(args.protocol, args.port)
        return EXIT_HTTP

    try:
        data = json.loads(body)
    except json.JSONDecodeError as exc:
        eprint(f"Invalid JSON from {url}: {exc}")
        eprint(body[:400])
        hint_http_tls(args.protocol, args.port)
        return EXIT_NO_CLUSTER

    items = data.get("items") or []
    names: list[str] = []
    for item in items:
        cl = item.get("Clusters") or {}
        n = cl.get("cluster_name")
        if n:
            names.append(str(n))

    if not names:
        eprint("No clusters in Ambari response (empty items or missing cluster_name).")
        return EXIT_NO_CLUSTER
    if len(names) > 1:
        eprint(", ".join(names))
        return EXIT_MULTI

    print(names[0], end="")
    return EXIT_OK


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
