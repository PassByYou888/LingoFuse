// =============================================================================
//  StressCommon.hpp
// -----------------------------------------------------------------------------
//  Shared definitions for the LingoFuse stress test suite.
//
//  Two operating modes:
//
//    (1) INTERACTIVE (default)
//          Human-readable output. Runs until stopped.
//
//    (2) CI (--ci)
//          Machine-readable JSON Lines on stdout. Fixed duration via
//          --duration. Exit code 0 on pass, 1 on fail, 2 on CLI error.
//
//  =============================================================================
//  CALL vs NOTIFY PARALLELISM (IMPORTANT)
//  =============================================================================
//
//  Call is SYNCHRONOUS. A thread that has issued a Call cannot do anything
//  else until the response returns. Call throughput scales with thread
//  count, up to the server's saturation point.
//
//  Notify is FIRE-AND-FORGET. A single thread can dispatch many Notify
//  messages back-to-back. Notify throughput scales with dispatch rate.
//
//  The client exposes two independent knobs:
//
//      --notify-per-loop N     notify messages per iteration (default 20)
//      --call-per-loop   N     Call messages per iteration   (default 1)
//
//  Pure-Call mode  : --notify-per-loop 0
//  Pure-Notify mode: --call-per-loop   0
// =============================================================================

#pragma once

#include "LingoFuse.hpp"

#include <algorithm>
#include <chrono>
#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <iostream>
#include <mutex>
#include <sstream>
#include <string>
#include <vector>

#if defined(_WIN32)
#  define WIN32_LEAN_AND_MEAN
#  include <windows.h>
#else
#  include <unistd.h>
#endif

namespace stress {

    // -------------------------------------------------------------------------
    //  Well-known names
    // -------------------------------------------------------------------------
    inline constexpr const char* kEndpoint = "ipc:stress";
    inline constexpr const char* kServiceApp = "StressSvc";
    inline constexpr const char* kMonitorApp = "StressMon";
    inline constexpr const char* kMonitorApi = "report";

    // -------------------------------------------------------------------------
    //  API table
    // -------------------------------------------------------------------------
    inline constexpr std::size_t kApiCount = 6;

    inline constexpr const char* kApiNames[kApiCount] = {
        "add", "sub", "mul", "div", "echo", "notify_demo"
    };

    enum ApiIndex : std::size_t {
        kIdxAdd = 0,
        kIdxSub = 1,
        kIdxMul = 2,
        kIdxDiv = 3,
        kIdxEcho = 4,
        kIdxNotifyDemo = 5
    };

    inline constexpr std::size_t kCallApiCount = 5;
    inline constexpr std::size_t kNotifyApiCount = 1;

    // -------------------------------------------------------------------------
    //  Report roles
    // -------------------------------------------------------------------------
    inline constexpr std::int32_t kRoleClient = 0;
    inline constexpr std::int32_t kRoleService = 1;

    // -------------------------------------------------------------------------
    //  Report record
    // -------------------------------------------------------------------------
    struct ClientReport {
        std::uint32_t pid = 0;
        std::uint64_t timestamp_ms = 0;
        std::int32_t  role = kRoleClient;
        std::int32_t  running = 0;

        std::uint64_t call_total = 0;
        std::uint64_t call_success = 0;
        std::uint64_t call_failure = 0;
        std::uint64_t notify_total = 0;

        std::uint64_t leaked_calls = 0;
        std::uint64_t leaked_handles = 0;

        std::uint64_t per_api[kApiCount] = {};
    };

    // -------------------------------------------------------------------------
    //  Portable helpers
    // -------------------------------------------------------------------------
    inline std::uint32_t get_current_pid() {
#if defined(_WIN32)
        return static_cast<std::uint32_t>(GetCurrentProcessId());
#else
        return static_cast<std::uint32_t>(::getpid());
#endif
    }

    inline std::uint64_t now_ms() {
        return static_cast<std::uint64_t>(
            std::chrono::duration_cast<std::chrono::milliseconds>(
                std::chrono::system_clock::now().time_since_epoch()).count());
    }

