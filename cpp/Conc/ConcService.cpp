// =============================================================================
//  ConcService.cpp
// -----------------------------------------------------------------------------
//  Service side of the concurrent-notify demo.
//
//  Registered APIs:
//
//      tick          (Notify)  -> void
//          Atomically increments a global counter. Runs on the HPC background
//          worker pool. Must be as cheap as possible.
//
//      wait_complete (Call)    -> (uint64 count, int32 complete, uint64 wait_ms)
//          Blocks until the counter reaches the requested target, or until
//          the internal wait budget expires. Runs on the simulated main
//          thread; blocking here does not stall the HPC notify drain.
//
//  Command line:
//      ConcService [--ci] [--shutdown-after N] [--wait-timeout N]
//
//  In --ci mode:
//      - the periodic reporter is suppressed
//      - the wait_complete callback emits one JSON line per invocation
//      - a service_ready event is emitted once the framework is up
//
//  Exit code is always 0 unless a startup error occurs.
// =============================================================================

#if defined(_WIN32) && !defined(_CRT_SECURE_NO_WARNINGS)
#  define _CRT_SECURE_NO_WARNINGS
#endif

#include "LingoFuse.hpp"
#include "ConcCommon.hpp"

#include <atomic>
#include <chrono>
#include <cstdint>
#include <cstdlib>
#include <iostream>
#include <mutex>
#include <sstream>
#include <string>
#include <thread>
#include <utility>

#if defined(_WIN32)
#  define WIN32_LEAN_AND_MEAN
#  include <windows.h>
#else
#  include <csignal>
#endif

namespace {

    // ---------------------------------------------------------------------
    //  Configuration (set once in main, read-only thereafter)
    // ---------------------------------------------------------------------
    bool g_ci_mode = false;
    int  g_wait_timeout_ms = conc::kDefaultWaitTimeoutMs;

    // ---------------------------------------------------------------------
    //  Shared state
    // ---------------------------------------------------------------------
    std::atomic<std::uint64_t> g_received_ticks{ 0 };
    std::atomic<std::uint64_t> g_wait_calls{ 0 };
    std::atomic<bool>          g_stop_flag{ false };

    // ---------------------------------------------------------------------
    //  Thread-safe line output
    // ---------------------------------------------------------------------
    std::mutex& log_mutex() {
        static std::mutex m;
        return m;
    }

    template <typename... Args>
    void log_line(Args&&... args) {
        std::ostringstream oss;
        (void)((oss << std::forward<Args>(args)), ...);
        std::lock_guard<std::mutex> lock(log_mutex());
        std::cout << oss.str() << '\n';
        std::cout.flush();
    }

    // ---------------------------------------------------------------------
    //  Signal handling
    // ---------------------------------------------------------------------
#if defined(_WIN32)
    BOOL WINAPI console_ctrl_handler(DWORD type) {
        switch (type) {
        case CTRL_C_EVENT:
        case CTRL_BREAK_EVENT:
        case CTRL_CLOSE_EVENT:
        case CTRL_LOGOFF_EVENT:
        case CTRL_SHUTDOWN_EVENT:
            g_stop_flag.store(true);
            return TRUE;
        default:
            return FALSE;
        }
    }
#else
    extern "C" void posix_signal_handler(int) {
        g_stop_flag.store(true);
    }
#endif

    // =====================================================================
    //  Notify handler  --  tick
    // =====================================================================
    void LF_CDECL api_tick(void* /*trigger*/, void* /*input*/) {
        g_received_ticks.fetch_add(1, std::memory_order_relaxed);
    }

