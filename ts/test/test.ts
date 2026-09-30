// =============================================================================
//  test/test.ts
// -----------------------------------------------------------------------------
//  Cross-runtime integration and unit test suite for the LingoFuse
//  TypeScript binding.
//
//  Runs on:
//      Node.js 18+ : npx tsx test/test.ts
//      Bun 1.x+    : bun run test/test.ts
//      Deno 2.x    : deno run --allow-ffi --allow-read --allow-env \
//                              --allow-net --allow-sys test/test.ts
//
//  This file does NOT use node:test or any runtime-specific test
//  runner. A small describe / it / before / after harness and a
//  minimal assertion library are defined in place. This keeps the
//  suite portable across the three supported runtimes.
//
//  Test organisation (nine suites):
//      1. errors              exception hierarchy (no native calls)
//      2. binding             platform name, search paths, exports
//      3. DataHandle          RAII wrapper for TDataHnd
//      4. lf-io               JSON / string / byte I/O
//      5. AppHandle           RAII wrapper for TAppHnd
//      6. framework           process-wide facade
//      7. status              status queue and health checks
//      8. callbacks           error reporting and isolation
//      9. network events      install / uninstall paths
//
//  Exit code:
//      0   all tests passed
//      1   at least one test failed, or setup failed
// =============================================================================

import * as lf from "../src/index";
import { DataHandle } from "../src/index";

// =============================================================================
//  Section 1 - Minimal test harness
// =============================================================================

type TestFn = () => void | Promise<void>;

interface TestCase {
    readonly name: string;
    readonly fn: TestFn;
}

interface Suite {
    readonly name: string;
    readonly tests: TestCase[];
}

const SUITES: Suite[] = [];
let currentSuite: Suite | null = null;
let beforeAllFn: TestFn | null = null;
let afterAllFn: TestFn | null = null;

function describe(name: string, fn: () => void): void {
    const suite: Suite = { name, tests: [] };
    SUITES.push(suite);
    const previous = currentSuite;
    currentSuite = suite;
    try {
        fn();
    }
    finally {
        currentSuite = previous;
    }
}

function it(name: string, fn: TestFn): void {
    if (currentSuite === null) {
        throw new Error(`it() called outside describe(): ${name}`);
    }
    currentSuite.tests.push({ name, fn });
}

function before(fn: TestFn): void {
    if (beforeAllFn !== null) {
        throw new Error("before() may only be registered once.");
    }
    beforeAllFn = fn;
}

function after(fn: TestFn): void {
    if (afterAllFn !== null) {
        throw new Error("after() may only be registered once.");
    }
    afterAllFn = fn;
}

// =============================================================================
//  Section 2 - Minimal assertion library
// =============================================================================

class AssertionError extends Error {
    public constructor(message: string) {
        super(message);
        this.name = "AssertionError";
    }
}

function formatValue(v: unknown): string {
    if (typeof v === "string") return JSON.stringify(v);
    if (typeof v === "bigint") return `${v}n`;
    if (v === null) return "null";
    if (v === undefined) return "undefined";
    if (typeof v === "object") {
        try { return JSON.stringify(v); }
        catch { return String(v); }
    }
    return String(v);
}

function deepEqual(a: unknown, b: unknown): boolean {
    if (Object.is(a, b)) return true;
    if (typeof a !== typeof b) return false;
    if (a === null || b === null) return false;
    if (typeof a !== "object") return false;
    if (Array.isArray(a) !== Array.isArray(b)) return false;

    if (Array.isArray(a) && Array.isArray(b)) {
        if (a.length !== b.length) return false;
        for (let i = 0; i < a.length; i++) {
            if (!deepEqual(a[i], b[i])) return false;
        }
        return true;
    }

    const ka = Object.keys(a as object);
    const kb = Object.keys(b as object);
    if (ka.length !== kb.length) return false;
    for (const k of ka) {
        if (!Object.prototype.hasOwnProperty.call(b, k)) return false;
        if (!deepEqual(
            (a as Record<string, unknown>)[k],
            (b as Record<string, unknown>)[k],
        )) return false;
    }
    return true;
}

const assert = {
    ok(value: unknown, message?: string): void {
        if (!value) {
            throw new AssertionError(
                message ?? `Expected a truthy value but received ${formatValue(value)}.`);
        }
    },

    equal(actual: unknown, expected: unknown, message?: string): void {
        if (!Object.is(actual, expected)) {
            throw new AssertionError(
                message ?? `Expected ${formatValue(expected)} but received ${formatValue(actual)}.`);
        }
    },

    notEqual(actual: unknown, expected: unknown, message?: string): void {
        if (Object.is(actual, expected)) {
            throw new AssertionError(
                message ?? `Expected a value different from ${formatValue(expected)}.`);
        }
    },

    deepEqual(actual: unknown, expected: unknown, message?: string): void {
        if (!deepEqual(actual, expected)) {
            throw new AssertionError(
                message ?? `Deep equality failed.\n        actual  : ${formatValue(actual)}\n        expected: ${formatValue(expected)}`);
        }
    },

    throws(fn: () => void, expectedType?: new (...args: never[]) => Error, message?: string): void {
        let thrown: unknown = null;
        let didThrow = false;
        try {
            fn();
        }
        catch (err) {
            didThrow = true;
            thrown = err;
        }

        if (!didThrow) {
            throw new AssertionError(
                message ?? `Expected function to throw${expectedType ? ` ${expectedType.name}` : ""}, but it returned normally.`);
        }
        if (expectedType && !(thrown instanceof expectedType)) {
            const actualName = thrown && (thrown as object).constructor
                ? (thrown as object).constructor.name
                : typeof thrown;
            throw new AssertionError(
                message ?? `Expected thrown error to be ${expectedType.name}, but received ${actualName}.`);
        }
    },

    match(value: string, pattern: RegExp, message?: string): void {
        if (typeof value !== "string") {
            throw new AssertionError(
                message ?? `match: value must be a string, got ${typeof value}.`);
        }
        if (!(pattern instanceof RegExp)) {
            throw new AssertionError(message ?? "match: pattern must be a RegExp.");
        }
        if (!pattern.test(value)) {
            throw new AssertionError(
                message ?? `Expected ${formatValue(value)} to match ${pattern}.`);
        }
    },
};

