// =============================================================================
// bridge_selftest.cpp
// -----------------------------------------------------------------------------
// Standalone self-test for the LingoFuse R bridge C++ layer (v2.0).
//
// This program links ONLY lf_bridge.cpp and lf_loader.h; it does NOT
// link lf_r_shim.c and therefore does NOT require R headers or R.dll.
// It exercises the lf_impl_* interface directly from C++, playing the
// role that lf_r_shim.c would otherwise play: constructing the exact
// C-level arguments that the R layer would produce.
//
// Coverage
// --------
//   Group 1  Build chain probes            (no runtime required)
//   Group 2  Runtime load                  (LF_LoadLibrary)
//   Group 3  Runtime options               (set / get, aliases, mask)
//   Group 4  DataHandle                    (create, IO, set_size, get_buffer)
//   Group 5  AppHandle + generate_app_name
//   Group 6  Process-wide P2P registration (register / duplicate / unregister)
//   Group 7  UID health checks             (32-byte by-value ABI test)
//   Group 8  Async dispatch failure path   (slot lifecycle)
//   Group 9  Job queries on NULL handles   (defensive)
//   Group 10 Full prepare cycle + status + shutdown
//
// The self-test deliberately does NOT attempt to call a live API on
// the local App. LingoFuse uses LOCAL-FIRST routing: calling
// lf_impl_call("BridgeSelfTest", ...) from the same process that
// registered the App would execute the trampoline on the CALLING
// thread, which would then block forever on the job queue. End-to-end
// Call / Notify coverage requires two processes and lives in the
// R-level test suite (caller_test.R / callee_test.R).
//
// Build (from c_ext/tests/):
//     g++ -std=c++17 -O2 -I../src ^
//         -o bridge_selftest.exe ^
//         bridge_selftest.cpp ../src/lf_bridge.cpp
//
// Run:
//     bridge_selftest.exe [runtime_dir]
//
// Runtime directory resolution (same order as lf_loader.h):
//     1. First command-line argument.
//     2. LINGOFUSE_RUNTIME environment variable.
//     3. Relative probes under the executable directory and the CWD.
//
// Exit code: 0 if every check passed, 1 otherwise.
// =============================================================================

#include "lf_r_shim.h"
#include "lf_loader.h"

#include <chrono>
#include <cstdarg>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <string>
#include <thread>
#include <vector>

// =============================================================================
// Test harness
// =============================================================================

namespace {

int g_pass = 0;
int g_fail = 0;
int g_group_pass = 0;
int g_group_fail = 0;

void section(const char* title)
{
    if (g_group_pass > 0 || g_group_fail > 0) {
        std::printf("      (%d passed, %d failed)\n",
                    g_group_pass, g_group_fail);
    }
    g_group_pass = 0;
    g_group_fail = 0;
    std::printf("\n");
    std::printf("=== %s ===\n", title);
}

void check(bool cond, const char* name)
{
    if (cond) {
        std::printf("  [PASS] %s\n", name);
        ++g_pass;
        ++g_group_pass;
    } else {
        std::printf("  [FAIL] %s\n", name);
        ++g_fail;
        ++g_group_fail;
    }
}

void check_str_eq(const char* got, const char* expected, const char* name)
{
    const bool ok =
        (got != nullptr) && (expected != nullptr) &&
        (std::strcmp(got, expected) == 0);
    if (ok) {
        std::printf("  [PASS] %s\n", name);
        ++g_pass;
        ++g_group_pass;
    } else {
        std::printf("  [FAIL] %s (got '%s', expected '%s')\n",
                    name,
                    got ? got : "<null>",
                    expected ? expected : "<null>");
        ++g_fail;
        ++g_group_fail;
    }
}

void info(const char* fmt, ...)
{
    std::printf("  [INFO] ");
    va_list ap;
    va_start(ap, fmt);
    std::vprintf(fmt, ap);
    va_end(ap);
    std::printf("\n");
}

} // namespace

// =============================================================================
// C callbacks used by the App registration step
// =============================================================================
// These are required because lf_impl_register_call_raw / _notify_raw
// take a trampoline that the runtime will call on a C4 worker
// thread. In this single-process self-test they are never actually
// invoked, but they must exist so that the registration succeeds.

