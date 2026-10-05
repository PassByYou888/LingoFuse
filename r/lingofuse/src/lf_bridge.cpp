// =============================================================================
// lf_bridge.cpp
// -----------------------------------------------------------------------------
// C++ implementation layer for the LingoFuse R bridge.
//
// STEP 1 : build chain probes
// STEP 2 : runtime loading + DataHandle / AppHandle
// STEP 3a: network preparation + remote invocation (caller)
// STEP 3b: callee -- job queue + trampoline callbacks
//
// Compiled as C++17 by Rtools g++. Does NOT include any R header.
//
// JOB LIFETIME
// ------------
// A Job is created by a C4 worker thread and handed to the R main
// thread through a lock-protected queue. It is referenced by both
// sides simultaneously and is destroyed when the LAST reference is
// dropped. This eliminates the use-after-free that a plain
// "delete" in the worker's timeout branch used to create: the R
// side could still be holding the pointer and accessing its mutex
// long after the worker had given up on it.
//
// Both trampolines are noexcept boundaries. Every C++ exception
// that could escape into the C stack (std::bad_alloc from a Job or
// std::string allocation, in particular) is caught and translated
// into a wire-level error response.
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

struct LfRuntime {
    lf::Loader loader;
    std::string last_error;

    // STEP 2
    using FnCreateData   = void* (*)(const char*);
    using FnFreeData     = void  (*)(void*);
    using FnWriteBuffer  = std::int64_t (*)(void*, const void*, std::int64_t);
    using FnReadBuffer   = std::int64_t (*)(void*, void*, std::int64_t);
    using FnGetPos       = std::int64_t (*)(void*);
    using FnSetPos       = void  (*)(void*, std::int64_t);
    using FnGetSize      = std::int64_t (*)(void*);
    using FnGetBuffer    = void* (*)(void*);
    using FnCreateApp    = void* (*)(const char*, const char*);
    using FnFreeApp      = void  (*)(void*);
    using FnGetAppName   = const char* (*)(void*);

    // STEP 3a
    using FnResetPrepare    = void (*)(void);
    using FnPrepareService  = int  (*)(const char*, const char*);
    using FnPrepareClient   = int  (*)(const char*, void*);
    using FnPrepareDone     = int  (*)(void);
    using FnExitMainThread  = void (*)(void);
    using FnCheckMainThread = int  (*)(void);
    using FnCheckApp        = int  (*)(const char*);
    using FnCheckApi        = int  (*)(const char*, const char*);
    using FnCall            = void*(*)(const char*, void*, std::uint64_t);
    using FnNotify          = void (*)(const char*, void*);
    using FnSequencedNotify = void (*)(const char*, void*);
    using FnShutdown        = void (*)(void);
    using FnSetOption       = void (*)(const char*, const char*);

    // STEP 3b
    using FnRegisterCall    = int  (*)(void*, const char*, const char*, void*,
                                       void (*)(void*, void*, void*));
    using FnRegisterNotify  = int  (*)(void*, const char*, const char*, void*,
                                       void (*)(void*, void*));
    using FnSetNetworkEvent = void (*)(void (*)(const char*),
                                       void (*)(const char*));

    FnCreateData      CreateData          = nullptr;
    FnCreateData      CreateDataPermanent = nullptr;
    FnFreeData        FreeData            = nullptr;
    FnWriteBuffer     WriteBuffer         = nullptr;
    FnReadBuffer      ReadBuffer          = nullptr;
    FnGetPos          GetPos              = nullptr;
    FnSetPos          SetPos              = nullptr;
    FnGetSize         GetSize             = nullptr;
    FnGetBuffer       GetBuffer           = nullptr;
    FnCreateApp       CreateApp           = nullptr;
    FnFreeApp         FreeApp             = nullptr;
    FnGetAppName      GetAppName          = nullptr;