    // =====================================================================
    //  Call handler  --  wait_complete
    // =====================================================================
    void LF_CDECL api_wait_complete(void* /*trigger*/, void* input, void* output) {
        lingofuse::DataHandle in_h(static_cast<TDataHnd>(input), false);
        lingofuse::DataHandle out_h(static_cast<TDataHnd>(output), false);

        std::uint64_t expected = 0;
        if (!in_h.read(expected)) {
            out_h.write(std::uint64_t{ 0 });
            out_h.write(std::int32_t{ 0 });
            out_h.write(std::uint64_t{ 0 });
            return;
        }

        const auto start = std::chrono::steady_clock::now();
        const auto timeout = std::chrono::milliseconds(g_wait_timeout_ms);

        std::uint64_t current = 0;
        std::uint64_t polls = 0;

        for (;;) {
            current = g_received_ticks.load(std::memory_order_relaxed);
            if (current >= expected) break;
            if (std::chrono::steady_clock::now() - start >= timeout) break;
            std::this_thread::sleep_for(std::chrono::milliseconds(1));
            ++polls;
        }

        const auto wait_ms = std::chrono::duration_cast<std::chrono::milliseconds>(
            std::chrono::steady_clock::now() - start).count();

        const std::int32_t complete = (current >= expected) ? 1 : 0;

        out_h.write(current);
        out_h.write(complete);
        out_h.write(static_cast<std::uint64_t>(wait_ms));

        g_wait_calls.fetch_add(1, std::memory_order_relaxed);

        if (g_ci_mode) {
            std::ostringstream oss;
            oss << "{\"event\":\"wait_complete\""
                << ",\"expected\":" << expected
                << ",\"current\":" << current
                << ",\"complete\":" << (complete ? "true" : "false")
                << ",\"wait_ms\":" << wait_ms
                << ",\"polls\":" << polls
                << "}";
            log_line(oss.str());
        }
        else {
            log_line("[Service] wait_complete  expected=", expected,
                "  current=", current,
                "  complete=", (complete ? "YES" : "NO"),
                "  wait_ms=", wait_ms,
                "  polls=", polls);
        }
    }

    // =====================================================================
    //  Periodic reporter (interactive mode only)
    // =====================================================================
    void reporter() {
        std::uint64_t last_ticks = 0;
        auto last_time = std::chrono::steady_clock::now();

        while (!g_stop_flag.load(std::memory_order_relaxed)) {
            std::this_thread::sleep_for(std::chrono::seconds(1));
            if (g_stop_flag.load(std::memory_order_relaxed)) break;

            const auto now = std::chrono::steady_clock::now();
            const double dt =
                std::chrono::duration<double>(now - last_time).count();
            last_time = now;

            const std::uint64_t ticks =
                g_received_ticks.load(std::memory_order_relaxed);
            const std::uint64_t delta = ticks - last_ticks;
            last_ticks = ticks;

            const std::uint64_t rate =
                (dt > 0.0)
                ? static_cast<std::uint64_t>(
                    static_cast<double>(delta) / dt)
                : 0;

            log_line("[Service] ticks=", ticks,
                "  rate=", rate, " ticks/s",
                "  wait_calls=", g_wait_calls.load(
                    std::memory_order_relaxed));
        }
    }

    // ---------------------------------------------------------------------
    //  ShutdownGuard
    // ---------------------------------------------------------------------
    struct ShutdownGuard {
        ~ShutdownGuard() {
            try { lingofuse::shutdown(); }
            catch (...) {}
        }
    };

} // namespace

/* ============================================================================
 *  main
 * ============================================================================ */

