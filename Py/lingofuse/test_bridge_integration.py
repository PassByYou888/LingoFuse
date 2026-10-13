# -*- coding: utf-8 -*-
"""
Integration tests for lingofuse.bridge.

Covers the L2 (integration) layer: the bridge's router, Flask
request handling, and the two Call-API callbacks, all exercised
in-process against a live LingoFuse connection.

Lifecycle design
----------------
LingoFuse is a process-global singleton: it has one simulated main
thread, one client pool, and one service pool per process. The
bridge's production ``_setup_network`` prepares only a CLIENT, on
the assumption that a separate process provides the SERVICE. In a
single-process integration test, that assumption does not hold:
``LF_PrepareDone`` would wait for an online state that never
arrives and time out.

This file therefore prepares BOTH the service and the client
itself, using the same primitives that ``_setup_network`` uses,
and binds the bridge's own App to the client. The result is a
fully functional in-process LingoFuse mesh on which the bridge's
router and callbacks can be exercised without a subprocess.

The full production path -- including ``_setup_network`` itself --
is covered by ``test_bridge_e2e.py``, which launches the bridge as
a real subprocess.

Coverage
--------

* Direction B (``_bridge_post_callback``): called directly with
  hand-built DataHandles; no LingoFuse round-trip needed.
* Direction C (``_bridge_repair_callback``): same technique.
* Inbound routing (``handle_call`` + the four URL forms) against a
  live in-process mesh with an ``echo`` API.
* Pre-check failure paths and malformed-URL error paths.
* Forward-only mode: the bridge's Call APIs remain callable.
* Config loading (env vars and CLI args).

All comments and status output are in English.
"""

import json
import logging
import os
import sys
import unittest
import uuid
from unittest import mock

# Make the package importable when running from the repository root.
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

logging.getLogger("lingofuse.json_repair_preprocess").setLevel(logging.CRITICAL)
logging.getLogger("LingoFuseBridge").setLevel(logging.WARNING)

import lingofuse.bridge as bridge_module
from lingofuse.bridge import (
    STATUS_CANONICAL,
    STATUS_PASSTHROUGH,
    STATUS_RECODED,
    STATUS_REPAIRED,
    BridgeConfig,
    _apply_command_line,
    _apply_environment_defaults,
    _bridge_post_callback,
    _bridge_repair_callback,
    normalize_json_bytes,
)
from lingofuse.core import App, DataHandle
from lingofuse._lf_native import (
    LF_ExitMainThread,
    LF_PrepareClient,
    LF_PrepareDone,
    LF_PrepareService,
    LF_ResetPrepare,
    LF_Shutdown,
    LFCallFunc,
)
from lingofuse.client import C4
from lingofuse.lf_io import (
    cstr,
    read_string_bytes,
    write_string_bytes,
)


# ======================================================================
# Helpers
# ======================================================================

def _reset_bridge_globals(clear_callbacks: bool = True):
    """
    Reset the module-level bridge state without touching LingoFuse.

    ``clear_callbacks`` must be True at class boundaries; inside a
    running class it must be False so that the ctypes callback
    objects held by a live App are not garbage-collected while the
    C library still owns their function pointers.
    """
    bridge_module._bridge_app_handle = None
    if clear_callbacks:
        bridge_module._bridge_app_callbacks.clear()
    bridge_module._cleanup_done = False

    defaults = BridgeConfig()
    for field_name in vars(defaults):
        setattr(
            bridge_module.config,
            field_name,
            getattr(defaults, field_name),
        )


def _full_lingofuse_reset():
    """Best-effort teardown of the LingoFuse process-global state."""
    try:
        C4.shutdown()
    except Exception:
        pass
    try:
        LF_ExitMainThread()
    except Exception:
        pass
    try:
        LF_Shutdown()
    except Exception:
        pass


def _make_bridge_call_handle(api_name: str, payload=None):
    hnd = DataHandle(api_name)
    if payload is not None:
        hnd.write_json(payload)
    return hnd


def _read_bridge_call_result(hnd: DataHandle):
    hnd.set_pos(0)
    return hnd.read_json_strict()


