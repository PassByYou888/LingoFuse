/**
 * @file LingoFuse.hpp
 * @brief Modern C++17 RAII wrapper for the LingoFuse dynamic library.
 *
 * This header provides a header-only, STL-flavoured, RAII-based interface
 * to the C API declared in LingoFuse.h. It manages resource lifetimes
 * automatically and uses standard C++ idioms throughout:
 *
 *   - std::string / std::vector / std::string_view
 *   - std::function for network event handlers
 *   - std::shared_ptr for LibraryLoader reference counting
 *   - std::optional for non-throwing tryCall()
 *   - std::runtime_error for a uniform exception type
 *   - lambdas / std::function for the modern async call model
 *   - nlohmann::json for JSON payloads (through lf_io.hpp)
 *
 * All symbols live in the `lingofuse` namespace.
 *
 * ============================================================================
 * REQUIREMENTS
 * ============================================================================
 *   - C++17 or later (std::optional, if constexpr, structured bindings)
 *   - LingoFuse.h    available on the include path
 *   - lf_io.hpp      available on the include path (pulls in json.hpp)
 *   - json.hpp       available on the include path (nlohmann/json)
 *
 * ============================================================================
 * LIBRARY LOADING CONTRACT (READ THIS FIRST)
 * ============================================================================
 *
 * The C ABI layer is DYNAMICALLY LOADED. Before LF_LoadLibrary() is called,
 * every LF_* function pointer is null. Invoking any LF_* function without a
 * prior successful LF_LoadLibrary() is undefined behaviour (typically a
 * null-pointer dereference).
 *
 * In this header, `lingofuse::LibraryLoader` performs both LF_LoadLibrary()
 * (in its constructor) and LF_FreeLibrary() (when the last LibraryLoader
 * instance is destroyed). Construct a LibraryLoader as the very first
 * object in main(), before any other LingoFuse code:
 *
 *     int main() {
 *         lingofuse::LibraryLoader loader;   // loads the runtime
 *         // ... everything else ...
 *         return 0;                          // unloads the runtime
 *     }
 *
 * If LF_LoadLibrary fails, the constructor throws
 * lingofuse::Error(ErrorCode::LibraryLoadFailed).
 *
 * If you prefer to call LF_LoadLibrary() / LF_FreeLibrary() manually, be
 * aware that LF_LoadLibrary() must still be the first LF_* call in the
 * process.
 *
 * ============================================================================
 * PAYLOAD I/O DELEGATION TO lf_io.hpp
 * ============================================================================
 * The string and JSON payload methods of DataHandle delegate to
 * `lingofuse::io` (lf_io.hpp), which is the single source of truth for
 * the whole C++ toolchain:
 *
 *     - the JSON serialization policy  (ensure_ascii=false),
 *     - the NUL framing on the wire    (trailing #0 byte),
 *     - the NUL-tolerant read behaviour (read to end when no NUL).
 *
 * The public signatures of every delegating method are preserved
 * exactly. Specifically:
 *
 *     DataHandle::write(std::string)          -> io::write_string
 *     DataHandle::write(std::vector<uint8_t>) -> io::write_string_bytes
 *     DataHandle::readString()                -> io::read_string
 *     DataHandle::read(std::string&)          -> io::read_string
 *     DataHandle::readBytes()                 -> io::read_string_bytes
 *
 * Two new methods expose the JSON path directly, mirroring the Python
 * DataHandle API:
 *
 *     DataHandle::writeJson(const nlohmann::json&)  -> io::write_json
 *     DataHandle::readJson()                        -> io::read_json
 *
 * The raw byte methods (writeRaw / readRaw) and the atomic scalar I/O
 * methods (write<int32_t>, read<float>, ...) are NOT affected: they do
 * not use NUL framing and belong to a different protocol layer.
 *
 * Every failure raised by io::LfIoError is translated into a
 * `lingofuse::Error` with the appropriate ErrorCode, so callers of
 * this wrapper never see the lower-level exception type.
 *
 * ============================================================================
 * STRING ENCODING - UTF-8 IS MANDATORY
 * ============================================================================
 * All string parameters are passed as std::string (or std::string_view) and
 * their bytes are forwarded directly to the C layer, which expects UTF-8
 * plus a null terminator. Ensure your std::string holds valid UTF-8 bytes.
 * No transcoding is performed by this wrapper.
 *
 * ============================================================================
 * NULL TERMINATOR CONTRACT
 * ============================================================================
 *   - DataHandle::write(std::string) appends a #0 terminator automatically.
 *   - DataHandle::write(std::vector<uint8_t>) also appends a #0 terminator.
 *   - DataHandle::writeJson() appends a #0 terminator.
 *   - DataHandle::writeRaw() writes raw bytes WITHOUT any terminator.
 *
 * Reading is fault-tolerant, matching Pascal's LF_ReadString and the
 * Python lf_io module:
 *
 *   Case A - a #0 is found within the buffer:
 *       The bytes before the #0 are returned, and the cursor is advanced
 *       to just past the #0.
 *
 *   Case B - no #0 is found (raw JSON from an HTTP bridge, etc.):
 *       All remaining bytes are returned, and the cursor is advanced to
 *       (buffer size + 1) -- ONE BYTE PAST the end. The underlying library
 *       implicitly grows the buffer by one byte to accommodate this,
 *       exactly like Pascal's LF_SetPos(Hnd, e + 1).
 *
 *   Case C - the cursor is already at or past the end:
 *       Returns an empty result (or false), cursor unchanged.
 *
 * `readString()`, `read(std::string&)`, `readBytes()` and `readJson()`
 * all follow the same three cases. The C / Python / Pascal wrappers
 * behave identically.
 *
 * ============================================================================
 * DATA HANDLE KINDS - AUTO-RECYCLED vs PERMANENT
 * ============================================================================
 * The library provides two flavours of data handles:
 *
 *   1. AUTO-RECYCLED (created by DataHandle(const std::string&)).
 *        - Backed by LF_CreateData().
 *        - Added to the library's idle pool.
 *        - The pool scans every 5 seconds and frees any handle that has
 *          been idle (no accessor call) for more than 10 minutes.
 *        - Any accessor (getSize / seek / read / write) refreshes the
 *          idle timestamp.
 *        - The destructor calls LF_FreeData(), which only marks the
 *          handle for release; the actual release happens on the next
 *          pool scan (at most 5 seconds later).
 *        - Recommended for the vast majority of use cases.
 *
 *   2. PERMANENT (created by DataHandle::createPermanent()).
 *        - Backed by LF_CreateData_Permanent().
 *        - NOT added to the library's idle pool.
 *        - The automatic idle-timeout reclaimer will NEVER free it, no
 *          matter how long it has been idle.
 *        - The destructor calls LF_FreeData(), which releases the handle
 *          IMMEDIATELY (synchronously).
 *        - Recommended for handles that must survive for the entire
 *          process lifetime (cached request templates, long-lived
 *          scratch buffers, global registries, etc.).
 *
 * Both kinds are released by LF_Shutdown() when the process terminates.
 * Do not forget to call lingofuse::shutdown() before unloading the
 * runtime.
 *
 * ============================================================================
 * SIDE-DATA ACCESSORS ON DataHandle (getP2PUid / getP2PName)
 * ============================================================================
 * The framework injects two identity fields into every inbound request
 * payload BEFORE transmission, on the SENDER side. Pascal side, for
 * reference:
 *
 *     TC40_LF_Client.Send_*
 *         -> TMemory_Param_Tool.Rebuild_UID_and_P2PName
 *         -> writes two fields into the payload header:
 *                FromUID       (32 bytes)
 *                FromP2PName   (UTF-8 string)
 *
 * These are "side data": they are NOT properties of the handle itself.
 * They are metadata the sender wrote into the payload, so the receiver
 * sees them only on the INPUT handle it receives from the framework.
 *
 * DataHandle therefore exposes two accessors that are valid ONLY on an
 * INPUT handle (i.e. the `inp` argument of a registered Call / Notify
 * callback):
 *
 *     handle.getP2PUid()   -> a 32-byte std::array
 *     handle.getP2PName()  -> a std::string (empty if unset)
 *
 * Calling either accessor on an OUTPUT handle or on a caller-created
 * handle is a well-defined no-op: the library logs a warning and returns
 * a zero-filled UID / empty string. The accessors never throw and never
 * return a raw pointer to the caller.
 *
 * {!!!!!  LF_Get_P2P_UID RETURNS A POINTER, NOT A VALUE  !!!!!}
 * At the C ABI level, LF_Get_P2P_UID returns a `const TP2P_UID*` (a
 * pointer to a library-owned 32-byte buffer that is released about 5
 * seconds after the call). The C++ DataHandle::getP2PUid() accessor
 * hides that pointer entirely: it copies the 32 bytes into a fresh
 * std::array that the caller can retain for as long as it likes. The
 * transient pointer is never exposed.
 *
 * ============================================================================
 * MODERN ASYNC CALL MODEL
 * ============================================================================
 *
 * LingoFuse's C ABI provides a family of asynchronous call primitives
 * (LF_Async_Call, LF_Async_Sequenced_Call, LF_UID_Async_Call,
 * LF_P2PNAME_Async_Call, ...) that return immediately and deliver their
 * result to a `LF_AsyncCallOnResult` callback on a background worker
 * thread. The raw C ABI requires a manual trampoline and a heap-allocated
 * "holder" object to carry a C++ lambda across the C boundary.
 *
 * This header hides that machinery behind a small, lambda-friendly API:
 *
 *     lingofuse::callAsync("CalcSvc", "add",
 *         {{"a", 5}, {"b", 7}},
 *         [](lingofuse::AsyncResult r) {
 *             if (!r.ok()) { std::cerr << r.error() << "\n"; return; }
 *             std::cout << r.handle().readJson().dump() << "\n";
 *         });
 *
 * The four entry points are:
 *
 *     callAsync            <-> LF_Async_Call
 *     callAsyncSequenced   <-> LF_Async_Sequenced_Call
 *     callAsyncByUid       <-> LF_UID_Async_Call
 *     callAsyncByP2PName   <-> LF_P2PNAME_Async_Call
 *
 * Each has two overloads:
 *
 *   A. DataHandle form:
 *
 *          callAsync(const std::string& app_name,
 *                    DataHandle& param,
 *                    F&& on_complete);
 *
 *      The caller owns the DataHandle. The C ABI copies the payload
 *      synchronously inside the call, so the handle may be destroyed
 *      immediately after callAsync() returns.
 *
 *   B. Convenience JSON form:
 *
 *          callAsync(const std::string& app_name,
 *                    const std::string& api_name,
 *                    const nlohmann::json& payload,
 *                    F&& on_complete);
 *
 *      A DataHandle is built internally, serialized with the toolchain's
 *      canonical JSON policy, and destroyed before callAsync() returns.
 *
 * {!!!!!  CALLBACK EXECUTION CONTEXT  !!!!!}
 * Every on_complete callback runs on a TCompute WORKER THREAD, NOT on
 * the caller's thread and NOT on the simulated main thread. Inside the
 * callback:
 *
 *     - DO NOT block (no sleep, no network I/O, no lock waits).
 *     - DO NOT call LF_Call / LF_Notify / LF_LocalCall / LF_PrepareDone
 *       / LF_Shutdown. This will deadlock.
 *     - DO NOT touch UI components.
 *     - DO NOT retain the AsyncResult's handle() reference beyond the
 *       callback body: the framework releases the underlying buffer
 *       the instant the callback returns.
 *
 * To use the result on another thread, COPY THE DATA OUT:
 *
 *     auto j = r.handle().readJson();     // fresh nlohmann::json
 *     my_main_thread_queue.post([j]() {   // safe to retain and use
 *         ui_label.setText(j.dump());
 *     });
 *
 * {!!!!!  DISPATCH FAILURE STILL FIRES THE CALLBACK  !!!!!}
 * If LF_Async_Call rejects the request before dispatching it (return
 * value 0), the wrapper invokes the user callback SYNCHRONOUSLY, on the
 * CALLER's thread, with an error AsyncResult. This means:
 *
 *     - There is no separate "return code" to check on the caller side.
 *       The "call failed" signal flows through the same error path
 *       (`if (!r.ok())`) as a remote-side failure.
 *     - The callback body must therefore be safe to run on ANY thread,
 *       including the caller's own thread. In practice this is a
 *       superset of the worker-thread restriction above, so any callback
 *       that follows the "do not block / do not call LF_* / do not touch
 *       UI" rule is already correct.
 *
 * {!!!!!  NO TIMEOUT / CANCELLATION  !!!!!}
 * The C ABI family has no timeout parameter and no cancellation handle.
 * If a request is dispatched but the response never arrives, the holder
 * object leaks and the callback is never called. In practice LingoFuse's
 * transport layer guarantees that every dispatched async request
 * eventually produces a callback (with either a result or an
 * empty-payload "timeout" result), so this is a theoretical rather than
 * a practical concern. Applications that need a hard timeout should
 * impose one at a higher layer (for example, by tracking outstanding
 * requests and abandoning them after a configured interval).
 *
 * ============================================================================
 * QUICK START
 * ============================================================================
 * @code
 * #include "LingoFuse.hpp"
 * #include <iostream>
 *
 * static void LF_CDECL add_cb(void*, void* in, void* out) {
 *     lingofuse::DataHandle in_h(static_cast<TDataHnd>(in), false);
 *     lingofuse::DataHandle out_h(static_cast<TDataHnd>(out), false);
 *     int32_t a = 0, b = 0;
 *     in_h.read(a);
 *     in_h.read(b);
 *     out_h.write(static_cast<int32_t>(a + b));
 * }
 *
 * int main() {
 *     try {
 *         lingofuse::LibraryLoader loader;
 *         lingofuse::App app("Calculator", "Demo");
 *         app.registerCall("add", "Add two ints", nullptr, add_cb);
 *
 *         // Synchronous local call.
 *         lingofuse::DataHandle param("add");
 *         param.write(int32_t{5});
 *         param.write(int32_t{7});
 *         auto result = app.localCall(param);
 *         int32_t sum = 0;
 *         result.read(sum);
 *         std::cout << "5 + 7 = " << sum << '\n';
 *
 *         // Asynchronous remote call, in the modern style.
 *         lingofuse::callAsync("Calculator", "add",
 *             {{"a", 5}, {"b", 7}},
 *             [](lingofuse::AsyncResult r) {
 *                 if (!r.ok()) {
 *                     std::cerr << "call failed: " << r.error() << '\n';
 *                     return;
 *                 }
 *                 std::cout << "async response: "
 *                           << r.handle().readJson().dump() << '\n';
 *             });
 *     }
 *     catch (const std::exception& e) {
 *         std::cerr << "Error: " << e.what() << '\n';
 *         return 1;
 *     }
 *     return 0;
 * }
 * @endcode
 *
 * ============================================================================
 * THREAD SAFETY
 * ============================================================================
 * All C API calls are thread-safe. Within this wrapper:
 *
 *   - Different DataHandle instances are independent and can be used
 *     concurrently without restriction.
 *   - The SAME DataHandle's write path (write / seek / reset) must be
 *     serialised by the caller; reads are safe.
 *   - LibraryLoader is internally reference-counted and safe to construct
 *     from any thread.
 *   - setNetworkEvent / clearNetworkEvent are protected by a process-wide
 *     mutex and can be called from any thread.
 *   - callAsync and its siblings are safe to call from any thread. The
 *     returned-void contract hides the trampoline and holder entirely.
 *
 * ============================================================================
 * CALLBACK CONTEXT (CRITICAL)
 * ============================================================================
 * All callbacks registered through the C API (LF_CallFunc / LF_NotifyFunc /
 * LF_NetworkEventFunc / LF_AsyncCallOnResult) execute on background worker
 * threads. Inside a callback:
 *
 *   - DO NOT block.
 *   - DO NOT call any remote invocation (LF_Call / LF_Notify /
 *     LF_Sequenced_Notify / LF_LocalCall) from a callback. This will
 *     deadlock.
 *   - DO NOT touch UI components without proper marshalling.
 *
 * ============================================================================
 * RESOURCE LIFETIME
 * ============================================================================
 *   - DataHandle: frees the underlying handle on destruction (if owned).
 *     Auto-recycled handles (regular constructor) are marked for pool
 *     release; permanent handles (createPermanent) are released
 *     synchronously.
 *   - App: calls LF_FreeApp on destruction (detach; the object itself
 *     remains in the global pool until LF_Shutdown).
 *   - LibraryLoader: internally reference-counted; the underlying
 *     LF_FreeLibrary is invoked only when the LAST instance is destroyed.
 *   - Call lingofuse::shutdown() at the end of your program to release
 *     the global pool held by the library.
 *   - callAsync: the holder object that carries the user's lambda is
 *     owned by the framework once the request is dispatched. It is
 *     released by the trampoline when the callback fires (or by the
 *     caller itself on a dispatch failure).
 *
 * ============================================================================
 * ERROR HANDLING
 * ============================================================================
 * All wrapper errors throw `lingofuse::Error` (derived from
 * std::runtime_error). The `code()` accessor returns an `ErrorCode` value
 * for programmatic dispatch:
 *
 *   try {
 *       ...
 *   } catch (const lingofuse::Error& e) {
 *       if (e.code() == lingofuse::ErrorCode::Timeout) { ... }
 *   }
 *
 * Async callbacks are the exception: they never throw out of the
 * callback. Instead they deliver an `AsyncResult` whose `ok()` is false
 * and whose `error()` carries a human-readable message. Any C++ exception
 * raised by the user's lambda is caught and logged to stderr; it is never
 * allowed to cross the C boundary.
 */

