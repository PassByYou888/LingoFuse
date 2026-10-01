// =============================================================================
//  StressClient.cpp
// -----------------------------------------------------------------------------
//  Multi-threaded caller for the LingoFuse stress test.
//
//  Per worker, per iteration:
//      --notify-per-loop  x notify_demo   (default 20)
//      --call-per-loop    x random Call   (default 1)
//
//  =============================================================================
//  CALL vs NOTIFY PARALLELISM
//  =============================================================================
//
//  Call is SYNCHRONOUS. A thread that has issued a Call cannot do
//  anything else until the response returns. Call throughput scales with
//  thread count, up to the server's saturation point:
//
//      StressClient --ci --duration 30 --threads 512 --notify-per-loop 0
//
//  Notify is FIRE-AND-FORGET. One thread can dispatch many messages
//  back-to-back without waiting. Notify throughput scales with dispatch
//  rate, not thread count.
//
//  The two loads are independent:
//
//      Pure Call      : --notify-per-loop 0
//      Pure Notify    : --call-per-loop 0
//      Mixed          : --threads 64 (default 20:1)
//
//  =============================================================================
//  THROUGHPUT NOTE
//  =============================================================================
//
//  When --pause is 0 (the default), the worker loop does NOT sleep
//  between iterations. Rate limiting is opt-in via --pause N.
//
//  =============================================================================
//  DELIBERATE HANDLE LEAK POLICY
//  =============================================================================
//
//  1 in 100 DataHandles is intentionally abandoned, to exercise the
//  auto-reclaimer under load. Do not copy this behaviour into
//  production code.
//
//  Cleanup order (Pascal LF-CLEAN-001):
//      LF_ExitMainThread -> LF_Shutdown -> LF_FreeLibrary
// =============================================================================

#if defined(_WIN32) && !defined(_CRT_SECURE_NO_WARNINGS)
#  define _CRT_SECURE_NO_WARNINGS
#endif

#include "LingoFuse.hpp"
#include "StressCommon.hpp"

#include <atomic>
#include <chrono>
#include <cstdint>
#include <cstdlib>
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
#else
#  include <csignal>
#  include <unistd.h>
#endif

namespace {

    constexpr int kCallTimeoutMs = 30000;
    constexpr int kStatusIntervalMs = 1000;
    constexpr int kMaxConsecutiveErrors = 100;
    constexpr int kLeakEveryN = 100;

    constexpr int kNumberMin = 1;
    constexpr int kNumberMax = 10000;

    std::atomic<int>  g_pause_ms{ 0 };
    std::atomic<bool> g_stop_flag{ false };

    bool g_ci_mode = false;

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
    extern "C" void posix_stop_handler(int) {
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
        std::cout.flush();
    }

    struct ShutdownGuard {
        ~ShutdownGuard() {
            try { lingofuse::shutdown(); }
            catch (...) {}
        }
    };

    inline bool roll_leak() {
        static thread_local int counter = kLeakEveryN;
        if (--counter <= 0) {
            counter = kLeakEveryN;
            return true;
        }
        return false;
    }

    struct Stats {
        std::atomic<std::uint64_t> call_total{ 0 };
        std::atomic<std::uint64_t> call_success{ 0 };
        std::atomic<std::uint64_t> call_failure{ 0 };
        std::atomic<std::uint64_t> notify_total{ 0 };
        std::atomic<std::uint64_t> leaked_calls{ 0 };
        std::atomic<std::uint64_t> leaked_handles{ 0 };
        std::atomic<std::uint64_t> per_api[stress::kApiCount]{};

        Stats() = default;
        Stats(const Stats&) = delete;
        Stats& operator=(const Stats&) = delete;
    };

