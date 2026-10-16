// =============================================================================
// lf_bridge.cpp
// -----------------------------------------------------------------------------
// C++ implementation layer for the LingoFuse R bridge. (v2.0)
//
// Compiled as C++17 by Rtools g++. Does NOT include any R header.
//
// Version history
// ---------------
//   v1.0  Initial release: STEP 1-3b (build probes, runtime loading,
//         DataHandle / AppHandle, network preparation, app-name
//         invocation, callee job queue).
//
//   v2.0  Full coverage of the 59-symbol C ABI, plus a modern
//         asynchronous layer.
//
//         New in v2.0:
//           - UID addressing (call / notify / sequenced_notify + checks)
//           - P2PName addressing (call / notify / sequenced_notify + checks)
//           - Process-wide P2P registration namespace
//           - Asynchronous calls (6 variants) with explicit lifetime
//           - Side data extraction (sender UID / P2P name)
//           - Network events
//           - Options / status / generate_app_name / bind /
//             unregister / data_set_size / data_get_buffer
//
// Asynchronous lifetime contract
// ------------------------------
// LF_Async_Call* cannot be cancelled. When the R side gives up on a
// request, the framework will still invoke the ctypes callback when
// (or if) the response arrives. To make this safe, the bridge
// NEVER frees the callback trampoline early; the trampoline is a
// static function pointer inside this DLL, so it remains valid for
// the process lifetime. Per-request state (a small AsyncSlot) lives
// in an unordered_map keyed by callback_id.
//
//     dispatch success -> slot inserted, callback live on C side
//     dispatch failure -> slot never inserted, callback never fires
//
//     R-side timeout / give-up:
//         lf_impl_async_release(id) marks the slot abandoned.
//         A late callback still fires, but its result is dropped
//         instead of being enqueued. The slot is removed either by
//         the trampoline (when it fires) or at shutdown.
//
//     normal completion:
//         The trampoline enqueues an AsyncResult job and removes
//         the slot. The R side receives the result via lf_poll.
//
// Every trampoline is a noexcept boundary. std::bad_alloc from a
// Job or std::string allocation is caught and translated into a
// wire-level error response (or silently dropped for async / event
// jobs).
// =============================================================================

#include "lf_r_shim.h"
#include "lf_loader.h"

#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstdint>
#include <cstring>
#include <deque>
#include <memory>
#include <mutex>
#include <string>
#include <unordered_map>

// =============================================================================
// Module state
// =============================================================================

namespace {

// -----------------------------------------------------------------------------
// UID as a by-value struct
// -----------------------------------------------------------------------------
// The C ABI declares the UID parameter as a 32-byte Pascal array
// (TP2P_UID___). On x64 that aggregate is classified MEMORY by the
// psABI and is passed on the stack. The matching C representation
// is therefore a struct with a single 32-byte array member.
struct TP2P_UID_t {
    std::uint8_t bytes[32];
};

static inline TP2P_UID_t uid_from_bytes(const std::uint8_t* src)
{
    TP2P_UID_t u;
    if (src != nullptr) std::memcpy(u.bytes, src, 32);
    else                std::memset(u.bytes, 0, 32);
    return u;
}

// -----------------------------------------------------------------------------
// Callback types
// -----------------------------------------------------------------------------
using FnCallCallback    = void(*)(void*, void*, void*);
using FnNotifyCallback  = void(*)(void*, void*);
using FnAsyncCallback   = void(*)(void*, void*);
using FnNetEventCb      = void(*)(const char*);

// -----------------------------------------------------------------------------
// Runtime function table
// -----------------------------------------------------------------------------
struct LfRuntime {
    lf::Loader loader;
    std::string last_error;

    // ---- v1.0: DataHandle ----
    using FnCreateData   = void*(*)(const char*);
    using FnFreeData     = void (*)(void*);
    using FnWriteBuffer  = std::int64_t(*)(void*, const void*, std::int64_t);
    using FnReadBuffer   = std::int64_t(*)(void*, void*, std::int64_t);
    using FnGetPos       = std::int64_t(*)(void*);
    using FnSetPos       = void (*)(void*, std::int64_t);
    using FnGetSize      = std::int64_t(*)(void*);
    using FnGetBuffer    = void*(*)(void*);
    using FnSetSize      = void (*)(void*, std::int64_t);

    // ---- v1.0: AppHandle ----
    using FnCreateApp    = void*(*)(const char*, const char*);
    using FnFreeApp      = void (*)(void*);
    using FnGetAppName   = const char*(*)(void*);
    using FnBindApp      = int (*)(void*);
    using FnUnregister   = int (*)(void*, const char*);
    using FnGenerateName = const char*(*)(void);

    // ---- v1.0: network preparation ----
    using FnResetPrepare    = void (*)(void);
    using FnPrepareService  = int  (*)(const char*, const char*);
    using FnPrepareClient   = int  (*)(const char*, void*);
    using FnPrepareDone     = int  (*)(void);
    using FnExitMainThread  = void (*)(void);
    using FnCheckMainThread = int  (*)(void);
    using FnCheckApp        = int  (*)(const char*);
    using FnCheckApi        = int  (*)(const char*, const char*);

    // ---- v1.0: invocation ----
    using FnCall            = void*(*)(const char*, void*, std::uint64_t);
    using FnNotify          = void (*)(const char*, void*);
    using FnSequencedNotify = void (*)(const char*, void*);

    // ---- v2.0: UID invocation ----
    using FnUidCall             = void*(*)(TP2P_UID_t, void*, std::uint64_t);
    using FnUidNotify           = void (*)(TP2P_UID_t, void*);
    using FnUidSequencedNotify  = void (*)(TP2P_UID_t, void*);
    using FnCheckUid            = int  (*)(TP2P_UID_t);
    using FnCheckUidApi         = int  (*)(TP2P_UID_t, const char*);

    // ---- v2.0: P2PName invocation ----
    using FnP2PNameCall            = void*(*)(const char*, void*, std::uint64_t);
    using FnP2PNameNotify          = void (*)(const char*, void*);
    using FnP2PNameSequencedNotify = void (*)(const char*, void*);
    using FnCheckP2PName           = int  (*)(const char*);
    using FnCheckP2PNameApi        = int  (*)(const char*, const char*);

    // ---- v2.0: local execution ----
    using FnLocalCall   = void*(*)(void*, void*);
    using FnLocalNotify = void (*)(void*, void*);

    // ---- v2.0: options ----
    using FnSetOption = void (*)(const char*, const char*);
    using FnGetOption = const char*(*)(const char*);

    // ---- v2.0: status ----
    using FnGetStatusCount = int         (*)(void);
    using FnGetStatus      = const char* (*)(void);
    using FnPostStatus     = void        (*)(const char*);

    // ---- v2.0: P2P registration ----
    using FnRegisterP2PCall   = int (*)(const char*, const char*, void*, FnCallCallback);
    using FnRegisterP2PNotify = int (*)(const char*, const char*, void*, FnNotifyCallback);
    using FnUnregisterP2P     = int (*)(const char*);

    // ---- v1.0: callee registration ----
    using FnRegisterCall   = int (*)(void*, const char*, const char*, void*, FnCallCallback);
    using FnRegisterNotify = int (*)(void*, const char*, const char*, void*, FnNotifyCallback);

    // ---- v2.0: async invocation (6 variants) ----
    using FnAsyncCall               = int (*)(const char*, void*, void*, FnAsyncCallback);
    using FnAsyncSequencedCall      = int (*)(const char*, void*, void*, FnAsyncCallback);
    using FnUidAsyncCall            = int (*)(TP2P_UID_t, void*, void*, FnAsyncCallback);
    using FnUidAsyncSequencedCall   = int (*)(TP2P_UID_t, void*, void*, FnAsyncCallback);
    using FnP2PNameAsyncCall        = int (*)(const char*, void*, void*, FnAsyncCallback);
    using FnP2PNameAsyncSequencedCall = int (*)(const char*, void*, void*, FnAsyncCallback);

    // ---- v2.0: side data ----
    using FnGetP2PUID  = void*(*)(void*);       // returns ^TUID___
    using FnGetP2PName = const char*(*)(void*);

    // ---- v2.0: network events ----
    using FnSetNetworkEvent = void (*)(FnNetEventCb, FnNetEventCb);

    // ---- v1.0: shutdown ----
    using FnShutdown = void (*)(void);

    // ---- Members (v1.0) ----
    FnCreateData      CreateData          = nullptr;
    FnCreateData      CreateDataPermanent = nullptr;
    FnFreeData        FreeData            = nullptr;
    FnWriteBuffer     WriteBuffer         = nullptr;
    FnReadBuffer      ReadBuffer          = nullptr;
    FnGetPos          GetPos              = nullptr;
    FnSetPos          SetPos              = nullptr;
    FnGetSize         GetSize             = nullptr;
    FnGetBuffer       GetBuffer           = nullptr;
    FnSetSize         SetSize             = nullptr;

    FnCreateApp    CreateApp    = nullptr;
    FnFreeApp      FreeApp      = nullptr;
    FnGetAppName   GetAppName   = nullptr;
    FnBindApp      BindApp      = nullptr;
    FnUnregister   Unregister   = nullptr;
    FnGenerateName GenerateName = nullptr;

    FnResetPrepare    ResetPrepare    = nullptr;
    FnPrepareService  PrepareService  = nullptr;
    FnPrepareClient   PrepareClient   = nullptr;
    FnPrepareDone     PrepareDone     = nullptr;
    FnExitMainThread  ExitMainThread  = nullptr;
    FnCheckMainThread CheckMainThread = nullptr;
    FnCheckApp        CheckApp        = nullptr;
    FnCheckApi        CheckApi        = nullptr;

