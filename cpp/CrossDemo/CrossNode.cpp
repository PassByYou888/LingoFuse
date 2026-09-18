// =============================================================================
//  CrossNode.cpp
// -----------------------------------------------------------------------------
//  Worker node that registers the "add" and "inv_seri" Call APIs.
//
//  It connects to the IPC endpoint "ipc:cross" as a client and exposes the
//  application "demo" to the C4 service mesh. Multiple instances may be
//  launched; the mesh automatically load-balances incoming calls across all
//  live workers.
//
//  Registered APIs:
//
//    add      (int32 a, int32 b)                    -> int32
//        Reads two 32-bit signed integers, returns their sum.
//
//    inv_seri (uint8, uint16, uint32, uint64,
//              string, float)                        -> same types reversed
//        Reads a fixed sequence of typed values and echoes them back in the
//        reverse order. Used to exercise the binary wire format.
//
//  Output interleaving:
//      Callbacks are invoked on the library's background worker threads.
//      When multiple clients call concurrently, several worker threads may
//      be running the callbacks at the same time. All callback output goes
//      through the helper `log_line()`, which formats the whole line in
//      memory and emits it under a process-wide mutex. This keeps each line
//      intact; the order between lines is, by nature of concurrency, still
//      arbitrary.
//
//      Startup and shutdown messages in main() are single-threaded and are
//      emitted directly via std::cout / std::cerr without locking.
//
//  Cleanup order (matching Pascal LF-CLEAN-001):
//      LF_ExitMainThread  ->  LF_FreeApp  ->  LF_Shutdown
//
//  The required destruction order is enforced by declaration order:
//
//      LibraryLoader   (declared FIRST  -> destroyed LAST)
//      ShutdownGuard   (declared SECOND -> destroyed SECOND)
//      App             (declared LAST   -> destroyed FIRST)
//
//  C++ destroys automatic objects in reverse order of declaration, so:
//
//      App destructor          -> LF_FreeApp
//      ShutdownGuard destructor -> LF_Shutdown
//      LibraryLoader destructor -> LF_FreeLibrary
//
//  exactly matching the required sequence. This same mechanism makes every
//  early-return and exception path safe: any exit from the try-block runs
//  the same destructors in the same order.
// =============================================================================

#include "LingoFuse.hpp"

#include <cstdint>
#include <cstdlib>
#include <exception>
#include <iostream>
#include <mutex>
#include <ostream>
#include <sstream>
#include <string>
#include <utility>

/* ============================================================================
 *  Thread-safe line output
 * ----------------------------------------------------------------------------
 *  Builds the whole line in an ostringstream (no lock held), then emits it
 *  in one write under a process-wide mutex. The lock is held for the
 *  shortest possible time and no formatting happens inside it.
 *
 *  The first parameter selects the target stream (std::cout or std::cerr).
 * ============================================================================ */

namespace {

    std::mutex& log_mutex() {
        static std::mutex m;
        return m;
    }

    template <typename... Args>
    void log_line(std::ostream& os, Args&&... args) {
        std::ostringstream oss;
        // C++17 fold expression: expands to (oss << arg0), (oss << arg1), ...
        (void)((oss << std::forward<Args>(args)), ...);

        std::lock_guard<std::mutex> lock(log_mutex());
        os << oss.str() << '\n';
    }

    /* ------------------------------------------------------------------------
     *  ShutdownGuard - RAII wrapper for lingofuse::shutdown()
     * ------------------------------------------------------------------------
     *  Calls lingofuse::shutdown() when it leaves scope. Declared AFTER the
     *  LibraryLoader and BEFORE any App object, so that the destruction
     *  order is:
     *
     *      App destructor           -> LF_FreeApp
     *      ShutdownGuard destructor -> LF_Shutdown
     *      LibraryLoader destructor -> LF_FreeLibrary
     *
     *  This guarantees the required cleanup sequence (Pascal LF-CLEAN-001)
     *  on every exit path, including early returns and stack unwinding
     *  triggered by exceptions.
     *
     *  lingofuse::shutdown() is idempotent and safe to call even when the
     *  framework was never fully started (e.g., before LF_PrepareDone).
     * ---------------------------------------------------------------------- */
    struct ShutdownGuard {
        ~ShutdownGuard() {
            try {
                lingofuse::shutdown();
            }
            catch (...) {
                // Destructors must never throw. LF_Shutdown is documented
                // as safe to call multiple times, but we still swallow any
                // unexpected C++ exception from the wrapper.
            }
        }
    };

} // namespace

/* ============================================================================
 *  API callbacks
 * ----------------------------------------------------------------------------
 *  Callbacks execute on background worker threads. Inside them:
 *    - DO NOT block.
 *    - DO NOT call LF_Call / LF_Notify / LF_LocalCall (deadlock risk).
 * ============================================================================ */

 // -----------------------------------------------------------------------------
 //  add(int32, int32) -> int32
 // -----------------------------------------------------------------------------
static void LF_CDECL add_callback(void* /*trigger*/,
    void* input,
    void* output) {
    // Borrow handles; the framework owns them for the duration of this call.
    lingofuse::DataHandle in(static_cast<TDataHnd>(input), false);
    lingofuse::DataHandle out(static_cast<TDataHnd>(output), false);

    std::int32_t a = 0;
    std::int32_t b = 0;
    if (!in.read(a) || !in.read(b)) {
        log_line(std::cerr, "[Node] add: failed to read parameters.");
        return;
    }

    const std::int32_t c = a + b;

    log_line(std::cout, "[Node] add(", a, ", ", b, ") = ", c);

    out.write(c);
}