    inline std::uint64_t steady_ms() {
        return static_cast<std::uint64_t>(
            std::chrono::duration_cast<std::chrono::milliseconds>(
                std::chrono::steady_clock::now().time_since_epoch()).count());
    }

    // -------------------------------------------------------------------------
    //  Wire serialization for the notify-based fleet protocol
    // -------------------------------------------------------------------------
    inline bool write_report(lingofuse::DataHandle& h, const ClientReport& r) {
        try {
            h.write(r.pid);
            h.write(r.timestamp_ms);
            h.write(r.role);
            h.write(r.running);
            h.write(r.call_total);
            h.write(r.call_success);
            h.write(r.call_failure);
            h.write(r.notify_total);
            h.write(r.leaked_calls);
            h.write(r.leaked_handles);
            for (std::size_t i = 0; i < kApiCount; ++i) {
                h.write(r.per_api[i]);
            }
            return true;
        }
        catch (...) {
            return false;
        }
    }

    inline bool read_report(lingofuse::DataHandle& h, ClientReport& r) {
        try {
            if (!h.read(r.pid))            return false;
            if (!h.read(r.timestamp_ms))   return false;
            if (!h.read(r.role))           return false;
            if (!h.read(r.running))        return false;
            if (!h.read(r.call_total))     return false;
            if (!h.read(r.call_success))   return false;
            if (!h.read(r.call_failure))   return false;
            if (!h.read(r.notify_total))   return false;
            if (!h.read(r.leaked_calls))   return false;
            if (!h.read(r.leaked_handles)) return false;
            for (std::size_t i = 0; i < kApiCount; ++i) {
                if (!h.read(r.per_api[i])) return false;
            }
            return true;
        }
        catch (...) {
            return false;
        }
    }

    // =========================================================================
    //  CI SUPPORT
    // =========================================================================

    inline std::mutex& json_mutex() {
        static std::mutex m;
        return m;
    }

    inline void json_emit(const nlohmann::json& j) {
        std::lock_guard<std::mutex> lock(json_mutex());
        std::cout << j.dump() << '\n';
        std::cout.flush();
    }

    // -------------------------------------------------------------------------
    //  Command-line options
    // -------------------------------------------------------------------------
    struct CliOptions {
        bool ci = false;
        bool show_help = false;

        int duration_sec = 0;
        int shutdown_after_sec = 0;

        int threads = 32;
        int pause_ms = 0;
        int notify_per_loop = 20;
        int call_per_loop = 1;

        int interval_ms = 1000;
        int stale_timeout_ms = 5000;

        double        min_success_pct = 99.0;
        std::uint64_t min_total_calls = 0;
        int           warmup_sec = 3;

        static void print_usage(const char* prog, const char* role) {
            std::cerr
                << "Usage: " << prog << " [options]\n"
                << "\n"
                << "Role: " << role << "\n"
                << "\n"
                << "  --ci                        JSON Lines output; exit 0/1/2\n"
                << "  --duration N                run for N seconds\n"
                << "  --shutdown-after N          (service) auto-shutdown after N seconds\n"
                << "  --threads N                 (client)  worker thread count (default 32)\n"
                << "  --notify-per-loop N         (client)  notify msgs per iteration (default 20)\n"
                << "  --call-per-loop N           (client)  Call msgs per iteration  (default 1)\n"
                << "  --pause N                   (client)  pause per iteration, ms (default 0)\n"
                << "  --interval N                (monitor) sample interval, ms (default 1000)\n"
                << "  --stale-timeout N           (monitor) dead-client threshold, ms (default 5000)\n"
                << "  --min-success-pct F         (CI)      min success rate %% (default 99.0)\n"
                << "  --min-total-calls N         (CI)      min total Call count (default 0)\n"
                << "  --warmup N                  (CI)      warmup window, sec (default 3)\n"
                << "  -h, --help                  show this message\n";
        }