// =============================================================================
//  Section 3 - Shared state
// =============================================================================

let app: lf.AppHandle | null = null;
let frameworkReady = false;
let lastCallbackError: { source: string; err: unknown } | null = null;

// =============================================================================
//  Section 4 - Helpers
// =============================================================================

function sleep(ms: number): Promise<void> {
    return new Promise((resolve) => setTimeout(resolve, ms));
}

async function waitFor(
    predicate: () => boolean,
    timeoutMs: number,
    intervalMs: number = 100,
): Promise<boolean> {
    const deadline = Date.now() + timeoutMs;
    while (Date.now() < deadline) {
        if (predicate()) return true;
        await sleep(intervalMs);
    }
    return false;
}

function requireApp(): lf.AppHandle {
    if (app === null) {
        throw new Error("the shared AppHandle is not initialised");
    }
    return app;
}

// =============================================================================
//  Section 5 - Global setup / teardown
// =============================================================================

before(async () => {
    lf.loadLibrary();

    lf.framework.setCallbackErrorHandler((source, err) => {
        lastCallbackError = { source, err };
    });

    lf.framework.setOption(lf.Option.WAIT_CONNECTION_READY_OK, lf.bool(false));

    const createdApp = new lf.AppHandle("JsTest", "TypeScript binding test suite");

    const registered =
        createdApp.registerCall("add", "Add two integers", (input, output) => {
            const req = lf.io.readJson<{ a?: number; b?: number }>(input) ?? {};
            const a = Number(req.a) || 0;
            const b = Number(req.b) || 0;
            lf.io.writeJson(output, { result: a + b });
        }) &&
        createdApp.registerCall("echo", "Echo the payload", (input, output) => {
            const req = lf.io.readJson<unknown>(input);
            lf.io.writeJson(output, { echo: req });
        }) &&
        createdApp.registerNotify("log", "One-way log", (input) => {
            const payload = lf.io.readJson<unknown>(input);
            lastCallbackError = {
                source: "test.log",
                err: { received: payload },
            };
        });

    if (!registered) {
        throw new Error("failed to register the test APIs");
    }

    lf.framework.resetPrepare();
    lf.framework.prepareService("ipc:jstest", "ipc:jstest");
    lf.framework.prepareClient("ipc:jstest", createdApp);

    const started = lf.framework.prepareDone();
    if (started !== 1) {
        throw new Error(`prepareDone() returned ${started}; expected 1.`);
    }

    const visible = await waitFor(
        () => lf.status.checkApp("JsTest"),
        10000);
    if (!visible) {
        throw new Error("JsTest did not become visible within 10 seconds");
    }

    app = createdApp;
    frameworkReady = true;
});

after(() => {
    if (!frameworkReady) return;
    try { lf.framework.exitMainThread(); } catch { /* ignore */ }
    if (app !== null) {
        try { app.dispose(); } catch { /* ignore */ }
        app = null;
    }
    try { lf.framework.shutdown(); } catch { /* ignore */ }
});

// =============================================================================
//  Section 6 - Test definitions
// =============================================================================

// -----------------------------------------------------------------------------
//  1. errors
// -----------------------------------------------------------------------------

describe("errors", () => {
    it("LingoFuseError extends Error", () => {
        const err = new lf.LingoFuseError("boom");
        assert.ok(err instanceof Error);
        assert.equal(err.name, "LingoFuseError");
        assert.equal(err.message, "boom");
    });

    it("LingoFuseError exposes a numeric code", () => {
        const err = new lf.LingoFuseError("boom", lf.ErrorCode.Timeout);
        assert.equal(err.code, lf.ErrorCode.Timeout);
    });

    it("LingoFuseLibraryLoadError carries the library name", () => {
        const err = new lf.LingoFuseLibraryLoadError("libfoo.so");
        assert.ok(err instanceof lf.LingoFuseError);
        assert.equal(err.libraryName, "libfoo.so");
        assert.match(err.message, /libfoo\.so/);
    });

    it("LingoFuseCallError carries target identification", () => {
        const err = new lf.LingoFuseCallError("timeout", {
            targetApp: "Foo",
            targetApi: "bar",
        });
        assert.ok(err instanceof lf.LingoFuseError);
        assert.equal(err.targetApp, "Foo");
        assert.equal(err.targetApi, "bar");
    });

    it("LingoFuseIoError carries the operation name", () => {
        const err = new lf.LingoFuseIoError("short read", {
            operation: "readBytesExact",
        });
        assert.equal(err.operation, "readBytesExact");
    });

    it("LingoFuseObjectDisposedError names the object", () => {
        const err = new lf.LingoFuseObjectDisposedError("DataHandle");
        assert.equal(err.objectName, "DataHandle");
        assert.match(err.message, /DataHandle/);
    });

    it("LingoFuseCallbackError preserves the original cause", () => {
        const cause = new Error("inner");
        const err = new lf.LingoFuseCallbackError("test.callback", cause);
        assert.equal(err.source, "test.callback");
        assert.equal(err.originalCause, cause);
    });

    it("LingoFuseError preserves a passed cause", () => {
        const cause = new Error("root");
        const err = new lf.LingoFuseError("wrapper", lf.ErrorCode.Generic, { cause });
        assert.equal(err.cause, cause);
    });
});

