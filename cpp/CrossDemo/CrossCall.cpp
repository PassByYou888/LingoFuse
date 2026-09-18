// =============================================================================
//  CrossCall.cpp
// -----------------------------------------------------------------------------
//  Concurrent client / load tester for the "ipc:cross" endpoint.
//
//  It connects as a pure consumer (no application attached) and spawns
//  several worker threads. Each thread repeatedly invokes one of two remote
//  APIs on the "demo" application at random:
//
//      add       (int32 a, int32 b)                    -> int32
//      inv_seri  (uint8, uint16, uint32, uint64,
//                 string, float)                        -> reversed types
//
//  The test runs for a fixed duration and then shuts down cleanly. Multiple
//  instances of this program may be launched concurrently to drive even
//  higher load against the mesh.
//
//  Output interleaving:
//      Worker threads print through the helper `log_line()`, which formats
//      the entire line in memory and then emits it under a process-wide
//      mutex. This prevents character-level interleaving that would occur
//      if multiple threads issued chained std::cout << ... << ... calls
//      concurrently. Single-threaded phases (startup, summary, shutdown)
//      still use std::cout directly.
//
//  Log sampling:
//      With kWorkerThreads = 32 and kPauseMillis = 1, the process issues
//      tens of thousands of calls per second. Printing every call would
//      make the log I/O itself the bottleneck. Each worker therefore only
//      logs one out of every kLogEveryNthCall iterations; the aggregate
//      counters in `Stats` remain exact.
//
//  Cleanup order (matching Pascal LF-CLEAN-001):
//      LF_ExitMainThread  ->  LF_Shutdown
//
//  The required destruction order is enforced by declaration order:
//
//      LibraryLoader   (declared FIRST  -> destroyed LAST)
//      ShutdownGuard   (declared SECOND -> destroyed SECOND)
//
//  C++ destroys automatic objects in reverse order of declaration, so any
//  exit path (normal return, early return, stack unwinding from an
//  exception) runs:
//
//      ~ShutdownGuard()   -> LF_Shutdown
//      ~LibraryLoader()   -> LF_FreeLibrary
//
//  exactly matching the required sequence. This process owns no App and no
//  long-lived DataHandle, so no explicit LF_FreeApp / LF_FreeData step is
//  required.
// =============================================================================

#include "LingoFuse.hpp"

#include <atomic>
#include <chrono>
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
#include <utility>
#include <vector>

namespace {

    /* ---------------------------------------------------------------------------
     * Configuration
     * ------------------------------------------------------------------------- */

    constexpr const char* kTargetApp = "demo";
    constexpr const char* kEndpoint = "ipc:cross";

    constexpr int         kWorkerThreads = 32;      // concurrent caller threads
    constexpr int         kTestSeconds = 10;      // total load-test duration
    constexpr int         kCallTimeoutMs = 1000;    // per-call timeout
    constexpr int         kPauseMillis = 1;       // pause between iterations

    // Log one iteration out of every N. With 32 threads running at
    // ~1000 calls/s each, printing every call would make the log I/O itself
    // the bottleneck. The Stats counters remain exact regardless of N.
    constexpr std::uint64_t kLogEveryNthCall = 5000;

    constexpr int         kNumberMin = 1;
    constexpr int         kNumberMax = 1000;

    /* ---------------------------------------------------------------------------
     * Thread-safe line output
     * ---------------------------------------------------------------------------
     * Builds the whole line in an ostringstream (no lock held), then emits it
     * in one std::cout call under a process-wide mutex. The lock is held for
     * the shortest possible time and no formatting happens inside it.
     * ------------------------------------------------------------------------- */

    std::mutex& log_mutex() {
        static std::mutex m;
        return m;
    }

    template <typename... Args>
    void log_line(Args&&... args) {
        std::ostringstream oss;
        // C++17 fold expression: expands to (oss << arg0), (oss << arg1), ...
        (void)((oss << std::forward<Args>(args)), ...);

        std::lock_guard<std::mutex> lock(log_mutex());
        std::cout << oss.str() << '\n';
    }

    /* ---------------------------------------------------------------------------
     * Aggregate statistics
     * ---------------------------------------------------------------------------
     * All counters are atomic and updated with memory_order_relaxed: they are
     * independent of each other and only read AFTER all worker threads have
     * been joined, so no ordering guarantees are required between them.
     * ------------------------------------------------------------------------- */

    struct Stats {
        std::atomic<std::uint64_t> total_calls{ 0 };
        std::atomic<std::uint64_t> success_calls{ 0 };
        std::atomic<std::uint64_t> failed_calls{ 0 };
        std::atomic<std::uint64_t> add_calls{ 0 };
        std::atomic<std::uint64_t> inv_seri_calls{ 0 };

        Stats() = default;
        Stats(const Stats&) = delete;
        Stats& operator=(const Stats&) = delete;
    };