    FnCall            Call            = nullptr;
    FnNotify          Notify          = nullptr;
    FnSequencedNotify SequencedNotify = nullptr;

    // ---- Members (v2.0) ----
    FnUidCall             UidCall             = nullptr;
    FnUidNotify           UidNotify           = nullptr;
    FnUidSequencedNotify  UidSequencedNotify  = nullptr;
    FnCheckUid            CheckUid            = nullptr;
    FnCheckUidApi         CheckUidApi         = nullptr;

    FnP2PNameCall            P2PNameCall            = nullptr;
    FnP2PNameNotify          P2PNameNotify          = nullptr;
    FnP2PNameSequencedNotify P2PNameSequencedNotify = nullptr;
    FnCheckP2PName           CheckP2PName           = nullptr;
    FnCheckP2PNameApi        CheckP2PNameApi        = nullptr;

    FnLocalCall   LocalCall   = nullptr;
    FnLocalNotify LocalNotify = nullptr;

    FnSetOption SetOption = nullptr;
    FnGetOption GetOption = nullptr;

    FnGetStatusCount GetStatusCount = nullptr;
    FnGetStatus      GetStatus      = nullptr;
    FnPostStatus     PostStatus     = nullptr;

    FnRegisterP2PCall   RegisterP2PCall   = nullptr;
    FnRegisterP2PNotify RegisterP2PNotify = nullptr;
    FnUnregisterP2P     UnregisterP2P     = nullptr;

    FnRegisterCall   RegisterCall   = nullptr;
    FnRegisterNotify RegisterNotify = nullptr;

    FnAsyncCall               AsyncCall               = nullptr;
    FnAsyncSequencedCall      AsyncSequencedCall      = nullptr;
    FnUidAsyncCall            UidAsyncCall            = nullptr;
    FnUidAsyncSequencedCall   UidAsyncSequencedCall   = nullptr;
    FnP2PNameAsyncCall        P2PNameAsyncCall        = nullptr;
    FnP2PNameAsyncSequencedCall P2PNameAsyncSequencedCall = nullptr;

    FnGetP2PUID  GetP2PUID  = nullptr;
    FnGetP2PName GetP2PName = nullptr;

    FnSetNetworkEvent SetNetworkEvent = nullptr;

    FnShutdown Shutdown = nullptr;

    // ---- Lifecycle ----

    void clear()
    {
        CreateData          = nullptr;
        CreateDataPermanent = nullptr;
        FreeData            = nullptr;
        WriteBuffer         = nullptr;
        ReadBuffer          = nullptr;
        GetPos              = nullptr;
        SetPos              = nullptr;
        GetSize             = nullptr;
        GetBuffer           = nullptr;
        SetSize             = nullptr;

        CreateApp    = nullptr;
        FreeApp      = nullptr;
        GetAppName   = nullptr;
        BindApp      = nullptr;
        Unregister   = nullptr;
        GenerateName = nullptr;

        ResetPrepare    = nullptr;
        PrepareService  = nullptr;
        PrepareClient   = nullptr;
        PrepareDone     = nullptr;
        ExitMainThread  = nullptr;
        CheckMainThread = nullptr;
        CheckApp        = nullptr;
        CheckApi        = nullptr;

        Call            = nullptr;
        Notify          = nullptr;
        SequencedNotify = nullptr;

        UidCall             = nullptr;
        UidNotify           = nullptr;
        UidSequencedNotify  = nullptr;
        CheckUid            = nullptr;
        CheckUidApi         = nullptr;

        P2PNameCall            = nullptr;
        P2PNameNotify          = nullptr;
        P2PNameSequencedNotify = nullptr;
        CheckP2PName           = nullptr;
        CheckP2PNameApi        = nullptr;

        LocalCall   = nullptr;
        LocalNotify = nullptr;

        SetOption = nullptr;
        GetOption = nullptr;

        GetStatusCount = nullptr;
        GetStatus      = nullptr;
        PostStatus     = nullptr;

        RegisterP2PCall   = nullptr;
        RegisterP2PNotify = nullptr;
        UnregisterP2P     = nullptr;

        RegisterCall   = nullptr;
        RegisterNotify = nullptr;

        AsyncCall               = nullptr;
        AsyncSequencedCall      = nullptr;
        UidAsyncCall            = nullptr;
        UidAsyncSequencedCall   = nullptr;
        P2PNameAsyncCall        = nullptr;
        P2PNameAsyncSequencedCall = nullptr;

        GetP2PUID  = nullptr;
        GetP2PName = nullptr;

        SetNetworkEvent = nullptr;

        Shutdown = nullptr;
    }

    bool resolveAll()
    {
        try {
            // ---- v1.0 (required) ----
            CreateData          = loader.get<FnCreateData>("LF_CreateData");
            CreateDataPermanent = loader.get<FnCreateData>("LF_CreateData_Permanent");
            FreeData            = loader.get<FnFreeData>("LF_FreeData");
            WriteBuffer         = loader.get<FnWriteBuffer>("LF_WriteBuffer");
            ReadBuffer          = loader.get<FnReadBuffer>("LF_ReadBuffer");
            GetPos              = loader.get<FnGetPos>("LF_GetPos");
            SetPos              = loader.get<FnSetPos>("LF_SetPos");
            GetSize             = loader.get<FnGetSize>("LF_GetSize");
            GetBuffer           = loader.get<FnGetBuffer>("LF_GetBuffer");
            SetSize             = loader.get<FnSetSize>("LF_SetSize");

            CreateApp    = loader.get<FnCreateApp>("LF_CreateApp");
            FreeApp      = loader.get<FnFreeApp>("LF_FreeApp");
            GetAppName   = loader.get<FnGetAppName>("LF_Get_AppName");
            BindApp      = loader.get<FnBindApp>("LF_BindApp");
            Unregister   = loader.get<FnUnregister>("LF_Unregister");
            GenerateName = loader.get<FnGenerateName>("LF_Generate_AppName");

            ResetPrepare    = loader.get<FnResetPrepare>("LF_ResetPrepare");
            PrepareService  = loader.get<FnPrepareService>("LF_PrepareService");
            PrepareClient   = loader.get<FnPrepareClient>("LF_PrepareClient");
            PrepareDone     = loader.get<FnPrepareDone>("LF_PrepareDone");
            ExitMainThread  = loader.get<FnExitMainThread>("LF_ExitMainThread");
            CheckMainThread = loader.get<FnCheckMainThread>("LF_CheckMainThread");
            CheckApp        = loader.get<FnCheckApp>("LF_CheckApp");
            CheckApi        = loader.get<FnCheckApi>("LF_CheckApi");

            Call            = loader.get<FnCall>("LF_Call");
            Notify          = loader.get<FnNotify>("LF_Notify");
            SequencedNotify = loader.get<FnSequencedNotify>("LF_Sequenced_Notify");

            // ---- v2.0 ----
            UidCall             = loader.get<FnUidCall>("LF_UID_Call");
            UidNotify           = loader.get<FnUidNotify>("LF_UID_Notify");
            UidSequencedNotify  = loader.get<FnUidSequencedNotify>("LF_UID_Sequenced_Notify");
            CheckUid            = loader.get<FnCheckUid>("LF_Check_UID");
            CheckUidApi         = loader.get<FnCheckUidApi>("LF_Check_UID_Api");

            P2PNameCall            = loader.get<FnP2PNameCall>("LF_P2PNAME_Call");
            P2PNameNotify          = loader.get<FnP2PNameNotify>("LF_P2PNAME_Notify");
            P2PNameSequencedNotify = loader.get<FnP2PNameSequencedNotify>("LF_P2PNAME_Sequenced_Notify");
            CheckP2PName           = loader.get<FnCheckP2PName>("LF_Check_P2PNAME");
            CheckP2PNameApi        = loader.get<FnCheckP2PNameApi>("LF_Check_P2PNAME_Api");

            LocalCall   = loader.get<FnLocalCall>("LF_LocalCall");
            LocalNotify = loader.get<FnLocalNotify>("LF_LocalNotify");

            SetOption = loader.get<FnSetOption>("LF_SetOption");
            GetOption = loader.get<FnGetOption>("LF_GetOption");

            GetStatusCount = loader.get<FnGetStatusCount>("LF_GetStatusCount");
            GetStatus      = loader.get<FnGetStatus>("LF_GetStatus");
            PostStatus     = loader.get<FnPostStatus>("LF_PostStatus");

            RegisterP2PCall   = loader.get<FnRegisterP2PCall>("LF_Register_P2P_Call");
            RegisterP2PNotify = loader.get<FnRegisterP2PNotify>("LF_Register_P2P_Notify");
            UnregisterP2P     = loader.get<FnUnregisterP2P>("LF_Unregister_P2P");

            RegisterCall   = loader.get<FnRegisterCall>("LF_RegisterCall");
            RegisterNotify = loader.get<FnRegisterNotify>("LF_RegisterNotify");

            AsyncCall                 = loader.get<FnAsyncCall>("LF_Async_Call");
            AsyncSequencedCall        = loader.get<FnAsyncSequencedCall>("LF_Async_Sequenced_Call");
            UidAsyncCall              = loader.get<FnUidAsyncCall>("LF_UID_Async_Call");
            UidAsyncSequencedCall     = loader.get<FnUidAsyncSequencedCall>("LF_UID_Async_Sequenced_Call");
            P2PNameAsyncCall          = loader.get<FnP2PNameAsyncCall>("LF_P2PNAME_Async_Call");
            P2PNameAsyncSequencedCall = loader.get<FnP2PNameAsyncSequencedCall>("LF_P2PNAME_Async_Sequenced_Call");

            GetP2PUID  = loader.get<FnGetP2PUID>("LF_Get_P2P_UID");
            GetP2PName = loader.get<FnGetP2PName>("LF_Get_P2P_Name");

            SetNetworkEvent = loader.get<FnSetNetworkEvent>("LF_Set_Network_Event");

            Shutdown = loader.get<FnShutdown>("LF_Shutdown");
            return true;
        } catch (const std::exception& e) {
            last_error = e.what();
            return false;
        }
    }