// -----------------------------------------------------------------------------
//  2. binding
// -----------------------------------------------------------------------------

describe("binding", () => {
    it("selectPlatformFileName returns a non-empty string", () => {
        const name = lf.selectPlatformFileName();
        assert.equal(typeof name, "string");
        assert.ok(name.length > 0);
    });

    it("the platform name matches the current OS", () => {
        const name = lf.selectPlatformFileName();
        if (process.platform === "win32") {
            assert.match(name, /^LingoFuse(32|64)\.dll$/);
        }
        else if (process.platform === "darwin") {
            assert.equal(name, "liblingofuse.dylib");
        }
        else {
            assert.equal(name, "liblingofuse.so");
        }
    });

    it("loadLibrary is idempotent and reports success", () => {
        assert.equal(lf.loadLibrary(), true);
        assert.equal(lf.loadLibrary(), true);
        assert.equal(lf.isNativeLoaded(), true);
    });

    it("platform() returns the runtime description", () => {
        const info = lf.platform();
        assert.equal(info.platform, process.platform);
        assert.equal(info.arch, process.arch);
        assert.ok(["node", "deno", "bun"].includes(info.runtime));
    });

    it("buildSearchPaths returns an array of absolute paths", () => {
        const paths = lf.buildSearchPaths();
        assert.ok(Array.isArray(paths));
        for (const p of paths) {
            assert.equal(typeof p, "string");
            assert.ok(p.length > 0);
        }
    });

    it("exports both RAII handle types", () => {
        assert.equal(typeof lf.DataHandle, "function");
        assert.equal(typeof lf.AppHandle, "function");
    });

    it("exports the four namespace groups", () => {
        assert.equal(typeof lf.io, "object");
        assert.equal(typeof lf.framework, "object");
        assert.equal(typeof lf.network, "object");
        assert.equal(typeof lf.status, "object");
    });
});

// -----------------------------------------------------------------------------
//  3. DataHandle
// -----------------------------------------------------------------------------

