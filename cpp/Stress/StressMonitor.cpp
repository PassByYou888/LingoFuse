// =============================================================================
//  StressMonitor.cpp
// -----------------------------------------------------------------------------
//  Fleet observer for the LingoFuse stress test.
//
//  It connects to ipc:stress as a client, publishes its App to the mesh, and
//  waits for status reports from any number of concurrently running
//  StressClient processes.
//
//  Once per second (configurable), the terminal is cleared and a single
//  fleet-wide aggregate report is drawn in place:
//
//      * client liveness (RUN / STOP / DEAD)
//      * total calls / success / failed
//      * calls per second (total, plus per-API breakdown)
//      * per-API cumulative call counts
//      * average and peak throughput
//      * deliberate handle leaks reported by the clients
//      * total RSS / handles / threads / CPU across all live clients
//
//  Set the environment variable STRESS_MONITOR_NO_CLEAR=1 to disable the
//  clear and let the reports accumulate (useful when piping to a log file).
//
//  Usage:
//      StressMonitor [interval_ms] [stale_timeout_ms]
//      Defaults: interval = 1000 ms, stale_timeout = 5000 ms
// =============================================================================

#include "LingoFuse.hpp"
#include "StressCommon.hpp"

#include <algorithm>
#include <chrono>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <ctime>
#include <iomanip>
#include <iostream>
#include <map>
#include <mutex>
#include <sstream>
#include <string>
#include <thread>
#include <vector>

#if defined(_WIN32)
#  define WIN32_LEAN_AND_MEAN
#  include <windows.h>
#  include <psapi.h>
#  include <tlhelp32.h>
#else
#  include <unistd.h>
#  include <dirent.h>
#  include <sys/types.h>
#endif

namespace {

    constexpr int kDefaultIntervalMs     = 1000;
    constexpr int kDefaultStaleTimeoutMs = 5000;

    std::atomic<bool> g_stop_flag{false};

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

    // -------------------------------------------------------------------------
    //  Terminal control
    // -------------------------------------------------------------------------
    bool g_use_clear_screen = true;

    void init_terminal() {
        if (const char* env = std::getenv("STRESS_MONITOR_NO_CLEAR")) {
            if (*env != '\0' && std::strcmp(env, "0") != 0) {
                g_use_clear_screen = false;
            }
        }

#if defined(_WIN32)
        HANDLE h = GetStdHandle(STD_OUTPUT_HANDLE);
        if (h != INVALID_HANDLE_VALUE) {
            DWORD mode = 0;
            if (GetConsoleMode(h, &mode)) {
                SetConsoleMode(
                    h, mode | 0x0004 /* ENABLE_VIRTUAL_TERMINAL_PROCESSING */);
            }
        }
#endif
    }

    void clear_screen() {
        if (!g_use_clear_screen) return;
        std::cout << "\x1b[2J\x1b[H";
    }

    // -------------------------------------------------------------------------
    //  Collected reports
    // -------------------------------------------------------------------------
    struct ReportEntry {
        stress::ClientReport report;
        std::uint64_t        last_seen_ms = 0;
    };

    std::mutex& reports_mutex() {
        static std::mutex m;
        return m;
    }

    std::map<std::uint32_t, ReportEntry>& reports() {
        static std::map<std::uint32_t, ReportEntry> r;
        return r;
    }

    void LF_CDECL api_report(void* /*trigger*/, void* input) {
        if (input == nullptr) return;

        lingofuse::DataHandle in(static_cast<TDataHnd>(input), false);
        stress::ClientReport r;
        if (!stress::read_report(in, r)) return;
        if (r.pid == 0) return;

        std::lock_guard<std::mutex> lock(reports_mutex());
        reports()[r.pid] = {r, stress::now_ms()};
    }

    // -------------------------------------------------------------------------
    //  Process metrics
    // -------------------------------------------------------------------------
    struct ProcessMetrics {
        std::uint64_t rss_kib        = 0;
        std::uint64_t handle_count   = 0;
        std::uint64_t thread_count   = 0;
        double        cpu_user_sec   = 0.0;
        double        cpu_system_sec = 0.0;
        bool          valid          = false;
    };

#if defined(_WIN32)