def _make_echo_callback():
    """
    Return a user-facing echo callback for ``App.register_call``.

    {!!!!!  DO NOT WRAP THE HANDLES  !!!!!}
    ``App.register_call`` already wraps the raw ctypes handles in
    DataHandle objects before invoking the user callback (see
    ``lingofuse.core.App.register_call``). The parameters arriving
    here are therefore ALREADY DataHandle instances, not raw
    pointers. Calling ``DataHandle._from_raw`` on them again would
    store a DataHandle where a raw pointer is expected, and the
    next ``LF_GetSize`` would raise
    ``TypeError: 'DataHandle' object cannot be interpreted as
    ctypes.c_void_p``.

    This is different from a DIRECT ctypes callback (one built with
    ``LFCallFunc(...)`` and handed straight to the C library, as
    ``bridge._bridge_repair_callback`` does). Such a callback DOES
    receive raw pointers and DOES need the ``_from_raw`` wrapping.
    The two paths must not be confused.
    """
    def _echo(trigger, h_in, h_out):
        try:
            data = h_in.read_json_strict()
        except Exception:
            data = None
        h_out.write_json(data)
    return _echo


# ======================================================================
# Base class for tests that need a live LingoFuse mesh
# ======================================================================

class BridgeNetworkTestBase(unittest.TestCase):
    """
    Bring up an in-process LingoFuse mesh with the bridge's own App
    bound to a client, so that inbound routing can be exercised
    end-to-end without a subprocess.

    The preparation sequence mirrors what ``_setup_network`` does
    for the client half, and adds the service half that a single
    process needs:

        1. Reset the prepare queue.
        2. Queue a service on ``<endpoint>``.
        3. Queue a client bound to the bridge's App.
        4. Start the simulated main thread via ``LF_PrepareDone``.

    After this, ``LF_Call(<bridge_app_name>, ...)`` from within this
    process will be serviced by the local client (local-first
    routing), which is exactly what the router tests need.
    """

    _CLASS_TAG = "BridgeTest"
    _REGISTERED_APIS = ("echo",)

    @classmethod
    def setUpClass(cls):
        _full_lingofuse_reset()
        _reset_bridge_globals(clear_callbacks=True)

        cls._endpoint = (
            f"ipc:bridge_{cls._CLASS_TAG.lower()}_"
            f"{os.getpid()}_{uuid.uuid4().hex[:6]}"
        )
        cls._app_name = f"__bridge_{cls._CLASS_TAG.lower()}__"

        # Create the App that will serve as the "backend" for the
        # bridge's own routing decisions.
        cls._bridge_app = App(cls._app_name, "bridge L2 host")

        # Register one echo API per entry in _REGISTERED_APIS.
        # App.register_call appends the ctypes wrapper to the App's
        # own _callbacks list, so lifetime is managed by the App.
        for api_name in cls._REGISTERED_APIS:
            cls._bridge_app.register_call(
                api_name, _make_echo_callback(), f"L2 test {api_name}"
            )

        # Prepare service + client + main thread.
        LF_ResetPrepare()
        LF_PrepareService(cstr(cls._endpoint), cstr(cls._endpoint))
        LF_PrepareClient(cstr(cls._endpoint), cls._bridge_app.raw)

        ret = LF_PrepareDone()
        if ret != 1:
            raise RuntimeError(
                f"LF_PrepareDone returned {ret} for endpoint "
                f"{cls._endpoint!r}"
            )

        # Publish the config that the bridge's router reads at
        # request time. These values are what a real bridge process
        # would have after _setup_network succeeded.
        cfg = bridge_module.config
        cfg.endpoint = cls._endpoint
        cfg.bridge_app_name = cls._app_name
        cfg.timeout_ms = 3000
        cfg.no_precheck = False
        cfg.debug = False
        cfg.normalize_json = True
        cfg.default_app = None

        # Publish the App handle so that the module-level identity
        # (used by cleanup and by any future code path) is coherent.
        bridge_module._bridge_app_handle = cls._bridge_app.raw

    @classmethod
    def tearDownClass(cls):
        _reset_bridge_globals(clear_callbacks=True)
        try:
            cls._bridge_app.free()
        except Exception:
            pass
        _full_lingofuse_reset()

    def setUp(self):
        # Snapshot config fields a test may mutate.
        self._saved = {
            "default_app": bridge_module.config.default_app,
            "no_precheck": bridge_module.config.no_precheck,
            "debug": bridge_module.config.debug,
            "normalize_json": bridge_module.config.normalize_json,
        }

    def tearDown(self):
        for key, value in self._saved.items():
            setattr(bridge_module.config, key, value)


