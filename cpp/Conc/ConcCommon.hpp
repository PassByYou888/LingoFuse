// =============================================================================
//  ConcCommon.hpp
// -----------------------------------------------------------------------------
//  Shared definitions for the LingoFuse concurrent-notify demo and CI harness.
//
//  =============================================================================
//  DEMO CONCEPT
//  =============================================================================
//
//      Client (N threads)                       Service
//      ------------------                       -------
//      send 10000 x notify("tick")   ------>    tick handler: counter++
//      then 1 x call("wait_complete", 10000)    wait handler: spin until
//                                                  counter >= 10000
//                                                  (or timeout), then return
//
//  Because Notify is fire-and-forget, the client cannot know when the
//  service has processed all 10000 messages without an explicit barrier.
//  The wait_complete Call provides that barrier: the service callback
//  blocks until its own tick counter reaches the target, guaranteeing
//  every notify has been observed.
//
//  This is safe from deadlock because C4 dispatches Notify callbacks on
//  the HPC background worker pool and Call callbacks on the simulated
//  main thread. Blocking the main thread inside wait_complete does NOT
//  stall the HPC workers draining the incoming notify backlog.
//
//  =============================================================================
//  TWO DISTINCT COUNTS (IMPORTANT FOR CI ASSERTIONS)
//  =============================================================================
//
//  Per batch, there are TWO different quantities that must not be confused:
//
//      sent          -- how many notify messages this batch actually
//                       dispatched locally. Its expected value is
//                       batch_size (a per-batch quantity).
//
//      target        -- the CUMULATIVE count handed to wait_complete.
//                       Its expected value is batch_size * batch_index.
//
//  The service's svc_count is also cumulative, so it is compared against
//  target, not against sent. Conflating these two was the original bug
//  that made every batch after the first report FAIL.
//
//  =============================================================================
//  CI MODE
//  =============================================================================
//
//  When --ci is passed, both sides switch to machine-readable output:
//
//      - Client : one JSON line per batch to stdout, then a summary line
//      - Service: periodic reports are suppressed; wait_complete events
//                 and a service_ready event are emitted as JSON
//
//  The client exits with 0 when every batch PASSes AND the CI verdict
//  thresholds are satisfied, 1 otherwise, 2 on CLI error.
//
//  Thresholds that can be set from the command line:
//
//      --min-batches N         minimum number of batches to complete
//      --min-total-sent N      minimum cumulative notify messages sent
//      --min-avg-rate F        minimum average notify rate (per second)
//
//  These thresholds are opt-in. When they are left at 0, only the
//  per-batch assertions apply.
// =============================================================================

#pragma once

#include "LingoFuse.hpp"

#include <algorithm>
#include <chrono>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <iostream>
#include <sstream>
#include <string>
#include <tuple>
#include <vector>

namespace conc {

    // ---------------------------------------------------------------------
    //  Well-known names (must match on both sides)
    // ---------------------------------------------------------------------
    inline constexpr const char* kEndpoint = "ipc:conc";
    inline constexpr const char* kServiceApp = "ConcSvc";
    inline constexpr const char* kTickApi = "tick";
    inline constexpr const char* kWaitApi = "wait_complete";

    // ---------------------------------------------------------------------
    //  Defaults
    // ---------------------------------------------------------------------
    inline constexpr std::uint64_t kDefaultBatchSize = 10000;
    inline constexpr int           kDefaultSendThreads = 8;
    inline constexpr int           kDefaultBatchPauseMs = 50;
    inline constexpr std::uint64_t kDefaultCallTimeoutMs = 60000;
    inline constexpr int           kDefaultWaitTimeoutMs = 30000;
    inline constexpr int           kDefaultCiBatches = 10;

    // ---------------------------------------------------------------------
    //  Portability helper
    // ---------------------------------------------------------------------
    inline std::uint64_t now_ms() {
        return static_cast<std::uint64_t>(
            std::chrono::duration_cast<std::chrono::milliseconds>(
                std::chrono::steady_clock::now().time_since_epoch())
            .count());
    }