#pragma once

#include "LingoFuse.h"
#include "lf_io.hpp"     // Brings in lingofuse::io and nlohmann::json.

#include <array>
#include <cstdint>
#include <cstring>
#include <functional>
#include <memory>
#include <mutex>
#include <optional>
#include <stdexcept>
#include <string>
#include <string_view>
#include <type_traits>
#include <utility>
#include <vector>

namespace lingofuse {

    /* ============================================================================
     * Error handling
     * ============================================================================ */

     /**
      * @brief Category for a lingofuse::Error.
      */
    enum class ErrorCode {
        Generic = 0,          /**< Unclassified error.                  */
        LibraryLoadFailed,    /**< LF_LoadLibrary failed.               */
        NullHandle,           /**< A null handle was used.              */
        InvalidArgument,      /**< An argument was invalid.             */
        WriteFailed,          /**< A write operation failed.            */
        ReadFailed,           /**< A read operation failed.             */
        CallFailed,           /**< A remote call failed.                */
        RegistrationFailed,   /**< API registration failed.             */
        NotConnected,         /**< The framework is not initialised.    */
        Timeout,              /**< A remote call timed out.             */
    };

    /**
     * @brief Exception thrown by all wrapper methods on failure.
     *
     * Derives from std::runtime_error, so `catch (const std::exception&)`
     * still works. Use `code()` for programmatic dispatch.
     */
    class Error : public std::runtime_error {
    public:
        Error(ErrorCode c, const std::string& what)
            : std::runtime_error(what), code_(c) {}

