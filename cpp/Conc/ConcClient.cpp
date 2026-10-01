// =============================================================================
//  ConcClient.cpp
// -----------------------------------------------------------------------------
//  Client side of the concurrent-notify demo and CI harness.
//
//  Interactive mode (default):
//      Runs batches until Ctrl+C or Enter. Prints a human-readable line per
//      batch plus a periodic progress report.
//
//  CI mode (--ci):
//      Runs a bounded set of batches (by --batches N and/or --duration N),
//      prints one JSON line per batch, then a summary line. Exits with 0
//      when the CI verdict is PASS, 1 otherwise, 2 on CLI error.
//
//  Batch loop:
//      Phase 1  dispatch batch_size notify messages across send_threads
//               concurrent workers. Each worker records the local duration
//               of every LF_Notify call into a private LatencySamples
//               collector.
//      Phase 2  issue one wait_complete Call whose argument is the
//               CUMULATIVE number of notify messages sent so far.
//      Phase 3  evaluate the batch against the assertion set in
//               ConcCommon.hpp :: evaluate(), then record the result.
//
//  Cleanup order (Pascal LF-CLEAN-001):
//      LF_ExitMainThread  ->  LF_Shutdown  ->  LF_FreeLibrary
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
#include <iomanip>
#include <iostream>
#include <mutex>
#include <sstream>
#include <string>
#include <thread>
#include <tuple>
#include <utility>
#include <vector>

#if defined(_WIN32)
#  define WIN32_LEAN_AND_MEAN
#  include <windows.h>
#else
#  include <csignal>
#endif

namespace {

    // ---------------------------------------------------------------------
    //  Global state
    // ---------------------------------------------------------------------
    std::atomic<bool>          g_stop_flag{ false };
    std::atomic<std::uint64_t> g_total_sent{ 0 };
    std::atomic<std::uint64_t> g_total_errors{ 0 };

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