    template <typename WriteFn, typename VerifyFn>
    bool call_api(const char* api,
        std::size_t api_index,
        WriteFn write_fn,
        VerifyFn verify_fn,
        Stats& stats) {
        const bool leak_this = roll_leak();
        try {
            lingofuse::DataHandle param(api);
            write_fn(param);

            auto response = lingofuse::tryCall(
                stress::kServiceApp, param, kCallTimeoutMs);

            bool ok = false;
            if (response) {
                ok = verify_fn(*response);
            }

            if (leak_this) {
                (void)param.release();
                stats.leaked_handles.fetch_add(1, std::memory_order_relaxed);
                stats.leaked_calls.fetch_add(1, std::memory_order_relaxed);
            }

            stats.call_total.fetch_add(1, std::memory_order_relaxed);
            stats.per_api[api_index].fetch_add(1, std::memory_order_relaxed);
            if (ok) {
                stats.call_success.fetch_add(1, std::memory_order_relaxed);
            }
            else {
                stats.call_failure.fetch_add(1, std::memory_order_relaxed);
            }
            return ok;
        }
        catch (...) {
            stats.call_total.fetch_add(1, std::memory_order_relaxed);
            stats.per_api[api_index].fetch_add(1, std::memory_order_relaxed);
            stats.call_failure.fetch_add(1, std::memory_order_relaxed);
            return false;
        }
    }

    void worker(int index,
        Stats& stats,
        int notify_per_loop,
        int call_per_loop) {
        std::mt19937 rng(
            static_cast<std::uint32_t>(index) ^
            static_cast<std::uint32_t>(
                std::chrono::steady_clock::now()
                .time_since_epoch().count()));

        std::uniform_int_distribution<int> num(kNumberMin, kNumberMax);
        std::uniform_int_distribution<int> api_pick(
            0, static_cast<int>(stress::kCallApiCount) - 1);

        int consecutive_errors = 0;

        while (!g_stop_flag.load(std::memory_order_relaxed)) {

            // ---------------------------------------------------------
            //  Phase 1: notify burst
            // ---------------------------------------------------------
            for (int i = 0; i < notify_per_loop; ++i) {
                if (g_stop_flag.load(std::memory_order_relaxed)) return;

                const bool leak_this = roll_leak();
                try {
                    lingofuse::DataHandle param("notify_demo");
                    param.write(std::string("tick"));
                    lingofuse::notify(stress::kServiceApp, param);

                    stats.notify_total.fetch_add(1, std::memory_order_relaxed);
                    stats.per_api[stress::kIdxNotifyDemo].fetch_add(
                        1, std::memory_order_relaxed);

                    if (leak_this) {
                        (void)param.release();
                        stats.leaked_handles.fetch_add(
                            1, std::memory_order_relaxed);
                        stats.leaked_calls.fetch_add(
                            1, std::memory_order_relaxed);
                    }
                }
                catch (...) {}
            }

            // ---------------------------------------------------------
            //  Phase 2: call burst (serial)
            // ---------------------------------------------------------
            bool iteration_ok = true;

            for (int c = 0; c < call_per_loop; ++c) {
                if (g_stop_flag.load(std::memory_order_relaxed)) return;

                bool ok = true;
                const int which = api_pick(rng);
                switch (which) {
                case 0: {
                    const std::int32_t a = static_cast<std::int32_t>(num(rng));
                    const std::int32_t b = static_cast<std::int32_t>(num(rng));
                    ok = call_api("add", stress::kIdxAdd,
                        [&](lingofuse::DataHandle& p) { p.write(a); p.write(b); },
                        [&](lingofuse::DataHandle& r) {
                            std::int32_t v = 0;
                            return r.read(v) && v == a + b;
                        }, stats);
                    break;
                }
                case 1: {
                    const std::int32_t a = static_cast<std::int32_t>(num(rng));
                    const std::int32_t b = static_cast<std::int32_t>(num(rng));
                    ok = call_api("sub", stress::kIdxSub,
                        [&](lingofuse::DataHandle& p) { p.write(a); p.write(b); },
                        [&](lingofuse::DataHandle& r) {
                            std::int32_t v = 0;
                            return r.read(v) && v == a - b;
                        }, stats);
                    break;
                }
                case 2: {
                    const std::int32_t a = static_cast<std::int32_t>(num(rng));
                    const std::int32_t b = static_cast<std::int32_t>(num(rng));
                    ok = call_api("mul", stress::kIdxMul,
                        [&](lingofuse::DataHandle& p) { p.write(a); p.write(b); },
                        [&](lingofuse::DataHandle& r) {
                            std::int32_t v = 0;
                            return r.read(v) && v == a * b;
                        }, stats);
                    break;
                }
                case 3: {
                    const std::int32_t a = static_cast<std::int32_t>(num(rng));
                    const std::int32_t b = static_cast<std::int32_t>(num(rng));
                    ok = call_api("div", stress::kIdxDiv,
                        [&](lingofuse::DataHandle& p) { p.write(a); p.write(b); },
                        [&](lingofuse::DataHandle& r) {
                            std::int32_t v = 0;
                            const std::int32_t expected = (b == 0) ? 0 : a / b;
                            return r.read(v) && v == expected;
                        }, stats);
                    break;
                }
                case 4: {
                    const std::string payload =
                        "echo_" + std::to_string(num(rng));
                    ok = call_api("echo", stress::kIdxEcho,
                        [&](lingofuse::DataHandle& p) { p.write(payload); },
                        [&](lingofuse::DataHandle& r) {
                            std::string s;
                            return r.read(s) && s == payload;
                        }, stats);
                    break;
                }
                default:
                    break;
                }

                if (!ok) iteration_ok = false;
            }

            // ---------------------------------------------------------
            //  Error kill switch
            // ---------------------------------------------------------
            if (iteration_ok) {
                consecutive_errors = 0;
            }
            else {
                ++consecutive_errors;
                if (consecutive_errors >= kMaxConsecutiveErrors) {
                    if (!g_ci_mode) {
                        log_line("[Worker ", index,
                            "] too many consecutive errors; exiting.");
                    }
                    return;
                }
            }

            // ---------------------------------------------------------
            //  Rate limiting (optional)
            // ---------------------------------------------------------
            const int pause = g_pause_ms.load(std::memory_order_relaxed);
            if (pause > 0) {
                std::this_thread::sleep_for(
                    std::chrono::milliseconds(pause));
            }
        }
    }

