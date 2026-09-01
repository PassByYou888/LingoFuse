以下是重写后的 `Bridge_User_Guide.md`，以匹配新的纯二进制转发 bridge.py：

---

# LingoFuse HTTP Bridge – Raw Passthrough Gateway

**File:** `Bridge_User_Guide.md`  
**Version:** 2.0  
**Component:** `lingofuse/bridge.py` (Raw Passthrough Mode)

---

## 1. Introduction

`bridge.py` is a **stateless HTTP to LingoFuse RPC gateway** that forwards HTTP POST requests directly to a LingoFuse backend.  
It does **not** inspect, parse, or modify the request body – it simply passes the raw binary payload to the target API and returns the raw response.

This design makes the bridge a pure **binary passthrough** layer, suitable for any application that accepts arbitrary binary data (including JSON, Protocol Buffers, MessagePack, or custom formats). The bridge only interprets the URL path to determine the target application and API name.

**Key features:**

- **Path‑based routing** – URL path format: `/<app>/<api>` or `/<api>` (uses default app).
- **No JSON parsing** – Request body is forwarded untouched.
- **Binary response** – Backend response is returned as raw bytes.
- **API pre‑check** – `check_api()` validates API availability before forwarding, returning error code `-3` if not found.
- **Multi‑threaded** (default) – Flask’s `threaded=True` for concurrent requests.
- **CORS support** – Allows browser‑based clients.
- **Debug logging** – Optional `--debug` to print request/response details.

---

## 2. Installation & Dependencies

### 2.1 Requirements

- Python 3.6+
- Flask (for HTTP server)
- LingoFuse dynamic library (`LingoFuse64.dll` / `liblingofuse.so` / `liblingofuse.dylib`)
- `lingofuse` Python package (in `Py/lingofuse`)

### 2.2 Install Flask

```bash
pip install flask
```

### 2.3 Environment Setup

Ensure the `lingofuse` package is importable (set `PYTHONPATH`) and the dynamic library is in the system `PATH` or current directory.  
On Windows, you can run `init_demo_env.ps1` to configure automatically.

---

## 3. Performance & Concurrency

- **LingoFuse core**: High‑performance multi‑threaded C4 service mesh, handles thousands of concurrent connections.
- **Python binding**: Uses `ctypes` to call the C library directly – no Python overhead on the critical path.
- **Flask development server**: Default `threaded=True` is sufficient for moderate loads (hundreds of RPS). For production, deploy behind **Gunicorn** or **uWSGI** for higher throughput (tens of thousands of RPS).

---

## 4. Usage

### 4.1 Command‑Line Startup

```bash
python lingofuse/bridge.py [options]
```

**Example:**

```bash
# Connect to IPC endpoint, set default app 'pas', enable debug, listen on port 8081
python bridge.py --endpoint ipc:compute_grid --app pas --debug --port 8081
```

### 4.2 Module Import (programmatic)

```python
from lingofuse.bridge import run_bridge

run_bridge(
    host='0.0.0.0',
    port=8081,
    endpoint_addr='ipc:compute_grid',
    default_app='pas',
    debug=True,
    threaded_enabled=True
)
```

---

## 5. Path Format

The bridge extracts `app` and `api` from the URL path:

- **Explicit app**: `/<app>/<api>` → `app` = first segment, `api` = rest of path.
- **Default app**: `/<api>` → uses the default app set via `--app` (must be provided).

Examples:

| Path | App | API | Note |
|------|-----|-----|------|
| `/pas/exp` | `pas` | `exp` | Explicit app |
| `/exp` | default app | `exp` | Requires `--app pas` |
| `/myapp/foo/bar` | `myapp` | `foo/bar` | Slashes in API name allowed |

If only one segment and no default app is set, the bridge returns error `-2`.

---

## 6. Request & Response

### 6.1 Request

- **Method**: `POST`
- **Headers**: `Content-Type` is ignored by the bridge (but may be used by the backend).
- **Body**: Arbitrary binary data – sent as‑is to the LingoFuse `LF_Call`.

### 6.2 Response

- **Success**: HTTP 200 with the raw response body from the backend.
- **Bridge‑level errors** (format errors, pre‑check failures, timeouts): HTTP 200 with a JSON error object:

```json
{"code": -1, "error": "error message"}   # call error (timeout, LingoFuse error)
{"code": -2, "error": "..."}             # request format error
{"code": -3, "error": "API not available"} # check_api pre‑check failed
```

> **Note**: The bridge **never** wraps a successful response in JSON – it returns the raw backend data.

---

## 7. API Pre‑Check (`check_api`)

