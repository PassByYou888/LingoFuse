// =============================================================================
//  StressMonitor.cpp
// -----------------------------------------------------------------------------
//  Fleet observer for the LingoFuse stress test.
//
//  Interactive mode: redraws a full-screen ASCII dashboard once per second.
//  CI mode (--ci):  emits a JSON Lines event stream instead, and terminates
//                   automatically after --duration seconds.
//
//  In CI mode, the render target is a sequence of JSON objects:
//
//      {"event":"ready", ...}
//      {"event":"progress","t_sec":N,"clients_run":N,...,"per_api":{...}}
//      ...
//      {"event":"summary","clients_seen":N,"peak_rate":N,...,"status":"PASS"}
//
//  Set STRESS_MONITOR_NO_CLEAR=1 to disable the screen clear in interactive
//  mode (useful when piping to a file).
// =============================================================================

#include "LingoFuse.hpp"
#include "StressCommon.hpp"

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <ctime>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <map>
#include <mutex>
#include <numeric>
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
    extern "C" void posix_signal_handler(int) {
        g_stop_flag.store(true);
    }
#endif

    // ---- Terminal control --------------------------------------------------
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
                SetConsoleMode(h, mode | 0x0004);  // ENABLE_VT_PROCESSING
            }
        }
#endif
    }

    void clear_screen() {
        if (!g_use_clear_screen) return;
        std::cout << "\x1b[2J\x1b[H";
    }

    // ---- Report storage ----------------------------------------------------
    struct ReportEntry {
        stress::ClientReport report;
        std::uint64_t        last_seen_ms = 0;
    };

    std::mutex& reports_mutex() {
        static std::mutex m;
        return m;
    }

    std::map<std::uint32_t, ReportEntry>& client_reports() {
        static std::map<std::uint32_t, ReportEntry> r;
        return r;
    }

    std::map<std::uint32_t, ReportEntry>& service_reports() {
        static std::map<std::uint32_t, ReportEntry> r;
        return r;
    }

    void LF_CDECL api_report(void* /*trigger*/, void* input) {
        if (input == nullptr) return;
        lingofuse::DataHandle in(static_cast<TDataHnd>(input), false);

        stress::ClientReport r;
        if (!stress::read_report(in, r)) return;
        if (r.pid == 0) return;

        const std::uint64_t now = stress::now_ms();

        std::lock_guard<std::mutex> lock(reports_mutex());
        if (r.role == stress::kRoleService) {
            service_reports()[r.pid] = { r, now };
        }
        else {
            client_reports()[r.pid] = { r, now };
        }
    }

    // ---- Process metrics (unchanged) ---------------------------------------
    struct ProcessMetrics {
        std::uint64_t rss_kib = 0;
        std::uint64_t handle_count = 0;
        std::uint64_t thread_count = 0;
        double        cpu_user_sec = 0.0;
        double        cpu_system_sec = 0.0;
        bool          valid = false;
    };

