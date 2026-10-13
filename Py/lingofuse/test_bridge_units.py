# -*- coding: utf-8 -*-
"""
Unit tests for lingofuse.bridge.

This file covers the L1 (pure unit) layer of the bridge test
strategy: every internal function that is stateless and can be
exercised without a live LingoFuse network, without a real HTTP
listener, and without calling LF_PrepareDone / LF_ExitMainThread.

Coverage
--------

* ``normalize_json_bytes`` -- the inbound payload transformation.
  Every status the function can return (passthrough / canonical /
  recoded / repaired), every encoding fallback (UTF-8 / GBK /
  Latin-1), the BOM handling (UTF-8 stripped, UTF-16 passthrough),
  the trailing-NUL handling, the two-layer repair stack, and
  idempotence.

* ``_try_repair_json`` -- Layer 1 of the repair stack: the
  conservative, in-module repairs.

* ``_decode_text_with_fallback`` -- the encoding fallback chain.

* ``_parse_inbound_path`` -- the URL grammar for the three
  addressing modes and the reserved leading segments.

* ``_parse_outbound_request`` -- validation of the JSON request
  object sent to ``__lf_outbound_post__``.

* ``_normalize_headers_dict`` -- case-insensitive header
  normalization.

* ``_json_error_response`` -- the JSON error envelope, exercised
  through Flask's test client (which does NOT open a socket).

* ``BridgeConfig`` -- default values and field contract.

* ``_ENV_VAR_TABLE`` -- environment-variable name mapping
  completeness.

What this file deliberately does NOT cover
------------------------------------------

* ``_setup_network`` and the lifecycle methods (``cleanup``).
  Those require a live LingoFuse connection and are covered by
  ``test_bridge_integration.py``.

* ``_bridge_post_callback`` and ``_bridge_repair_callback``. Those
  require a real DataHandle and are covered by the integration
  layer.

* The inbound ``handle_call`` handler. That needs a real DataHandle
  for the LingoFuse call and is likewise covered by the integration
  layer.

Environment
-----------

Importing ``lingofuse.bridge`` loads the LingoFuse shared library
(because ``bridge.py`` imports from the ``lingofuse`` package, whose
``__init__`` loads the DLL at import time). That load is the same
prerequisite every test file in this suite has. Beyond that load,
this file does not touch the native library: no DataHandle is
created, no call is made, no network is started.

All comments and status output are in English.
"""

import json
import logging
import os
import sys
import unittest

# Ensure the parent directory is importable when running from the
# repository root, matching the convention used by the other test
# files in this package.
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

# Silence the repair preprocessor so that expected WARNINGs from the
# repaired paths do not pollute the test output. The policy under
# test is the returned bytes and the returned status, not the log.
logging.getLogger("lingofuse.json_repair_preprocess").setLevel(
    logging.CRITICAL
)

from lingofuse import bridge as bridge_module
from lingofuse.bridge import (
    ALLOWED_HTTP_METHODS,
    BridgeConfig,
    DEFAULT_BRIDGE_API_NAME,
    DEFAULT_BRIDGE_APP_NAME,
    DEFAULT_BRIDGE_REPAIR_API_NAME,
    DEFAULT_ENDPOINT,
    DEFAULT_FORWARD_ONLY,
    DEFAULT_HOST,
    DEFAULT_NORMALIZE_JSON,
    DEFAULT_PORT,
    DEFAULT_THREADED,
    DEFAULT_TIMEOUT_MS,
    DEFAULT_WAIT_CONNECTION,
    DEFAULT_WAIT_TIMEOUT_MS,
    MAX_OUTBOUND_TIMEOUT_S,
    RESERVED_PREFIX_P2P,
    RESERVED_PREFIX_UID,
    STATUS_CANONICAL,
    STATUS_PASSTHROUGH,
    STATUS_RECODED,
    STATUS_REPAIRED,
    _ENV_VAR_TABLE,
    _decode_text_with_fallback,
    _json_error_response,
    _normalize_headers_dict,
    _parse_inbound_path,
    _parse_outbound_request,
    _try_repair_json,
    normalize_json_bytes,
)