    ProcessMetrics sample_process_win(std::uint32_t pid) {
        ProcessMetrics m;
        if (pid == 0) return m;

        HANDLE h = OpenProcess(
            PROCESS_QUERY_INFORMATION | PROCESS_VM_READ,
            FALSE, static_cast<DWORD>(pid));
        if (!h) {
            h = OpenProcess(
                PROCESS_QUERY_LIMITED_INFORMATION,
                FALSE, static_cast<DWORD>(pid));
        }
        if (!h) return m;

        PROCESS_MEMORY_COUNTERS pmc{};
        if (GetProcessMemoryInfo(h, &pmc, sizeof(pmc))) {
            m.rss_kib = pmc.WorkingSetSize / 1024;
            m.valid = true;
        }

        DWORD hc = 0;
        if (GetProcessHandleCount(h, &hc)) {
            m.handle_count = hc;
        }

        FILETIME c{}, e{}, k{}, u{};
        if (GetProcessTimes(h, &c, &e, &k, &u)) {
            auto to_sec = [](const FILETIME& ft) -> double {
                ULARGE_INTEGER li;
                li.LowPart  = ft.dwLowDateTime;
                li.HighPart = ft.dwHighDateTime;
                return static_cast<double>(li.QuadPart) / 10000000.0;
            };
            m.cpu_user_sec   = to_sec(u);
            m.cpu_system_sec = to_sec(k);
        }

        CloseHandle(h);

        HANDLE snap = CreateToolhelp32Snapshot(TH32CS_SNAPTHREAD, 0);
        if (snap != INVALID_HANDLE_VALUE) {
            THREADENTRY32 te{};
            te.dwSize = sizeof(te);
            if (Thread32First(snap, &te)) {
                do {
                    if (te.th32OwnerProcessID == static_cast<DWORD>(pid)) {
                        ++m.thread_count;
                    }
                } while (Thread32Next(snap, &te));
            }
            CloseHandle(snap);
        }

        return m;
    }

#else

    ProcessMetrics sample_process_linux(std::uint32_t pid) {
        ProcessMetrics m;
        if (pid == 0) return m;

        const std::string base = "/proc/" + std::to_string(pid);

        {
            std::ifstream f(base + "/statm");
            if (f.is_open()) {
                std::uint64_t total_pages = 0;
                std::uint64_t resident_pages = 0;
                f >> total_pages >> resident_pages;
                const long page_size = sysconf(_SC_PAGESIZE);
                if (page_size > 0) {
                    m.rss_kib = (resident_pages *
                                 static_cast<std::uint64_t>(page_size)) / 1024;
                    m.valid = true;
                }
            }
        }

        {
            DIR* dir = opendir((base + "/fd").c_str());
            if (dir) {
                std::uint64_t count = 0;
                while (dirent* entry = readdir(dir)) {
                    if (std::strcmp(entry->d_name, ".") == 0 ||
                        std::strcmp(entry->d_name, "..") == 0) {
                        continue;
                    }
                    ++count;
                }
                closedir(dir);
                m.handle_count = count;
            }
        }

        {
            std::ifstream f(base + "/status");
            if (f.is_open()) {
                std::string line;
                while (std::getline(f, line)) {
                    if (line.rfind("Threads:", 0) == 0) {
                        std::istringstream iss(line.substr(8));
                        iss >> m.thread_count;
                        break;
                    }
                }
            }
        }

        {
            std::ifstream f(base + "/stat");
            if (f.is_open()) {
                std::string line;
                std::getline(f, line);
                const auto pos = line.find_last_of(')');
                if (pos != std::string::npos && pos + 2 < line.size()) {
                    std::istringstream iss(line.substr(pos + 2));
                    std::string tok;
                    for (int i = 0; i < 11; ++i) iss >> tok;
                    std::uint64_t utime = 0;
                    std::uint64_t stime = 0;
                    iss >> utime >> stime;
                    const long hz = sysconf(_SC_CLK_TCK);
                    if (hz > 0) {
                        m.cpu_user_sec   = static_cast<double>(utime) / hz;
                        m.cpu_system_sec = static_cast<double>(stime) / hz;
                    }
                }
            }
        }

        return m;
    }

#endif

