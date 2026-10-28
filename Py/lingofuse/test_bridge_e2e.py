# -*- coding: utf-8 -*-
"""
End-to-end tests for lingofuse.bridge.

This file covers the L3 (end-to-end) layer of the bridge test
strategy. It launches a REAL bridge subprocess, waits for its
REAL HTTP listener to come up, and drives it with REAL HTTP
requests. Nothing is mocked.

Coverage
--------

* The full inbound path: HTTP socket -> Flask -> URL router ->
  LingoFuse call -> backend API -> response -> HTTP socket.

* JSON normalization applied at the socket boundary, verified by
  observing the repaired payload arrive at the backend.

* Binary safety at the socket boundary: a non-JSON payload reaches
  the backend without corrupting the bridge.

* The error envelope: unknown App, malformed URL, returned as
  well-formed HTTP responses with the documented JSON codes.

* CORS headers attached to every response, including error
  responses.

* Forward-only mode: the LingoFuse Call APIs are registered while
  the HTTP listener is genuinely NOT opened.

Architecture
------------

The test class sets up a small cluster once, in setUpClass:

    [test process]
    |- Backend Server (LingoFuse Server, hosts echo / add)
    |- HTTP client (requests)

    [bridge subprocess]
    |- python bridge.py
    |- connects to the SAME ipc endpoint as the backend
    |- listens on an OS-assigned free TCP port

The backend and the bridge communicate over LingoFuse IPC. The
HTTP client reaches the bridge over a real TCP socket. This is
the only layer that exercises the actual socket path.

{!!!!!  SUBPROCESS ENVIRONMENT IS SANITIZED  !!!!!}
The bridge subprocess is launched with a PYTHONPATH that points
exclusively at THIS checkout of the lingofuse package (the one
that sits next to this test file). The parent process's PYTHONPATH
is deliberately NOT inherited, because a stale copy of the same
package somewhere else on that path (for example, an editable
install from a different project directory) would silently win
the import race and cause the subprocess to fail at import time
with an ImportError for a symbol that exists in THIS copy but not
in the stale one.

See `_build_bridge_env` for the exact construction, and the
`_spawn_bridge` docstring for the reason the sanitation is not
optional.

Isolation
---------

Bridge subprocesses are terminated with SIGTERM/TerminateProcess
in tearDownClass. Because the terminated process does not run its
atexit hooks, port and IPC-queue cleanup is best-effort: each
test class uses a unique endpoint and an OS-assigned port, so
residue from one class cannot affect another.

The backend Server's LingoFuse state is torn down with
``LF_Shutdown`` at the end of each class. This is required
because the LingoFuse library is a process-global singleton: the
next class cannot start a fresh backend until the previous one
has fully released the library.

Known limitations
-----------------

* Forward-only E2E cannot call the bridge's LingoFuse APIs from
  the test process, because the test process's LingoFuse
  singleton is already owned by the backend Server. Forward-only
  Call API coverage therefore lives in the L2 integration file,
  and this file only verifies that no HTTP listener is opened.

All comments and status output are in English.
"""

import json
import os
import socket
import subprocess
import sys
import tempfile
import time
import unittest
import uuid

# Make the package importable when running from the repository root.
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import requests

from lingofuse import Server
from lingofuse._lf_native import LF_Shutdown
from lingofuse.client import C4


# Absolute path to bridge.py. It sits next to this test file.
_BRIDGE_SCRIPT = os.path.join(
    os.path.dirname(os.path.abspath(__file__)),
    "bridge.py",
)

# The directory that contains the `lingofuse` package. It becomes
# the cwd of the bridge subprocess so that `from lingofuse import
# ...` resolves, and so that LingoFuse64.dll is found either on
# PATH or in the cwd fallback.
_PACKAGE_PARENT = os.path.dirname(
    os.path.dirname(os.path.abspath(__file__))
)


# ----------------------------------------------------------------------
# Sanity checks on the paths this test relies on.
#
# Failing here (at import time, in the test process) is far more
# useful than failing later inside the subprocess, where the error
# would only surface as an opaque "subprocess exited early".
# ----------------------------------------------------------------------

if not os.path.isfile(_BRIDGE_SCRIPT):
    raise RuntimeError(
        f"bridge.py not found at {_BRIDGE_SCRIPT!r}. "
        f"This test expects bridge.py to sit next to itself "
        f"inside the lingofuse package directory."
    )