describe("DataHandle", () => {
    it("creates an owning handle", () => {
        const h = new DataHandle("test");
        assert.equal(h.isOwning, true);
        assert.equal(h.isValid, true);
        assert.notEqual(h.raw, null);
        h.dispose();
    });

    it("dispose is idempotent", () => {
        const h = new DataHandle("test");
        h.dispose();
        h.dispose();
        assert.equal(h.isValid, false);
    });

    it("operations after dispose throw LingoFuseObjectDisposedError", () => {
        const h = new DataHandle("test");
        h.dispose();
        assert.throws(() => h.position, lf.LingoFuseObjectDisposedError);
    });

    it("constructor rejects a non-string API name", () => {
        assert.throws(
            () => new DataHandle(42 as unknown as string),
            TypeError);
    });

    it("a new handle starts empty", () => {
        const h = new DataHandle("test");
        assert.equal(h.size, 0);
        assert.equal(h.position, 0);
        h.dispose();
    });

    it("writeBytes and readBytes round-trip", () => {
        const h = new DataHandle("test");
        h.writeBytes(Uint8Array.of(1, 2, 3, 4));
        assert.equal(h.size, 4);
        assert.equal(h.position, 4);

        h.position = 0;
        const back = h.readBytes(4);
        assert.deepEqual(Array.from(back), [1, 2, 3, 4]);
        h.dispose();
    });

    it("readBytes returns fewer bytes at end-of-buffer", () => {
        const h = new DataHandle("test");
        h.writeBytes(Uint8Array.of(1, 2));
        h.position = 0;
        const back = h.readBytes(10);
        assert.equal(back.length, 2);
        h.dispose();
    });

    it("readBytesExact throws on a short read", () => {
        const h = new DataHandle("test");
        h.writeBytes(Uint8Array.of(1, 2));
        h.position = 0;
        assert.throws(() => h.readBytesExact(4), lf.LingoFuseIoError);
        h.dispose();
    });

    it("readBytesExact restores the cursor on failure", () => {
        const h = new DataHandle("test");
        h.writeBytes(Uint8Array.of(1, 2));
        h.position = 0;
        try { h.readBytesExact(4); } catch { /* expected */ }
        assert.equal(h.position, 0);
        h.dispose();
    });

    it("tryReadBytes returns ok=false on a short read", () => {
        const h = new DataHandle("test");
        h.writeBytes(Uint8Array.of(1, 2));
        h.position = 0;
        const r = h.tryReadBytes(4);
        assert.equal(r.ok, false);
        assert.equal(h.position, 0);
        h.dispose();
    });

    it("readAllBytes consumes the remaining buffer", () => {
        const h = new DataHandle("test");
        h.writeBytes(Uint8Array.of(1, 2, 3, 4, 5));
        h.position = 2;
        const rest = h.readAllBytes();
        assert.deepEqual(Array.from(rest), [3, 4, 5]);
        assert.equal(h.position, 5);
        h.dispose();
    });

    it("readAllBytes returns empty when the cursor is at the end", () => {
        const h = new DataHandle("test");
        h.writeBytes(Uint8Array.of(1));
        const rest = h.readAllBytes();
        assert.equal(rest.length, 0);
        h.dispose();
    });

    it("writeInt32 / readInt32 round-trip", () => {
        const h = new DataHandle("test");
        h.writeInt32(0x01020304);
        h.position = 0;
        assert.equal(h.readInt32(), 0x01020304);
        h.dispose();
    });

    it("writeInt32 is little-endian", () => {
        const h = new DataHandle("test");
        h.writeInt32(0x01020304);
        h.position = 0;
        assert.deepEqual(
            Array.from(h.readBytesExact(4)),
            [0x04, 0x03, 0x02, 0x01]);
        h.dispose();
    });

    it("writeInt64 / readInt64 round-trip (BigInt)", () => {
        const h = new DataHandle("test");
        h.writeInt64(0x0102030405060708n);
        h.position = 0;
        assert.equal(h.readInt64(), 0x0102030405060708n);
        h.dispose();
    });

    it("writeInt64 rejects a fractional number", () => {
        const h = new DataHandle("test");
        assert.throws(
            () => h.writeInt64(1.5),
            RangeError);
        h.dispose();
    });

    it("writeDouble / readDouble round-trip", () => {
        const h = new DataHandle("test");
        h.writeDouble(Math.PI);
        h.position = 0;
        assert.equal(h.readDouble(), Math.PI);
        h.dispose();
    });

    it("writeSingle / readSingle round-trip", () => {
        const h = new DataHandle("test");
        h.writeSingle(1.5);
        h.position = 0;
        assert.equal(h.readSingle(), 1.5);
        h.dispose();
    });

    it("tryReadInt32 returns ok=false on a short buffer", () => {
        const h = new DataHandle("test");
        h.writeUInt8(1);
        h.position = 0;
        const r = h.tryReadBytes(4);
        assert.equal(r.ok, false);
        h.dispose();
    });

    it("writeString appends a NUL terminator", () => {
        const h = new DataHandle("test");
        h.writeString("hi");
        assert.equal(h.size, 3);
        h.position = 0;
        assert.deepEqual(
            Array.from(h.readBytesExact(3)),
            [0x68, 0x69, 0x00]);
        h.dispose();
    });

    it("writeString of an empty string writes a single NUL", () => {
        const h = new DataHandle("test");
        h.writeString("");
        assert.equal(h.size, 1);
        h.position = 0;
        assert.deepEqual(Array.from(h.readBytesExact(1)), [0x00]);
        h.dispose();
    });

    it("writeString / readString round-trip (ASCII)", () => {
        const h = new DataHandle("test");
        h.writeString("hello");
        h.position = 0;
        assert.equal(h.readString(), "hello");
        h.dispose();
    });

    it("writeString / readString round-trip (non-ASCII)", () => {
        const h = new DataHandle("test");
        h.writeString("\u4f60\u597d \ud83c\udf0d");
        h.position = 0;
        assert.equal(h.readString(), "\u4f60\u597d \ud83c\udf0d");
        h.dispose();
    });

    it("readString advances the cursor past the NUL", () => {
        const h = new DataHandle("test");
        h.writeString("ab");
        h.writeString("cd");
        h.position = 0;
        assert.equal(h.readString(), "ab");
        assert.equal(h.position, 3);
        assert.equal(h.readString(), "cd");
        h.dispose();
    });

    it("readString is fault-tolerant when no NUL is present", () => {
        const h = new DataHandle("test");
        h.writeBytes(Uint8Array.of(0x68, 0x69));
        h.position = 0;
        assert.equal(h.readString(), "hi");
        assert.equal(h.position, 3);
        h.dispose();
    });

    it("readString returns empty on an exhausted buffer", () => {
        const h = new DataHandle("test");
        assert.equal(h.readString(), "");
        h.dispose();
    });

    it("tryReadString returns ok=false on an exhausted buffer", () => {
        const h = new DataHandle("test");
        const r = h.tryReadString();
        assert.equal(r.ok, false);
        h.dispose();
    });

    it("size setter resizes the buffer", () => {
        const h = new DataHandle("test");
        h.size = 10;
        assert.equal(h.size, 10);
        h.dispose();
    });

    it("size setter rejects a negative value", () => {
        const h = new DataHandle("test");
        assert.throws(() => { h.size = -1; }, RangeError);
        h.dispose();
    });

    it("position setter rejects a negative value", () => {
        const h = new DataHandle("test");
        assert.throws(() => { h.position = -1; }, RangeError);
        h.dispose();
    });

    it("fromRaw(false) produces a non-owning handle", () => {
        const owner = new DataHandle("test");
        owner.writeString("x");
        const borrowed = DataHandle.fromRaw(owner.raw, false);
        assert.equal(borrowed.isOwning, false);
        borrowed.dispose();
        assert.equal(borrowed.isValid, true);
        owner.dispose();
    });

    it("a borrowed handle survives dispose on the wrapper", () => {
        const owner = new DataHandle("test");
        owner.writeString("payload");
        owner.position = 0;

        const borrowed = DataHandle.fromRaw(owner.raw, false);
        borrowed.dispose();

        assert.equal(borrowed.readString(), "payload");
        owner.dispose();
    });
});

