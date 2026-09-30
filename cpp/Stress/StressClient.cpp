// =============================================================================
//  StressClient.cpp
// -----------------------------------------------------------------------------
//  Multi-threaded caller for the LingoFuse stress and stability test.
//
//  Behaviour:
//      - Connects to "ipc:stress" as a pure consumer.
//      - Spawns N worker threads that loop forever, calling a randomly
//        chosen API on "StressSvc".
//      - A reporter thread sends a status record to "StressMon" once per
//        second via LF_Notify.
//
//  =============================================================================
//  HANDLE USAGE RULES (applied throughout this file)
//  =============================================================================
//
//    R1. A handle may be used ONLY BEFORE and DURING the call.
//        (Write payload / read position / pass to LF_Call / etc.)
//
//    R2. After the call returns, the handle MUST be destroyed.
//        In this file that is done either by ~DataHandle RAII (normal
//        path) or by an explicit in.reset() (defensive form).
//
//    R3. If the handle is NOT destroyed (deliberate leak), it MUST NOT
//        be used again in any way. "Used" means any accessor:
//        LF_GetSize / LF_GetPos / LF_GetBuffer / LF_WriteBuffer /
//        LF_ReadBuffer / LF_SetPos / LF_SetSize / LF_FreeData / ...
//
//  The purpose of these rules is to keep every handle's state
//  unambiguous: either it is owned and alive (before / during the
//  call), or it is gone (after the call). No in-between.
//
//  =============================================================================
//  HANDLE LIFECYCLE (v3)
//  -----------------------------------------------------------------------------
//  This client deliberately does NOT reuse DataHandle instances across
//  iterations.
//
//    * Normal path:
//        - the input handle is created inside its own scope;
//        - LF_Call / tryCall is invoked;
//        - the scope closes -> ~DataHandle -> LF_FreeData, immediately.
//        - the result handle is used, then destroyed by RAII.
//
//    * Leak path (every kLeakEveryN-th iteration):
//        - the input handle is detached via DataHandle::release() and
//          is then NEVER touched again;
//        - the result handle from LF_Call is NOT wrapped and NEVER
//          touched after the single size-check;
//        - the whole purpose is to let the library's idle reclaimer
//          (TLF_DataPool.Progress) pick them up after the timeout.
//
//  The number of leaked calls and leaked handles is included in every
//  report sent to the monitor, so the operator can watch the pool grow
//  and then shrink back as the reclaimer catches up.
//
//  Usage:
//      StressClient [threads] [pause_ms]
//      Defaults: threads = 100, pause_ms = 0
// =============================================================================

#include "LingoFuse.hpp"
#include "StressCommon.hpp"

#include <atomic>
#include <chrono>
#include <csignal>
#include <cstdint>
#include <cstdlib>
#include <exception>
#include <iostream>
#include <mutex>
#include <optional>
#include <random>
#include <sstream>
#include <string>
#include <thread>
#include <vector>

#if defined(_WIN32)
#  define WIN32_LEAN_AND_MEAN
#  include <windows.h>
#endif

namespace {

    constexpr int  kDefaultThreads = 100;
    constexpr int  kDefaultPauseMs = 0;
    constexpr int  kCallTimeoutMs = 60000;
    constexpr int  kStatusIntervalMs = 1000;

    // Every N-th worker iteration deliberately leaks its handles.
    constexpr std::uint64_t kLeakEveryN = 100;