    bool ready() const noexcept
    {
        return loader.is_loaded()
            && CreateData != nullptr
            && Call       != nullptr;
    }
};

LfRuntime g_rt;

// -----------------------------------------------------------------------------
// Thread-local return buffers
// -----------------------------------------------------------------------------
// The runtime returns pointers to transient buffers that are released
// after a few seconds. Every returned const char* therefore points
// to a thread-local std::string that the caller must copy before the
// next call on the same thread.
thread_local std::string t_call_result;
thread_local std::string t_call_bin_result;
thread_local std::string t_get_option_result;
thread_local std::string t_generate_name_result;
thread_local std::string t_get_status_result;

// -----------------------------------------------------------------------------
// Job kinds and registry spaces
// -----------------------------------------------------------------------------
enum class JobKind : int {
    Call        = 0,
    Notify      = 1,
    AsyncResult = 2,
    NetEvent    = 3,
};

enum class RegistrySpace : int {
    AppBound = 0,
    P2P      = 1,
};

// -----------------------------------------------------------------------------
// Job
// -----------------------------------------------------------------------------
// A Job carries one inbound request (Call / Notify) or one outbound
// event (AsyncResult / NetEvent) between a C4 worker thread and the
// R main thread.
//
// Reference counting
// ------------------
//   bidirectional = true  (Call / Notify):
//       starts with refs = 2. One reference for the worker thread,
//       one for the R side. The Job is destroyed when the second
//       reference is dropped, whichever side drops it last.
//
//   bidirectional = false (AsyncResult / NetEvent):
//       starts with refs = 1. The worker thread does not wait for a
//       response; the R side owns the only reference and destroys
//       the Job when it processes (or drops) the event.
//
// The done flag
// -------------
//   For bidirectional jobs, `done` is set by lf_impl_job_complete /
//   lf_impl_job_abandon (R side) or by the worker thread when it
//   times out. It is used to synchronise the two sides.
//
//   For unidirectional jobs, `done` is irrelevant; the worker side
//   never touches the Job again after pushing it.
struct Job {
    std::atomic<int>        refs;
    bool                    bidirectional;

    std::mutex              mtx;
    std::condition_variable cv;
    bool                    done = false;

    JobKind                 kind  = JobKind::Call;
    RegistrySpace           space = RegistrySpace::AppBound;
    bool                    is_call = true;

    std::string             api_name;
    std::string             input;
    std::string             output;

    // Side data (Call / Notify jobs only)
    bool                    sender_uid_valid = false;
    std::uint8_t            sender_uid[32]   = {0};
    std::string             sender_p2p_name;

    // Async result (AsyncResult jobs)
    std::int64_t            callback_id    = 0;
    std::string             async_result;
    std::string             async_error;
    int                     async_error_kind = 0;

    // Network event (NetEvent jobs)
    std::string             event_kind;  // "connect" / "disconnect"
    std::string             event_addr;

    // Pointer to the LingoFuse output handle (Call jobs)
    void*                   lf_output = nullptr;

    explicit Job(bool bidir)
        : refs(bidir ? 2 : 1)
        , bidirectional(bidir)
    {
    }

    void release() noexcept
    {
        if (refs.fetch_sub(1, std::memory_order_acq_rel) == 1) {
            delete this;
        }
    }
};

// -----------------------------------------------------------------------------
// Job queue
// -----------------------------------------------------------------------------
struct JobQueue {
    std::mutex                       mtx;
    std::condition_variable          cv;
    std::deque<Job*>                 q;
    std::atomic<std::int64_t>        timeout_ms{5000};

    void push(Job* j)
    {
        {
            std::lock_guard<std::mutex> lk(mtx);
            q.push_back(j);
        }
        cv.notify_one();
    }

    Job* pop_wait(std::int64_t wait_ms)
    {
        std::unique_lock<std::mutex> lk(mtx);
        if (wait_ms <= 0) {
            if (q.empty()) return nullptr;
            Job* j = q.front();
            q.pop_front();
            return j;
        }
        if (!cv.wait_for(lk, std::chrono::milliseconds(wait_ms),
                         [this]{ return !q.empty(); })) {
            return nullptr;
        }
        Job* j = q.front();
        q.pop_front();
        return j;
    }