    ProcessMetrics sample_process(std::uint32_t pid) {
#if defined(_WIN32)
        return sample_process_win(pid);
#else
        return sample_process_linux(pid);
#endif
    }

    // -------------------------------------------------------------------------
    //  Per-PID history kept between reports
    // -------------------------------------------------------------------------
    struct ClientHistory {
        std::uint64_t first_seen_ms     = 0;
        std::uint64_t last_total        = 0;
        std::uint64_t last_echo         = 0;
        std::uint64_t last_add          = 0;
        std::uint64_t last_hash         = 0;
        std::uint64_t last_leaked_calls = 0;
        std::uint64_t last_leaked_hnd   = 0;
        std::uint64_t last_ts_ms        = 0;
        double        current_echo_rate = 0.0;
        double        current_add_rate  = 0.0;
        double        current_hash_rate = 0.0;
        double        current_leak_rate = 0.0;
        ProcessMetrics last_metrics;
    };

    // -------------------------------------------------------------------------
    //  Fleet-wide state kept between reports
    // -------------------------------------------------------------------------
    struct FleetState {
        std::uint64_t first_seen_ms = 0;
        double        peak_rate     = 0.0;
    };

    // -------------------------------------------------------------------------
    //  Formatting helpers
    // -------------------------------------------------------------------------
    std::string format_wallclock(std::uint64_t unix_ms) {
        const std::time_t t = static_cast<std::time_t>(unix_ms / 1000ULL);
        std::tm tm_buf{};
#if defined(_WIN32)
        localtime_s(&tm_buf, &t);
#else
        localtime_r(&t, &tm_buf);
#endif
        std::ostringstream oss;
        oss << std::put_time(&tm_buf, "%H:%M:%S");
        return oss.str();
    }

    std::string format_duration(double seconds) {
        std::ostringstream oss;
        if (seconds < 60.0) {
            oss << std::fixed << std::setprecision(0) << seconds << "s";
        } else if (seconds < 3600.0) {
            const int m = static_cast<int>(seconds) / 60;
            const int s = static_cast<int>(seconds) % 60;
            oss << m << "m " << s << "s";
        } else {
            const int h = static_cast<int>(seconds) / 3600;
            const int m = (static_cast<int>(seconds) % 3600) / 60;
            oss << h << "h " << m << "m";
        }
        return oss.str();
    }

    std::string format_thousands(std::uint64_t v) {
        std::string s = std::to_string(v);
        std::string out;
        out.reserve(s.size() + s.size() / 3);
        int count = 0;
        for (auto it = s.rbegin(); it != s.rend(); ++it) {
            if (count == 3) {
                out.push_back(',');
                count = 0;
            }
            out.push_back(*it);
            ++count;
        }
        std::reverse(out.begin(), out.end());
        return out;
    }

    // -------------------------------------------------------------------------
    //  Report rendering
    // -------------------------------------------------------------------------
    constexpr const char* kHeavyRule =
        "================================================================================";