    std::atomic<int>  g_pause_ms{ kDefaultPauseMs };
    std::atomic<bool> g_stop_flag{ false };

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
    }

    struct Stats {
        std::atomic<std::uint64_t> total{ 0 };
        std::atomic<std::uint64_t> success{ 0 };
        std::atomic<std::uint64_t> failure{ 0 };
        std::atomic<std::uint64_t> echo_calls{ 0 };
        std::atomic<std::uint64_t> add_calls{ 0 };
        std::atomic<std::uint64_t> hash_calls{ 0 };
        std::atomic<std::uint64_t> leaked_calls{ 0 };
        std::atomic<std::uint64_t> leaked_handles{ 0 };

        Stats() = default;
        Stats(const Stats&) = delete;
        Stats& operator=(const Stats&) = delete;
    };

    // -------------------------------------------------------------------------
    //  Worker thread body
    //
    //  Each iteration allocates fresh DataHandle instances.
    //
    //  Normal path:
    //     { DataHandle in(...); ...; resp = tryCall(..., in, ...); }
    //     ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
    //     The inner scope closes immediately after tryCall returns, so
    //     `in` is destroyed at exactly the moment the call completes.
    //
    //  Leak path:
    //     The handle is used strictly before the call. After the call
    //     returns, `in.release()` detaches it from RAII and it is
    //     NEVER touched again. `raw_result` is size-checked once and
    //     then also never touched.
    // -------------------------------------------------------------------------
    void worker(int index, Stats& stats) {
        std::mt19937 rng(
            static_cast<std::uint32_t>(index) ^
            static_cast<std::uint32_t>(stress::now_ms()));

        std::uniform_int_distribution<int> which(0, 2);
        std::uniform_int_distribution<int> num(1, 10000);

        std::uint64_t iter = 0;

        while (!g_stop_flag.load(std::memory_order_relaxed)) {
            ++iter;

            // Every kLeakEveryN-th iteration deliberately leaks.
            const bool leak_this_call = (iter % kLeakEveryN == 0);

            const int choice = which(rng);
            bool ok = false;

            if (leak_this_call) {
                // ============================================================
                //  DELIBERATE LEAK PATH
                //
                //  Rule R1: `in` is used ONLY before and during the call.
                //  Rule R2: we choose NOT to destroy it (deliberate leak).
                //  Rule R3: after the call, `in` and `raw_result` are
                //           NEVER touched again.
                // ============================================================
                try {
                    const char* api_name = (choice == 0) ? "echo"
                        : (choice == 1) ? "add"
                        : "hash";

                    // --- Phase A: create and fill the input handle ---
                    //     (allowed: before the call)
                    lingofuse::DataHandle in(api_name);

                    switch (choice) {
                    case 0: {
                        const std::string payload =
                            "leak_echo_" + std::to_string(num(rng));
                        in.write(payload);
                        break;
                    }
                    case 1: {
                        const std::int32_t a =
                            static_cast<std::int32_t>(num(rng));
                        const std::int32_t b =
                            static_cast<std::int32_t>(num(rng));
                        in.write(a);
                        in.write(b);
                        break;
                    }
                    case 2: {
                        const std::string payload =
                            "leak_hash_" + std::to_string(num(rng));
                        in.write(payload);
                        break;
                    }
                    default:
                        break;
                    }

                    // --- Phase B: the call ---
                    //     (allowed: during the call)
                    //
                    //     `in.get()` hands the raw handle to LF_Call.
                    //     From the moment LF_Call returns, `in` must not
                    //     be used again (see Phase C below).
                    TDataHnd raw_result =
                        LF_Call(stress::kServiceApp, in.get(), kCallTimeoutMs);

                    // --- Phase C: post-call handling ---
                    //
                    //  Rule R3: after the call, `in` is treated as dead.
                    //  Detach it from RAII so ~DataHandle will NOT call
                    //  LF_FreeData. This is the deliberate leak.
                    //
                    //  IMPORTANT: after this line, `in` MUST NOT appear
                    //  in any expression, even inside a debug log.
                    (void)in.release();

                    //  `raw_result` is a *fresh* handle returned by
                    //  LF_Call. We may inspect it ONCE (a size check)
                    //  and then it too is left to the reclaimer.
                    //
                    //  After the following `if`, `raw_result` MUST NOT
                    //  appear in any expression.
                    if (raw_result != nullptr && LF_GetSize(raw_result) > 0) {
                        ok = true;
                    }

                    // --- Phase D: bookkeeping only, no handle touches ---
                    stats.leaked_calls.fetch_add(
                        1, std::memory_order_relaxed);
                    stats.leaked_handles.fetch_add(
                        (raw_result != nullptr) ? 2 : 1,
                        std::memory_order_relaxed);

                }
                catch (const std::exception& e) {
                    log_line("[Worker ", index,
                        "] LEAK-PATH EXCEPTION: ", e.what());
                    ok = false;
                }
                catch (...) {
                    log_line("[Worker ", index,
                        "] LEAK-PATH EXCEPTION: unknown");
                    ok = false;
                }

            }
            else {
                // ============================================================
                //  NORMAL PATH
                //
                //  Rule R2: after the call returns, the input handle is
                //           destroyed *immediately* by closing its scope.
                // ============================================================
                try {
                    switch (choice) {
                    case 0: {
                        const std::string payload =
                            "stress_echo_" + std::to_string(num(rng));

                        std::optional<lingofuse::DataHandle> resp;

                        // Input handle lives in its own scope: it is
                        // destroyed the instant we leave this block,
                        // which is right after the call returns.
                        {
                            lingofuse::DataHandle in("echo");
                            in.write(payload);
                            resp = lingofuse::tryCall(
                                stress::kServiceApp, in, kCallTimeoutMs);
                        }
                        // ¡û R2 satisfied: `in` destroyed here.

                        // `resp` is a *new* handle from LF_Call; it is
                        // independent of `in`. Safe to use now.
                        if (resp) {
                            std::string echoed;
                            ok = resp->read(echoed) && (echoed == payload);
                        }
                        // `resp` destroyed by RAII at end of the case.
                        break;
                    }
                    case 1: {
                        const std::int32_t a =
                            static_cast<std::int32_t>(num(rng));
                        const std::int32_t b =
                            static_cast<std::int32_t>(num(rng));

                        std::optional<lingofuse::DataHandle> resp;
                        {
                            lingofuse::DataHandle in("add");
                            in.write(a);
                            in.write(b);
                            resp = lingofuse::tryCall(
                                stress::kServiceApp, in, kCallTimeoutMs);
                        }
                        // ¡û R2 satisfied: `in` destroyed here.

                        if (resp) {
                            std::int32_t sum = 0;
                            ok = resp->read(sum) && (sum == a + b);
                        }
                        break;
                    }
                    case 2: {
                        const std::string payload =
                            "stress_hash_" + std::to_string(num(rng));

                        std::optional<lingofuse::DataHandle> resp;
                        {
                            lingofuse::DataHandle in("hash");
                            in.write(payload);
                            resp = lingofuse::tryCall(
                                stress::kServiceApp, in, kCallTimeoutMs);
                        }
                        // ¡û R2 satisfied: `in` destroyed here.

                        if (resp) {
                            std::uint64_t h = 0;
                            ok = resp->read(h);
                        }
                        break;
                    }
                    default:
                        break;
                    }
                }
                catch (const std::exception& e) {
                    log_line("[Worker ", index, "] EXCEPTION: ", e.what());
                    ok = false;
                }
                catch (...) {
                    log_line("[Worker ", index, "] EXCEPTION: unknown");
                    ok = false;
                }
            }

            // Per-API counters (both paths).
            switch (choice) {
            case 0: stats.echo_calls.fetch_add(
                1, std::memory_order_relaxed); break;
            case 1: stats.add_calls.fetch_add(
                1, std::memory_order_relaxed); break;
            case 2: stats.hash_calls.fetch_add(
                1, std::memory_order_relaxed); break;
            default: break;
            }

            stats.total.fetch_add(1, std::memory_order_relaxed);
            if (ok) {
                stats.success.fetch_add(1, std::memory_order_relaxed);
            }
            else {
                stats.failure.fetch_add(1, std::memory_order_relaxed);
            }

            const int pause = g_pause_ms.load(std::memory_order_relaxed);
            if (pause > 0) {
                std::this_thread::sleep_for(
                    std::chrono::milliseconds(pause));
            }
        }
    }

    // -------------------------------------------------------------------------
    //  Reporter thread
    // -------------------------------------------------------------------------
    void reporter(const Stats& stats, const std::atomic<bool>& stop_flag) {
        const std::uint32_t my_pid = stress::get_current_pid();

        auto last_report = std::chrono::steady_clock::now();
        std::uint64_t last_total = 0;

        auto publish = [&](int running) {
            stress::ClientReport r;
            r.pid = my_pid;
            r.timestamp_ms = stress::now_ms();
            r.total_calls = stats.total.load(std::memory_order_relaxed);
            r.success_calls = stats.success.load(std::memory_order_relaxed);
            r.failure_calls = stats.failure.load(std::memory_order_relaxed);
            r.echo_calls = stats.echo_calls.load(std::memory_order_relaxed);
            r.add_calls = stats.add_calls.load(std::memory_order_relaxed);
            r.hash_calls = stats.hash_calls.load(std::memory_order_relaxed);
            r.leaked_calls = stats.leaked_calls.load(std::memory_order_relaxed);
            r.leaked_handles = stats.leaked_handles.load(
                std::memory_order_relaxed);
            r.running = running;

            if (!lingofuse::checkApp(stress::kMonitorApp)) {
                return;
            }

            // `param` is used strictly inside this scope: it is built,
            // handed to LF_Notify, and destroyed by RAII on scope exit.
            // This matches R1 + R2 for the reporter path too.
            try {
                lingofuse::DataHandle param(stress::kMonitorApi);
                if (stress::write_report(param, r)) {
                    lingofuse::notify(stress::kMonitorApp, param);
                }
                // LF_Notify returns; `param` is destroyed by ~DataHandle
                // as the `if` block closes. No further use.
            }
            catch (...) {
                // Never let a reporting failure disturb the load loop.
            }
            };

        while (!stop_flag.load(std::memory_order_relaxed)) {
            std::this_thread::sleep_for(
                std::chrono::milliseconds(kStatusIntervalMs));
            if (stop_flag.load(std::memory_order_relaxed)) break;

            const auto now = std::chrono::steady_clock::now();
            const double dt =
                std::chrono::duration<double>(now - last_report).count();
            last_report = now;

            const std::uint64_t total =
                stats.total.load(std::memory_order_relaxed);
            const double rate = (dt > 0.0)
                ? static_cast<double>(total - last_total) / dt
                : 0.0;
            last_total = total;

            publish(1);

            log_line("[Client ", my_pid, "] total=", total,
                " success=", stats.success.load(std::memory_order_relaxed),
                " failure=", stats.failure.load(std::memory_order_relaxed),
                " leaked=", stats.leaked_calls.load(std::memory_order_relaxed),
                " handles_leaked=", stats.leaked_handles.load(
                    std::memory_order_relaxed),
                " rate=", static_cast<std::uint64_t>(rate), " calls/s");
        }

        publish(0);
    }

    struct ShutdownGuard {
        ~ShutdownGuard() {
            try { lingofuse::shutdown(); }
            catch (...) {}
        }
    };

} // namespace