if not os.path.isdir(os.path.join(_PACKAGE_PARENT, "lingofuse")):
    raise RuntimeError(
        f"No lingofuse package directory found under "
        f"{_PACKAGE_PARENT!r}. This test expects the package "
        f"parent to be two levels above this file."
    )


def _find_free_port() -> int:
    """Ask the OS for a free TCP port. Raises on failure."""
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    try:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]
    finally:
        s.close()


def _build_bridge_env() -> dict:
    """
    Build the environment for the bridge subprocess.

    {!!!!!  PYTHONPATH IS PREPENDED, NOT INHERITED  !!!!!}

    The subprocess runs bridge.py, which does `import lingofuse`.
    For the import to resolve against THIS copy of the package --
    the one that sits next to this test file -- the subprocess's
    PYTHONPATH must point at `_PACKAGE_PARENT`.

    Simply inheriting the parent's PYTHONPATH is NOT safe. Python
    searches sys.path in order, and a stale copy of `lingofuse`
    that happens to be earlier on that path (for example, an
    editable install from a different project directory, or an
    intentionally-installed copy for use by a different tool)
    would win the import race. The subprocess would then fail at
    import time with an ImportError for a symbol that exists in
    this copy but not in the stale one:

        ImportError: cannot import name 'LF_UID_Call' from
        'lingofuse._lf_native'

    This has actually been observed in practice: the failure mode
    is silent and confusing because the traceback names the OTHER
    copy's file path, not this one.

    Therefore:

      * `_PACKAGE_PARENT` is placed at the FRONT of the new
        PYTHONPATH, so it beats every other candidate.

      * Any pre-existing PYTHONPATH entries are preserved AFTER
        it, so third-party dependencies that the bridge might
        need (Flask, requests, ...) still resolve. In practice
        these live in site-packages and are added by site.py, not
        via PYTHONPATH, so this preservation is purely defensive.

      * PATH is inherited unchanged, so the subprocess finds
        LingoFuse64.dll the same way the parent process does.

      * Every other environment variable is inherited unchanged
        (HOME, TMPDIR, SystemRoot, ...), matching the parent's
        behaviour exactly.

    Returns:
        A new dict suitable for `subprocess.Popen(env=...)`.
    """
    env = os.environ.copy()

    existing = env.get("PYTHONPATH", "")
    if existing:
        env["PYTHONPATH"] = _PACKAGE_PARENT + os.pathsep + existing
    else:
        env["PYTHONPATH"] = _PACKAGE_PARENT

    return env