// -----------------------------------------------------------------------------
//  4. lf-io
// -----------------------------------------------------------------------------

describe("lf-io", () => {
    it("dumps produces compact JSON with no whitespace", () => {
        assert.equal(lf.io.dumps({ a: 1, b: [2, 3] }), '{"a":1,"b":[2,3]}');
    });

    it("dumps preserves non-ASCII as literal UTF-8", () => {
        const text = lf.io.dumps({ greeting: "\u4f60\u597d" });
        assert.ok(!text.includes("\\u"));
        assert.equal(text, '{"greeting":"\u4f60\u597d"}');
    });

    it("dumps serializes a small BigInt as a JSON number", () => {
        assert.equal(lf.io.dumps({ x: 42n }), '{"x":42}');
    });

    it("dumps serializes a large BigInt as a JSON string", () => {
        const big = 9007199254740993n;
        assert.equal(lf.io.dumps({ x: big }), '{"x":"9007199254740993"}');
    });

    it("dumps treats a top-level undefined as JSON null", () => {
        assert.equal(lf.io.dumps(undefined), "null");
    });

    it("loads parses compact JSON", () => {
        assert.deepEqual(lf.io.loads<{ a: number }>('{"a":1}'), { a: 1 });
    });

    it("loads throws LingoFuseIoError on invalid JSON", () => {
        assert.throws(() => lf.io.loads("{"), lf.LingoFuseIoError);
    });

    it("loads rejects a non-string argument", () => {
        assert.throws(
            () => lf.io.loads(42 as unknown as string),
            TypeError);
    });

    it("writeJson / readJson round-trip an object", () => {
        const h = new DataHandle("test");
        lf.io.writeJson(h, { a: 1, b: "two", c: [3] });
        h.position = 0;
        assert.deepEqual(
            lf.io.readJson<{ a: number; b: string; c: number[] }>(h),
            { a: 1, b: "two", c: [3] });
        h.dispose();
    });

    it("writeJson / readJson round-trip a non-ASCII string", () => {
        const h = new DataHandle("test");
        lf.io.writeJson(h, { name: "\u5f20\u4e09", emoji: "\ud83c\udf0d" });
        h.position = 0;
        assert.deepEqual(
            lf.io.readJson<{ name: string; emoji: string }>(h),
            { name: "\u5f20\u4e09", emoji: "\ud83c\udf0d" });
        h.dispose();
    });

    it("readJson returns null for an empty payload", () => {
        const h = new DataHandle("test");
        assert.equal(lf.io.readJson(h), null);
        h.dispose();
    });

    it("readJson throws LingoFuseIoError on invalid JSON", () => {
        const h = new DataHandle("test");
        h.writeString("{not json");
        h.position = 0;
        assert.throws(() => lf.io.readJson(h), lf.LingoFuseIoError);
        h.dispose();
    });

    it("tryReadJson returns ok=false on invalid JSON", () => {
        const h = new DataHandle("test");
        h.writeString("{not json");
        h.position = 0;
        const r = lf.io.tryReadJson(h);
        assert.equal(r.ok, false);
        h.dispose();
    });

    it("readJson is fault-tolerant when no NUL is present", () => {
        const h = new DataHandle("test");
        const text = '{"a":1}';
        const bytes = new TextEncoder().encode(text);
        h.writeBytes(bytes);
        h.position = 0;
        assert.deepEqual(lf.io.readJson<{ a: number }>(h), { a: 1 });
        h.dispose();
    });

    it("writeString and readString are exact inverses", () => {
        const h = new DataHandle("test");
        lf.io.writeString(h, "hello");
        h.position = 0;
        assert.equal(lf.io.readString(h), "hello");
        h.dispose();
    });

    it("writeStringBytes preserves embedded NUL bytes", () => {
        const h = new DataHandle("test");
        const data = Uint8Array.of(0x61, 0x00, 0x62);
        lf.io.writeStringBytes(h, data);
        h.position = 0;
        const back = lf.io.readStringBytes(h);
        assert.deepEqual(Array.from(back), [0x61]);
        h.dispose();
    });

    it("writeStringBytes / readStringBytes round-trip (no embedded NUL)", () => {
        const h = new DataHandle("test");
        const data = Uint8Array.of(1, 2, 3, 4);
        lf.io.writeStringBytes(h, data);
        h.position = 0;
        const back = lf.io.readStringBytes(h);
        assert.deepEqual(Array.from(back), [1, 2, 3, 4]);
        h.dispose();
    });

    it("readAllBytes ignores NUL framing", () => {
        const h = new DataHandle("test");
        lf.io.writeStringBytes(h, Uint8Array.of(1, 2));
        h.position = 0;
        const back = lf.io.readAllBytes(h);
        assert.deepEqual(Array.from(back), [1, 2, 0]);
        h.dispose();
    });

    it("writeJson rejects a non-DataHandle argument", () => {
        assert.throws(
            () => lf.io.writeJson({} as unknown as DataHandle, { a: 1 }),
            TypeError);
    });

    it("readJson rejects a non-DataHandle argument", () => {
        assert.throws(
            () => lf.io.readJson({} as unknown as DataHandle),
            TypeError);
    });
});