        ErrorCode code() const noexcept { return code_; }

    private:
        ErrorCode code_;
    };

    /* ============================================================================
     * LibraryLoader - reference-counted RAII wrapper
     * ----------------------------------------------------------------------------
     * Multiple LibraryLoader instances may coexist. The underlying
     * LF_LoadLibrary is invoked exactly once (on the first construction), and
     * LF_FreeLibrary is invoked exactly once (when the last instance is
     * destroyed). This is implemented with a process-wide std::weak_ptr +
     * std::shared_ptr pair.
     *
     * This class is thread-safe for construction and destruction.
     *
     * Because LF_LoadLibrary must be the FIRST LF_* call in the process,
     * construct a LibraryLoader (or call LF_LoadLibrary manually) before
     * any other LingoFuse code.
     * ============================================================================ */

    class LibraryLoader {
    public:
        LibraryLoader() : handle_(acquire()) {}

        ~LibraryLoader() = default;

        LibraryLoader(const LibraryLoader&) = delete;
        LibraryLoader& operator=(const LibraryLoader&) = delete;
        LibraryLoader(LibraryLoader&&) noexcept = default;
        LibraryLoader& operator=(LibraryLoader&&) noexcept = default;

    private:
        std::shared_ptr<void> handle_;

        static std::weak_ptr<void>& singleton_weak() {
            static std::weak_ptr<void> w;
            return w;
        }

        static std::mutex& singleton_mutex() {
            static std::mutex m;
            return m;
        }

        static std::shared_ptr<void> acquire() {
            std::lock_guard<std::mutex> lock(singleton_mutex());
            auto& weak = singleton_weak();

            if (auto existing = weak.lock()) {
                return existing;   // reuse an active load
            }

            if (!LF_LoadLibrary()) {
                throw Error(ErrorCode::LibraryLoadFailed,
                    "LibraryLoader: LF_LoadLibrary failed");
            }

            // std::shared_ptr requires a non-null stored pointer when a
            // custom deleter is provided (the pointer is what the deleter
            // "receives"). We never obtain a real library base address
            // because LF_LoadLibrary stores it internally; the pointer value
            // `1` here is a PURE SENTINEL and is NEVER dereferenced. Only
            // the deleter runs, and it calls LF_FreeLibrary() when the last
            // reference to this shared_ptr goes away.
            //
            // Using a static address (e.g. &some_static) would work too,
            // but the arbitrary non-zero literal is the smallest, clearest
            // token that communicates "this is not a real pointer".
            std::shared_ptr<void> shared(
                reinterpret_cast<void*>(1),
                [](void*) { LF_FreeLibrary(); });

            weak = shared;
            return shared;
        }
    };

    /* ============================================================================
     * DataHandle - RAII wrapper around TDataHnd
     * ============================================================================ */

     /**
      * @brief Manages a TDataHnd and provides STL-flavoured access.
      *
      * The buffer is accessed sequentially through a read/write cursor.
      * `write` methods append at the cursor; `read` methods consume from it.
      *
      * Copy is disabled; move is supported. `DataHandle` is convertible to
      * bool (true if the handle is non-null).
      *
      * Write methods throw Error on failure.
      * Read methods return bool (true on success) or a value.
      *
      * The string and JSON payload methods delegate to lingofuse::io
      * (lf_io.hpp), which is the single source of truth for the NUL
      * framing and the JSON serialization policy.
      *
      * Two construction paths:
      *   - DataHandle(const std::string&)        auto-recycled handle
      *   - DataHandle::createPermanent(name)      permanent handle
      * See the file-level docstring ("DATA HANDLE KINDS") for the
      * difference.
      *
      * The side-data accessors getP2PUid() / getP2PName() are valid ONLY
      * on the `input` handle of a registered callback; see the file-level
      * docstring section "SIDE-DATA ACCESSORS".
      */
    class DataHandle {
    public:
        /**
         * @brief Create a new auto-recycled data handle bound to the given
         *        API name.
         *
         * The underlying handle is created with LF_CreateData(), which adds
         * it to the library's idle pool. The pool frees it after 10 minutes
         * of idle time (scanned every 5 seconds).
         *
         * @throws Error with ErrorCode::Generic if LF_CreateData returns NULL.
         */
        explicit DataHandle(const std::string& api_name)
            : h_(LF_CreateData(api_name.c_str())), owned_(true) {
            if (!h_) {
                throw Error(ErrorCode::Generic,
                    "DataHandle: LF_CreateData failed for '"
                    + api_name + "'");
            }
        }

        /**
         * @brief Wrap an existing handle.
         * @param h      Raw TDataHnd.
         * @param owned  If true, LF_FreeData is called on destruction. Pass
         *               false when borrowing a handle (e.g. inside a callback).
         */
        explicit DataHandle(TDataHnd h, bool owned) noexcept
            : h_(h), owned_(owned) {
        }

        DataHandle(DataHandle&& other) noexcept
            : h_(other.h_), owned_(other.owned_) {
            other.h_ = nullptr;
            other.owned_ = false;
        }

        DataHandle& operator=(DataHandle&& other) noexcept {
            if (this != &other) {
                reset();
                h_ = other.h_;
                owned_ = other.owned_;
                other.h_ = nullptr;
                other.owned_ = false;
            }
            return *this;
        }

        DataHandle(const DataHandle&) = delete;
        DataHandle& operator=(const DataHandle&) = delete;

        ~DataHandle() { reset(); }

        /* ---- Factory: permanent handle ---- */

        /**
         * @brief Create a new PERMANENT data handle bound to the given API
         *        name.
         *
         * The underlying handle is created with LF_CreateData_Permanent().
         *
         * Difference from the regular DataHandle(const std::string&)
         * constructor:
         *   - NOT added to the library's idle pool.
         *   - The automatic idle-timeout reclaimer will NEVER free it, no
         *     matter how long it has been idle.
         *   - On destruction, LF_FreeData() releases it IMMEDIATELY
         *     (synchronously), rather than marking it for a later pool scan.
         *
         * When to use:
         *   - Handles that must survive for the entire lifetime of the
         *     process, or for an unbounded period (cached request templates,
         *     long-lived scratch buffers, global registries, etc.).
         *
         * When NOT to use:
         *   - Short-lived or one-shot handles. Use the regular constructor
         *     for those, so the pool can reclaim any handle you forget to
         *     free.
         *
         * [PITFALL - NO-OP WINDOW]
         *   The underlying LF_FreeData is a no-op while the simulated main
         *   thread is not active (before LF_PrepareDone or after
         *   LF_ExitMainThread). Permanent handles created in that window
         *   stay allocated until the process terminates. In practice this
         *   is safe: the OS reclaims the process memory on exit.
         *
         * @throws Error with ErrorCode::Generic if LF_CreateData_Permanent
         *         returns NULL.
         */
        static DataHandle createPermanent(const std::string& api_name) {
            TDataHnd h = LF_CreateData_Permanent(api_name.c_str());
            if (!h) {
                throw Error(ErrorCode::Generic,
                    "DataHandle::createPermanent: "
                    "LF_CreateData_Permanent failed for '"
                    + api_name + "'");
            }
            return DataHandle(h, true);
        }

