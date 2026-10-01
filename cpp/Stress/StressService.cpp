// =============================================================================
//  StressService.cpp
// -----------------------------------------------------------------------------
//  Beacon + API executor for the LingoFuse stress test.
//
//  Interactive mode: prints a human-readable summary once per second.
//  CI mode (--ci):  emits JSON Lines events (ready / progress / summary)
//                   and supports --shutdown-after for automatic termination.
//
//  Registered APIs:
//      add, sub, mul, div, echo    (Call mode)
//      notify_demo                 (Notify mode)
//
//  Cleanup order (Pascal LF-CLEAN-001):
//      LF_ExitMainThread -> ~App (LF_FreeApp) -> LF_Shutdown
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
#include <sstream>
#include <string>
#include <thread>

#if defined(_WIN32)
#  define WIN32_LEAN_AND_MEAN
#  include <windows.h>
#else
#  include <csignal>
#  include <unistd.h>
#endif

namespace {

    std::atomic<std::uint64_t> g_api_counts[stress::kApiCount]{};
    std::atomic<bool>          g_stop_flag{ false };

    // Set in main; read by reporter and JSON emitters.
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
        std::cout.flush();
    }

    // ========================================================================
    //  API callbacks
    // ========================================================================

    void LF_CDECL api_add(void*, void* input, void* output) {
        g_api_counts[stress::kIdxAdd].fetch_add(1, std::memory_order_relaxed);
        lingofuse::DataHandle in(static_cast<TDataHnd>(input), false);
        lingofuse::DataHandle out(static_cast<TDataHnd>(output), false);
        std::int32_t a = 0, b = 0;
        if (!in.read(a) || !in.read(b)) return;
        out.write(static_cast<std::int32_t>(a + b));
    }

    void LF_CDECL api_sub(void*, void* input, void* output) {
        g_api_counts[stress::kIdxSub].fetch_add(1, std::memory_order_relaxed);
        lingofuse::DataHandle in(static_cast<TDataHnd>(input), false);
        lingofuse::DataHandle out(static_cast<TDataHnd>(output), false);
        std::int32_t a = 0, b = 0;
        if (!in.read(a) || !in.read(b)) return;
        out.write(static_cast<std::int32_t>(a - b));
    }

    void LF_CDECL api_mul(void*, void* input, void* output) {
        g_api_counts[stress::kIdxMul].fetch_add(1, std::memory_order_relaxed);
        lingofuse::DataHandle in(static_cast<TDataHnd>(input), false);
        lingofuse::DataHandle out(static_cast<TDataHnd>(output), false);
        std::int32_t a = 0, b = 0;
        if (!in.read(a) || !in.read(b)) return;
        out.write(static_cast<std::int32_t>(a * b));
    }

    void LF_CDECL api_div(void*, void* input, void* output) {
        g_api_counts[stress::kIdxDiv].fetch_add(1, std::memory_order_relaxed);
        lingofuse::DataHandle in(static_cast<TDataHnd>(input), false);
        lingofuse::DataHandle out(static_cast<TDataHnd>(output), false);
        std::int32_t a = 0, b = 0;
        if (!in.read(a) || !in.read(b)) return;
        out.write(static_cast<std::int32_t>(b == 0 ? 0 : a / b));
    }

    void LF_CDECL api_echo(void*, void* input, void* output) {
        g_api_counts[stress::kIdxEcho].fetch_add(1, std::memory_order_relaxed);
        lingofuse::DataHandle in(static_cast<TDataHnd>(input), false);
        lingofuse::DataHandle out(static_cast<TDataHnd>(output), false);
        std::string s;
        if (!in.read(s)) return;
        out.write(s);
    }

    void LF_CDECL api_notify_demo(void*, void* /*input*/) {
        g_api_counts[stress::kIdxNotifyDemo].fetch_add(
            1, std::memory_order_relaxed);
    }

    // ========================================================================
    //  Reporter
    // ========================================================================
    //  Interactive: one human-readable line per second.
    //  CI:          one JSON object per second on stdout, plus a final
    //               summary emitted by main on shutdown.
    // ========================================================================
    void reporter(int interval_ms) {
        std::uint64_t last[stress::kApiCount] = { 0 };
        const std::uint32_t pid = stress::get_current_pid();
        const auto start_steady = std::chrono::steady_clock::now();

        while (!g_stop_flag.load(std::memory_order_relaxed)) {
            std::this_thread::sleep_for(
                std::chrono::milliseconds(interval_ms));
            if (g_stop_flag.load(std::memory_order_relaxed)) break;

            const auto now_steady = std::chrono::steady_clock::now();
            const double elapsed_sec =
                std::chrono::duration<double>(now_steady - start_steady).count();

            stress::ClientReport r;
            r.pid = pid;
            r.timestamp_ms = stress::now_ms();
            r.role = stress::kRoleService;
            r.running = 1;

            std::uint64_t delta_total = 0;
            std::uint64_t cumulative = 0;

            for (std::size_t i = 0; i < stress::kApiCount; ++i) {
                r.per_api[i] = g_api_counts[i].load(std::memory_order_relaxed);
                delta_total += (r.per_api[i] - last[i]);
                cumulative += r.per_api[i];
                last[i] = r.per_api[i];
            }

            for (std::size_t i = 0; i < stress::kCallApiCount; ++i) {
                r.call_total += r.per_api[i];
            }
            r.call_success = r.call_total;
            r.notify_total = r.per_api[stress::kIdxNotifyDemo];

            if (g_ci_mode) {
                nlohmann::json j;
                j["event"] = "progress";
                j["t_sec"] = static_cast<int>(elapsed_sec);
                j["processed"] = delta_total;
                j["cumulative"] = cumulative;
                j["rate"] = (elapsed_sec > 0.0)
                    ? static_cast<std::uint64_t>(
                        static_cast<double>(cumulative) / elapsed_sec)
                    : 0;
                for (std::size_t i = 0; i < stress::kApiCount; ++i) {
                    j["per_api"][stress::kApiNames[i]] = r.per_api[i];
                }
                stress::json_emit(j);
            }
            else {
                std::ostringstream oss;
                oss << "[Service " << pid << "] processed/s=" << delta_total
                    << "  cumulative=" << cumulative << "  |";
                for (std::size_t i = 0; i < stress::kApiCount; ++i) {
                    oss << ' ' << stress::kApiNames[i] << '=' << r.per_api[i];
                }
                log_line(oss.str());
            }

            // Publish to monitor if online.
            if (!lingofuse::checkApp(stress::kMonitorApp)) continue;
            try {
                lingofuse::DataHandle param(stress::kMonitorApi);
                if (stress::write_report(param, r)) {
                    lingofuse::notify(stress::kMonitorApp, param);
                }
            }
            catch (...) {}
        }
    }

    struct ShutdownGuard {
        ~ShutdownGuard() {
            try { lingofuse::shutdown(); }
            catch (...) {}
        }
    };

} // namespace