    std::size_t size()
    {
        std::lock_guard<std::mutex> lk(mtx);
        return q.size();
    }
};

JobQueue g_jobs;

// -----------------------------------------------------------------------------
// Async slots
// -----------------------------------------------------------------------------
// One slot per outstanding asynchronous request. The slot is a
// tiny bookkeeping object: it exists so that the R side can
// communicate "I have given up on this request" to the trampoline
// without racing against a callback that might fire concurrently.
struct AsyncSlot {
    std::int64_t     id = 0;
    std::atomic<bool> abandoned{false};
};

std::mutex                                              g_async_mtx;
std::unordered_map<std::int64_t, std::unique_ptr<AsyncSlot>>
                                                        g_async_slots;
std::atomic<std::int64_t>                               g_async_next_id{1};

// -----------------------------------------------------------------------------
// Registration name keep-alive
// -----------------------------------------------------------------------------
// The runtime stores the `trigger` pointer we pass to LF_RegisterCall
// and passes it back to the trampoline on every invocation. That
// pointer must therefore remain valid for the process lifetime.
std::mutex                                              g_reg_mtx;
std::unordered_map<std::string, std::unique_ptr<std::string>>
                                                        g_reg_names;

std::string* keep_name(const char* api_name) noexcept
{
    try {
        std::lock_guard<std::mutex> lk(g_reg_mtx);
        std::string key = api_name ? api_name : "";
        auto it = g_reg_names.find(key);
        if (it != g_reg_names.end()) return it->second.get();
        auto p = std::unique_ptr<std::string>(new std::string(key));
        std::string* raw = p.get();
        g_reg_names.emplace(key, std::move(p));
        return raw;
    } catch (...) {
        return nullptr;
    }
}

// -----------------------------------------------------------------------------
// Helpers
// -----------------------------------------------------------------------------

void drain_handle_into_string(void* hnd, std::string& out)
{
    out.clear();
    if (hnd == nullptr) return;
    std::int64_t sz = g_rt.GetSize(hnd);
    if (sz <= 0) return;
    g_rt.SetPos(hnd, 0);
    try {
        out.resize(static_cast<std::size_t>(sz));
    } catch (...) {
        out.clear();
        return;
    }
    std::int64_t got = g_rt.ReadBuffer(hnd, &out[0], sz);
    if (got < 0) got = 0;
    try {
        out.resize(static_cast<std::size_t>(got));
    } catch (...) {
        out.clear();
    }
    // Deliberately do NOT strip a trailing NUL. Binary payloads may
    // legitimately end with 0x00. The R dispatch layer strips the
    // NUL for string-mode jobs and keeps it verbatim for binary.
}

void write_string_to_handle(void* hnd, const std::string& value)
{
    if (hnd == nullptr) return;
    if (!value.empty()) {
        const std::int64_t want =
            static_cast<std::int64_t>(value.size());
        const std::int64_t wrote =
            g_rt.WriteBuffer(hnd, value.data(), want);
        if (wrote != want) return;
    }
    const char nul = 0;
    g_rt.WriteBuffer(hnd, &nul, 1);
}

// Write a NUL-terminated string-mode payload to a freshly created
// DataHandle. Returns true on success.
bool write_payload_string(void* hnd, const char* payload)
{
    if (hnd == nullptr) return false;
    const char* p = payload ? payload : "";
    const std::size_t n = std::strlen(p);
    if (n > 0) {
        if (g_rt.WriteBuffer(hnd, p, static_cast<std::int64_t>(n))
            != static_cast<std::int64_t>(n)) {
            return false;
        }
    }
    const char nul = 0;
    return g_rt.WriteBuffer(hnd, &nul, 1) == 1;
}

// Write a binary payload (no NUL terminator) to a DataHandle.
bool write_payload_bin(void* hnd, const void* req, std::int64_t req_len)
{
    if (hnd == nullptr) return false;
    if (req_len <= 0) return true;
    if (req == nullptr) return false;
    return g_rt.WriteBuffer(hnd, req, req_len) == req_len;
}

// String-mode call shared by lf_impl_call / lf_impl_uid_call /
// lf_impl_p2pname_call. The caller supplies a lambda that issues
// the underlying LF_* call.
template <typename IssueFn>
const char* do_string_call(const char* api_name,
                           const char* payload,
                           std::uint64_t timeout_ms,
                           std::int64_t* out_len,
                           IssueFn&& issue)
{
    if (out_len) *out_len = 0;
    if (!g_rt.ready() || api_name == nullptr) {
        g_rt.last_error = "runtime not loaded or null argument";
        return nullptr;
    }

    try {
        void* hnd = g_rt.CreateData(api_name);
        if (!hnd) {
            g_rt.last_error = "LF_CreateData returned NULL";
            return nullptr;
        }
        if (!write_payload_string(hnd, payload)) {
            g_rt.FreeData(hnd);
            g_rt.last_error = "failed to write request payload";
            return nullptr;
        }

        void* res = issue(hnd, timeout_ms);
        g_rt.FreeData(hnd);

        if (!res) {
            g_rt.last_error = "call returned NULL";
            return nullptr;
        }

        std::string tmp;
        drain_handle_into_string(res, tmp);
        g_rt.FreeData(res);
        t_call_result = std::move(tmp);

        if (out_len) *out_len = static_cast<std::int64_t>(t_call_result.size());
        return t_call_result.c_str();
    } catch (const std::exception& e) {
        g_rt.last_error = std::string("call: ") + e.what();
        return nullptr;
    } catch (...) {
        g_rt.last_error = "call: unknown exception";
        return nullptr;
    }
}

// Binary-mode call shared by lf_impl_call_bin / lf_impl_uid_call_bin /
// lf_impl_p2pname_call_bin.
template <typename IssueFn>
const char* do_binary_call(const char* api_name,
                           const void* req, std::int64_t req_len,
                           std::uint64_t timeout_ms,
                           std::int64_t* out_len,
                           IssueFn&& issue)
{
    if (out_len) *out_len = 0;
    if (!g_rt.ready() || api_name == nullptr) {
        g_rt.last_error = "runtime not loaded or null argument";
        return nullptr;
    }
    if (req == nullptr && req_len > 0) {
        g_rt.last_error = "req is NULL with positive length";
        return nullptr;
    }
    if (req_len < 0) {
        g_rt.last_error = "req_len is negative";
        return nullptr;
    }

    try {
        void* hnd = g_rt.CreateData(api_name);
        if (!hnd) {
            g_rt.last_error = "LF_CreateData returned NULL";
            return nullptr;
        }
        if (!write_payload_bin(hnd, req, req_len)) {
            g_rt.FreeData(hnd);
            g_rt.last_error = "failed to write binary request payload";
            return nullptr;
        }

        void* res = issue(hnd, timeout_ms);
        g_rt.FreeData(hnd);

        if (!res) {
            g_rt.last_error = "call returned NULL";
            return nullptr;
        }

        t_call_bin_result.clear();
        std::int64_t sz = g_rt.GetSize(res);
        if (sz > 0) {
            g_rt.SetPos(res, 0);
            t_call_bin_result.resize(static_cast<std::size_t>(sz));
            std::int64_t got = g_rt.ReadBuffer(res, &t_call_bin_result[0], sz);
            if (got < 0) got = 0;
            t_call_bin_result.resize(static_cast<std::size_t>(got));
        }
        g_rt.FreeData(res);

        if (out_len) *out_len =
            static_cast<std::int64_t>(t_call_bin_result.size());
        return t_call_bin_result.empty() ? "" : t_call_bin_result.data();
    } catch (const std::exception& e) {
        g_rt.last_error = std::string("call_bin: ") + e.what();
        return nullptr;
    } catch (...) {
        g_rt.last_error = "call_bin: unknown exception";
        return nullptr;
    }
}

// Notify helper. The payload may be a NUL-terminated string or a
// raw byte buffer.
template <typename IssueFn>
int do_notify(const char* api_name,
              const char* payload,
              IssueFn&& issue)
{
    if (!g_rt.ready() || api_name == nullptr) return -1;
    void* hnd = g_rt.CreateData(api_name);
    if (!hnd) return -1;
    if (!write_payload_string(hnd, payload)) {
        g_rt.FreeData(hnd);
        return -1;
    }
    issue(hnd);
    g_rt.FreeData(hnd);
    return 0;
}

template <typename IssueFn>
int do_notify_bin(const char* api_name,
                  const void* req, std::int64_t req_len,
                  IssueFn&& issue)
{
    if (!g_rt.ready() || api_name == nullptr) return -1;
    if (req == nullptr && req_len > 0) return -1;
    if (req_len < 0) return -1;

    void* hnd = g_rt.CreateData(api_name);
    if (!hnd) return -1;
    if (!write_payload_bin(hnd, req, req_len)) {
        g_rt.FreeData(hnd);
        return -1;
    }
    issue(hnd);
    g_rt.FreeData(hnd);
    return 0;
}

// =============================================================================
// Trampolines
// =============================================================================
// All of these run on a C4 worker thread. They MUST NOT touch the R
// interpreter. They may only touch the Job queue and the runtime
// function table.

extern "C" void call_trampoline(void* trigger, void* input, void* output)
{
    Job* j = nullptr;
    try {
        j = new Job(true);
        auto* name = static_cast<std::string*>(trigger);
        j->kind     = JobKind::Call;
        j->space    = RegistrySpace::AppBound;
        j->is_call  = true;
        j->api_name = name ? *name : "";

        // Extract side data BEFORE draining input. The runtime
        // injects the sender identity into the payload header, and
        // the corresponding accessors read it from the input handle
        // only; once we drain the handle, the information is gone.
        if (input != nullptr) {
            if (g_rt.GetP2PUID != nullptr) {
                void* uid_ptr = g_rt.GetP2PUID(input);
                if (uid_ptr != nullptr) {
                    std::memcpy(j->sender_uid, uid_ptr, 32);
                    j->sender_uid_valid = true;
                }
            }
            if (g_rt.GetP2PName != nullptr) {
                const char* p = g_rt.GetP2PName(input);
                if (p != nullptr) j->sender_p2p_name = p;
            }
        }

        drain_handle_into_string(input, j->input);
        j->lf_output = output;
    } catch (...) {
        delete j;
        write_string_to_handle(
            output, "{\"error\":\"failed to allocate job\"}");
        return;
    }

    try {
        g_jobs.push(j);
    } catch (...) {
        write_string_to_handle(
            output, "{\"error\":\"job queue push failed\"}");
        delete j;
        return;
    }

    const std::int64_t t =
        g_jobs.timeout_ms.load(std::memory_order_relaxed);
    bool timed_out = false;

    try {
        std::unique_lock<std::mutex> lk(j->mtx);
        if (t <= 0) {
            j->cv.wait(lk, [j]{ return j->done; });
        } else {
            if (!j->cv.wait_for(lk, std::chrono::milliseconds(t),
                                [j]{ return j->done; })) {
                j->done = true;
                timed_out = true;
            }
        }
    } catch (...) {
        j->done = true;
        timed_out = true;
    }

    if (timed_out) {
        write_string_to_handle(
            output, "{\"error\":\"R handler timeout\"}");
    } else {
        write_string_to_handle(output, j->output);
    }

    j->release();
}

extern "C" void notify_trampoline(void* trigger, void* input)
{
    Job* j = nullptr;
    try {
        j = new Job(true);
        auto* name = static_cast<std::string*>(trigger);
        j->kind     = JobKind::Notify;
        j->space    = RegistrySpace::AppBound;
        j->is_call  = false;
        j->api_name = name ? *name : "";

        if (input != nullptr) {
            if (g_rt.GetP2PUID != nullptr) {
                void* uid_ptr = g_rt.GetP2PUID(input);
                if (uid_ptr != nullptr) {
                    std::memcpy(j->sender_uid, uid_ptr, 32);
                    j->sender_uid_valid = true;
                }
            }
            if (g_rt.GetP2PName != nullptr) {
                const char* p = g_rt.GetP2PName(input);
                if (p != nullptr) j->sender_p2p_name = p;
            }
        }

        drain_handle_into_string(input, j->input);
    } catch (...) {
        delete j;
        return;
    }

    try {
        g_jobs.push(j);
    } catch (...) {
        delete j;
        return;
    }

    const std::int64_t t =
        g_jobs.timeout_ms.load(std::memory_order_relaxed);
    try {
        std::unique_lock<std::mutex> lk(j->mtx);
        if (t <= 0) {
            j->cv.wait(lk, [j]{ return j->done; });
        } else {
            if (!j->cv.wait_for(lk, std::chrono::milliseconds(t),
                                [j]{ return j->done; })) {
                j->done = true;
            }
        }
    } catch (...) {
        j->done = true;
    }

    j->release();
}

extern "C" void p2p_call_trampoline(void* trigger, void* input, void* output)
{
    Job* j = nullptr;
    try {
        j = new Job(true);
        auto* name = static_cast<std::string*>(trigger);
        j->kind     = JobKind::Call;
        j->space    = RegistrySpace::P2P;
        j->is_call  = true;
        j->api_name = name ? *name : "";

        if (input != nullptr) {
            if (g_rt.GetP2PUID != nullptr) {
                void* uid_ptr = g_rt.GetP2PUID(input);
                if (uid_ptr != nullptr) {
                    std::memcpy(j->sender_uid, uid_ptr, 32);
                    j->sender_uid_valid = true;
                }
            }
            if (g_rt.GetP2PName != nullptr) {
                const char* p = g_rt.GetP2PName(input);
                if (p != nullptr) j->sender_p2p_name = p;
            }
        }

        drain_handle_into_string(input, j->input);
        j->lf_output = output;
    } catch (...) {
        delete j;
        write_string_to_handle(
            output, "{\"error\":\"failed to allocate job\"}");
        return;
    }

    try {
        g_jobs.push(j);
    } catch (...) {
        write_string_to_handle(
            output, "{\"error\":\"job queue push failed\"}");
        delete j;
        return;
    }

    const std::int64_t t =
        g_jobs.timeout_ms.load(std::memory_order_relaxed);
    bool timed_out = false;

    try {
        std::unique_lock<std::mutex> lk(j->mtx);
        if (t <= 0) {
            j->cv.wait(lk, [j]{ return j->done; });
        } else {
            if (!j->cv.wait_for(lk, std::chrono::milliseconds(t),
                                [j]{ return j->done; })) {
                j->done = true;
                timed_out = true;
            }
        }
    } catch (...) {
        j->done = true;
        timed_out = true;
    }

    if (timed_out) {
        write_string_to_handle(
            output, "{\"error\":\"R handler timeout\"}");
    } else {
        write_string_to_handle(output, j->output);
    }

    j->release();
}

extern "C" void p2p_notify_trampoline(void* trigger, void* input)
{
    Job* j = nullptr;
    try {
        j = new Job(true);
        auto* name = static_cast<std::string*>(trigger);
        j->kind     = JobKind::Notify;
        j->space    = RegistrySpace::P2P;
        j->is_call  = false;
        j->api_name = name ? *name : "";

        if (input != nullptr) {
            if (g_rt.GetP2PUID != nullptr) {
                void* uid_ptr = g_rt.GetP2PUID(input);
                if (uid_ptr != nullptr) {
                    std::memcpy(j->sender_uid, uid_ptr, 32);
                    j->sender_uid_valid = true;
                }
            }
            if (g_rt.GetP2PName != nullptr) {
                const char* p = g_rt.GetP2PName(input);
                if (p != nullptr) j->sender_p2p_name = p;
            }
        }

        drain_handle_into_string(input, j->input);
    } catch (...) {
        delete j;
        return;
    }

    try {
        g_jobs.push(j);
    } catch (...) {
        delete j;
        return;
    }

    const std::int64_t t =
        g_jobs.timeout_ms.load(std::memory_order_relaxed);
    try {
        std::unique_lock<std::mutex> lk(j->mtx);
        if (t <= 0) {
            j->cv.wait(lk, [j]{ return j->done; });
        } else {
            if (!j->cv.wait_for(lk, std::chrono::milliseconds(t),
                                [j]{ return j->done; })) {
                j->done = true;
            }
        }
    } catch (...) {
        j->done = true;
    }

    j->release();
}

extern "C" void async_result_trampoline(void* data, void* raw_result)
{
    // `data` is the callback_id encoded as a void*. See
    // lf_impl_async_call for how it is constructed.
    const std::int64_t id =
        static_cast<std::int64_t>(reinterpret_cast<std::intptr_t>(data));
    if (id <= 0) return;

    // The result handle is only valid for the duration of the
    // callback. Copy its bytes into a local string immediately.
    std::string result_bytes;
    if (raw_result != nullptr) {
        drain_handle_into_string(raw_result, result_bytes);
    }

    // Look up the slot. If it has already been removed (the R side
    // released it earlier, or a duplicate callback arrived), drop
    // the result silently.
    std::unique_ptr<AsyncSlot> slot;
    {
        std::lock_guard<std::mutex> lk(g_async_mtx);
        auto it = g_async_slots.find(id);
        if (it == g_async_slots.end()) return;
        slot = std::move(it->second);
        g_async_slots.erase(it);
    }

    if (slot->abandoned.load(std::memory_order_acquire)) {
        // R side gave up. Drop the result; the slot unique_ptr
        // frees the bookkeeping object.
        return;
    }

    Job* j = nullptr;
    try {
        j = new Job(false);
        j->kind          = JobKind::AsyncResult;
        j->callback_id   = id;
        j->async_result  = std::move(result_bytes);
        j->async_error_kind = 0;
    } catch (...) {
        delete j;
        return;
    }

    try {
        g_jobs.push(j);
    } catch (...) {
        delete j;
    }
}

extern "C" void net_connect_trampoline(const char* addr)
{
    Job* j = nullptr;
    try {
        j = new Job(false);
        j->kind       = JobKind::NetEvent;
        j->event_kind = "connect";
        j->event_addr = addr ? addr : "";
    } catch (...) {
        delete j;
        return;
    }
    try {
        g_jobs.push(j);
    } catch (...) {
        delete j;
    }
}

extern "C" void net_disconnect_trampoline(const char* addr)
{
    Job* j = nullptr;
    try {
        j = new Job(false);
        j->kind       = JobKind::NetEvent;
        j->event_kind = "disconnect";
        j->event_addr = addr ? addr : "";
    } catch (...) {
        delete j;
        return;
    }
    try {
        g_jobs.push(j);
    } catch (...) {
        delete j;
    }
}

} // namespace

