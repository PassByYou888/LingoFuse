# -*- coding: utf-8 -*-
"""
lingofuse._lf_native_check - Automated symbol-completeness check.

This module is a DIAGNOSTIC TOOL, not a public API. It verifies that
the low-level ctypes bindings in ``lingofuse._lf_native`` match, one
for one, the ``exports`` clause of the C ABI shared library.

The authoritative symbol list is embedded below, as
``EXPECTED_SYMBOLS``. It is a verbatim transcription of the
``exports`` clause of ``LingoFuse.lpr``, in the order the symbols
appear there. The count is asserted against the expected total so
that a future edit to this file cannot silently drop an entry.

Usage
-----
Three invocation styles are supported and produce identical output.

1. As a module (recommended; works from any working directory)::

       python -m lingofuse._lf_native_check

2. As a script, from the parent directory of the ``lingofuse``
   package::

       python lingofuse/_lf_native_check.py

3. From inside the ``lingofuse`` directory::

       cd lingofuse
       python _lf_native_check.py

Styles 1 and 2 are the ones to prefer. Style 3 works only because
this file falls back to inserting its own directory on ``sys.path``
when it detects that it is running as a top-level script.

Exit status:
    0 - every expected symbol is bound and every bound symbol is
        expected, and every structural check passed.
    1 - one or more expected symbols are missing, one or more
        unexpected symbols are present, or a structural check
        failed.
    2 - the check itself could not run (for example, the shared
        library failed to load at import time).

As a library::

    from lingofuse._lf_native_check import run_check
    result = run_check()
    if not result.ok:
        print(result.report())

The check is cheap (a dict lookup per symbol, plus a small fixed
number of structural inspections) and safe to run at any time,
including in production. It does NOT invoke any LingoFuse function:
it only verifies that the symbols were successfully resolved by
ctypes at module import time, and that a few bindings carry the
ctypes types their ABI role requires.

{!!!!!  WHAT THE STRUCTURAL CHECKS COVER  !!!!!}
Beyond symbol existence, this checker verifies that certain
bindings use the correct ctypes type. The current set of structural
checks is:

  * LF_Get_P2P_UID.restype must be ``ctypes.c_void_p`` (a pointer),
    NOT a ctypes Structure and NOT a ctypes array. The C ABI
    signature is:

        function LF_Get_P2P_UID(Hnd: TDataHnd___): PP2P_UID___;

    i.e. ``^TUID___`` (a POINTER to a 32-byte UID), not the value
    itself. Using a Structure restype here would be the old (and
    incorrect) representation of a by-value return, and would cause
    the caller to misinterpret the returned value.

  * LF_Get_P2P_Name.restype must be ``ctypes.c_char_p`` (a NUL-
    terminated string pointer), NOT a Structure.

Each structural check is deliberately narrow: it names the specific
binding and the specific property it requires, so that a regression
produces a precise, actionable error message rather than a vague
"something is wrong" verdict.

{!!!!!  WHEN TO RE-RUN  !!!!!}
Re-run this check after:

    * Upgrading the LingoFuse shared library (LingoFuse64.dll etc.)
      to a version with a different exports clause.
    * Editing ``lingofuse/_lf_native.py`` to add, remove, or rename a
      binding, or to change a restype / argtypes.
    * Porting to a platform where the shared library might have a
      different symbol set, or where the ABI differs.

{!!!!!  HOW TO UPDATE  !!!!!}
If the C ABI genuinely gains or loses a symbol, edit
``EXPECTED_SYMBOLS`` below to match the new ``exports`` clause, and
add or remove the corresponding ``_set_func`` call in
``_lf_native.py``. The count assertion at the bottom of this module
will then require updating the ``_EXPECTED_COUNT`` constant.

If a new binding needs a structural check (for example, another
function whose return type must be a specific ctypes type), add a
private ``_check_xxx`` function modelled on ``_check_uid_restype``
and call it from the Phase 3 section of ``run_check``.

All comments and output are in English.
"""

from __future__ import annotations

import ctypes
import os
import sys
from dataclasses import dataclass, field
from typing import List, Optional, Tuple