# ======================================================================
# Helpers
# ======================================================================

def _is_valid_utf8_json(raw: bytes) -> bool:
    """Return True if ``raw`` decodes to valid JSON over UTF-8."""
    try:
        json.loads(raw.decode("utf-8"))
        return True
    except (UnicodeDecodeError, json.JSONDecodeError):
        return False


# ======================================================================
# normalize_json_bytes: status classification
# ======================================================================

class TestNormalizeJsonBytesStatuses(unittest.TestCase):
    """
    Every return status the inbound normalizer can produce.

    The status is informational (the caller decides what to do with
    it) but it is a stable part of the module's contract and is
    therefore worth pinning down explicitly.
    """

    def test_empty_payload_is_passthrough(self):
        result, status = normalize_json_bytes(b"")
        self.assertEqual(result, b"")
        self.assertEqual(status, STATUS_PASSTHROUGH)

    def test_whitespace_only_is_passthrough(self):
        """
        Whitespace is valid UTF-8 but not JSON. The repair engine
        cannot turn it into JSON, so the original bytes are returned
        unchanged.
        """
        payload = b"   "
        result, status = normalize_json_bytes(payload)
        self.assertEqual(result, payload)
        self.assertEqual(status, STATUS_PASSTHROUGH)

    def test_canonical_utf8_json(self):
        payload = b'{"a": 1}'
        result, status = normalize_json_bytes(payload)
        # The output is re-serialized through dumps_json, so
        # whitespace may differ from the input. What matters is
        # that it is valid UTF-8 JSON and semantically equal.
        self.assertEqual(json.loads(result.decode("utf-8")), {"a": 1})
        self.assertEqual(status, STATUS_CANONICAL)

    def test_non_ascii_canonical_utf8_json(self):
        """Non-ASCII content must be preserved literally (not escaped)."""
        payload = '{"name": "\u4f60\u597d"}'.encode("utf-8")
        result, status = normalize_json_bytes(payload)
        # The canonical policy is ensure_ascii=False, so the output
        # must contain the literal characters, not \\uXXXX escapes.
        text = result.decode("utf-8")
        self.assertIn("\u4f60\u597d", text)
        self.assertNotIn("\\u4f60", text)
        self.assertEqual(status, STATUS_CANONICAL)

    def test_gbk_payload_is_recoded(self):
        """GBK-encoded JSON must be decoded and re-emitted as UTF-8."""
        gbk_bytes = '{"name": "\u4f60\u597d"}'.encode("gbk")
        result, status = normalize_json_bytes(gbk_bytes)
        self.assertEqual(status, STATUS_RECODED)
        self.assertEqual(
            json.loads(result.decode("utf-8")),
            {"name": "\u4f60\u597d"},
        )

    def test_trailing_comma_is_repaired(self):
        payload = b'{"a": 1,}'
        result, status = normalize_json_bytes(payload)
        self.assertEqual(status, STATUS_REPAIRED)
        self.assertEqual(json.loads(result.decode("utf-8")), {"a": 1})

    def test_single_quoted_json_is_repaired(self):
        payload = b"{'a': 1}"
        result, status = normalize_json_bytes(payload)
        self.assertEqual(status, STATUS_REPAIRED)
        self.assertEqual(json.loads(result.decode("utf-8")), {"a": 1})

    def test_binary_payload_is_passthrough(self):
        """A PNG signature is not JSON and must be forwarded unchanged."""
        payload = b"\x89PNG\r\n\x1a\n"
        result, status = normalize_json_bytes(payload)
        self.assertEqual(result, payload)
        self.assertEqual(status, STATUS_PASSTHROUGH)

    def test_trailing_comma_with_whitespace_is_repaired(self):
        """
        A trailing comma followed by whitespace must be repaired at
        the ``normalize_json_bytes`` level. Layer 1 alone leaves the
        whitespace in place, but the subsequent re-serialization
        through ``dumps_json`` produces the canonical compact form.
        """
        result, status = normalize_json_bytes(b'{"a": 1,   }')
        self.assertEqual(status, STATUS_REPAIRED)
        self.assertEqual(result, b'{"a": 1}')