# ======================================================================
# Direction B: outbound HTTP POST proxy
# ======================================================================

class TestOutboundPostCallback(unittest.TestCase):
    """Direction B: the outbound HTTP POST proxy (direct invocation)."""

    def setUp(self):
        _reset_bridge_globals(clear_callbacks=False)

    def tearDown(self):
        _reset_bridge_globals(clear_callbacks=False)

    def _invoke(self, request_obj, mock_response=None, side_effect=None):
        h_in = _make_bridge_call_handle(
            bridge_module.config.bridge_api_name, request_obj
        )
        h_out = DataHandle("result")
        try:
            with mock.patch(
                "lingofuse.bridge.requests.request"
            ) as mocked:
                if side_effect is not None:
                    mocked.side_effect = side_effect
                else:
                    mocked.return_value = mock_response
                _bridge_post_callback(None, h_in.raw, h_out.raw)
            return _read_bridge_call_result(h_out)
        finally:
            h_in.free()
            h_out.free()

    def _ok_response(self, status=200, body=None, headers=None):
        resp = mock.Mock()
        resp.status_code = status
        resp.headers = headers or {"Content-Type": "application/json"}
        if body is None:
            body = {"ok": True}
        resp.json.return_value = body
        return resp

    def test_minimal_request_succeeds(self):
        resp = self._ok_response(status=201, body={"id": 7})
        result = self._invoke(
            {"url": "http://example.com/api"}, mock_response=resp
        )
        self.assertEqual(result["status_code"], 201)
        self.assertEqual(result["body"], {"id": 7})
        self.assertIn("content-type", result["headers"])

    def test_invalid_request_returns_error_object(self):
        result = self._invoke({"method": "GET"})  # missing url
        self.assertIn("error", result)
        self.assertIn("url", result["error"].lower())

    def test_http_timeout_returns_error(self):
        import requests
        result = self._invoke(
            {"url": "http://example.com/slow"},
            side_effect=requests.Timeout(),
        )
        self.assertIn("error", result)
        msg = result["error"].lower()
        self.assertTrue(
            "timed out" in msg or "timeout" in msg,
            f"expected a timeout indication, got {result['error']!r}",
        )

    def test_http_request_exception_returns_error(self):
        import requests
        result = self._invoke(
            {"url": "http://example.com/down"},
            side_effect=requests.ConnectionError("refused"),
        )
        self.assertIn("error", result)
        self.assertIn("failed", result["error"].lower())

    def test_unexpected_exception_is_caught(self):
        result = self._invoke(
            {"url": "http://example.com/x"},
            side_effect=RuntimeError("unexpected"),
        )
        self.assertIn("error", result)

    def test_non_json_response_body_is_wrapped_as_string(self):
        resp = mock.Mock()
        resp.status_code = 200
        resp.headers = {"Content-Type": "text/plain"}
        resp.json.side_effect = ValueError("not json")
        resp.content = b"plain text body"
        result = self._invoke(
            {"url": "http://example.com/txt"}, mock_response=resp
        )
        self.assertEqual(result["body"], "plain text body")

    def test_body_is_serialized_with_ensure_ascii_false(self):
        resp = self._ok_response()
        with mock.patch(
            "lingofuse.bridge.requests.request"
        ) as mocked:
            mocked.return_value = resp
            h_in = _make_bridge_call_handle(
                "test",
                {
                    "url": "http://example.com/api",
                    "body": {"name": "\u4f60\u597d"},
                },
            )
            h_out = DataHandle("result")
            try:
                _bridge_post_callback(None, h_in.raw, h_out.raw)
            finally:
                h_in.free()
                h_out.free()

        _, kwargs = mocked.call_args
        sent = kwargs["data"]
        self.assertIsInstance(sent, bytes)
        self.assertIn("\u4f60\u597d".encode("utf-8"), sent)
        self.assertNotIn(b"\\u4f60", sent)