        static CliOptions parse(int argc, char* argv[], const char* role) {
            CliOptions o;
            for (int i = 1; i < argc; ++i) {
                const std::string a = argv[i];
                auto need = [&]() -> std::string {
                    if (i + 1 >= argc) {
                        std::cerr << "Missing value for " << a << "\n";
                        std::exit(2);
                    }
                    return argv[++i];
                    };

                if (a == "--ci") {
                    o.ci = true;
                }
                else if (a == "--duration") {
                    o.duration_sec = std::atoi(need().c_str());
                }
                else if (a == "--shutdown-after") {
                    o.shutdown_after_sec = std::atoi(need().c_str());
                }
                else if (a == "--threads") {
                    o.threads = std::atoi(need().c_str());
                }
                else if (a == "--notify-per-loop") {
                    o.notify_per_loop = std::atoi(need().c_str());
                }
                else if (a == "--call-per-loop") {
                    o.call_per_loop = std::atoi(need().c_str());
                }
                else if (a == "--pause") {
                    o.pause_ms = std::atoi(need().c_str());
                }
                else if (a == "--interval") {
                    o.interval_ms = std::atoi(need().c_str());
                }
                else if (a == "--stale-timeout") {
                    o.stale_timeout_ms = std::atoi(need().c_str());
                }
                else if (a == "--min-success-pct") {
                    o.min_success_pct = std::atof(need().c_str());
                }
                else if (a == "--min-total-calls") {
                    o.min_total_calls = std::strtoull(need().c_str(), nullptr, 10);
                }
                else if (a == "--warmup") {
                    o.warmup_sec = std::atoi(need().c_str());
                }
                else if (a == "-h" || a == "--help") {
                    print_usage(argv[0], role);
                    std::exit(0);
                }
                else {
                    std::cerr << "Unknown argument: " << a << "\n";
                    print_usage(argv[0], role);
                    std::exit(2);
                }
            }
            if (o.threads < 1)              o.threads = 1;
            if (o.notify_per_loop < 0)      o.notify_per_loop = 0;
            if (o.call_per_loop < 0)        o.call_per_loop = 0;
            if (o.notify_per_loop == 0 && o.call_per_loop == 0) {
                std::cerr << "At least one of --notify-per-loop / --call-per-loop "
                    "must be > 0.\n";
                std::exit(2);
            }
            if (o.interval_ms < 100)        o.interval_ms = 100;
            if (o.stale_timeout_ms < 1000)  o.stale_timeout_ms = 1000;
            if (o.duration_sec < 0)         o.duration_sec = 0;
            if (o.shutdown_after_sec < 0)   o.shutdown_after_sec = 0;
            return o;
        }
    };

    // -------------------------------------------------------------------------
    //  CI pass/fail verdict
    // -------------------------------------------------------------------------
    //  Two distinct run shapes are supported:
    //
    //  (A) Call-dominant or mixed (total_calls > 0)
    //        The usual thresholds apply. success_pct is the fraction of
    //        Calls whose response matched the expected value.
    //
    //  (B) Pure Notify (total_calls == 0)
    //        There are no Calls to succeed or fail; success_pct is
    //        meaningless (it would be 0/0). The relevant quantity is
    //        whether any Notify was actually dispatched. Require at
    //        least one to consider the run PASS.
    //
    //  This distinction matters because a pure-Notify scenario that
    //  sustains a high throughput would otherwise be marked FAIL by the
    //  success_pct check. See the harness script for why pure-Notify is
    //  a valid and useful scenario.
    // -------------------------------------------------------------------------
    inline bool ci_verdict_pass(
        std::uint64_t total_calls,
        std::uint64_t total_notifies,
        double        success_pct,
        const CliOptions& opt)
    {
        // Pure-Notify run: the success_pct gate does not apply.
        if (total_calls == 0) {
            return total_notifies > 0;
        }

        // Call-dominant or mixed run: apply the normal thresholds.
        if (opt.min_total_calls > 0 && total_calls < opt.min_total_calls) {
            return false;
        }
        if (success_pct < opt.min_success_pct) {
            return false;
        }
        return true;
    }

} // namespace stress