    /* ------------------------------------------------------------------------
     *  ShutdownGuard - RAII wrapper for lingofuse::shutdown()
     * ------------------------------------------------------------------------
     *  Calls lingofuse::shutdown() when it leaves scope. Declared AFTER the
     *  LibraryLoader, so the destruction order is:
     *
     *      ShutdownGuard destructor -> LF_Shutdown
     *      LibraryLoader destructor -> LF_FreeLibrary
     *
     *  This guarantees the required cleanup sequence (Pascal LF-CLEAN-001)
     *  on every exit path, including early returns and stack unwinding
     *  triggered by exceptions.
     *
     *  lingofuse::shutdown() is idempotent and safe to call even when the
     *  framework was never fully started (e.g., before LF_PrepareDone).
     * ---------------------------------------------------------------------- */
    struct ShutdownGuard {
        ~ShutdownGuard() {
            try {
                lingofuse::shutdown();
            }
            catch (...) {
                // Destructors must never throw. LF_Shutdown is documented
                // as safe to call multiple times, but we still swallow any
                // unexpected C++ exception from the wrapper.
            }
        }
    };

    /* ---------------------------------------------------------------------------
     * Remote call wrappers
     * ------------------------------------------------------------------------- */

     /**
      * @brief Invoke the remote "add" API.
      * @return The sum on success, std::nullopt on timeout or failure.
      */
    std::optional<std::int32_t> remoteAdd(std::int32_t a, std::int32_t b) {
        lingofuse::DataHandle param("add");
        param.write(a);
        param.write(b);

        auto response = lingofuse::tryCall(kTargetApp, param, kCallTimeoutMs);
        if (!response) return std::nullopt;

        std::int32_t result = 0;
        if (!response->read(result)) return std::nullopt;
        return result;
    }

    /**
     * @brief Invoke the remote "inv_seri" API and format the reply.
     * @return A human-readable string on success, std::nullopt on failure.
     */
    std::optional<std::string> remoteInvSeri() {
        const std::uint8_t  b = 200;
        const std::uint16_t w = 0x10;
        const std::uint32_t c = 0x2F;
        const std::uint64_t u64 = 0x3F;
        const std::string   s = "hello world";
        const float         f = 3.14f;

        lingofuse::DataHandle param("inv_seri");
        param.write(b);
        param.write(w);
        param.write(c);
        param.write(u64);
        param.write(s);
        param.write(f);

        auto response = lingofuse::tryCall(kTargetApp, param, kCallTimeoutMs);
        if (!response) return std::nullopt;

        float         rf = 0.0f;
        std::string   rs;
        std::uint64_t ru64 = 0;
        std::uint32_t rc = 0;
        std::uint16_t rw = 0;
        std::uint8_t  rb = 0;

        if (!response->read(rf) ||
            !response->read(rs) ||
            !response->read(ru64) ||
            !response->read(rc) ||
            !response->read(rw) ||
            !response->read(rb)) {
            return std::nullopt;
        }

        std::ostringstream oss;
        oss << "reply: [" << static_cast<int>(rb) << ", " << rw << ", " << rc
            << ", " << ru64 << ", \"" << rs << "\", " << rf << "]"
            << "  original: [" << static_cast<int>(b) << ", " << w << ", " << c
            << ", " << u64 << ", \"" << s << "\", " << f << "]";
        return oss.str();
    }

    /* ---------------------------------------------------------------------------
     * Worker thread body
     * ---------------------------------------------------------------------------
     * Each worker keeps a private iteration counter used purely to decide
     * whether the current iteration should be logged. The aggregate counters
     * in Stats are updated unconditionally and are exact.
     * ------------------------------------------------------------------------- */

    void worker(int index,
        const std::atomic<bool>& stop_flag,
        Stats& stats) {
        std::mt19937 rng(static_cast<std::uint32_t>(index) ^
            static_cast<std::uint32_t>(
                std::chrono::steady_clock::now()
                .time_since_epoch()
                .count()));

        std::uniform_int_distribution<int> which(0, 1);
        std::uniform_int_distribution<int> num(kNumberMin, kNumberMax);

        std::uint64_t iter = 0;
        while (!stop_flag.load(std::memory_order_relaxed)) {
            ++iter;
            const bool do_log = (iter % kLogEveryNthCall == 0);

            if (which(rng) == 0) {
                const int a = num(rng);
                const int b = num(rng);
                const auto result = remoteAdd(a, b);

                stats.total_calls.fetch_add(1, std::memory_order_relaxed);
                stats.add_calls.fetch_add(1, std::memory_order_relaxed);

                if (result) {
                    stats.success_calls.fetch_add(1, std::memory_order_relaxed);
                    if (do_log) {
                        log_line("[Call ", index, "] add(",
                            a, ", ", b, ") = ", *result);
                    }
                }
                else {
                    stats.failed_calls.fetch_add(1, std::memory_order_relaxed);
                    if (do_log) {
                        log_line("[Call ", index, "] add(",
                            a, ", ", b, ") timed out or failed.");
                    }
                }
            }
            else {
                const auto result = remoteInvSeri();

                stats.total_calls.fetch_add(1, std::memory_order_relaxed);
                stats.inv_seri_calls.fetch_add(1, std::memory_order_relaxed);

                if (result) {
                    stats.success_calls.fetch_add(1, std::memory_order_relaxed);
                    if (do_log) {
                        log_line("[Call ", index, "] ", *result);
                    }
                }
                else {
                    stats.failed_calls.fetch_add(1, std::memory_order_relaxed);
                    if (do_log) {
                        log_line("[Call ", index,
                            "] inv_seri timed out or failed.");
                    }
                }
            }

            if (kPauseMillis > 0) {
                std::this_thread::sleep_for(
                    std::chrono::milliseconds(kPauseMillis));
            }
        }
    }

} // namespace