// -----------------------------------------------------------------------------
//  5. AppHandle
// -----------------------------------------------------------------------------

describe("AppHandle", () => {
    it("has the configured name", () => {
        assert.equal(requireApp().name, "JsTest");
    });

    it("is valid while alive", () => {
        assert.equal(requireApp().isValid, true);
        assert.notEqual(requireApp().raw, null);
    });

    it("constructor rejects a non-string name", () => {
        assert.throws(
            () => new lf.AppHandle(42 as unknown as string),
            TypeError);
    });

    it("registerCall returns false on a duplicate name", () => {
        const ok = requireApp().registerCall("add", "dup", () => { });
        assert.equal(ok, false);
    });

    it("registerNotify returns false on a duplicate name", () => {
        const ok = requireApp().registerNotify("log", "dup", () => { });
        assert.equal(ok, false);
    });

    it("unregister returns false for an unknown name", () => {
        assert.equal(requireApp().unregister("does-not-exist"), false);
    });

    it("localCall invokes the callback and returns a result", () => {
        const param = new DataHandle("add");
        lf.io.writeJson(param, { a: 10, b: 32 });

        const result = requireApp().localCall(param);
        try {
            assert.equal(result.size > 0, true);
            assert.deepEqual(
                lf.io.readJson<{ result: number }>(result),
                { result: 42 });
        }
        finally {
            param.dispose();
            result.dispose();
        }
    });

    it("localCall with a missing API returns an empty handle", () => {
        const param = new DataHandle("nonexistent");
        lf.io.writeJson(param, { a: 1 });

        const result = requireApp().localCall(param);
        try {
            assert.equal(result.size, 0);
        }
        finally {
            param.dispose();
            result.dispose();
        }
    });

    it("localNotify fires the callback asynchronously", async () => {
        lastCallbackError = null;

        const param = new DataHandle("log");
        lf.io.writeJson(param, { marker: "notify-test" });

        requireApp().localNotify(param);
        param.dispose();

        const delivered = await waitFor(
            () => lastCallbackError !== null &&
                lastCallbackError.source === "test.log",
            1000);
        assert.equal(delivered, true);
    });

    it("localCall rejects a non-DataHandle argument", () => {
        assert.throws(
            () => requireApp().localCall({} as unknown as DataHandle),
            TypeError);
    });

    it("localNotify rejects a non-DataHandle argument", () => {
        assert.throws(
            () => requireApp().localNotify({} as unknown as DataHandle),
            TypeError);
    });

    it("a disposed AppHandle rejects further operations", () => {
        const tmp = new lf.AppHandle("JsTestTmp", "temporary");
        tmp.dispose();
        assert.equal(tmp.isValid, false);
        assert.throws(
            () => tmp.registerCall("x", "x", () => { }),
            lf.LingoFuseObjectDisposedError);
    });
});

// -----------------------------------------------------------------------------
//  6. framework
// -----------------------------------------------------------------------------

describe("framework", () => {
    it("checkMainThread reports the framework is running", () => {
        assert.equal(lf.status.checkMainThread(), true);
    });

    it("checkApp finds the shared application", () => {
        assert.equal(lf.status.checkApp("JsTest"), true);
    });

    it("checkApp returns false for an unknown name", () => {
        assert.equal(lf.status.checkApp("DefinitelyNotAnApp_12345"), false);
    });

    it("checkApi finds a registered API", () => {
        assert.equal(lf.status.checkApi("JsTest", "add"), true);
        assert.equal(lf.status.checkApi("JsTest", "echo"), true);
        assert.equal(lf.status.checkApi("JsTest", "log"), true);
    });

    it("checkApi returns false for an unknown API", () => {
        assert.equal(
            lf.status.checkApi("JsTest", "definitely-not-registered"),
            false);
    });

    it("checkApp rejects a non-string argument", () => {
        assert.throws(
            () => lf.status.checkApp(42 as unknown as string),
            TypeError);
    });

    it("checkApi rejects non-string arguments", () => {
        assert.throws(
            () => lf.status.checkApi(42 as unknown as string, "x"),
            TypeError);
        assert.throws(
            () => lf.status.checkApi("x", 42 as unknown as string),
            TypeError);
    });

    it("call routes through the mesh and reaches the local instance", () => {
        const param = new DataHandle("add");
        lf.io.writeJson(param, { a: 1, b: 2 });

        const result = lf.framework.call("JsTest", param, 5000);
        try {
            assert.equal(result.size > 0, true);
            assert.deepEqual(
                lf.io.readJson<{ result: number }>(result),
                { result: 3 });
        }
        finally {
            param.dispose();
            result.dispose();
        }
    });

    it("call to an unknown target returns an empty handle", () => {
        const param = new DataHandle("add");
        lf.io.writeJson(param, { a: 1, b: 2 });

        const result = lf.framework.call(
            "DefinitelyNotAnApp_12345", param, 500);
        try {
            assert.equal(result.size, 0);
        }
        finally {
            param.dispose();
            result.dispose();
        }
    });

    it("call rejects a non-string appName", () => {
        const param = new DataHandle("add");
        try {
            assert.throws(
                () => lf.framework.call(42 as unknown as string, param, 500),
                TypeError);
        }
        finally {
            param.dispose();
        }
    });

    it("call rejects a non-DataHandle param", () => {
        assert.throws(
            () => lf.framework.call("JsTest", {} as unknown as DataHandle, 500),
            TypeError);
    });

    it("call rejects a negative timeout", () => {
        const param = new DataHandle("add");
        try {
            assert.throws(
                () => lf.framework.call("JsTest", param, -1),
                RangeError);
        }
        finally {
            param.dispose();
        }
    });

    it("notify rejects a non-DataHandle param", () => {
        assert.throws(
            () => lf.framework.notify("JsTest", {} as unknown as DataHandle),
            TypeError);
    });

    it("sequencedNotify rejects a non-DataHandle param", () => {
        assert.throws(
            () => lf.framework.sequencedNotify("JsTest", {} as unknown as DataHandle),
            TypeError);
    });

    it("setOption rejects non-string arguments", () => {
        assert.throws(
            () => lf.framework.setOption(42 as unknown as string, "x"),
            TypeError);
        assert.throws(
            () => lf.framework.setOption("x", 42 as unknown as string),
            TypeError);
    });

    it("prepareService rejects non-string arguments", () => {
        assert.throws(
            () => lf.framework.prepareService(42 as unknown as string, "x"),
            TypeError);
        assert.throws(
            () => lf.framework.prepareService("x", 42 as unknown as string),
            TypeError);
    });

    it("prepareClient rejects a non-string address", () => {
        assert.throws(
            () => lf.framework.prepareClient(42 as unknown as string, null),
            TypeError);
    });

    it("prepareClient rejects a non-AppHandle application", () => {
        assert.throws(
            () => lf.framework.prepareClient("ipc:x", {} as unknown as lf.AppHandle),
            TypeError);
    });

    it("generateAppName returns a string after prepareDone", () => {
        const name = lf.framework.generateAppName();
        assert.equal(typeof name, "string");
        assert.ok(name.length > 0);
    });
});