    // ---------------------------------------------------------------------
    //  Command-line options
    // ---------------------------------------------------------------------
    struct CliOptions {
        bool          ci_mode = false;
        int           batch_count = 0;   // 0 = unbounded
        std::uint64_t batch_size = kDefaultBatchSize;
        int           send_threads = kDefaultSendThreads;
        int           batch_pause_ms = kDefaultBatchPauseMs;
        std::uint64_t call_timeout_ms = kDefaultCallTimeoutMs;
        int           wait_timeout_ms = kDefaultWaitTimeoutMs;

        // ---- Lifecycle (CI) ------------------------------------------
        //  duration_sec        : client auto-exits after N seconds
        //  shutdown_after_sec  : service auto-exits after N seconds
        int           duration_sec = 0;
        int           shutdown_after_sec = 0;

        // ---- CI verdict thresholds -----------------------------------
        int           min_batches = 0;
        std::uint64_t min_total_sent = 0;
        double        min_avg_rate = 0.0;

        static void print_usage(const char* prog) {
            std::cerr
                << "Usage: " << prog << " [options]\n"
                << "\n"
                << "Run shapes\n"
                << "  --ci                JSON Lines output; auto-exit; 0/1/2 exit code\n"
                << "  --batches N         number of batches (0 = unbounded; default 10 in --ci)\n"
                << "  --duration N        stop after N seconds (0 = unbounded)\n"
                << "\n"
                << "Load shape\n"
                << "  --size N            notify messages per batch (default " << kDefaultBatchSize << ")\n"
                << "  --threads N         concurrent sender threads    (default " << kDefaultSendThreads << ")\n"
                << "  --pause N           pause between batches, ms    (default " << kDefaultBatchPauseMs << ")\n"
                << "\n"
                << "Timeouts\n"
                << "  --timeout N         client-side LF_Call timeout, ms (default " << kDefaultCallTimeoutMs << ")\n"
                << "  --wait-timeout N    service-side wait budget, ms    (default " << kDefaultWaitTimeoutMs << ")\n"
                << "\n"
                << "Service lifecycle\n"
                << "  --shutdown-after N  (service) auto-exit after N seconds\n"
                << "\n"
                << "CI verdict thresholds (opt-in; 0 disables the check)\n"
                << "  --min-batches N     require at least N completed batches\n"
                << "  --min-total-sent N  require at least N cumulative notify messages\n"
                << "  --min-avg-rate F    require average notify rate >= F per second\n"
                << "\n"
                << "  -h, --help          show this message\n"
                << "\n"
                << "Examples\n"
                << "  Interactive  : " << prog << "\n"
                << "  CI short     : " << prog << " --ci --batches 20 --size 1000 --threads 8\n"
                << "  CI time-box  : " << prog << " --ci --duration 30 --size 10000 --threads 8\n";
        }

