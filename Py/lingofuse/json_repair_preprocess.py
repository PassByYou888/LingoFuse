# -*- coding: utf-8 -*-
"""
Unified JSON repair preprocessing for the LingoFuse toolchain.

This module is the single point where a JSON text payload is inspected
for damage before it is handed to a strict parser. It is used by every
JSON read path in the toolchain:

    * lingofuse.lf_io.read_json
    * lingofuse.lf_io.read_json_or_bytes
    * lingofuse.serializers.default_deserializer
    * lingofuse.bridge.normalize_json_bytes

Design contract
---------------
``repair_json_text`` is the ONLY public entry point. It follows a
three-way policy that matches the operational requirement of the
toolchain:

    1. Payload is already valid JSON
         -> return it unchanged, and emit NO log message.

    2. Payload is invalid but can be repaired
         -> return the repaired text, and emit a WARNING that names
            the source (which read path produced the payload) so that
            the operator can trace where the malformed data came from.

    3. Payload is invalid and cannot be repaired
         -> return the original text unchanged, and emit an ERROR
            that names the source. The caller then decides what to do:
            strict readers raise, lenient readers pass the raw bytes
            through.

No other behaviour is implemented. In particular, this module does
NOT do serialization (see lingofuse.lf_io.dumps_json) and does NOT
do byte-level framing (NUL handling lives in lf_io's low-level
helpers).

Repair engine
-------------
The actual repair is delegated to ``lingofuse.json_repair`` (the
vendored copy of the json_repair library). If that subpackage cannot
be imported -- for example, because it was stripped from a deployment
-- the module degrades gracefully: it still validates the payload, so
cases (1) and (3) keep working, but case (2) becomes indistinguishable
from case (3). A single WARNING is emitted at load time in that
degraded mode.

{!!!!!  NO-ESCAPE POLICY ON REPAIRED TEXT  !!!!!}
The engine call below passes ``ensure_ascii=False`` explicitly. This
is REQUIRED, not optional, because:

    * ``repair_json_text`` is re-exported from ``lingofuse.__init__``
      as a PUBLIC API. An advanced caller may consume its return
      value directly, without the subsequent ``json.loads`` that
      every internal read path happens to perform.

    * The toolchain contract, defined once in ``lf_io.dumps_json``,
      is that NO ``\\uXXXX`` escape ever appears on any wire or in
      any intermediate JSON string. If the engine were allowed to
      default to ``ensure_ascii=True``, a repaired payload that
      contains Chinese, emoji, or any non-ASCII character would
      come back with ``\\uXXXX`` escapes and silently violate the
      contract for direct consumers.

Internal read paths (lf_io, serializers, bridge) re-parse the
repaired text with ``json.loads`` before re-serializing through
``dumps_json``, so they would have masked the defect by accident.
The explicit flag removes that latent hazard and keeps the module
self-consistent with the rest of the toolchain.

Threading
---------
All functions are stateless and safe to call from any thread. The only
shared state is the one-time engine import attempt, which is guarded
by a module-level flag and a lock.

Environment override
--------------------
Set ``LINGOFUSE_JSON_REPAIR=0`` to disable repair entirely. In that
case ``repair_json_text`` only validates and never modifies the input;
case (2) is downgraded to case (3). This is provided as an escape
hatch for environments where automatic rewriting is not acceptable.

All comments and log messages are in English.
"""

from __future__ import annotations

import json
import logging
import os
import threading

_log = logging.getLogger("lingofuse.json_repair_preprocess")


# ----------------------------------------------------------------------
# Environment switch
# ----------------------------------------------------------------------

def _env_flag(name: str, default: bool) -> bool:
    """Return a boolean from an environment variable.

    An unset variable yields ``default``. The empty string, "0",
    "false", "no", and "off" (case-insensitive) all yield False.
    """
    raw = os.environ.get(name)
    if raw is None:
        return default
    return raw.strip().lower() not in ("0", "false", "no", "off", "")


_REPAIR_ENABLED: bool = _env_flag("LINGOFUSE_JSON_REPAIR", True)


# ----------------------------------------------------------------------
# Repair engine loading (lazy, one-shot)
# ----------------------------------------------------------------------
#
# We deliberately do NOT import lingofuse.json_repair at module import
# time. Two reasons:
#
#   1. A deployment may strip the vendored json_repair subpackage. We
#      want to detect that lazily and degrade, not crash at import.
#
#   2. Importing it eagerly would pull the repair engine (and its own
#      transitive imports) into every process that merely imports
#      lingofuse, even if no JSON payload is ever read.
#
# The lock makes the one-shot load safe against concurrent first use.

_repair_engine = None
_repair_engine_loaded = False
_repair_engine_lock = threading.Lock()


