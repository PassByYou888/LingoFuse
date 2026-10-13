/**
 * @file test_lingofuse_uid.c
 * @brief UID identity-injection verification test.
 *
 * Goal
 * ----
 * Verify that a UID injected by the framework on the sender side is
 * correctly transmitted to a receiving callback and returned to the
 * caller via LF_Get_P2P_UID, WITHOUT any data corruption across the
 * struct-by-value / pointer-return C ABI boundary.
 *
 * Why this matters
 * ----------------
 * The Pascal-side type TP2P_UID___ is `array[0..31] of Byte`. On the C
 * side it is exposed in TWO DIFFERENT ROLES with TWO DIFFERENT C TYPES:
 *
 *   ARGUMENT role (e.g. the first parameter of LF_UID_Call, LF_Check_UID,
 *   LF_WriteUid, LF_ReadUid): `TP2P_UID`, the 32-byte struct, passed by
 *   value.
 *
 *   RETURN role (only LF_Get_P2P_UID): `const TP2P_UID*`, a pointer to a
 *   library-owned 32-byte UID released by the library ~5 seconds after
 *   the call.
 *
 * The Pascal signature of the return-role function is:
 *
 *     function LF_Get_P2P_UID(Hnd: TDataHnd___): PP2P_UID___;
 *
 * i.e. ^TUID___ (a pointer), NOT TUID___ (the value). An earlier revision
 * of the ABI returned the 32-byte UID by value and the Python binding had
 * to work around the x64 SRet convention with a ctypes Structure. The
 * current ABI eliminates that workaround.
 *
 * {!!!!!  SIDE-DATA SEMANTICS  !!!!!}
 * The UID that LF_Get_P2P_UID reads is NOT a property of the handle
 * itself. It is "side data" written by the SENDER'S transport layer into
 * every request payload before transmission. Pascal side, for reference:
 *
 *     TC40_LF_Client.Send_*
 *         -> TMemory_Param_Tool.Rebuild_UID_and_P2PName
 *         -> writes two identity fields into the payload header:
 *                FromUID       (32 bytes)
 *                FromP2PName   (UTF-8 string)
 *
 * The receiver therefore sees these two fields inside the Data_Param of
 * the INPUT handle it receives from the framework. Because of this:
 *
 *     VALID    -- the `input` argument of a registered Call / Notify
 *                 callback, or the input of a local call.
 *     INVALID  -- an OUTPUT handle, or a caller-created handle. The
 *                 library logs a warning and returns a pointer to a
 *                 zero-filled UID / empty P2P name.
 *
 * This test detects any divergence in the SENDER-INJECTION path by
 * exercising the FULL route:
 *
 *   sender: Rebuild_UID_and_P2PName  ->  wire payload
 *   receiver: DecryptFromMem          ->  Data_Param.FromUID
 *   callback: LF_Get_P2P_UID(Input)   ->  returns const TP2P_UID*
 *   callback: *uid_ptr                ->  copy the 32-byte value locally
 *   callback: LF_WriteUid(out, uid)   ->  echo the value back
 *   C caller: LF_ReadUid(result, &r)  ->  receive the 32-byte value
 *
 * Verification strategy
 * ---------------------
 *   1. Register a `whoami` Call API whose only job is to echo back the
 *      UID and P2P name it sees on the input handle.
 *   2. Call `whoami` twice from the same client session.
 *   3. Assert:
 *        (a) both calls return a NON-zero UID, and
 *        (b) both calls return the SAME UID, and
 *        (c) the P2P name we set is echoed back verbatim, and
 *        (d) the callback-side snapshot agrees with the wire round-trip.
 *
 * A non-zero return value alone would be consistent with random stack
 * garbage. The "two calls agree" check makes garbage an extremely
 * unlikely explanation: garbage would have to be identical across two
 * independent dispatches.
 *
 * ============================================================================
 * WHY `Wait_Connection_ReadyOk = True` IS REQUIRED HERE
 * ============================================================================
 * An earlier revision of this test set `Wait_Connection_ReadyOk = False`
 * in the belief that, since service and client live in the SAME process,
 * `LF_Call` would immediately fall through to local-first routing and
 * never need the network.
 *
 * That belief was WRONG, for a subtle reason:
 *
 *   - `LF_Call` is issued from the CURRENT CLIENT's perspective, not from
 *     the service's. It routes through the client's `Wait_Execute_Call`
 *     path.
 *
 *   - The identity-injection step (`Rebuild_UID_and_P2PName`) is performed
 *     by the CLIENT SEND SIDE before the request leaves the caller. Even
 *     for local-first routing, the payload must have been rebuilt first.
 *
 *   - The client's `FLast_UID` is only generated when `TunnelLink`
 *     succeeds (`Client.TunnelLink: uid regenerated`). Before that, the
 *     client has no UID to inject.
 *
 *   - `Wait_Connection_ReadyOk = False` makes `LF_PrepareDone` return
 *     BEFORE the client's `TunnelLink` completes. A `LF_Call` issued
 *     immediately afterwards times out because the client is still in
 *     the middle of establishing its connection.
 *
 * Therefore this test uses the DEFAULT (`Wait_Connection_ReadyOk = True`)
 * so that `LF_PrepareDone` blocks until the client is online and its
 * `FLast_UID` is available. Only then can a `whoami` call actually
 * observe a non-empty injected UID.
 *
 * Environment
 * -----------
 * Quiet mode is explicitly DISABLED so the [LF-DEBUG] trace is visible.
 * This is diagnostic output only, not a test assertion.
 *
 * ============================================================================
 * CLEANUP CONTRACT
 * ============================================================================
 * Every exit path (success or failure) MUST run the same teardown
 * sequence:
 *
 *     LF_ExitMainThread()  ->  LF_FreeApp(app)  ->  LF_Shutdown()
 *
 * Returning from `main()` without running the teardown leaves the DLL in
 * a mid-initialised state; when the process exits and the DLL finaliser
 * runs, it can crash (observed: access violation inside TLF_App.Destroy).
 * This file therefore uses a `goto cleanup` pattern so that no early
 * return can bypass the teardown.
 */