    void reporter(const Stats& stats, int interval_ms) {
        try {
            const std::uint32_t my_pid = stress::get_current_pid();
            const auto start_steady = std::chrono::steady_clock::now();

            auto last_report = std::chrono::steady_clock::now();
            std::uint64_t last_call_total = 0;

            auto publish = [&](int running) {
                stress::ClientReport r;
                r.pid = my_pid;
                r.timestamp_ms = stress::now_ms();
                r.role = stress::kRoleClient;
                r.running = running;
                r.call_total = stats.call_total.load(std::memory_order_relaxed);
                r.call_success = stats.call_success.load(std::memory_order_relaxed);
                r.call_failure = stats.call_failure.load(std::memory_order_relaxed);
                r.notify_total = stats.notify_total.load(std::memory_order_relaxed);
                r.leaked_calls = stats.leaked_calls.load(std::memory_order_relaxed);
                r.leaked_handles = stats.leaked_handles.load(std::memory_order_relaxed);
                for (std::size_t i = 0; i < stress::kApiCount; ++i) {
                    r.per_api[i] = stats.per_api[i].load(
                        std::memory_order_relaxed);
                }
                if (!lingofuse::checkApp(stress::kMonitorApp)) return;
                try {
                    lingofuse::DataHandle param(stress::kMonitorApi);
                    if (stress::write_report(param, r)) {
                        lingofuse::notify(stress::kMonitorApp, param);
                    }
                }
                catch (...) {}
                };

            while (!g_stop_flag.load(std::memory_order_relaxed)) {
                std::this_thread::sleep_for(
                    std::chrono::milliseconds(interval_ms));
                if (g_stop_flag.load(std::memory_order_relaxed)) break;

                const auto now = std::chrono::steady_clock::now();
                const double dt =
                    std::chrono::duration<double>(now - last_report).count();
                last_report = now;

                const std::uint64_t total =
                    stats.call_total.load(std::memory_order_relaxed);
                const double call_rate = (dt > 0.0)
                    ? static_cast<double>(total - last_call_total) / dt
                    : 0.0;
                last_call_total = total;

                publish(1);

                const auto now_steady = std::chrono::steady_clock::now();
                const double elapsed_sec =
                    std::chrono::duration<double>(now_steady - start_steady).count();

                if (g_ci_mode) {
                    nlohmann::json j;
                    j["event"] = "progress";
                    j["t_sec"] = static_cast<int>(elapsed_sec);
                    j["call_total"] = total;
                    j["call_success"] = stats.call_success.load(
                        std::memory_order_relaxed);
                    j["call_failure"] = stats.call_failure.load(
                        std::memory_order_relaxed);
                    j["notify_total"] = stats.notify_total.load(
                        std::memory_order_relaxed);
                    j["leaked_handles"] = stats.leaked_handles.load(
                        std::memory_order_relaxed);
                    j["call_rate"] = static_cast<std::uint64_t>(call_rate);
                    stress::json_emit(j);
                }
                else {
                    log_line("[Client ", my_pid,
                        "] calls=", total,
                        " ok=", stats.call_success.load(
                            std::memory_order_relaxed),
                        " fail=", stats.call_failure.load(
                            std::memory_order_relaxed),
                        " notifies=", stats.notify_total.load(
                            std::memory_order_relaxed),
                        " leaks=", stats.leaked_handles.load(
                            std::memory_order_relaxed),
                        " call_rate=",
                        static_cast<std::uint64_t>(call_rate),
                        " calls/s");
                }
            }

            publish(0);
        }
        catch (const std::exception& e) {
            if (!g_ci_mode) {
                log_line("[Reporter] FATAL: ", e.what());
            }
        }
        catch (...) {
            if (!g_ci_mode) {
                log_line("[Reporter] FATAL: unknown exception.");
            }
        }
    }

} // namespace