def _load_repair_engine():
    """Load and return the repair callable, or None if unavailable.

    The returned callable has the signature ``text -> text`` and is
    expected to raise ``ValueError`` if it cannot produce a repaired
    document that parses as strict JSON.

    No-escape guarantee
    -------------------
    The returned callable is REQUIRED to honour the toolchain-wide
    no-escape policy: for any input it accepts, its output must not
    contain a ``\\uXXXX`` escape for a character that can be emitted
    literally in UTF-8. This is enforced by passing
    ``ensure_ascii=False`` to the engine (see the inline comment in
    ``_engine`` below). Callers therefore do NOT need to re-serialize
    the repaired text through ``dumps_json`` before forwarding it to
    a downstream consumer that expects literal UTF-8.
    """
    global _repair_engine, _repair_engine_loaded

    if _repair_engine_loaded:
        return _repair_engine

    with _repair_engine_lock:
        if _repair_engine_loaded:
            return _repair_engine

        try:
            from . import json_repair as _jr

            def _engine(text: str) -> str:
                # ``skip_json_loads=True`` short-circuits the fast path
                # inside json_repair: we already know the payload is
                # malformed, so re-validating it there is wasted work.
                #
                # ``ensure_ascii=False`` enforces the toolchain-wide
                # no-escape policy on the repaired text itself. This
                # is REQUIRED because:
                #
                #   * repair_json_text() is re-exported from
                #     lingofuse.__init__ as a PUBLIC API, so an
                #     advanced caller may use the return value
                #     directly without going through json.loads();
                #
                #   * the toolchain contract (see lf_io.dumps_json)
                #     is that no \uXXXX escape ever appears on any
                #     wire or in any intermediate JSON string.
                #
                # Without this flag, json.dumps inside json_repair
                # would default to ensure_ascii=True and emit
                # \uXXXX escapes for any non-ASCII content, which
                # would silently violate the contract for direct
                # consumers of repair_json_text().
                repaired = _jr.repair_json(
                    text,
                    skip_json_loads=True,
                    ensure_ascii=False,
                )
                if not isinstance(repaired, str) or not repaired:
                    raise ValueError("json_repair produced an empty result")
                # Strict re-validation of the engine's output. This is
                # what preserves the binary-safety guarantee of the
                # bridge: a repair that cannot be parsed as strict
                # JSON is reported as a failure, and the caller falls
                # back to the original bytes.
                json.loads(repaired)
                return repaired

            _repair_engine = _engine
            _log.debug("JSON repair engine loaded: lingofuse.json_repair")
        except Exception as exc:
            _repair_engine = None
            _log.warning(
                "JSON repair engine unavailable (%s). "
                "Malformed JSON will be reported but not repaired.",
                exc,
            )
        finally:
            _repair_engine_loaded = True

    return _repair_engine


# ----------------------------------------------------------------------
# Logging helper
# ----------------------------------------------------------------------

def _preview(text, limit: int = 120) -> str:
    """Return a compact, single-line preview of ``text`` for logging.

    Control characters are escaped so that a multi-line or binary
    payload cannot break the log stream. The result is truncated to
    ``limit`` characters.
    """
    if text is None:
        return "<none>"
    flat = text.replace("\r", "\\r").replace("\n", "\\n")
    if len(flat) > limit:
        return flat[:limit] + "..."
    return flat


# ----------------------------------------------------------------------
# Public API
# ----------------------------------------------------------------------

def repair_json_text(
    text: str,
    *,
    source: str,
    report_failure: bool = True,
) -> str:
    """Inspect ``text`` for JSON validity and repair it if necessary.

    Parameters
    ----------
    text:
        The candidate JSON text. It must already be a decoded ``str``;
        this module does not perform any encoding or decoding.
    source:
        A short identifier for the read path that produced ``text``.
        It is embedded verbatim in every log message. Recommended
        values:

            "lf_io.read_json"
            "lf_io.read_json_or_bytes"
            "serializers.default_deserializer"
            "bridge.normalize_json_bytes"
    report_failure:
        When True (the default), an unrepairable payload emits one
        ERROR. Set this to False for read paths where a non-JSON
        payload is a legitimate outcome (for example, the bridge's
        byte passthrough), so that normal operation does not produce
        error-level noise.

    Returns
    -------
    str
        * The original ``text`` when it is already valid JSON.
        * The repaired text when repair succeeded. The repaired text
          is guaranteed to contain NO ``\\uXXXX`` escape for any
          character that can be emitted literally in UTF-8, because
          the engine is invoked with ``ensure_ascii=False`` (see
          ``_load_repair_engine`` for the full rationale).
        * The original ``text`` when repair failed or is disabled.

    Logging
    -------
    * Valid input  -> no log message at all.
    * Repaired     -> one WARNING naming ``source``.
    * Unrepairable -> one ERROR naming ``source`` (when
      ``report_failure`` is True).
    """
    # ------------------------------------------------------------------
    # Fast path: already valid JSON. This is the overwhelmingly common
    # case, so it must not emit any log message.
    # ------------------------------------------------------------------
    try:
        json.loads(text)
        return text
    except json.JSONDecodeError as exc:
        first_error = exc

    # ------------------------------------------------------------------
    # The payload is malformed. Decide whether to repair.
    # ------------------------------------------------------------------
    if not _REPAIR_ENABLED:
        if report_failure:
            _log.error(
                "Malformed JSON from %s and repair is disabled "
                "(LINGOFUSE_JSON_REPAIR=0): %s",
                source,
                first_error,
            )
        return text

    engine = _load_repair_engine()
    if engine is None:
        if report_failure:
            _log.error(
                "Malformed JSON from %s and no repair engine is "
                "available: %s",
                source,
                first_error,
            )
        return text

    # ------------------------------------------------------------------
    # Attempt the repair. Two failure modes are possible:
    #   * The engine raises -> unrecoverable.
    #   * The engine returns a string that still fails strict parsing
    #     -> also unrecoverable. The engine re-validates internally,
    #     so this branch should not trigger in practice; it is kept as
    #     a defensive guard.
    # ------------------------------------------------------------------
    try:
        repaired = engine(text)
    except Exception as exc:
        if report_failure:
            _log.error(
                "Malformed JSON from %s could not be repaired: %s "
                "(original error: %s)",
                source,
                exc,
                first_error,
            )
        return text

    _log.warning(
        "Repaired malformed JSON from %s: %s -> %s",
        source,
        _preview(text),
        _preview(repaired),
    )
    return repaired