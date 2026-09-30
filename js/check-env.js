/**
 * @file check-env.js
 * @brief Environment diagnostic for the LingoFuse JavaScript binding.
 *
 * Run this script with:
 *
 *     node check-env.js
 *
 * It performs the following checks, in order, and prints a report:
 *
 *   1. Node.js runtime information (version, platform, architecture).
 *   2. Whether koffi can be require()d.
 *   3. Whether the koffi native addon loads and reports a version.
 *   4. Whether every binding source file can be require()d.
 *   5. Whether the LingoFuse native shared library can be loaded.
 *   6. Whether a real native call round-trips correctly.
 *
 * Every check is independent: a failure in one does not stop the
 * others. The script exits with status 0 when every check passed and
 * status 1 when any check failed, so it can be used in CI.
 *
 * This script is a diagnostic tool. It is not part of the binding's
 * public surface and it is safe to delete.
 *
 * ============================================================================
 * DIRECTORY LAYOUT THIS SCRIPT ASSUMES
 * ============================================================================
 * The script is designed for the following flat project layout:
 *
 *     js/
 *     ├── check-env.js               (this file)
 *     ├── test.js
 *     ├── lf_js_helloworld.js
 *     ├── package.json
 *     ├── index.js
 *     ├── index.mjs
 *     ├── binding.js
 *     ├── ... all other binding sources ...
 *     └── node_modules/              (koffi)
 *
 * Every file lives in the same directory as this script. There is no
 * src/ subdirectory.
 *
 * ============================================================================
 * WHY CHECK 5 ATTEMPTS A LOAD INSTEAD OF CHECKING FILE PATHS
 * ============================================================================
 * On Windows, Linux, and macOS the operating system loader resolves a
 * bare library name (for example "LingoFuse64.dll") against a search
 * path that is not visible to the JavaScript process: PATH on Windows,
 * LD_LIBRARY_PATH on Linux, DYLD_LIBRARY_PATH on macOS. A file-existence
 * check on a fixed list of candidate directories will therefore produce
 * a false negative whenever the library is discoverable only through
 * that system path.
 *
 * The only authoritative check is to ask the loader to actually load
 * the library, which is what check 5 does. The file-system candidate
 * list is still printed, but only as diagnostic information.
 *
 * ============================================================================
 */

"use strict";

const path = require("path");
const fs = require("fs");

// ---------------------------------------------------------------------------
// Project layout
// ---------------------------------------------------------------------------
//
// Every path below is expressed relative to __dirname (the directory
// that contains this script), NOT relative to process.cwd(). That makes
// the script independent of where the user runs it from.

/**
 * The directory that contains the binding. All binding source files
 * live here, next to this script.
 *
 * @type {string}
 */
const BINDING_DIR = __dirname;

/**
 * The binding source files, in dependency order. If any of these
 * cannot be require()d, the binding is not usable.
 *
 * @type {string[]}
 */
const BINDING_MODULES = [
    path.join(BINDING_DIR, "errors.js"),
    path.join(BINDING_DIR, "binding.js"),
    path.join(BINDING_DIR, "data-handle.js"),
    path.join(BINDING_DIR, "app-handle.js"),
    path.join(BINDING_DIR, "lf-io.js"),
    path.join(BINDING_DIR, "framework.js"),
    path.join(BINDING_DIR, "network-events.js"),
    path.join(BINDING_DIR, "status.js"),
    path.join(BINDING_DIR, "index.js"),
];

// ---------------------------------------------------------------------------
// Report helpers
// ---------------------------------------------------------------------------

let failures = 0;
let warnings = 0;

/**
 * Print a section header.
 *
 * @param {string} title
 */
function section(title) {
    console.log("");
    console.log("=".repeat(72));
    console.log(title);
    console.log("=".repeat(72));
}

/**
 * Print a successful check result.
 *
 * @param {string} message
 */
function ok(message) {
    console.log(`  [OK]   ${message}`);
}

/**
 * Print a failed check result and increment the failure counter.
 *
 * @param {string} message
 */
function fail(message) {
    console.log(`  [FAIL] ${message}`);
    failures += 1;
}

/**
 * Print a non-fatal warning.
 *
 * @param {string} message
 */
function warn(message) {
    console.log(`  [WARN] ${message}`);
    warnings += 1;
}