// -----------------------------------------------------------------------------
//  7. status
// -----------------------------------------------------------------------------

describe("status", () => {
    it("getStatusCount returns a non-negative integer", () => {
        const n = lf.status.getStatusCount();
        assert.equal(Number.isInteger(n), true);
        assert.ok(n >= 0);
    });

    it("getStatus returns a string", () => {
        const s = lf.status.getStatus();
        assert.equal(typeof s, "string");
    });

    it("drainStatus returns an array of strings", () => {
        const messages = lf.status.drainStatus(16);
        assert.ok(Array.isArray(messages));
        for (const m of messages) {
            assert.equal(typeof m, "string");
        }
    });

    it("drainStatus(0) returns an empty array", () => {
        assert.deepEqual(lf.status.drainStatus(0), []);
    });

    it("drainStatus rejects a negative argument", () => {
        assert.throws(() => lf.status.drainStatus(-1), RangeError);
    });

    it("drainStatus rejects a non-number argument", () => {
        assert.throws(
            () => lf.status.drainStatus("x" as unknown as number),
            TypeError);
    });

    it("postStatus accepts a string", () => {
        lf.status.postStatus("test marker");
    });

    it("postStatus rejects a non-string argument", () => {
        assert.throws(
            () => lf.status.postStatus(42 as unknown as string),
            TypeError);
    });
});

// -----------------------------------------------------------------------------
//  8. callbacks
// -----------------------------------------------------------------------------

describe("callbacks", () => {
    it("setCallbackErrorHandler accepts a function", () => {
        const previous = lf.framework.getCallbackErrorHandler();
        try {
            lf.framework.setCallbackErrorHandler(() => { });
            assert.equal(
                typeof lf.framework.getCallbackErrorHandler(),
                "function");
        }
        finally {
            lf.framework.setCallbackErrorHandler(previous);
        }
    });

    it("setCallbackErrorHandler accepts null", () => {
        const previous = lf.framework.getCallbackErrorHandler();
        try {
            lf.framework.setCallbackErrorHandler(null);
            assert.equal(lf.framework.getCallbackErrorHandler(), null);
        }
        finally {
            lf.framework.setCallbackErrorHandler(previous);
        }
    });

    it("setCallbackErrorHandler rejects a non-function", () => {
        assert.throws(
            () => lf.framework.setCallbackErrorHandler(42 as unknown as () => void),
            TypeError);
    });

    it("a throwing callback does not crash the process", () => {
        const tmpApp = new lf.AppHandle("JsTestThrow", "throwing callback");
        tmpApp.registerCall("boom", "always throws", () => {
            throw new Error("intentional test failure");
        });

        const param = new DataHandle("boom");
        try {
            const result = tmpApp.localCall(param);
            assert.equal(result.size, 0);
            result.dispose();
        }
        finally {
            param.dispose();
            tmpApp.dispose();
        }

        assert.equal(lf.status.checkMainThread(), true);
    });

    it("the process-level error handler receives the exception", async () => {
        const recorded: Array<{ source: string; err: unknown }> = [];
        const previous = lf.framework.getCallbackErrorHandler();
        lf.framework.setCallbackErrorHandler((source, err) => {
            recorded.push({ source, err });
        });

        try {
            const tmpApp = new lf.AppHandle("JsTestRecord", "recorded error");
            tmpApp.registerCall("boom", "always throws", () => {
                throw new Error("recorded failure");
            });

            const param = new DataHandle("boom");
            try {
                const result = tmpApp.localCall(param);
                result.dispose();
            }
            finally {
                param.dispose();
                tmpApp.dispose();
            }

            const delivered = await waitFor(() => recorded.length > 0, 500);
            assert.equal(delivered, true);
            assert.match(recorded[0].source, /boom/);
            assert.ok(recorded[0].err instanceof Error);
            assert.equal(
                (recorded[0].err as Error).message,
                "recorded failure");
        }
        finally {
            lf.framework.setCallbackErrorHandler(previous);
        }
    });
});