int main(int argc, char* argv[]) {
    const int num_threads =
        (argc > 1) ? std::atoi(argv[1]) : kDefaultThreads;
    const int pause_ms =
        (argc > 2) ? std::atoi(argv[2]) : kDefaultPauseMs;

    g_pause_ms.store(pause_ms > 0 ? pause_ms : 0);

    const std::uint32_t my_pid = stress::get_current_pid();

    std::cout << "=== Stress Client (multi-threaded caller) ==="
        << std::endl;
    std::cout << "[Client] PID           : " << my_pid << "\n"
        << "[Client] Threads       : " << num_threads << "\n"
        << "[Client] Pause/call    : " << pause_ms << " ms\n"
        << "[Client] Call timeout  : " << kCallTimeoutMs << " ms\n"
        << "[Client] Handle policy : R1 use before/during call,\n"
        << "[Client]                 R2 destroy right after call,\n"
        << "[Client]                 R3 if leaked, never reuse\n"
        << "[Client] Leak policy   : 1 out of every "
        << kLeakEveryN << " calls\n"
        << "[Client] Target app    : " << stress::kServiceApp << "\n"
        << "[Client] Monitor app   : " << stress::kMonitorApp
        << " (API \"" << stress::kMonitorApi << "\")\n"
        << "[Client] Exit with Ctrl+C, or press Enter." << std::endl;

    try {
#if defined(_WIN32)
        SetConsoleCtrlHandler(console_ctrl_handler, TRUE);
#else
        std::signal(SIGINT, posix_signal_handler);
        std::signal(SIGTERM, posix_signal_handler);
#endif

        lingofuse::LibraryLoader loader;
        ShutdownGuard shutdown_guard;

        lingofuse::setOption("Wait_Ready", "False");
        lingofuse::resetPrepare();

        const int tag = lingofuse::prepareClient(stress::kEndpoint, nullptr);
        if (tag < 0) {
            std::cerr << "[FATAL] LF_PrepareClient failed for "
                << stress::kEndpoint << std::endl;
            return EXIT_FAILURE;
        }

        if (lingofuse::prepareDone() != 1) {
            std::cerr << "[FATAL] LF_PrepareDone failed." << std::endl;
            return EXIT_FAILURE;
        }

        std::cout << "[Client " << my_pid << "] Connected to "
            << stress::kEndpoint << ". Waiting for "
            << stress::kServiceApp << " to become visible..." << std::endl;

        bool ready = false;
        for (int i = 0; i < 50 && !g_stop_flag.load(); ++i) {
            if (lingofuse::checkApi(stress::kServiceApp, "echo") &&
                lingofuse::checkApi(stress::kServiceApp, "add") &&
                lingofuse::checkApi(stress::kServiceApp, "hash")) {
                ready = true;
                break;
            }
            std::this_thread::sleep_for(
                std::chrono::milliseconds(200));
        }

        if (!ready) {
            std::cerr << "[FATAL] Service '" << stress::kServiceApp
                << "' not visible after 10 seconds." << std::endl;
            lingofuse::exitMainThread();
            return EXIT_FAILURE;
        }

        std::cout << "[Client " << my_pid << "] Service is ready. Starting "
            << num_threads << " worker threads (infinite loop)..."
            << std::endl;

        Stats stats;

        std::vector<std::thread> workers;
        workers.reserve(static_cast<std::size_t>(num_threads));
        for (int i = 0; i < num_threads; ++i) {
            workers.emplace_back(worker, i, std::ref(stats));
        }

        std::thread reporter_thread(
            reporter,
            std::cref(stats),
            std::cref(g_stop_flag));

        std::thread([]() {
            std::string line;
            if (std::getline(std::cin, line)) {
                g_stop_flag.store(true);
            }
            }).detach();

        while (!g_stop_flag.load()) {
            std::this_thread::sleep_for(std::chrono::milliseconds(100));
        }

        std::cout << "\n[Client " << my_pid
            << "] Stop signal received. Joining threads..."
            << std::endl;

        for (auto& t : workers) {
            if (t.joinable()) t.join();
        }

        if (reporter_thread.joinable()) {
            reporter_thread.join();
        }

        const auto total = stats.total.load();
        const auto success = stats.success.load();
        const auto failure = stats.failure.load();
        const auto leaked_calls = stats.leaked_calls.load();
        const auto leaked_handles = stats.leaked_handles.load();

        std::cout << "\n[Client " << my_pid << "] Final summary\n"
            << "         total calls       : " << total << "\n"
            << "         success           : " << success << "\n"
            << "         failed            : " << failure << "\n"
            << "         leaked calls      : " << leaked_calls << "\n"
            << "         leaked handles    : " << leaked_handles << "\n"
            << std::endl;

        lingofuse::exitMainThread();

    }
    catch (const lingofuse::Error& e) {
        std::cerr << "[FATAL] lingofuse::Error (code="
            << static_cast<int>(e.code()) << "): "
            << e.what() << std::endl;
        g_stop_flag.store(true);
        return EXIT_FAILURE;
    }
    catch (const std::exception& e) {
        std::cerr << "[FATAL] std::exception: " << e.what() << std::endl;
        g_stop_flag.store(true);
        return EXIT_FAILURE;
    }
    catch (...) {
        std::cerr << "[FATAL] Unknown exception." << std::endl;
        g_stop_flag.store(true);
        return EXIT_FAILURE;
    }

    std::cout << "[Client " << my_pid << "] Bye." << std::endl;
    return EXIT_SUCCESS;
}