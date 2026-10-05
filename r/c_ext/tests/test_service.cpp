// =============================================================================
// test_service.cpp
// -----------------------------------------------------------------------------
// A minimal LingoFuse service used by the R caller test.
//
// Standalone executable. NOT part of the R bridge. Exists only so that
// caller_test.R has a stable, well-known target to call during
// development.
//
// Loads LingoFuse64.dll from a runtime directory, creates an App
// called "RTestService", registers two Call APIs:
//
//     echo       -- returns input bytes verbatim.
//     add        -- parses {"a": int, "b": int} and returns {"result": int}.
//
// RUNTIME DIRECTORY RESOLUTION (no hard-coded absolute path):
//   1. First command-line argument.
//   2. LINGOFUSE_RUNTIME environment variable.
//   3. Relative probes under the executable directory and the CWD
//      (Binary/, runtime/, ../Binary/, ../../Binary/, ...).
//
// LF SHUTDOWN CONTRACT
// --------------------
// This program starts a LingoFuse service. It therefore runs the full
// shutdown sequence before exiting:
//
//   1. LF_ExitMainThread   -- stop the simulated main thread
//   2. LF_FreeApp(app)     -- detach the application
//   3. LF_Shutdown         -- release all library resources
//
// The bridge DLL is deliberately NOT unloaded. LF_Shutdown is
// asynchronous and worker threads may still be executing inside the
// DLL when it returns. See lf_loader.h for the full rationale.
//
// Build:
//     g++ -std=c++17 -O2 -I../src -o test_service.exe test_service.cpp
//
// Run:
//     test_service.exe [runtime_dir]
// =============================================================================

#include "lf_loader.h"

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <iostream>
#include <string>

// =============================================================================
// Function pointer table
// =============================================================================

namespace {

struct FnTable {
    void* (*CreateData)(const char*);
    void  (*FreeData)(void*);
    std::int64_t (*WriteBuffer)(void*, const void*, std::int64_t);
    std::int64_t (*ReadBuffer)(void*, void*, std::int64_t);
    std::int64_t (*GetSize)(void*);
    std::int64_t (*GetPos)(void*);
    void  (*SetPos)(void*, std::int64_t);
    void* (*CreateApp)(const char*, const char*);
    void  (*FreeApp)(void*);
    int   (*RegisterCall)(void*, const char*, const char*, void*,
                          void (*)(void*, void*, void*));
    int   (*PrepareService)(const char*, const char*);
    int   (*PrepareClient)(const char*, void*);
    void  (*ResetPrepare)(void);
    int   (*PrepareDone)(void);
    void  (*ExitMainThread)(void);
    void  (*Shutdown)(void);
};

FnTable g_fn{};

struct CbContext {
    FnTable* fn;
};

CbContext g_echo_ctx{ &g_fn };
CbContext g_add_ctx{ &g_fn };

// -----------------------------------------------------------------------------
// echo callback
// -----------------------------------------------------------------------------
// Copies every byte from `input` to `output`, then appends a NUL.
// -----------------------------------------------------------------------------
void __cdecl echo_cb(void* trigger, void* input, void* output)
{
    CbContext* ctx = reinterpret_cast<CbContext*>(trigger);
    FnTable* fn = ctx->fn;

    std::int64_t sz = fn->GetSize(input);
    if (sz > 0) {
        std::string buf(static_cast<std::size_t>(sz), '\0');
        fn->SetPos(input, 0);
        fn->ReadBuffer(input, &buf[0], sz);

        // Drop any trailing NUL the caller may have written.
        while (!buf.empty() && buf.back() == '\0') buf.pop_back();

        if (!buf.empty()) {
            fn->WriteBuffer(output, buf.data(),
                            static_cast<std::int64_t>(buf.size()));
        }
    }
    const char nul = 0;
    fn->WriteBuffer(output, &nul, 1);
}

// -----------------------------------------------------------------------------
// add callback
// -----------------------------------------------------------------------------
// Minimal parser for {"a": int, "b": int}. Response: {"result": int}.
// -----------------------------------------------------------------------------
void __cdecl add_cb(void* trigger, void* input, void* output)
{
    CbContext* ctx = reinterpret_cast<CbContext*>(trigger);
    FnTable* fn = ctx->fn;

    std::int64_t sz = fn->GetSize(input);
    std::string buf;
    if (sz > 0) {
        buf.resize(static_cast<std::size_t>(sz));
        fn->SetPos(input, 0);
        fn->ReadBuffer(input, &buf[0], sz);
        while (!buf.empty() && buf.back() == '\0') buf.pop_back();
    }

    auto find_int = [&buf](const char* key, long long defval) -> long long {
        std::string needle = std::string("\"") + key + "\"";
        auto p = buf.find(needle);
        if (p == std::string::npos) return defval;
        p = buf.find(':', p);
        if (p == std::string::npos) return defval;
        ++p;
        while (p < buf.size() && (buf[p] == ' ' || buf[p] == '\t')) ++p;
        long long v = 0;
        bool neg = false;
        if (p < buf.size() && buf[p] == '-') { neg = true; ++p; }
        while (p < buf.size() && buf[p] >= '0' && buf[p] <= '9') {
            v = v * 10 + (buf[p] - '0');
            ++p;
        }
        return neg ? -v : v;
    };

    long long a = find_int("a", 0);
    long long b = find_int("b", 0);

    char resp[64];
    std::snprintf(resp, sizeof(resp), "{\"result\":%lld}", a + b);
    fn->WriteBuffer(output, resp,
                    static_cast<std::int64_t>(std::strlen(resp)));
    const char nul = 0;
    fn->WriteBuffer(output, &nul, 1);
}

} // namespace

// =============================================================================
// main
// =============================================================================