    // ---------------------------------------------------------------------
    //  Sender worker
    // ---------------------------------------------------------------------
    void send_slice(std::uint64_t start_seq,
        std::uint64_t count,
        std::atomic<std::uint64_t>& sent,
        std::atomic<std::uint64_t>& errors,
        conc::LatencySamples& lat) {
        lat.reserve(static_cast<std::size_t>(count));
        for (std::uint64_t i = 0; i < count; ++i) {
            if (g_stop_flag.load(std::memory_order_relaxed)) return;

            try {
                lingofuse::DataHandle p(conc::kTickApi);
                p.write(start_seq + i);

                const auto t0 = std::chrono::steady_clock::now();
                lingofuse::notify(conc::kServiceApp, p);
                const auto t1 = std::chrono::steady_clock::now();

                const auto us = std::chrono::duration_cast<
                    std::chrono::microseconds>(t1 - t0).count();

                lat.record_us(static_cast<std::uint64_t>(us));
                sent.fetch_add(1, std::memory_order_relaxed);
            }
            catch (...) {
                errors.fetch_add(1, std::memory_order_relaxed);
            }
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

    // ---------------------------------------------------------------------
    //  Formatting helpers
    // ---------------------------------------------------------------------
    std::string pad_right(const std::string& s, std::size_t w) {
        if (s.size() >= w) return s;
        return s + std::string(w - s.size(), ' ');
    }
    std::string pad_left(const std::string& s, std::size_t w) {
        if (s.size() >= w) return s;
        return std::string(w - s.size(), ' ') + s;
    }

    std::string rule(char c, std::size_t w = 78) {
        return std::string(w, c);
    }

    std::string format_thousands(std::uint64_t v) {
        std::string s = std::to_string(v);
        std::string out;
        out.reserve(s.size() + s.size() / 3);
        int count = 0;
        for (auto it = s.rbegin(); it != s.rend(); ++it) {
            if (count == 3) { out.push_back(','); count = 0; }
            out.push_back(*it);
            ++count;
        }
        std::reverse(out.begin(), out.end());
        return out;
    }

    // ---------------------------------------------------------------------
    //  Final CI report (human-readable block)
    // ---------------------------------------------------------------------
    void print_ci_report(
        const conc::CliOptions& opt,
        const std::vector<conc::BatchResult>& batches,
        const conc::LatencySamples& global_lat,
        double elapsed_sec,
        std::uint64_t total_sent,
        std::uint64_t total_errors,
        const conc::CiVerdict& verdict)
    {
        int passed = 0;
        for (const auto& b : batches) if (b.pass) ++passed;
        const int failed = static_cast<int>(batches.size()) - passed;

        long long send_min = 0, send_max = 0, send_sum = 0;
        long long call_min = 0, call_max = 0, call_sum = 0;
        for (const auto& b : batches) {
            if (send_min == 0 || b.send_ms < send_min) send_min = b.send_ms;
            if (b.send_ms > send_max) send_max = b.send_ms;
            send_sum += b.send_ms;
            if (call_min == 0 || b.call_ms < call_min) call_min = b.call_ms;
            if (b.call_ms > call_max) call_max = b.call_ms;
            call_sum += b.call_ms;
        }
        const auto n = static_cast<long long>(batches.size());
        const long long send_avg = (n > 0) ? send_sum / n : 0;
        const long long call_avg = (n > 0) ? call_sum / n : 0;

        auto [lmin, lp50, lp95, lp99, lmax, lmean] = global_lat.stats_us();

        const double avg_rate = (elapsed_sec > 0.0)
            ? static_cast<double>(total_sent) / elapsed_sec
            : 0.0;

        std::ostringstream out;
        out << "\n" << rule('=') << "\n";
        out << "  CONCURRENT NOTIFY -- CI REPORT\n";
        out << rule('=') << "\n";
        out << "  Config\n";
        out << "    Batches ............ : " << batches.size();
        if (opt.batch_count > 0) out << " / " << opt.batch_count;
        out << "\n";
        out << "    Batch size ......... : " << opt.batch_size << "\n";
        out << "    Send threads ....... : " << opt.send_threads << "\n";
        out << "    Call timeout ....... : " << opt.call_timeout_ms << " ms\n";
        out << "    Elapsed ............ : " << std::fixed
            << std::setprecision(2) << elapsed_sec << " s\n";
        out << "\n";
        out << "  Result\n";
        out << "    Total sent ......... : " << format_thousands(total_sent) << "\n";
        out << "    Total errors ....... : " << total_errors << "\n";
        out << "    Average rate ....... : "
            << format_thousands(static_cast<std::uint64_t>(avg_rate + 0.5))
            << " notify/s\n";
        out << "    Batches passed ..... : " << passed
            << " / " << batches.size() << "\n";
        out << "    Batches failed ..... : " << failed
            << " / " << batches.size() << "\n";
        out << "\n";
        out << "  Local notify latency (microseconds, caller side)\n";
        out << "    min ................ : " << lmin << "\n";
        out << "    p50 ................ : " << lp50 << "\n";
        out << "    p95 ................ : " << lp95 << "\n";
        out << "    p99 ................ : " << lp99 << "\n";
        out << "    max ................ : " << lmax << "\n";
        out << "    mean ............... : " << lmean << "\n";
        out << "\n";
        out << "  Per-batch timings (ms)\n";
        out << "    send  min/avg/max .. : " << send_min << " / "
            << send_avg << " / " << send_max << "\n";
        out << "    call  min/avg/max .. : " << call_min << " / "
            << call_avg << " / " << call_max << "\n";
        out << "\n";
        out << "  Per-batch results\n";
        out << "    " << pad_left("batch", 6)
            << " " << pad_right("status", 8)
            << pad_left("sent", 8)
            << pad_left("exp", 8)
            << pad_left("svc", 10)
            << pad_left("send_ms", 10)
            << pad_left("call_ms", 10)
            << pad_left("p95_us", 10)
            << "\n";
        out << "    " << rule('-', 78) << "\n";
        for (const auto& b : batches) {
            out << "    " << pad_left(std::to_string(b.batch_index), 6)
                << " " << pad_right(b.pass ? "PASS" : "FAIL", 8)
                << pad_left(std::to_string(b.sent), 8)
                << pad_left(std::to_string(b.expected_sent), 8)
                << pad_left(std::to_string(b.svc_count), 10)
                << pad_left(std::to_string(b.send_ms), 10)
                << pad_left(std::to_string(b.call_ms), 10)
                << pad_left(std::to_string(b.lat_p95_us), 10);
            if (!b.pass) out << "   (" << b.fail_reason << ")";
            out << "\n";
        }
        out << "    " << rule('-', 78) << "\n";
        out << "\n";

        if (verdict.pass) {
            out << "  " << rule('*', 78) << "\n";
            out << "  *  RESULT: PASS"
                << std::string(78 - 4 - 13, ' ') << "*\n";
            out << "  " << rule('*', 78) << "\n";
        }
        else {
            std::ostringstream msg;
            msg << "  *  RESULT: FAIL  (" << verdict.reason << ")";
            out << "  " << rule('*', 78) << "\n";
            out << msg.str()
                << std::string(
                    (msg.str().size() < 78) ? (78 - msg.str().size()) : 0,
                    ' ')
                << "*\n";
            out << "  " << rule('*', 78) << "\n";
        }
        out << rule('=') << "\n";

        log_line(out.str());
    }

    // ---------------------------------------------------------------------
    //  Final CI summary (machine-readable single JSON line)
    // ---------------------------------------------------------------------
    void print_ci_summary_json(
        const conc::CliOptions& opt,
        const std::vector<conc::BatchResult>& batches,
        const conc::LatencySamples& global_lat,
        double elapsed_sec,
        std::uint64_t total_sent,
        std::uint64_t total_errors,
        const conc::CiVerdict& verdict)
    {
        int passed = 0;
        for (const auto& b : batches) if (b.pass) ++passed;
        const int failed = static_cast<int>(batches.size()) - passed;

        auto [lmin, lp50, lp95, lp99, lmax, lmean] = global_lat.stats_us();
        const double avg_rate = (elapsed_sec > 0.0)
            ? static_cast<double>(total_sent) / elapsed_sec
            : 0.0;

        std::ostringstream oss;
        oss << "{\"event\":\"summary\""
            << ",\"role\":\"client\""
            << ",\"elapsed_sec\":" << std::fixed << std::setprecision(3)
            << elapsed_sec
            << ",\"batch_count\":" << batches.size()
            << ",\"batches_passed\":" << passed
            << ",\"batches_failed\":" << failed
            << ",\"batch_size\":" << opt.batch_size
            << ",\"send_threads\":" << opt.send_threads
            << ",\"total_sent\":" << total_sent
            << ",\"total_errors\":" << total_errors
            << ",\"avg_rate\":" << static_cast<std::uint64_t>(avg_rate + 0.5)
            << ",\"lat_p50_us\":" << lp50
            << ",\"lat_p95_us\":" << lp95
            << ",\"lat_p99_us\":" << lp99
            << ",\"status\":\"" << (verdict.pass ? "PASS" : "FAIL") << "\"";
        if (!verdict.pass) {
            oss << ",\"reason\":\"" << conc::json_escape(verdict.reason) << "\"";
        }
        oss << "}";

        log_line(oss.str());
    }

} // namespace

/* ============================================================================
 *  main
 * ============================================================================ */

int main(int argc, char* argv[]) {
    const conc::CliOptions opt = conc::CliOptions::parse(argc, argv);

    if (!opt.ci_mode) {
        std::cout << "=== Concurrent Notify Client ===" << std::endl;
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

        lingofuse::setOption("Wait_Ready", "False");
        if (opt.ci_mode) {
            lingofuse::setOption("Quiet", "True");
        }
        lingofuse::resetPrepare();

        const int tag = lingofuse::prepareClient(conc::kEndpoint, nullptr);
        if (tag < 0) {
            std::cerr << "[FATAL] LF_PrepareClient failed for "
                << conc::kEndpoint << "." << std::endl;
            return EXIT_FAILURE;
        }

        if (lingofuse::prepareDone() != 1) {
            std::cerr << "[FATAL] LF_PrepareDone failed." << std::endl;
            return EXIT_FAILURE;
        }

        // -------------------------------------------------------------
        //  Wait for the service to appear on the mesh
        // -------------------------------------------------------------
        if (!opt.ci_mode) {
            log_line("[Client] Waiting for service '",
                conc::kServiceApp, "'...");
        }
        bool ready = false;
        for (int i = 0; i < 50 && !g_stop_flag.load(); ++i) {
            if (lingofuse::checkApi(conc::kServiceApp, conc::kTickApi) &&
                lingofuse::checkApi(conc::kServiceApp, conc::kWaitApi)) {
                ready = true;
                break;
            }
            std::this_thread::sleep_for(std::chrono::milliseconds(200));
        }
        if (!ready) {
            std::cerr << "[FATAL] Service '" << conc::kServiceApp
                << "' not visible after 10 seconds." << std::endl;
            lingofuse::exitMainThread();
            return EXIT_FAILURE;
        }

        // ---- CI ready event -----------------------------------------
        if (opt.ci_mode) {
            std::ostringstream oss;
            oss << "{\"event\":\"client_ready\""
                << ",\"batch_size\":" << opt.batch_size
                << ",\"send_threads\":" << opt.send_threads
                << ",\"batch_count\":" << opt.batch_count
                << ",\"duration_sec\":" << opt.duration_sec
                << ",\"min_batches\":" << opt.min_batches
                << ",\"min_total_sent\":" << opt.min_total_sent
                << ",\"min_avg_rate\":" << opt.min_avg_rate
                << "}";
            log_line(oss.str());
        }
        else {
            log_line("[Client] Service ready.  Batch=", opt.batch_size,
                "  SendThreads=", opt.send_threads,
                "  CallTimeout=", opt.call_timeout_ms, "ms");
            log_line("[Client] Press Ctrl+C or Enter to stop.");
        }

        // -------------------------------------------------------------
        //  Input thread: stop on Enter (interactive only)
        // -------------------------------------------------------------
        if (!opt.ci_mode) {
            std::thread([]() {
                std::string line;
                if (std::getline(std::cin, line)) {
                    g_stop_flag.store(true);
                }
                }).detach();
        }

        // -------------------------------------------------------------
        //  Batch loop
        // -------------------------------------------------------------
        std::vector<conc::BatchResult> results;
        conc::LatencySamples global_lat;
        std::uint64_t batch_index = 0;

        const std::uint64_t per_thread = opt.batch_size /
            static_cast<std::uint64_t>(opt.send_threads);
        const std::uint64_t last_slice = opt.batch_size -
            per_thread * static_cast<std::uint64_t>(opt.send_threads - 1);

        while (!g_stop_flag.load(std::memory_order_relaxed)) {

            // ---- Time-boxed exit (CI mode) --------------------------
            if (opt.duration_sec > 0) {
                const auto elapsed_s =
                    std::chrono::duration_cast<std::chrono::seconds>(
                        std::chrono::steady_clock::now() - start_steady)
                    .count();
                if (elapsed_s >= opt.duration_sec) break;
            }

            // ---- Batch-count exit -----------------------------------
            if (opt.batch_count > 0 &&
                batch_index >= static_cast<std::uint64_t>(opt.batch_count)) {
                break;
            }

            ++batch_index;
            const std::uint64_t start_seq =
                (batch_index - 1) * opt.batch_size;

            // ---------------------------------------------------------
            //  Phase 1: dispatch the batch across concurrent workers
            // ---------------------------------------------------------
            std::atomic<std::uint64_t> batch_sent{ 0 };
            std::atomic<std::uint64_t> batch_errors{ 0 };

            std::vector<conc::LatencySamples> per_thread_lat(
                static_cast<std::size_t>(opt.send_threads));
            std::vector<std::thread> senders;
            senders.reserve(static_cast<std::size_t>(opt.send_threads));

            const auto send_start = std::chrono::steady_clock::now();

            for (int t = 0; t < opt.send_threads; ++t) {
                const std::uint64_t slice =
                    (t == opt.send_threads - 1) ? last_slice : per_thread;
                const std::uint64_t my_start =
                    start_seq + static_cast<std::uint64_t>(t) * per_thread;

                senders.emplace_back(
                    send_slice,
                    my_start,
                    slice,
                    std::ref(batch_sent),
                    std::ref(batch_errors),
                    std::ref(per_thread_lat[static_cast<std::size_t>(t)]));
            }
            for (auto& th : senders) {
                if (th.joinable()) th.join();
            }

            const auto send_ms = std::chrono::duration_cast<
                std::chrono::milliseconds>(
                    std::chrono::steady_clock::now() - send_start).count();

            conc::LatencySamples batch_lat;
            for (auto& l : per_thread_lat) {
                batch_lat.merge_from(l);
                global_lat.merge_from(l);
            }

            g_total_sent.fetch_add(batch_sent.load(), std::memory_order_relaxed);
            g_total_errors.fetch_add(batch_errors.load(), std::memory_order_relaxed);

            if (g_stop_flag.load(std::memory_order_relaxed)) break;

            // ---------------------------------------------------------
            //  Phase 2: completion barrier via a single wait_complete Call
            // ---------------------------------------------------------
            const std::uint64_t target =
                g_total_sent.load(std::memory_order_relaxed);

            lingofuse::DataHandle req(conc::kWaitApi);
            req.write(target);

            const auto call_start = std::chrono::steady_clock::now();
            auto resp = lingofuse::tryCall(
                conc::kServiceApp, req, opt.call_timeout_ms);
            const auto call_ms = std::chrono::duration_cast<
                std::chrono::milliseconds>(
                    std::chrono::steady_clock::now() - call_start).count();

            // ---------------------------------------------------------
            //  Phase 3: build the batch result, evaluate, report
            // ---------------------------------------------------------
            conc::BatchResult r;
            r.batch_index = batch_index;
            r.sent = batch_sent.load();
            r.expected_sent = opt.batch_size;
            r.target = target;
            r.errors = batch_errors.load();
            r.send_ms = send_ms;
            r.call_ms = call_ms;
            r.resp_ok = resp.has_value();

            if (r.resp_ok) {
                std::uint64_t svc_count = 0;
                std::int32_t  complete = 0;
                std::uint64_t wait_ms = 0;
                const bool parsed =
                    resp->read(svc_count) &&
                    resp->read(complete) &&
                    resp->read(wait_ms);
                if (parsed) {
                    r.svc_count = svc_count;
                    r.wait_ms = wait_ms;
                }
                else {
                    r.resp_ok = false;
                }
            }

            std::tie(r.lat_min_us, r.lat_p50_us, r.lat_p95_us,
                r.lat_p99_us, r.lat_max_us, r.lat_mean_us) =
                batch_lat.stats_us();

            conc::evaluate(r);
            results.push_back(r);

            if (opt.ci_mode) {
                log_line(r.to_json_line());
            }
            else {
                log_line("[Batch ", batch_index, "] ",
                    "send_ms=", send_ms,
                    "  call_ms=", call_ms,
                    "  sent=", r.sent,
                    "  target=", r.target,
                    "  svc_count=", r.svc_count,
                    "  wait_ms=", r.wait_ms,
                    "  errors=", r.errors,
                    "  p95_us=", r.lat_p95_us,
                    "  status=", (r.pass ? "OK" : "FAIL"));
            }

            if (opt.batch_pause_ms > 0 &&
                !g_stop_flag.load(std::memory_order_relaxed)) {
                std::this_thread::sleep_for(
                    std::chrono::milliseconds(opt.batch_pause_ms));
            }
        }

        // -------------------------------------------------------------
        //  Final report
        // -------------------------------------------------------------
        const auto end_steady = std::chrono::steady_clock::now();
        const double elapsed_sec =
            std::chrono::duration<double>(end_steady - start_steady).count();

        const std::uint64_t total_sent =
            g_total_sent.load(std::memory_order_relaxed);
        const std::uint64_t total_errors =
            g_total_errors.load(std::memory_order_relaxed);

        const conc::CiVerdict verdict =
            conc::ci_verdict(results, total_sent, elapsed_sec, opt);

        if (opt.ci_mode) {
            print_ci_summary_json(opt, results, global_lat,
                elapsed_sec, total_sent, total_errors,
                verdict);
            print_ci_report(opt, results, global_lat,
                elapsed_sec, total_sent, total_errors,
                verdict);
        }
        else {
            log_line("[Client] ===== Final summary =====");
            log_line("  total_sent   = ", total_sent);
            log_line("  total_errors = ", total_errors);
            log_line("  batches      = ", results.size());
            log_line("  elapsed      = ", elapsed_sec, " s");
        }

        lingofuse::exitMainThread();

        // ---- Exit code contract -------------------------------------
        if (opt.ci_mode) {
            return verdict.pass ? EXIT_SUCCESS : EXIT_FAILURE;
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

    if (!opt.ci_mode) {
        std::cout << "[Client] Bye." << std::endl;
    }
    return EXIT_SUCCESS;
}