    FnResetPrepare    ResetPrepare        = nullptr;
    FnPrepareService  PrepareService      = nullptr;
    FnPrepareClient   PrepareClient       = nullptr;
    FnPrepareDone     PrepareDone         = nullptr;
    FnExitMainThread  ExitMainThread      = nullptr;
    FnCheckMainThread CheckMainThread     = nullptr;
    FnCheckApp        CheckApp            = nullptr;
    FnCheckApi        CheckApi            = nullptr;
    FnCall            Call                = nullptr;
    FnNotify          Notify              = nullptr;
    FnSequencedNotify SequencedNotify     = nullptr;
    FnShutdown        Shutdown            = nullptr;
    FnSetOption       SetOption           = nullptr;

    FnRegisterCall    RegisterCall        = nullptr;
    FnRegisterNotify  RegisterNotify      = nullptr;
    FnSetNetworkEvent SetNetworkEvent     = nullptr;

    void clear() {
        CreateData          = nullptr;
        CreateDataPermanent = nullptr;
        FreeData            = nullptr;
        WriteBuffer         = nullptr;
        ReadBuffer          = nullptr;
        GetPos              = nullptr;
        SetPos              = nullptr;
        GetSize             = nullptr;
        GetBuffer           = nullptr;
        CreateApp           = nullptr;
        FreeApp             = nullptr;
        GetAppName          = nullptr;

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
        Shutdown        = nullptr;
        SetOption       = nullptr;

        RegisterCall    = nullptr;
        RegisterNotify  = nullptr;
        SetNetworkEvent = nullptr;
    }

    bool resolveAll() {
        try {
            // STEP 2
            CreateData          = loader.get<FnCreateData>("LF_CreateData");
            CreateDataPermanent = loader.get<FnCreateData>("LF_CreateData_Permanent");
            FreeData            = loader.get<FnFreeData>("LF_FreeData");
            WriteBuffer         = loader.get<FnWriteBuffer>("LF_WriteBuffer");
            ReadBuffer          = loader.get<FnReadBuffer>("LF_ReadBuffer");
            GetPos              = loader.get<FnGetPos>("LF_GetPos");
            SetPos              = loader.get<FnSetPos>("LF_SetPos");
            GetSize             = loader.get<FnGetSize>("LF_GetSize");
            GetBuffer           = loader.get<FnGetBuffer>("LF_GetBuffer");
            CreateApp           = loader.get<FnCreateApp>("LF_CreateApp");
            FreeApp             = loader.get<FnFreeApp>("LF_FreeApp");
            GetAppName          = loader.get<FnGetAppName>("LF_Get_AppName");

            // STEP 3a
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
            Shutdown        = loader.get<FnShutdown>("LF_Shutdown");
            SetOption       = loader.get<FnSetOption>("LF_SetOption");

            // STEP 3b
            RegisterCall    = loader.get<FnRegisterCall>("LF_RegisterCall");
            RegisterNotify  = loader.get<FnRegisterNotify>("LF_RegisterNotify");
            SetNetworkEvent = loader.get<FnSetNetworkEvent>("LF_Set_Network_Event");
            return true;
        } catch (const std::exception& e) {
            last_error = e.what();
            return false;
        }
    }

    bool ready() const noexcept {
        return loader.is_loaded() && CreateData != nullptr && Call != nullptr;
    }
};

LfRuntime g_rt;

// Thread-local buffer for the most recent lf_impl_call response.
thread_local std::string t_call_result;

// Thread-local buffer for the most recent lf_impl_call_bin response.
thread_local std::string t_call_bin_result;

// =============================================================================
// Job queue (STEP 3b)
// =============================================================================

// A Job carries one inbound call or notify from a worker thread to the
// R main thread, and carries the response back on completion.
//
// Lifetime (the reference-counted contract that makes the timeout
// path safe):
//
//   * The Job is created by a worker thread and starts with refs = 2:
//     one reference for the worker, one for the R side.
//   * The R side receives a raw pointer through the job queue and is
//     expected to call lf_impl_job_complete (normal path) or let the
//     externalptr finalizer call lf_impl_job_abandon (error path).
//     Both drop the R side's reference.
//   * The worker drops its reference as the last action of the
//     trampoline.
//   * The Job object destroys itself when the second reference is
//     dropped.
struct Job {
    // Reference count. Starts at 2: one reference for the worker
    // thread, one for the R main thread. The Job is deleted when the
    // count reaches zero.
    std::atomic<int>        refs{2};