// =============================================================================
// SECTION 1 - Build chain probes
// =============================================================================

extern "C" const char* lf_impl_ping(void)     { return "pong"; }
extern "C" const char* lf_impl_version(void)  { return "2.0.0"; }
extern "C" const char* lf_impl_stage(void)    { return "step-4-full-abi"; }
extern "C" const char* lf_impl_compiled(void) { return __DATE__ " " __TIME__; }

// =============================================================================
// SECTION 2 - Runtime loading
// =============================================================================

extern "C" int lf_impl_load_library(const char* runtime_dir)
{
    if (runtime_dir == nullptr) {
        g_rt.last_error = "runtime_dir is NULL";
        return 0;
    }
    if (g_rt.ready()) return 1;

    g_rt.clear();
    g_rt.last_error.clear();

    try {
        g_rt.loader.load(std::string(runtime_dir));
    } catch (const std::exception& e) {
        g_rt.last_error = e.what();
        return 0;
    }
    if (!g_rt.resolveAll()) {
        g_rt.loader.unload();
        g_rt.clear();
        return 0;
    }
    return 1;
}

extern "C" void lf_impl_unload_library(void)
{
    // Deliberately do NOT call lf::Loader::unload() here. See
    // lf_loader.h for the full rationale: LingoFuse starts
    // background threads at load time and cannot be safely
    // unmapped until process exit.
    g_rt.clear();
    g_rt.loader.detach();
    g_rt.last_error.clear();

    // Drop every remaining async slot. Any callback that fires
    // after this point will find no slot and drop its result.
    {
        std::lock_guard<std::mutex> lk(g_async_mtx);
        g_async_slots.clear();
    }
}

extern "C" int lf_impl_is_loaded(void)
{
    return g_rt.ready() ? 1 : 0;
}

extern "C" const char* lf_impl_loaded_path(void)
{
    if (!g_rt.loader.is_loaded()) return "";
    return g_rt.loader.loaded_path().c_str();
}

extern "C" const char* lf_impl_last_error(void)
{
    return g_rt.last_error.c_str();
}

// =============================================================================
// SECTION 3 - DataHandle
// =============================================================================

extern "C" void* lf_impl_data_create(const char* api_name)
{
    if (!g_rt.ready() || api_name == nullptr) return nullptr;
    return g_rt.CreateData(api_name);
}

extern "C" void* lf_impl_data_create_permanent(const char* api_name)
{
    if (!g_rt.ready() || api_name == nullptr) return nullptr;
    return g_rt.CreateDataPermanent(api_name);
}

extern "C" void lf_impl_data_free(void* hnd)
{
    if (!g_rt.ready() || hnd == nullptr) return;
    g_rt.FreeData(hnd);
}

extern "C" std::int64_t lf_impl_data_write_buffer(
    void* hnd, const void* buf, std::int64_t len)
{
    if (!g_rt.ready() || hnd == nullptr || buf == nullptr || len < 0) return -1;
    return g_rt.WriteBuffer(hnd, buf, len);
}

extern "C" std::int64_t lf_impl_data_read_buffer(
    void* hnd, void* buf, std::int64_t len)
{
    if (!g_rt.ready() || hnd == nullptr || buf == nullptr || len < 0) return -1;
    return g_rt.ReadBuffer(hnd, buf, len);
}

extern "C" std::int64_t lf_impl_data_get_pos(void* hnd)
{
    if (!g_rt.ready() || hnd == nullptr) return -1;
    return g_rt.GetPos(hnd);
}

extern "C" int lf_impl_data_set_pos(void* hnd, std::int64_t pos)
{
    if (!g_rt.ready() || hnd == nullptr || pos < 0) return -1;
    g_rt.SetPos(hnd, pos);
    return 0;
}

extern "C" std::int64_t lf_impl_data_get_size(void* hnd)
{
    if (!g_rt.ready() || hnd == nullptr) return -1;
    return g_rt.GetSize(hnd);
}

extern "C" void* lf_impl_data_get_buffer(void* hnd)
{
    if (!g_rt.ready() || hnd == nullptr) return nullptr;
    if (g_rt.GetBuffer == nullptr) return nullptr;
    return g_rt.GetBuffer(hnd);
}

extern "C" int lf_impl_data_set_size(void* hnd, std::int64_t size)
{
    if (!g_rt.ready() || hnd == nullptr || size < 0) return -1;
    if (g_rt.SetSize == nullptr) return -1;
    g_rt.SetSize(hnd, size);
    return 0;
}

// =============================================================================
// SECTION 4 - AppHandle
// =============================================================================

extern "C" void* lf_impl_app_create(const char* name, const char* description)
{
    if (!g_rt.ready() || name == nullptr) return nullptr;
    return g_rt.CreateApp(name, description ? description : "");
}

extern "C" void lf_impl_app_free(void* app)
{
    if (!g_rt.ready() || app == nullptr) return;
    g_rt.FreeApp(app);
}

extern "C" const char* lf_impl_app_name(void* app)
{
    if (!g_rt.ready() || app == nullptr) return nullptr;
    return g_rt.GetAppName(app);
}

extern "C" int lf_impl_app_bind(void* app)
{
    if (!g_rt.ready() || app == nullptr) return 0;
    if (g_rt.BindApp == nullptr) return 0;
    return g_rt.BindApp(app);
}

extern "C" int lf_impl_app_unregister(void* app, const char* api_name)
{
    if (!g_rt.ready() || app == nullptr || api_name == nullptr) return 0;
    if (g_rt.Unregister == nullptr) return 0;
    return g_rt.Unregister(app, api_name);
}

extern "C" const char* lf_impl_generate_app_name(void)
{
    if (!g_rt.ready()) return "";
    if (g_rt.GenerateName == nullptr) return "";
    const char* p = g_rt.GenerateName();
    if (p == nullptr) return "";
    // LF_Generate_AppName returns a pointer valid for ~5 seconds.
    // Copy immediately into thread-local storage.
    t_generate_name_result = p;
    return t_generate_name_result.c_str();
}