        static CliOptions parse(int argc, char* argv[]) {
            CliOptions o;
            for (int i = 1; i < argc; ++i) {
                const std::string a = argv[i];
                auto need = [&](const char* name) -> std::string {
                    if (i + 1 >= argc) {
                        std::cerr << "Missing value for " << name << "\n";
                        std::exit(2);
                    }
                    return argv[++i];
                    };
                if (a == "--ci")                 o.ci_mode = true;
                else if (a == "--batches")       o.batch_count = std::atoi(need("--batches").c_str());
                else if (a == "--duration")      o.duration_sec = std::atoi(need("--duration").c_str());
                else if (a == "--size")          o.batch_size = std::strtoull(need("--size").c_str(), nullptr, 10);
                else if (a == "--threads")       o.send_threads = std::atoi(need("--threads").c_str());
                else if (a == "--pause")         o.batch_pause_ms = std::atoi(need("--pause").c_str());
                else if (a == "--timeout")       o.call_timeout_ms = std::strtoull(need("--timeout").c_str(), nullptr, 10);
                else if (a == "--wait-timeout")  o.wait_timeout_ms = std::atoi(need("--wait-timeout").c_str());
                else if (a == "--shutdown-after")o.shutdown_after_sec = std::atoi(need("--shutdown-after").c_str());
                else if (a == "--min-batches")   o.min_batches = std::atoi(need("--min-batches").c_str());
                else if (a == "--min-total-sent")o.min_total_sent = std::strtoull(need("--min-total-sent").c_str(), nullptr, 10);
                else if (a == "--min-avg-rate")  o.min_avg_rate = std::atof(need("--min-avg-rate").c_str());
                else if (a == "-h" || a == "--help") {
                    print_usage(argv[0]);
                    std::exit(0);
                }
                else {
                    std::cerr << "Unknown argument: " << a << "\n";
                    print_usage(argv[0]);
                    std::exit(2);
                }
            }
            // In CI mode, if neither batch_count nor duration is set,
            // default to a fixed number of batches.
            if (o.ci_mode && o.batch_count <= 0 && o.duration_sec <= 0) {
                o.batch_count = kDefaultCiBatches;
            }
            if (o.send_threads < 1) o.send_threads = 1;
            if (o.batch_size < 1)   o.batch_size = 1;
            return o;
        }
    };

    // ---------------------------------------------------------------------
    //  JSON string escape (minimal, sufficient for our ASCII-only output)
    // ---------------------------------------------------------------------
    inline std::string json_escape(const std::string& s) {
        std::string out;
        out.reserve(s.size() + 8);
        for (char c : s) {
            switch (c) {
            case '"':  out += "\\\""; break;
            case '\\': out += "\\\\"; break;
            case '\n': out += "\\n";  break;
            case '\r': out += "\\r";  break;
            case '\t': out += "\\t";  break;
            default:
                if (static_cast<unsigned char>(c) < 0x20) {
                    char buf[8];
                    std::snprintf(buf, sizeof(buf), "\\u%04x",
                        static_cast<unsigned>(c));
                    out += buf;
                }
                else {
                    out += c;
                }
            }
        }
        return out;
    }

    // ---------------------------------------------------------------------
    //  Latency sample collector (unchanged)
    // ---------------------------------------------------------------------
    class LatencySamples {
    public:
        void reserve(std::size_t n) { v_.reserve(n); }

        void record_us(std::uint64_t us) { v_.push_back(us); }

        void merge_from(const LatencySamples& other) {
            v_.insert(v_.end(), other.v_.begin(), other.v_.end());
        }

        std::size_t size() const noexcept { return v_.size(); }

        std::tuple<std::uint64_t, std::uint64_t, std::uint64_t,
            std::uint64_t, std::uint64_t, std::uint64_t>
            stats_us() const {
            if (v_.empty()) return { 0, 0, 0, 0, 0, 0 };
            auto sorted = v_;
            std::sort(sorted.begin(), sorted.end());
            auto pct = [&](double p) -> std::uint64_t {
                const double idx = p * static_cast<double>(sorted.size() - 1);
                return sorted[static_cast<std::size_t>(idx + 0.5)];
                };
            std::uint64_t sum = 0;
            for (auto x : sorted) sum += x;
            return {
                sorted.front(),
                pct(0.50),
                pct(0.95),
                pct(0.99),
                sorted.back(),
                sum / static_cast<std::uint64_t>(sorted.size())
            };
        }

    private:
        std::vector<std::uint64_t> v_;
    };

    // ---------------------------------------------------------------------
    //  Per-batch result (unchanged)
    // ---------------------------------------------------------------------
    struct BatchResult {
        std::uint64_t batch_index = 0;
        std::uint64_t sent = 0;
        std::uint64_t expected_sent = 0;
        std::uint64_t target = 0;
        std::uint64_t svc_count = 0;
        std::uint64_t wait_ms = 0;
        std::uint64_t errors = 0;
        long long     send_ms = 0;
        long long     call_ms = 0;
        bool          resp_ok = false;
        bool          pass = false;
        std::string   fail_reason;

