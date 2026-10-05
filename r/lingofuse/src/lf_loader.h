#pragma once
// =============================================================================
// lf_loader.hpp
// -----------------------------------------------------------------------------
// Dynamic loader for the LingoFuse runtime, header-only, C++17.
//
// This loader loads the LingoFuse DLL (or .so / .dylib) from an explicit
// directory rather than relying on the platform's executable-directory
// search, which is what the runtime's own LF_LoadLibrary helper does.
//
// WHY THE DESTRUCTOR DOES NOT UNLOAD THE LIBRARY
// ----------------------------------------------
// LF_Shutdown (called by the caller before returning from main) is
// ASYNCHRONOUS. It returns once the top-level structures have been torn
// down, but some C4 worker threads may still be executing inside the
// DLL for a short time afterwards. The most visible example is the
// sequenced-notification threads, which are released via
// DelayFreeObj(5.0, self) -- i.e. up to five seconds after the shutdown
// sequence returns.
//
// If the destructor called FreeLibrary (or dlclose) during that window,
// the DLL code would be removed from the process address space while a
// worker thread was still running inside it, producing an access
// violation. The correct behaviour is to let the operating system unload
// the library during process exit, when all threads have already been
// torn down by the loader.
//
// Callers who genuinely need to unload the library before process exit
// (for example, a program that never started LingoFuse, or one that has
// waited long enough for every background thread to finish) may call
// unload() explicitly. The destructor will not do so on its own.
// =============================================================================

#include <stdexcept>
#include <string>
#include <unordered_map>

#ifdef _WIN32
#  include <windows.h>
#else
#  include <dlfcn.h>
#endif

namespace lf {

class LoaderError : public std::runtime_error {
public:
    explicit LoaderError(const std::string& what)
        : std::runtime_error(what) {}
};

class Loader {
public:
    Loader() = default;
    Loader(const Loader&) = delete;
    Loader& operator=(const Loader&) = delete;

    // The destructor deliberately does NOT unload the library. See the
    // file-level comment for the full rationale. Use unload() if you
    // are certain that no LingoFuse worker thread is still running.
    ~Loader() = default;

    bool load(const std::string& runtime_dir) {
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

        void* h = ::dlopen(full.c_str(), RTLD_NOW | RTLD_GLOBAL);
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

    // Explicit unload. The caller is responsible for ensuring that no
    // LingoFuse worker thread is still executing inside the library.
    // In test programs that have called LF_Shutdown, this method must
    // NOT be called: LF_Shutdown is asynchronous and the safest policy
    // is to leave the library loaded until process exit.
    void unload() {
        if (!handle_) return;
#ifdef _WIN32
        ::FreeLibrary(reinterpret_cast<HMODULE>(handle_));
#else
        ::dlclose(handle_);
#endif
        handle_ = nullptr;
        path_.clear();
        cache_.clear();
    }

    // Drop ownership of the loaded library without unloading it.
    // After this call, is_loaded() returns false and the destructor
    // has nothing to release. The library remains mapped in the
    // process until the operating system unloads it at process exit.
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