# ======================================================================
# normalize_json_bytes: BOM and NUL handling
# ======================================================================

class TestNormalizeJsonBytesFraming(unittest.TestCase):
    """BOM stripping and trailing-NUL stripping."""

    def test_utf8_bom_is_stripped(self):
        payload = b"\xef\xbb\xbf" + b'{"a": 1}'
        result, status = normalize_json_bytes(payload)
        self.assertEqual(json.loads(result.decode("utf-8")), {"a": 1})
        self.assertNotEqual(status, STATUS_PASSTHROUGH)

    def test_utf16_le_bom_is_passthrough(self):
        """
        A UTF-16 BOM signals UTF-16 content. The bridge does not
        attempt to guess endianness on a payload that may be binary,
        so it forwards the bytes unchanged.
        """
        payload = b"\xff\xfe" + "hello".encode("utf-16-le")
        result, status = normalize_json_bytes(payload)
        self.assertEqual(result, payload)
        self.assertEqual(status, STATUS_PASSTHROUGH)

    def test_utf16_be_bom_is_passthrough(self):
        payload = b"\xfe\xff" + "hello".encode("utf-16-be")
        result, status = normalize_json_bytes(payload)
        self.assertEqual(result, payload)
        self.assertEqual(status, STATUS_PASSTHROUGH)

    def test_trailing_nul_is_stripped(self):
        """
        A payload produced by a NUL-terminating writer must be
        normalized as if the trailing NUL were absent.
        """
        payload = b'{"a": 1}\x00'
        result, status = normalize_json_bytes(payload)
        self.assertEqual(json.loads(result.decode("utf-8")), {"a": 1})
        self.assertNotEqual(status, STATUS_PASSTHROUGH)

    def test_multiple_trailing_nuls_are_stripped(self):
        payload = b'{"a": 1}\x00\x00\x00'
        result, status = normalize_json_bytes(payload)
        self.assertEqual(json.loads(result.decode("utf-8")), {"a": 1})
        self.assertNotEqual(status, STATUS_PASSTHROUGH)

    def test_all_nuls_is_passthrough(self):
        payload = b"\x00\x00\x00"
        result, status = normalize_json_bytes(payload)
        self.assertEqual(result, payload)
        self.assertEqual(status, STATUS_PASSTHROUGH)

    def test_bom_only_is_passthrough(self):
        payload = b"\xef\xbb\xbf"
        result, status = normalize_json_bytes(payload)
        self.assertEqual(result, payload)
        self.assertEqual(status, STATUS_PASSTHROUGH)


# ======================================================================
# normalize_json_bytes: idempotence and canonical policy
# ======================================================================

class TestNormalizeJsonBytesIdempotence(unittest.TestCase):
    """Applying the normalizer twice must be equivalent to once."""

    def test_canonical_is_idempotent(self):
        payload = b'{"a": 1}'
        first, _ = normalize_json_bytes(payload)
        second, status = normalize_json_bytes(first)
        self.assertEqual(first, second)
        self.assertEqual(status, STATUS_CANONICAL)

    def test_repaired_is_idempotent(self):
        payload = b'{"a": 1,}'
        first, _ = normalize_json_bytes(payload)
        second, status = normalize_json_bytes(first)
        self.assertEqual(first, second)
        self.assertEqual(status, STATUS_CANONICAL)

    def test_passthrough_is_idempotent(self):
        payload = b"\x89PNG\r\n\x1a\n"
        first, status1 = normalize_json_bytes(payload)
        second, status2 = normalize_json_bytes(first)
        self.assertEqual(first, second)
        self.assertEqual(status1, status2)

    def test_canonical_output_has_no_u_escapes(self):
        """
        The toolchain-wide policy is ensure_ascii=False. Confirm that
        the canonical output never contains a \\uXXXX escape for a
        character that can be emitted literally.
        """
        payload = '{"emoji": "\U0001F30D"}'.encode("utf-8")
        result, _ = normalize_json_bytes(payload)
        text = result.decode("utf-8")
        self.assertIn("\U0001F30D", text)
        self.assertNotIn("\\ud83c", text.lower())