# ======================================================================
# Script-mode bootstrap
# ----------------------------------------------------------------------
# When this file is executed directly (``python lingofuse/_lf_native_check.py``
# or ``python _lf_native_check.py`` from inside the package directory),
# Python does NOT attach it to the ``lingofuse`` package, and
# ``__package__`` is either ``None`` or the empty string. In that
# case, the relative import ``from . import _lf_native`` in
# ``_import_lf_native()`` would fail with::
#
#     ImportError: attempted relative import with no known parent package
#
# We restore a usable import environment by putting the directory that
# contains ``_lf_native.py`` (i.e., this file's own directory) on
# ``sys.path``. ``_lf_native.py`` itself imports only ``ctypes``,
# ``sys`` and ``os`` -- it has no package-relative imports -- so a
# plain top-level ``import _lf_native`` then works.
#
# This block is a NO-OP when the file is imported as a module
# (``python -m lingofuse._lf_native_check``) or as a package
# submodule (``import lingofuse._lf_native_check``), because
# ``__package__`` is then ``"lingofuse"``.
# ======================================================================

if not __package__:
    _HERE = os.path.dirname(os.path.abspath(__file__))
    if _HERE not in sys.path:
        # Insert at position 0 so that this directory takes priority
        # over any other copy of `_lf_native.py` that might be lurking
        # elsewhere on sys.path.
        sys.path.insert(0, _HERE)


# ======================================================================
# Authoritative symbol list
# ----------------------------------------------------------------------
# This list is the verbatim transcription of the ``exports`` clause
# of ``LingoFuse.lpr``. Order is preserved for readability; the
# checker itself treats the list as a set.
#
# Grouped by C ABI category, matching the comments in LingoFuse.lpr.
# ======================================================================

EXPECTED_SYMBOLS: Tuple[str, ...] = (
    # ---- Data handles --------------------------------------------------
    "LF_CreateData",
    "LF_CreateData_Permanent",
    "LF_FreeData",
    "LF_GetBuffer",
    "LF_WriteBuffer",
    "LF_ReadBuffer",
    "LF_GetPos",
    "LF_SetPos",
    "LF_GetSize",
    "LF_SetSize",
    "LF_Get_P2P_UID",
    "LF_Get_P2P_Name",

    # ---- Application handles -------------------------------------------
    "LF_CreateApp",
    "LF_FreeApp",
    "LF_Generate_AppName",
    "LF_Get_AppName",
    "LF_BindApp",

    # ---- API registration (app-bound) ----------------------------------
    "LF_RegisterCall",
    "LF_RegisterNotify",
    "LF_Unregister",

    # ---- API registration (process-wide P2P) ---------------------------
    "LF_Register_P2P_Call",
    "LF_Register_P2P_Notify",
    "LF_Unregister_P2P",

    # ---- Local execution -----------------------------------------------
    "LF_LocalCall",
    "LF_LocalNotify",

    # ---- Network preparation -------------------------------------------
    "LF_PrepareService",
    "LF_PrepareClient",
    "LF_ResetPrepare",
    "LF_PrepareDone",
    "LF_ExitMainThread",

    # ---- Remote invocation by app name ---------------------------------
    "LF_Call",
    "LF_Async_Call",
    "LF_Async_Sequenced_Call",
    "LF_Notify",
    "LF_Sequenced_Notify",

    # ---- Remote invocation by UID --------------------------------------
    "LF_UID_Call",
    "LF_UID_Async_Call",
    "LF_UID_Async_Sequenced_Call",
    "LF_UID_Notify",
    "LF_UID_Sequenced_Notify",

    # ---- Remote invocation by P2P name ---------------------------------
    "LF_P2PNAME_Call",
    "LF_P2PNAME_Async_Call",
    "LF_P2PNAME_Async_Sequenced_Call",
    "LF_P2PNAME_Notify",
    "LF_P2PNAME_Sequenced_Notify",

    # ---- Health checks -------------------------------------------------
    "LF_CheckMainThread",
    "LF_CheckApp",
    "LF_CheckApi",
    "LF_Check_UID",
    "LF_Check_UID_Api",
    "LF_Check_P2PNAME",
    "LF_Check_P2PNAME_Api",

    # ---- Runtime options -----------------------------------------------
    "LF_SetOption",
    "LF_GetOption",

    # ---- Status / diagnostics ------------------------------------------
    "LF_GetStatusCount",
    "LF_GetStatus",
    "LF_PostStatus",

    # ---- Network events ------------------------------------------------
    "LF_Set_Network_Event",

    # ---- Shutdown ------------------------------------------------------
    "LF_Shutdown",
)