class BridgeE2EFixture:
    """
    Manages a backend Server and a bridge subprocess as one unit.

    The fixture is designed to be created once per test class. All
    resources are released by ``stop``, which is idempotent.
    """

    def __init__(self, *, forward_only: bool = False,
                 normalize_json: bool = True):
        self.forward_only = forward_only
        self.normalize_json = normalize_json

        self.server = None
        self.bridge_proc = None
        self.bridge_port = None
        self.bridge_endpoint = None
        self.backend_app_name = None

        self._stderr_path = None
        self._stderr_file = None

    # ------------------------------------------------------------------
    # Lifecycle
    # ------------------------------------------------------------------

    def start(self) -> None:
        suffix = uuid.uuid4().hex[:6]
        pid = os.getpid()
        self.bridge_endpoint = f"ipc:bridge_e2e_{pid}_{suffix}"
        self.bridge_port = _find_free_port()
        self.backend_app_name = f"E2EBackend_{suffix}"

        # --- Start the backend Server in this process. ---
        self.server = Server(self.backend_app_name, "e2e backend")

        @self.server.expose("echo")
        def echo(value):
            return value

        @self.server.expose("add")
        def add(a, b):
            return a + b

        self.server.start(self.bridge_endpoint)

        # --- Start the bridge subprocess. ---
        self._spawn_bridge()

    def stop(self) -> None:
        # Kill the bridge first; it holds a client connection into
        # the endpoint that the backend Server is about to close.
        self._kill_bridge()
        self._close_stderr()
        self._remove_stderr()

        if self.server is not None:
            try:
                self.server.stop()
            except Exception:
                pass
            self.server = None

    # ------------------------------------------------------------------
    # Bridge subprocess management
    # ------------------------------------------------------------------

    def _spawn_bridge(self) -> None:
        """
        Launch bridge.py as a subprocess.

        {!!!!!  ENV SANITATION IS REQUIRED  !!!!!}
        The subprocess is launched with a PYTHONPATH that resolves
        `import lingofuse` against THIS checkout of the package,
        not against a stale copy that might be reachable through
        the parent's environment. See `_build_bridge_env` for the
        full rationale and for the exact construction.

        Without this, the subprocess fails at import time with an
        opaque ImportError naming the OTHER copy of the package,
        and every test in the class errors out at setUpClass with
        a generic "subprocess exited early" message.
        """
        # Keep the subprocess's stdout+stderr in a temp file so that
        # a failure can be diagnosed after the fact.
        fd, self._stderr_path = tempfile.mkstemp(
            prefix="lingofuse_bridge_e2e_", suffix=".log"
        )
        os.close(fd)
        self._stderr_file = open(self._stderr_path, "wb")

        args = [
            sys.executable,
            _BRIDGE_SCRIPT,
            "--endpoint", self.bridge_endpoint,
            "--bridge-app", f"__lf_e2e_{os.getpid()}__",
            # Force the bridge to block in LF_PrepareDone until the
            # handshake completes, so its broadcast cache is already
            # populated when the first inbound HTTP request arrives.
            # Without this flag the bridge starts the HTTP listener
            # immediately and the first 1-3 seconds of requests can
            # fail with a -3 pre-check error.
            "--wait-connection",
            # Generous timeout: the backend is local, but CI can be
            # slow to spin up the IPC channel.
            "--wait-timeout", "20000",
        ]

        if self.forward_only:
            args.append("--forward-only")
        else:
            args.extend([
                "--host", "127.0.0.1",
                "--port", str(self.bridge_port),
            ])

        if not self.normalize_json:
            args.append("--no-normalize-json")

        creationflags = 0
        if sys.platform == "win32":
            creationflags = subprocess.CREATE_NEW_PROCESS_GROUP

        # ------------------------------------------------------------------
        # Build the subprocess environment.
        #
        # See `_build_bridge_env` for the full rationale. The key
        # point is that PYTHONPATH points at THIS checkout, so the
        # subprocess cannot accidentally import a stale copy of the
        # lingofuse package.
        # ------------------------------------------------------------------
        env = _build_bridge_env()

        self.bridge_proc = subprocess.Popen(
            args,
            cwd=_PACKAGE_PARENT,
            env=env,
            stdout=self._stderr_file,
            stderr=subprocess.STDOUT,
            creationflags=creationflags,
        )

        if not self.forward_only:
            self._wait_for_http_ready()
        else:
            # No HTTP listener to probe. Give the subprocess a
            # moment to finish starting its LingoFuse connection,
            # then confirm it is still alive.
            time.sleep(3.0)
            if self.bridge_proc.poll() is not None:
                self._dump_stderr()
                raise RuntimeError(
                    f"bridge subprocess exited early in forward-only "
                    f"mode (code={self.bridge_proc.returncode})"
                )

    def _wait_for_http_ready(self, timeout: float = 30.0) -> None:
        """
        Poll the bridge's HTTP port until it accepts a connection.

        A POST to "/" is guaranteed to produce a 400 response from
        the URL parser, which is exactly the signal we want: any
        HTTP response means the listener is up.
        """
        url = f"http://127.0.0.1:{self.bridge_port}/"
        deadline = time.monotonic() + timeout
        last_exc = None

        while time.monotonic() < deadline:
            if self.bridge_proc.poll() is not None:
                self._dump_stderr()
                raise RuntimeError(
                    f"bridge subprocess exited early "
                    f"(code={self.bridge_proc.returncode})"
                )
            try:
                requests.post(url, data=b"", timeout=0.5)
                return
            except requests.RequestException as exc:
                last_exc = exc
                time.sleep(0.2)

        self._dump_stderr()
        raise TimeoutError(
            f"bridge HTTP listener did not become ready within "
            f"{timeout}s; last error: {last_exc}"
        )

    def _kill_bridge(self) -> None:
        if self.bridge_proc is None:
            return
        try:
            if self.bridge_proc.poll() is None:
                self.bridge_proc.terminate()
                try:
                    self.bridge_proc.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    self.bridge_proc.kill()
                    self.bridge_proc.wait(timeout=5)
        except Exception:
            pass
        finally:
            self.bridge_proc = None

    def _close_stderr(self) -> None:
        if self._stderr_file is not None:
            try:
                self._stderr_file.close()
            except Exception:
                pass
            self._stderr_file = None

    def _remove_stderr(self) -> None:
        if self._stderr_path and os.path.exists(self._stderr_path):
            try:
                os.unlink(self._stderr_path)
            except Exception:
                pass
            self._stderr_path = None

    def _dump_stderr(self) -> None:
        if not self._stderr_path or not os.path.exists(self._stderr_path):
            return
        try:
            with open(self._stderr_path, "rb") as fh:
                data = fh.read().decode("utf-8", errors="replace")
        except Exception:
            return
        tail = data[-4000:]
        print(
            "\n--- bridge subprocess stderr (tail) ---\n"
            f"{tail}\n--- end of stderr ---\n"
        )

    # ------------------------------------------------------------------
    # Convenience
    # ------------------------------------------------------------------

    def url(self, path: str) -> str:
        return (
            f"http://127.0.0.1:{self.bridge_port}/"
            f"{path.lstrip('/')}"
        )
    