int main(int argc, char* argv[]) {
    const stress::CliOptions opt =
        stress::CliOptions::parse(argc, argv, "StressService");
    g_ci_mode = opt.ci;

    const std::uint32_t pid = stress::get_current_pid();
    const auto start_steady = std::chrono::steady_clock::now();

    if (!opt.ci) {
        std::cout << "=== Stress Service (beacon + API executor) ===" << std::endl;
    }

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
            lingofuse::App app(stress::kServiceApp, "Stress test service");

            struct Entry { const char* name; LF_CallFunc cb; };
            const Entry call_entries[] = {
                { "add",  api_add  },
                { "sub",  api_sub  },
                { "mul",  api_mul  },
                { "div",  api_div  },
                { "echo", api_echo },
            };

            for (const auto& e : call_entries) {
                if (!app.registerCall(e.name, e.name, nullptr, e.cb)) {
                    std::cerr << "[FATAL] Failed to register call API '"
                        << e.name << "'." << std::endl;
                    return EXIT_FAILURE;
                }
            }

            if (!app.registerNotify("notify_demo",
                "one-way notification sink",
                nullptr, api_notify_demo)) {
                std::cerr << "[FATAL] Failed to register notify API "
                    "'notify_demo'." << std::endl;
                return EXIT_FAILURE;
            }

            if (opt.ci) {
                lingofuse::setOption("Quiet", "True");
            }

            lingofuse::setOption("Wait_Ready", "False");
            lingofuse::resetPrepare();

            const int serv_tag =
                lingofuse::prepareService("ipc:stress", "ipc:stress");
            if (serv_tag < 0) {
                std::cerr << "[FATAL] LF_PrepareService failed (ipc)."
                    << std::endl;
                return EXIT_FAILURE;
            }

            const int serv_tag2 =
                lingofuse::prepareService("0.0.0.0:9588", "127.0.0.1:9588");
            if (serv_tag2 < 0) {
                std::cerr << "[FATAL] LF_PrepareService failed (0.0.0.0:9588)."
                    << std::endl;
                return EXIT_FAILURE;
            }

            const int cli_tag =
                lingofuse::prepareClient("ipc:stress", app.get());
            if (cli_tag < 0) {
                std::cerr << "[FATAL] LF_PrepareClient failed (ipc)."
                    << std::endl;
                return EXIT_FAILURE;
            }

            const int cli_tag2 =
                lingofuse::prepareClient("127.0.0.1:9588", app.get());
            if (cli_tag2 < 0) {
                std::cerr << "[FATAL] LF_PrepareClient failed (0.0.0.0:9588)."
                    << std::endl;
                return EXIT_FAILURE;
            }

            if (lingofuse::prepareDone() != 1) {
                std::cerr << "[FATAL] LF_PrepareDone failed." << std::endl;
                return EXIT_FAILURE;
            }

            if (opt.ci) {
                nlohmann::json j;
                j["event"] = "ready";
                j["pid"] = pid;
                j["role"] = "service";
                j["endpoint"] = stress::kEndpoint;
                j["app"] = stress::kServiceApp;
                j["api_count"] = stress::kApiCount;
                for (std::size_t i = 0; i < stress::kApiCount; ++i) {
                    j["apis"][i] = stress::kApiNames[i];
                }
                stress::json_emit(j);
            }
            else {
                std::cout << "[Service] Registered " << stress::kApiCount
                    << " APIs (" << stress::kCallApiCount
                    << " Call-mode, " << stress::kNotifyApiCount
                    << " Notify-mode)." << std::endl;
                std::cout << "[Service] Online on ipc:stress. "
                    "Press Ctrl+C or Enter to shut down..."
                    << std::endl;
            }

            // ---- Auto-shutdown timer (CI / unattended mode) --------------
            if (opt.shutdown_after_sec > 0) {
                std::thread([&]() {
                    std::this_thread::sleep_for(
                        std::chrono::seconds(opt.shutdown_after_sec));
                    g_stop_flag.store(true);
                    }).detach();
            }
            else if (!opt.ci) {
                // Interactive mode only: Enter stops the program.
                std::thread([]() {
                    std::string line;
                    if (std::getline(std::cin, line)) {
                        g_stop_flag.store(true);
                    }
                    }).detach();
            }

            std::thread reporter_thread(reporter, opt.interval_ms);

            while (!g_stop_flag.load()) {
                std::this_thread::sleep_for(std::chrono::milliseconds(100));
            }

            if (!opt.ci) {
                std::cout << "\n[Service] Shutting down..." << std::endl;
            }

            if (reporter_thread.joinable()) reporter_thread.join();

            // ---- Final summary -------------------------------------------
            const auto now_steady = std::chrono::steady_clock::now();
            const double uptime_sec =
                std::chrono::duration<double>(now_steady - start_steady).count();

            std::uint64_t call_total = 0;
            std::uint64_t notify_total = 0;
            std::uint64_t per_api[stress::kApiCount] = {};
            for (std::size_t i = 0; i < stress::kApiCount; ++i) {
                per_api[i] = g_api_counts[i].load(std::memory_order_relaxed);
            }
            for (std::size_t i = 0; i < stress::kCallApiCount; ++i) {
                call_total += per_api[i];
            }
            notify_total = per_api[stress::kIdxNotifyDemo];

            if (opt.ci) {
                nlohmann::json j;
                j["event"] = "summary";
                j["pid"] = pid;
                j["role"] = "service";
                j["uptime_sec"] = static_cast<int>(uptime_sec);
                j["call_total"] = call_total;
                j["notify_total"] = notify_total;
                j["total_processed"] = call_total + notify_total;
                for (std::size_t i = 0; i < stress::kApiCount; ++i) {
                    j["per_api"][stress::kApiNames[i]] = per_api[i];
                }
                stress::json_emit(j);
            }
            else {
                std::cout << "[Service] Final: call_total=" << call_total
                    << "  notify_total=" << notify_total
                    << "  uptime=" << uptime_sec << "s" << std::endl;
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

    if (!opt.ci) {
        std::cout << "[Service] Bye." << std::endl;
    }
    return EXIT_SUCCESS;
}