# ======================================================================
# _try_repair_json (Layer 1)
# ======================================================================

class TestTryRepairJson(unittest.TestCase):
    """Layer 1 of the repair stack: conservative, in-module repairs."""

    def test_empty_string_returns_none(self):
        self.assertIsNone(_try_repair_json(""))

    def test_whitespace_only_returns_none(self):
        self.assertIsNone(_try_repair_json("   "))

    def test_non_json_starting_char_returns_none(self):
        """
        The first non-whitespace character must be a JSON value
        token. Anything else (``x``, ``@``, etc.) is rejected so
        that the more aggressive Layer 2 is not invoked on obvious
        non-JSON.
        """
        self.assertIsNone(_try_repair_json("x"))
        self.assertIsNone(_try_repair_json("@"))
        self.assertIsNone(_try_repair_json("hello world"))

    def test_stray_unicode_bom_is_stripped(self):
        repaired = _try_repair_json('\ufeff{"a": 1}')
        self.assertIsNotNone(repaired)
        self.assertFalse(repaired.startswith("\ufeff"))

    def test_trailing_comma_in_object(self):
        repaired = _try_repair_json('{"a": 1,}')
        self.assertEqual(repaired, '{"a": 1}')

    def test_trailing_comma_in_array(self):
        repaired = _try_repair_json('[1, 2, 3,]')
        self.assertEqual(repaired, '[1, 2, 3]')

    def test_trailing_comma_with_whitespace(self):
        """
        Layer 1 removes the comma but preserves any whitespace that
        stood between the comma and the closing delimiter. Whitespace
        normalization is NOT part of Layer 1's job; it happens later,
        when the caller re-serializes through ``dumps_json``. This
        test pins that division of responsibility.
        """
        repaired = _try_repair_json('{"a": 1,   }')
        self.assertEqual(repaired, '{"a": 1   }')
        # The repaired text must still be parseable; that is the
        # property that actually matters for Layer 1's contract.
        self.assertEqual(json.loads(repaired), {"a": 1})

    def test_no_repair_needed_returns_original_stripped(self):
        """
        When no repair is applicable but the input is well-formed,
        Layer 1 returns the stripped text. It does NOT itself parse
        the JSON; that is the caller's job.
        """
        repaired = _try_repair_json('  {"a": 1}  ')
        self.assertEqual(repaired, '{"a": 1}')

    def test_does_not_touch_single_quotes(self):
        """
        Single-quoted JSON is a Layer 2 repair, not a Layer 1
        repair. Layer 1 must leave it alone.
        """
        repaired = _try_repair_json("{'a': 1}")
        self.assertEqual(repaired, "{'a': 1}")


# ======================================================================
# _decode_text_with_fallback
# ======================================================================

