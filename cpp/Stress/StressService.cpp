// =============================================================================
//  StressService.cpp
// -----------------------------------------------------------------------------
//  Service node for the LingoFuse stress and stability test.
//
//  This process plays BOTH roles:
//
//      1. Beacon   -- prepareService("ipc:stress", "ipc:stress")
//      2. Worker   -- prepareClient("ipc:stress", app) publishes the App
//
//  Registered APIs:
//
//      echo  (string)         -> string   (returns the input unchanged)
//      add   (int32, int32)   -> int32    (returns the sum)
//      hash  (string)         -> uint64   (FNV-1a 64-bit)
//
//  Additionally, a background reporter thread prints once per second the
//  number of calls that the service has executed for each API in the last
//  second, plus the total and cumulative count:
//
//      [Service] calls/s: echo=5028 add=5027 hash=5027 total=15082   cumulative: 633822
//
//  Cleanup order (LF-CLEAN-001):
//      LF_ExitMainThread -> ~App (LF_FreeApp) -> LF_Shutdown
// =============================================================================

#if defined(_WIN32) && !defined(_CRT_SECURE_NO_WARNINGS)
#  define _CRT_SECURE_NO_WARNINGS
#endif

#include "LingoFuse.hpp"

#include <atomic>
#include <chrono>
#include <csignal>
#include <cstdint>
#include <cstdlib>
#include <iostream>
#include <mutex>
#include <sstream>
#include <string>
#include <thread>

// Platform-specific headers for the Ctrl+C handler.
#if defined(_WIN32)
#  define WIN32_LEAN_AND_MEAN
#  include <windows.h>
#else
#  include <unistd.h>
#endif

namespace {

    // -------------------------------------------------------------------------
    //  Per-API call counters
    // -------------------------------------------------------------------------
    std::atomic<std::uint64_t> g_echo_count{ 0 };
    std::atomic<std::uint64_t> g_add_count{ 0 };
    std::atomic<std::uint64_t> g_hash_count{ 0 };

    // -------------------------------------------------------------------------
    //  Stop flag
    // -------------------------------------------------------------------------
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

    // -------------------------------------------------------------------------
    //  Thread-safe line output
    // -------------------------------------------------------------------------
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

    // -------------------------------------------------------------------------
    //  API: echo(string) -> string
    // -------------------------------------------------------------------------
    void LF_CDECL api_echo(void* /*trigger*/,
        void* input,
        void* output) {
        g_echo_count.fetch_add(1, std::memory_order_relaxed);

        lingofuse::DataHandle in(static_cast<TDataHnd>(input), false);
        lingofuse::DataHandle out(static_cast<TDataHnd>(output), false);

        std::string text;
        if (!in.read(text)) return;
        out.write(text);
    }

    // -------------------------------------------------------------------------
    //  API: add(int32, int32) -> int32
    // -------------------------------------------------------------------------
    void LF_CDECL api_add(void* /*trigger*/,
        void* input,
        void* output) {
        g_add_count.fetch_add(1, std::memory_order_relaxed);

        lingofuse::DataHandle in(static_cast<TDataHnd>(input), false);
        lingofuse::DataHandle out(static_cast<TDataHnd>(output), false);

        std::int32_t a = 0;
        std::int32_t b = 0;
        if (!in.read(a) || !in.read(b)) return;
        out.write(static_cast<std::int32_t>(a + b));
    }

    // -------------------------------------------------------------------------
    //  API: hash(string) -> uint64  (FNV-1a 64-bit)
    // -------------------------------------------------------------------------
    void LF_CDECL api_hash(void* /*trigger*/,
        void* input,
        void* output) {
        g_hash_count.fetch_add(1, std::memory_order_relaxed);

        lingofuse::DataHandle in(static_cast<TDataHnd>(input), false);
        lingofuse::DataHandle out(static_cast<TDataHnd>(output), false);

        std::string text;
        if (!in.read(text)) return;

        std::uint64_t h = 14695981039346656037ULL;
        for (unsigned char c : text) {
            h ^= static_cast<std::uint64_t>(c);
            h *= 1099511628211ULL;
        }
        out.write(h);
    }

    // -------------------------------------------------------------------------
    //  Reporter thread
    // -------------------------------------------------------------------------
    void reporter() {
        using namespace std::chrono;

        std::uint64_t last_echo = 0;
        std::uint64_t last_add = 0;
        std::uint64_t last_hash = 0;

        while (!g_stop_flag.load(std::memory_order_relaxed)) {
            std::this_thread::sleep_for(seconds(1));
            if (g_stop_flag.load(std::memory_order_relaxed)) break;

            const std::uint64_t cur_echo =
                g_echo_count.load(std::memory_order_relaxed);
            const std::uint64_t cur_add =
                g_add_count.load(std::memory_order_relaxed);
            const std::uint64_t cur_hash =
                g_hash_count.load(std::memory_order_relaxed);

            const std::uint64_t d_echo = cur_echo - last_echo;
            const std::uint64_t d_add = cur_add - last_add;
            const std::uint64_t d_hash = cur_hash - last_hash;
            const std::uint64_t d_total = d_echo + d_add + d_hash;

            last_echo = cur_echo;
            last_add = cur_add;
            last_hash = cur_hash;

            log_line("[Service] calls/s: echo=", d_echo,
                " add=", d_add,
                " hash=", d_hash,
                " total=", d_total,
                "   cumulative: ", (cur_echo + cur_add + cur_hash));
        }
    }