        /* ---- Handle accessors ---- */

        TDataHnd get() const noexcept { return h_; }

        explicit operator bool() const noexcept { return h_ != nullptr; }

        /// Release ownership without freeing; caller must free the handle.
        TDataHnd release() noexcept {
            TDataHnd tmp = h_;
            h_ = nullptr;
            owned_ = false;
            return tmp;
        }

        /// Free the handle if owned and reset to null. Idempotent.
        void reset() noexcept {
            if (owned_ && h_) {
                LF_FreeData(h_);
            }
            h_ = nullptr;
            owned_ = false;
        }

        /* ---- Scalar I/O (arithmetic types, excluding bool) ----
         *
         * The SFINAE constraint is intentionally narrow:
         *   - std::is_arithmetic<T> is required.
         *   - bool is excluded because its wire representation is not defined.
         *   - Pointers, C arrays, and class types are rejected at compile time.
         */

        template <typename T,
            std::enable_if_t<
            std::is_arithmetic<T>::value &&
            !std::is_same<std::remove_cv_t<T>, bool>::value,
            int> = 0>
        void write(T value) {
            if (!h_) {
                throw Error(ErrorCode::NullHandle,
                    "DataHandle::write: null handle");
            }
            const auto written = LF_WriteBuffer(h_, &value,
                static_cast<int64_t>(sizeof(T)));
            if (written != static_cast<int64_t>(sizeof(T))) {
                throw Error(ErrorCode::WriteFailed,
                    "DataHandle::write: LF_WriteBuffer failed");
            }
        }

        template <typename T,
            std::enable_if_t<
            std::is_arithmetic<T>::value &&
            !std::is_same<std::remove_cv_t<T>, bool>::value,
            int> = 0>
        bool read(T& out) {
            if (!h_) return false;
            const auto got = LF_ReadBuffer(h_, &out,
                static_cast<int64_t>(sizeof(T)));
            return got == static_cast<int64_t>(sizeof(T));
        }

        /* ---- Raw byte I/O ---- */

        /// Append `len` raw bytes at the cursor. No terminator is added.
        void writeRaw(const void* data, std::size_t len) {
            if (!h_) {
                throw Error(ErrorCode::NullHandle,
                    "DataHandle::writeRaw: null handle");
            }
            if (len == 0) return;
            if (data == nullptr) {
                throw Error(ErrorCode::InvalidArgument,
                    "DataHandle::writeRaw: null data with len > 0");
            }
            const auto written = LF_WriteBuffer(h_, data,
                static_cast<int64_t>(len));
            if (written != static_cast<int64_t>(len)) {
                throw Error(ErrorCode::WriteFailed,
                    "DataHandle::writeRaw: LF_WriteBuffer failed");
            }
        }

        /// Read up to `len` raw bytes into `data`. Returns bytes actually read.
        std::size_t readRaw(void* data, std::size_t len) {
            if (!h_ || len == 0) return 0;
            if (data == nullptr) return 0;
            const auto got = LF_ReadBuffer(h_, data,
                static_cast<int64_t>(len));
            if (got < 0) return 0;
            return static_cast<std::size_t>(got);
        }

        /* ---- String and byte-sequence I/O (delegated to lf_io.hpp) ---- */

        /**
         * @brief Append a UTF-8 string followed by a null terminator (#0).
         *
         * Delegates to lingofuse::io::write_string.
         *
         * Throws Error on failure.
         */
        void write(const std::string& s) {
            if (!h_) {
                throw Error(ErrorCode::NullHandle,
                    "DataHandle::write(string): null handle");
            }
            try {
                io::write_string(h_, s);
            }
            catch (const io::LfIoError& e) {
                throw Error(ErrorCode::WriteFailed, e.what());
            }
        }

        /**
         * @brief Append a raw byte vector followed by a null terminator (#0).
         *
         * Delegates to lingofuse::io::write_string_bytes. The vector may
         * contain embedded #0 bytes; they are preserved.
         */
        void write(const std::vector<std::uint8_t>& v) {
            if (!h_) {
                throw Error(ErrorCode::NullHandle,
                    "DataHandle::write(vector): null handle");
            }
            try {
                io::write_string_bytes(h_, v.data(), v.size());
            }
            catch (const io::LfIoError& e) {
                throw Error(ErrorCode::WriteFailed, e.what());
            }
        }

        /**
         * @brief Serialize `obj` as UTF-8 JSON and write it with a #0
         *        terminator.
         *
         * Delegates to lingofuse::io::write_json, which uses the
         * toolchain-wide serialization policy:
         *
         *     nlohmann::json::dump(
         *         -1, ' ', false,
         *         nlohmann::json::error_handler_t::replace)
         *
         * i.e. compact output, literal UTF-8 (no \\uXXXX escapes),
         * and a safe error handler for invalid UTF-8 bytes.
         *
         * Throws Error on failure.
         */
        void writeJson(const nlohmann::json& obj) {
            if (!h_) {
                throw Error(ErrorCode::NullHandle,
                    "DataHandle::writeJson: null handle");
            }
            try {
                io::write_json(h_, obj);
            }
            catch (const io::LfIoError& e) {
                throw Error(ErrorCode::WriteFailed, e.what());
            }
        }

        /**
         * @brief Read a null-terminated UTF-8 string from the cursor.
         *
         * Delegates to lingofuse::io::read_string, which is fault-tolerant:
         *   - If a #0 is found, the bytes before it are returned and the
         *     cursor is advanced past the #0.
         *   - If no #0 is found, the entire remaining buffer is consumed
         *     and returned, and the cursor is advanced to (buffer size
         *     + 1), i.e. ONE BYTE PAST the end. The underlying library
         *     implicitly grows the buffer by one byte to accommodate
         *     this, matching Pascal's LF_SetPos(Hnd, e + 1).
         *   - If the cursor is at or past the end, returns an empty
         *     string and the cursor is unchanged.
         *
         * Errors raised by the underlying layer are translated into an
         * empty return value, preserving the historical signature.
         */
        std::string readString() {
            if (!h_) return {};
            try {
                return io::read_string(h_);
            }
            catch (const io::LfIoError&) {
                return {};
            }
        }

        /**
         * @brief Read a null-terminated UTF-8 string into `out`.
         * @return true on success, false if no data was available.
         *
         * Delegates to lingofuse::io::read_string. The `start >= total`
         * precondition is checked here so that an exhausted buffer
         * returns false (matching the historical behaviour) rather
         * than an empty string.
         *
         * See readString() for the fault-tolerant rules and the exact
         * cursor semantics.
         */
        bool read(std::string& out) {
            out.clear();
            if (!h_) return false;

            const std::int64_t start = LF_GetPos(h_);
            const std::int64_t total = LF_GetSize(h_);
            if (start < 0 || start >= total) return false;

            try {
                out = io::read_string(h_);
                return true;
            }
            catch (const io::LfIoError&) {
                return false;
            }
        }

        /**
         * @brief Read a byte sequence terminated by #0 or by the end of
         *        the buffer, into a vector.
         *
         * Delegates to lingofuse::io::read_string_bytes. Fault-tolerant;
         * see readString() for the exact rules and cursor semantics.
         * Returns an empty vector when no data was available or when the
         * underlying layer reports an error.
         */
        std::vector<std::uint8_t> readBytes() {
            if (!h_) return {};
            try {
                return io::read_string_bytes(h_);
            }
            catch (const io::LfIoError&) {
                return {};
            }
        }

        /**
         * @brief Read a UTF-8 JSON payload from the cursor and return it.
         *
         * Delegates to lingofuse::io::read_json, which is strict: any
         * failure (invalid UTF-8, invalid JSON, empty payload) raises
         * io::LfIoError. This wrapper converts both a null-handle case
         * and an io::LfIoError into a default-constructed nlohmann::json
         * (JSON null), preserving the historical signature of an
         * "empty payload -> null" convention.
         *
         * Callers that want the strict behaviour should call
         * lingofuse::io::read_json on the raw handle directly.
         */
        nlohmann::json readJson() {
            if (!h_) return nlohmann::json();
            try {
                return io::read_json(h_);
            }
            catch (const io::LfIoError&) {
                return nlohmann::json();
            }
        }

