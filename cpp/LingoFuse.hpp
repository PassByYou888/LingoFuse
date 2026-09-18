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
 *
 * All symbols live in the `lingofuse` namespace.
 *
 * ============================================================================
 * REQUIREMENTS
 * ============================================================================
 *   - C++17 or later (std::optional, if constexpr, structured bindings)
 *   - LingoFuse.h available on the include path
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
 *   - DataHandle::writeRaw() writes raw bytes WITHOUT any terminator.
 *
 * Reading is fault-tolerant, matching Pascal's LF_ReadString:
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
 * `readString()`, `read(std::string&)`, `readBytes()` and their C-level
 * counterparts `LF_ReadString` / `LF_ReadStringBytes` all follow the same
 * three cases. Cross-language wrappers (Python / C# / Pascal) behave
 * identically.
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
 *         lingofuse::DataHandle param("add");
 *         param.write(int32_t{5});
 *         param.write(int32_t{7});
 *
 *         auto result = app.localCall(param);
 *         int32_t sum = 0;
 *         result.read(sum);
 *         std::cout << "5 + 7 = " << sum << '\n';
 *     } catch (const std::exception& e) {
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
 *
 * ============================================================================
 * CALLBACK CONTEXT (CRITICAL)
 * ============================================================================
 * All callbacks registered through the C API (LF_CallFunc / LF_NotifyFunc /
 * LF_NetworkEventFunc) execute on background worker threads. Inside a
 * callback:
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
 *   - App: calls LF_FreeApp on destruction (detach; the object itself
 *     remains in the global pool until LF_Shutdown).
 *   - LibraryLoader: internally reference-counted; the underlying
 *     LF_FreeLibrary is invoked only when the LAST instance is destroyed.
 *   - Call lingofuse::shutdown() at the end of your program to release
 *     the global pool held by the library.
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
 */

#pragma once

#include "LingoFuse.h"

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
      * Read methods return bool (true on success).
      */
    class DataHandle {
    public:
        /**
         * @brief Create a new data handle bound to the given API name.
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

        /* ---- String and byte-sequence I/O ---- */

        /**
         * @brief Append a UTF-8 string followed by a null terminator (#0).
         *
         * Throws Error on failure. Returns nothing; use `s.size()` if you need
         * the byte count.
         */
        void write(const std::string& s) {
            if (!h_) {
                throw Error(ErrorCode::NullHandle,
                    "DataHandle::write(string): null handle");
            }
            if (LF_WriteString(h_, s.c_str()) != 1) {
                throw Error(ErrorCode::WriteFailed,
                    "DataHandle::write(string): LF_WriteString failed");
            }
        }

        /**
         * @brief Append a raw byte vector followed by a null terminator (#0).
         *
         * The vector may contain embedded #0 bytes; they are preserved.
         */
        void write(const std::vector<std::uint8_t>& v) {
            if (!h_) {
                throw Error(ErrorCode::NullHandle,
                    "DataHandle::write(vector): null handle");
            }
            const void* data = v.empty() ? nullptr : v.data();
            if (LF_WriteStringBytes(h_, data,
                static_cast<int64_t>(v.size())) != 1) {
                throw Error(ErrorCode::WriteFailed,
                    "DataHandle::write(vector): "
                    "LF_WriteStringBytes failed");
            }
        }

        /**
         * @brief Read a null-terminated UTF-8 string from the cursor.
         *
         * Fault-tolerant:
         *   - If a #0 is found, the bytes before it are returned and the
         *     cursor is advanced past the #0.
         *   - If no #0 is found, the entire remaining buffer is consumed and
         *     returned, and the cursor is advanced to (buffer size + 1),
         *     i.e. ONE BYTE PAST the end. The underlying library implicitly
         *     grows the buffer by one byte to accommodate this, matching
         *     Pascal's LF_SetPos(Hnd, e + 1).
         *   - On failure (cursor at end, or handle null), returns an empty
         *     string and the cursor is unchanged.
         */
        std::string readString() {
            std::string out;
            read(out);
            return out;
        }

        /**
         * @brief Read a null-terminated UTF-8 string into `out`.
         * @return true on success, false if no data was available.
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

            const auto [ptr, len] = scanUntilNul(start, total);
            if (ptr == nullptr) return false;

            out.assign(reinterpret_cast<const char*>(ptr),
                static_cast<std::size_t>(len));
            return true;
        }

        /**
         * @brief Read a byte sequence terminated by #0 or by the end of the
         *        buffer, into a vector.
         *
         * Fault-tolerant; see readString() for the exact rules and cursor
         * semantics. Returns an empty vector if no data was available, and
         * the cursor is unchanged in that case.
         */
        std::vector<std::uint8_t> readBytes() {
            std::vector<std::uint8_t> out;
            if (!h_) return out;

            const std::int64_t start = LF_GetPos(h_);
            const std::int64_t total = LF_GetSize(h_);
            if (start < 0 || start >= total) return out;

            const auto [ptr, len] = scanUntilNul(start, total);
            if (ptr == nullptr) return out;

            out.assign(ptr, ptr + len);
            return out;
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

        /**
         * @brief Scan the buffer from `start` until the first #0, then
         *        advance the cursor to (end + 1).
         *
         * Returns a pointer+length pair describing the payload bytes:
         *   - `first`  points to the start of the payload (never null on
         *              success; returns {nullptr, 0} if the underlying
         *              buffer pointer is null, in which case the cursor is
         *              left unchanged).
         *   - `second` is the number of bytes before the #0, or the number
         *              of bytes to the end of the buffer if no #0 was found.
         *
         * After a successful scan, the cursor has been advanced to
         * (end + 1). When no #0 is found, `end == total` and the cursor
         * becomes `total + 1`; the underlying library then implicitly grows
         * the buffer by one byte, matching Pascal's LF_SetPos(Hnd, e + 1).
         *
         * Preconditions (already validated by the callers):
         *   - `h_` is non-null
         *   - 0 <= start < total
         */
        std::pair<const std::uint8_t*, std::int64_t>
            scanUntilNul(std::int64_t start, std::int64_t total) {
            const auto* base =
                static_cast<const std::uint8_t*>(LF_GetBuffer(h_));
            if (base == nullptr) {
                return { nullptr, 0 };
            }

            std::int64_t end = start;
            while (end < total && base[end] != 0) {
                ++end;
            }

            LF_SetPos(h_, end + 1);
            return { base + start, end - start };
        }
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

    /* ---- Remote invocation ---- */

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