class TestDecodeTextWithFallback(unittest.TestCase):
    """The encoding fallback chain: UTF-8 -> GBK -> Latin-1."""

    def test_ascii_uses_utf8(self):
        text, enc = _decode_text_with_fallback(b"hello")
        self.assertEqual(text, "hello")
        self.assertEqual(enc, "utf-8")

    def test_utf8_non_ascii(self):
        raw = "\u4f60\u597d".encode("utf-8")
        text, enc = _decode_text_with_fallback(raw)
        self.assertEqual(text, "\u4f60\u597d")
        self.assertEqual(enc, "utf-8")

    def test_gbk_bytes_fall_back_to_gbk(self):
        raw = "\u4f60\u597d".encode("gbk")
        text, enc = _decode_text_with_fallback(raw)
        self.assertEqual(text, "\u4f60\u597d")
        self.assertEqual(enc, "gbk")

    def test_arbitrary_bytes_fall_back_to_latin1(self):
        """
        Latin-1 accepts every byte sequence, so the fallback chain
        never fails. The result may be meaningless text, but it is
        always decodable.
        """
        raw = b"\xff\xfe\xfd"
        text, enc = _decode_text_with_fallback(raw)
        self.assertIsNotNone(text)
        self.assertEqual(enc, "latin-1")

    def test_empty_bytes(self):
        text, enc = _decode_text_with_fallback(b"")
        self.assertEqual(text, "")
        self.assertEqual(enc, "utf-8")


# ======================================================================
# _parse_inbound_path
# ======================================================================

class TestParseInboundPath(unittest.TestCase):
    """URL grammar: three addressing modes plus reserved segments."""

    # ---- App-name addressing ----

    def test_app_and_api(self):
        mode, key, api = _parse_inbound_path("MyApp/add")
        self.assertEqual(mode, "app")
        self.assertEqual(key, "MyApp")
        self.assertEqual(api, "add")

    def test_api_only(self):
        mode, key, api = _parse_inbound_path("add")
        self.assertEqual(mode, "app")
        self.assertIsNone(key)
        self.assertEqual(api, "add")

    def test_app_and_nested_api(self):
        """
        The API name may itself contain slashes. Only the first
        segment is treated as the App name.
        """
        mode, key, api = _parse_inbound_path("MyApp/a/b/c")
        self.assertEqual(mode, "app")
        self.assertEqual(key, "MyApp")
        self.assertEqual(api, "a/b/c")

    def test_leading_and_trailing_slashes_are_tolerated(self):
        mode, key, api = _parse_inbound_path("/MyApp/add/")
        self.assertEqual(mode, "app")
        self.assertEqual(key, "MyApp")
        self.assertEqual(api, "add")

    def test_empty_path_raises(self):
        with self.assertRaises(ValueError):
            _parse_inbound_path("")

    def test_only_slashes_raises(self):
        with self.assertRaises(ValueError):
            _parse_inbound_path("///")

    # ---- UID addressing ----

    def test_uid_route(self):
        hex64 = "ab" * 32
        mode, key, api = _parse_inbound_path(f"uid/{hex64}/whoami")
        self.assertEqual(mode, "uid")
        self.assertIsInstance(key, bytes)
        self.assertEqual(len(key), 32)
        self.assertEqual(api, "whoami")

    def test_uid_route_with_uppercase_hex(self):
        hex64 = ("AB" * 32)
        mode, key, api = _parse_inbound_path(f"uid/{hex64}/whoami")
        self.assertEqual(mode, "uid")
        self.assertEqual(len(key), 32)

    def test_uid_route_short_hex_raises(self):
        with self.assertRaises(ValueError):
            _parse_inbound_path("uid/abcd/whoami")

    def test_uid_route_non_hex_raises(self):
        with self.assertRaises(ValueError):
            _parse_inbound_path("uid/" + "zz" * 32 + "/whoami")

    def test_uid_route_missing_api_raises(self):
        hex64 = "ab" * 32
        with self.assertRaises(ValueError):
            _parse_inbound_path(f"uid/{hex64}")

    def test_uid_reserved_prefix_is_literal(self):
        """
        An App whose name is literally ``uid`` cannot be reached
        through the App-name route, because ``uid`` always selects
        UID addressing. This is documented as a deliberate
        trade-off.
        """
        self.assertEqual(RESERVED_PREFIX_UID, "uid")

    # ---- P2PName addressing ----

    def test_p2p_route(self):
        mode, key, api = _parse_inbound_path("p2p/workers/process")
        self.assertEqual(mode, "p2p")
        self.assertEqual(key, "workers")
        self.assertEqual(api, "process")

    def test_p2p_route_missing_api_raises(self):
        with self.assertRaises(ValueError):
            _parse_inbound_path("p2p/workers")

    def test_p2p_route_empty_group_raises(self):
        with self.assertRaises(ValueError):
            _parse_inbound_path("p2p//process")

    def test_p2p_route_empty_api_raises(self):
        with self.assertRaises(ValueError):
            _parse_inbound_path("p2p/workers/")

    def test_p2p_reserved_prefix_is_literal(self):
        self.assertEqual(RESERVED_PREFIX_P2P, "p2p")