        /* ---- Side-data accessors (identity of the SENDER) ----
         *
         * These accessors read the "side data" that the SENDER'S transport
         * layer wrote into the payload header before transmission. They
         * are valid ONLY on an INPUT handle:
         *
         *     VALID    -- the `inp` argument of a registered Call / Notify
         *                 callback, or the input of a local call.
         *     INVALID  -- an OUTPUT handle, or a caller-created handle.
         *                 The library logs a warning and returns a
         *                 zero-filled UID / empty string.
         *
         * Both accessors are safe to call from any thread. They never
         * throw and never expose a raw pointer.
         *
         * {!!!!!  LF_Get_P2P_UID RETURNS A POINTER, NOT A VALUE  !!!!!}
         * At the C ABI level, LF_Get_P2P_UID returns a `const TP2P_UID*`
         * (a pointer to a library-owned 32-byte buffer released about
         * 5 seconds after the call). getP2PUid() copies the 32 bytes
         * into a fresh std::array that the caller owns, so the transient
         * pointer is never exposed and the value is safe to retain.
         */

         /**
          * @brief Return the sender's 32-byte UID.
          *
          * Valid ONLY on the `inp` argument of a registered callback.
          * On any other handle, returns a zero-filled UID.
          *
          * The returned std::array is a fresh copy; it is fully detached
          * from the library's transient buffer and safe to retain.
          */
        std::array<std::uint8_t, 32> getP2PUid() const {
            std::array<std::uint8_t, 32> out{};
            const TP2P_UID* uid_ptr = LF_Get_P2P_UID(h_);
            if (uid_ptr != nullptr) {
                std::memcpy(out.data(), uid_ptr->bytes, 32);
            }
            return out;
        }

        /**
         * @brief Return the sender's P2P group name as a std::string.
         *
         * Valid ONLY on the `inp` argument of a registered callback.
         * On any other handle, returns an empty string.
         *
         * The returned std::string is a fresh copy; it is fully detached
         * from the library's transient buffer and safe to retain.
         */
        std::string getP2PName() const {
            const char* name_ptr = LF_Get_P2P_Name(h_);
            if (name_ptr == nullptr) return {};
            return std::string(name_ptr);
        }

        /* ---- Cursor and size ---- */

        /// Set the read/write cursor.
        void seek(std::int64_t pos) {
            if (h_) LF_SetPos(h_, pos);
        }

        /// Return the current cursor.
        std::int64_t tell() const {
            return h_ ? LF_GetPos(h_) : 0;
        }

        /// Return the total buffer size in bytes.
        std::int64_t size() const {
            return h_ ? LF_GetSize(h_) : 0;
        }

        /// Return a read-only view of the internal buffer (do not free).
        const std::uint8_t* data() const {
            return h_ ? static_cast<const std::uint8_t*>(LF_GetBuffer(h_))
                : nullptr;
        }

    private:
        TDataHnd h_ = nullptr;
        bool     owned_ = false;
    };

    /* ============================================================================
     * AsyncResult - outcome of an asynchronous call
     * ============================================================================
     *
     * NOTE ON DECLARATION ORDER:
     * This class is defined AFTER DataHandle, because it stores a
     * DataHandle by value. Defining it before DataHandle would require
     * a forward declaration plus out-of-line method definitions, which
     * adds noise without benefit. Keeping the definition here makes the
     * member type fully visible and lets the compiler lay out AsyncResult
     * directly.
     *
     * Every on_complete callback registered through callAsync and its
     * siblings receives an AsyncResult by value. The AsyncResult carries
     * either a SUCCESS handle (borrowed from the framework; valid only
     * inside the callback body) or a failure message.
     *
     * Success path:
     *
     *     AsyncResult r = ...;   // constructed internally by the trampoline
     *     if (r.ok()) {
     *         auto j = r.handle().readJson();  // fresh object, safe to keep
     *     }
     *
     * Failure path:
     *
     *     if (!r.ok()) {
     *         std::cerr << "async call failed: " << r.error() << '\n';
     *     }
     *
     * {!!!!!  OWNERSHIP OF handle()  !!!!!}
     * The DataHandle returned by handle() is BORROWED (owned = false).
     * The framework releases the underlying buffer the instant the
     * callback returns. Any data the caller wants to keep MUST be copied
     * out of the handle inside the callback body.
     *
     * Do NOT:
     *   - call LF_FreeData on it (it is not yours),
     *   - retain the DataHandle or its buffer pointer across the callback,
     *   - hand the handle to another thread.
     * ============================================================================ */
    class AsyncResult {
    public:
        /** Success constructor. Used by the trampoline. */
        explicit AsyncResult(TDataHnd raw_handle) noexcept
            : handle_(raw_handle, false)
            , ok_(true) {
        }

        /** Failure constructor. Used for dispatch failure / internal error. */
        explicit AsyncResult(std::string error_msg) noexcept
            : handle_(nullptr, false)
            , ok_(false)
            , error_(std::move(error_msg)) {
        }

        AsyncResult(AsyncResult&&) noexcept = default;
        AsyncResult& operator=(AsyncResult&&) noexcept = default;

        AsyncResult(const AsyncResult&) = delete;
        AsyncResult& operator=(const AsyncResult&) = delete;

        /** True if the call succeeded and a result handle is available. */
        bool ok() const noexcept { return ok_; }

        /** Same as ok(). Enables `if (!r) { ... }`. */
        explicit operator bool() const noexcept { return ok_; }

        /**
         * @brief The result handle (borrowed; only valid inside the callback).
         *
         * Throws Error(NullHandle) if the call failed. Callers that are
         * unsure should check ok() first.
         */
        DataHandle& handle() noexcept { return handle_; }
        const DataHandle& handle() const noexcept { return handle_; }

        /**
         * @brief Human-readable error message, empty on success.
         *
         * The exact strings are not part of a public contract. They are
         * suitable for logging and diagnostics but should not be compared
         * for equality by callers.
         */
        const std::string& error() const noexcept { return error_; }

    private:
        DataHandle  handle_;
        bool        ok_;
        std::string error_;
    };

    /* ============================================================================
     * App - RAII wrapper around TAppHnd
     * ============================================================================ */

     /**
      * @brief Manages an application handle and its registered APIs.
      *
      * An App groups a set of related APIs under a network-unique name. The
      * underlying TAppHnd is detached on destruction (LF_FreeApp); the object
      * itself is destroyed later by LF_Shutdown().
      *
      * Copy is disabled; move is supported.
      */
    class App {
    public:
        /**
         * @brief Create an application with the given name and description.
         * @throws Error with ErrorCode::Generic if LF_CreateApp returns NULL.
         */
        explicit App(const std::string& name,
            const std::string& desc = "")
            : h_(LF_CreateApp(name.c_str(), desc.c_str())),
            name_(name) {
            if (!h_) {
                throw Error(ErrorCode::Generic,
                    "App: LF_CreateApp failed for '" + name + "'");
            }
        }

        ~App() {
            if (h_) LF_FreeApp(h_);
        }

        App(App&& other) noexcept
            : h_(other.h_), name_(std::move(other.name_)) {
            other.h_ = nullptr;
            other.name_.clear();
        }

        App& operator=(App&& other) noexcept {
            if (this != &other) {
                if (h_) LF_FreeApp(h_);
                h_ = other.h_;
                name_ = std::move(other.name_);
                other.h_ = nullptr;
                other.name_.clear();
            }
            return *this;
        }

        App(const App&) = delete;
        App& operator=(const App&) = delete;

        /// Return the raw application handle.
        TAppHnd get() const noexcept { return h_; }

        explicit operator bool() const noexcept { return h_ != nullptr; }

        /// Return the application name.
        const std::string& name() const noexcept { return name_; }

        /* ---- API registration ---- */

        /**
         * @brief Register a Call API (request-response).
         *
         * The callback must be a plain C function with LF_CDECL calling
         * convention. Inside it, do not block and do not make remote calls.
         *
         * @return true on success, false if the API name already exists.
         */
        bool registerCall(const std::string& api_name,
            const std::string& desc,
            void* trigger,
            LF_CallFunc on_call) {
            if (!h_) {
                throw Error(ErrorCode::NullHandle,
                    "App::registerCall: app is null");
            }
            return LF_RegisterCall(h_, api_name.c_str(), desc.c_str(),
                trigger, on_call) == 1;
        }