#: Expected total number of exported symbols. Asserted below so that
#: an accidental edit to EXPECTED_SYMBOLS is caught at import time.
_EXPECTED_COUNT = 59


# Sanity check: the tuple must have exactly the expected length.
# This catches a typo in EXPECTED_SYMBOLS itself, before any ctypes
# work happens.
if len(EXPECTED_SYMBOLS) != _EXPECTED_COUNT:
    raise AssertionError(
        f"EXPECTED_SYMBOLS has {len(EXPECTED_SYMBOLS)} entries, "
        f"expected {_EXPECTED_COUNT}. Update _EXPECTED_COUNT if the "
        f"C ABI genuinely changed."
    )

if len(set(EXPECTED_SYMBOLS)) != len(EXPECTED_SYMBOLS):
    # Find duplicates for the error message.
    _seen = set()
    _dups = []
    for _sym in EXPECTED_SYMBOLS:
        if _sym in _seen:
            _dups.append(_sym)
        else:
            _seen.add(_sym)
    raise AssertionError(
        f"EXPECTED_SYMBOLS contains duplicate entries: {_dups}"
    )


# ======================================================================
# Result object
# ======================================================================

@dataclass
class CheckResult:
    """Outcome of a symbol-completeness check."""

    #: Symbols that are in EXPECTED_SYMBOLS but not bound in
    #: _lf_native. These are the "load failure" cases.
    missing: List[str] = field(default_factory=list)

    #: Symbols that are bound in _lf_native but not in
    #: EXPECTED_SYMBOLS, OR structural check failures. These are the
    #: "stale binding / wrong type" cases.
    #:
    #: Structural check failures are prefixed with ``<restype check>``
    #: or a similar tag so that the operator can tell them apart from
    #: plain symbol mismatches.
    unexpected: List[str] = field(default_factory=list)

    #: Bound symbols that DO match EXPECTED_SYMBOLS. Purely
    #: informational; the checker's verdict depends only on the two
    #: lists above.
    matched: List[str] = field(default_factory=list)

    @property
    def ok(self) -> bool:
        """True if no symbol is missing and no symbol is unexpected."""
        return not self.missing and not self.unexpected

    def report(self) -> str:
        """Return a human-readable, multi-line report string."""
        lines = []
        lines.append(
            f"LingoFuse C ABI symbol check: "
            f"{len(self.matched)} matched, "
            f"{len(self.missing)} missing, "
            f"{len(self.unexpected)} unexpected"
        )
        if self.missing:
            lines.append("")
            lines.append(
                "MISSING (in EXPECTED_SYMBOLS but not bound in "
                "_lf_native):"
            )
            for sym in self.missing:
                lines.append(f"  - {sym}")
        if self.unexpected:
            lines.append("")
            lines.append(
                "UNEXPECTED (bound in _lf_native but not in "
                "EXPECTED_SYMBOLS, or structural check failure):"
            )
            for sym in self.unexpected:
                lines.append(f"  - {sym}")
        if self.ok:
            lines.append("")
            lines.append(
                "RESULT: OK - the 59 C ABI symbols are all bound, "
                "and all structural checks passed."
            )
        else:
            lines.append("")
            lines.append("RESULT: FAIL - see the lists above.")
        return "\n".join(lines)


# ======================================================================
# Internal: import the low-level module in any execution mode
# ======================================================================

