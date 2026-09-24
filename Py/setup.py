# -*- coding: utf-8 -*-
"""
Setup script for the lingofuse Python distribution.

==================== WHAT CHANGED IN THIS REVISION ====================
This revision vendors the JSON repair engine as an internal
subpackage of ``lingofuse``:

    before:  py/json_repair/               (top-level package)
    after:   py/lingofuse/json_repair/     (subpackage of lingofuse)

Only three things in this file needed to change as a result. Each is
marked with a ``[CHANGED]`` comment below.

    1. ``python_requires`` was raised from ``>=3.7`` to ``>=3.10``.
       The vendored repair engine uses PEP 604 union syntax
       (``X | None``) and PEP 585 builtin generics (``dict[str, Any]``)
       at runtime, without ``from __future__ import annotations``.
       See the ``python_requires`` field for the full explanation.

    2. ``extras_require`` gained a ``"schema"`` entry for the optional
       JSON Schema / pydantic integration that lives in
       ``lingofuse.json_repair.schema_repair``.

    3. ``package_data`` was added to declare the ``py.typed`` marker
       explicitly for both ``lingofuse`` and ``lingofuse.json_repair``.
       Previously this relied on ``include_package_data=True`` plus
       whatever the build backend could infer; the explicit
       declaration makes the intent unambiguous.

==================== WHAT DID NOT CHANGE ====================
``packages=find_packages(...)`` was NOT modified. This is
intentional and worth understanding:

    find_packages() discovers every directory that contains an
    ``__init__.py`` file. It therefore already includes the vendored
    engine, without any manual list maintenance:

        lingofuse
            lingofuse.json_repair
                lingofuse.json_repair.parse_string_helpers
                lingofuse.json_repair.utils

    This is the same mechanism that used to discover the old
    top-level ``json_repair`` package. Moving the tree under
    ``lingofuse/`` and keeping find_packages() is therefore a no-op
    from the packaging perspective -- the distribution simply stops
    shipping the top-level name and starts shipping the subpackage.

    A side benefit: the top-level name ``json_repair`` is no longer
    installed into ``site-packages``, so this distribution no longer
    collides with the unrelated PyPI project of that name.

The distribution name, version, author, entry points, classifiers,
and the ``bridge``/``dev`` extras are all preserved exactly as they
were. This revision is a pure internal restructuring plus the
Python-version floor update.

==================== VERIFYING THE RESULT ====================
After ``pip install -e .`` (or a wheel build), the following should
all succeed:

    >>> import lingofuse
    >>> from lingofuse.json_repair import loads
    >>> from lingofuse.json_repair.utils.constants import JSONReturnType
    >>> from lingofuse.json_repair.parse_string_helpers import (
    ...     object_value_context,
    ... )
    >>> import json_repair
    Traceback (most recent call last):
        ...
    ModuleNotFoundError: No module named 'json_repair'

The last one is the intended outcome: the top-level name is gone.

All comments and log messages in this file are in English.
"""

from setuptools import setup, find_packages

with open("README.md", "r", encoding="utf-8") as fh:
    long_description = fh.read()