        /**
         * @brief Register a Notify API (one-way).
         *
         * @return true on success, false if the API name already exists.
         */
        bool registerNotify(const std::string& api_name,
            const std::string& desc,
            void* trigger,
            LF_NotifyFunc on_notify) {
            if (!h_) {
                throw Error(ErrorCode::NullHandle,
                    "App::registerNotify: app is null");
            }
            return LF_RegisterNotify(h_, api_name.c_str(), desc.c_str(),
                trigger, on_notify) == 1;
        }

        /**
         * @brief Unregister an API by name.
         *
         * Removal is immediate locally; network propagation takes ~3 seconds.
         *
         * @return true if the API was found and removed.
         */
        bool unregister(const std::string& api_name) {
            if (!h_) {
                throw Error(ErrorCode::NullHandle,
                    "App::unregister: app is null");
            }
            return LF_Unregister(h_, api_name.c_str()) == 1;
        }

        /* ---- Local execution ---- */

        /**
         * @brief Execute a Call API locally (no network round-trip).
         * @return A new DataHandle owning the result (never null).
         */
        DataHandle localCall(const DataHandle& param) const {
            if (!h_) {
                throw Error(ErrorCode::NullHandle,
                    "App::localCall: app is null");
            }
            TDataHnd result = LF_LocalCall(h_, param.get());
            if (!result) {
                throw Error(ErrorCode::CallFailed,
                    "App::localCall: returned null handle");
            }
            return DataHandle(result, true);
        }

        /**
         * @brief Execute a Notify API locally (no network round-trip).
         */
        void localNotify(const DataHandle& param) const {
            if (!h_) {
                throw Error(ErrorCode::NullHandle,
                    "App::localNotify: app is null");
            }
            LF_LocalNotify(h_, param.get());
        }

        /* ---- Client binding ---- */

        /**
         * @brief Bind this application to all currently unbound clients.
         *
         * Must be called after LF_PrepareDone() returned 1 and while the
         * simulated main thread is active.
         *
         * @return Number of clients bound. 0 means no free client was available.
         */
        int bind() {
            if (!h_) {
                throw Error(ErrorCode::NullHandle, "App::bind: app is null");
            }
            return LF_BindApp(h_);
        }

    private:
        TAppHnd     h_ = nullptr;
        std::string name_;
    };

    /* ============================================================================
     * NetworkEventListener - abstract base for network event listeners
     * ============================================================================ */

     /**
      * @brief Base class for object-oriented network event listeners.
      *
      * Subclass and override onConnect / onDisconnect. Both methods run on a
      * background worker thread; see the file-level docstring for the full
      * threading contract.
      *
      * When installed via `setNetworkEvent(std::shared_ptr<NetworkEventListener>)`,
      * the shared_ptr is captured by the internal handler, guaranteeing the
      * listener stays alive for as long as it is installed.
      */
    class NetworkEventListener {
    public:
        virtual ~NetworkEventListener() = default;

        /// Called when a client becomes online.
        virtual void onConnect(const std::string& /*addr*/) {}

        /// Called when a client goes offline.
        virtual void onDisconnect(const std::string& /*addr*/) {}
    };

    /* ============================================================================
     * Network event registration - internal machinery
     * ============================================================================ */

    namespace detail {

        using ConnectHandler = std::function<void(const std::string&)>;
        using DisconnectHandler = std::function<void(const std::string&)>;

        inline std::mutex& handlerMutex() {
            static std::mutex m;
            return m;
        }

        inline ConnectHandler& connectHandler() {
            static ConnectHandler h;
            return h;
        }

        inline DisconnectHandler& disconnectHandler() {
            static DisconnectHandler h;
            return h;
        }

        /*
         * C ABI trampolines. These must be noexcept and must never let a C++
         * exception escape into the C stack.
         */
        inline void LF_CDECL connectTrampoline(const char* addr) noexcept {
            try {
                ConnectHandler handler;
                {
                    std::lock_guard<std::mutex> lock(handlerMutex());
                    handler = connectHandler();
                }
                if (handler) handler(addr ? std::string(addr) : std::string());
            }
            catch (...) {
                // Suppress all exceptions; the C stack must remain intact.
            }
        }

        inline void LF_CDECL disconnectTrampoline(const char* addr) noexcept {
            try {
                DisconnectHandler handler;
                {
                    std::lock_guard<std::mutex> lock(handlerMutex());
                    handler = disconnectHandler();
                }
                if (handler) handler(addr ? std::string(addr) : std::string());
            }
            catch (...) {
                // Suppress all exceptions; the C stack must remain intact.
            }
        }

    } // namespace detail

    /*
     * Forward declaration.
     *
     * clearNetworkEvent() is defined further below, but the shared_ptr overload
     * of setNetworkEvent() (which appears just below) needs to reference it.
     * Non-template inline functions require names to be declared before use.
     */
    inline void clearNetworkEvent();

    /* ============================================================================
     * MODERN ASYNC CALL MODEL - internal machinery
     * ============================================================================
     *
     * The C ABI's async family takes a raw function pointer plus a caller
     * supplied `void* data`. To carry a C++ lambda across that boundary we
     * allocate a small heap holder, hand its address to the C library as
     * `data`, and reconstruct the holder inside a static trampoline that
     * the C library calls back.
     *
     * The holder is type-erased behind AsyncCallHolderBase so that a single
     * trampoline works for any callable type. Ownership is transferred to
     * the trampoline the instant the C library invokes it: the trampoline
     * wraps the raw `void*` in a unique_ptr and destroys it after the user
     * callback returns.
     *
     * If the dispatch itself fails (LF_Async_Call returns 0, or throws),
     * ownership stays with the caller-side helper, which invokes the
     * callback synchronously with an error AsyncResult and then destroys
     * the holder.
     * ============================================================================ */

    namespace detail {

        class AsyncCallHolderBase {
        public:
            virtual ~AsyncCallHolderBase() = default;
            virtual void invoke_result(TDataHnd h) noexcept = 0;
            virtual void invoke_error(std::string msg) noexcept = 0;
        };

        template <typename F>
        class AsyncCallHolder final : public AsyncCallHolderBase {
        public:
            explicit AsyncCallHolder(F&& f) noexcept(
                std::is_nothrow_move_constructible<F>::value)
                : cb_(std::move(f)) {
            }

            void invoke_result(TDataHnd h) noexcept override {
                try {
                    cb_(AsyncResult(h));
                }
                catch (...) {
                    // A user callback must never let an exception escape
                    // into the C stack. Swallow and continue.
                }
            }

            void invoke_error(std::string msg) noexcept override {
                try {
                    cb_(AsyncResult(std::move(msg)));
                }
                catch (...) {
                }
            }

        private:
            F cb_;
        };

        /*
         * The single static trampoline used by every callAsync* entry
         * point. It reconstructs the holder from `data`, invokes it, and
         * then destroys it. The C library passes `result` as an opaque
         * DataHnd that is OWNED BY THE FRAMEWORK for the duration of the
         * callback; AsyncResult wraps it with owned = false.
         */
        inline void LF_CDECL async_call_trampoline(void* data, void* result) {
            std::unique_ptr<AsyncCallHolderBase> owner(
                static_cast<AsyncCallHolderBase*>(data));
            if (owner) {
                owner->invoke_result(static_cast<TDataHnd>(result));
            }
        }

        /*
         * Shared submission helper.
         *
         * `issue` is a callable that takes the holder's address as a void*
         * and returns the C ABI's int result code (1 = dispatched,
         * anything else = not dispatched). It must NOT throw; if it does,
         * the helper treats it as a dispatch failure.
         *
         * On success, ownership of the holder passes to the framework.
         * On failure, the helper invokes the user callback synchronously
         * with an error AsyncResult and then destroys the holder.
         */
        template <typename IssueFn, typename F>
        void submit_async_call(IssueFn&& issue, F&& on_complete) {
            using DecayedF = std::decay_t<F>;

            auto* holder = new AsyncCallHolder<DecayedF>(
                std::forward<F>(on_complete));

            int ret = 0;
            try {
                ret = issue(static_cast<void*>(holder));
            }
            catch (...) {
                ret = 0;
            }

            if (ret != 1) {
                // Dispatch failed; the framework will never invoke the
                // callback. Invoke it ourselves with an error result so
                // that the user has a single, unified error path.
                std::unique_ptr<AsyncCallHolderBase> owner(holder);
                owner->invoke_error(
                    "async call was not dispatched "
                    "(LF_Async_Call returned 0 or threw)");
            }
        }

    } // namespace detail