def _import_lf_native():
    """
    Import and return the ``_lf_native`` module, regardless of how
    this file was loaded.

    Two execution modes are possible:

      * Module mode (``python -m lingofuse._lf_native_check``, or
        ``import lingofuse._lf_native_check`` from another module):
        ``__package__`` is ``"lingofuse"`` and the relative import
        ``from . import _lf_native`` succeeds.

      * Script mode (``python lingofuse/_lf_native_check.py``, or
        ``python _lf_native_check.py`` from inside the package
        directory): ``__package__`` is empty. The module-level
        bootstrap block has already put this file's directory on
        ``sys.path``, so a plain top-level ``import _lf_native``
        succeeds.
    """
    if __package__:
        from . import _lf_native  # type: ignore[import-not-found]
        return _lf_native
    # Script mode.
    import _lf_native  # type: ignore[import-not-found]
    return _lf_native


# ======================================================================
# Structural checks
# ----------------------------------------------------------------------
# Each check inspects one binding and returns None on success or a
# human-readable error string on failure. The error string is
# appended to CheckResult.unexpected by run_check, so ok becomes
# False and the operator sees a specific, actionable message.
#
# {!!!!!  WHY STRUCTURAL CHECKS EXIST  !!!!!}
# Symbol existence is necessary but NOT sufficient. Some C ABI
# functions require a specific ctypes representation for their
# argument or return types, and getting it wrong produces a bug that
# is silent at load time: the symbol resolves, no exception is
# raised, and the wrong behaviour only manifests as garbage data or
# memory corruption at call time.
#
# The canonical example is LF_Get_P2P_UID, which returns a POINTER
# to a 32-byte UID (Pascal: PP2P_UID___ = ^TUID___). Its restype
# MUST be ctypes.c_void_p. Using a ctypes Structure here would be
# the OLD (and incorrect) representation of a by-value return, and
# would cause the caller to misinterpret the returned pointer as if
# the 32-byte UID had been returned by value.
#
# Every new check should follow the same shape:
#   * named after the binding and the property it verifies
#     (``_check_uid_restype``, ``_check_xxx_argtype``, ...),
#   * return None on success or a non-empty error string on failure,
#   * produce an error message that names the binding, states the
#     observed value, states the expected value, and explains (very
#     briefly) why the expected value is required.
# ======================================================================

def _check_uid_restype() -> Optional[str]:
    """
    Verify that LF_Get_P2P_UID uses ``ctypes.c_void_p`` (a pointer)
    as its restype, NOT a ctypes Structure and NOT a ctypes array.

    Returns None when the binding is correct, or a human-readable
    error string when it is not.

    {!!!!!  WHY THIS CHECK EXISTS  !!!!!}
    The C ABI signature is:

        function LF_Get_P2P_UID(Hnd: TDataHnd___): PP2P_UID___;

    i.e. the function returns a POINTER to a 32-byte UID, not the
    value itself. The correct ctypes restype is therefore
    ``ctypes.c_void_p``.

    A previous revision of the bindings declared the restype as a
    ctypes Structure (``TP2P_UID_Return``) in order to work around
    the x64 SRet convention for by-value aggregate returns. That
    representation was correct ONLY for the old ABI (by-value
    return). With the current pointer-returning ABI, using a
    Structure would cause the caller to dereference the returned
    pointer as if the 32 bytes had been copied into the return
    slot -- a silent misread that produces garbage UID bytes.

    This check catches that regression by asserting the restype is
    exactly ``ctypes.c_void_p``.
    """
    lf_native = _import_lf_native()

    restype = getattr(lf_native.LF_Get_P2P_UID, "restype", None)
    if restype is None:
        return (
            "LF_Get_P2P_UID.restype is None; expected "
            "ctypes.c_void_p"
        )
    # The C ABI returns a POINTER to the 32-byte UID. The correct
    # ctypes representation is ctypes.c_void_p.
    if restype is not ctypes.c_void_p:
        return (
            f"LF_Get_P2P_UID.restype is {restype!r}; expected "
            f"ctypes.c_void_p. The C ABI returns a POINTER to the "
            f"32-byte UID (Pascal: PP2P_UID___ = ^TUID___), not "
            f"the value itself. Using a Structure or an array here "
            f"would misinterpret the returned pointer."
        )
    return None