# ======================================================================
# Direction C: JSON repair API
# ======================================================================

class TestRepairCallback(unittest.TestCase):
    """Direction C: the JSON repair service."""

    def setUp(self):
        _reset_bridge_globals(clear_callbacks=False)

    def tearDown(self):
        _reset_bridge_globals(clear_callbacks=False)

    def _invoke(self, payload: bytes) -> bytes:
        # Reset position to 0 after writing; write_string_bytes
        # advances the write position to the end.
        h_in = DataHandle("__lf_repair_json__")
        write_string_bytes(h_in.raw, payload)
        h_in.set_pos(0)
        h_out = DataHandle("result")
        try:
            _bridge_repair_callback(None, h_in.raw, h_out.raw)
            h_out.set_pos(0)
            return read_string_bytes(h_out.raw)
        finally:
            h_in.free()
            h_out.free()

    def test_valid_json_passes_through_unchanged(self):
        payload = b'{"a": 1}'
        self.assertEqual(self._invoke(payload), payload)

    def test_trailing_comma_is_repaired(self):
        result = self._invoke(b'{"a": 1,}')
        self.assertEqual(json.loads(result.decode("utf-8")), {"a": 1})

    def test_single_quotes_are_repaired(self):
        result = self._invoke(b"{'a': 1}")
        self.assertEqual(json.loads(result.decode("utf-8")), {"a": 1})

    def test_empty_input_returns_empty(self):
        self.assertEqual(self._invoke(b""), b"")

    def test_non_ascii_is_preserved_literally(self):
        payload = '{"name": "\u4f60\u597d"}'.encode("utf-8")
        result = self._invoke(payload)
        self.assertIn("\u4f60\u597d".encode("utf-8"), result)
        self.assertNotIn(b"\\u4f60", result)

    def test_utf8_bom_is_stripped(self):
        payload = b"\xef\xbb\xbf" + b'{"a": 1}'
        result = self._invoke(payload)
        self.assertFalse(result.startswith(b"\xef\xbb\xbf"))

    def test_utf16_bom_payload_passes_through_unchanged(self):
        """
        The ONLY binary-safe path the repair callback offers: a
        payload whose first two bytes are a UTF-16 BOM is returned
        byte-for-byte unchanged, without any decode-repair-encode
        round-trip.

        This is the callback's documented binary safety contract.
        Note that arbitrary binary WITHOUT a UTF-16 BOM is not
        binary-safe: the encoding fallback chain decodes it via GBK
        or Latin-1 and re-encodes it as UTF-8, which mutates the
        bytes. That behaviour is exercised by the next test.
        """
        payload = b"\xff\xfe" + b"\x89PNG\r\n\x1a\n"
        result = self._invoke(payload)
        self.assertEqual(result, payload)

    def test_non_bom_binary_is_reencoded_via_gbk(self):
        """
        Documents the encoding fallback behaviour for arbitrary
        binary without a UTF-16 BOM: the payload is decoded via GBK
        (if possible) and re-encoded as UTF-8, which mutates the
        bytes. This is a limitation, not a bug: the repair API is a
        JSON repair service, not a binary transport.
        """
        payload = b"\x89PNG\r\n\x1a\n"
        result = self._invoke(payload)
        # b'\x89P' is a valid GBK pair for U+5852; the rest is ASCII.
        # After decode + repair + UTF-8 encode the leading pair
        # becomes the three-byte UTF-8 sequence for that character.
        self.assertNotEqual(result, payload)
        self.assertGreater(len(result), len(payload))
        # The trailing ASCII bytes are preserved.
        self.assertTrue(result.endswith(b"NG\r\n\x1a\n"))