// =============================================================================
// SECTION 5 - Network preparation
// =============================================================================

extern "C" int lf_impl_reset_prepare(void)
{
    if (!g_rt.ready()) return -1;
    g_rt.ResetPrepare();
    return 0;
}

extern "C" int lf_impl_prepare_client(const char* endpoint)
{
    if (!g_rt.ready() || endpoint == nullptr) return -1;
    return g_rt.PrepareClient(endpoint, nullptr);
}

extern "C" int lf_impl_prepare_client_with_app(
    const char* endpoint, void* app)
{
    if (!g_rt.ready() || endpoint == nullptr) return -1;
    return g_rt.PrepareClient(endpoint, app);
}

extern "C" int lf_impl_prepare_service(
    const char* listen_addr, const char* physics_addr)
{
    if (!g_rt.ready() || listen_addr == nullptr) return -1;
    return g_rt.PrepareService(listen_addr,
                               physics_addr ? physics_addr : listen_addr);
}

extern "C" int lf_impl_prepare_done(void)
{
    if (!g_rt.ready()) return -1;
    return g_rt.PrepareDone();
}

extern "C" void lf_impl_exit_main_thread(void)
{
    if (!g_rt.ready()) return;
    g_rt.ExitMainThread();
}

extern "C" int lf_impl_check_main_thread(void)
{
    if (!g_rt.ready()) return 0;
    return g_rt.CheckMainThread();
}

extern "C" int lf_impl_check_app(const char* app_name)
{
    if (!g_rt.ready() || app_name == nullptr) return 0;
    return g_rt.CheckApp(app_name);
}

extern "C" int lf_impl_check_api(const char* app_name, const char* api_name)
{
    if (!g_rt.ready() || app_name == nullptr || api_name == nullptr) return 0;
    return g_rt.CheckApi(app_name, api_name);
}

// =============================================================================
// SECTION 6 - Remote invocation by App name
// =============================================================================

extern "C" const char* lf_impl_call(
    const char* app_name, const char* api_name, const char* payload,
    std::uint64_t timeout_ms, std::int64_t* out_len)
{
    if (app_name == nullptr) {
        if (out_len) *out_len = 0;
        g_rt.last_error = "app_name is NULL";
        return nullptr;
    }
    return do_string_call(
        api_name, payload, timeout_ms, out_len,
        [&](void* hnd, std::uint64_t t) {
            return g_rt.Call(app_name, hnd, t);
        });
}

extern "C" int lf_impl_notify(
    const char* app_name, const char* api_name, const char* payload)
{
    if (app_name == nullptr) return -1;
    return do_notify(
        api_name, payload,
        [&](void* hnd) { g_rt.Notify(app_name, hnd); });
}

extern "C" int lf_impl_sequenced_notify(
    const char* app_name, const char* api_name, const char* payload)
{
    if (app_name == nullptr) return -1;
    return do_notify(
        api_name, payload,
        [&](void* hnd) { g_rt.SequencedNotify(app_name, hnd); });
}

extern "C" const char* lf_impl_call_bin(
    const char* app_name, const char* api_name,
    const void* req, std::int64_t req_len,
    std::uint64_t timeout_ms, std::int64_t* out_len)
{
    if (app_name == nullptr) {
        if (out_len) *out_len = 0;
        g_rt.last_error = "app_name is NULL";
        return nullptr;
    }
    return do_binary_call(
        api_name, req, req_len, timeout_ms, out_len,
        [&](void* hnd, std::uint64_t t) {
            return g_rt.Call(app_name, hnd, t);
        });
}

extern "C" int lf_impl_notify_bin(
    const char* app_name, const char* api_name,
    const void* req, std::int64_t req_len)
{
    if (app_name == nullptr) return -1;
    return do_notify_bin(
        api_name, req, req_len,
        [&](void* hnd) { g_rt.Notify(app_name, hnd); });
}

// =============================================================================
// SECTION 7 - Remote invocation by UID
// =============================================================================

extern "C" const char* lf_impl_uid_call(
    const std::uint8_t* uid, const char* api_name, const char* payload,
    std::uint64_t timeout_ms, std::int64_t* out_len)
{
    if (uid == nullptr) {
        if (out_len) *out_len = 0;
        g_rt.last_error = "uid is NULL";
        return nullptr;
    }
    if (g_rt.UidCall == nullptr) {
        if (out_len) *out_len = 0;
        g_rt.last_error = "LF_UID_Call not available";
        return nullptr;
    }
    TP2P_UID_t u = uid_from_bytes(uid);
    return do_string_call(
        api_name, payload, timeout_ms, out_len,
        [&](void* hnd, std::uint64_t t) {
            return g_rt.UidCall(u, hnd, t);
        });
}

extern "C" int lf_impl_uid_notify(
    const std::uint8_t* uid, const char* api_name, const char* payload)
{
    if (uid == nullptr) return -1;
    if (g_rt.UidNotify == nullptr) return -1;
    TP2P_UID_t u = uid_from_bytes(uid);
    return do_notify(
        api_name, payload,
        [&](void* hnd) { g_rt.UidNotify(u, hnd); });
}

extern "C" int lf_impl_uid_sequenced_notify(
    const std::uint8_t* uid, const char* api_name, const char* payload)
{
    if (uid == nullptr) return -1;
    if (g_rt.UidSequencedNotify == nullptr) return -1;
    TP2P_UID_t u = uid_from_bytes(uid);
    return do_notify(
        api_name, payload,
        [&](void* hnd) { g_rt.UidSequencedNotify(u, hnd); });
}

extern "C" const char* lf_impl_uid_call_bin(
    const std::uint8_t* uid, const char* api_name,
    const void* req, std::int64_t req_len,
    std::uint64_t timeout_ms, std::int64_t* out_len)
{
    if (uid == nullptr) {
        if (out_len) *out_len = 0;
        g_rt.last_error = "uid is NULL";
        return nullptr;
    }
    if (g_rt.UidCall == nullptr) {
        if (out_len) *out_len = 0;
        g_rt.last_error = "LF_UID_Call not available";
        return nullptr;
    }
    TP2P_UID_t u = uid_from_bytes(uid);
    return do_binary_call(
        api_name, req, req_len, timeout_ms, out_len,
        [&](void* hnd, std::uint64_t t) {
            return g_rt.UidCall(u, hnd, t);
        });
}

extern "C" int lf_impl_uid_notify_bin(
    const std::uint8_t* uid, const char* api_name,
    const void* req, std::int64_t req_len)
{
    if (uid == nullptr) return -1;
    if (g_rt.UidNotify == nullptr) return -1;
    TP2P_UID_t u = uid_from_bytes(uid);
    return do_notify_bin(
        api_name, req, req_len,
        [&](void* hnd) { g_rt.UidNotify(u, hnd); });
}

// =============================================================================
// SECTION 8 - Remote invocation by P2P name
// =============================================================================

extern "C" const char* lf_impl_p2pname_call(
    const char* group_name, const char* api_name, const char* payload,
    std::uint64_t timeout_ms, std::int64_t* out_len)
{
    if (group_name == nullptr) {
        if (out_len) *out_len = 0;
        g_rt.last_error = "group_name is NULL";
        return nullptr;
    }
    if (g_rt.P2PNameCall == nullptr) {
        if (out_len) *out_len = 0;
        g_rt.last_error = "LF_P2PNAME_Call not available";
        return nullptr;
    }
    return do_string_call(
        api_name, payload, timeout_ms, out_len,
        [&](void* hnd, std::uint64_t t) {
            return g_rt.P2PNameCall(group_name, hnd, t);
        });
}

extern "C" int lf_impl_p2pname_notify(
    const char* group_name, const char* api_name, const char* payload)
{
    if (group_name == nullptr) return -1;
    if (g_rt.P2PNameNotify == nullptr) return -1;
    return do_notify(
        api_name, payload,
        [&](void* hnd) { g_rt.P2PNameNotify(group_name, hnd); });
}

extern "C" int lf_impl_p2pname_sequenced_notify(
    const char* group_name, const char* api_name, const char* payload)
{
    if (group_name == nullptr) return -1;
    if (g_rt.P2PNameSequencedNotify == nullptr) return -1;
    return do_notify(
        api_name, payload,
        [&](void* hnd) { g_rt.P2PNameSequencedNotify(group_name, hnd); });
}

extern "C" const char* lf_impl_p2pname_call_bin(
    const char* group_name, const char* api_name,
    const void* req, std::int64_t req_len,
    std::uint64_t timeout_ms, std::int64_t* out_len)
{
    if (group_name == nullptr) {
        if (out_len) *out_len = 0;
        g_rt.last_error = "group_name is NULL";
        return nullptr;
    }
    if (g_rt.P2PNameCall == nullptr) {
        if (out_len) *out_len = 0;
        g_rt.last_error = "LF_P2PNAME_Call not available";
        return nullptr;
    }
    return do_binary_call(
        api_name, req, req_len, timeout_ms, out_len,
        [&](void* hnd, std::uint64_t t) {
            return g_rt.P2PNameCall(group_name, hnd, t);
        });
}

extern "C" int lf_impl_p2pname_notify_bin(
    const char* group_name, const char* api_name,
    const void* req, std::int64_t req_len)
{
    if (group_name == nullptr) return -1;
    if (g_rt.P2PNameNotify == nullptr) return -1;
    return do_notify_bin(
        api_name, req, req_len,
        [&](void* hnd) { g_rt.P2PNameNotify(group_name, hnd); });
}

// =============================================================================
// SECTION 9 - Local execution
// =============================================================================