def _check_uid_name_restype() -> Optional[str]:
    """
    Verify that LF_Get_P2P_Name uses ``ctypes.c_char_p`` as its
    restype.

    The C ABI returns a pointer to a NUL-terminated UTF-8 string.
    ctypes converts a ``c_char_p`` RETURN VALUE into a fresh Python
    ``bytes`` object on the call boundary, so the caller receives a
    detached value.

    Returns None when the binding is correct, or a human-readable
    error string when it is not.
    """
    lf_native = _import_lf_native()

    restype = getattr(lf_native.LF_Get_P2P_Name, "restype", None)
    if restype is None:
        return (
            "LF_Get_P2P_Name.restype is None; expected "
            "ctypes.c_char_p"
        )
    if restype is not ctypes.c_char_p:
        return (
            f"LF_Get_P2P_Name.restype is {restype!r}; expected "
            f"ctypes.c_char_p. The C ABI returns a pointer to a "
            f"NUL-terminated UTF-8 string."
        )
    return None


# ======================================================================
# Public entry point
# ======================================================================

def run_check() -> CheckResult:
    """
    Compare the EXPECTED_SYMBOLS list against the bindings actually
    present in ``lingofuse._lf_native``, and run structural checks on
    the bindings that require a specific ctypes representation.

    Returns a ``CheckResult`` instance. The check is read-only: it
    does not call any LingoFuse function, and it does not modify the
    bound functions in any way.

    Raises ImportError only if ``_lf_native`` itself cannot be
    imported (which would indicate a problem with the shared library,
    not with this checker).
    """
    lf_native = _import_lf_native()

    result = CheckResult()

    expected_set = set(EXPECTED_SYMBOLS)

    # --- Phase 1: every expected symbol must be present as a module
    #     attribute AND must be a ctypes function object (i.e., was
    #     successfully resolved through ``_set_func``).
    for sym in EXPECTED_SYMBOLS:
        obj = getattr(lf_native, sym, None)
        if obj is None:
            result.missing.append(sym)
        else:
            # Sanity: all bound symbols are _FuncPtr instances.
            # We do not assert the exact type (cpython version
            # differences exist) but we do require the attribute to
            # exist and to be non-None.
            result.matched.append(sym)

    # --- Phase 2: find bindings that are present but not expected.
    #
    # The candidate set is defined as every module-level attribute
    # whose name starts with ``LF_``. This is the naming convention
    # the C ABI follows, and it is broad enough to catch a stale
    # binding whose name does not appear in EXPECTED_SYMBOLS.
    #
    # Private helpers (``_set_func``, ``_load_library``, etc.) do
    # not match this prefix, and neither do the callback prototypes
    # (``LFCallFunc`` etc.), which are type objects rather than
    # functions.
    for name in dir(lf_native):
        if not name.startswith("LF_"):
            continue
        if name in expected_set:
            continue
        result.unexpected.append(name)

    # --- Phase 3: structural checks on specific bindings that have
    #     non-obvious ctypes requirements.
    #
    # Each check returns None on success or an error string on
    # failure. A failure is recorded in the ``unexpected`` list (with
    # a tag prefix so it can be told apart from a symbol mismatch),
    # which causes ``ok`` to be False and the operator to see a
    # specific error message.
    #
    # LF_Get_P2P_UID returns a POINTER to a 32-byte UID. Its restype
    # MUST be ctypes.c_void_p, NOT a ctypes Structure. See the
    # docstring of _check_uid_restype for the full rationale.
    restype_error = _check_uid_restype()
    if restype_error is not None:
        result.unexpected.append(
            f"<restype check> {restype_error}"
        )

    # LF_Get_P2P_Name returns a NUL-terminated UTF-8 string pointer.
    # Its restype MUST be ctypes.c_char_p so that ctypes converts the
    # returned pointer into a fresh Python bytes object on the call
    # boundary.
    name_restype_error = _check_uid_name_restype()
    if name_restype_error is not None:
        result.unexpected.append(
            f"<restype check> {name_restype_error}"
        )

    result.unexpected.sort()
    return result


# ======================================================================
# Script entry point
# ======================================================================

def _main() -> int:
    """Run the check and print a report. Returns a process exit code."""
    try:
        result = run_check()
    except Exception as exc:
        print(f"ERROR: symbol check could not run: {exc}")
        return 2

    print(result.report())
    return 0 if result.ok else 1


if __name__ == "__main__":
    sys.exit(_main())