/* ============================================================================
 *  main
 * ============================================================================ */

int main() {
    std::cout << "=== Cross Call (Client) ===" << std::endl;

    try {
        // Load the dynamic library (reference-counted RAII).
        // Declared FIRST -> destroyed LAST.
        lingofuse::LibraryLoader loader;

        // RAII guard for LF_Shutdown.
        // Declared SECOND -> destroyed SECOND, i.e. before the LibraryLoader
        // destructor runs. Any exit path below (including early returns and
        // exceptions) triggers LF_Shutdown followed by LF_FreeLibrary.
        ShutdownGuard shutdown_guard;

        // Connect as a pure consumer; pass nullptr for the app handle.
        lingofuse::resetPrepare();

        const int client_tag =
            lingofuse::prepareClient(kEndpoint, nullptr);
        if (client_tag < 0) {
            std::cerr << "[FATAL] LF_PrepareClient failed for "
                << kEndpoint
                << " (duplicate or invalid address)."
                << std::endl;
            return EXIT_FAILURE;
        }

        const int ready = lingofuse::prepareDone();
        if (ready != 1) {
            std::cerr << "[FATAL] LF_PrepareDone returned " << ready
                << " (expected 1). Check the library's console "
                "output for details."
                << std::endl;
            return EXIT_FAILURE;
        }

        std::cout << "[Call] Connected to " << kEndpoint
            << ". Starting " << kTestSeconds
            << "-second load test with " << kWorkerThreads
            << " threads..." << std::endl;

        // Launch worker threads.
        //
        // std::thread decay-copies its arguments, so the shared objects must
        // be passed through std::ref / std::cref to prevent an attempted copy
        // (Stats contains atomics and is not copyable).
        Stats stats;
        std::atomic<bool> stop_flag{ false };
        std::vector<std::thread> threads;
        threads.reserve(kWorkerThreads);

        const auto start_time = std::chrono::steady_clock::now();

        for (int i = 0; i < kWorkerThreads; ++i) {
            threads.emplace_back(worker,
                i,
                std::cref(stop_flag),
                std::ref(stats));
        }

        // Run for the configured duration.
        std::this_thread::sleep_for(std::chrono::seconds(kTestSeconds));
        stop_flag.store(true, std::memory_order_relaxed);

        // Join all workers.
        for (auto& t : threads) {
            if (t.joinable()) t.join();
        }

        const auto end_time = std::chrono::steady_clock::now();

        // Snapshot the counters now that all workers have stopped.
        const auto total = stats.total_calls.load(std::memory_order_relaxed);
        const auto success = stats.success_calls.load(std::memory_order_relaxed);
        const auto failed = stats.failed_calls.load(std::memory_order_relaxed);
        const auto add_calls = stats.add_calls.load(std::memory_order_relaxed);
        const auto inv_seri_calls =
            stats.inv_seri_calls.load(std::memory_order_relaxed);

        const double elapsed_s = std::chrono::duration<double>(
            end_time - start_time).count();
        const double success_rate =
            (total > 0) ? (100.0 * static_cast<double>(success) /
                static_cast<double>(total))
            : 0.0;
        const double throughput =
            (elapsed_s > 0.0) ? (static_cast<double>(total) / elapsed_s) : 0.0;
        const double success_throughput =
            (elapsed_s > 0.0) ? (static_cast<double>(success) / elapsed_s) : 0.0;

        // Summary. Single-threaded at this point, so std::cout is safe.
        std::cout << '\n'
            << "[Call] Load test summary\n"
            << "         duration          : " << elapsed_s << " s\n"
            << "         total calls       : " << total << '\n'
            << "         success           : " << success
            << " (" << success_rate << " %)\n"
            << "         failed            : " << failed << '\n'
            << "         add calls         : " << add_calls << '\n'
            << "         inv_seri calls    : " << inv_seri_calls << '\n'
            << "         throughput        : " << throughput
            << " calls/s\n"
            << "         success throughput: " << success_throughput
            << " calls/s\n"
            << std::endl;

        std::cout << "[Call] Press Enter to exit..." << std::endl;

        // Stop the network loop. LF_Shutdown and LF_FreeLibrary will run
        // automatically when the automatic objects leave their scope.
        lingofuse::exitMainThread();

    } // <- ~ShutdownGuard(): LF_Shutdown
      // <- ~LibraryLoader(): LF_FreeLibrary

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

    std::cout << "[Call] Bye." << std::endl;
    return EXIT_SUCCESS;
}