#if defined(_WIN32)
    ProcessMetrics sample_process_win(std::uint32_t pid) {
        ProcessMetrics m;
        if (pid == 0) return m;
        HANDLE h = OpenProcess(
            PROCESS_QUERY_INFORMATION | PROCESS_VM_READ,
            FALSE, static_cast<DWORD>(pid));
        if (!h) {
            h = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION,
                FALSE, static_cast<DWORD>(pid));
        }
        if (!h) return m;

        PROCESS_MEMORY_COUNTERS pmc{};
        if (GetProcessMemoryInfo(h, &pmc, sizeof(pmc))) {
            m.rss_kib = pmc.WorkingSetSize / 1024;
            m.valid = true;
        }
        DWORD hc = 0;
        if (GetProcessHandleCount(h, &hc)) m.handle_count = hc;

        FILETIME c{}, e{}, k{}, u{};
        if (GetProcessTimes(h, &c, &e, &k, &u)) {
            auto to_sec = [](const FILETIME& ft) -> double {
                ULARGE_INTEGER li;
                li.LowPart = ft.dwLowDateTime;
                li.HighPart = ft.dwHighDateTime;
                return static_cast<double>(li.QuadPart) / 10000000.0;
                };
            m.cpu_user_sec = to_sec(u);
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
                std::uint64_t total_pages = 0, resident_pages = 0;
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
                        std::strcmp(entry->d_name, "..") == 0) continue;
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
                    std::uint64_t utime = 0, stime = 0;
                    iss >> utime >> stime;
                    const long hz = sysconf(_SC_CLK_TCK);
                    if (hz > 0) {
                        m.cpu_user_sec = static_cast<double>(utime) / hz;
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

    // ---- History -----------------------------------------------------------
    struct ClientHistory {
        std::uint64_t first_seen_ms = 0;
        std::uint64_t baseline_call_total = 0;
        std::uint64_t last_ts_ms = 0;
        std::uint64_t last_per_api[stress::kApiCount] = {};
        double        current_per_api_rate[stress::kApiCount] = {};
        ProcessMetrics last_metrics;
    };

    struct ServiceHistory {
        std::uint64_t last_ts_ms = 0;
        std::uint64_t last_per_api[stress::kApiCount] = {};
        double        current_per_api_rate[stress::kApiCount] = {};
        double        call_rate = 0.0;
        double        notify_rate = 0.0;
    };

    struct FleetState {
        std::uint64_t first_seen_ms = 0;
        double        peak_call_rate = 0.0;
    };

    // ---- Formatting helpers (interactive mode) -----------------------------
    std::string format_wallclock(std::uint64_t unix_ms) {
        const std::time_t t = static_cast<std::time_t>(unix_ms / 1000ULL);
        std::tm tm_buf{};
#if defined(_WIN32)
        localtime_s(&tm_buf, &t);
#else
        localtime_r(&t, &tm_buf);
#endif
        std::ostringstream oss;
        oss << std::put_time(&tm_buf, "%Y-%m-%d %H:%M:%S");
        return oss.str();
    }

    std::string format_duration(double seconds) {
        std::ostringstream oss;
        if (seconds < 60.0) {
            oss << std::fixed << std::setprecision(0) << seconds << "s";
        }
        else if (seconds < 3600.0) {
            const int m = static_cast<int>(seconds) / 60;
            const int s = static_cast<int>(seconds) % 60;
            oss << m << "m " << s << "s";
        }
        else {
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
            if (count == 3) { out.push_back(','); count = 0; }
            out.push_back(*it);
            ++count;
        }
        std::reverse(out.begin(), out.end());
        return out;
    }

    std::string format_bytes_mib(std::uint64_t kib) {
        std::ostringstream oss;
        oss << std::fixed << std::setprecision(1)
            << (static_cast<double>(kib) / 1024.0) << " MiB"
            << "  (" << format_thousands(kib) << " KiB)";
        return oss.str();
    }

    constexpr int kFrameWidth = 80;

    std::string rule_double() { return std::string(kFrameWidth, '='); }
    std::string rule_single() { return std::string(kFrameWidth, '-'); }

    void render_fleet_report(
        int report_index,
        std::uint64_t now_wall_ms,
        double uptime_sec,
        int interval_ms,
        int n_run, int n_stop, int n_dead, int n_total_seen,
        std::uint64_t client_call_total,
        std::uint64_t client_call_success,
        std::uint64_t client_call_failure,
        std::uint64_t client_notify_total,
        std::uint64_t client_leaked_calls,
        std::uint64_t client_leaked_handles,
        double client_call_rate_total,
        double client_notify_rate_total,
        double client_leak_rate,
        double average_call_rate,
        double peak_call_rate,
        bool service_online,
        std::uint32_t service_pid,
        double service_call_rate,
        double service_notify_rate,
        std::uint64_t service_call_cumulative,
        std::uint64_t service_notify_cumulative,
        const std::uint64_t service_per_api_cumulative[stress::kApiCount],
        const std::uint64_t service_per_api_rate[stress::kApiCount],
        const std::uint64_t client_per_api_cumulative[stress::kApiCount],
        const std::uint64_t client_per_api_rate[stress::kApiCount],
        const ProcessMetrics& sum_metrics)
    {
        const double success_pct =
            (client_call_total > 0)
            ? (100.0 * static_cast<double>(client_call_success) /
                static_cast<double>(client_call_total))
            : 0.0;

        std::ostringstream out;
        out << rule_double() << "\n";
        out << "  LINGOFUSE  -  STRESS MONITOR\n";
        out << "  Report #" << report_index
            << "   -   " << format_wallclock(now_wall_ms)
            << "   -   Uptime " << format_duration(uptime_sec)
            << "   -   Sample " << interval_ms << " ms\n";
        out << rule_double() << "\n\n";

        out << "  CLIENT FLEET"
            "                              "
            "SERVICE\n";
        out << "  " << std::string(36, '-') << "      "
            << std::string(36, '-') << "\n";

        {
            std::ostringstream a, b;
            a << "    Running ................ " << std::setw(3) << n_run;
            b << "    Status ................ "
                << (service_online ? "ONLINE" : "OFFLINE");
            out << a.str() << "     " << b.str() << "\n";

            a.str(""); a.clear(); b.str(""); b.clear();
            a << "    Stopped ................ " << std::setw(3) << n_stop;
            b << "    Call processing ....... "
                << std::setw(9)
                << format_thousands(static_cast<std::uint64_t>(
                    service_call_rate + 0.5))
                << " /s";
            out << a.str() << "     " << b.str() << "\n";

            a.str(""); a.clear(); b.str(""); b.clear();
            a << "    Dead ................... " << std::setw(3) << n_dead;
            b << "    Notify processing ..... "
                << std::setw(9)
                << format_thousands(static_cast<std::uint64_t>(
                    service_notify_rate + 0.5))
                << " /s";
            out << a.str() << "     " << b.str() << "\n";

            a.str(""); a.clear(); b.str(""); b.clear();
            a << "    Total ever seen ........ " << std::setw(3) << n_total_seen;
            b << "    Total processed ....... "
                << std::setw(12)
                << format_thousands(service_call_cumulative +
                    service_notify_cumulative);
            out << a.str() << "     " << b.str() << "\n";

            a.str(""); a.clear(); b.str(""); b.clear();
            a << "    Leaked handles ........ "
                << std::setw(12) << format_thousands(client_leaked_handles);
            b << "    Service PID ........... " << std::setw(12)
                << (service_online ? std::to_string(service_pid) : "-");
            out << a.str() << "     " << b.str() << "\n";
        }

        out << "\n" << rule_single() << "\n";
        out << "  THROUGHPUT (fleet  -  current second)\n";
        out << rule_single() << "\n";

        auto tp_line = [&](const std::string& label, const std::string& value) {
            out << "    " << std::left << std::setw(28) << label
                << std::right << std::setw(18) << value << "\n";
            };

        tp_line("Calls sent ..................",
            format_thousands(static_cast<std::uint64_t>(
                client_call_rate_total + 0.5)) + " /s");
        tp_line("Notifies sent ...............",
            format_thousands(static_cast<std::uint64_t>(
                client_notify_rate_total + 0.5)) + " /s");
        tp_line("Success rate ................",
            (std::ostringstream() << std::fixed << std::setprecision(2)
                << success_pct << " %").str());
        tp_line("Average (observation window) .",
            format_thousands(static_cast<std::uint64_t>(
                average_call_rate + 0.5)) + " /s");
        tp_line("Peak ........................",
            format_thousands(static_cast<std::uint64_t>(
                peak_call_rate + 0.5)) + " /s");

        out << "\n" << rule_single() << "\n";
        out << "  HANDLE LEAKS  "
            "(deliberate; reclaimed by the library after 10 min idle)\n";
        out << rule_single() << "\n";
        tp_line("Leaked calls ................",
            format_thousands(client_leaked_calls) + "   rate "
            + format_thousands(static_cast<std::uint64_t>(
                client_leak_rate + 0.5)) + " /s");
        tp_line("Leaked handles ..............",
            format_thousands(client_leaked_handles));

        out << "\n" << rule_single() << "\n";
        out << "  RESOURCES (live clients only)\n";
        out << rule_single() << "\n";
        tp_line("RSS .........................",
            format_bytes_mib(sum_metrics.rss_kib));
        tp_line("Open handles ................",
            format_thousands(sum_metrics.handle_count));
        tp_line("Threads .....................",
            format_thousands(sum_metrics.thread_count));
        {
            std::ostringstream cpu;
            cpu << std::fixed << std::setprecision(1)
                << sum_metrics.cpu_user_sec << " s user + "
                << sum_metrics.cpu_system_sec << " s system  =  "
                << (sum_metrics.cpu_user_sec + sum_metrics.cpu_system_sec)
                << " s";
            tp_line("CPU time ....................", cpu.str());
        }

        out << "\n" << rule_single() << "\n";
        out << "  PER-API  (client view)\n";
        out << rule_single() << "\n";
        for (std::size_t i = 0; i < stress::kApiCount; ++i) {
            out << "    " << std::left << std::setw(14)
                << stress::kApiNames[i]
                << std::right << std::setw(12)
                << format_thousands(client_per_api_rate[i])
                << " /s   cumulative  "
                << std::setw(14)
                << format_thousands(client_per_api_cumulative[i]);
            if (i == stress::kIdxNotifyDemo) out << "   [notify]";
            out << "\n";
        }

        out << "\n" << rule_double() << "\n";

        clear_screen();
        std::cout << out.str();
        std::cout.flush();
    }

    // ---- CI progress emitter ------------------------------------------------
    void emit_ci_progress(
        int report_index,
        double uptime_sec,
        int n_run, int n_stop, int n_dead, int n_total_seen,
        std::uint64_t sum_call_total,
        std::uint64_t sum_call_success,
        std::uint64_t sum_call_failure,
        std::uint64_t sum_notify_total,
        double client_call_rate_total,
        double average_call_rate,
        double peak_call_rate,
        const std::uint64_t sum_per_api_rate[stress::kApiCount],
        const std::uint64_t sum_per_api_cumulative[stress::kApiCount],
        const ProcessMetrics& sum_metrics)
    {
        const double success_pct =
            (sum_call_total > 0)
            ? (100.0 * static_cast<double>(sum_call_success) /
                static_cast<double>(sum_call_total))
            : 0.0;

        nlohmann::json j;
        j["event"] = "progress";
        j["report"] = report_index;
        j["t_sec"] = static_cast<int>(uptime_sec);
        j["clients_run"] = n_run;
        j["clients_stop"] = n_stop;
        j["clients_dead"] = n_dead;
        j["clients_seen"] = n_total_seen;
        j["call_total"] = sum_call_total;
        j["call_success"] = sum_call_success;
        j["call_failure"] = sum_call_failure;
        j["notify_total"] = sum_notify_total;
        j["success_pct"] = success_pct;
        j["rate_calls_per_sec"] =
            static_cast<std::uint64_t>(client_call_rate_total + 0.5);
        j["rate_average"] = static_cast<std::uint64_t>(average_call_rate + 0.5);
        j["rate_peak"] = static_cast<std::uint64_t>(peak_call_rate + 0.5);

        for (std::size_t i = 0; i < stress::kApiCount; ++i) {
            j["per_api_rate"][stress::kApiNames[i]] = sum_per_api_rate[i];
            j["per_api_cumulative"][stress::kApiNames[i]] =
                sum_per_api_cumulative[i];
        }

        j["rss_kib"] = sum_metrics.rss_kib;
        j["handles"] = sum_metrics.handle_count;
        j["threads"] = sum_metrics.thread_count;
        j["cpu_user_sec"] = sum_metrics.cpu_user_sec;
        j["cpu_system_sec"] = sum_metrics.cpu_system_sec;

        stress::json_emit(j);
    }

} // namespace