// -----------------------------------------------------------------------------
//  inv_seri() -> reversed typed sequence
// -----------------------------------------------------------------------------
static void LF_CDECL inv_seri_callback(void* /*trigger*/,
    void* input,
    void* output) {
    lingofuse::DataHandle in(static_cast<TDataHnd>(input), false);
    lingofuse::DataHandle out(static_cast<TDataHnd>(output), false);

    std::uint8_t  b = 0;
    std::uint16_t w = 0;
    std::uint32_t c = 0;
    std::uint64_t u64 = 0;
    std::string   s;
    float         f = 0.0f;

    if (!in.read(b) ||
        !in.read(w) ||
        !in.read(c) ||
        !in.read(u64) ||
        !in.read(s) ||
        !in.read(f)) {
        log_line(std::cerr, "[Node] inv_seri: failed to read data.");
        return;
    }

    log_line(std::cout,
        "[Node] inv_seri received: [",
        static_cast<int>(b), ", ", w, ", ", c, ", ",
        u64, ", \"", s, "\", ", f, "]");

    // Reply in reverse order.
    out.write(f);
    out.write(s);
    out.write(u64);
    out.write(c);
    out.write(w);
    out.write(b);

    log_line(std::cout,
        "[Node] inv_seri replied: [",
        f, ", \"", s, "\", ", u64, ", ", c, ", ",
        w, ", ", static_cast<int>(b), "]");
}

/* ============================================================================
 *  main
 * ============================================================================ */

int main() {
    std::cout << "=== Cross Node (Worker) ===" << std::endl;

    try {
        // Load the LingoFuse dynamic library (reference-counted RAII).
        // Declared FIRST -> destroyed LAST.
        lingofuse::LibraryLoader loader;

        // RAII guard for LF_Shutdown.
        // Declared SECOND -> destroyed SECOND, i.e., after any App object
        // declared below and before the LibraryLoader destructor runs.
        ShutdownGuard shutdown_guard;

        // Application scope. Declared LAST -> destroyed FIRST.
        //
        // Because C++ destroys automatic objects in reverse order of
        // declaration, the App destructor (LF_FreeApp) runs BEFORE the
        // ShutdownGuard destructor (LF_Shutdown). This preserves the
        // required cleanup sequence LF-CLEAN-001.
        {
            lingofuse::App app("demo", "C++ worker node");

            // Register the two Call APIs. The framework copies the API name
            // internally, so the std::string literals below are safe.
            if (!app.registerCall("add",
                "add(int a, int b) -> int",
                nullptr,
                add_callback)) {
                std::cerr << "[FATAL] Failed to register API 'add'."
                    << std::endl;
                return EXIT_FAILURE;
            }
            if (!app.registerCall("inv_seri",
                "inv_seri() -> reversed typed sequence",
                nullptr,
                inv_seri_callback)) {
                std::cerr << "[FATAL] Failed to register API 'inv_seri'."
                    << std::endl;
                return EXIT_FAILURE;
            }

            std::cout << "[Node] Registered APIs 'add' and 'inv_seri' "
                "under application 'demo'."
                << std::endl;

            // Deployment mode: do not block LF_PrepareDone waiting for the
            // service endpoint. This allows the node to start before the
            // coordinator; it will connect automatically once the endpoint
            // becomes reachable.
            lingofuse::setOption("Wait_Ready", "False");

            // Reset any previous preparation state, then connect as a
            // client and attach our application.
            //
            // LF_PrepareClient returns -1 for a duplicate/invalid address;
            // any non-negative value is a valid tag ID.
            lingofuse::resetPrepare();

            const int client_tag =
                lingofuse::prepareClient("ipc:cross", app.get());
            if (client_tag < 0) {
                std::cerr << "[FATAL] LF_PrepareClient failed for "
                    "ipc:cross (duplicate or invalid address)."
                    << std::endl;
                return EXIT_FAILURE;
            }

            // Start the framework.
            //
            // If LF_PrepareDone returns a value other than 1, the framework
            // may be partially initialised. Returning here triggers stack
            // unwinding, which runs:
            //     ~App()             -> LF_FreeApp
            //     ~ShutdownGuard()   -> LF_Shutdown
            //     ~LibraryLoader()   -> LF_FreeLibrary
            // so a plain `return EXIT_FAILURE` leaves the process in a
            // clean state.
            const int ready = lingofuse::prepareDone();
            if (ready != 1) {
                std::cerr << "[FATAL] LF_PrepareDone returned " << ready
                    << " (expected 1). Check the library's console "
                    "output for details."
                    << std::endl;
                return EXIT_FAILURE;
            }

            std::cout << "[Node] Online. Press Enter to exit..." << std::endl;

            // Idle until the user presses Enter.
            std::string line;
            std::getline(std::cin, line);

            // Stop the network loop. LF_FreeApp and LF_Shutdown will run
            // automatically when the automatic objects leave their scope.
            std::cout << "[Node] Shutting down..." << std::endl;
            lingofuse::exitMainThread();

        } // <- ~App():           LF_FreeApp(app_handle)
          // <- ~ShutdownGuard(): LF_Shutdown()

    }
    catch (const lingofuse::Error& e) {
        std::cerr << "[FATAL] lingofuse::Error (code="
            << static_cast<int>(e.code()) << "): "
            << e.what() << std::endl;
        return EXIT_FAILURE;
    }
    catch (const std::exception& e) {
        std::cerr << "[FATAL] std::exception: " << e.what() << std::endl;
        return EXIT_FAILURE;
    }
    catch (...) {
        std::cerr << "[FATAL] Unknown exception." << std::endl;
        return EXIT_FAILURE;
    }

    std::cout << "[Node] Bye." << std::endl;
    return EXIT_SUCCESS;
}