    std::mutex              mtx;
    std::condition_variable cv;
    bool                    done    = false;   // worker no longer waiting
    bool                    is_call = true;
    std::string             api_name;
    std::string             input;              // copied from the DataHandle
    std::string             output;             // filled by the R main thread

    // Only meaningful before the worker returns; not touched after.
    void*                   lf_output = nullptr;  // LingoFuse output handle

    // Drop one reference. When the last reference is dropped the
    // object destroys itself.
    void release() noexcept {
        if (refs.fetch_sub(1, std::memory_order_acq_rel) == 1) {
            delete this;
        }
    }
};

struct JobQueue {
    std::mutex                      mtx;
    std::condition_variable         cv;
    std::deque<Job*>                q;
    std::atomic<std::int64_t>       timeout_ms{5000};

    void push(Job* j) {
        {
            std::lock_guard<std::mutex> lk(mtx);
            q.push_back(j);
        }
        cv.notify_one();
    }

    Job* pop_wait(std::int64_t wait_ms) {
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

    std::size_t size() {
        std::lock_guard<std::mutex> lk(mtx);
        return q.size();
    }
};

JobQueue g_jobs;

// =============================================================================
// Callback helpers (STEP 3b)
// =============================================================================
// These functions run on a LingoFuse C4 worker thread. They MUST NOT
// touch the R interpreter in any way.

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
        // Allocation failure. Leave `out` empty so the caller sees a
        // zero-length payload rather than a half-initialised one.
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
    // Do NOT strip a trailing NUL byte. Binary payloads may
    // legitimately end with 0x00 (for example, the last byte of an
    // int32 whose high bytes are zero). The R-side dispatch layer
    // strips the NUL for string-mode jobs and keeps it verbatim for
    // binary-mode jobs.
}

void write_string_to_handle(void* hnd, const std::string& value)
{
    if (hnd == nullptr) return;
    if (!value.empty()) {
        const std::int64_t want =
            static_cast<std::int64_t>(value.size());
        const std::int64_t wrote =
            g_rt.WriteBuffer(hnd, value.data(), want);
        if (wrote != want) {
            // A short write here means the underlying buffer is
            // corrupt or the process is out of memory. The wire
            // frame is already broken; do not attempt to append the
            // NUL terminator.
            return;
        }
    }
    const char nul = 0;
    g_rt.WriteBuffer(hnd, &nul, 1);
}

// The `trigger` argument is a pointer to a std::string holding the
// API name. It is owned by the callback registration record kept
// alive by keep_name() below.
extern "C" void call_trampoline(void* trigger, void* input, void* output)
{
    // ------------------------------------------------------------------
    // Phase 1: allocate the Job and copy the input bytes. Any
    // allocation failure is caught here and turned into a wire-level
    // error response. The Job has not yet been handed to the R side,
    // so we can delete it directly.
    // ------------------------------------------------------------------
    Job* j = nullptr;
    try {
        j = new Job();
        auto* name = static_cast<std::string*>(trigger);
        j->is_call  = true;
        j->api_name = name ? *name : "";
        drain_handle_into_string(input, j->input);
        j->lf_output = output;
    } catch (...) {
        delete j;
        write_string_to_handle(
            output,
            "{\"error\":\"failed to allocate job\"}");
        return;
    }

    // ------------------------------------------------------------------
    // Phase 2: enqueue. If push_back itself fails to allocate, the R
    // side never saw the pointer, so we can delete the Job directly.
    // ------------------------------------------------------------------
    try {
        g_jobs.push(j);
    } catch (...) {
        write_string_to_handle(
            output,
            "{\"error\":\"job queue push failed\"}");
        delete j;
        return;
    }

    // ------------------------------------------------------------------
    // Phase 3: wait for the R side to complete the job (or timeout).
    // ------------------------------------------------------------------
    const std::int64_t t = g_jobs.timeout_ms.load(std::memory_order_relaxed);
    bool timed_out = false;

    try {
        std::unique_lock<std::mutex> lk(j->mtx);
        if (t <= 0) {
            j->cv.wait(lk, [j]{ return j->done; });
        } else {
            if (!j->cv.wait_for(lk, std::chrono::milliseconds(t),
                                [j]{ return j->done; })) {
                // Timed out. Mark done so a later complete() sees the
                // flag and becomes a no-op. The R side still holds
                // its reference and will drop it when it calls
                // lf_impl_job_complete (or when the externalptr
                // finalizer calls lf_impl_job_abandon).
                j->done = true;
                timed_out = true;
            }
        }
    } catch (...) {
        // wait / wait_for only throw on system errors. Treat the job
        // as timed out; the R side will still release its reference.
        j->done = true;
        timed_out = true;
    }

    // ------------------------------------------------------------------
    // Phase 4: write the response and drop the worker's reference.
    // The R side holds the other reference and will drop it when it
    // completes or abandons the Job.
    // ------------------------------------------------------------------
    if (timed_out) {
        write_string_to_handle(
            output,
            "{\"error\":\"R handler timeout\"}");
    } else {
        write_string_to_handle(output, j->output);
    }

    j->release();
}