int main(int argc, char* argv[]) {
    const conc::CliOptions opt = conc::CliOptions::parse(argc, argv);
    g_ci_mode = opt.ci_mode;
    g_wait_timeout_ms = opt.wait_timeout_ms;

    if (!g_ci_mode) {
        std::cout << "=== Concurrent Notify Service ===" << std::endl;
    }

    const auto start_steady = std::chrono::steady_clock::now();

    try {
#if defined(_WIN32)
        SetConsoleCtrlHandler(console_ctrl_handler, TRUE);
#else
        std::signal(SIGINT, posix_signal_handler);
        std::signal(SIGTERM, posix_signal_handler);
#endif

        lingofuse::LibraryLoader loader;
        ShutdownGuard shutdown_guard;

        {
            lingofuse::App app(conc::kServiceApp,
                "Concurrent-notify demo service");

            if (!app.registerNotify(conc::kTickApi,
                "increment tick counter",
                nullptr,
                api_tick)) {
                std::cerr << "[FATAL] Failed to register notify API '"
                    << conc::kTickApi << "'." << std::endl;
                return EXIT_FAILURE;
            }

            if (!app.registerCall(conc::kWaitApi,
                "wait until target tick count is reached",
                nullptr,
                api_wait_complete)) {
                std::cerr << "[FATAL] Failed to register call API '"
                    << conc::kWaitApi << "'." << std::endl;
                return EXIT_FAILURE;
            }

            lingofuse::setOption("Wait_Ready", "False");
            if (g_ci_mode) {
                lingofuse::setOption("Quiet", "True");
            }

            lingofuse::resetPrepare();

            const int serv_tag =
                lingofuse::prepareService(conc::kEndpoint, conc::kEndpoint);
            if (serv_tag < 0) {
                std::cerr << "[FATAL] LF_PrepareService failed for "
                    << conc::kEndpoint << "." << std::endl;
                return EXIT_FAILURE;
            }

            const int cli_tag =
                lingofuse::prepareClient(conc::kEndpoint, app.get());
            if (cli_tag < 0) {
                std::cerr << "[FATAL] LF_PrepareClient failed for "
                    << conc::kEndpoint << "." << std::endl;
                return EXIT_FAILURE;
            }

            if (lingofuse::prepareDone() != 1) {
                std::cerr << "[FATAL] LF_PrepareDone failed." << std::endl;
                return EXIT_FAILURE;
            }

            if (g_ci_mode) {
                std::ostringstream oss;
                oss << "{\"event\":\"service_ready\""
                    << ",\"endpoint\":\"" << conc::kEndpoint << "\""
                    << ",\"app\":\"" << conc::kServiceApp << "\""
                    << ",\"wait_timeout_ms\":" << g_wait_timeout_ms
                    << "}";
                log_line(oss.str());
            }
            else {
                log_line("[Service] Online on ", conc::kEndpoint);
                log_line("[Service] App='", conc::kServiceApp,
                    "'  notify='", conc::kTickApi,
                    "'  call='", conc::kWaitApi, "'");
                log_line("[Service] Press Ctrl+C or Enter to stop.");
            }

            // ---- Auto-shutdown timer (CI mode) --------------------------
            //  When --shutdown-after is set, a detached thread flips the
            //  stop flag after the requested delay. This lets the CI
            //  script start the service with a generous lifetime, then
            //  forget about it.
            if (opt.shutdown_after_sec > 0) {
                const int seconds = opt.shutdown_after_sec;
                std::thread([seconds]() {
                    std::this_thread::sleep_for(
                        std::chrono::seconds(seconds));
                    g_stop_flag.store(true);
                    }).detach();
            }

            // ---- Interactive stop hook (Enter) --------------------------
            //  Only in interactive mode: pressing Enter ends the service.
            if (!g_ci_mode) {
                std::thread([]() {
                    std::string line;
                    if (std::getline(std::cin, line)) {
                        g_stop_flag.store(true);
                    }
                    }).detach();
            }

            // ---- Reporter thread (interactive mode only) ----------------
            std::thread reporter_thread;
            if (!g_ci_mode) {
                reporter_thread = std::thread(reporter);
            }

            while (!g_stop_flag.load(std::memory_order_relaxed)) {
                std::this_thread::sleep_for(std::chrono::milliseconds(100));
            }

            if (reporter_thread.joinable()) reporter_thread.join();

            // ---- Final summary ------------------------------------------
            const auto now_steady = std::chrono::steady_clock::now();
            const double uptime_sec =
                std::chrono::duration<double>(now_steady - start_steady).count();

            const std::uint64_t final_ticks =
                g_received_ticks.load(std::memory_order_relaxed);
            const std::uint64_t final_waits =
                g_wait_calls.load(std::memory_order_relaxed);

            if (g_ci_mode) {
                std::ostringstream oss;
                oss << "{\"event\":\"service_summary\""
                    << ",\"uptime_sec\":" << static_cast<int>(uptime_sec)
                    << ",\"ticks\":" << final_ticks
                    << ",\"wait_calls\":" << final_waits
                    << "}";
                log_line(oss.str());
            }
            else {
                log_line("[Service] Final: ticks=", final_ticks,
                    "  wait_calls=", final_waits,
                    "  uptime=", uptime_sec, "s");
            }

            lingofuse::exitMainThread();
        }
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

    if (!g_ci_mode) {
        std::cout << "[Service] Bye." << std::endl;
    }
    return EXIT_SUCCESS;
}