    void render_fleet_report(int report_index,
                             std::uint64_t now_wall_ms,
                             double uptime_sec,
                             int interval_ms,
                             int n_run,
                             int n_stop,
                             int n_dead,
                             int n_total_seen,
                             const stress::ClientReport& sum,
                             const ProcessMetrics& sum_metrics,
                             std::uint64_t rate_total,
                             std::uint64_t rate_echo,
                             std::uint64_t rate_add,
                             std::uint64_t rate_hash,
                             std::uint64_t leak_rate,
                             double average_rate,
                             double peak_rate) {
        std::ostringstream out;

        // ---- Header ----
        out << kHeavyRule << "\n";
        out << " STRESS MONITOR (fleet total)  #" << report_index
            << "   " << format_wallclock(now_wall_ms)
            << "   uptime " << format_duration(uptime_sec)
            << "   sample " << interval_ms << " ms\n";
        out << kHeavyRule << "\n";

        // ---- Liveness ----
        out << " Clients          : " << n_run << " RUN";
        if (n_stop > 0) out << "  |  " << n_stop << " STOP";
        if (n_dead > 0) out << "  |  " << n_dead << " DEAD";
        out << "   (total ever seen: " << n_total_seen << ")\n";

        // ---- Call counters ----
        const double success_pct =
            (sum.total_calls > 0)
                ? (100.0 * static_cast<double>(sum.success_calls) /
                   static_cast<double>(sum.total_calls))
                : 0.0;

        out << " Total calls      : " << format_thousands(sum.total_calls)
            << "\n";

        // ---- Calls per second ----
        out << " Calls per second : " << format_thousands(rate_total)
            << "   (echo=" << format_thousands(rate_echo)
            << "  add="  << format_thousands(rate_add)
            << "  hash=" << format_thousands(rate_hash) << ")\n";

        out << " Success / Failed : "
            << format_thousands(sum.success_calls) << " / "
            << format_thousands(sum.failure_calls)
            << "   (" << std::fixed << std::setprecision(2)
            << success_pct << " %)\n";
        out << " Per-API (total)  : echo="
            << format_thousands(sum.echo_calls)
            << "   add="  << format_thousands(sum.add_calls)
            << "   hash=" << format_thousands(sum.hash_calls) << "\n";

        // ---- Deliberate leaks ----
        out << " Leaked handles   : "
            << format_thousands(sum.leaked_handles)
            << " handles, " << format_thousands(sum.leaked_calls)
            << " calls   (rate " << format_thousands(leak_rate)
            << " calls/s)\n";

        // ---- Throughput ----
        out << " Throughput       : average "
            << std::fixed << std::setprecision(0)
            << average_rate << " c/s   peak " << peak_rate << " c/s\n";

        // ---- Resource totals ----
        std::ostringstream rss;
        rss << format_thousands(sum_metrics.rss_kib) << " KiB";
        if (sum_metrics.rss_kib >= 1024) {
            rss << "  (" << std::fixed << std::setprecision(1)
                << (static_cast<double>(sum_metrics.rss_kib) / 1024.0)
                << " MiB)";
        }

        out << kHeavyRule << "\n";
        out << " Total RSS        : " << rss.str() << "\n";
        out << " Total handles    : "
            << format_thousands(sum_metrics.handle_count) << "\n";
        out << " Total threads    : "
            << format_thousands(sum_metrics.thread_count) << "\n";
        out << " Total CPU time   : "
            << std::fixed << std::setprecision(1)
            << sum_metrics.cpu_user_sec << " s user + "
            << sum_metrics.cpu_system_sec << " s system = "
            << (sum_metrics.cpu_user_sec + sum_metrics.cpu_system_sec)
            << " s\n";
        out << " RSS/handle/thread/CPU totals cover the "
            << n_run << " live client(s) only.\n";
        out << kHeavyRule << "\n";

        // ---- Draw ----
        clear_screen();
        std::cout << out.str();
        std::cout.flush();
    }

} // namespace