extern "C" void notify_trampoline(void* trigger, void* input)
{
    Job* j = nullptr;
    try {
        j = new Job();
        auto* name = static_cast<std::string*>(trigger);
        j->is_call   = false;
        j->api_name  = name ? *name : "";
        drain_handle_into_string(input, j->input);
        j->lf_output = nullptr;
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

    const std::int64_t t = g_jobs.timeout_ms.load(std::memory_order_relaxed);
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

// Registration records: kept alive for the process lifetime so that
// the `trigger` pointers passed to LingoFuse stay valid.
std::mutex g_reg_mtx;
std::unordered_map<std::string, std::unique_ptr<std::string>> g_reg_names;

std::string* keep_name(const char* api_name) noexcept
{
    try {
        std::lock_guard<std::mutex> lk(g_reg_mtx);
        std::string key = api_name ? api_name : "";
        auto it = g_reg_names.find(key);
        if (it != g_reg_names.end()) {
            return it->second.get();
        }
        auto p = std::unique_ptr<std::string>(new std::string(key));
        std::string* raw = p.get();
        g_reg_names.emplace(key, std::move(p));
        return raw;
    } catch (...) {
        return nullptr;
    }
}

} // namespace

// =============================================================================
// STEP 1 - probes
// =============================================================================

extern "C" const char* lf_impl_ping(void)     { return "pong"; }
extern "C" const char* lf_impl_version(void)  { return "0.5.0"; }
extern "C" const char* lf_impl_stage(void)    { return "step-3b-callee"; }
extern "C" const char* lf_impl_compiled(void) { return __DATE__ " " __TIME__; }

// =============================================================================
// STEP 2 - runtime loading
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
    g_rt.clear();
    g_rt.loader.unload();
    g_rt.last_error.clear();
}

extern "C" int lf_impl_is_loaded(void) { return g_rt.ready() ? 1 : 0; }

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
// STEP 2 - DataHandle
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
    return g_rt.GetBuffer(hnd);
}

// =============================================================================
// STEP 2 - AppHandle
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

// =============================================================================
// STEP 3a - network preparation and invocation
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

