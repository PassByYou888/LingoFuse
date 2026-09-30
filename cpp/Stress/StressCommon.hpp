// =============================================================================
//  StressCommon.hpp
// -----------------------------------------------------------------------------
//  Shared definitions for the LingoFuse stress test suite.
//
//  This header is included by StressClient.cpp and StressMonitor.cpp.
//  It defines:
//
//      - Well-known LingoFuse names:
//            StressSvc / StressMon / report / ipc:stress
//      - The ClientReport record sent from client to monitor
//      - Binary serialisation helpers (write_report / read_report)
//      - Portable helpers (get_current_pid / now_ms)
//
//  The transport is the LingoFuse mesh itself: the client issues
//  LF_Notify("StressMon", param) once per second, and the monitor receives
//  it through a registered Notify API ("report"). No filesystem is used.
//
//  Note on the ClientReport layout:
//      Fields are written and read in a fixed order. Adding or reordering
//      fields requires updating BOTH write_report and read_report in the
//      same commit, otherwise the two sides lose sync.
// =============================================================================

#pragma once

#include "LingoFuse.hpp"

#include <chrono>
#include <cstdint>

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
    inline constexpr const char* kEndpoint    = "ipc:stress";
    inline constexpr const char* kServiceApp  = "StressSvc";
    inline constexpr const char* kMonitorApp  = "StressMon";
    inline constexpr const char* kMonitorApi  = "report";

    // -------------------------------------------------------------------------
    //  ClientReport record
    // -------------------------------------------------------------------------
    //  Transmitted as a fixed-layout binary blob (little-endian), matching
    //  the DataHandle::write<T> / read<T> contract.
    // -------------------------------------------------------------------------
    struct ClientReport {
        std::uint32_t pid            = 0;
        std::uint64_t timestamp_ms   = 0;
        std::uint64_t total_calls    = 0;
        std::uint64_t success_calls  = 0;
        std::uint64_t failure_calls  = 0;
        std::uint64_t echo_calls     = 0;
        std::uint64_t add_calls      = 0;
        std::uint64_t hash_calls     = 0;
        std::uint64_t leaked_calls   = 0;   // calls in which we deliberately
                                            //   did NOT free the DataHandles
        std::uint64_t leaked_handles = 0;   // total handles leaked so far
                                            //   (input + result per leak call)
        std::int32_t  running        = 0;   // 1 while the client is active
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
                std::chrono::system_clock::now().time_since_epoch())
                .count());
    }

    // -------------------------------------------------------------------------
    //  Serialisation
    // -------------------------------------------------------------------------
    inline bool write_report(lingofuse::DataHandle& h, const ClientReport& r) {
        try {
            h.write(r.pid);
            h.write(r.timestamp_ms);
            h.write(r.total_calls);
            h.write(r.success_calls);
            h.write(r.failure_calls);
            h.write(r.echo_calls);
            h.write(r.add_calls);
            h.write(r.hash_calls);
            h.write(r.leaked_calls);
            h.write(r.leaked_handles);
            h.write(r.running);
            return true;
        } catch (...) {
            return false;
        }
    }

    inline bool read_report(lingofuse::DataHandle& h, ClientReport& r) {
        try {
            return h.read(r.pid)
                && h.read(r.timestamp_ms)
                && h.read(r.total_calls)
                && h.read(r.success_calls)
                && h.read(r.failure_calls)
                && h.read(r.echo_calls)
                && h.read(r.add_calls)
                && h.read(r.hash_calls)
                && h.read(r.leaked_calls)
                && h.read(r.leaked_handles)
                && h.read(r.running);
        } catch (...) {
            return false;
        }
    }

} // namespace stress