    // -------------------------------------------------------------------------
    //  ShutdownGuard
    // -------------------------------------------------------------------------
    struct ShutdownGuard {
        ~ShutdownGuard() {
            try { lingofuse::shutdown(); }
            catch (...) {}
        }
    };

} // namespace

int main() {
    std::cout << "=== Stress Service (beacon + API executor) ==="
        << std::endl;

    try {
#if defined(_WIN32)
        SetConsoleCtrlHandler(console_ctrl_handler, TRUE);
#else
        std::signal(SIGINT, posix_signal_handler);
        std::signal(SIGTERM, posix_signal_handler);
#endif

        lingofuse::LibraryLoader loader;      // destroyed last  -> LF_FreeLibrary
        ShutdownGuard shutdown_guard;          // destroyed second -> LF_Shutdown

        {
            lingofuse::App app("StressSvc", "Stress test service");

            if (!app.registerCall("echo",
                "echo(string) -> string",
                nullptr, api_echo)) {
                std::cerr << "[FATAL] Failed to register 'echo'."
                    << std::endl;
                return EXIT_FAILURE;
            }
            if (!app.registerCall("add",
                "add(int32,int32) -> int32",
                nullptr, api_add)) {
                std::cerr << "[FATAL] Failed to register 'add'."
                    << std::endl;
                return EXIT_FAILURE;
            }
            if (!app.registerCall("hash",
                "hash(string) -> uint64",
                nullptr, api_hash)) {
                std::cerr << "[FATAL] Failed to register 'hash'."
                    << std::endl;
                return EXIT_FAILURE;
            }

            std::cout << "[Service] Registered APIs: echo, add, hash"
                << std::endl;

            lingofuse::setOption("Wait_Ready", "False");
            lingofuse::resetPrepare();

            // Step 1: create the IPC beacon endpoint.
            const int serv_tag =
                lingofuse::prepareService("ipc:stress", "ipc:stress");
            if (serv_tag < 0) {
                std::cerr << "[FATAL] LF_PrepareService failed."
                    << std::endl;
                return EXIT_FAILURE;
            }

            const int serv_tag2 =
                lingofuse::prepareService("0.0.0.0:9588", "127.0.0.1:9588");
            if (serv_tag2 < 0) {
                std::cerr << "[FATAL] LF_PrepareService failed."
                    << std::endl;
                return EXIT_FAILURE;
            }

            // Step 2: publish the App to the mesh.
            const int cli_tag =
                lingofuse::prepareClient("ipc:stress", app.get());
            if (cli_tag < 0) {
                std::cerr << "[FATAL] LF_PrepareClient failed."
                    << std::endl;
                return EXIT_FAILURE;
            }

            const int cli_tag2 =
                lingofuse::prepareClient("127.0.0.1:9588", app.get());
            if (cli_tag2 < 0) {
                std::cerr << "[FATAL] LF_PrepareClient failed."
                    << std::endl;
                return EXIT_FAILURE;
            }

            if (lingofuse::prepareDone() != 1) {
                std::cerr << "[FATAL] LF_PrepareDone failed."
                    << std::endl;
                return EXIT_FAILURE;
            }

            std::cout << "[Service] Online on ipc:stress. "
                << "Press Ctrl+C or Enter to shut down..." << std::endl;

            // Per-second throughput reporter.
            std::thread reporter_thread(reporter);

            // Stdin watcher: any line on stdin also triggers shutdown.
            std::thread([]() {
                std::string line;
                if (std::getline(std::cin, line)) {
                    g_stop_flag.store(true);
                }
                }).detach();

            // Wait until Ctrl+C or Enter.
            while (!g_stop_flag.load()) {
                std::this_thread::sleep_for(
                    std::chrono::milliseconds(100));
            }

            std::cout << "\n[Service] Shutting down..." << std::endl;

            if (reporter_thread.joinable()) {
                reporter_thread.join();
            }

            lingofuse::exitMainThread();

        } // <- ~App()           : LF_FreeApp
          // <- ~ShutdownGuard() : LF_Shutdown
          // <- ~LibraryLoader() : LF_FreeLibrary

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

    std::cout << "[Service] Bye." << std::endl;
    return EXIT_SUCCESS;
}