extern "C" const char* lf_impl_call(
    const char* app_name, const char* api_name, const char* payload,
    std::uint64_t timeout_ms, std::int64_t* out_len)
{
    if (out_len) *out_len = 0;
    if (!g_rt.ready() || app_name == nullptr || api_name == nullptr) {
        g_rt.last_error = "runtime not loaded or null argument";
        return nullptr;
    }

    try {
        void* hnd = g_rt.CreateData(api_name);
        if (!hnd) {
            g_rt.last_error = "LF_CreateData returned NULL";
            return nullptr;
        }

        // Write the payload with an explicit NUL terminator, matching
        // the wire format used everywhere in the LingoFuse toolchain.
        {
            const char* p = payload ? payload : "";
            const std::size_t n = std::strlen(p);
            if (n > 0) {
                if (g_rt.WriteBuffer(hnd, p, static_cast<std::int64_t>(n))
                    != static_cast<std::int64_t>(n)) {
                    g_rt.FreeData(hnd);
                    g_rt.last_error = "failed to write request payload";
                    return nullptr;
                }
            }
            const char nul = 0;
            if (g_rt.WriteBuffer(hnd, &nul, 1) != 1) {
                g_rt.FreeData(hnd);
                g_rt.last_error = "failed to write NUL terminator";
                return nullptr;
            }
        }

        void* res = g_rt.Call(app_name, hnd, timeout_ms);
        g_rt.FreeData(hnd);

        if (!res) {
            g_rt.last_error = "LF_Call returned NULL";
            return nullptr;
        }

        std::string tmp;
        drain_handle_into_string(res, tmp);
        g_rt.FreeData(res);
        t_call_result = std::move(tmp);

        if (out_len) {
            *out_len = static_cast<std::int64_t>(t_call_result.size());
        }
        return t_call_result.c_str();
    } catch (const std::exception& e) {
        g_rt.last_error = std::string("lf_impl_call: ") + e.what();
        return nullptr;
    } catch (...) {
        g_rt.last_error = "lf_impl_call: unknown exception";
        return nullptr;
    }
}

extern "C" int lf_impl_notify(
    const char* app_name, const char* api_name, const char* payload)
{
    if (!g_rt.ready() || app_name == nullptr || api_name == nullptr) return -1;

    void* hnd = g_rt.CreateData(api_name);
    if (!hnd) return -1;

    const char* p = payload ? payload : "";
    const std::size_t n = std::strlen(p);
    if (n > 0 && g_rt.WriteBuffer(hnd, p, static_cast<std::int64_t>(n))
                 != static_cast<std::int64_t>(n)) {
        g_rt.FreeData(hnd);
        return -1;
    }
    const char nul = 0;
    if (g_rt.WriteBuffer(hnd, &nul, 1) != 1) {
        g_rt.FreeData(hnd);
        return -1;
    }

    g_rt.Notify(app_name, hnd);
    g_rt.FreeData(hnd);
    return 0;
}

extern "C" int lf_impl_sequenced_notify(
    const char* app_name, const char* api_name, const char* payload)
{
    if (!g_rt.ready() || app_name == nullptr || api_name == nullptr) return -1;

    void* hnd = g_rt.CreateData(api_name);
    if (!hnd) return -1;

    const char* p = payload ? payload : "";
    const std::size_t n = std::strlen(p);
    if (n > 0 && g_rt.WriteBuffer(hnd, p, static_cast<std::int64_t>(n))
                 != static_cast<std::int64_t>(n)) {
        g_rt.FreeData(hnd);
        return -1;
    }
    const char nul = 0;
    if (g_rt.WriteBuffer(hnd, &nul, 1) != 1) {
        g_rt.FreeData(hnd);
        return -1;
    }

    g_rt.SequencedNotify(app_name, hnd);
    g_rt.FreeData(hnd);
    return 0;
}

