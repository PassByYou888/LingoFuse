// =============================================================================
// cross_client.cpp
// -----------------------------------------------------------------------------
// STEP 4: C++ CrossDemo client for the R cross_node.
//
// Issues, using the raw little-endian wire format:
//   demo.add       (int32 a, int32 b)  ->  int32
//   demo.inv_seri  (u8, u16, u32, u64, string(NUL), float)  ->  reversed
//
// The values chosen match the LingoFuse reference CrossCall so that
// interop with the standard CrossNode can be verified by inspection.
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
//     g++ -std=c++17 -O2 -I../src -o cross_client.exe cross_client.cpp
//
// Run:
//     cross_client.exe [runtime_dir]
// =============================================================================

#include "lf_loader.h"

#include <cstdint>
#include <cstring>
#include <iostream>
#include <string>
#include <thread>
#include <chrono>
#include <vector>

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
    int   (*CheckApi)(const char*, const char*);
    void  (*ExitMainThread)(void);
    void  (*Shutdown)(void);
};

FnTable g_fn{};

// ---- wire-format helpers (little-endian) -----------------------------------

void put_u8 (std::vector<std::uint8_t>& b, std::uint8_t v)  { b.push_back(v); }
void put_u16(std::vector<std::uint8_t>& b, std::uint16_t v) {
    b.push_back(v & 0xFF); b.push_back((v >> 8) & 0xFF);
}
void put_u32(std::vector<std::uint8_t>& b, std::uint32_t v) {
    for (int i = 0; i < 4; ++i) b.push_back((v >> (8 * i)) & 0xFF);
}
void put_u64(std::vector<std::uint8_t>& b, std::uint64_t v) {
    for (int i = 0; i < 8; ++i) b.push_back((v >> (8 * i)) & 0xFF);
}
void put_str(std::vector<std::uint8_t>& b, const std::string& s) {
    b.insert(b.end(), s.begin(), s.end());
    b.push_back(0);
}
void put_f32(std::vector<std::uint8_t>& b, float v) {
    std::uint32_t u; std::memcpy(&u, &v, 4);
    put_u32(b, u);
}

std::uint8_t  get_u8 (const std::vector<std::uint8_t>& b, std::size_t& p) {
    return b[p++];
}
std::uint16_t get_u16(const std::vector<std::uint8_t>& b, std::size_t& p) {
    std::uint16_t v = b[p] | (std::uint16_t(b[p+1]) << 8); p += 2; return v;
}
std::uint32_t get_u32(const std::vector<std::uint8_t>& b, std::size_t& p) {
    std::uint32_t v = 0;
    for (int i = 0; i < 4; ++i) v |= std::uint32_t(b[p+i]) << (8*i);
    p += 4; return v;
}
std::uint64_t get_u64(const std::vector<std::uint8_t>& b, std::size_t& p) {
    std::uint64_t v = 0;
    for (int i = 0; i < 8; ++i) v |= std::uint64_t(b[p+i]) << (8*i);
    p += 8; return v;
}
std::string   get_str(const std::vector<std::uint8_t>& b, std::size_t& p) {
    std::string s;
    while (p < b.size() && b[p] != 0) s.push_back(char(b[p++]));
    if (p < b.size()) ++p;   // skip NUL
    return s;
}
float         get_f32(const std::vector<std::uint8_t>& b, std::size_t& p) {
    std::uint32_t u = get_u32(b, p);
    float f; std::memcpy(&f, &u, 4); return f;
}

std::vector<std::uint8_t> call_raw(const char* app, const char* api,
                                   const std::vector<std::uint8_t>& req)
{
    void* hnd = g_fn.CreateData(api);
    if (!hnd) return {};
    if (!req.empty()) g_fn.WriteBuffer(hnd, req.data(), (std::int64_t)req.size());
    void* res = g_fn.Call(app, hnd, 5000);
    g_fn.FreeData(hnd);
    if (!res) return {};
    std::int64_t sz = g_fn.GetSize(res);
    std::vector<std::uint8_t> out;
    if (sz > 0) {
        out.resize((std::size_t)sz);
        g_fn.SetPos(res, 0);
        std::int64_t got = g_fn.ReadBuffer(res, out.data(), sz);
        if (got < 0) got = 0;
        out.resize((std::size_t)got);
    }
    g_fn.FreeData(res);
    return out;
}

} // namespace