        std::uint64_t lat_min_us = 0;
        std::uint64_t lat_p50_us = 0;
        std::uint64_t lat_p95_us = 0;
        std::uint64_t lat_p99_us = 0;
        std::uint64_t lat_max_us = 0;
        std::uint64_t lat_mean_us = 0;

        std::string to_json_line() const {
            std::ostringstream oss;
            oss << "{\"event\":\"batch\""
                << ",\"index\":" << batch_index
                << ",\"send_ms\":" << send_ms
                << ",\"call_ms\":" << call_ms
                << ",\"sent\":" << sent
                << ",\"expected_sent\":" << expected_sent
                << ",\"target\":" << target
                << ",\"svc_count\":" << svc_count
                << ",\"wait_ms\":" << wait_ms
                << ",\"errors\":" << errors
                << ",\"resp_ok\":" << (resp_ok ? "true" : "false")
                << ",\"lat_p50_us\":" << lat_p50_us
                << ",\"lat_p95_us\":" << lat_p95_us
                << ",\"lat_p99_us\":" << lat_p99_us
                << ",\"status\":\"" << (pass ? "PASS" : "FAIL") << "\"";
            if (!pass && !fail_reason.empty()) {
                oss << ",\"reason\":\"" << json_escape(fail_reason) << "\"";
            }
            oss << "}";
            return oss.str();
        }
    };

    // ---------------------------------------------------------------------
    //  Per-batch evaluator (unchanged)
    // ---------------------------------------------------------------------
    inline void evaluate(BatchResult& r) {
        if (!r.resp_ok) {
            r.pass = false;
            r.fail_reason = "CALL_TIMEOUT";
        }
        else if (r.sent != r.expected_sent) {
            r.pass = false;
            r.fail_reason = "SEND_INCOMPLETE";
        }
        else if (r.errors != 0) {
            r.pass = false;
            r.fail_reason = "SEND_ERRORS";
        }
        else if (r.svc_count < r.target) {
            r.pass = false;
            r.fail_reason = "COUNT_MISMATCH";
        }
        else {
            r.pass = true;
            r.fail_reason.clear();
        }
    }

    // ---------------------------------------------------------------------
    //  CI verdict
    // ---------------------------------------------------------------------
    //  Combines per-batch results with the optional threshold checks.
    //  The result is a single PASS/FAIL with an optional reason string.
    // ---------------------------------------------------------------------
    struct CiVerdict {
        bool        pass = false;
        std::string reason;
    };

    inline CiVerdict ci_verdict(
        const std::vector<BatchResult>& batches,
        std::uint64_t total_sent,
        double        elapsed_sec,
        const CliOptions& opt)
    {
        CiVerdict v;

        // 1. Any batch failure is an immediate FAIL.
        for (const auto& b : batches) {
            if (!b.pass) {
                v.pass = false;
                std::ostringstream oss;
                oss << "BATCH_" << b.batch_index << "_" << b.fail_reason;
                v.reason = oss.str();
                return v;
            }
        }

        // 2. Minimum batch count.
        if (opt.min_batches > 0 &&
            static_cast<int>(batches.size()) < opt.min_batches) {
            v.pass = false;
            v.reason = "BATCHES_BELOW_MINIMUM";
            return v;
        }

        // 3. Minimum cumulative notify count.
        if (opt.min_total_sent > 0 && total_sent < opt.min_total_sent) {
            v.pass = false;
            v.reason = "TOTAL_SENT_BELOW_MINIMUM";
            return v;
        }

        // 4. Minimum average notify rate.
        if (opt.min_avg_rate > 0.0) {
            const double rate = (elapsed_sec > 0.0)
                ? static_cast<double>(total_sent) / elapsed_sec
                : 0.0;
            if (rate < opt.min_avg_rate) {
                v.pass = false;
                v.reason = "AVG_RATE_BELOW_MINIMUM";
                return v;
            }
        }

        v.pass = true;
        return v;
    }

} // namespace conc