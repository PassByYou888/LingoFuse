#pragma once
// =============================================================================
// lf_loader.h
// -----------------------------------------------------------------------------
// Dynamic loader for the LingoFuse runtime, header-only, C++17.
//
// This loader loads the LingoFuse DLL (or .so / .dylib) from an explicit
// directory rather than relying on the platform's executable-directory
// search, which is what the runtime's own LF_LoadLibrary helper does.
//
// WHY THE DESTRUCTOR AND unload() DO NOT UNLOAD THE LIBRARY
// ---------------------------------------------------------
// LF_Shutdown (called by the caller before returning from main) is
// ASYNCHRONOUS. It returns once the top-level structures have been torn
// down, but some C4 worker threads may still be executing inside the
// DLL for a short time afterwards. The most visible example is the
// sequenced-notification threads, which are released via
// DelayFreeObj(5.0, self) -- i.e. up to five seconds after the shutdown
// sequence returns.
//
// If the loader called FreeLibrary (or dlclose) during that window,
// the DLL code would be removed from the process address space while a
// worker thread was still running inside it, producing an access
// violation (exit code 0xC0000005 on Windows).
//
// To make this impossible even by accident, load() pins the library
// into the process using GetModuleHandleExA with the
// GET_MODULE_HANDLE_EX_FLAG_PIN flag. A pinned library can never be
// unmapped for the lifetime of the process, so Windows will terminate
// the process directly at exit instead of running the DLL detach
// sequence. There is therefore no window in which a background thread
// could race against its own DLL's unmapping.
//
// RUNTIME DIRECTORY DISCOVERY
// ---------------------------
// find_runtime_dir() locates the runtime directory without a hard-coded
// absolute path, so that the entire repository tree can be copied to
// any location and the test binaries will still find the runtime.
//
// Resolution order:
//   1. The LINGOFUSE_RUNTIME environment variable.
//   2. Relative probes under the executable's directory and the CWD:
//        Binary/, runtime/, runtime/Binary/, lib/
//        ../Binary/, ../runtime/, ../runtime/Binary/
//        ../../Binary/, ../../runtime/, ../../runtime/Binary/
//        ../../../Binary/
//
// Returns an empty string when nothing is found. Callers are expected
// to print a clear diagnostic and exit with a non-zero status.
// =============================================================================

#include <cstdlib>
#include <filesystem>
#include <stdexcept>
#include <string>
#include <unordered_map>
#include <vector>

#ifdef _WIN32
#  include <windows.h>
#else
#  include <dlfcn.h>
#  include <unistd.h>
#  ifdef __APPLE__
#    include <mach-o/dyld.h>
#  endif
#endif

namespace lf {

class LoaderError : public std::runtime_error {
public:
    explicit LoaderError(const std::string& what)
        : std::runtime_error(what) {}
};

// -----------------------------------------------------------------------------
// find_runtime_dir()
// -----------------------------------------------------------------------------
// Locate the LingoFuse runtime directory without a hard-coded path.
// Returns an empty string when nothing is found.
// -----------------------------------------------------------------------------
inline std::string find_runtime_dir() {
    namespace fs = std::filesystem;
    std::error_code ec;

    // 1. Environment variable
    const char* env = std::getenv("LINGOFUSE_RUNTIME");
    if (env != nullptr && *env != '\0') {
        fs::path p(env);
        if (fs::is_directory(p, ec)) {
            auto canon = fs::canonical(p, ec);
            if (!ec) return canon.string();
        }
    }

    // 2. Collect base directories
    std::vector<fs::path> bases;

#ifdef _WIN32
    {
        char buf[MAX_PATH] = {0};
        DWORD n = ::GetModuleFileNameA(nullptr, buf, MAX_PATH);
        if (n > 0 && n < MAX_PATH) {
            bases.push_back(fs::path(buf).parent_path());
        }
    }
#elif defined(__APPLE__)
    {
        char buf[4096] = {0};
        uint32_t sz = sizeof(buf);
        if (_NSGetExecutablePath(buf, &sz) == 0) {
            bases.push_back(fs::path(buf).parent_path());
        }
    }
#else
    {
        char buf[4096] = {0};
        ssize_t n = ::readlink("/proc/self/exe", buf, sizeof(buf) - 1);
        if (n > 0) {
            buf[n] = '\0';
            bases.push_back(fs::path(buf).parent_path());
        }
    }
#endif

    {
        auto cwd = fs::current_path(ec);
        if (!ec) bases.push_back(cwd);
    }

    // 3. Relative probes under each base
    static const char* relatives[] = {
        "Binary",
        "runtime",
        "runtime/Binary",
        "lib",
        "../Binary",
        "../runtime",
        "../runtime/Binary",
        "../../Binary",
        "../../runtime",
        "../../runtime/Binary",
        "../../../Binary"
    };

    for (const auto& base : bases) {
        for (const char* rel : relatives) {
            fs::path candidate = base / rel;
            if (fs::is_directory(candidate, ec)) {
                auto canon = fs::canonical(candidate, ec);
                if (!ec) return canon.string();
            }
        }
    }

    return "";
}

class Loader {
public:
    Loader() = default;
    Loader(const Loader&) = delete;
    Loader& operator=(const Loader&) = delete;