# ======================================================================
# Inbound routing (against a live in-process mesh)
# ======================================================================

class TestInboundAppNameRouting(BridgeNetworkTestBase):
    """Inbound App-name addressing: /<app>/<api> and /<api>."""

    _CLASS_TAG = "AppRoute"
    _REGISTERED_APIS = ("echo",)

    def test_app_and_api_success(self):
        app_name = bridge_module.config.bridge_app_name
        client = bridge_module.app.test_client()
        response = client.post(
            f"/{app_name}/echo",
            data=json.dumps({"msg": "hi"}).encode("utf-8"),
            content_type="application/json",
        )
        self.assertEqual(response.status_code, 200)
        self.assertEqual(
            json.loads(response.get_data().decode("utf-8")),
            {"msg": "hi"},
        )

    def test_api_only_with_default_app(self):
        bridge_module.config.default_app = (
            bridge_module.config.bridge_app_name
        )
        client = bridge_module.app.test_client()
        response = client.post(
            "/echo",
            data=json.dumps({"k": 1}).encode("utf-8"),
            content_type="application/json",
        )
        self.assertEqual(response.status_code, 200)
        self.assertEqual(
            json.loads(response.get_data().decode("utf-8")), {"k": 1}
        )

    def test_api_only_without_default_app_returns_400(self):
        bridge_module.config.default_app = None
        client = bridge_module.app.test_client()
        response = client.post("/echo", data=b"{}")
        self.assertEqual(response.status_code, 400)
        body = json.loads(response.get_data().decode("utf-8"))
        self.assertEqual(body["code"], -2)

    def test_unknown_app_triggers_precheck_failure(self):
        bridge_module.config.no_precheck = False
        bridge_module.config.debug = False
        client = bridge_module.app.test_client()
        response = client.post("/NoSuchApp/echo", data=b"{}")
        self.assertEqual(response.status_code, 200)
        body = json.loads(response.get_data().decode("utf-8"))
        self.assertEqual(body["code"], -3)


class TestInboundUidRouting(BridgeNetworkTestBase):
    """Inbound UID addressing: /uid/<hex64>/<api>."""

    _CLASS_TAG = "UidRoute"
    _REGISTERED_APIS = ()

    def test_invalid_uid_hex_returns_400(self):
        client = bridge_module.app.test_client()
        response = client.post("/uid/not-a-uid/echo", data=b"{}")
        self.assertEqual(response.status_code, 400)
        body = json.loads(response.get_data().decode("utf-8"))
        self.assertEqual(body["code"], -2)
        self.assertIn("UID", body["error"])

    def test_missing_uid_segment_returns_400(self):
        client = bridge_module.app.test_client()
        response = client.post("/uid/echo", data=b"{}")
        self.assertEqual(response.status_code, 400)
        body = json.loads(response.get_data().decode("utf-8"))
        self.assertEqual(body["code"], -2)

    def test_short_uid_hex_returns_400(self):
        client = bridge_module.app.test_client()
        response = client.post("/uid/abcd/echo", data=b"{}")
        self.assertEqual(response.status_code, 400)
        body = json.loads(response.get_data().decode("utf-8"))
        self.assertEqual(body["code"], -2)

    def test_unknown_uid_precheck_failure(self):
        bridge_module.config.no_precheck = False
        bridge_module.config.debug = False
        unknown_uid = "ab" * 32
        client = bridge_module.app.test_client()
        response = client.post(
            f"/uid/{unknown_uid}/echo", data=b"{}"
        )
        self.assertEqual(response.status_code, 200)
        body = json.loads(response.get_data().decode("utf-8"))
        self.assertEqual(body["code"], -3)