Before forwarding, the bridge calls `check_api(app_name, api_name)`:

- If it returns `True` → proceed.
- If it returns `False` → immediately respond with `{"code": -3, "error": "..."}`.

This avoids unnecessary network trips for non‑existent APIs.

---

## 8. Command‑Line Parameters

| Parameter | Environment Variable | Default | Description |
|-----------|----------------------|---------|-------------|
| `--host` | `LINGOFUSE_HOST` | `0.0.0.0` | Listening address |
| `--port` | `LINGOFUSE_PORT` | `8081` | Listening port |
| `--endpoint` | `LINGOFUSE_ENDPOINT` | `ipc:lingofuse_bridge` | LingoFuse service endpoint (e.g., `ipc:cross` or `127.0.0.1:9898`) |
| `--timeout` | `LINGOFUSE_TIMEOUT` | `5000` | Call timeout (milliseconds) |
| `--app` | `LINGOFUSE_APP` | `None` | Default target app name (required for one‑segment paths) |
| `--threaded` / `--no-threaded` | – | `True` | Enable/disable Flask multi‑threading |
| `--debug` | – | `False` | Enable debug logging (request/response details) |

---

## 9. Debug Logging (`--debug`)

When `--debug` is set, the bridge prints:

- Incoming path, app, api, body size.
- Body content (truncated to first 1024 bytes, or hex dump if not UTF‑8).
- Response size and content (truncated).
- `check_api` failure messages and internal LingoFuse status messages.

This is useful for diagnosing connectivity and data issues.

---

## 10. Full Example (with Pascal compute service)

Assume you have the following running:

- `bridge_service` – IPC beacon on `ipc:compute_grid`
- `bridge_compute` – Pascal node exposing `exp` API under app `pas`

### 10.1 Start the Bridge

```bash
python lingofuse/bridge.py --endpoint ipc:compute_grid --app pas --debug --port 8081
```

Output:
```
=== LingoFuse HTTP Bridge (Raw Passthrough) ===
Endpoint: ipc:compute_grid
Default app: pas
Timeout: 5000ms
Threaded: True
Debug: True
Path format: /<app>/<api>  or  /<api> (uses default app)
[Bridge] Connected to LingoFuse service: ipc:compute_grid
Starting HTTP service: http://0.0.0.0:8081
Press Ctrl+C to exit...
```

### 10.2 Call the `exp` API (JSON payload)

```bash
curl -X POST http://127.0.0.1:8081/pas/exp \
     -H "Content-Type: application/json" \
     -d '{"args":["1+2*3"]}'
```

Response (raw JSON from backend):
```json
{"code":0,"result":"7"}
```

Using the default app (path only):
```bash
curl -X POST http://127.0.0.1:8081/exp \
     -H "Content-Type: application/json" \
     -d '{"args":["1+2*3"]}'
```
(same response)

### 10.3 Call a non‑existent API

```bash
curl -X POST http://127.0.0.1:8081/pas/unknown -d '{}'
```

Response:
```json
{"code": -3, "error": "API 'unknown' not available for app 'pas'"}
```

---

## 11. Troubleshooting

### Q1: Library loading fails
- Ensure `LingoFuse64.dll` (or platform‑specific) is in `PATH` or current directory.
- Run `init_demo_env.ps1` (Windows) to set `PATH` and `PYTHONPATH`.

### Q2: `prepareDone` fails / connection timeout
- Verify the beacon (`bridge_service`) is running.
- Ensure the target node (`bridge_compute`) is registered.
- Check that the endpoint (`--endpoint`) matches.

### Q3: `check_api` returns `-3` even though the API exists
- The pre‑check uses cached information; wait a few seconds for network propagation.
- Use `--debug` to see any status messages from the library.

---

## 12. Customisation & Extending

- **Custom serialisation**: The bridge does not serialise – it leaves that to the backend. If you need to decode/encode JSON at the gateway, modify the `handle_call` function.
- **Add middleware**: Insert authentication, logging, or rate‑limiting logic inside `handle_call()`.
- **Health check**: Add a route like `/health` returning `{"status":"ok"}` (not provided by default).

---

## 13. Summary

The LingoFuse HTTP Bridge in raw passthrough mode is a simple, high‑performance gateway that forwards binary HTTP POST requests to LingoFuse RPC services. It is ideal for integrating existing HTTP clients with a LingoFuse backend, especially when the backend handles its own serialisation (e.g., JSON, Protobuf). The bridge’s minimal design ensures low latency and maximum flexibility.

For further details, see the `Cross_Demo_Guide_zh.md` and migration records in the project root.