extern "C" void selftest_call_cb(void* trigger, void* input, void* output)
{
    (void)trigger;
    (void)input;
    (void)output;
}

extern "C" void selftest_notify_cb(void* trigger, void* input)
{
    (void)trigger;
    (void)input;
}

// =============================================================================
// main
// =============================================================================

int main(int argc, char** argv)
{
    std::printf("========================================================\n");
    std::printf("LingoFuse R bridge - C++ layer self-test (v2.0)\n");
    std::printf("========================================================\n");

    // ------------------------------------------------------------------
    // Resolve the runtime directory
    // ------------------------------------------------------------------
    std::string runtime_dir;
    if (argc >= 2) {
        runtime_dir = argv[1];
    } else {
        runtime_dir = lf::find_runtime_dir();
    }
    if (runtime_dir.empty()) {
        std::fprintf(stderr,
            "[FATAL] Runtime directory not provided and could not be "
            "auto-detected.\n"
            "        Usage: %s <runtime_dir>\n"
            "        Or set the LINGOFUSE_RUNTIME environment variable.\n"
            "        Or place the runtime in a Binary/ directory "
            "relative to this executable.\n",
            argv[0]);
        return 1;
    }
    std::printf("Runtime directory: %s\n", runtime_dir.c_str());

    // ==================================================================
    // Group 1 - Build chain probes (no runtime required)
    // ==================================================================
    section("Group 1. Build chain probes (no runtime required)");

    check_str_eq(lf_impl_ping(), "pong", "lf_impl_ping returns 'pong'");
    check_str_eq(lf_impl_version(), "2.0.0",
                 "lf_impl_version reports 2.0.0");
    check(lf_impl_stage() != nullptr && std::strlen(lf_impl_stage()) > 0,
          "lf_impl_stage returns a non-empty string");
    check(lf_impl_compiled() != nullptr && std::strlen(lf_impl_compiled()) > 0,
          "lf_impl_compiled returns a non-empty string");

    check(lf_impl_is_loaded() == 0,
          "lf_impl_is_loaded returns 0 before load");
    check_str_eq(lf_impl_loaded_path(), "",
                 "lf_impl_loaded_path returns empty before load");

    // ==================================================================
    // Group 2 - Runtime load
    // ==================================================================
    section("Group 2. Runtime load");

    int rc = lf_impl_load_library(runtime_dir.c_str());
    check(rc == 1, "lf_impl_load_library returns 1");
    check(lf_impl_is_loaded() == 1,
          "lf_impl_is_loaded returns 1 after load");

    const char* loaded_path = lf_impl_loaded_path();
    check(loaded_path != nullptr && std::strlen(loaded_path) > 0,
          "lf_impl_loaded_path returns a non-empty string");
    if (loaded_path != nullptr) {
        info("loaded from: %s", loaded_path);
    }

    // Idempotence: a second load_library is a no-op that returns 1.
    rc = lf_impl_load_library(runtime_dir.c_str());
    check(rc == 1, "second lf_impl_load_library returns 1 (idempotent)");

    // ==================================================================
    // Group 3 - Runtime options
    // ==================================================================
    section("Group 3. Runtime options");

    // Note on thread-local returns: lf_impl_get_option stores its
    // result in thread-local storage. Capture the value into a
    // std::string immediately, before the next call overwrites it.

    lf_impl_set_option("Quiet", "True");
    {
        const char* v = lf_impl_get_option("Quiet");
        std::string quiet = v ? v : "";
        check(quiet == "True" || quiet == "true",
              "set/get option roundtrip (Quiet=True)");
    }

    lf_impl_set_option("Quiet", "False");
    {
        const char* v = lf_impl_get_option("Quiet");
        std::string quiet = v ? v : "";
        check(quiet == "False" || quiet == "false",
              "set/get option roundtrip (Quiet=False)");
    }

    // The password option must be masked on read.
    lf_impl_set_option("password", "selftest_secret");
    {
        const char* v = lf_impl_get_option("password");
        std::string pw = v ? v : "";
        check(pw == "********",
              "password option is masked on read");
    }

    // An unknown option returns an empty string.
    {
        const char* v = lf_impl_get_option("__no_such_option__");
        check(v == nullptr || std::strlen(v) == 0,
              "unknown option returns an empty string");
    }

    // DataHandle_Idle_Timeout round-trip with a numeric value.
    lf_impl_set_option("DataHandle_Idle_Timeout", "123456");
    {
        const char* v = lf_impl_get_option("DataHandle_Idle_Timeout");
        std::string s = v ? v : "";
        check(s == "123456",
              "set/get numeric option roundtrip (DataHandle_Idle_Timeout)");
    }

    // ==================================================================
    // Group 4 - DataHandle
    // ==================================================================
    section("Group 4. DataHandle");

    void* hnd = lf_impl_data_create("selftest_api");
    check(hnd != nullptr, "lf_impl_data_create returns non-NULL");

    check(lf_impl_data_get_size(hnd) == 0,
          "fresh handle has size 0");
    check(lf_impl_data_get_pos(hnd) == 0,
          "fresh handle has pos 0");

    const std::uint8_t payload[5] = {0x11, 0x22, 0x33, 0x44, 0x55};
    std::int64_t wrote = lf_impl_data_write_buffer(hnd, payload, 5);
    check(wrote == 5, "write_buffer reports 5 bytes written");
    check(lf_impl_data_get_size(hnd) == 5,
          "size is 5 after write");
    check(lf_impl_data_get_pos(hnd) == 5,
          "pos is 5 after write");

    // get_buffer returns a pointer to the internal buffer.
    void* buf = lf_impl_data_get_buffer(hnd);
    check(buf != nullptr, "lf_impl_data_get_buffer returns non-NULL");
    if (buf != nullptr) {
        std::uint8_t local[5] = {0};
        std::memcpy(local, buf, 5);
        check(std::memcmp(local, payload, 5) == 0,
              "get_buffer content matches what was written");
    }

    // Read back through the read_buffer path.
    check(lf_impl_data_set_pos(hnd, 0) == 0, "set_pos(0) succeeds");
    std::uint8_t readback[5] = {0};
    std::int64_t got = lf_impl_data_read_buffer(hnd, readback, 5);
    check(got == 5, "read_buffer reports 5 bytes read");
    check(std::memcmp(readback, payload, 5) == 0,
          "readback content matches");

    // set_size: grow, shrink, and re-read size.
    check(lf_impl_data_set_size(hnd, 8) == 0, "set_size(8) succeeds");
    check(lf_impl_data_get_size(hnd) == 8, "size is 8 after set_size(8)");
    check(lf_impl_data_set_size(hnd, 2) == 0, "set_size(2) succeeds");
    check(lf_impl_data_get_size(hnd) == 2, "size is 2 after set_size(2)");

    // Free and check idempotence.
    lf_impl_data_free(hnd);
    lf_impl_data_free(hnd);   // second call must not crash
    info("lf_impl_data_free is idempotent");

    // A permanent handle
    void* perm = lf_impl_data_create_permanent("perm_api");
    check(perm != nullptr, "lf_impl_data_create_permanent returns non-NULL");
    lf_impl_data_free(perm);

    // ==================================================================
    // Group 5 - AppHandle + generate_app_name
    // ==================================================================
    section("Group 5. AppHandle + generate_app_name");

    // generate_app_name works even before prepare_done, but the
    // resulting string lacks tunnel information. We only verify that
    // it returns non-empty and that two consecutive calls differ.
    {
        const char* n1_c = lf_impl_generate_app_name();
        std::string n1 = n1_c ? n1_c : "";
        const char* n2_c = lf_impl_generate_app_name();
        std::string n2 = n2_c ? n2_c : "";

        check(!n1.empty(), "generate_app_name returns non-empty");
        check(!n2.empty(), "generate_app_name second call non-empty");
        check(n1 != n2, "generate_app_name returns unique values");
        info("first generated name: %s", n1.c_str());
    }

    void* app = lf_impl_app_create("BridgeSelfTest",
                                    "bridge self-test app");
    check(app != nullptr, "lf_impl_app_create returns non-NULL");

    {
        const char* name = lf_impl_app_name(app);
        check_str_eq(name, "BridgeSelfTest",
                     "lf_impl_app_name returns the configured name");
    }

    // Register two APIs (one Call, one Notify). Both must succeed.
    rc = lf_impl_register_call_raw(app, "echo", "echo back", nullptr);
    check(rc == 1, "lf_impl_register_call_raw(echo) succeeds");

    rc = lf_impl_register_notify_raw(app, "log", "log message", nullptr);
    check(rc == 1, "lf_impl_register_notify_raw(log) succeeds");

    // Duplicate registration must be rejected.
    rc = lf_impl_register_call_raw(app, "echo", "duplicate", nullptr);
    check(rc == 0, "duplicate register_call_raw is rejected");

    // Unregister semantics.
    rc = lf_impl_app_unregister(app, "echo");
    check(rc == 1, "app_unregister(echo) returns 1");

    rc = lf_impl_app_unregister(app, "echo");
    check(rc == 0, "second app_unregister(echo) returns 0");

    rc = lf_impl_app_unregister(app, "__no_such_api__");
    check(rc == 0, "app_unregister(unknown) returns 0");

    // Re-register so later groups can still find "echo".
    rc = lf_impl_register_call_raw(app, "echo", "echo back", nullptr);
    check(rc == 1, "re-register echo after unregister succeeds");

    // Note: `app` is kept alive until Group 10 completes.

    // ==================================================================
    // Group 6 - Process-wide P2P registration
    // ==================================================================
    section("Group 6. Process-wide P2P registration");

    // Use a unique name to avoid colliding with any previous run.
    const char* p2p_call_name   = "__bridge_selftest_p2p_call__";
    const char* p2p_notify_name = "__bridge_selftest_p2p_notify__";

    rc = lf_impl_register_p2p_call(p2p_call_name, "self-test call", nullptr);
    check(rc == 1, "register_p2p_call succeeds");

    rc = lf_impl_register_p2p_call(p2p_call_name, "duplicate", nullptr);
    check(rc == 0, "duplicate register_p2p_call is rejected");

    rc = lf_impl_register_p2p_notify(p2p_notify_name, "self-test notify",
                                      nullptr);
    check(rc == 1, "register_p2p_notify succeeds");

    rc = lf_impl_unregister_p2p(p2p_call_name);
    check(rc == 1, "unregister_p2p(call) returns 1");

    rc = lf_impl_unregister_p2p(p2p_call_name);
    check(rc == 0, "second unregister_p2p(call) returns 0");

    rc = lf_impl_unregister_p2p(p2p_notify_name);
    check(rc == 1, "unregister_p2p(notify) returns 1");

    rc = lf_impl_unregister_p2p("__never_registered__");
    check(rc == 0, "unregister_p2p(unknown) returns 0");

    // ==================================================================
    // Group 7 - UID health checks (32-byte by-value ABI)
    // ==================================================================
    // This is the critical ABI test. lf_impl_check_uid takes a
    // pointer to 32 bytes and internally converts it to a by-value
    // struct before calling the runtime. If the conversion were
    // wrong (e.g. off by one byte, or passed by reference when the
    // runtime expects by-value), the runtime would either crash or
    // misbehave. The safest observable check is: a UID that was
    // never registered must return 0.
    section("Group 7. UID health checks (32-byte by-value ABI)");

    {
        std::uint8_t zero_uid[32] = {0};
        int r = lf_impl_check_uid(zero_uid);
        check(r == 0, "check_uid(all-zero) returns 0");
    }

    {
        std::uint8_t nonzero_uid[32];
        for (int i = 0; i < 32; ++i) {
            nonzero_uid[i] = static_cast<std::uint8_t>(i + 1);
        }
        int r = lf_impl_check_uid(nonzero_uid);
        check(r == 0, "check_uid(non-zero unregistered) returns 0");
    }

    {
        std::uint8_t zero_uid[32] = {0};
        int r = lf_impl_check_uid_api(zero_uid, "__no_such_api__");
        check(r == 0, "check_uid_api(zero, unknown) returns 0");
    }

    // ==================================================================
    // Group 8 - Async dispatch failure path
    // ==================================================================
    // The async layer must never leak a slot when dispatch fails.
    // The precise behaviour of LF_Async_Call with an unknown app name
    // is not specified by the C ABI: it may return 0 (rejected) or 1
    // (queued, then wait forever for a response that never comes).
    // Both are acceptable. We test that:
    //   * if dispatch succeeded, releasing the slot works and is
    //     idempotent,
    //   * if dispatch failed, the slot count is unchanged.
    section("Group 8. Async dispatch failure path");

    {
        std::int64_t before = lf_impl_async_slot_count();
        info("async slot count before dispatch: %lld",
             static_cast<long long>(before));

        std::int64_t id = lf_impl_async_call(
            "__no_such_app_for_selftest__",
            "no_op",
            "{}",
            static_cast<std::uint64_t>(500));
        info("async dispatch returned id=%lld",
             static_cast<long long>(id));

        if (id == 0) {
            std::int64_t after = lf_impl_async_slot_count();
            check(after == before,
                  "dispatch failure leaves slot count unchanged");
        } else {
            std::int64_t after = lf_impl_async_slot_count();
            check(after == before + 1,
                  "dispatch success increments slot count");

            lf_impl_async_release(id);
            std::int64_t after_release = lf_impl_async_slot_count();
            check(after_release == before,
                  "async_release decrements slot count");

            // Second release must be a no-op.
            lf_impl_async_release(id);
            std::int64_t after_double = lf_impl_async_slot_count();
            check(after_double == before,
                  "double async_release is a no-op");
        }

        // Release an unknown id: must not crash.
        lf_impl_async_release(999999);
        check(true, "async_release(unknown id) does not crash");
    }

    // ==================================================================
    // Group 9 - Job queries on NULL handles
    // ==================================================================
    // The job-inspection helpers must be defensive against a NULL
    // job pointer. The R side never passes NULL (the finalizer
    // prevents it), but making the C++ layer robust lets us reason
    // about it in isolation.
    section("Group 9. Job queries on NULL handles");

    check(lf_impl_job_kind(nullptr) == -1,
          "job_kind(NULL) returns -1");
    check(lf_impl_job_registry_space(nullptr) == 0,
          "job_registry_space(NULL) returns 0");
    check(lf_impl_job_api_name(nullptr) == nullptr,
          "job_api_name(NULL) returns NULL");
    check(lf_impl_job_is_call(nullptr) == 0,
          "job_is_call(NULL) returns 0");
    check(lf_impl_job_get_input_size(nullptr) == -1,
          "job_get_input_size(NULL) returns -1");
    check(lf_impl_job_sender_uid_valid(nullptr) == 0,
          "job_sender_uid_valid(NULL) returns 0");
    check(lf_impl_job_sender_uid(nullptr, nullptr, 0) == 0,
          "job_sender_uid(NULL) returns 0");
    check(lf_impl_job_callback_id(nullptr) == 0,
          "job_callback_id(NULL) returns 0");
    check(std::strlen(lf_impl_job_result(nullptr)) == 0,
          "job_result(NULL) returns empty string");
    check(std::strlen(lf_impl_job_error(nullptr)) == 0,
          "job_error(NULL) returns empty string");
    check(lf_impl_job_error_kind(nullptr) == 3,
          "job_error_kind(NULL) returns 3");
    check(std::strlen(lf_impl_job_event_kind(nullptr)) == 0,
          "job_event_kind(NULL) returns empty string");
    check(std::strlen(lf_impl_job_event_addr(nullptr)) == 0,
          "job_event_addr(NULL) returns empty string");

    // Empty queue: poll must return NULL immediately.
    check(lf_impl_poll_job(0) == nullptr,
          "poll_job(0) on empty queue returns NULL");
    check(lf_impl_pending_job_count() == 0,
          "pending_job_count is 0 on empty queue");

    // ==================================================================
    // Group 10 - Full prepare cycle + status + shutdown
    // ==================================================================
    section("Group 10. Full prepare cycle");

    lf_impl_reset_prepare();
    check(true, "reset_prepare does not crash");

    rc = lf_impl_prepare_service("ipc:bridge_selftest",
                                  "ipc:bridge_selftest");
    check(rc >= 0, "prepare_service returns a non-negative tag");
    info("prepare_service tag = %d", rc);

    rc = lf_impl_prepare_client_with_app("ipc:bridge_selftest", app);
    check(rc >= 0, "prepare_client_with_app returns a non-negative tag");
    info("prepare_client_with_app tag = %d", rc);

    rc = lf_impl_prepare_done();
    check(rc == 1, "prepare_done returns 1");

    check(lf_impl_check_main_thread() == 1,
          "check_main_thread returns 1 after prepare_done");

    // Give the mesh a moment to broadcast the App registration.
    std::this_thread::sleep_for(std::chrono::milliseconds(800));

    check(lf_impl_check_app("BridgeSelfTest") == 1,
          "check_app(BridgeSelfTest) returns 1");
    check(lf_impl_check_api("BridgeSelfTest", "echo") == 1,
          "check_api(BridgeSelfTest, echo) returns 1");

    // app_bind: every client is already bound to an App, so this
    // must return 0 and log "all clients are already occupied".
    {
        int bound = lf_impl_app_bind(app);
        check(bound == 0,
              "app_bind returns 0 when no free client is available");
    }

    // ------------------------------------------------------------------
    // Status queue
    // ------------------------------------------------------------------
    // Now that the simulated main thread is running, LF_PostStatus
    // and LF_GetStatus behave as documented. We push a unique marker
    // and read the queue back until we find it.
    {
        const char* marker = "__bridge_selftest_status_marker__";
        int before = lf_impl_get_status_count();
        info("status queue count before post: %d", before);

        lf_impl_post_status(marker);

        // Let the main thread process the queue.
        std::this_thread::sleep_for(std::chrono::milliseconds(300));

        int after = lf_impl_get_status_count();
        info("status queue count after post: %d", after);
        check(after > before,
              "post_status increments the queue count");

        bool found = false;
        int guard = 0;
        while (lf_impl_get_status_count() > 0 && guard < 10000) {
            const char* msg = lf_impl_get_status();
            if (msg != nullptr && std::strstr(msg, marker) != nullptr) {
                found = true;
            }
            ++guard;
        }
        check(found,
              "posted status message appears in the get_status stream");
    }

    // generate_app_name now has tunnel information.
    {
        const char* n_c = lf_impl_generate_app_name();
        std::string n = n_c ? n_c : "";
        check(!n.empty(),
              "generate_app_name works after prepare_done");
        info("generated name (with tunnel info): %s", n.c_str());
    }

    // ------------------------------------------------------------------
    // Shutdown sequence
    // ------------------------------------------------------------------
    // Order per LF-CLEAN-001:
    //   1. lf_impl_exit_main_thread
    //   2. lf_impl_app_free
    //   3. lf_impl_shutdown
    //
    // We do NOT call lf_impl_unload_library (the runtime is pinned by
    // the loader and must not be unmapped). We DO call it after the
    // shutdown sequence to clear the function pointer table, matching
    // what the R layer's lf_unload would do.

    lf_impl_exit_main_thread();
    check(true, "exit_main_thread does not crash");

    check(lf_impl_check_main_thread() == 0,
          "check_main_thread returns 0 after exit_main_thread");

    lf_impl_app_free(app);
    check(true, "app_free does not crash");

    lf_impl_shutdown();
    check(true, "shutdown does not crash");

    lf_impl_unload_library();
    check(lf_impl_is_loaded() == 0,
          "is_loaded returns 0 after unload_library");

    // ==================================================================
    // Summary
    // ==================================================================
    std::printf("\n");
    std::printf("========================================================\n");
    std::printf("Self-test summary\n");
    std::printf("========================================================\n");
    std::printf("  Passed : %d\n", g_pass);
    std::printf("  Failed : %d\n", g_fail);
    std::printf("  Total  : %d\n", g_pass + g_fail);
    std::printf("========================================================\n");

    if (g_fail == 0) {
        std::printf("\nBridge C++ layer verified. Ready for R layer.\n");
        return 0;
    }

    std::printf("\nSelf-test FAILED. See above for details.\n");
    return 1;
}