int main(int argc, char** argv)
{
    // ------------------------------------------------------------------
    // Runtime directory resolution (no hard-coded absolute path).
    // ------------------------------------------------------------------
    std::string runtime_dir;
    if (argc >= 2) {
        runtime_dir = argv[1];
    } else {
        runtime_dir = lf::find_runtime_dir();
    }
    if (runtime_dir.empty()) {
        std::cerr << "[FATAL] Runtime directory not provided and could "
                  << "not be auto-detected.\n"
                  << "        Usage: " << argv[0] << " <runtime_dir>\n"
                  << "        Or set the LINGOFUSE_RUNTIME environment "
                  << "variable.\n"
                  << "        Or place the runtime in a Binary/ directory "
                  << "relative to this executable.\n";
        return 1;
    }

    std::cout << "=== LingoFuse R test service ===" << std::endl;
    std::cout << "Runtime directory: " << runtime_dir << std::endl;

    lf::Loader loader;
    try {
        loader.load(runtime_dir);
    } catch (const std::exception& e) {
        std::cerr << "[FATAL] " << e.what() << std::endl;
        return 1;
    }
    std::cout << "[OK] Loaded: " << loader.loaded_path() << std::endl;

    try {
        g_fn.CreateData      = loader.get<decltype(g_fn.CreateData)>("LF_CreateData");
        g_fn.FreeData        = loader.get<decltype(g_fn.FreeData)>("LF_FreeData");
        g_fn.WriteBuffer     = loader.get<decltype(g_fn.WriteBuffer)>("LF_WriteBuffer");
        g_fn.ReadBuffer      = loader.get<decltype(g_fn.ReadBuffer)>("LF_ReadBuffer");
        g_fn.GetSize         = loader.get<decltype(g_fn.GetSize)>("LF_GetSize");
        g_fn.GetPos          = loader.get<decltype(g_fn.GetPos)>("LF_GetPos");
        g_fn.SetPos          = loader.get<decltype(g_fn.SetPos)>("LF_SetPos");
        g_fn.CreateApp       = loader.get<decltype(g_fn.CreateApp)>("LF_CreateApp");
        g_fn.FreeApp         = loader.get<decltype(g_fn.FreeApp)>("LF_FreeApp");
        g_fn.RegisterCall    = loader.get<decltype(g_fn.RegisterCall)>("LF_RegisterCall");
        g_fn.PrepareService  = loader.get<decltype(g_fn.PrepareService)>("LF_PrepareService");
        g_fn.PrepareClient   = loader.get<decltype(g_fn.PrepareClient)>("LF_PrepareClient");
        g_fn.ResetPrepare    = loader.get<decltype(g_fn.ResetPrepare)>("LF_ResetPrepare");
        g_fn.PrepareDone     = loader.get<decltype(g_fn.PrepareDone)>("LF_PrepareDone");
        g_fn.ExitMainThread  = loader.get<decltype(g_fn.ExitMainThread)>("LF_ExitMainThread");
        g_fn.Shutdown        = loader.get<decltype(g_fn.Shutdown)>("LF_Shutdown");
    } catch (const std::exception& e) {
        std::cerr << "[FATAL] Symbol resolution failed: " << e.what() << std::endl;
        return 1;
    }
    std::cout << "[OK] Symbols resolved" << std::endl;

    void* app = g_fn.CreateApp("RTestService", "Service for R caller tests");
    if (!app) {
        std::cerr << "[FATAL] LF_CreateApp failed" << std::endl;
        return 1;
    }

    if (g_fn.RegisterCall(app, "echo", "Echo input",
                          &g_echo_ctx,
                          reinterpret_cast<void(*)(void*,void*,void*)>(echo_cb)) != 1) {
        std::cerr << "[FATAL] LF_RegisterCall(echo) failed" << std::endl;
        return 1;
    }
    if (g_fn.RegisterCall(app, "add", "Add two integers (JSON)",
                          &g_add_ctx,
                          reinterpret_cast<void(*)(void*,void*,void*)>(add_cb)) != 1) {
        std::cerr << "[FATAL] LF_RegisterCall(add) failed" << std::endl;
        return 1;
    }
    std::cout << "[OK] APIs registered: echo, add" << std::endl;

    g_fn.ResetPrepare();
    if (g_fn.PrepareService("ipc:r_test", "ipc:r_test") < 0) {
        std::cerr << "[FATAL] LF_PrepareService failed" << std::endl;
        return 1;
    }
    if (g_fn.PrepareClient("ipc:r_test", app) < 0) {
        std::cerr << "[FATAL] LF_PrepareClient failed" << std::endl;
        return 1;
    }

    int ready = g_fn.PrepareDone();
    if (ready != 1) {
        std::cerr << "[FATAL] LF_PrepareDone returned " << ready << std::endl;
        return 1;
    }

    // ------------------------------------------------------------------
    // Wait for the user to press Enter. The service keeps processing
    // requests while this loop is blocked on stdin, because the C4
    // worker threads run independently of the main thread.
    // ------------------------------------------------------------------
    std::cout << "[OK] Service online. Press Enter to exit..." << std::endl;
    std::string line;
    std::getline(std::cin, line);

    // ------------------------------------------------------------------
    // Full LF shutdown sequence.
    //
    //   1. ExitMainThread   stop the simulated main thread
    //   2. FreeApp          detach the application
    //   3. Shutdown         release library resources
    //
    // The DLL is deliberately left loaded. See lf_loader.h.
    // ------------------------------------------------------------------
    std::cout << "Shutting down..." << std::endl;
    g_fn.ExitMainThread();
    g_fn.FreeApp(app);
    g_fn.Shutdown();

    std::cout << "Bye." << std::endl;
    return 0;
}