# ======================================================================
# _parse_outbound_request
# ======================================================================

class TestParseOutboundRequest(unittest.TestCase):
    """Validation of the JSON request object for __lf_outbound_post__."""

    def test_none_returns_error(self):
        parsed, err = _parse_outbound_request(None)
        self.assertIsNone(parsed)
        self.assertIsNotNone(err)

    def test_non_dict_returns_error(self):
        parsed, err = _parse_outbound_request("not a dict")
        self.assertIsNone(parsed)
        self.assertIsNotNone(err)

    def test_missing_url_returns_error(self):
        parsed, err = _parse_outbound_request({"method": "GET"})
        self.assertIsNone(parsed)
        self.assertIn("url", err.lower())

    def test_non_string_url_returns_error(self):
        parsed, err = _parse_outbound_request({"url": 123})
        self.assertIsNone(parsed)
        self.assertIn("url", err.lower())

    def test_minimal_request_succeeds(self):
        parsed, err = _parse_outbound_request(
            {"url": "http://example.com/api"}
        )
        self.assertIsNone(err)
        self.assertEqual(parsed["url"], "http://example.com/api")
        self.assertEqual(parsed["method"], "POST")
        self.assertEqual(parsed["headers"], {})
        self.assertIsNone(parsed["body"])
        self.assertIsNone(parsed["timeout"])

    def test_method_is_uppercased(self):
        parsed, err = _parse_outbound_request(
            {"url": "http://x", "method": "get"}
        )
        self.assertIsNone(err)
        self.assertEqual(parsed["method"], "GET")

    def test_unsupported_method_returns_error(self):
        parsed, err = _parse_outbound_request(
            {"url": "http://x", "method": "INVALID"}
        )
        self.assertIsNone(parsed)
        self.assertIn("method", err.lower())

    def test_all_allowed_methods_accepted(self):
        for method in sorted(ALLOWED_HTTP_METHODS):
            parsed, err = _parse_outbound_request(
                {"url": "http://x", "method": method}
            )
            self.assertIsNone(err, f"method {method!r} was rejected")

    def test_headers_none_becomes_empty_dict(self):
        parsed, err = _parse_outbound_request(
            {"url": "http://x", "headers": None}
        )
        self.assertIsNone(err)
        self.assertEqual(parsed["headers"], {})

    def test_headers_non_dict_returns_error(self):
        parsed, err = _parse_outbound_request(
            {"url": "http://x", "headers": "not a dict"}
        )
        self.assertIsNone(parsed)
        self.assertIn("headers", err.lower())

    def test_timeout_negative_returns_error(self):
        parsed, err = _parse_outbound_request(
            {"url": "http://x", "timeout": -1}
        )
        self.assertIsNone(parsed)
        self.assertIn("timeout", err.lower())

    def test_timeout_zero_returns_error(self):
        parsed, err = _parse_outbound_request(
            {"url": "http://x", "timeout": 0}
        )
        self.assertIsNone(parsed)
        self.assertIn("timeout", err.lower())

    def test_timeout_is_clamped_to_max(self):
        parsed, err = _parse_outbound_request(
            {"url": "http://x", "timeout": MAX_OUTBOUND_TIMEOUT_S + 1000}
        )
        self.assertIsNone(err)
        self.assertEqual(parsed["timeout"], MAX_OUTBOUND_TIMEOUT_S)

    def test_timeout_float_is_accepted(self):
        parsed, err = _parse_outbound_request(
            {"url": "http://x", "timeout": 2.5}
        )
        self.assertIsNone(err)
        self.assertEqual(parsed["timeout"], 2.5)

    def test_body_is_passed_through_verbatim(self):
        body = {"any": ["json", "structure"]}
        parsed, err = _parse_outbound_request(
            {"url": "http://x", "body": body}
        )
        self.assertIsNone(err)
        self.assertEqual(parsed["body"], body)