int main(int argc, char** argv)
{
    std::string runtime_dir =
        (argc >= 2) ? argv[1] : "D:/CoreLibrary/LingoFuse/Binary";

    std::cout << "=== LingoFuse cross_client ===" << std::endl;
    std::cout << "Runtime: " << runtime_dir << std::endl;

    lf::Loader loader;
    try { loader.load(runtime_dir); }
    catch (const std::exception& e) {
        std::cerr << "[FATAL] " << e.what() << std::endl; return 1;
    }
    std::cout << "[OK] Loaded: " << loader.loaded_path() << std::endl;

    try {
        g_fn.CreateData     = loader.get<decltype(g_fn.CreateData)>("LF_CreateData");
        g_fn.FreeData       = loader.get<decltype(g_fn.FreeData)>("LF_FreeData");
        g_fn.WriteBuffer    = loader.get<decltype(g_fn.WriteBuffer)>("LF_WriteBuffer");
        g_fn.ReadBuffer     = loader.get<decltype(g_fn.ReadBuffer)>("LF_ReadBuffer");
        g_fn.GetSize        = loader.get<decltype(g_fn.GetSize)>("LF_GetSize");
        g_fn.SetPos         = loader.get<decltype(g_fn.SetPos)>("LF_SetPos");
        g_fn.PrepareClient  = loader.get<decltype(g_fn.PrepareClient)>("LF_PrepareClient");
        g_fn.ResetPrepare   = loader.get<decltype(g_fn.ResetPrepare)>("LF_ResetPrepare");
        g_fn.PrepareDone    = loader.get<decltype(g_fn.PrepareDone)>("LF_PrepareDone");
        g_fn.Call           = loader.get<decltype(g_fn.Call)>("LF_Call");
        g_fn.CheckApi       = loader.get<decltype(g_fn.CheckApi)>("LF_CheckApi");
        g_fn.ExitMainThread = loader.get<decltype(g_fn.ExitMainThread)>("LF_ExitMainThread");
        g_fn.Shutdown       = loader.get<decltype(g_fn.Shutdown)>("LF_Shutdown");
    } catch (const std::exception& e) {
        std::cerr << "[FATAL] Symbol resolution failed: " << e.what() << std::endl;
        return 1;
    }

    g_fn.ResetPrepare();
    if (g_fn.PrepareClient("ipc:cross", nullptr) < 0) {
        std::cerr << "[FATAL] PrepareClient failed" << std::endl; return 1;
    }
    if (g_fn.PrepareDone() != 1) {
        std::cerr << "[FATAL] PrepareDone failed" << std::endl; return 1;
    }
    std::cout << "[OK] Connected to ipc:cross" << std::endl;

    std::cout << "Waiting for demo app..." << std::endl;
    for (int i = 0; i < 30; ++i) {
        if (g_fn.CheckApi("demo", "add")) break;
        std::this_thread::sleep_for(std::chrono::milliseconds(200));
    }

    // ---- add -----------------------------------------------------------------
    {
        std::vector<std::uint8_t> req;
        put_u32(req, 3);    // a = 3
        put_u32(req, 4);    // b = 4
        auto resp = call_raw("demo", "add", req);
        std::cout << ">> demo.add(3, 4)" << std::endl;
        if (resp.size() >= 4) {
            std::size_t p = 0;
            std::int32_t v = (std::int32_t)get_u32(resp, p);
            std::cout << "   << result = " << v << "  (expected 7)" << std::endl;
        } else {
            std::cout << "   << [ERROR] short response (" << resp.size()
                      << " bytes)" << std::endl;
        }
    }

    // ---- inv_seri ------------------------------------------------------------
    {
        std::vector<std::uint8_t> req;
        put_u8 (req, 200);
        put_u16(req, 0x0010);
        put_u32(req, 0x0000002F);
        put_u64(req, 0x000000000000003FULL);
        put_str(req, "hello world");
        put_f32(req, 3.14f);

        auto resp = call_raw("demo", "inv_seri", req);
        std::cout << ">> demo.inv_seri(...)" << std::endl;

        if (resp.size() >= 1 + 2 + 4 + 8 + 12 + 4) {
            std::size_t p = 0;
            float       f   = get_f32(resp, p);
            std::string s   = get_str(resp, p);
            std::uint64_t u = get_u64(resp, p);
            std::uint32_t c = get_u32(resp, p);
            std::uint16_t w = get_u16(resp, p);
            std::uint8_t  b = get_u8 (resp, p);

            std::cout << "   << reversed: f=" << f
                      << " s=\"" << s << "\""
                      << " u64=0x" << std::hex << u
                      << " u32=0x" << c
                      << " u16=0x" << w
                      << " u8=" << std::dec << (int)b << std::endl;
        } else {
            std::cout << "   << [ERROR] short response (" << resp.size()
                      << " bytes)" << std::endl;
        }
    }

    std::this_thread::sleep_for(std::chrono::milliseconds(300));

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