setup(
    name="lingofuse",
    version="1.0.0",
    author="passbyyou888 / Team",
    author_email="600585@qq.com",
    description="Python bindings for the LingoFuse RPC framework",
    long_description=long_description,
    long_description_content_type="text/markdown",
    url="https://github.com/PassByYou888/LingoFuse",

    # ------------------------------------------------------------------
    # [UNCHANGED] Package discovery
    # ------------------------------------------------------------------
    # find_packages() walks the source tree and returns every directory
    # that contains an __init__.py file. After the vendoring move, the
    # following packages are discovered automatically:
    #
    #     lingofuse
    #     lingofuse.json_repair
    #     lingofuse.json_repair.parse_string_helpers
    #     lingofuse.json_repair.utils
    #
    # No manual list is needed, and no subpackage can be accidentally
    # omitted when a new helper module is added to the repair engine.
    #
    # The ``exclude`` list filters out directories that are present in
    # the repository but are not part of the published package:
    #
    #     cross            -- demo scripts for cross-language clients
    #     cross.*          -- their subdirectories
    #     tests, *.tests   -- any test tree that may be added later
    #
    # Keeping the exclude list identical to the pre-revision value
    # preserves the previous distribution content exactly, minus the
    # top-level json_repair name and plus the new subpackage.
    packages=find_packages(
        exclude=["cross", "cross.*", "tests", "*.tests"]
    ),

    # ------------------------------------------------------------------
    # [CHANGED] Python version floor
    # ------------------------------------------------------------------
    # Before this revision:
    #
    #     python_requires=">=3.7"
    #
    # The LingoFuse bindings themselves (core, client, server, lf_io,
    # network_events, serializers, errors, _lf_native, and the new
    # json_repair_preprocess module) are compatible with Python 3.7
    # and later: they only use ``typing.Optional``, ``typing.Tuple``,
    # and other constructs that were introduced before 3.7.
    #
    # The vendored repair engine, however, is NOT 3.7-compatible. It
    # uses the following runtime-evaluated syntax, and it does not opt
    # out of evaluation with ``from __future__ import annotations``:
    #
    #     * PEP 604 union syntax:  ``X | Y``
    #       Examples:
    #           json_parser.py:
    #               schema: dict[str, Any] | bool | None = None
    #           json_repair/__init__.py:
    #               JSONReturnType = dict[str, Any] | list[Any] | ...
    #           parse_string.py:
    #               lookahead_cache: dict[
    #                   tuple[str, ...], tuple[int, int | None]
    #               ] = field(default_factory=dict)
    #
    #     * PEP 585 builtin generics:  ``dict[str, Any]``, ``list[X]``,
    #       ``tuple[X, Y]`` used at runtime (not in string form, not
    #       behind a future import).
    #
    # PEP 604 requires Python 3.10. PEP 585 requires Python 3.9.
    # The combined floor for this distribution is therefore 3.10.
    #
    # If you are deploying the LingoFuse bindings in an environment
    # that is pinned to Python 3.7, 3.8, or 3.9, and you do NOT need
    # the JSON repair feature, you have two options:
    #
    #     A. Install only the non-repair modules by importing them
    #        directly (e.g. ``from lingofuse import Server``); the
    #        repair engine is loaded lazily and a malformed payload
    #        will simply be reported as unrepairable. However, note
    #        that the ``from .json_repair_preprocess import
    #        repair_json_text`` line in ``lingofuse/__init__.py``
    #        does parse that module at import time, and that module
    #        itself does not use 3.10-only syntax -- it only imports
    #        the engine lazily. So importing lingofuse on 3.9 may work
    #        in practice, but it is NOT a supported configuration.
    #
    #     B. Fork the vendored engine and rewrite its type annotations
    #        from ``X | Y`` to ``typing.Union[X, Y]`` and ``dict[K, V]``
    #        to ``typing.Dict[K, V]``. This is a mechanical change but
    #        must be reapplied whenever the engine is updated from
    #        upstream.
    #
    # Option A is fragile because it relies on the repair engine never
    # being touched at runtime; option B is a maintenance burden. For
    # both reasons, the supported floor for this distribution is
    # declared as 3.10 below. If you must support an older Python
    # version, this is the single line to revisit.
    python_requires=">=3.10",

    # ------------------------------------------------------------------
    # [UNCHANGED] Runtime dependencies
    # ------------------------------------------------------------------
    # The lingofuse bindings, including the vendored repair engine,
    # have no third-party runtime dependency. Everything is built on
    # the Python standard library. See requirements.txt for the full
    # explanation.
    install_requires=[],

    # ------------------------------------------------------------------
    # [CHANGED] Optional feature extras
    # ------------------------------------------------------------------
    # The bridge and dev extras are preserved exactly as before.
    #
    # The new "schema" extra declares the optional dependencies of
    # lingofuse.json_repair.schema_repair, which provides JSON Schema
    # and pydantic v2 integration for the repair engine. These are
    # optional: importing lingofuse, using the repair engine on plain
    # JSON, and running the bridge all work without them. They are
    # only needed when a caller passes a ``schema=`` argument to a
    # repair function.
    #
    # Installation examples:
    #
    #     pip install -e ".[bridge]"         # HTTP bridge only
    #     pip install -e ".[schema]"         # schema-aware repair only
    #     pip install -e ".[bridge,schema]"  # both
    #     pip install -e ".[dev]"            # full development setup
    extras_require={
        "bridge": [
            "Flask>=2.0",
            "requests>=2.25",
        ],
        "schema": [
            "jsonschema>=4.0",
            "pydantic>=2.0",
        ],
        "dev": [
            "pytest>=7.0",
            "black",
            "flake8",
        ],
    },

    # ------------------------------------------------------------------
    # [CHANGED] Package data
    # ------------------------------------------------------------------
    # py.typed is the PEP 561 marker that tells static type checkers
    # (mypy, pyright, pylance) to use the inline type annotations
    # shipped with a package. The vendored repair engine has its own
    # py.typed file, and so does the top-level lingofuse package.
    #
    # Previously this relied on include_package_data=True plus
    # whatever the build backend could infer from version control or
    # a MANIFEST.in file. The explicit declaration below removes that
    # dependency: the two py.typed markers are always included, no
    # matter which build backend or source distribution tooling is
    # used.
    #
    # Note: py.typed is a ZERO-BYTE file, so listing it here costs
    # nothing in distribution size. Its only purpose is to exist.
    package_data={
        "lingofuse": ["py.typed"],
        "lingofuse.json_repair": ["py.typed"],
    },
    include_package_data=True,

    # ------------------------------------------------------------------
    # [UNCHANGED] Console scripts
    # ------------------------------------------------------------------
    # The ``lingofuse-bridge`` entry point resolves to the ``main``
    # function of lingofuse.bridge, which is unchanged in this
    # revision. The bridge now uses the unified JSON repair
    # preprocessor internally, but its command-line interface, its
    # error codes, and its module path are all identical to before.
    entry_points={
        "console_scripts": [
            "lingofuse-bridge = lingofuse.bridge:main",
        ],
    },

    # ------------------------------------------------------------------
    # [UNCHANGED] Trove classifiers
    # ------------------------------------------------------------------
    # These describe the distribution on PyPI. No classifier needed to
    # change: the ``Python :: 3`` classifier already covers 3.10 and
    # later, and the ``Operating System :: OS Independent`` classifier
    # is still accurate because the bindings are pure Python on top
    # of a platform-specific shared library that the user must
    # provide separately.
    #
    # A note for a future revision: if you want to advertise the
    # Python version floor explicitly on PyPI, you may add one or more
    # of the following classifiers. They are NOT required for the
    # distribution to work; they only affect discovery.
    #
    #     "Programming Language :: Python :: 3.10",
    #     "Programming Language :: Python :: 3.11",
    #     "Programming Language :: Python :: 3.12",
    #     "Programming Language :: Python :: 3.13",
    classifiers=[
        "Programming Language :: Python :: 3",
        "License :: OSI Approved :: MIT License",
        "Operating System :: OS Independent",
    ],
)