# ======================================================================
# _normalize_headers_dict
# ======================================================================

class TestNormalizeHeadersDict(unittest.TestCase):
    """Case-insensitive header normalization."""

    def test_none_becomes_empty_dict(self):
        self.assertEqual(_normalize_headers_dict(None), {})

    def test_plain_dict_lowercases_keys(self):
        result = _normalize_headers_dict(
            {"Content-Type": "application/json", "X-Foo": "Bar"}
        )
        self.assertEqual(
            result,
            {"content-type": "application/json", "x-foo": "Bar"},
        )

    def test_values_are_stringified(self):
        result = _normalize_headers_dict({"X-Num": 42})
        self.assertEqual(result["x-num"], "42")

    def test_non_mapping_falls_back_to_raw(self):
        """
        An object without an ``items()`` method is wrapped under a
        single ``_raw`` key rather than crashing.
        """
        result = _normalize_headers_dict(42)
        self.assertIn("_raw", result)


# ======================================================================
# _json_error_response
# ======================================================================

class TestJsonErrorResponse(unittest.TestCase):
    """
    The JSON error envelope.

    Exercised through Flask's test client, which does NOT open a
    socket. The response body must be canonical UTF-8 JSON with no
    \\uXXXX escapes.
    """

    def setUp(self):
        # Use the module-level Flask app directly. No network setup.
        self.client = bridge_module.app.test_client()

    def _call_with_cleanup(self, code, msg, http_status=200):
        """
        Flask's test client can be used with a context manager to
        ensure the response body is fully consumed.
        """
        with bridge_module.app.test_request_context("/"):
            response = _json_error_response(code, msg, http_status)
            # Materialise the body.
            body = response.get_data()
            return response.status_code, body

    def test_error_code_is_negative_int(self):
        status, body = self._call_with_cleanup(-1, "boom")
        self.assertEqual(status, 200)
        parsed = json.loads(body.decode("utf-8"))
        self.assertEqual(parsed["code"], -1)
        self.assertEqual(parsed["error"], "boom")

    def test_error_code_2_uses_http_400(self):
        status, body = self._call_with_cleanup(-2, "bad request", 400)
        self.assertEqual(status, 400)

    def test_error_code_3_uses_http_200(self):
        status, body = self._call_with_cleanup(-3, "precheck failed", 200)
        self.assertEqual(status, 200)
        parsed = json.loads(body.decode("utf-8"))
        self.assertEqual(parsed["code"], -3)

    def test_body_is_valid_utf8_json(self):
        _, body = self._call_with_cleanup(-1, "boom")
        # Must decode as UTF-8 and parse as JSON.
        parsed = json.loads(body.decode("utf-8"))
        self.assertIn("code", parsed)
        self.assertIn("error", parsed)

    def test_non_ascii_error_message_is_literal(self):
        _, body = self._call_with_cleanup(-1, "failure: \u4f60\u597d")
        text = body.decode("utf-8")
        # No \uXXXX escapes for characters that can be literal.
        self.assertNotIn("\\u4f60", text)
        self.assertIn("\u4f60\u597d", text)


# ======================================================================
# BridgeConfig and constants
# ======================================================================