class TestInboundP2PNameRouting(BridgeNetworkTestBase):
    """Inbound P2PName addressing: /p2p/<group>/<api>."""

    _CLASS_TAG = "P2pRoute"
    _REGISTERED_APIS = ()

    def test_missing_group_returns_400(self):
        client = bridge_module.app.test_client()
        response = client.post("/p2p/echo", data=b"{}")
        self.assertEqual(response.status_code, 400)
        body = json.loads(response.get_data().decode("utf-8"))
        self.assertEqual(body["code"], -2)

    def test_empty_group_returns_400(self):
        client = bridge_module.app.test_client()
        response = client.post("/p2p//echo", data=b"{}")
        self.assertEqual(response.status_code, 400)

    def test_unknown_group_precheck_failure(self):
        bridge_module.config.no_precheck = False
        bridge_module.config.debug = False
        client = bridge_module.app.test_client()
        response = client.post(
            "/p2p/no_such_group/echo", data=b"{}"
        )
        self.assertEqual(response.status_code, 200)
        body = json.loads(response.get_data().decode("utf-8"))
        self.assertEqual(body["code"], -3)


# ======================================================================
# Inbound JSON normalization
# ======================================================================

class TestInboundJsonNormalization(BridgeNetworkTestBase):
    """Normalization runs before the payload is forwarded."""

    _CLASS_TAG = "Normalize"
    _REGISTERED_APIS = ("echo",)

    def test_trailing_comma_is_repaired_before_forward(self):
        app_name = bridge_module.config.bridge_app_name
        client = bridge_module.app.test_client()
        response = client.post(
            f"/{app_name}/echo",
            data=b'{"a": 1,}',
            content_type="application/json",
        )
        self.assertEqual(response.status_code, 200)
        self.assertEqual(
            json.loads(response.get_data().decode("utf-8")), {"a": 1}
        )


# ======================================================================
# Forward-only mode (in-process)
# ======================================================================

class TestForwardOnlyModeCallbacks(unittest.TestCase):
    """
    Forward-only mode does not change the Call APIs themselves:
    they remain callable. This test exercises the callbacks
    directly, so it does not require a LingoFuse mesh.
    """

    def setUp(self):
        _reset_bridge_globals(clear_callbacks=False)

    def tearDown(self):
        _reset_bridge_globals(clear_callbacks=False)

    def test_post_api_is_callable(self):
        resp = mock.Mock()
        resp.status_code = 200
        resp.headers = {"Content-Type": "application/json"}
        resp.json.return_value = {"ok": True}

        with mock.patch(
            "lingofuse.bridge.requests.request"
        ) as mocked:
            mocked.return_value = resp
            h_in = _make_bridge_call_handle(
                bridge_module.config.bridge_api_name,
                {"url": "http://example.com/"},
            )
            h_out = DataHandle("result")
            try:
                _bridge_post_callback(None, h_in.raw, h_out.raw)
                result = _read_bridge_call_result(h_out)
            finally:
                h_in.free()
                h_out.free()

        self.assertEqual(result["status_code"], 200)
        self.assertEqual(result["body"], {"ok": True})

    def test_repair_api_is_callable(self):
        h_in = DataHandle("__lf_repair_json__")
        write_string_bytes(h_in.raw, b'{"a": 1,}')
        h_in.set_pos(0)
        h_out = DataHandle("result")
        try:
            _bridge_repair_callback(None, h_in.raw, h_out.raw)
            h_out.set_pos(0)
            result = read_string_bytes(h_out.raw)
        finally:
            h_in.free()
            h_out.free()
        self.assertEqual(json.loads(result.decode("utf-8")), {"a": 1})


# ======================================================================
# Configuration loading
# ======================================================================

