// =============================================================================
// echo_client.cpp
// -----------------------------------------------------------------------------
// Minimal LingoFuse client used to verify the R callee (STEP 3b).
//
// It connects to ipc:r_callee (the R service) and issues:
//     1. Call  add   {"a":3,"b":4}     -> {"result":7}
//     2. Call  add   {"a":-10,"b":25}  -> {"result":15}
//     3. Call  echo  "hello"           -> "hello"
//     4. Notify log  "ping from client"
//
// It prints every response, then waits for Enter before running the
// LF shutdown sequence. This matches the behaviour of every other
// CS-style demo in this repository.
//
// LF SHUTDOWN CONTRACT
// --------------------
// This program establishes a client connection to a LingoFuse service.
// It therefore runs the full shutdown sequence before exiting:
//
//   1. LF_ExitMainThread
//   2. LF_Shutdown
//
// The bridge DLL is deliberately NOT unloaded. LF_Shutdown is
// asynchronous and worker threads may still be executing inside the
// DLL when it returns. See lf_loader.hpp for the full rationale.
//
// Build:
//     g++ -std=c++17 -O2 -I../src -o echo_client.exe echo_client.cpp
//
// Run:
//     echo_client.exe [runtime_dir]
// =============================================================================

#include "lf_loader.h"

#include <cstdint>
#include <cstring>
#include <iostream>
#include <string>
#include <thread>
#include <chrono>

namespace {

struct FnTable {
    void* (*CreateData)(const char*);
    void  (*FreeData)(void*);
    std::int64_t (*WriteBuffer)(void*, const void*, std::int64_t);
    std::int64_t (*ReadBuffer)(void*, void*, std::int64_t);
    std::int64_t (*GetSize)(void*);
    void  (*SetPos)(void*, std::int64_t);
    int   (*PrepareClient)(const char*, void*);
    void  (*ResetPrepare)(void);
    int   (*PrepareDone)(void);
    void* (*Call)(const char*, void*, std::uint64_t);
    void  (*Notify)(const char*, void*);
    int   (*CheckApi)(const char*, const char*);
    void  (*ExitMainThread)(void);
    void  (*Shutdown)(void);
};

FnTable g_fn{};

void write_payload(void* hnd, const std::string& s)
{
    if (!s.empty()) {
        g_fn.WriteBuffer(hnd, s.data(), (std::int64_t)s.size());
    }
    const char nul = 0;
    g_fn.WriteBuffer(hnd, &nul, 1);
}

std::string read_payload(void* hnd)
{
    std::int64_t sz = g_fn.GetSize(hnd);
    if (sz <= 0) return "";
    std::string out((std::size_t)sz, '\0');
    g_fn.SetPos(hnd, 0);
    std::int64_t got = g_fn.ReadBuffer(hnd, &out[0], sz);
    if (got < 0) got = 0;
    out.resize((std::size_t)got);
    while (!out.empty() && out.back() == '\0') out.pop_back();
    return out;
}

void call_and_print(const char* app, const char* api, const std::string& payload)
{
    std::cout << ">> CALL " << app << "." << api
              << "  payload=" << payload << std::endl;

    void* hnd = g_fn.CreateData(api);
    if (!hnd) { std::cerr << "   [ERROR] CreateData failed" << std::endl; return; }

    write_payload(hnd, payload);
    void* res = g_fn.Call(app, hnd, 5000);
    g_fn.FreeData(hnd);

    if (!res) {
        std::cerr << "   [ERROR] LF_Call returned NULL" << std::endl;
        return;
    }
    std::string out = read_payload(res);
    g_fn.FreeData(res);
    std::cout << "   << RESP: " << out << std::endl;
}

} // namespace

int main(int argc, char** argv)
{
    std::string runtime_dir =
        (argc >= 2) ? argv[1] : "D:/CoreLibrary/LingoFuse/Binary";

    std::cout << "=== LingoFuse echo_client ===" << std::endl;
    std::cout << "Runtime: " << runtime_dir << std::endl;

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
        g_fn.SetPos          = loader.get<decltype(g_fn.SetPos)>("LF_SetPos");
        g_fn.PrepareClient   = loader.get<decltype(g_fn.PrepareClient)>("LF_PrepareClient");
        g_fn.ResetPrepare    = loader.get<decltype(g_fn.ResetPrepare)>("LF_ResetPrepare");
        g_fn.PrepareDone     = loader.get<decltype(g_fn.PrepareDone)>("LF_PrepareDone");
        g_fn.Call            = loader.get<decltype(g_fn.Call)>("LF_Call");
        g_fn.Notify          = loader.get<decltype(g_fn.Notify)>("LF_Notify");
        g_fn.CheckApi        = loader.get<decltype(g_fn.CheckApi)>("LF_CheckApi");
        g_fn.ExitMainThread  = loader.get<decltype(g_fn.ExitMainThread)>("LF_ExitMainThread");
        g_fn.Shutdown        = loader.get<decltype(g_fn.Shutdown)>("LF_Shutdown");
    } catch (const std::exception& e) {
        std::cerr << "[FATAL] Symbol resolution failed: " << e.what() << std::endl;
        return 1;
    }
    std::cout << "[OK] Symbols resolved" << std::endl;

    g_fn.ResetPrepare();
    if (g_fn.PrepareClient("ipc:r_callee", nullptr) < 0) {
        std::cerr << "[FATAL] PrepareClient failed" << std::endl;
        return 1;
    }
    if (g_fn.PrepareDone() != 1) {
        std::cerr << "[FATAL] PrepareDone failed" << std::endl;
        return 1;
    }
    std::cout << "[OK] Connected to ipc:r_callee" << std::endl;

    // Wait until the R service registers its APIs.
    std::cout << "Waiting for RService to become visible..." << std::endl;
    for (int i = 0; i < 30; ++i) {
        if (g_fn.CheckApi("RService", "add")) break;
        std::this_thread::sleep_for(std::chrono::milliseconds(200));
    }

    call_and_print("RService", "add",  "{\"a\":3,\"b\":4}");
    call_and_print("RService", "add",  "{\"a\":-10,\"b\":25}");
    call_and_print("RService", "echo", "hello from echo_client");

    // Notify
    std::cout << ">> NOTIFY RService.log" << std::endl;
    {
        void* hnd = g_fn.CreateData("log");
        write_payload(hnd, "ping from echo_client");
        g_fn.Notify("RService", hnd);
        g_fn.FreeData(hnd);
    }

    // Give the notify a moment to be delivered before shutdown begins.
    std::this_thread::sleep_for(std::chrono::milliseconds(500));

    // ------------------------------------------------------------------
    // Wait for the user to press Enter, then run the full LF shutdown
    // sequence. The service keeps running while this loop is blocked on
    // stdin.
    // ------------------------------------------------------------------
    std::cout << "[OK] Done. Press Enter to exit..." << std::endl;
    std::string line;
    std::getline(std::cin, line);

    g_fn.ExitMainThread();
    g_fn.Shutdown();

    // Do NOT unload the bridge DLL. See lf_loader.hpp.
    std::cout << "Bye." << std::endl;
    return 0;
}