extern "C" const char* lf_impl_local_call(
    void* app, const char* api_name, const char* payload,
    std::int64_t* out_len)
{
    if (out_len) *out_len = 0;
    if (!g_rt.ready() || app == nullptr || api_name == nullptr) {
        g_rt.last_error = "runtime not loaded or null argument";
        return nullptr;
    }
    if (g_rt.LocalCall == nullptr) {
        g_rt.last_error = "LF_LocalCall not available";
        return nullptr;
    }

    try {
        void* hnd = g_rt.CreateData(api_name);
        if (!hnd) {
            g_rt.last_error = "LF_CreateData returned NULL";
            return nullptr;
        }
        if (!write_payload_string(hnd, payload)) {
            g_rt.FreeData(hnd);
            g_rt.last_error = "failed to write request payload";
            return nullptr;
        }

        void* res = g_rt.LocalCall(app, hnd);
        g_rt.FreeData(hnd);

        if (!res) {
            g_rt.last_error = "LF_LocalCall returned NULL";
            return nullptr;
        }

        std::string tmp;
        drain_handle_into_string(res, tmp);
        g_rt.FreeData(res);
        t_call_result = std::move(tmp);
        if (out_len) *out_len = static_cast<std::int64_t>(t_call_result.size());
        return t_call_result.c_str();
    } catch (const std::exception& e) {
        g_rt.last_error = std::string("local_call: ") + e.what();
        return nullptr;
    } catch (...) {
        g_rt.last_error = "local_call: unknown exception";
        return nullptr;
    }
}

extern "C" int lf_impl_local_notify(
    void* app, const char* api_name, const char* payload)
{
    if (!g_rt.ready() || app == nullptr || api_name == nullptr) return -1;
    if (g_rt.LocalNotify == nullptr) return -1;

    void* hnd = g_rt.CreateData(api_name);
    if (!hnd) return -1;
    if (!write_payload_string(hnd, payload)) {
        g_rt.FreeData(hnd);
        return -1;
    }
    g_rt.LocalNotify(app, hnd);
    g_rt.FreeData(hnd);
    return 0;
}

// =============================================================================
// SECTION 10 - Runtime options
// =============================================================================

extern "C" void lf_impl_set_option(const char* name, const char* value)
{
    if (!g_rt.ready() || name == nullptr) return;
    if (g_rt.SetOption == nullptr) return;
    g_rt.SetOption(name, value ? value : "");
}

extern "C" const char* lf_impl_get_option(const char* name)
{
    if (!g_rt.ready() || name == nullptr) return "";
    if (g_rt.GetOption == nullptr) return "";
    const char* p = g_rt.GetOption(name);
    if (p == nullptr) {
        t_get_option_result.clear();
        return t_get_option_result.c_str();
    }
    // LF_GetOption returns a pointer valid for ~5 seconds.
    t_get_option_result = p;
    return t_get_option_result.c_str();
}

// =============================================================================
// SECTION 11 - Status queue
// =============================================================================

extern "C" int lf_impl_get_status_count(void)
{
    if (!g_rt.ready()) return 0;
    if (g_rt.GetStatusCount == nullptr) return 0;
    return g_rt.GetStatusCount();
}

extern "C" const char* lf_impl_get_status(void)
{
    if (!g_rt.ready()) return "";
    if (g_rt.GetStatus == nullptr) return "";
    const char* p = g_rt.GetStatus();
    if (p == nullptr) {
        t_get_status_result.clear();
        return t_get_status_result.c_str();
    }
    // LF_GetStatus returns a pointer to a 64KB static buffer that is
    // reused by the next call. Copy immediately.
    t_get_status_result = p;
    return t_get_status_result.c_str();
}

extern "C" void lf_impl_post_status(const char* text)
{
    if (!g_rt.ready() || text == nullptr) return;
    if (g_rt.PostStatus == nullptr) return;
    g_rt.PostStatus(text);
}

// =============================================================================
// SECTION 12 - Health checks for UID / P2PName
// =============================================================================

extern "C" int lf_impl_check_uid(const std::uint8_t* uid)
{
    if (!g_rt.ready() || uid == nullptr) return 0;
    if (g_rt.CheckUid == nullptr) return 0;
    TP2P_UID_t u = uid_from_bytes(uid);
    return g_rt.CheckUid(u);
}

extern "C" int lf_impl_check_uid_api(
    const std::uint8_t* uid, const char* api_name)
{
    if (!g_rt.ready() || uid == nullptr || api_name == nullptr) return 0;
    if (g_rt.CheckUidApi == nullptr) return 0;
    TP2P_UID_t u = uid_from_bytes(uid);
    return g_rt.CheckUidApi(u, api_name);
}

extern "C" int lf_impl_check_p2pname(const char* group_name)
{
    if (!g_rt.ready() || group_name == nullptr) return 0;
    if (g_rt.CheckP2PName == nullptr) return 0;
    return g_rt.CheckP2PName(group_name);
}

extern "C" int lf_impl_check_p2pname_api(
    const char* group_name, const char* api_name)
{
    if (!g_rt.ready() || group_name == nullptr || api_name == nullptr) return 0;
    if (g_rt.CheckP2PNameApi == nullptr) return 0;
    return g_rt.CheckP2PNameApi(group_name, api_name);
}

// =============================================================================
// SECTION 13 - Process-wide P2P registration
// =============================================================================

extern "C" int lf_impl_register_p2p_call(
    const char* api_name, const char* description, void* user_trigger)
{
    if (!g_rt.ready() || api_name == nullptr) return 0;
    if (g_rt.RegisterP2PCall == nullptr) return 0;
    (void)user_trigger;

    std::string* name_ptr = keep_name(api_name);
    if (name_ptr == nullptr) {
        g_rt.last_error = "keep_name allocation failed";
        return 0;
    }
    return g_rt.RegisterP2PCall(
        api_name,
        description ? description : "",
        name_ptr,
        p2p_call_trampoline);
}

extern "C" int lf_impl_register_p2p_notify(
    const char* api_name, const char* description, void* user_trigger)
{
    if (!g_rt.ready() || api_name == nullptr) return 0;
    if (g_rt.RegisterP2PNotify == nullptr) return 0;
    (void)user_trigger;

    std::string* name_ptr = keep_name(api_name);
    if (name_ptr == nullptr) {
        g_rt.last_error = "keep_name allocation failed";
        return 0;
    }
    return g_rt.RegisterP2PNotify(
        api_name,
        description ? description : "",
        name_ptr,
        p2p_notify_trampoline);
}

extern "C" int lf_impl_unregister_p2p(const char* api_name)
{
    if (!g_rt.ready() || api_name == nullptr) return 0;
    if (g_rt.UnregisterP2P == nullptr) return 0;
    return g_rt.UnregisterP2P(api_name);
}

// =============================================================================
// SECTION 14 - Callee: job queue and trampolines
// =============================================================================

extern "C" int lf_impl_register_call_raw(
    void* app, const char* api_name, const char* description,
    void* user_trigger)
{
    if (!g_rt.ready() || app == nullptr || api_name == nullptr) return 0;
    (void)user_trigger;

    std::string* name_ptr = keep_name(api_name);
    if (name_ptr == nullptr) {
        g_rt.last_error = "keep_name allocation failed";
        return 0;
    }
    return g_rt.RegisterCall(
        app,
        api_name,
        description ? description : "",
        name_ptr,
        call_trampoline);
}

extern "C" int lf_impl_register_notify_raw(
    void* app, const char* api_name, const char* description,
    void* user_trigger)
{
    if (!g_rt.ready() || app == nullptr || api_name == nullptr) return 0;
    (void)user_trigger;

    std::string* name_ptr = keep_name(api_name);
    if (name_ptr == nullptr) {
        g_rt.last_error = "keep_name allocation failed";
        return 0;
    }
    return g_rt.RegisterNotify(
        app,
        api_name,
        description ? description : "",
        name_ptr,
        notify_trampoline);
}

extern "C" void* lf_impl_poll_job(std::int64_t timeout_ms)
{
    return g_jobs.pop_wait(timeout_ms);
}

extern "C" int lf_impl_job_kind(void* job)
{
    if (job == nullptr) return -1;
    return static_cast<int>(static_cast<Job*>(job)->kind);
}

extern "C" int lf_impl_job_registry_space(void* job)
{
    if (job == nullptr) return 0;
    return static_cast<int>(static_cast<Job*>(job)->space);
}

extern "C" std::int64_t lf_impl_job_get_input(
    void* job, void* buf, std::int64_t cap)
{
    if (job == nullptr || buf == nullptr || cap < 0) return -1;
    Job* j = static_cast<Job*>(job);
    std::int64_t n = static_cast<std::int64_t>(j->input.size());
    if (n > cap) n = cap;
    if (n > 0) std::memcpy(buf, j->input.data(), static_cast<std::size_t>(n));
    return n;
}

extern "C" std::int64_t lf_impl_job_get_input_size(void* job)
{
    if (job == nullptr) return -1;
    return static_cast<std::int64_t>(static_cast<Job*>(job)->input.size());
}

extern "C" const char* lf_impl_job_api_name(void* job)
{
    if (job == nullptr) return nullptr;
    return static_cast<Job*>(job)->api_name.c_str();
}

extern "C" int lf_impl_job_is_call(void* job)
{
    if (job == nullptr) return 0;
    return static_cast<Job*>(job)->is_call ? 1 : 0;
}

extern "C" int lf_impl_job_sender_uid_valid(void* job)
{
    if (job == nullptr) return 0;
    return static_cast<Job*>(job)->sender_uid_valid ? 1 : 0;
}