class TestConfigEnvironment(unittest.TestCase):
    """_apply_environment_defaults: every env var, precedence rules."""

    def setUp(self):
        _reset_bridge_globals(clear_callbacks=False)

    def tearDown(self):
        _reset_bridge_globals(clear_callbacks=False)

    def _run_with_env(self, env):
        cfg = BridgeConfig()
        with mock.patch.dict(os.environ, env, clear=False):
            _apply_environment_defaults(cfg)
        return cfg

    def test_host_and_port(self):
        cfg = self._run_with_env(
            {"LINGOFUSE_HOST": "127.0.0.1", "LINGOFUSE_PORT": "9090"}
        )
        self.assertEqual(cfg.host, "127.0.0.1")
        self.assertEqual(cfg.port, 9090)

    def test_endpoint(self):
        cfg = self._run_with_env(
            {"LINGOFUSE_ENDPOINT": "ipc:my_test"}
        )
        self.assertEqual(cfg.endpoint, "ipc:my_test")

    def test_timeout(self):
        cfg = self._run_with_env({"LINGOFUSE_TIMEOUT": "1234"})
        self.assertEqual(cfg.timeout_ms, 1234)

    def test_app_unset_leaves_none(self):
        cfg = self._run_with_env({})
        self.assertIsNone(cfg.default_app)

    def test_app_set_to_string(self):
        cfg = self._run_with_env({"LINGOFUSE_APP": "MyApp"})
        self.assertEqual(cfg.default_app, "MyApp")

    def test_app_set_to_empty_string_becomes_none(self):
        cfg = self._run_with_env({"LINGOFUSE_APP": ""})
        self.assertIsNone(cfg.default_app)

    def test_boolean_flags(self):
        cfg = self._run_with_env(
            {
                "LINGOFUSE_THREADED": "false",
                "LINGOFUSE_FORWARD_ONLY": "1",
                "LINGOFUSE_WAIT_CONNECTION": "yes",
                "LINGOFUSE_DEBUG": "on",
                "LINGOFUSE_NO_PRECHECK": "True",
                "LINGOFUSE_NORMALIZE_JSON": "0",
            }
        )
        self.assertFalse(cfg.threaded)
        self.assertTrue(cfg.forward_only)
        self.assertTrue(cfg.wait_connection)
        self.assertTrue(cfg.debug)
        self.assertTrue(cfg.no_precheck)
        self.assertFalse(cfg.normalize_json)

    def test_wait_timeout(self):
        cfg = self._run_with_env({"LINGOFUSE_WAIT_TIMEOUT": "5000"})
        self.assertEqual(cfg.wait_timeout_ms, 5000)

    def test_log_file_empty_becomes_none(self):
        cfg = self._run_with_env({"LINGOFUSE_LOG_FILE": ""})
        self.assertIsNone(cfg.log_file)

    def test_log_file_set(self):
        cfg = self._run_with_env({"LINGOFUSE_LOG_FILE": "/tmp/x.log"})
        self.assertEqual(cfg.log_file, "/tmp/x.log")

    def test_bridge_names(self):
        cfg = self._run_with_env(
            {
                "LINGOFUSE_BRIDGE_APP": "my_bridge",
                "LINGOFUSE_BRIDGE_API": "my_post",
                "LINGOFUSE_BRIDGE_REPAIR_API": "my_repair",
            }
        )
        self.assertEqual(cfg.bridge_app_name, "my_bridge")
        self.assertEqual(cfg.bridge_api_name, "my_post")
        self.assertEqual(cfg.bridge_repair_api_name, "my_repair")

    def test_bridge_names_empty_fall_back_to_default(self):
        cfg = self._run_with_env(
            {
                "LINGOFUSE_BRIDGE_APP": "",
                "LINGOFUSE_BRIDGE_API": "",
                "LINGOFUSE_BRIDGE_REPAIR_API": "",
            }
        )
        self.assertEqual(
            cfg.bridge_app_name, bridge_module.DEFAULT_BRIDGE_APP_NAME
        )
        self.assertEqual(
            cfg.bridge_api_name, bridge_module.DEFAULT_BRIDGE_API_NAME
        )
        self.assertEqual(
            cfg.bridge_repair_api_name,
            bridge_module.DEFAULT_BRIDGE_REPAIR_API_NAME,
        )

    def test_malformed_int_falls_back_to_default(self):
        cfg = self._run_with_env({"LINGOFUSE_PORT": "not-a-number"})
        self.assertEqual(cfg.port, bridge_module.DEFAULT_PORT)

    def test_malformed_bool_falls_back_to_default(self):
        cfg = self._run_with_env({"LINGOFUSE_THREADED": "maybe"})
        self.assertEqual(cfg.threaded, bridge_module.DEFAULT_THREADED)