int main(int argc, char* argv[]) {
    const stress::CliOptions opt =
        stress::CliOptions::parse(argc, argv, "StressMonitor");
    g_ci_mode = opt.ci;

    init_terminal();

    if (!opt.ci) {
        std::cout << "=== Stress Monitor (fleet total) ===" << std::endl;
        std::cout << "[Monitor] Endpoint       : " << stress::kEndpoint << "\n"
            << "[Monitor] App name       : " << stress::kMonitorApp << "\n"
            << "[Monitor] API name       : " << stress::kMonitorApi << "\n"
            << "[Monitor] Report period  : " << opt.interval_ms << " ms\n"
            << "[Monitor] Stale timeout  : " << opt.stale_timeout_ms << " ms\n"
            << "[Monitor] Clear screen   : "
            << (g_use_clear_screen ? "yes" : "no") << "\n"
            << "[Monitor] Press Ctrl+C to stop.\n"
            << std::endl;
    }

    const auto start = std::chrono::steady_clock::now();

    try {
#if defined(_WIN32)
        SetConsoleCtrlHandler(console_ctrl_handler, TRUE);
#else
        std::signal(SIGINT, posix_signal_handler);
        std::signal(SIGTERM, posix_signal_handler);
#endif

        lingofuse::LibraryLoader loader;

        lingofuse::App app(stress::kMonitorApp,
            "Stress test monitor observer");
        if (!app.registerNotify(stress::kMonitorApi,
            "client and service status reports",
            nullptr, api_report)) {
            std::cerr << "[FATAL] Failed to register monitor API '"
                << stress::kMonitorApi << "'." << std::endl;
            return EXIT_FAILURE;
        }

        lingofuse::setOption("Wait_Ready", "False");
        if (opt.ci) {
            lingofuse::setOption("Quiet", "True");
        }
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
                stress::kMonitorApi)) break;
            std::this_thread::sleep_for(std::chrono::milliseconds(200));
        }

        if (opt.ci) {
            nlohmann::json j;
            j["event"] = "ready";
            j["pid"] = stress::get_current_pid();
            j["role"] = "monitor";
            j["endpoint"] = stress::kEndpoint;
            j["app"] = stress::kMonitorApp;
            j["api"] = stress::kMonitorApi;
            j["interval_ms"] = opt.interval_ms;
            j["stale_timeout_ms"] = opt.stale_timeout_ms;
            j["duration_sec"] = opt.duration_sec;
            stress::json_emit(j);
        }
        else {
            std::cout << "[Monitor] Online on " << stress::kEndpoint
                << ". Waiting for reports..." << std::endl;
        }

        std::map<std::uint32_t, ClientHistory>  client_hist;
        std::map<std::uint32_t, ServiceHistory> service_hist;
        FleetState fleet;
        int report_index = 0;
        int total_seen = 0;

        // Interactive placeholder so the operator sees a frame immediately.
        if (!opt.ci) {
            const auto now_steady = std::chrono::steady_clock::now();
            const double uptime_sec =
                std::chrono::duration<double>(now_steady - start).count();
            std::uint64_t zero[stress::kApiCount] = {};
            render_fleet_report(
                0, stress::now_ms(), uptime_sec, opt.interval_ms,
                0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
                0.0, 0.0, 0.0, 0.0, 0.0,
                false, 0, 0.0, 0.0, 0, 0,
                zero, zero, zero, zero,
                ProcessMetrics{});
        }

        // Snapshot for the final CI summary.
        std::uint64_t final_call_total = 0;
        std::uint64_t final_call_success = 0;
        std::uint64_t final_call_failure = 0;
        std::uint64_t final_notify_total = 0;
        double        final_peak_rate = 0.0;
        double        final_avg_rate = 0.0;
        double        final_success_pct = 0.0;

        while (!g_stop_flag.load()) {
            std::this_thread::sleep_for(
                std::chrono::milliseconds(opt.interval_ms));
            if (g_stop_flag.load()) break;

            // CI auto-termination after --duration sec.
            if (opt.ci && opt.duration_sec > 0) {
                const auto now_steady = std::chrono::steady_clock::now();
                const int elapsed = static_cast<int>(
                    std::chrono::duration_cast<std::chrono::seconds>(
                        now_steady - start).count());
                if (elapsed >= opt.duration_sec) {
                    g_stop_flag.store(true);
                    break;
                }
            }

            const auto now_steady = std::chrono::steady_clock::now();
            const double uptime_sec =
                std::chrono::duration<double>(now_steady - start).count();
            const std::uint64_t now_wall_ms = stress::now_ms();

            // Snapshot under lock.
            std::map<std::uint32_t, ReportEntry> client_snap;
            std::map<std::uint32_t, ReportEntry> service_snap;
            {
                std::lock_guard<std::mutex> lock(reports_mutex());
                client_snap = client_reports();
                service_snap = service_reports();
            }

            // ---- Client aggregate ----------------------------------------
            std::uint64_t sum_call_total = 0;
            std::uint64_t sum_call_success = 0;
            std::uint64_t sum_call_failure = 0;
            std::uint64_t sum_notify_total = 0;
            std::uint64_t sum_leaked_calls = 0;
            std::uint64_t sum_leaked_handles = 0;
            std::uint64_t sum_per_api_cumulative[stress::kApiCount] = {};
            std::uint64_t sum_per_api_rate[stress::kApiCount] = {};
            ProcessMetrics sum_metrics{};
            std::uint64_t fleet_delta_call = 0;
            double        leak_rate = 0.0;
            int n_run = 0, n_stop = 0, n_dead = 0;

            for (auto& [pid, entry] : client_snap) {
                if (entry.report.running == 0) {
                    ++n_stop;
                }
                else if (now_wall_ms - entry.last_seen_ms >
                    static_cast<std::uint64_t>(opt.stale_timeout_ms)) {
                    ++n_dead;
                }
                else {
                    ++n_run;
                }

                ClientHistory& h = client_hist[pid];
                if (h.first_seen_ms == 0) {
                    h.first_seen_ms = entry.last_seen_ms;
                    h.baseline_call_total = entry.report.call_total;
                    h.last_ts_ms = entry.report.timestamp_ms;
                    for (std::size_t i = 0; i < stress::kApiCount; ++i) {
                        h.last_per_api[i] = entry.report.per_api[i];
                    }
                    ++total_seen;
                }

                if (entry.report.timestamp_ms > h.last_ts_ms) {
                    const double dt = static_cast<double>(
                        entry.report.timestamp_ms - h.last_ts_ms) / 1000.0;
                    if (dt > 0.0) {
                        for (std::size_t i = 0; i < stress::kApiCount; ++i) {
                            if (entry.report.per_api[i] >= h.last_per_api[i]) {
                                h.current_per_api_rate[i] =
                                    static_cast<double>(
                                        entry.report.per_api[i] -
                                        h.last_per_api[i]) / dt;
                            }
                            else {
                                h.current_per_api_rate[i] = 0.0;
                            }
                        }
                    }
                }
                for (std::size_t i = 0; i < stress::kApiCount; ++i) {
                    h.last_per_api[i] = entry.report.per_api[i];
                }
                h.last_ts_ms = entry.report.timestamp_ms;

                for (std::size_t i = 0; i < stress::kApiCount; ++i) {
                    sum_per_api_rate[i] += static_cast<std::uint64_t>(
                        h.current_per_api_rate[i] + 0.5);
                    sum_per_api_cumulative[i] += entry.report.per_api[i];
                }
                sum_call_total += entry.report.call_total;
                sum_call_success += entry.report.call_success;
                sum_call_failure += entry.report.call_failure;
                sum_notify_total += entry.report.notify_total;
                sum_leaked_calls += entry.report.leaked_calls;
                sum_leaked_handles += entry.report.leaked_handles;

                fleet_delta_call +=
                    (entry.report.call_total - h.baseline_call_total);

                if (entry.report.running != 0 &&
                    now_wall_ms - entry.last_seen_ms <=
                    static_cast<std::uint64_t>(opt.stale_timeout_ms)) {
                    ProcessMetrics m = sample_process(pid);
                    if (m.valid) h.last_metrics = m;
                    sum_metrics.rss_kib += h.last_metrics.rss_kib;
                    sum_metrics.handle_count += h.last_metrics.handle_count;
                    sum_metrics.thread_count += h.last_metrics.thread_count;
                    sum_metrics.cpu_user_sec += h.last_metrics.cpu_user_sec;
                    sum_metrics.cpu_system_sec += h.last_metrics.cpu_system_sec;
                }
            }

            if (sum_metrics.rss_kib > 0 || sum_metrics.handle_count > 0) {
                sum_metrics.valid = true;
            }

            double client_call_rate_total = 0.0;
            for (std::size_t i = 0; i < stress::kCallApiCount; ++i) {
                client_call_rate_total += static_cast<double>(
                    sum_per_api_rate[i]);
            }
            const double client_notify_rate_total = static_cast<double>(
                sum_per_api_rate[stress::kIdxNotifyDemo]);

            if (fleet.first_seen_ms == 0) {
                fleet.first_seen_ms = now_wall_ms;
            }
            const double elapsed_since_start =
                static_cast<double>(now_wall_ms - fleet.first_seen_ms) / 1000.0;
            leak_rate = (elapsed_since_start > 0.0)
                ? static_cast<double>(sum_leaked_handles) / elapsed_since_start
                : 0.0;

            if (client_call_rate_total > fleet.peak_call_rate) {
                fleet.peak_call_rate = client_call_rate_total;
            }
            const double average_call_rate =
                (elapsed_since_start > 0.0)
                ? (static_cast<double>(fleet_delta_call) / elapsed_since_start)
                : 0.0;

            // ---- Service aggregate ---------------------------------------
            bool          service_online = false;
            std::uint32_t service_pid = 0;
            double        service_call_rate = 0.0;
            double        service_notify_rate = 0.0;
            std::uint64_t service_call_cumul = 0;
            std::uint64_t service_notify_cumul = 0;
            std::uint64_t service_per_api_cumul[stress::kApiCount] = {};
            std::uint64_t service_per_api_rate[stress::kApiCount] = {};

            for (auto& [pid, entry] : service_snap) {
                const bool fresh = (now_wall_ms - entry.last_seen_ms <=
                    static_cast<std::uint64_t>(opt.stale_timeout_ms));
                if (!fresh) continue;

                service_online = true;
                service_pid = pid;

                ServiceHistory& h = service_hist[pid];
                if (entry.report.timestamp_ms > h.last_ts_ms) {
                    const double dt = static_cast<double>(
                        entry.report.timestamp_ms - h.last_ts_ms) / 1000.0;
                    if (dt > 0.0) {
                        for (std::size_t i = 0; i < stress::kApiCount; ++i) {
                            if (entry.report.per_api[i] >= h.last_per_api[i]) {
                                h.current_per_api_rate[i] =
                                    static_cast<double>(
                                        entry.report.per_api[i] -
                                        h.last_per_api[i]) / dt;
                            }
                            else {
                                h.current_per_api_rate[i] = 0.0;
                            }
                        }
                    }
                }
                for (std::size_t i = 0; i < stress::kApiCount; ++i) {
                    h.last_per_api[i] = entry.report.per_api[i];
                }
                h.last_ts_ms = entry.report.timestamp_ms;

                for (std::size_t i = 0; i < stress::kApiCount; ++i) {
                    service_per_api_cumul[i] = entry.report.per_api[i];
                    service_per_api_rate[i] = static_cast<std::uint64_t>(
                        h.current_per_api_rate[i] + 0.5);
                }
                service_call_cumul = entry.report.call_total;
                service_notify_cumul = entry.report.notify_total;

                double sum_call_rate = 0.0;
                for (std::size_t i = 0; i < stress::kCallApiCount; ++i) {
                    sum_call_rate += h.current_per_api_rate[i];
                }
                service_call_rate = sum_call_rate;
                service_notify_rate = h.current_per_api_rate[
                    stress::kIdxNotifyDemo];
            }

            // Remember the values that go into the CI summary.
            final_call_total = sum_call_total;
            final_call_success = sum_call_success;
            final_call_failure = sum_call_failure;
            final_notify_total = sum_notify_total;
            final_peak_rate = fleet.peak_call_rate;
            final_avg_rate = average_call_rate;
            final_success_pct = (sum_call_total > 0)
                ? (100.0 * static_cast<double>(sum_call_success) /
                    static_cast<double>(sum_call_total))
                : 0.0;

            ++report_index;

            if (opt.ci) {
                emit_ci_progress(
                    report_index, uptime_sec,
                    n_run, n_stop, n_dead, total_seen,
                    sum_call_total, sum_call_success, sum_call_failure,
                    sum_notify_total,
                    client_call_rate_total, average_call_rate,
                    fleet.peak_call_rate,
                    sum_per_api_rate, sum_per_api_cumulative,
                    sum_metrics);
            }
            else {
                render_fleet_report(
                    report_index, now_wall_ms, uptime_sec, opt.interval_ms,
                    n_run, n_stop, n_dead, total_seen,
                    sum_call_total, sum_call_success, sum_call_failure,
                    sum_notify_total,
                    sum_leaked_calls, sum_leaked_handles,
                    client_call_rate_total, client_notify_rate_total,
                    leak_rate, average_call_rate, fleet.peak_call_rate,
                    service_online, service_pid,
                    service_call_rate, service_notify_rate,
                    service_call_cumul, service_notify_cumul,
                    service_per_api_cumul, service_per_api_rate,
                    sum_per_api_cumulative, sum_per_api_rate,
                    sum_metrics);
            }
        }

        if (!opt.ci) {
            std::cout << "\n[Monitor] Shutting down..." << std::endl;
        }

        // ---- Final CI summary -------------------------------------------
        if (opt.ci) {
            const auto now_steady = std::chrono::steady_clock::now();
            const double uptime_sec =
                std::chrono::duration<double>(now_steady - start).count();

            nlohmann::json j;
            j["event"] = "summary";
            j["pid"] = stress::get_current_pid();
            j["role"] = "monitor";
            j["uptime_sec"] = static_cast<int>(uptime_sec);
            j["reports"] = report_index;
            j["clients_seen"] = total_seen;
            j["call_total"] = final_call_total;
            j["call_success"] = final_call_success;
            j["call_failure"] = final_call_failure;
            j["notify_total"] = final_notify_total;
            j["success_pct"] = final_success_pct;
            j["rate_average"] =
                static_cast<std::uint64_t>(final_avg_rate + 0.5);
            j["rate_peak"] =
                static_cast<std::uint64_t>(final_peak_rate + 0.5);
            j["status"] = (final_success_pct >= opt.min_success_pct)
                ? "PASS" : "FAIL";
            stress::json_emit(j);
        }

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

    if (!opt.ci) {
        std::cout << "[Monitor] Bye." << std::endl;
    }
    return EXIT_SUCCESS;
}