# ======================================================================
# Default mode: HTTP listener + LingoFuse connection
# ======================================================================

class TestBridgeEndToEnd(unittest.TestCase):
    """
    Real HTTP socket -> bridge subprocess -> LingoFuse IPC ->
    backend Server -> back over the same path.

    One fixture is shared by every test method in this class, so
    the ~5-second subprocess startup cost is paid once.
    """

    @classmethod
    def setUpClass(cls):
        cls.fixture = BridgeE2EFixture()
        try:
            cls.fixture.start()
        except Exception:
            cls.fixture.stop()
            raise

    @classmethod
    def tearDownClass(cls):
        cls.fixture.stop()
        # Reset the process-global LingoFuse state so that the next
        # test class (forward-only) can start a fresh backend.
        try:
            C4.shutdown()
        except Exception:
            pass
        try:
            LF_Shutdown()
        except Exception:
            pass

    # ------------------------------------------------------------------
    # Happy paths
    # ------------------------------------------------------------------

    def test_app_route_roundtrip(self):
        """A JSON object round-trips through the full stack."""
        app = self.fixture.backend_app_name
        resp = requests.post(
            self.fixture.url(f"{app}/echo"),
            data=json.dumps({"msg": "hello"}).encode("utf-8"),
            headers={"Content-Type": "application/json"},
            timeout=10,
        )
        self.assertEqual(resp.status_code, 200)
        self.assertEqual(resp.json(), {"msg": "hello"})

    def test_app_route_positional_arguments(self):
        """
        A JSON list is unpacked into positional arguments of the
        backend function, matching the Server dispatch rules.
        """
        app = self.fixture.backend_app_name
        resp = requests.post(
            self.fixture.url(f"{app}/add"),
            data=json.dumps([3, 4]).encode("utf-8"),
            headers={"Content-Type": "application/json"},
            timeout=10,
        )
        self.assertEqual(resp.status_code, 200)
        self.assertEqual(resp.json(), 7)

    def test_response_is_utf8_json(self):
        """
        The response body is canonical UTF-8 with literal non-ASCII
        characters (no \\uXXXX escapes).
        """
        app = self.fixture.backend_app_name
        resp = requests.post(
            self.fixture.url(f"{app}/echo"),
            data=json.dumps({"name": "\u4f60\u597d"}).encode("utf-8"),
            headers={"Content-Type": "application/json"},
            timeout=10,
        )
        self.assertEqual(resp.status_code, 200)
        # ``requests`` decodes the body using the charset in the
        # Content-Type header. The bridge sets it to utf-8.
        self.assertIn("\u4f60\u597d", resp.text)
        self.assertNotIn("\\u4f60", resp.text)

    # ------------------------------------------------------------------
    # Normalization at the socket boundary
    # ------------------------------------------------------------------

    def test_trailing_comma_is_repaired_on_the_wire(self):
        """
        A payload with a trailing comma reaches the backend as valid
        JSON, proving that the normalization runs at the socket
        boundary.
        """
        app = self.fixture.backend_app_name
        resp = requests.post(
            self.fixture.url(f"{app}/echo"),
            data=b'{"a": 1,}',
            headers={"Content-Type": "application/json"},
            timeout=10,
        )
        self.assertEqual(resp.status_code, 200)
        self.assertEqual(resp.json(), {"a": 1})

    def test_utf8_bom_is_stripped_on_the_wire(self):
        app = self.fixture.backend_app_name
        body = b"\xef\xbb\xbf" + b'{"k": "v"}'
        resp = requests.post(
            self.fixture.url(f"{app}/echo"),
            data=body,
            headers={"Content-Type": "application/json"},
            timeout=10,
        )
        self.assertEqual(resp.status_code, 200)
        self.assertEqual(resp.json(), {"k": "v"})

    # ------------------------------------------------------------------
    # Binary safety
    # ------------------------------------------------------------------

    def test_binary_payload_does_not_crash_bridge(self):
        """
        A non-JSON payload is forwarded unchanged. The backend's
        strict JSON reader rejects it, and the Server wrapper turns
        that into a structured error, but the bridge itself stays
        healthy.
        """
        app = self.fixture.backend_app_name
        resp = requests.post(
            self.fixture.url(f"{app}/echo"),
            data=b"\x89PNG\r\n\x1a\n",
            headers={"Content-Type": "application/octet-stream"},
            timeout=10,
        )
        self.assertIn(resp.status_code, (200, 400))
        # The bridge is still alive after forwarding binary data.
        self.assertIsNone(self.fixture.bridge_proc.poll())

    # ------------------------------------------------------------------
    # Error envelopes
    # ------------------------------------------------------------------

    def test_unknown_app_returns_documented_error_code(self):
        resp = requests.post(
            self.fixture.url("NoSuchApp_xyz/anything"),
            data=b"{}",
            timeout=10,
        )
        self.assertEqual(resp.status_code, 200)
        body = resp.json()
        # -1: call failure. -3: pre-check failure.
        self.assertIn(body["code"], (-1, -3))
        self.assertIn("error", body)

    def test_malformed_uid_route_returns_400(self):
        resp = requests.post(
            self.fixture.url("uid/not-a-valid-uid/echo"),
            data=b"{}",
            timeout=10,
        )
        self.assertEqual(resp.status_code, 400)
        self.assertEqual(resp.json()["code"], -2)

    def test_malformed_p2p_route_returns_400(self):
        # Missing the api segment.
        resp = requests.post(
            self.fixture.url("p2p/only-a-group"),
            data=b"{}",
            timeout=10,
        )
        self.assertEqual(resp.status_code, 400)
        self.assertEqual(resp.json()["code"], -2)

    # ------------------------------------------------------------------
    # CORS
    # ------------------------------------------------------------------

    def test_cors_headers_on_success(self):
        app = self.fixture.backend_app_name
        resp = requests.post(
            self.fixture.url(f"{app}/echo"),
            data=b"{}",
            timeout=10,
        )
        self.assertEqual(
            resp.headers.get("Access-Control-Allow-Origin"), "*"
        )

    def test_cors_headers_on_error(self):
        resp = requests.post(
            self.fixture.url("uid/bad/echo"),
            data=b"{}",
            timeout=10,
        )
        self.assertEqual(
            resp.headers.get("Access-Control-Allow-Origin"), "*"
        )