// -----------------------------------------------------------------------------
//  9. network events
// -----------------------------------------------------------------------------

describe("network events", () => {
    it("isNetworkEventInstalled reports false initially", () => {
        assert.equal(lf.network.isNetworkEventInstalled(), false);
    });

    it("setNetworkEvent installs handlers and reports the state", () => {
        lf.network.setNetworkEvent(() => { }, () => { });
        assert.equal(lf.network.isNetworkEventInstalled(), true);
        lf.network.clearNetworkEvent();
        assert.equal(lf.network.isNetworkEventInstalled(), false);
    });

    it("setNetworkEvent accepts null for either handler", () => {
        lf.network.setNetworkEvent(null, null);
        assert.equal(lf.network.isNetworkEventInstalled(), false);
    });

    it("clearNetworkEvent is idempotent", () => {
        lf.network.clearNetworkEvent();
        lf.network.clearNetworkEvent();
        assert.equal(lf.network.isNetworkEventInstalled(), false);
    });

    it("setNetworkEvent rejects a non-function, non-null argument", () => {
        assert.throws(
            () => lf.network.setNetworkEvent(42 as unknown as () => void, null),
            TypeError);
        assert.throws(
            () => lf.network.setNetworkEvent(null, 42 as unknown as () => void),
            TypeError);
    });

    it("setNetworkEventListener accepts a listener instance", () => {
        class Listener extends lf.network.NetworkEventListener { }
        const listener = new Listener();
        try {
            lf.network.setNetworkEventListener(listener);
            assert.equal(lf.network.isNetworkEventInstalled(), true);
        }
        finally {
            lf.network.clearNetworkEvent();
        }
    });

    it("setNetworkEventListener rejects a non-listener instance", () => {
        assert.throws(
            () => lf.network.setNetworkEventListener({} as unknown as lf.network.NetworkEventListener),
            TypeError);
    });

    it("NetworkEventListener base class has no-op methods", () => {
        class Listener extends lf.network.NetworkEventListener { }
        const listener = new Listener();
        listener.onConnect("addr");
        listener.onDisconnect("addr");
    });
});

// =============================================================================
//  Section 7 - Runner
// =============================================================================

function detectRuntimeLabel(): string {
    if (typeof (globalThis as { Deno?: unknown }).Deno !== "undefined") return "Deno";
    if (typeof (globalThis as { Bun?: unknown }).Bun !== "undefined") return "Bun";
    if (typeof process !== "undefined" &&
        process.versions &&
        process.versions.node) {
        return `Node.js ${process.versions.node}`;
    }
    return "Unknown";
}

async function runAll(): Promise<number> {
    console.log("LingoFuse TypeScript binding - test suite");
    console.log(`Runtime: ${detectRuntimeLabel()}`);
    console.log("");

    let setupFailed = false;
    let setupError: unknown = null;

    if (beforeAllFn !== null) {
        try {
            await beforeAllFn();
        }
        catch (err) {
            setupFailed = true;
            setupError = err;
        }
    }

    let passed = 0;
    let failed = 0;

    if (setupFailed) {
        const detail = setupError instanceof Error
            ? setupError.stack ?? setupError.message
            : String(setupError);
        console.error("[SETUP FAILED]");
        console.error(detail);
        console.error("");
        console.error("All tests are skipped because the shared setup did not complete.");
        console.error("");
    }

    for (const suite of SUITES) {
        console.log(`  ${suite.name}`);
        for (const testCase of suite.tests) {
            if (setupFailed) {
                console.log(`    - ${testCase.name} (skipped)`);
                continue;
            }
            try {
                await testCase.fn();
                passed += 1;
                console.log(`    \u2713 ${testCase.name}`);
            }
            catch (err) {
                failed += 1;
                const message = err instanceof Error ? err.message : String(err);
                console.log(`    \u2717 ${testCase.name}`);
                console.log(`        ${message}`);
            }
        }
    }

    if (afterAllFn !== null) {
        try {
            await afterAllFn();
        }
        catch (err) {
            const detail = err instanceof Error
                ? err.stack ?? err.message
                : String(err);
            console.error("[TEARDOWN FAILED]");
            console.error(detail);
        }
    }

    console.log("");
    console.log("Summary");
    console.log(`  runtime : ${detectRuntimeLabel()}`);
    console.log(`  passed  : ${passed}`);
    console.log(`  failed  : ${failed}`);
    console.log(`  total   : ${passed + failed}`);

    if (setupFailed) return 1;
    return failed === 0 ? 0 : 1;
}

runAll()
    .then((code) => {
        process.exitCode = code;
    })
    .catch((err: unknown) => {
        console.error("");
        console.error("[FATAL] The test runner itself crashed:");
        console.error(err instanceof Error
            ? err.stack ?? err.message
            : String(err));
        process.exitCode = 1;
    });