int main(int argc, char* argv[]) {
    const stress::CliOptions opt =
        stress::CliOptions::parse(argc, argv, "StressClient");
    g_ci_mode = opt.ci;
    g_pause_ms.store(opt.pause_ms > 0 ? opt.pause_ms : 0);

    const std::uint32_t my_pid = stress::get_current_pid();
    const auto start_steady = std::chrono::steady_clock::now();

#if defined(_WIN32)
    SetConsoleCtrlHandler(console_ctrl_handler, TRUE);
#else
    std::signal(SIGINT, posix_stop_handler);
    std::signal(SIGTERM, posix_stop_handler);
#endif

    if (!opt.ci) {
        std::cout << "=== Stress Client (multi-threaded caller) ===" << std::endl;
        std::cout << "[Client] PID             : " << my_pid << "\n"
            << "[Client] Threads         : " << opt.threads << "\n"
            << "[Client] Notify/loop     : " << opt.notify_per_loop << "\n"
            << "[Client] Call/loop       : " << opt.call_per_loop << "\n"
            << "[Client] Pause/loop      : " << opt.pause_ms << " ms"
            << (opt.pause_ms > 0
                ? "\n"
                : "   (no pause; full speed)\n")
            << "[Client] Call timeout    : " << kCallTimeoutMs << " ms\n"
            << "[Client] Handle leak rate: 1 in " << kLeakEveryN
            << " handles (deliberate; reclaimed after 10 min idle)\n"
            << "[Client] Target app      : " << stress::kServiceApp << "\n"
            << "[Client] Endpoint        : " << stress::kEndpoint << "\n"
            << "[Client] Exit with Ctrl+C, or press Enter." << std::endl;
    }

    try {
        lingofuse::LibraryLoader loader;
        ShutdownGuard shutdown_guard;

        lingofuse::setOption("Wait_Ready", "False");
        if (opt.ci) {
            lingofuse::setOption("Quiet", "True");
        }
        lingofuse::resetPrepare();

        const int tag = lingofuse::prepareClient(stress::kEndpoint, nullptr);
        if (tag < 0) {
            std::cerr << "[FATAL] LF_PrepareClient failed for "
                << stress::kEndpoint << std::endl;
            return EXIT_FAILURE;
        }

        const int tag2 = lingofuse::prepareClient("127.0.0.1:9588", nullptr);
        if (tag2 < 0) {
            std::cerr << "[FATAL] LF_PrepareClient failed for "
                << "127.0.0.1:9588" << std::endl;
            return EXIT_FAILURE;
        }

        if (lingofuse::prepareDone() != 1) {
            std::cerr << "[FATAL] LF_PrepareDone failed." << std::endl;
            return EXIT_FAILURE;
        }

        if (!opt.ci) {
            std::cout << "[Client " << my_pid << "] Waiting for "
                << stress::kServiceApp << "..." << std::endl;
        }

        bool ready = false;
        for (int i = 0; i < 50 && !g_stop_flag.load(); ++i) {
            bool all_visible = true;
            for (std::size_t k = 0; k < stress::kApiCount; ++k) {
                if (!lingofuse::checkApi(stress::kServiceApp,
                    stress::kApiNames[k])) {
                    all_visible = false;
                    break;
                }
            }
            if (all_visible) { ready = true; break; }
            std::this_thread::sleep_for(std::chrono::milliseconds(200));
        }

        if (!ready) {
            std::cerr << "[FATAL] Service '" << stress::kServiceApp
                << "' not fully visible after 10 seconds."
                << std::endl;
            lingofuse::exitMainThread();
            return EXIT_FAILURE;
        }

        if (opt.ci) {
            nlohmann::json j;
            j["event"] = "ready";
            j["pid"] = my_pid;
            j["role"] = "client";
            j["threads"] = opt.threads;
            j["notify_per_loop"] = opt.notify_per_loop;
            j["call_per_loop"] = opt.call_per_loop;
            j["pause_ms"] = opt.pause_ms;
            j["duration_sec"] = opt.duration_sec;
            j["warmup_sec"] = opt.warmup_sec;
            j["min_success_pct"] = opt.min_success_pct;
            j["min_total_calls"] = opt.min_total_calls;
            stress::json_emit(j);
        }
        else {
            std::cout << "[Client " << my_pid << "] Service ready. Starting "
                << opt.threads << " worker threads ("
                << opt.notify_per_loop << " notify + "
                << opt.call_per_loop << " call per loop)..."
                << std::endl;
        }

        Stats stats;
        std::vector<std::thread> threads;
        threads.reserve(static_cast<std::size_t>(opt.threads) + 1);

        for (int i = 0; i < opt.threads; ++i) {
            threads.emplace_back(worker, i, std::ref(stats),
                opt.notify_per_loop, opt.call_per_loop);
        }
        threads.emplace_back(reporter, std::cref(stats), opt.interval_ms);

        if (!opt.ci) {
            std::thread([]() {
                std::string line;
                if (std::getline(std::cin, line)) {
                    g_stop_flag.store(true);
                }
                }).detach();
        }

        if (!opt.ci) {
            std::cout << "[Client " << my_pid
                << "] All threads running. Press Ctrl+C or Enter to stop."
                << std::endl;
        }

        while (!g_stop_flag.load()) {
            std::this_thread::sleep_for(std::chrono::milliseconds(100));

            if (opt.duration_sec > 0) {
                const auto now_steady = std::chrono::steady_clock::now();
                const int elapsed =
                    static_cast<int>(std::chrono::duration_cast<
                        std::chrono::seconds>(now_steady - start_steady).count());
                if (elapsed >= opt.duration_sec) {
                    g_stop_flag.store(true);
                }
            }
        }

        if (!opt.ci) {
            std::cout << "\n[Client " << my_pid
                << "] Stop signal received. Joining threads..."
                << std::endl;
        }

        for (auto& t : threads) {
            if (t.joinable()) t.join();
        }

        const auto now_steady = std::chrono::steady_clock::now();
        const double elapsed_sec =
            std::chrono::duration<double>(now_steady - start_steady).count();

        const auto total = stats.call_total.load();
        const auto success = stats.call_success.load();
        const auto failure = stats.call_failure.load();
        const auto notifies = stats.notify_total.load();
        const auto leaked_h = stats.leaked_handles.load();
        const auto leaked_c = stats.leaked_calls.load();

        const double success_pct =
            (total > 0)
            ? (100.0 * static_cast<double>(success) / static_cast<double>(total))
            : 0.0;

        // ---------------------------------------------------------
        //  Verdict
        // ---------------------------------------------------------
        //  Pass both the Call count AND the Notify count to the
        //  verdict function. The function decides which threshold to
        //  apply based on the run shape (pure-Notify vs Call-dominant).
        const bool pass =
            stress::ci_verdict_pass(total, notifies, success_pct, opt);

        if (opt.ci) {
            nlohmann::json j;
            j["event"] = "summary";
            j["pid"] = my_pid;
            j["role"] = "client";
            j["duration_sec"] = static_cast<int>(elapsed_sec);
            j["threads"] = opt.threads;
            j["notify_per_loop"] = opt.notify_per_loop;
            j["call_per_loop"] = opt.call_per_loop;
            j["call_total"] = total;
            j["call_success"] = success;
            j["call_failure"] = failure;
            j["success_pct"] = success_pct;
            j["notify_total"] = notifies;
            j["leaked_calls"] = leaked_c;
            j["leaked_handles"] = leaked_h;
            j["call_rate"] = (elapsed_sec > 0.0)
                ? static_cast<std::uint64_t>(
                    static_cast<double>(total) / elapsed_sec)
                : 0;
            j["notify_rate"] = (elapsed_sec > 0.0)
                ? static_cast<std::uint64_t>(
                    static_cast<double>(notifies) / elapsed_sec)
                : 0;
            j["success_rate_per_sec"] = (elapsed_sec > 0.0)
                ? static_cast<std::uint64_t>(
                    static_cast<double>(success) / elapsed_sec)
                : 0;
            for (std::size_t i = 0; i < stress::kApiCount; ++i) {
                j["per_api"][stress::kApiNames[i]] =
                    stats.per_api[i].load(std::memory_order_relaxed);
            }
            j["status"] = pass ? "PASS" : "FAIL";
            if (!pass) {
                // Distinguish the two failure modes for diagnosability.
                if (total == 0) {
                    j["reason"] = "NO_MESSAGES_DISPATCHED";
                }
                else if (opt.min_total_calls > 0 && total < opt.min_total_calls) {
                    j["reason"] = "TOTAL_CALLS_BELOW_MINIMUM";
                }
                else if (success_pct < opt.min_success_pct) {
                    j["reason"] = "SUCCESS_RATE_BELOW_MINIMUM";
                }
            }
            stress::json_emit(j);
        }
        else {
            std::cout << "\n[Client " << my_pid << "] Final summary\n"
                << "         duration       : " << elapsed_sec << " s\n"
                << "         call total     : " << total << "\n"
                << "         call success   : " << success << "\n"
                << "         call failed    : " << failure << "\n"
                << "         success rate   : " << success_pct << " %\n"
                << "         notify total   : " << notifies << "\n"
                << "         leaked calls   : " << leaked_c << "\n"
                << "         leaked handles : " << leaked_h << "\n"
                << "         per-API counts :\n";
            for (std::size_t i = 0; i < stress::kApiCount; ++i) {
                std::cout << "             " << stress::kApiNames[i] << " = "
                    << stats.per_api[i].load(std::memory_order_relaxed)
                    << "\n";
            }
            std::cout << std::endl;
        }

        lingofuse::exitMainThread();

        if (opt.ci) {
            return pass ? EXIT_SUCCESS : EXIT_FAILURE;
        }
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

    if (!opt.ci) {
        std::cout << "[Client " << my_pid << "] Bye." << std::endl;
    }
    return EXIT_SUCCESS;
}