class TestBridgeConfig(unittest.TestCase):
    """The BridgeConfig dataclass and its default values."""

    def test_defaults_match_module_constants(self):
        cfg = BridgeConfig()
        self.assertEqual(cfg.host, DEFAULT_HOST)
        self.assertEqual(cfg.port, DEFAULT_PORT)
        self.assertEqual(cfg.threaded, DEFAULT_THREADED)
        self.assertEqual(cfg.forward_only, DEFAULT_FORWARD_ONLY)
        self.assertEqual(cfg.endpoint, DEFAULT_ENDPOINT)
        self.assertEqual(cfg.timeout_ms, DEFAULT_TIMEOUT_MS)
        self.assertEqual(cfg.wait_connection, DEFAULT_WAIT_CONNECTION)
        self.assertEqual(cfg.wait_timeout_ms, DEFAULT_WAIT_TIMEOUT_MS)
        self.assertEqual(cfg.normalize_json, DEFAULT_NORMALIZE_JSON)
        self.assertEqual(cfg.bridge_app_name, DEFAULT_BRIDGE_APP_NAME)
        self.assertEqual(cfg.bridge_api_name, DEFAULT_BRIDGE_API_NAME)
        self.assertEqual(
            cfg.bridge_repair_api_name,
            DEFAULT_BRIDGE_REPAIR_API_NAME,
        )

    def test_default_app_is_none(self):
        self.assertIsNone(BridgeConfig().default_app)

    def test_default_log_file_is_none(self):
        self.assertIsNone(BridgeConfig().log_file)

    def test_reserved_names_do_not_collide_with_bridge_app(self):
        """
        The bridge's own App name uses a double-underscore prefix
        and suffix, so it can never collide with the reserved URL
        segments ``uid`` / ``p2p``.
        """
        self.assertNotEqual(DEFAULT_BRIDGE_APP_NAME, RESERVED_PREFIX_UID)
        self.assertNotEqual(DEFAULT_BRIDGE_APP_NAME, RESERVED_PREFIX_P2P)
        self.assertTrue(DEFAULT_BRIDGE_APP_NAME.startswith("__"))
        self.assertTrue(DEFAULT_BRIDGE_APP_NAME.endswith("__"))

    def test_allowed_methods_are_uppercase_strings(self):
        for method in ALLOWED_HTTP_METHODS:
            self.assertEqual(method, method.upper())
            self.assertIsInstance(method, str)

    def test_default_endpoint_uses_ipc_scheme(self):
        self.assertTrue(DEFAULT_ENDPOINT.startswith("ipc:"))


class TestEnvVarTable(unittest.TestCase):
    """
    The environment-variable mapping.

    Its completeness matters because ``_apply_environment_defaults``
    is the ONLY reader of ``os.environ`` in the module. A field that
    is missing from the table silently loses its environment
    support.
    """

    def test_every_config_field_has_an_env_var_except_debug(self):
        """
        Every BridgeConfig field except ``debug`` (which is derived
        from a boolean env var named LINGOFUSE_DEBUG) should have
        an entry. We check the full expected key set here.
        """
        expected_keys = {
            "host",
            "port",
            "endpoint",
            "timeout_ms",
            "default_app",
            "threaded",
            "forward_only",
            "wait_connection",
            "wait_timeout_ms",
            "debug",
            "no_precheck",
            "normalize_json",
            "log_file",
            "bridge_app_name",
            "bridge_api_name",
            "bridge_repair_api_name",
        }
        self.assertEqual(set(_ENV_VAR_TABLE.keys()), expected_keys)

    def test_env_var_names_use_lingofuse_prefix(self):
        for field, env_name in _ENV_VAR_TABLE.items():
            self.assertTrue(
                env_name.startswith("LINGOFUSE_"),
                f"field {field!r} maps to non-prefixed {env_name!r}",
            )

    def test_env_var_names_are_unique(self):
        values = list(_ENV_VAR_TABLE.values())
        self.assertEqual(len(values), len(set(values)))


# ======================================================================
# Entry point
# ======================================================================

if __name__ == "__main__":
    unittest.main()