    // The destructor does NOT unload the library. See the file-level
    // comment for the full rationale.
    ~Loader() = default;

    bool load(const std::string& runtime_dir) {
        // Drop any stale handle from a previous load. unload() no
        // longer calls FreeLibrary/dlclose; it only clears the
        // bookkeeping fields.
        unload();

#ifdef _WIN32
        const char* name = "LingoFuse64.dll";
        // (32-bit support can be added later via #ifdef _WIN64)
        std::string full = runtime_dir;
        if (!full.empty() && full.back() != '\\' && full.back() != '/') {
            full += '\\';
        }
        full += name;

        // LoadLibraryExA with LOAD_WITH_ALTERED_SEARCH_PATH makes the
        // loader resolve dependencies (z_ipc_64.dll, mimalloc64.dll)
        // from the same directory as LingoFuse64.dll.
        HMODULE h = ::LoadLibraryExA(
            full.c_str(), nullptr, LOAD_WITH_ALTERED_SEARCH_PATH);
        if (!h) {
            DWORD err = ::GetLastError();
            throw LoaderError(
                "Failed to load " + full +
                " (GetLastError=" + std::to_string(err) + ")");
        }

        // Pin the runtime library into the process.
        //
        // LingoFuse starts background activity as soon as it is
        // loaded (the data-handle pool scanner, the simulated main
        // thread, and the C4 network machinery). If the DLL were
        // unmapped at process exit while any of those threads were
        // still running, Windows would produce an access violation
        // (exit code 0xC0000005).
        //
        // GET_MODULE_HANDLE_EX_FLAG_PIN makes the DLL effectively
        // permanent for the lifetime of the process: Windows will
        // terminate the process directly at exit instead of running
        // the detach sequence, so there is no race window.
        //
        // The call is best-effort: if it fails (for example on a
        // hardened build that forbids pinning), the library is still
        // loaded and the caller continues normally.
        HMODULE pinned = nullptr;
        ::GetModuleHandleExA(
            GET_MODULE_HANDLE_EX_FLAG_PIN,
            full.c_str(),
            &pinned);

        handle_ = reinterpret_cast<void*>(h);
        path_ = full;
#else
        std::string name =
#ifdef __APPLE__
            "liblingofuse.dylib";
#else
            "liblingofuse.so";
#endif
        std::string full = runtime_dir;
        if (!full.empty() && full.back() != '/') {
            full += '/';
        }
        full += name;

        // RTLD_NODELETE prevents the dynamic loader from unmapping the
        // library even if dlclose is called. Together with the "do not
        // dlclose" policy below, this guarantees that LingoFuse's
        // background threads cannot race against their own library
        // being torn down at process exit.
        void* h = ::dlopen(full.c_str(), RTLD_NOW | RTLD_GLOBAL | RTLD_NODELETE);
        if (!h) {
            throw LoaderError(
                std::string("Failed to load ") + full + ": " +
                ::dlerror());
        }
        handle_ = h;
        path_ = full;
#endif
        return true;
    }

    // Drop the caller's handle to the library WITHOUT unmapping it.
    //
    // This is deliberately a no-op with respect to the OS loader. The
    // runtime starts background threads at load time and cannot be
    // safely unmapped until process exit. On Windows the library is
    // additionally pinned at load() time, so even an explicit
    // FreeLibrary would be silently ignored.
    //
    // After this call, is_loaded() returns false and the destructor
    // has nothing to release. The DLL itself stays mapped in the
    // process until the operating system terminates the process.
    void unload() {
        handle_ = nullptr;
        path_.clear();
        cache_.clear();
    }

    // Backwards-compatible alias. Semantically identical to unload().
    void detach() noexcept {
        handle_ = nullptr;
    }

    bool is_loaded() const noexcept { return handle_ != nullptr; }

    const std::string& loaded_path() const noexcept { return path_; }

    template <typename Fn>
    Fn get(const char* symbol) {
        void* addr = resolve(symbol);
        return reinterpret_cast<Fn>(addr);
    }

private:
    void* resolve(const char* symbol) {
        if (!handle_) {
            throw LoaderError(
                std::string("Cannot resolve '") + symbol +
                "': runtime not loaded");
        }
        auto it = cache_.find(symbol);
        if (it != cache_.end()) {
            return it->second;
        }
#ifdef _WIN32
        void* addr = reinterpret_cast<void*>(
            ::GetProcAddress(reinterpret_cast<HMODULE>(handle_), symbol));
#else
        void* addr = ::dlsym(handle_, symbol);
#endif
        if (!addr) {
            throw LoaderError(
                std::string("Symbol not found: ") + symbol);
        }
        cache_.emplace(symbol, addr);
        return addr;
    }

    void* handle_ = nullptr;
    std::string path_;
    std::unordered_map<std::string, void*> cache_;
};

} // namespace lf