#if defined(_WIN32) && !defined(_CRT_SECURE_NO_WARNINGS)
#  define _CRT_SECURE_NO_WARNINGS
#endif

#include "LingoFuse.h"

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

 /* ============================================================================
  *  Tiny assertion framework (same shape as test_lingofuse_capi.c)
  * ============================================================================ */

static int g_tests_run = 0;
static int g_tests_passed = 0;
static int g_tests_failed = 0;
static int g_current_ok = 1;

static void section_header(const char* title) {
    printf("\n\n");
    printf("======================================================================\n");
    printf("  %s\n", title);
    printf("======================================================================\n");
}

static void begin_test(const char* name) {
    g_current_ok = 1;
    printf("\n[ %s ]\n", name);
}

static void end_test(void) {
    ++g_tests_run;
    if (g_current_ok) {
        ++g_tests_passed;
        printf("[ PASS ]\n");
    }
    else {
        ++g_tests_failed;
        printf("[ FAIL ]\n");
    }
}

#define CHECK(cond)                                                        \
    do {                                                                   \
        if (!(cond)) {                                                     \
            printf("    [CHECK FAILED] %s  (line %d)\n", #cond, __LINE__); \
            g_current_ok = 0;                                              \
        }                                                                  \
    } while (0)

/* ============================================================================
 *  Test constants
 * ============================================================================ */

static const char* kEndpoint = "ipc:test_uid_verify";
static const char* kServiceApp = "TestUidSvc";
static const char* kWhoamiApi = "whoami";
static const char* kP2PName = "uid_verify_group";

/* ============================================================================
 *  Global state captured by the whoami callback
 * ============================================================================ */

static int      g_whoami_calls = 0;
static int      g_whoami_uid_ptr_nonnull[2] = { 0, 0 };
static int      g_whoami_uid_nonzero[2] = { 0, 0 };
static TP2P_UID g_whoami_uid[2];
static char     g_whoami_p2p_name[2][256];
static char     g_whoami_p2p_name_ptr_nonnull[2] = { 0, 0 };

/* ============================================================================
 *  Helpers
 * ============================================================================ */

static void uid_to_hex(const TP2P_UID* uid, char out[65]) {
    static const char hex[] = "0123456789abcdef";
    int i;
    for (i = 0; i < 32; ++i) {
        out[i * 2] = hex[(uid->bytes[i] >> 4) & 0x0F];
        out[i * 2 + 1] = hex[uid->bytes[i] & 0x0F];
    }
    out[64] = '\0';
}

static int uid_is_all_zero(const TP2P_UID* uid) {
    int i;
    for (i = 0; i < 32; ++i) {
        if (uid->bytes[i] != 0) return 0;
    }
    return 1;
}

/* ============================================================================
 *  whoami callback
 * ----------------------------------------------------------------------------
 *  Reads the framework-injected identity from the INPUT handle and writes
 *  it back to the OUTPUT handle as:
 *
 *      [32 bytes UID][NUL-terminated P2P name]
 *
 *  It also records a snapshot into the global arrays so that the main
 *  function can compare snapshots across calls without relying on the
 *  round-trip alone.
 *
 *  {!!!!!  UID POINTER LIFETIME  !!!!!}
 *  LF_Get_P2P_UID returns a `const TP2P_UID*` allocated by the library.
 *  The pointer is scheduled for automatic release about 5 seconds after
 *  the call. We therefore:
 *
 *      1. Check the pointer for NULL (only fails if the library was not
 *         loaded, which is impossible inside a callback).
 *      2. Dereference it ONCE and copy the 32 bytes into a local
 *         `TP2P_UID` value.
 *      3. Never retain the pointer beyond this callback body.
 *      4. Never free the pointer.
 *
 *  LF_Get_P2P_Name follows the same rule: the returned `const char*`
 *  points to a transient buffer released after ~5 seconds. We copy the
 *  string immediately into our own fixed-size buffer.
 * ============================================================================ */

static void LF_CDECL whoami_cb(void* trigger, void* input, void* output) {
    TDataHnd         in = (TDataHnd)input;
    TDataHnd         out = (TDataHnd)output;
    const TP2P_UID* uid_ptr;
    TP2P_UID         uid;
    const char* name;
    int              slot;

    (void)trigger;

    /* Initialize the local UID value so that a defensive caller would
       still see a well-defined value if the pointer were NULL. */
    memset(&uid, 0, sizeof(uid));

    /* The value whose byte layout the whole test exists to verify.
     *
     * The RETURN-role pointer is dereferenced exactly once and the
     * 32 bytes are copied locally. The pointer is NOT retained. */
    uid_ptr = LF_Get_P2P_UID(in);

    /* The P2P group name, also injected by the framework. The returned
     * pointer is a transient buffer; copy the string immediately. */
    name = LF_Get_P2P_Name(in);

    slot = g_whoami_calls;
    if (slot > 1) slot = 1;   /* only the first two calls are recorded */

    g_whoami_uid_ptr_nonnull[slot] = (uid_ptr != NULL) ? 1 : 0;

    if (uid_ptr != NULL) {
        uid = *uid_ptr;       /* copy 32 bytes out of the library buffer */
    }

    g_whoami_uid_nonzero[slot] = uid_is_all_zero(&uid) ? 0 : 1;
    memcpy(g_whoami_uid[slot].bytes, uid.bytes, 32);

    g_whoami_p2p_name_ptr_nonnull[slot] = (name != NULL) ? 1 : 0;

    if (name != NULL) {
        strncpy(g_whoami_p2p_name[slot], name,
            sizeof(g_whoami_p2p_name[slot]) - 1);
        g_whoami_p2p_name[slot][sizeof(g_whoami_p2p_name[slot]) - 1] = '\0';
    }
    else {
        g_whoami_p2p_name[slot][0] = '\0';
    }

    ++g_whoami_calls;

    /* Echo both identity fields back to the caller.
     *
     * LF_WriteUid takes the ARGUMENT-role `TP2P_UID` (by value). This is
     * the value we just copied out of the library's transient buffer, so
     * the wire round-trip is independent of the library's release timing. */
    LF_WriteUid(out, uid);
    LF_WriteString(out, g_whoami_p2p_name[slot]);
}

/* ============================================================================
 *  One whoami call + response parsing
 * ============================================================================ */

typedef struct WhoamiResult_s {
    int      ok;
    TP2P_UID uid;
    char     p2p_name[256];
} WhoamiResult;

static WhoamiResult call_whoami(void) {
    WhoamiResult r;
    TDataHnd     param;
    TDataHnd     result;

    memset(&r, 0, sizeof(r));

    param = LF_CreateData(kWhoamiApi);
    if (param == NULL) return r;

    /* No payload needed: the callback only reads the injected identity. */

    result = LF_Call(kServiceApp, param, 5000);
    LF_FreeData(param);

    if (result == NULL) {
        return r;
    }
    if (LF_GetSize(result) == 0) {
        /* Empty result: call timed out or target unreachable. */
        LF_FreeData(result);
        return r;
    }

    LF_SetPos(result, 0);

    if (!LF_ReadUid(result, &r.uid)) {
        LF_FreeData(result);
        return r;
    }
    if (!LF_ReadString(result, r.p2p_name, sizeof(r.p2p_name))) {
        LF_FreeData(result);
        return r;
    }

    LF_FreeData(result);
    r.ok = 1;
    return r;
}

/* ============================================================================
 *  main
 * ============================================================================ */

int main(void) {
    TAppHnd      app = NULL;
    char         hex_a[65] = { 0 };
    char         hex_b[65] = { 0 };
    int          ret_prepare_done;
    int          prepare_done_ok = 0;
    int          app_created = 0;
    int          prepare_reset = 0;
    WhoamiResult r1;
    WhoamiResult r2;
    int          i;
    int          exit_code = EXIT_FAILURE;

    printf("======================================================================\n");
    printf("  LingoFuse UID Identity-Injection Verification\n");
    printf("======================================================================\n");
    printf("  Purpose : verify that a UID injected on the sender side survives\n");
    printf("            the pointer-return ABI boundary and reaches the\n");
    printf("            receiving callback intact.\n");
    printf("  Method  : register a `whoami` API that echoes back the identity\n");
    printf("            of its caller; call it twice and compare.\n");
    printf("\n");
    printf("  ABI role in play:\n");
    printf("    LF_Get_P2P_UID   -> const TP2P_UID*  (RETURN-role pointer)\n");
    printf("    LF_WriteUid      -> TP2P_UID         (ARGUMENT-role struct)\n");
    printf("    LF_ReadUid       -> TP2P_UID*        (ARGUMENT-role out param)\n");

    /* ------------------------------------------------------------------
     * Step 1: load library
     * ------------------------------------------------------------------ */
    section_header("Step 1: Library loading");
    if (LF_LoadLibrary() != 1) {
        fprintf(stderr, "FATAL: LF_LoadLibrary failed\n");
        return EXIT_FAILURE;
    }

    /* ------------------------------------------------------------------
     * Step 2: runtime configuration
     *
     * Quiet is EXPLICITLY DISABLED so the [LF-DEBUG] trace is visible.
     *
     * {!!!!!  Wait_Connection_ReadyOk IS LEFT AT ITS DEFAULT (True)  !!!!!}
     * An earlier revision set this to False on the assumption that
     * same-process local-first routing would make LF_Call succeed
     * immediately. That was wrong: the identity-injection step
     * (Rebuild_UID_and_P2PName) is performed by the CLIENT before the
     * request leaves the caller, and the client's FLast_UID is only
     * generated when TunnelLink succeeds. Letting LF_PrepareDone return
     * before that point causes LF_Call to time out.
     *
     * LF_PrepareDone must therefore block until the client is online.
     * That is the DEFAULT behaviour, so we simply do not change it.
     *
     * The Wait_Connection_Timeout is raised a little above the default
     * so that a slow CI machine has room to complete the handshake.
     * ------------------------------------------------------------------ */
    section_header("Step 2: Runtime configuration");
    printf("  Setting Quiet = False  (verbose [LF-DEBUG] trace will follow)\n");
    LF_SetOption("Quiet", "False");

    printf("  Setting Overlap_Connection = True\n");
    LF_SetOption("Overlap_Connection", "True");

    printf("  Setting Wait_Connection_Timeout = 15000 ms\n");
    LF_SetOption("Wait_Connection_Timeout", "15000");

    printf("  Setting LF_P2P_name = \"%s\"\n", kP2PName);
    LF_SetOption("LF_P2P_name", kP2PName);

    printf("  (Wait_Connection_ReadyOk left at default: True)\n");

    /* ------------------------------------------------------------------
     * Step 3: create service App and register whoami
     * ------------------------------------------------------------------ */
    section_header("Step 3: Create service App and register whoami");
    app = LF_CreateApp(kServiceApp, "UID verification service");
    if (app == NULL) {
        fprintf(stderr, "FATAL: LF_CreateApp failed\n");
        goto cleanup;
    }
    app_created = 1;

    if (LF_RegisterCall(app, kWhoamiApi,
        "echo back the injected identity",
        NULL, whoami_cb) != 1) {
        fprintf(stderr, "FATAL: LF_RegisterCall failed\n");
        goto cleanup;
    }
    printf("  Registered Call API '%s'\n", kWhoamiApi);

    /* ------------------------------------------------------------------
     * Step 4: prepare network
     * ------------------------------------------------------------------ */
    section_header("Step 4: Prepare network");
    LF_ResetPrepare();
    prepare_reset = 1;

    if (LF_PrepareService(kEndpoint, kEndpoint) < 0) {
        fprintf(stderr, "FATAL: LF_PrepareService failed\n");
        goto cleanup;
    }
    if (LF_PrepareClient(kEndpoint, app) < 0) {
        fprintf(stderr, "FATAL: LF_PrepareClient failed\n");
        goto cleanup;
    }

    ret_prepare_done = LF_PrepareDone();
    if (ret_prepare_done != 1) {
        fprintf(stderr,
            "FATAL: LF_PrepareDone returned %d\n", ret_prepare_done);
        goto cleanup;
    }
    prepare_done_ok = 1;

    /* Defensive short poll: with Wait_Connection_ReadyOk = True the
       handshake is complete by the time LF_PrepareDone returns, so the
       local API cache should already be populated. The loop is kept
       only as a belt-and-braces check; a failure is a warning, not a
       fatal error, because the actual verification is done by the
       whoami call below. */
    printf("  Short poll for local API visibility (informational)...\n");
    for (i = 0; i < 5; ++i) {
        if (LF_CheckApi(kServiceApp, kWhoamiApi)) {
            printf("  Local API visible after %d poll(s).\n", i + 1);
            break;
        }
        {
            volatile long k;
            for (k = 0; k < 2000000L; ++k) { /* ~20 ms */ }
        }
    }
    if (i >= 5) {
        printf("  NOTE: local API not visible via LF_CheckApi within 5 polls;\n");
        printf("        proceeding anyway. The whoami call below is the\n");
        printf("        authoritative check.\n");
    }

    /* ------------------------------------------------------------------
     * Step 5: first whoami call
     * ------------------------------------------------------------------ */
    section_header("Step 5: First whoami call");
    r1 = call_whoami();
    if (!r1.ok) {
        fprintf(stderr, "FATAL: first whoami call failed\n");
        goto cleanup;
    }
    uid_to_hex(&r1.uid, hex_a);
    printf("  Response UID  : %s\n", hex_a);
    printf("  Response name : \"%s\"\n", r1.p2p_name);

    /* ------------------------------------------------------------------
     * Step 6: second whoami call (same session)
     * ------------------------------------------------------------------ */
    section_header("Step 6: Second whoami call (same session)");
    r2 = call_whoami();
    if (!r2.ok) {
        fprintf(stderr, "FATAL: second whoami call failed\n");
        goto cleanup;
    }
    uid_to_hex(&r2.uid, hex_b);
    printf("  Response UID  : %s\n", hex_b);
    printf("  Response name : \"%s\"\n", r2.p2p_name);

    /* ------------------------------------------------------------------
     * Step 7: assertions
     * ------------------------------------------------------------------ */
    section_header("Step 7: Verification");

    begin_test("UID :: callback received a non-NULL pointer from LF_Get_P2P_UID");
    CHECK(g_whoami_calls >= 2);
    if (g_whoami_calls >= 2) {
        CHECK(g_whoami_uid_ptr_nonnull[0] == 1);
        CHECK(g_whoami_uid_ptr_nonnull[1] == 1);
    }
    end_test();

    begin_test("UID :: callback received a non-NULL pointer from LF_Get_P2P_Name");
    CHECK(g_whoami_calls >= 2);
    if (g_whoami_calls >= 2) {
        CHECK(g_whoami_p2p_name_ptr_nonnull[0] == 1);
        CHECK(g_whoami_p2p_name_ptr_nonnull[1] == 1);
    }
    end_test();

    begin_test("UID :: first call returns a non-zero UID");
    CHECK(!uid_is_all_zero(&r1.uid));
    end_test();

    begin_test("UID :: second call returns a non-zero UID");
    CHECK(!uid_is_all_zero(&r2.uid));
    end_test();

    begin_test("UID :: both calls return the SAME UID (same session)");
    CHECK(memcmp(r1.uid.bytes, r2.uid.bytes, 32) == 0);
    end_test();

    begin_test("UID :: callback-side snapshot agrees with round-trip value");
    CHECK(g_whoami_calls >= 2);
    if (g_whoami_calls >= 2) {
        CHECK(memcmp(g_whoami_uid[0].bytes, r1.uid.bytes, 32) == 0);
        CHECK(memcmp(g_whoami_uid[1].bytes, r2.uid.bytes, 32) == 0);
    }
    end_test();

    begin_test("UID :: callback-side snapshot is non-zero");
    CHECK(g_whoami_calls >= 2);
    if (g_whoami_calls >= 2) {
        CHECK(g_whoami_uid_nonzero[0] == 1);
        CHECK(g_whoami_uid_nonzero[1] == 1);
    }
    end_test();

    begin_test("P2PName :: echoed name matches the value we set");
    CHECK(strcmp(r1.p2p_name, kP2PName) == 0);
    CHECK(strcmp(r2.p2p_name, kP2PName) == 0);
    end_test();

    /* ------------------------------------------------------------------
     * Step 8: ABI summary
     * ------------------------------------------------------------------ */
    section_header("Step 8: ABI summary");
    printf("  sizeof(TP2P_UID)               : %d\n", (int)sizeof(TP2P_UID));
    printf("  LF_Get_P2P_UID return type     : const TP2P_UID*  (pointer)\n");
    printf("  LF_WriteUid  argument type     : TP2P_UID         (struct)\n");
    printf("  LF_ReadUid   out argument type : TP2P_UID*        (pointer)\n");
    printf("  whoami callback count          : %d\n", g_whoami_calls);
    printf("  UID call #1                    : %s\n", hex_a);
    printf("  UID call #2                    : %s\n", hex_b);
    printf("  UID equality                   : %s\n",
        memcmp(r1.uid.bytes, r2.uid.bytes, 32) == 0
        ? "IDENTICAL" : "DIFFERENT");
    printf("\n");
    printf("  Interpretation:\n");
    printf("    - The callback received a non-NULL pointer from LF_Get_P2P_UID\n");
    printf("      and dereferenced it safely. A NULL there would be a\n");
    printf("      library-load order failure, not an identity failure.\n");
    printf("    - IDENTICAL + non-zero across two independent dispatches is\n");
    printf("      the expected result when the sender-side injection and the\n");
    printf("      pointer-return ABI agree.\n");
    printf("    - A zero UID means the sender-side injection did not happen,\n");
    printf("      or the receiver did not read it back correctly.\n");
    printf("    - A DIFFERENT UID across two calls in the SAME session means\n");
    printf("      the return-value path is producing garbage (the layout or\n");
    printf("      the calling convention does not match).\n");
    printf("\n");
    printf("  Lifecycle note:\n");
    printf("    - The pointer returned by LF_Get_P2P_UID is released by the\n");
    printf("      library about 5 seconds after the call. This test copies the\n");
    printf("      32 bytes out of the pointer IMMEDIATELY (inside the callback)\n");
    printf("      and never retains the pointer. The echo back to the caller\n");
    printf("      uses the copied value, so the wire round-trip is independent\n");
    printf("      of the library's release timing.\n");

    /* Success path reaches here. */
    if (g_tests_failed == 0) {
        exit_code = EXIT_SUCCESS;
    }

cleanup:
    /* ------------------------------------------------------------------
     * Step 9: teardown
     *
     * The cleanup sequence is FIXED (Pascal LF-CLEAN-001):
     *
     *     LF_ExitMainThread()  ->  LF_FreeApp()  ->  LF_Shutdown()
     *
     * Every exit path -- success, fatal error, or intermediate failure --
     * funnels through this label. Returning from main() without running
     * the teardown leaves the DLL in a mid-initialised state and can
     * crash the DLL finaliser on process exit.
     * ------------------------------------------------------------------ */
    section_header("Step 9: Teardown");

    if (prepare_done_ok) {
        printf("  LF_ExitMainThread()...\n");
        LF_ExitMainThread();
    }
    if (app_created) {
        printf("  LF_FreeApp()...\n");
        LF_FreeApp(app);
    }
    if (prepare_done_ok || prepare_reset) {
        printf("  LF_Shutdown()...\n");
        LF_Shutdown();
    }

    printf("\n\n");
    printf("======================================================================\n");
    printf("  Summary\n");
    printf("======================================================================\n");
    printf("  Tests run    : %d\n", g_tests_run);
    printf("  Tests passed : %d\n", g_tests_passed);
    printf("  Tests failed : %d\n", g_tests_failed);
    if (g_tests_failed == 0 && exit_code == EXIT_SUCCESS) {
        printf("\n  RESULT: ALL TESTS PASSED\n");
    }
    else if (g_tests_run == 0) {
        printf("\n  RESULT: NO TESTS RAN (setup failure)\n");
    }
    else {
        printf("\n  RESULT: %d TEST(S) FAILED\n", g_tests_failed);
    }
    printf("======================================================================\n");

    return exit_code;
}