int main(int argc, char* argv[]) {
    const int interval_ms =
        (argc > 1) ? std::atoi(argv[1]) : kDefaultIntervalMs;
    const int stale_timeout_ms =
        (argc > 2) ? std::atoi(argv[2]) : kDefaultStaleTimeoutMs;

    init_terminal();

    std::cout << "=== Stress Monitor (fleet total) ===" << std::endl;
    std::cout << "[Monitor] Endpoint       : " << stress::kEndpoint << "\n"
              << "[Monitor] App name       : " << stress::kMonitorApp << "\n"
              << "[Monitor] API name       : " << stress::kMonitorApi << "\n"
              << "[Monitor] Report period  : " << interval_ms << " ms\n"
              << "[Monitor] Stale timeout  : " << stale_timeout_ms << " ms\n"
              << "[Monitor] Clear screen   : "
              << (g_use_clear_screen ? "yes" : "no") << "\n"
              << "[Monitor] Press Ctrl+C to stop.\n"
              << std::endl;

    try {
#if defined(_WIN32)
        SetConsoleCtrlHandler(console_ctrl_handler, TRUE);
#else
        std::signal(SIGINT,  posix_signal_handler);
        std::signal(SIGTERM, posix_signal_handler);
#endif

        lingofuse::LibraryLoader loader;

        lingofuse::App app(stress::kMonitorApp,
                           "Stress test monitor observer");
        if (!app.registerNotify(stress::kMonitorApi,
                                "client status report (binary payload)",
                                nullptr, api_report)) {
            std::cerr << "[FATAL] Failed to register monitor API '"
                      << stress::kMonitorApi << "'." << std::endl;
            return EXIT_FAILURE;
        }

        lingofuse::setOption("Wait_Ready", "False");
        lingofuse::resetPrepare();

        const int cli_tag =
            lingofuse::prepareClient(stress::kEndpoint, app.get());
        if (cli_tag < 0) {
            std::cerr << "[FATAL] LF_PrepareClient failed for "
                      << stress::kEndpoint << std::endl;
            return EXIT_FAILURE;
        }

        if (lingofuse::prepareDone() != 1) {
            std::cerr << "[FATAL] LF_PrepareDone failed." << std::endl;
            return EXIT_FAILURE;
        }

        for (int i = 0; i < 50 && !g_stop_flag.load(); ++i) {
            if (lingofuse::checkApi(stress::kMonitorApp,
                                    stress::kMonitorApi)) {
                break;
            }
            std::this_thread::sleep_for(
                std::chrono::milliseconds(200));
        }

        std::cout << "[Monitor] Online on " << stress::kEndpoint
                  << ". Waiting for client reports..." << std::endl;

        const auto start = std::chrono::steady_clock::now();

        std::map<std::uint32_t, ClientHistory> history;
        FleetState fleet;
        int report_index = 0;
        int total_seen   = 0;

        // Placeholder report so the operator sees an empty table immediately.
        {
            const auto now_steady = std::chrono::steady_clock::now();
            const double uptime_sec =
                std::chrono::duration<double>(now_steady - start).count();
            render_fleet_report(0, stress::now_ms(), uptime_sec,
                                interval_ms,
                                0, 0, 0, 0,
                                stress::ClientReport{},
                                ProcessMetrics{},
                                0, 0, 0, 0, 0,
                                0.0, 0.0);
        }

        while (!g_stop_flag.load()) {
            std::this_thread::sleep_for(
                std::chrono::milliseconds(interval_ms));
            if (g_stop_flag.load()) break;

            const auto now_steady = std::chrono::steady_clock::now();
            const double uptime_sec =
                std::chrono::duration<double>(now_steady - start).count();
            const std::uint64_t now_wall_ms = stress::now_ms();

            // Snapshot the reports map.
            std::map<std::uint32_t, ReportEntry> snapshot;
            {
                std::lock_guard<std::mutex> lock(reports_mutex());
                snapshot = reports();
            }

            // Fleet accumulators.
            stress::ClientReport sum{};
            ProcessMetrics sum_metrics{};

            std::uint64_t rate_echo = 0;
            std::uint64_t rate_add  = 0;
            std::uint64_t rate_hash = 0;
            std::uint64_t leak_rate = 0;

            int n_run = 0, n_stop = 0, n_dead = 0;

            for (auto& [pid, entry] : snapshot) {
                // Liveness
                std::string state;
                if (entry.report.running == 0) {
                    state = "STOP";
                    ++n_stop;
                } else if (now_wall_ms - entry.last_seen_ms >
                           static_cast<std::uint64_t>(stale_timeout_ms)) {
                    state = "DEAD";
                    ++n_dead;
                } else {
                    state = "RUN";
                    ++n_run;
                }

                // History bookkeeping.
                ClientHistory& h = history[pid];
                if (h.first_seen_ms == 0) {
                    h.first_seen_ms     = entry.last_seen_ms;
                    h.last_total        = entry.report.total_calls;
                    h.last_echo         = entry.report.echo_calls;
                    h.last_add          = entry.report.add_calls;
                    h.last_hash         = entry.report.hash_calls;
                    h.last_leaked_calls = entry.report.leaked_calls;
                    h.last_leaked_hnd   = entry.report.leaked_handles;
                    h.last_ts_ms        = entry.report.timestamp_ms;
                    ++total_seen;
                }

                // Per-API rates from successive reports.
                if (entry.report.timestamp_ms > h.last_ts_ms) {
                    const double dt =
                        static_cast<double>(
                            entry.report.timestamp_ms - h.last_ts_ms) / 1000.0;
                    if (dt > 0.0) {
                        if (entry.report.echo_calls >= h.last_echo) {
                            h.current_echo_rate =
                                static_cast<double>(
                                    entry.report.echo_calls - h.last_echo)
                                / dt;
                        }
                        if (entry.report.add_calls >= h.last_add) {
                            h.current_add_rate =
                                static_cast<double>(
                                    entry.report.add_calls - h.last_add)
                                / dt;
                        }
                        if (entry.report.hash_calls >= h.last_hash) {
                            h.current_hash_rate =
                                static_cast<double>(
                                    entry.report.hash_calls - h.last_hash)
                                / dt;
                        }
                        if (entry.report.leaked_calls >= h.last_leaked_calls) {
                            h.current_leak_rate =
                                static_cast<double>(
                                    entry.report.leaked_calls -
                                    h.last_leaked_calls) / dt;
                        }
                    }
                }
                h.last_total        = entry.report.total_calls;
                h.last_echo         = entry.report.echo_calls;
                h.last_add          = entry.report.add_calls;
                h.last_hash         = entry.report.hash_calls;
                h.last_leaked_calls = entry.report.leaked_calls;
                h.last_leaked_hnd   = entry.report.leaked_handles;
                h.last_ts_ms        = entry.report.timestamp_ms;

                // Accumulate rates.
                rate_echo += static_cast<std::uint64_t>(
                    h.current_echo_rate + 0.5);
                rate_add  += static_cast<std::uint64_t>(
                    h.current_add_rate  + 0.5);
                rate_hash += static_cast<std::uint64_t>(
                    h.current_hash_rate + 0.5);
                leak_rate += static_cast<std::uint64_t>(
                    h.current_leak_rate + 0.5);

                // Accumulate counters.
                sum.total_calls    += entry.report.total_calls;
                sum.success_calls  += entry.report.success_calls;
                sum.failure_calls  += entry.report.failure_calls;
                sum.echo_calls     += entry.report.echo_calls;
                sum.add_calls      += entry.report.add_calls;
                sum.hash_calls     += entry.report.hash_calls;
                sum.leaked_calls   += entry.report.leaked_calls;
                sum.leaked_handles += entry.report.leaked_handles;

                // Accumulate resources for live clients only.
                if (state == "RUN") {
                    ProcessMetrics m = sample_process(pid);
                    if (m.valid) {
                        h.last_metrics = m;
                    }
                    sum_metrics.rss_kib        += h.last_metrics.rss_kib;
                    sum_metrics.handle_count   += h.last_metrics.handle_count;
                    sum_metrics.thread_count   += h.last_metrics.thread_count;
                    sum_metrics.cpu_user_sec   += h.last_metrics.cpu_user_sec;
                    sum_metrics.cpu_system_sec += h.last_metrics.cpu_system_sec;
                }
            }

            if (sum_metrics.rss_kib > 0 || sum_metrics.handle_count > 0) {
                sum_metrics.valid = true;
            }

            // Fleet-level rate history.
            const std::uint64_t rate_total = rate_echo + rate_add + rate_hash;

            if (fleet.first_seen_ms == 0) {
                fleet.first_seen_ms = now_wall_ms;
            }
            if (static_cast<double>(rate_total) > fleet.peak_rate) {
                fleet.peak_rate = static_cast<double>(rate_total);
            }

            const double elapsed_since_start =
                static_cast<double>(now_wall_ms - fleet.first_seen_ms) / 1000.0;
            const double average_rate =
                (elapsed_since_start > 0.0)
                    ? (static_cast<double>(sum.total_calls) /
                       elapsed_since_start)
                    : 0.0;

            ++report_index;
            render_fleet_report(report_index, now_wall_ms, uptime_sec,
                                interval_ms,
                                n_run, n_stop, n_dead, total_seen,
                                sum, sum_metrics,
                                rate_total,
                                rate_echo, rate_add, rate_hash,
                                leak_rate,
                                average_rate, fleet.peak_rate);
        }

        std::cout << "\n[Monitor] Shutting down..." << std::endl;
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

    std::cout << "[Monitor] Bye." << std::endl;
    return EXIT_SUCCESS;
}