/**
 * Print an informational line.
 *
 * @param {string} message
 */
function info(message) {
    console.log(`         ${message}`);
}

// ---------------------------------------------------------------------------
// Check 1 - Node.js runtime
// ---------------------------------------------------------------------------

section("1. Node.js runtime");

info(`Node version    : ${process.version}`);
info(`Platform        : ${process.platform}`);
info(`Architecture    : ${process.arch}`);
info(`Executable      : ${process.execPath}`);
info(`Working dir     : ${process.cwd()}`);
info(`Script dir      : ${__dirname}`);
info(`Binding dir     : ${BINDING_DIR}`);

// Detect the runtime family. The binding is designed to work on Node,
// Deno and Bun; only Node is exercised by this script.
let runtime = "node";
if (typeof Deno !== "undefined") {
    runtime = "deno";
} else if (typeof Bun !== "undefined") {
    runtime = "bun";
}
info(`Runtime family  : ${runtime}`);

if (runtime !== "node") {
    warn(
        "This script targets Node.js. Results on Deno/Bun may differ."
    );
} else {
    ok("Running on Node.js.");
}

// ---------------------------------------------------------------------------
// Check 2 - koffi is installed
// ---------------------------------------------------------------------------

section("2. koffi package");

let koffi = null;
try {
    koffi = require("koffi");
    ok("koffi can be require()d.");
} catch (err) {
    fail(`koffi cannot be require()d: ${err.message}`);
    info("Expected location: <root>/node_modules/koffi");
    info("Run `npm install` in the project root to install it.");
}

if (koffi !== null) {
    // koffi exposes a version field; fall back to reading package.json
    // if the field is missing in this koffi release.
    let koffiVersion = koffi.version;
    if (!koffiVersion) {
        try {
            const pkg = require("koffi/package.json");
            koffiVersion = pkg.version;
        } catch (_) {
            koffiVersion = "(unknown)";
        }
    }
    ok(`koffi version: ${koffiVersion}`);
}

// ---------------------------------------------------------------------------
// Check 3 - koffi native addon loads
// ---------------------------------------------------------------------------

section("3. koffi native addon");

if (koffi === null) {
    fail("Skipped: koffi is not available.");
} else {
    // Loading a trivially small known library exercises the native
    // addon's loader. We use the platform's own C runtime so that no
    // LingoFuse-specific file is required for this check.
    try {
        let probeName;
        if (process.platform === "win32") {
            probeName = "kernel32.dll";
        } else if (process.platform === "darwin") {
            probeName = "libSystem.B.dylib";
        } else {
            probeName = "libc.so.6";
        }
        const probeLib = koffi.load(probeName);
        if (probeLib) {
            ok(`koffi native addon loaded; probed '${probeName}'.`);
        } else {
            fail(`koffi.load('${probeName}') returned a falsy value.`);
        }
    } catch (err) {
        fail(`koffi native addon failed to load a probe library: ${err.message}`);
    }
}

// ---------------------------------------------------------------------------
// Check 4 - binding source files are require-able
// ---------------------------------------------------------------------------

section("4. Binding modules");

for (const abs of BINDING_MODULES) {
    const rel = path.relative(__dirname, abs);
    if (!fs.existsSync(abs)) {
        fail(`Missing file: ${rel}`);
        continue;
    }
    try {
        // eslint-disable-next-line global-require
        require(abs);
        ok(`require('${rel}') succeeded.`);
    } catch (err) {
        fail(`require('${rel}') failed: ${err.message}`);
    }
}

// ---------------------------------------------------------------------------
// Check 5 - LingoFuse native library
// ---------------------------------------------------------------------------

section("5. LingoFuse native library");

let binding = null;
const bindingPath = path.join(BINDING_DIR, "binding.js");
try {
    binding = require(bindingPath);
} catch (err) {
    fail(`Cannot require ${path.relative(__dirname, bindingPath)}: ${err.message}`);
}

