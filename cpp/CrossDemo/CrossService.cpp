// =============================================================================
//  CrossService.cpp
// -----------------------------------------------------------------------------
//  Coordinator process for the IPC endpoint "ipc:cross".
//
//  This program:
//    1. Loads the LingoFuse dynamic library (RAII, reference-counted).
//    2. Creates the IPC service endpoint "ipc:cross".
//    3. Starts the framework (LF_PrepareDone).
//    4. Waits for the user to press Enter.
//    5. Performs a clean shutdown (LF_ExitMainThread -> LF_Shutdown).
//
//  It does NOT register any API and does NOT create a client. Its sole
//  purpose is to act as the discovery/anchor endpoint that worker nodes and
//  callers connect to.
//
//  Cleanup order (matching Pascal LF-CLEAN-001):
//      LF_ExitMainThread  ->  LF_Shutdown
//
//  The required destruction order is enforced by declaration order:
//
//      LibraryLoader   (declared FIRST  -> destroyed LAST)
//      ShutdownGuard   (declared SECOND -> destroyed SECOND)
//
//  C++ destroys automatic objects in reverse order of declaration, so any
//  exit path (normal return, early return, stack unwinding from an
//  exception) runs:
//
//      ~ShutdownGuard()   -> LF_Shutdown
//      ~LibraryLoader()   -> LF_FreeLibrary
//
//  exactly matching the required sequence. This process owns no App and no
//  DataHandle, so no explicit LF_FreeApp / LF_FreeData step is required.
//
//  Build:
//      See the CMakeLists.txt in the parent directory. This file requires
//      lingofuse_c_wrapper (the static wrapper around LingoFuse.c).
// =============================================================================

#include "LingoFuse.hpp"

#include <cstdlib>
#include <exception>
#include <iostream>
#include <string>

namespace {

    /* ------------------------------------------------------------------------
     *  ShutdownGuard - RAII wrapper for lingofuse::shutdown()
     * ------------------------------------------------------------------------
     *  Calls lingofuse::shutdown() when it leaves scope. Declared AFTER the
     *  LibraryLoader, so the destruction order is:
     *
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

    /*
     * Print a banner describing the process.
     */
    void print_banner() {
        std::cout << "=== Cross Service (Coordinator) ===" << std::endl;
    }

    /*
     * Block until the user presses Enter.
     *
     * We deliberately consume an entire line (getline) rather than a single
     * character (cin.get()), because some terminals leave a newline in the
     * buffer after earlier input, which would make cin.get() return
     * immediately.
     */
    void wait_for_enter() {
        std::cout << "IPC service 'ipc:cross' is running. "
            "Press Enter to exit..."
            << std::endl;

        std::string line;
        std::getline(std::cin, line);
    }

} // namespace

int main() {
    print_banner();

    try {
        // 1. Load the dynamic library (reference-counted RAII).
        //    Declared FIRST -> destroyed LAST.
        lingofuse::LibraryLoader loader;

        // 2. RAII guard for LF_Shutdown.
        //    Declared SECOND -> destroyed SECOND, i.e. before the
        //    LibraryLoader destructor runs. Any exit path below
        //    (including early returns and exceptions) triggers
        //    LF_Shutdown followed by LF_FreeLibrary.
        ShutdownGuard shutdown_guard;

        // 3. Reset any preparation state left over from a previous run.
        //    In a fresh process this is a no-op, but it is good hygiene.
        lingofuse::resetPrepare();

        // 4. Prepare the IPC service endpoint.
        //
        //    The two arguments are:
        //      - listening address : where the service actually binds.
        //      - physics address   : the address advertised to clients.
        //
        //    For IPC both are the same. For TCP they can differ (e.g. bind
        //    on 0.0.0.0 but advertise 192.168.1.5:9898).
        //
        //    A return value of -1 indicates a duplicate or invalid address;
        //    any non-negative value is a valid tag ID.
        const int serv_tag =
            lingofuse::prepareService("ipc:cross", "ipc:cross");
        if (serv_tag < 0) {
            std::cerr << "[FATAL] LF_PrepareService failed for ipc:cross "
                "(duplicate or invalid address)."
                << std::endl;
            return EXIT_FAILURE;
        }

        // 5. Start the framework.
        //
        //    LF_PrepareDone blocks until the framework is initialised (or
        //    until the configured timeout expires). It returns 1 only on the
        //    FIRST call per process; a return value other than 1 here means
        //    the framework failed to start.
        //
        //    If LF_PrepareDone returns a value other than 1, the framework
        //    may be partially initialised. Returning here triggers stack
        //    unwinding, which runs:
        //        ~ShutdownGuard()  -> LF_Shutdown
        //        ~LibraryLoader()  -> LF_FreeLibrary
        //    so a plain `return EXIT_FAILURE` leaves the process in a clean
        //    state.
        const int ready = lingofuse::prepareDone();
        if (ready != 1) {
            std::cerr << "[FATAL] LF_PrepareDone returned " << ready
                << " (expected 1). Check the library's console output "
                "for details."
                << std::endl;
            return EXIT_FAILURE;
        }

        // 6. Idle until the user presses Enter.
        wait_for_enter();

        // 7. Stop the network loop. LF_Shutdown will run automatically when
        //    the automatic objects leave their scope.
        std::cout << "Shutting down..." << std::endl;
        lingofuse::exitMainThread();

    } // <- ~ShutdownGuard(): LF_Shutdown
      // <- ~LibraryLoader(): LF_FreeLibrary

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

    std::cout << "Bye." << std::endl;
    return EXIT_SUCCESS;
}