    /* ============================================================================
     * Global functions - thin forwarders to the C API
     * ============================================================================ */

     /* ---- Network preparation ---- */

     /// Clear any previously prepared services and clients.
    inline void resetPrepare() {
        LF_ResetPrepare();
    }

    /**
     * @brief Prepare a listening service.
     * @return A tag ID on success, or -1 on duplicate/invalid address.
     */
    inline int prepareService(const std::string& listening_addr,
        const std::string& physics_addr) {
        return LF_PrepareService(listening_addr.c_str(),
            physics_addr.c_str());
    }

    /**
     * @brief Prepare a client connection.
     *
     * Attach an app by passing a valid handle; pass nullptr for a pure
     * consumer. The same physical address can be used for only one client
     * unless the `Overlap_Connection` option is enabled via setOption().
     *
     * @return A tag ID on success, or -1 on duplicate address.
     */
    inline int prepareClient(const std::string& physics_addr,
        TAppHnd app = nullptr) {
        return LF_PrepareClient(physics_addr.c_str(), app);
    }

    /**
     * @brief Start the framework with all prepared services/clients.
     *
     * Returns 1 ONLY ONCE per process (without an intervening shutdown()).
     * A second call returns 0; do not interpret that as a failure.
     */
    inline int prepareDone() {
        return LF_PrepareDone();
    }

    /// Ask the simulated main thread to exit gracefully.
    inline void exitMainThread() {
        LF_ExitMainThread();
    }

    /* ---- Remote invocation (synchronous) ---- */

    /**
     * @brief Call a remote API synchronously.
     *
     * @return A DataHandle owning the response. Check `size() > 0` to detect
     *         a timeout or failure. The handle is never null.
     */
    inline DataHandle call(const std::string& app_name,
        const DataHandle& param,
        std::uint64_t timeout_ms) {
        TDataHnd result = LF_Call(app_name.c_str(), param.get(), timeout_ms);
        return DataHandle(result, true);
    }

    /**
     * @brief Call a remote API synchronously.
     *
     * @return std::nullopt if the call timed out or returned an empty result;
     *         otherwise an engaged optional holding the response.
     */
    inline std::optional<DataHandle> tryCall(const std::string& app_name,
        const DataHandle& param,
        std::uint64_t timeout_ms) {
        TDataHnd result = LF_Call(app_name.c_str(), param.get(), timeout_ms);
        DataHandle handle(result, true);
        if (handle.size() == 0) {
            return std::nullopt;
        }
        return std::optional<DataHandle>(std::move(handle));
    }

    /// Send a one-way notification (order not guaranteed).
    inline void notify(const std::string& app_name,
        const DataHandle& param) {
        LF_Notify(app_name.c_str(), param.get());
    }

    /// Send a one-way notification with FIFO ordering per (app, api) pair.
    inline void sequencedNotify(const std::string& app_name,
        const DataHandle& param) {
        LF_Sequenced_Notify(app_name.c_str(), param.get());
    }

    /* ============================================================================
     * MODERN ASYNC CALL MODEL - public API
     * ============================================================================
     *
     * Four entry points, each with two overloads (DataHandle form and
     * convenience JSON form). See the file-level docstring section
     * "MODERN ASYNC CALL MODEL" for the callback contract, the dispatch
     * failure semantics, and the lifetime rules.
     * ============================================================================ */

     /* ---- callAsync: LF_Async_Call ---- */

     /**
      * @brief Issue an asynchronous call by App name; the DataHandle form.
      *
      * The C ABI copies the payload synchronously inside LF_Async_Call, so
      * the caller-owned DataHandle may be destroyed the moment this
      * function returns.
      *
      * The callback is guaranteed to be invoked exactly once, either:
      *   - asynchronously on a TCompute worker thread, with the result, or
      *   - synchronously on the caller's thread, with a dispatch error.
      *
      * @param app_name     Target application name (UTF-8).
      * @param param        Caller-owned DataHandle containing the request.
      * @param on_complete  Callable; invoked as `void(AsyncResult)`.
      */
    template <typename F>
    inline void callAsync(const std::string& app_name,
        const DataHandle& param,
        F&& on_complete) {
        const std::string app_copy = app_name;   // decouple from caller
        TDataHnd raw = param.get();

        detail::submit_async_call(
            [&](void* holder) -> int {
                // cstr() returns a NUL-terminated std::string whose
                // lifetime extends to the end of the full-expression,
                // which is the LF_Async_Call call below. Safe.
                return LF_Async_Call(
                    io::cstr(app_copy).c_str(),
                    raw,
                    holder,
                    detail::async_call_trampoline);
            },
            std::forward<F>(on_complete));
    }

    /**
     * @brief Issue an asynchronous call by App name; the convenience
     *        JSON form.
     *
     * A DataHandle is built internally, serialized with the toolchain's
     * canonical JSON policy, and destroyed before this function returns.
     * If building or serializing the payload fails (for example on OOM),
     * the callback is still invoked, synchronously, with an error result.
     *
     * @param app_name     Target application name (UTF-8).
     * @param api_name     Target API name (UTF-8).
     * @param payload      Request payload, serialized as canonical JSON.
     * @param on_complete  Callable; invoked as `void(AsyncResult)`.
     */
    template <typename F>
    inline void callAsync(const std::string& app_name,
        const std::string& api_name,
        const nlohmann::json& payload,
        F&& on_complete) {
        using DecayedF = std::decay_t<F>;
        DecayedF cb(std::forward<F>(on_complete));

        std::unique_ptr<DataHandle> param;
        try {
            param = std::make_unique<DataHandle>(api_name);
            param->writeJson(payload);
        }
        catch (const std::exception& e) {
            auto* h = new detail::AsyncCallHolder<DecayedF>(std::move(cb));
            std::unique_ptr<detail::AsyncCallHolderBase> owner(h);
            owner->invoke_error(
                std::string("failed to build request payload: ") + e.what());
            return;
        }

        const std::string app_copy = app_name;
        TDataHnd raw = param->get();

        detail::submit_async_call(
            [&](void* holder) -> int {
                return LF_Async_Call(
                    io::cstr(app_copy).c_str(),
                    raw,
                    holder,
                    detail::async_call_trampoline);
            },
            std::move(cb));
    }

    /* ---- callAsyncSequenced: LF_Async_Sequenced_Call ---- */

    /**
     * @brief Issue an asynchronous sequenced call; FIFO ordering per
     *        (app, api) pair.
     */
    template <typename F>
    inline void callAsyncSequenced(const std::string& app_name,
        const DataHandle& param,
        F&& on_complete) {
        const std::string app_copy = app_name;
        TDataHnd raw = param.get();

        detail::submit_async_call(
            [&](void* holder) -> int {
                return LF_Async_Sequenced_Call(
                    io::cstr(app_copy).c_str(),
                    raw,
                    holder,
                    detail::async_call_trampoline);
            },
            std::forward<F>(on_complete));
    }

    /**
     * @brief Issue an asynchronous sequenced call; convenience JSON form.
     */
    template <typename F>
    inline void callAsyncSequenced(const std::string& app_name,
        const std::string& api_name,
        const nlohmann::json& payload,
        F&& on_complete) {
        using DecayedF = std::decay_t<F>;
        DecayedF cb(std::forward<F>(on_complete));

        std::unique_ptr<DataHandle> param;
        try {
            param = std::make_unique<DataHandle>(api_name);
            param->writeJson(payload);
        }
        catch (const std::exception& e) {
            auto* h = new detail::AsyncCallHolder<DecayedF>(std::move(cb));
            std::unique_ptr<detail::AsyncCallHolderBase> owner(h);
            owner->invoke_error(
                std::string("failed to build request payload: ") + e.what());
            return;
        }

        const std::string app_copy = app_name;
        TDataHnd raw = param->get();

        detail::submit_async_call(
            [&](void* holder) -> int {
                return LF_Async_Sequenced_Call(
                    io::cstr(app_copy).c_str(),
                    raw,
                    holder,
                    detail::async_call_trampoline);
            },
            std::move(cb));
    }

    /* ---- callAsyncByUid: LF_UID_Async_Call ---- */

    /**
     * @brief Issue an asynchronous call addressed by session UID.
     *
     * `uid` is the ARGUMENT-role 32-byte struct (TP2P_UID), passed by
     * value to the C ABI. The value can be obtained from a prior call's
     * AsyncResult handle via `getP2PUid()` (or from an equivalent source).
     */
    template <typename F>
    inline void callAsyncByUid(const TP2P_UID& uid,
        const DataHandle& param,
        F&& on_complete) {
        const TP2P_UID uid_copy = uid;
        TDataHnd raw = param.get();

        detail::submit_async_call(
            [&](void* holder) -> int {
                return LF_UID_Async_Call(
                    uid_copy,
                    raw,
                    holder,
                    detail::async_call_trampoline);
            },
            std::forward<F>(on_complete));
    }