# ======================================================================
# Forward-only mode: no HTTP listener
# ======================================================================

class TestBridgeForwardOnlyE2E(unittest.TestCase):
    """
    In forward-only mode the bridge registers its LingoFuse Call
    APIs but does NOT open an HTTP listener.

    The test process cannot verify the Call APIs end-to-end here,
    because its LingoFuse singleton is already owned by the backend
    Server. That coverage lives in the L2 integration file, where
    the bridge's callbacks are invoked directly. This class focuses
    on the one thing only an end-to-end test can prove: the HTTP
    listener is genuinely absent.
    """

    @classmethod
    def setUpClass(cls):
        cls.fixture = BridgeE2EFixture(forward_only=True)
        try:
            cls.fixture.start()
        except Exception:
            cls.fixture.stop()
            raise

    @classmethod
    def tearDownClass(cls):
        cls.fixture.stop()
        try:
            C4.shutdown()
        except Exception:
            pass
        try:
            LF_Shutdown()
        except Exception:
            pass

    def test_no_http_listener_is_opened(self):
        """
        A TCP connect to the (never-bound) bridge port must fail.

        The fixture chose a free port precisely so that nothing else
        on the machine is listening on it. If the bridge had opened
        a listener despite --forward-only, the connect would
        succeed and this test would fail.
        """
        port = self.fixture.bridge_port
        sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        sock.settimeout(1.0)
        try:
            with self.assertRaises(
                (ConnectionRefusedError, OSError, socket.timeout)
            ):
                sock.connect(("127.0.0.1", port))
        finally:
            sock.close()

    def test_bridge_subprocess_stays_alive(self):
        """
        Forward-only mode is not a "start and immediately exit"
        mode. The subprocess stays alive so that its LingoFuse Call
        APIs remain servable.
        """
        self.assertIsNone(self.fixture.bridge_proc.poll())


# ======================================================================
# Entry point
# ======================================================================

if __name__ == "__main__":
    unittest.main()
    