extern "C" int lf_impl_job_sender_uid(void* job, void* buf, std::int64_t cap)
{
    if (job == nullptr || buf == nullptr || cap < 32) return 0;
    Job* j = static_cast<Job*>(job);
    if (!j->sender_uid_valid) return 0;
    std::memcpy(buf, j->sender_uid, 32);
    return 1;
}

extern "C" const char* lf_impl_job_sender_p2p_name(void* job)
{
    if (job == nullptr) return "";
    return static_cast<Job*>(job)->sender_p2p_name.c_str();
}

extern "C" void lf_impl_job_complete(
    void* job, const void* buf, std::int64_t len)
{
    if (job == nullptr) return;
    Job* j = static_cast<Job*>(job);

    bool was_pending = false;
    {
        std::unique_lock<std::mutex> lk(j->mtx);
        if (!j->done) {
            was_pending = true;
            if (j->is_call && j->bidirectional
                && buf != nullptr && len > 0) {
                try {
                    j->output.assign(
                        static_cast<const char*>(buf),
                        static_cast<std::size_t>(len));
                } catch (...) {
                    j->output.clear();
                }
            }
            j->done = true;
        }
    }

    if (was_pending && j->bidirectional) {
        j->cv.notify_one();
    }

    j->release();
}

extern "C" void lf_impl_job_abandon(void* job)
{
    if (job == nullptr) return;
    Job* j = static_cast<Job*>(job);

    bool was_pending = false;
    {
        std::unique_lock<std::mutex> lk(j->mtx);
        if (!j->done) {
            was_pending = true;
            j->done = true;
        }
    }

    if (was_pending && j->bidirectional) {
        j->cv.notify_one();
    }

    j->release();
}

extern "C" void lf_impl_set_job_timeout_ms(std::int64_t ms)
{
    g_jobs.timeout_ms.store(ms, std::memory_order_relaxed);
}

extern "C" std::int64_t lf_impl_pending_job_count(void)
{
    return static_cast<std::int64_t>(g_jobs.size());
}

// =============================================================================
// SECTION 15 - Asynchronous calls
// =============================================================================

namespace {

// Shared implementation for the six async entry points. `issue_fn`
// is a callable that takes the encoded callback_id (as a void*) and
// the ctypes callback pointer, and returns the C ABI's int result
// code (1 on success, anything else on failure).
template <typename IssueFn>
std::int64_t do_async_dispatch(const char* api_name,
                               const char* payload,
                               std::uint64_t timeout_ms,
                               IssueFn&& issue_fn)
{
    (void)timeout_ms;  // Timeout is enforced in R; the C side has none.
    if (!g_rt.ready() || api_name == nullptr) return 0;

    // Allocate a fresh callback id and slot.
    const std::int64_t id =
        g_async_next_id.fetch_add(1, std::memory_order_relaxed);
    auto slot = std::unique_ptr<AsyncSlot>(new AsyncSlot());
    slot->id = id;

    {
        std::lock_guard<std::mutex> lk(g_async_mtx);
        g_async_slots[id] = std::move(slot);
    }

    // Create the request DataHandle and encode the payload.
    void* hnd = g_rt.CreateData(api_name);
    if (!hnd) {
        std::lock_guard<std::mutex> lk(g_async_mtx);
        g_async_slots.erase(id);
        return 0;
    }
    if (!write_payload_string(hnd, payload)) {
        g_rt.FreeData(hnd);
        std::lock_guard<std::mutex> lk(g_async_mtx);
        g_async_slots.erase(id);
        return 0;
    }

    // Encode the callback id as the opaque data pointer. The C
    // side never dereferences this pointer; it forwards it back to
    // the trampoline verbatim.
    void* user_data = reinterpret_cast<void*>(
        static_cast<std::intptr_t>(id));

    int ret = 0;
    try {
        ret = issue_fn(hnd, user_data, async_result_trampoline);
    } catch (...) {
        ret = 0;
    }
    g_rt.FreeData(hnd);

    if (ret != 1) {
        // Dispatch failed; the callback will never fire. Remove
        // the slot so it does not leak.
        std::lock_guard<std::mutex> lk(g_async_mtx);
        g_async_slots.erase(id);
        return 0;
    }

    return id;
}

} // namespace

extern "C" std::int64_t lf_impl_async_call(
    const char* app_name, const char* api_name,
    const char* payload, std::uint64_t timeout_ms)
{
    if (app_name == nullptr) return 0;
    if (g_rt.AsyncCall == nullptr) return 0;
    return do_async_dispatch(
        api_name, payload, timeout_ms,
        [&](void* hnd, void* data, FnAsyncCallback cb) {
            return g_rt.AsyncCall(app_name, hnd, data, cb);
        });
}

extern "C" std::int64_t lf_impl_async_sequenced_call(
    const char* app_name, const char* api_name,
    const char* payload, std::uint64_t timeout_ms)
{
    if (app_name == nullptr) return 0;
    if (g_rt.AsyncSequencedCall == nullptr) return 0;
    return do_async_dispatch(
        api_name, payload, timeout_ms,
        [&](void* hnd, void* data, FnAsyncCallback cb) {
            return g_rt.AsyncSequencedCall(app_name, hnd, data, cb);
        });
}

extern "C" std::int64_t lf_impl_uid_async_call(
    const std::uint8_t* uid, const char* api_name,
    const char* payload, std::uint64_t timeout_ms)
{
    if (uid == nullptr) return 0;
    if (g_rt.UidAsyncCall == nullptr) return 0;
    TP2P_UID_t u = uid_from_bytes(uid);
    return do_async_dispatch(
        api_name, payload, timeout_ms,
        [&](void* hnd, void* data, FnAsyncCallback cb) {
            return g_rt.UidAsyncCall(u, hnd, data, cb);
        });
}

extern "C" std::int64_t lf_impl_uid_async_sequenced_call(
    const std::uint8_t* uid, const char* api_name,
    const char* payload, std::uint64_t timeout_ms)
{
    if (uid == nullptr) return 0;
    if (g_rt.UidAsyncSequencedCall == nullptr) return 0;
    TP2P_UID_t u = uid_from_bytes(uid);
    return do_async_dispatch(
        api_name, payload, timeout_ms,
        [&](void* hnd, void* data, FnAsyncCallback cb) {
            return g_rt.UidAsyncSequencedCall(u, hnd, data, cb);
        });
}

extern "C" std::int64_t lf_impl_p2pname_async_call(
    const char* group_name, const char* api_name,
    const char* payload, std::uint64_t timeout_ms)
{
    if (group_name == nullptr) return 0;
    if (g_rt.P2PNameAsyncCall == nullptr) return 0;
    return do_async_dispatch(
        api_name, payload, timeout_ms,
        [&](void* hnd, void* data, FnAsyncCallback cb) {
            return g_rt.P2PNameAsyncCall(group_name, hnd, data, cb);
        });
}

extern "C" std::int64_t lf_impl_p2pname_async_sequenced_call(
    const char* group_name, const char* api_name,
    const char* payload, std::uint64_t timeout_ms)
{
    if (group_name == nullptr) return 0;
    if (g_rt.P2PNameAsyncSequencedCall == nullptr) return 0;
    return do_async_dispatch(
        api_name, payload, timeout_ms,
        [&](void* hnd, void* data, FnAsyncCallback cb) {
            return g_rt.P2PNameAsyncSequencedCall(group_name, hnd, data, cb);
        });
}

extern "C" std::int64_t lf_impl_job_callback_id(void* job)
{
    if (job == nullptr) return 0;
    return static_cast<Job*>(job)->callback_id;
}

extern "C" const char* lf_impl_job_result(void* job)
{
    if (job == nullptr) return "";
    return static_cast<Job*>(job)->async_result.c_str();
}

extern "C" const char* lf_impl_job_error(void* job)
{
    if (job == nullptr) return "";
    return static_cast<Job*>(job)->async_error.c_str();
}

extern "C" int lf_impl_job_error_kind(void* job)
{
    if (job == nullptr) return 3;
    return static_cast<Job*>(job)->async_error_kind;
}

extern "C" void lf_impl_async_release(std::int64_t callback_id)
{
    std::unique_ptr<AsyncSlot> slot;
    {
        std::lock_guard<std::mutex> lk(g_async_mtx);
        auto it = g_async_slots.find(callback_id);
        if (it == g_async_slots.end()) return;
        slot = std::move(it->second);
        g_async_slots.erase(it);
    }
    // Mark the slot abandoned. The slot unique_ptr still owns the
    // object; if the trampoline fires later, it will find no
    // matching entry in the map and drop its result. If the
    // trampoline already fired, this is a no-op.
    slot->abandoned.store(true, std::memory_order_release);
}

extern "C" std::int64_t lf_impl_async_slot_count(void)
{
    std::lock_guard<std::mutex> lk(g_async_mtx);
    return static_cast<std::int64_t>(g_async_slots.size());
}

// =============================================================================
// SECTION 16 - Network events
// =============================================================================

extern "C" void lf_impl_set_network_event(
    FnNetEventCb on_connect,
    FnNetEventCb on_disconnect)
{
    if (!g_rt.ready()) return;
    if (g_rt.SetNetworkEvent == nullptr) return;
    g_rt.SetNetworkEvent(on_connect, on_disconnect);
}

extern "C" const char* lf_impl_job_event_kind(void* job)
{
    if (job == nullptr) return "";
    return static_cast<Job*>(job)->event_kind.c_str();
}

extern "C" const char* lf_impl_job_event_addr(void* job)
{
    if (job == nullptr) return "";
    return static_cast<Job*>(job)->event_addr.c_str();
}

// =============================================================================
// SECTION 17 - Shutdown
// =============================================================================

extern "C" void lf_impl_shutdown(void)
{
    if (!g_rt.ready()) return;
    g_rt.Shutdown();
}