class TestConfigCommandLine(unittest.TestCase):
    """_apply_command_line: parsing and precedence over environment."""

    def setUp(self):
        _reset_bridge_globals(clear_callbacks=False)

    def tearDown(self):
        _reset_bridge_globals(clear_callbacks=False)

    def _run_with_argv(self, argv, base_env=None):
        cfg = BridgeConfig()
        if base_env:
            with mock.patch.dict(os.environ, base_env, clear=False):
                _apply_environment_defaults(cfg)
        _apply_command_line(cfg, argv)
        return cfg

    def test_host_port_override(self):
        cfg = self._run_with_argv(
            ["--host", "0.0.0.0", "--port", "1234"]
        )
        self.assertEqual(cfg.host, "0.0.0.0")
        self.assertEqual(cfg.port, 1234)

    def test_cli_overrides_env(self):
        cfg = self._run_with_argv(
            ["--host", "cli-host"],
            base_env={"LINGOFUSE_HOST": "env-host"},
        )
        self.assertEqual(cfg.host, "cli-host")

    def test_forward_only_flag(self):
        cfg = self._run_with_argv(["--forward-only"])
        self.assertTrue(cfg.forward_only)

    def test_no_forward_only_flag(self):
        cfg = self._run_with_argv(
            ["--no-forward-only"],
            base_env={"LINGOFUSE_FORWARD_ONLY": "1"},
        )
        self.assertFalse(cfg.forward_only)

    def test_endpoint_timeout_app(self):
        cfg = self._run_with_argv(
            [
                "--endpoint", "ipc:x",
                "--timeout", "777",
                "--app", "MyApp",
            ]
        )
        self.assertEqual(cfg.endpoint, "ipc:x")
        self.assertEqual(cfg.timeout_ms, 777)
        self.assertEqual(cfg.default_app, "MyApp")

    def test_app_empty_string_becomes_none(self):
        cfg = self._run_with_argv(["--app", ""])
        self.assertIsNone(cfg.default_app)

    def test_wait_connection_flags(self):
        cfg = self._run_with_argv(["--no-wait-connection"])
        self.assertFalse(cfg.wait_connection)
        cfg = self._run_with_argv(["--wait-connection"])
        self.assertTrue(cfg.wait_connection)

    def test_wait_timeout(self):
        cfg = self._run_with_argv(["--wait-timeout", "500"])
        self.assertEqual(cfg.wait_timeout_ms, 500)

    def test_threaded_flags(self):
        cfg = self._run_with_argv(["--no-threaded"])
        self.assertFalse(cfg.threaded)

    def test_debug_flags(self):
        cfg = self._run_with_argv(["--debug"])
        self.assertTrue(cfg.debug)

    def test_normalize_json_flags(self):
        cfg = self._run_with_argv(["--no-normalize-json"])
        self.assertFalse(cfg.normalize_json)

    def test_no_precheck_flags(self):
        cfg = self._run_with_argv(["--no-precheck"])
        self.assertTrue(cfg.no_precheck)
        cfg = self._run_with_argv(["--precheck"])
        self.assertFalse(cfg.no_precheck)

    def test_bridge_names(self):
        cfg = self._run_with_argv(
            [
                "--bridge-app", "ba",
                "--bridge-api", "bp",
                "--bridge-repair-api", "br",
            ]
        )
        self.assertEqual(cfg.bridge_app_name, "ba")
        self.assertEqual(cfg.bridge_api_name, "bp")
        self.assertEqual(cfg.bridge_repair_api_name, "br")

    def test_log_file(self):
        cfg = self._run_with_argv(["--log-file", "/tmp/y.log"])
        self.assertEqual(cfg.log_file, "/tmp/y.log")

    def test_log_file_empty_becomes_none(self):
        cfg = self._run_with_argv(["--log-file", ""])
        self.assertIsNone(cfg.log_file)


# ======================================================================
# Entry point
# ======================================================================

if __name__ == "__main__":
    unittest.main()