    /**
     * @brief Issue an asynchronous call addressed by session UID;
     *        convenience JSON form.
     */
    template <typename F>
    inline void callAsyncByUid(const TP2P_UID& uid,
        const std::string& api_name,
        const nlohmann::json& payload,
        F&& on_complete) {
        using DecayedF = std::decay_t<F>;
        DecayedF cb(std::forward<F>(on_complete));

        std::unique_ptr<DataHandle> param;
        try {
            param = std::make_unique<DataHandle>(api_name);
            param->writeJson(payload);
        }
        catch (const std::exception& e) {
            auto* h = new detail::AsyncCallHolder<DecayedF>(std::move(cb));
            std::unique_ptr<detail::AsyncCallHolderBase> owner(h);
            owner->invoke_error(
                std::string("failed to build request payload: ") + e.what());
            return;
        }

        const TP2P_UID uid_copy = uid;
        TDataHnd raw = param->get();

        detail::submit_async_call(
            [&](void* holder) -> int {
                return LF_UID_Async_Call(
                    uid_copy,
                    raw,
                    holder,
                    detail::async_call_trampoline);
            },
            std::move(cb));
    }

    /* ---- callAsyncByP2PName: LF_P2PNAME_Async_Call ---- */

    /**
     * @brief Issue an asynchronous call addressed by P2P group name.
     *
     * Routing is NOT local-first: even if the caller process itself
     * hosts a client in the target group, the call is forwarded to the
     * server for dispatch (the server owns the load-balancing state).
     */
    template <typename F>
    inline void callAsyncByP2PName(const std::string& group_name,
        const DataHandle& param,
        F&& on_complete) {
        const std::string group_copy = group_name;
        TDataHnd raw = param.get();

        detail::submit_async_call(
            [&](void* holder) -> int {
                return LF_P2PNAME_Async_Call(
                    io::cstr(group_copy).c_str(),
                    raw,
                    holder,
                    detail::async_call_trampoline);
            },
            std::forward<F>(on_complete));
    }

    /**
     * @brief Issue an asynchronous call addressed by P2P group name;
     *        convenience JSON form.
     */
    template <typename F>
    inline void callAsyncByP2PName(const std::string& group_name,
        const std::string& api_name,
        const nlohmann::json& payload,
        F&& on_complete) {
        using DecayedF = std::decay_t<F>;
        DecayedF cb(std::forward<F>(on_complete));

        std::unique_ptr<DataHandle> param;
        try {
            param = std::make_unique<DataHandle>(api_name);
            param->writeJson(payload);
        }
        catch (const std::exception& e) {
            auto* h = new detail::AsyncCallHolder<DecayedF>(std::move(cb));
            std::unique_ptr<detail::AsyncCallHolderBase> owner(h);
            owner->invoke_error(
                std::string("failed to build request payload: ") + e.what());
            return;
        }

        const std::string group_copy = group_name;
        TDataHnd raw = param->get();

        detail::submit_async_call(
            [&](void* holder) -> int {
                return LF_P2PNAME_Async_Call(
                    io::cstr(group_copy).c_str(),
                    raw,
                    holder,
                    detail::async_call_trampoline);
            },
            std::move(cb));
    }

    /* ---- Options and diagnostics ---- */

    /// Adjust a global runtime option (see LingoFuse.h for the key list).
    inline void setOption(const std::string& option,
        const std::string& value) {
        LF_SetOption(option.c_str(), value.c_str());
    }

    /// True if the simulated main thread is currently running.
    inline bool checkMainThread() {
        return LF_CheckMainThread() != 0;
    }

    /**
     * @brief Probe whether the named application is available.
     *
     * WARNING: The underlying lookup uses a local cache that is updated via
     * network broadcasts. The cache may be up to ~3 seconds stale. This is a
     * probing tool, not an authoritative existence test.
     */
    inline bool checkApp(const std::string& app_name) {
        return LF_CheckApp(app_name.c_str()) != 0;
    }

    /**
     * @brief Probe whether the named API is available for the given app.
     *
     * WARNING: Same cache-based caveat as checkApp; may be up to ~3 seconds
     * stale.
     */
    inline bool checkApi(const std::string& app_name,
        const std::string& api_name) {
        return LF_CheckApi(app_name.c_str(), api_name.c_str()) != 0;
    }

    /// Number of pending messages in the internal status queue.
    inline int statusCount() {
        return LF_GetStatusCount();
    }

    /// Retrieve the next status message as a std::string (empty if none).
    inline std::string popStatus() {
        const char* ptr = LF_GetStatus();
        return ptr ? std::string(ptr) : std::string();
    }

    /// Inject a custom status message into the internal queue.
    inline void postStatus(const std::string& msg) {
        LF_PostStatus(msg.c_str());
    }

    /**
     * @brief Generate a globally unique application name.
     *
     * Must be called AFTER prepareDone() has returned 1, otherwise the
     * generated name lacks tunnel information. The underlying C pointer is
     * only valid for 5 seconds; this wrapper copies it immediately.
     */
    inline std::string generateAppName() {
        const char* ptr = LF_Generate_AppName();
        return ptr ? std::string(ptr) : std::string();
    }

    /**
     * @brief Retrieve the application name of an existing handle.
     *
     * Same 5-second validity rule as generateAppName; this wrapper copies the
     * string immediately.
     */
    inline std::string getAppName(TAppHnd app) {
        const char* ptr = LF_Get_AppName(app);
        return ptr ? std::string(ptr) : std::string();
    }

    /* ---- Shutdown ---- */

    /**
     * @brief Fully shut down the LingoFuse framework and release all resources.
     *
     * Safe to call multiple times. After shutdown, the library may be
     * re-initialised by calling prepareService / prepareClient / prepareDone.
     */
    inline void shutdown() {
        LF_Shutdown();
    }

    /* ============================================================================
     * Network event registration
     * ============================================================================ */

     /**
      * @brief Install std::function-based network event handlers.
      *
      * Passing an empty std::function disables that particular event.
      *
      * This is a REPLACE operation: calling it again discards any previously
      * installed handlers. Use clearNetworkEvent() to uninstall completely.
      *
      * Handlers run on a background worker thread; see the file-level docstring
      * for the threading contract.
      */
    inline void setNetworkEvent(detail::ConnectHandler    on_connect,
        detail::DisconnectHandler on_disconnect) {
        /*
         * The lock covers both the update of the stored handlers AND the
         * underlying LF_Set_Network_Event call. Without this, two concurrent
         * setNetworkEvent calls could race and leave the C library with
         * handlers that do not match the C++ state.
         */
        std::lock_guard<std::mutex> lock(detail::handlerMutex());

        detail::connectHandler() = std::move(on_connect);
        detail::disconnectHandler() = std::move(on_disconnect);

        LF_NetworkEventFunc c_connect =
            detail::connectHandler()
            ? &detail::connectTrampoline
            : nullptr;
        LF_NetworkEventFunc c_disconnect =
            detail::disconnectHandler()
            ? &detail::disconnectTrampoline
            : nullptr;

        LF_Set_Network_Event(c_connect, c_disconnect);
    }

    /**
     * @brief Install a NetworkEventListener.
     *
     * The shared_ptr is captured by the internal handlers, keeping the
     * listener alive for as long as it is installed. This prevents the
     * use-after-free that would occur if the listener were destroyed while
     * still registered.
     *
     * Use clearNetworkEvent() to uninstall.
     */
    inline void setNetworkEvent(std::shared_ptr<NetworkEventListener> listener) {
        if (!listener) {
            clearNetworkEvent();
            return;
        }

        // Capture the shared_ptr by value so the listener stays alive.
        setNetworkEvent(
            [listener](const std::string& addr) { listener->onConnect(addr); },
            [listener](const std::string& addr) { listener->onDisconnect(addr); }
        );
    }

    /**
     * @brief Uninstall all network event handlers.
     *
     * Safe to call multiple times. Also releases the strong references held
     * by the internal handlers, allowing any captured shared_ptr to be freed.
     */
    inline void clearNetworkEvent() {
        std::lock_guard<std::mutex> lock(detail::handlerMutex());

        detail::connectHandler() = nullptr;
        detail::disconnectHandler() = nullptr;

        LF_Set_Network_Event(nullptr, nullptr);
    }

} // namespace lingofuse