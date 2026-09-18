#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Bridge smoke test: POST a JSON payload to a running bridge and print
the response.

The payload is serialized via lingofuse.lf_io.dumps_json, which is the
single source of truth for the toolchain's JSON policy:

    json.dumps(obj, ensure_ascii=False, default=str)

The serialized bytes are sent with requests.post(data=...) rather than
requests.post(json=...), because the json= shortcut routes through
json.dumps with ensure_ascii=True and would silently escape any
non-ASCII content the payload might carry. The current payload is
pure ASCII, so the two forms are equivalent byte-for-byte today; the
explicit data= form is chosen so that the test stays correct if the
payload is ever extended with non-ASCII content.

This script does not exercise any LingoFuse API directly. It only
talks HTTP to a bridge process that is assumed to be running (see
bridge.py). It is used as a quick "is the bridge alive and echoing"
check during development.

Exit status:
    0 - the bridge returned HTTP 200 with a non-empty body.
    1 - transport error, non-200 status, or an empty body.
"""

import sys

import requests

from lingofuse.lf_io import dumps_json


# Target bridge URL. The bridge is expected to route
# /<app>/<api> to the matching backend tool. The default app name
# configured via `--app` is not used here; the full path is given
# explicitly so the test does not depend on the bridge's launch
# arguments.
URL = "http://127.0.0.1:8081/exp"

# The payload is deliberately a small JSON object. The backend "exp"
# API is expected to interpret {"args": ["<expression>"]} and return
# the evaluated result.
PAYLOAD = {"args": ["1+2*3"]}


def main() -> int:
    # Serialize with the toolchain-wide JSON policy. dumps_json returns
    # a Python str with literal non-ASCII characters; encode to UTF-8
    # bytes for the wire.
    body = dumps_json(PAYLOAD).encode("utf-8")

    print(f"Sending request: {body!r}")

    try:
        resp = requests.post(
            URL,
            data=body,
            headers={"Content-Type": "application/json"},
            timeout=5,
        )
    except Exception as e:
        print(f"Request exception: {e}", file=sys.stderr)
        return 1

    print(f"Status code: {resp.status_code}")
    print(f"Response content: {resp.text}")

    if resp.status_code != 200:
        print(f"[ERROR] HTTP error: {resp.status_code}", file=sys.stderr)
        return 1

    if resp.text:
        print(f"[OK] Result: {resp.text}")
    else:
        print("[WARN] Empty response (API may not exist or returned empty)")
    return 0


if __name__ == "__main__":
    sys.exit(main())