if (binding === null) {
    fail("Skipped: binding.js is not loadable.");
} else {
    const fileName = binding.selectPlatformFileName();
    info(`Expected file name on this platform: ${fileName}`);

    const candidates = binding.buildSearchPaths();
    info("File-system search order (informational):");
    for (const c of candidates) {
        info(`  - ${c}`);
    }

    // Report whether the file was found on disk. This is informational
    // only; a missing file here does not mean the library is
    // unavailable, because the OS loader may still find it on PATH.
    let foundPath = null;
    for (const c of candidates) {
        try {
            if (fs.existsSync(c)) {
                foundPath = c;
                break;
            }
        } catch (_) {
            // Some environments restrict filesystem access; ignore.
        }
    }
    if (foundPath !== null) {
        info(`Found on disk at: ${foundPath}`);
    } else {
        info("Not present on disk at any of the paths above.");
        info("The OS loader will now be asked to resolve the bare name.");
    }

    // Authoritative check: try to actually load the library. This
    // exercises the file-system candidates, the OS loader search path,
    // and the Koffi symbol-resolution path in a single call.
    try {
        const b = binding.getBinding();
        ok(`Native library loaded successfully: '${b.libraryName}'.`);
    } catch (err) {
        fail(`Could not load the native library: ${err.message}`);
        info(
            "Place the file next to the executable, in the current " +
            "working directory, in a ./native/ subdirectory, or on the " +
            "system loader search path (PATH on Windows, " +
            "LD_LIBRARY_PATH on Linux, DYLD_LIBRARY_PATH on macOS)."
        );
    }
}

// ---------------------------------------------------------------------------
// Check 6 - real native call round-trip
// ---------------------------------------------------------------------------

section("6. Native call round-trip");

if (binding === null || !binding.isLoaded()) {
    fail("Skipped: the native library is not loaded.");
} else {
    try {
        const b = binding.getBinding();
        ok("Binding initialised successfully.");
        info(`Native library name: ${b.libraryName}`);
        info(`Platform            : ${b.platform}`);

        // Create and free a data handle. This exercises the full path:
        // Koffi -> C ABI -> native allocator -> C ABI -> Koffi.
        const hnd = b.funcs.LF_CreateData("check-env");
        if (hnd === null || hnd === undefined) {
            fail("LF_CreateData returned a null handle.");
        } else {
            ok("LF_CreateData returned a non-null handle.");

            // Write 4 bytes and read them back.
            const payload = Uint8Array.of(0x01, 0x02, 0x03, 0x04);
            const written = b.funcs.LF_WriteBuffer(
                hnd,
                payload,
                payload.length
            );
            const writtenNum =
                typeof written === "bigint" ? Number(written) : written;
            if (writtenNum === payload.length) {
                ok(`LF_WriteBuffer wrote ${writtenNum} bytes.`);
            } else {
                fail(
                    `LF_WriteBuffer wrote ${writtenNum} bytes ` +
                    `(expected ${payload.length}).`
                );
            }

            // Rewind and read back.
            b.funcs.LF_SetPos(hnd, 0);
            const back = new Uint8Array(4);
            const read = b.funcs.LF_ReadBuffer(hnd, back, back.length);
            const readNum =
                typeof read === "bigint" ? Number(read) : read;
            if (readNum === back.length) {
                const match =
                    back[0] === 0x01 &&
                    back[1] === 0x02 &&
                    back[2] === 0x03 &&
                    back[3] === 0x04;
                if (match) {
                    ok("LF_ReadBuffer returned the exact bytes written.");
                } else {
                    fail(
                        `LF_ReadBuffer returned ${Array.from(back)
                            .map((b) => b.toString(16).padStart(2, "0"))
                            .join(" ")}; expected 01 02 03 04.`
                    );
                }
            } else {
                fail(
                    `LF_ReadBuffer read ${readNum} bytes ` +
                    `(expected ${back.length}).`
                );
            }

            b.funcs.LF_FreeData(hnd);
            ok("LF_FreeData released the handle.");
        }
    } catch (err) {
        fail(`Native call round-trip failed: ${err.message}`);
        if (err.stack) {
            info(err.stack.split("\n").slice(0, 5).join("\n         "));
        }
    }
}

// ---------------------------------------------------------------------------
// Report
// ---------------------------------------------------------------------------

section("Report");

if (failures === 0 && warnings === 0) {
    console.log("  All checks passed. The environment is ready.");
} else if (failures === 0) {
    console.log(
        `  All checks passed with ${warnings} warning(s). ` +
        `The environment is usable.`
    );
} else {
    console.log(
        `  ${failures} check(s) failed and ${warnings} warning(s) were ` +
        `recorded. See the sections above.`
    );
}

process.exit(failures === 0 ? 0 : 1);