extern "C" const char* lf_impl_call_bin(
    const char* app_name, const char* api_name,
    const void* req, std::int64_t req_len,
    std::uint64_t timeout_ms, std::int64_t* out_len)
{
    if (out_len) *out_len = 0;
    if (!g_rt.ready() || app_name == nullptr || api_name == nullptr) {
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

        if (req_len > 0) {
            if (g_rt.WriteBuffer(hnd, req, req_len) != req_len) {
                g_rt.FreeData(hnd);
                g_rt.last_error = "failed to write binary request payload";
                return nullptr;
            }
        }

        void* res = g_rt.Call(app_name, hnd, timeout_ms);
        g_rt.FreeData(hnd);

        if (!res) {
            g_rt.last_error = "LF_Call returned NULL";
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

        if (out_len) *out_len = static_cast<std::int64_t>(t_call_bin_result.size());
        return t_call_bin_result.empty() ? "" : t_call_bin_result.data();
    } catch (const std::exception& e) {
        g_rt.last_error = std::string("lf_impl_call_bin: ") + e.what();
        return nullptr;
    } catch (...) {
        g_rt.last_error = "lf_impl_call_bin: unknown exception";
        return nullptr;
    }
}

extern "C" int lf_impl_notify_bin(
    const char* app_name, const char* api_name,
    const void* req, std::int64_t req_len)
{
    if (!g_rt.ready() || app_name == nullptr || api_name == nullptr) return -1;
    if (req == nullptr && req_len > 0) return -1;
    if (req_len < 0) return -1;

    void* hnd = g_rt.CreateData(api_name);
    if (!hnd) return -1;

    if (req_len > 0) {
        if (g_rt.WriteBuffer(hnd, req, req_len) != req_len) {
            g_rt.FreeData(hnd);
            return -1;
        }
    }

    g_rt.Notify(app_name, hnd);
    g_rt.FreeData(hnd);
    return 0;
}

extern "C" void lf_impl_shutdown(void)
{
    if (!g_rt.ready()) return;
    g_rt.Shutdown();
}

extern "C" void lf_impl_set_option(const char* name, const char* value)
{
    if (!g_rt.ready() || name == nullptr) return;
    g_rt.SetOption(name, value ? value : "");
}

// =============================================================================
// STEP 3b - callee
// =============================================================================

extern "C" int lf_impl_register_call_raw(
    void* app, const char* api_name, const char* description,
    void* user_trigger)
{
    if (!g_rt.ready() || app == nullptr || api_name == nullptr) {
        return 0;
    }
    // The callback trampoline is a C++-layer internal detail. The
    // caller's trigger is not used; the trampoline looks up the API
    // name through the registration record kept alive by keep_name().
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
    if (!g_rt.ready() || app == nullptr || api_name == nullptr) {
        return 0;
    }
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

extern "C" std::int64_t lf_impl_job_input_size(void* job)
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

extern "C" void lf_impl_job_complete(void* job, const void* buf, std::int64_t len)
{
    if (job == nullptr) return;
    Job* j = static_cast<Job*>(job);

    bool worker_timed_out = false;
    {
        std::unique_lock<std::mutex> lk(j->mtx);
        if (j->done) {
            // The worker already timed out and has dropped (or is
            // about to drop) its reference. We are now the last
            // owner; do not touch any field except through release().
            worker_timed_out = true;
        } else {
            if (j->is_call && buf != nullptr && len > 0) {
                try {
                    j->output.assign(static_cast<const char*>(buf),
                                     static_cast<std::size_t>(len));
                } catch (...) {
                    // Allocation failed. Leave output empty; the
                    // worker will return a zero-length response.
                    j->output.clear();
                }
            }
            j->done = true;
        }
    }

    if (!worker_timed_out) {
        // Normal path: wake the worker so it can write the response
        // and drop the other reference.
        j->cv.notify_one();
    }

    // Drop the R side's reference. When the worker has already
    // dropped its own (timeout path), this destroys the Job.
    j->release();
}

extern "C" void lf_impl_job_abandon(void* job)
{
    if (job == nullptr) return;
    Job* j = static_cast<Job*>(job);

    bool worker_timed_out = false;
    {
        std::unique_lock<std::mutex> lk(j->mtx);
        if (j->done) {
            worker_timed_out = true;
        } else {
            j->done = true;
        }
    }

    if (!worker_timed_out) {
        j->cv.notify_one();
    }

    j->release();
}

extern "C" void lf_impl_set_network_event(
    void (*on_connect)(const char*),
    void (*on_disconnect)(const char*))
{
    if (!g_rt.ready()) return;
    g_rt.SetNetworkEvent(on_connect, on_disconnect);
}

extern "C" void lf_impl_set_job_timeout_ms(std::int64_t ms)
{
    g_jobs.timeout_ms.store(ms, std::memory_order_relaxed);
}

extern "C" std::int64_t lf_impl_pending_job_count(void)
{
    return static_cast<std::int64_t>(g_jobs.size());
}