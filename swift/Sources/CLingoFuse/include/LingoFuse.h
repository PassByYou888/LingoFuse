/**
 * @file LingoFuse.h
 * @brief C explicit-linking wrapper for the LingoFuse dynamic library.
 *
 * This header declares the complete C ABI of the LingoFuse distributed RPC
 * framework. It mirrors the Pascal import unit `lingofuse_import.pas` and
 * the export table defined in `LingoFuse.lpr`.
 *
 * ============================================================================
 * EXPORTED FUNCTIONS (59 total, defined in LingoFuse.lpr)
 * ============================================================================
 *
 *   Data handles (12):
 *       LF_CreateData, LF_CreateData_Permanent, LF_FreeData,
 *       LF_GetBuffer, LF_WriteBuffer, LF_ReadBuffer,
 *       LF_GetPos, LF_SetPos, LF_GetSize, LF_SetSize,
 *       LF_Get_P2P_UID, LF_Get_P2P_Name
 *
 *   Application handles (5):
 *       LF_CreateApp, LF_FreeApp,
 *       LF_Generate_AppName, LF_Get_AppName, LF_BindApp
 *
 *   API registration, app-bound (3):
 *       LF_RegisterCall, LF_RegisterNotify, LF_Unregister
 *
 *   API registration, process-wide P2P (3):
 *       LF_Register_P2P_Call, LF_Register_P2P_Notify, LF_Unregister_P2P
 *
 *   Local execution (2):
 *       LF_LocalCall, LF_LocalNotify
 *
 *   Network preparation (5):
 *       LF_PrepareService, LF_PrepareClient,
 *       LF_ResetPrepare, LF_PrepareDone, LF_ExitMainThread
 *
 *   Remote invocation, app-name addressing (5):
 *       LF_Call, LF_Async_Call, LF_Async_Sequenced_Call,
 *       LF_Notify, LF_Sequenced_Notify
 *
 *   Remote invocation, UID addressing (5):
 *       LF_UID_Call, LF_UID_Async_Call, LF_UID_Async_Sequenced_Call,
 *       LF_UID_Notify, LF_UID_Sequenced_Notify
 *
 *   Remote invocation, P2PName addressing (5):
 *       LF_P2PNAME_Call, LF_P2PNAME_Async_Call, LF_P2PNAME_Async_Sequenced_Call,
 *       LF_P2PNAME_Notify, LF_P2PNAME_Sequenced_Notify
 *
 *   Queries (7):
 *       LF_CheckMainThread, LF_CheckApp, LF_CheckApi,
 *       LF_Check_UID, LF_Check_UID_Api,
 *       LF_Check_P2PNAME, LF_Check_P2PNAME_Api
 *
 *   Options (2):
 *       LF_SetOption, LF_GetOption
 *
 *   Status (3):
 *       LF_GetStatusCount, LF_GetStatus, LF_PostStatus
 *
 *   Network events (1):
 *       LF_Set_Network_Event
 *
 *   Shutdown (1):
 *       LF_Shutdown
 *
 * ============================================================================
 * HELPER FUNCTIONS (implemented by this C wrapper, NOT exported from the DLL)
 * ============================================================================
 * The helpers at the bottom of this file mirror the Pascal helper functions
 * in `lingofuse_import.pas` and are implemented on top of the exported
 * primitives (LF_WriteBuffer / LF_ReadBuffer / etc.).
 *
 * All integer helpers use little-endian byte order, matching the wire format.
 *
 * ============================================================================
 * STRING ENCODING - UTF-8 IS MANDATORY
 * ============================================================================
 * All string parameters (API names, descriptions, network addresses, option
 * names, option values) MUST be encoded in UTF-8 and MUST be null-terminated.
 *
 * The library internally decodes UTF-8 input into Unicode and encodes
 * outgoing strings back to UTF-8. This is platform-independent and works
 * identically on Windows, Linux, macOS, and BSD.
 *
 * Do NOT use the system ANSI codepage (e.g., CP_ACP on Windows).
 *
 * ============================================================================
 * UID TYPE - TP2P_UID
 * ============================================================================
 * The Pascal-side type `TP2P_UID___` is `array[0..31] of Byte`. In C there
 * are no function-returnable arrays, so the 32-byte value is wrapped in a
 * struct:
 *
 *     typedef struct TP2P_UID_s { uint8_t bytes[32]; } TP2P_UID;
 *
 * {!!!!!  TWO DIFFERENT ROLES, TWO DIFFERENT REPRESENTATIONS  !!!!!}
 * The same Pascal type plays two different roles on the C ABI, and each
 * role requires a DIFFERENT C-level representation:
 *
 *   ROLE 1 -- ARGUMENT (input position).
 *
 *       Functions such as LF_UID_Call, LF_Check_UID, LF_WriteUid, and
 *       LF_ReadUid take a 32-byte UID BY VALUE. The C type used for these
 *       parameters is `TP2P_UID` (the struct, not a pointer).
 *
 *       ABI NOTE (DELIBERATE, TESTED ASSUMPTION): On x86-64 (both System V
 *       AMD64 and Microsoft x64), a >16-byte aggregate is classified MEMORY
 *       by the psABI and is therefore passed on the stack (as an argument).
 *       FPC's `array[0..31] of Byte` falls into the same MEMORY class, so
 *       a struct with a single 32-byte array member is intended to be
 *       ABI-compatible. This assumption is DELIBERATE and TESTED: the C++
 *       test suite includes a UID round-trip test that would catch a
 *       divergence.
 *
 *   ROLE 2 -- RETURN VALUE (only LF_Get_P2P_UID).
 *
 *       `LF_Get_P2P_UID` does NOT return a 32-byte UID by value. It
 *       returns a POINTER to a 32-byte UID. The C type used for this
 *       return is `const TP2P_UID*`.
 *
 *       The pointer is allocated by the C side via Pascal `New`, populated
 *       with the sender's UID, and then scheduled for automatic release
 *       about 5 seconds after the call (Pascal `DelayFreeMem(5.0, ...)`).
 *
 *       Callers MUST:
 *           1. Copy the 32 bytes IMMEDIATELY into their own storage.
 *           2. NOT call any deallocation function on the pointer.
 *           3. NOT retain the pointer beyond the ~5-second window.
 *
 * {!!!!!  DO NOT UNIFY THESE TWO ROLES  !!!!!}
 * It is tempting to declare `typedef uint8_t TP2P_UID[32]` and use one
 * representation for both roles. That DECOUPLES the ABI from FPC's
 * by-value array convention and would produce a silent stack-corrupting
 * failure at the argument position. The two roles are different positions
 * in the ABI and must be represented differently.
 *
 * ============================================================================
 * SIDE-DATA SEMANTICS OF LF_Get_P2P_UID / LF_Get_P2P_Name
 * ============================================================================
 * {!!!!!  THESE FUNCTIONS DO NOT READ A PROPERTY OF THE HANDLE  !!!!!}
 *
 * `LF_Get_P2P_UID` and `LF_Get_P2P_Name` read the "SIDE DATA" that the
 * SENDER'S transport layer writes into every request payload BEFORE
 * transmission. The mechanism (Pascal side, for reference only):
 *
 *     TC40_LF_Client.Send_*
 *         -> TMemory_Param_Tool.Rebuild_UID_and_P2PName
 *         -> writes two fields into the payload header:
 *                FromUID       (32 bytes)
 *                FromP2PName   (UTF-8 string)
 *
 * The receiver therefore sees these two fields inside the Data_Param of
 * the INPUT handle it receives from the framework.
 *
 * CONSEQUENCE -- these functions work ONLY on INPUT handles:
 *
 *     VALID   -- the `input` (or `param`) argument of a registered Call
 *                or Notify callback, i.e. the handle that the framework
 *                delivered to the receiving side.
 *     VALID   -- the input handle of a local call / notify (the framework
 *                injects identity on the local path too).
 *     INVALID -- an OUTPUT handle (no Data_Param side data).
 *                The DLL logs a warning and returns a zero-filled UID /
 *                empty string.
 *     INVALID -- a handle the caller created itself via LF_CreateData or
 *                LF_CreateData_Permanent (no "sender" -> same zero result).
 *
 * The functions are populated on ALL command paths: Call, Notify,
 * Sequenced_Call, Sequenced_Notify, and the UID_* / P2PName_* variants.
 *
 * ============================================================================
 * STRING MECHANISM - THE #0 NULL TERMINATOR CONTRACT
 * ============================================================================
 * LingoFuse uses C-style null-terminated strings on the wire:
 *
 *   1. Every string written by LF_WriteString / LF_WriteStringBytes is
 *      followed by exactly ONE byte of value 0 (#0).
 *
 *   2. When reading, LF_ReadString / LF_ReadStringBytes scan forward until
 *      the first #0.
 *
 *   3. FAULT-TOLERANT MODE (critical for cross-language interop):
 *      If no #0 is found before the end of the buffer, the reader returns
 *      ALL remaining bytes and advances the cursor to (buffer size + 1),
 *      i.e. ONE BYTE PAST the end of the buffer. This is the exact
 *      behaviour of Pascal's LF_ReadString in `lingofuse_import.pas`
 *      (LF_SetPos(Hnd, e + 1) with e == size); the underlying library
 *      implicitly grows the buffer by one byte to accommodate the position.
 *
 *      This case is REQUIRED for interoperability with HTTP bridges
 *      (e.g., bridge.py) and any non-Pascal client that forwards raw JSON
 *      without appending a #0.
 *
 *   4. UTF-8 validation: This C wrapper does NOT validate UTF-8. The bytes
 *      copied into the caller's buffer are raw. If strict UTF-8 validation
 *      is required, the caller must perform it after reading.
 *
 * ============================================================================
 * THREAD SAFETY
 * ============================================================================
 * All exported functions are fully thread-safe and may be called
 * concurrently from any thread without external synchronization.
 *
 * However, for a given data handle (TDataHnd), write operations
 * (LF_WriteBuffer, LF_SetPos, LF_SetSize) must be serialised across
 * threads because they mutate the internal buffer state. Read-only
 * operations (LF_GetBuffer, LF_GetPos, LF_GetSize) are safe even while
 * another thread is writing, provided the handle is not being freed.
 *
 * Different TDataHnd instances are independent and may be used
 * concurrently without any restrictions.
 *
 * ============================================================================
 * CALLBACK EXECUTION CONTEXT (CRITICAL)
 * ============================================================================
 * All registered callbacks (LF_CallFunc, LF_NotifyFunc, LF_NetworkEventFunc,
 * LF_AsyncCallOnResult) are executed on background worker threads from the
 * library's internal thread pool. This means:
 *
 *   - DO NOT perform long-blocking operations inside a callback.
 *   - DO NOT call LF_Call() / LF_Notify() / LF_LocalCall() / LF_PrepareDone()
 *     / LF_Shutdown() from within a callback; this may deadlock.
 *   - DO NOT access UI components or thread-local storage without proper
 *     synchronization (e.g. a message queue).
 *
 * ASYNC RESULT HANDLE OWNERSHIP
 * -----------------------------
 * The `result` argument of LF_AsyncCallOnResult is OWNED BY THE FRAMEWORK.
 * It is released IMMEDIATELY after the callback returns. The callback MUST:
 *
 *   - read or copy everything it needs inside the callback body,
 *   - NOT call LF_FreeData on the handle,
 *   - NOT retain the pointer past the callback body.
 *
 * This is the OPPOSITE of the synchronous family (LF_Call / LF_UID_Call /
 * LF_P2PNAME_Call), whose returned handle is owned by the CALLER and MUST
 * be released with LF_FreeData. Mixing the two ownership rules is a
 * use-after-free and a double-free in one shot.
 *
 * ============================================================================
 * DATA HANDLE LIFETIME
 * ============================================================================
 * Every TDataHnd created with LF_CreateData() or LF_CreateData_Permanent()
 * MUST be freed with LF_FreeData() when no longer needed.
 *
 * The library has an automatic idle-timeout reclaimer on the simulated
 * main thread. It scans the handle pool every 5 seconds and frees any
 * handle that has been idle (no accessor call) for more than 10 minutes.
 * This is a safety net only; relying on it can leak resources under heavy
 * load. It does NOT apply to handles created with LF_CreateData_Permanent().
 *
 * LF_Call() ALWAYS returns a valid TDataHnd (never a NULL pointer). If the
 * call times out or fails, the handle size will be 0. You must still free
 * it with LF_FreeData().
 *
 * LF_LocalCall() also ALWAYS returns a valid TDataHnd.
 *
 * {!!!!!  ASYNC RESULT HANDLE  !!!!!}
 * LF_Async_Call() and its UID / P2PName variants do NOT return a handle.
 * They hand it to your LF_AsyncCallOnResult callback. That handle is owned
 * by the framework and MUST NOT be freed by the callback. See the
 * "ASYNC RESULT HANDLE OWNERSHIP" section above.
 *
 * ============================================================================
 * LIBRARY LOADING
 * ============================================================================
 * On Windows, use `LF_LoadLibrary()` to explicitly load `LingoFuse64.dll`
 * (or `LingoFuse32.dll`). On Linux/macOS the loader resolves
 * `liblingofuse.so` / `liblingofuse.dylib`.
 *
 * The loader first tries the executable's own directory, then falls back
 * to the system search path. Call `LF_FreeLibrary()` when done.
 *
 * Call `LF_LoadLibrary()` BEFORE any other LF_* function. Calling any other
 * LF_* function first is undefined behaviour (null-pointer dereference).
 *
 * ============================================================================
 * USAGE EXAMPLE
 * ============================================================================
 * @code
 * #include "LingoFuse.h"
 * #include <stdio.h>
 *
 * static void LF_CDECL AddCallback(void* trigger, void* input, void* output) {
 *     int a = 0, b = 0, sum = 0;
 *     LF_ReadInt32((TDataHnd)input, &a);
 *     LF_ReadInt32((TDataHnd)input, &b);
 *     sum = a + b;
 *     LF_WriteInt32((TDataHnd)output, sum);
 * }
 *
 * int main(void) {
 *     if (!LF_LoadLibrary()) return 1;
 *
 *     TAppHnd app = LF_CreateApp("Calculator", "Simple calculator");
 *     LF_RegisterCall(app, "add", "Add two integers", NULL, AddCallback);
 *
 *     LF_ResetPrepare();
 *     LF_PrepareService("0.0.0.0", "127.0.0.1:9898");
 *     LF_PrepareClient("127.0.0.1:9898", app);
 *     if (LF_PrepareDone() != 1) { LF_FreeLibrary(); return 1; }
 *
 *     TDataHnd data = LF_CreateData("add");
 *     LF_WriteInt32(data, 5);
 *     LF_WriteInt32(data, 7);
 *     TDataHnd result = LF_Call("Calculator", data, 5000);
 *     int sum = 0;
 *     if (result && LF_GetSize(result) >= 4) LF_ReadInt32(result, &sum);
 *     printf("5 + 7 = %d\n", sum);
 *
 *     LF_FreeData(data);
 *     LF_FreeData(result);
 *     LF_FreeApp(app);
 *     LF_Shutdown();
 *     LF_FreeLibrary();
 *     return 0;
 * }
 * @endcode
 */

#ifndef LINGOFUSE_H_INCLUDED
#define LINGOFUSE_H_INCLUDED

#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

    /* ----------------------------------------------------------------------------
     * Calling convention
     * ----------------------------------------------------------------------------
     * The library uses the C calling convention (cdecl) on all platforms.
     *
     *   - MSVC / clang-cl: __cdecl
     *   - MinGW / Cygwin GCC: __cdecl (GCC's Windows target supports it)
     *   - GCC / Clang on non-Windows platforms: the default calling convention,
     *     so the macro expands to nothing.
     * ------------------------------------------------------------------------- */
#if defined(_WIN32)
#  if defined(__GNUC__) || defined(__clang__)
#    define LF_CDECL __attribute__((cdecl))
#  else
#    define LF_CDECL __cdecl
#  endif
#else
#  define LF_CDECL
#endif

     /* ----------------------------------------------------------------------------
      * Opaque handle types
      * ------------------------------------------------------------------------- */
    typedef void* TDataHnd;   /**< Data handle (binary buffer with an API name). */
    typedef void* TAppHnd;    /**< Application handle (groups a set of APIs).    */

    /* ----------------------------------------------------------------------------
     * UID type
     * ----------------------------------------------------------------------------
     * The Pascal-side type is `array[0..31] of Byte`. In C there are no
     * function-returnable arrays, so the 32-byte value is wrapped in a
     * struct. See the file-level docstring section "UID TYPE" for the
     * ABI compatibility note and for the distinction between the two
     * roles the same Pascal type plays on the C ABI.
     *
     * Field layout:
     *     bytes[0] .. bytes[31]    the 32 UID octets, in network order
     *
     * A zero-filled TP2P_UID is the "null UID" (see LF_Get_P2P_UID).
     * ------------------------------------------------------------------------- */
    typedef struct TP2P_UID_s {
        uint8_t bytes[32];
    } TP2P_UID;

    /* ----------------------------------------------------------------------------
     * Callback types (all cdecl, all executed on background worker threads)
     * ------------------------------------------------------------------------- */
     /**
      * @brief Prototype for a Call-mode (request-response) callback.
      *
      * @param trigger  User-supplied pointer passed at registration time.
      * @param input    Read-only data handle containing the request payload.
      * @param output   Writable data handle to be filled with the response.
      */
    typedef void (LF_CDECL* LF_CallFunc)(void* trigger, void* input, void* output);

    /**
     * @brief Prototype for a Notify-mode (one-way) callback.
     *
     * @param trigger  User-supplied pointer passed at registration time.
     * @param input    Read-only data handle containing the notification payload.
     */
    typedef void (LF_CDECL* LF_NotifyFunc)(void* trigger, void* input);

    /**
     * @brief Prototype for a network connect/disconnect callback.
     *
     * @param addr  UTF-8 endpoint string. Valid ONLY during the callback
     *              invocation; copy the string if you need to retain it.
     *
     * IMPORTANT: Runs on a background worker thread. Do NOT touch UI directly.
     */
    typedef void (LF_CDECL* LF_NetworkEventFunc)(const char* addr);

    /**
     * @brief Prototype for the asynchronous Call result callback.
     *
     * Used by LF_Async_Call, LF_Async_Sequenced_Call, LF_UID_Async_Call,
     * LF_UID_Async_Sequenced_Call, LF_P2PNAME_Async_Call, and
     * LF_P2PNAME_Async_Sequenced_Call.
     *
     * @param data    The opaque pointer the caller supplied at the call site.
     *                The library neither owns nor frees it.
     * @param result  A TDataHnd OWNED BY THE FRAMEWORK. It is released
     *                IMMEDIATELY after this callback returns.
     *
     *                The callback MUST:
     *                  - read or copy everything it needs inside the body,
     *                  - NOT call LF_FreeData on @p result,
     *                  - NOT retain the pointer past the callback body.
     *
     *                On timeout, the callback is not invoked and the
     *                framework releases the pending op internally.
     *
     * Threading contract:
     *   The callback runs on a TCompute worker thread (NOT the calling
     *   thread, NOT the simulated main thread). It MUST return promptly.
     *
     * {!!!!!  C++ MODERN WRAPPER  !!!!!}
     * The C ABI is deliberately minimal: a bare function pointer plus a
     * caller-supplied opaque data pointer. A C++ wrapper can layer
     * std::function, lambdas, or a Future/Promise on top of this by
     * allocating a small holder object and passing its address as @p data,
     * with a static trampoline as the function pointer. Do NOT attempt to
     * widen the C ABI itself; the existing shape is ABI-stable across
     * all supported platforms.
     */
    typedef void (LF_CDECL* LF_AsyncCallOnResult)(void* data, void* result);

    /* ============================================================================
     * Library loader API (implemented by this C wrapper, not exported from DLL)
     * ============================================================================ */

     /**
      * @brief Loads the LingoFuse dynamic library and resolves all exported symbols.
      *
      * Resolution order:
      *   1. The directory containing the current executable.
      *   2. The system search path.
      *
      * @return 1 on success, 0 on failure.
      * @note Must be called before any other LF_* function.
      */
    int  LF_LoadLibrary(void);

    /**
     * @brief Unloads the dynamic library and clears all cached function pointers.
     *
     * Safe to call multiple times.
     */
    void LF_FreeLibrary(void);

    /* ============================================================================
     * DATA HANDLE - creation, destruction, raw buffer access
     * ============================================================================ */

     /**
      * @brief Creates a new auto-recycled data handle bound to the given API name.
      *
      * The initial payload is empty. The handle must be freed with LF_FreeData().
      *
      * Auto-recycle behaviour:
      *   - The handle is added to the library's idle pool.
      *   - The pool scans every 5 seconds and frees any handle that has been
      *     idle for more than 10 minutes.
      *   - Any accessor call (LF_GetSize, LF_GetPos, LF_ReadBuffer,
      *     LF_WriteBuffer, ...) refreshes the idle timestamp.
      *   - LF_FreeData() marks the handle for release; the actual release
      *     happens on the next pool scan (at most 5 seconds later).
      *
      * @param method_name  UTF-8, null-terminated API name.
      * @return A new TDataHnd (never NULL on success).
      */
    TDataHnd LF_CreateData(const char* method_name);

    /**
     * @brief Creates a new PERMANENT data handle bound to the given API name.
     *
     * Difference from LF_CreateData:
     *   - The handle is NOT added to the library's idle pool.
     *   - The automatic idle-timeout reclaimer will NEVER free it, no matter
     *     how long it has been idle.
     *   - LF_FreeData() releases it IMMEDIATELY (synchronously), rather than
     *     merely marking it as deleted for a later pool scan.
     *
     * When to use:
     *   - Handles that must survive for the entire lifetime of the process,
     *     or for an unbounded period (cached request templates, long-lived
     *     scratch buffers, global registries, etc.).
     *
     * When NOT to use:
     *   - Short-lived or one-shot handles. For those, use LF_CreateData so
     *     the pool can reclaim any handle you forget to free.
     *
     * [PITFALL - NO-OP WINDOW]
     *   LF_FreeData is a no-op while the simulated main thread is not active
     *   (i.e. before LF_PrepareDone or after LF_ExitMainThread). Permanent
     *   handles created in that window stay allocated until the process
     *   terminates.
     *
     * @param method_name  UTF-8, null-terminated API name.
     * @return A new TDataHnd (never NULL on success). Must be freed with
     *         LF_FreeData().
     */
    TDataHnd LF_CreateData_Permanent(const char* method_name);

    /**
     * @brief Destroys a data handle and releases its memory.
     *
     * @param hnd  Handle to free. NULL is accepted and ignored.
     *
     * [PITFALL] If the simulated main thread is not active (before
     *   LF_PrepareDone or after LF_ExitMainThread), this call is a NO-OP.
     *
     * [PITFALL] For auto-recycled handles, this only sets the "deleted"
     *   flag; the actual release happens on the next pool scan (at most 5
     *   seconds later). For permanent handles, the release is synchronous.
     *
     * [PITFALL] Do NOT call this on the @p result argument of an
     *   LF_AsyncCallOnResult callback. That handle is owned by the framework
     *   and is released automatically.
     */
    void LF_FreeData(TDataHnd hnd);

    /**
     * @brief Returns a pointer to the internal buffer.
     *
     * The pointer is valid until the handle is freed or resized. Do NOT free it.
     *
     * @param hnd  Data handle.
     * @return Pointer to internal memory, or NULL if the handle is empty.
     */
    void* LF_GetBuffer(TDataHnd hnd);

    /**
     * @brief Writes @p size bytes at the current position; advances the position.
     *
     * @param hnd   Data handle.
     * @param buff  Source buffer.
     * @param size  Number of bytes to write.
     * @return Number of bytes actually written (normally equals @p size).
     */
    int64_t LF_WriteBuffer(TDataHnd hnd, const void* buff, int64_t size);

    /**
     * @brief Reads up to @p size bytes from the current position into @p buff.
     *
     * @param hnd   Data handle.
     * @param buff  Destination buffer.
     * @param size  Maximum number of bytes to read.
     * @return Number of bytes actually read.
     */
    int64_t LF_ReadBuffer(TDataHnd hnd, void* buff, int64_t size);

    /**
     * @brief Returns the current read/write position.
     */
    int64_t LF_GetPos(TDataHnd hnd);

    /**
     * @brief Sets the current read/write position.
     *
     * If @p pos exceeds the current size, the buffer is implicitly expanded.
     */
    void LF_SetPos(TDataHnd hnd, int64_t pos);

    /**
     * @brief Returns the total buffer size in bytes.
     */
    int64_t LF_GetSize(TDataHnd hnd);

    /**
     * @brief Adjusts the buffer size. Newly added space is uninitialized.
     */
    void LF_SetSize(TDataHnd hnd, int64_t size);

    /* ----------------------------------------------------------------------------
     * LF_Get_P2P_UID - read the auto-injected sender UID from an INPUT handle
     * ----------------------------------------------------------------------------
     *
     * {!!!!!  SIDE DATA, NOT A HANDLE PROPERTY  !!!!!}
     *
     * This function does NOT read a property of the handle itself. It reads
     * the "side data" that the SENDER'S transport layer writes into every
     * request payload before transmission. Pascal side:
     *
     *     TC40_LF_Client.Send_*
     *         -> TMemory_Param_Tool.Rebuild_UID_and_P2PName
     *         -> writes two identity fields into the payload header:
     *                FromUID       (32 bytes)
     *                FromP2PName   (UTF-8 string)
     *
     * The receiver therefore sees these two fields inside the Data_Param of
     * the INPUT handle it receives from the framework.
     *
     * {!!!!!  ONLY WORKS ON INPUT HANDLES  !!!!!}
     *
     *     VALID    -- the `input` (or `param`) argument of a registered
     *                 Call or Notify callback.
     *     VALID    -- the input handle of a local call / notify (the
     *                 framework injects identity on the local path too).
     *     INVALID  -- an OUTPUT handle (no Data_Param side data). The DLL
     *                 logs a warning and returns a pointer to a zero-filled
     *                 UID.
     *     INVALID  -- a handle the caller created itself via LF_CreateData
     *                 or LF_CreateData_Permanent. Such a handle has no
     *                 "sender", so the same zero result applies.
     *
     * {!!!!!  RETURNS A POINTER, NOT A VALUE  !!!!!}
     *
     * Pascal signature (authoritative):
     *
     *     function LF_Get_P2P_UID(Hnd: TDataHnd___): PP2P_UID___;
     *
     * i.e. ^TUID___, NOT TUID___. The pointer is allocated by the C side
     * via Pascal `New` and is scheduled for automatic release about 5
     * seconds after the call (Pascal `DelayFreeMem(5.0, ...)`).
     *
     * Callers MUST:
     *   1. Copy the 32 bytes IMMEDIATELY into their own storage if they
     *      want to retain them.
     *   2. NOT call any deallocation function on the pointer.
     *   3. NOT retain the pointer beyond the ~5-second window.
     *
     * The UID is regenerated on every TunnelLink. Caching a UID across a
     * link loss is unsafe; callers that cache must re-probe after a
     * reconnect.
     *
     * @param hnd  Data handle (must be an INPUT handle).
     * @return A pointer to a 32-byte UID, or NULL if the library has not
     *         been loaded. If @p hnd is not an input handle, the pointer
     *         is still non-NULL and points to a zero-filled UID (the DLL
     *         also emits a diagnostic on the C side).
     *         Do NOT free the returned pointer.
     */
    const TP2P_UID* LF_Get_P2P_UID(TDataHnd hnd);

    /* ----------------------------------------------------------------------------
     * LF_Get_P2P_Name - read the auto-injected sender P2P name from an INPUT handle
     * ----------------------------------------------------------------------------
     *
     * {!!!!!  SIDE DATA, NOT A HANDLE PROPERTY  !!!!!}
     *
     * Same identity-injection mechanism as LF_Get_P2P_UID. This function
     * reads the FromP2PName field that the sender's transport layer wrote
     * into the payload header; it does NOT read a property of the handle
     * itself.
     *
     * {!!!!!  ONLY WORKS ON INPUT HANDLES  !!!!!}
     *
     *     VALID    -- the `input` (or `param`) argument of a registered
     *                 Call or Notify callback.
     *     VALID    -- the input handle of a local call / notify.
     *     INVALID  -- an OUTPUT handle. The DLL logs a warning and returns
     *                 an empty string.
     *     INVALID  -- a handle the caller created itself via LF_CreateData
     *                 or LF_CreateData_Permanent (no "sender", so empty).
     *
     * {!!!!!  TRANSIENT BUFFER - COPY IMMEDIATELY  !!!!!}
     *
     * The returned pointer is a transient buffer released ~5 seconds
     * after this call (Pascal `DelayFreeMem(5.0, ...)`). COPY THE STRING
     * IMMEDIATELY if you need to retain it, and DO NOT free the pointer.
     *
     * @param hnd  Data handle (must be an INPUT handle).
     * @return A UTF-8, null-terminated string, or an empty string "" on
     *         failure. Do NOT free the returned pointer.
     */
    const char* LF_Get_P2P_Name(TDataHnd hnd);

    /* ============================================================================
     * APPLICATION HANDLE - creation, name generation, client binding
     * ============================================================================ */

     /**
      * @brief Creates a new application with the given name and description.
      *
      * @param app_name  UTF-8, null-terminated application name (unique on the
      *                  wire; matching is case-insensitive).
      * @param desc      UTF-8, null-terminated description. A NULL value is
      *                  treated as an empty string by this wrapper.
      * @return A new TAppHnd (never NULL on success).
      */
    TAppHnd LF_CreateApp(const char* app_name, const char* desc);

    /**
     * @brief Detaches the application from all clients and stops its sequenced
     *        notification threads.
     *
     * The underlying application object is NOT destroyed immediately; it remains
     * in the global pool until LF_Shutdown() is called. After LF_FreeApp() the
     * handle must be considered invalid.
     *
     * @param app_hnd  Application handle.
     */
    void LF_FreeApp(TAppHnd app_hnd);

    /**
     * @brief Generates a globally unique application name.
     *
     * The name is built from active C4 tunnel addresses, process name (with PID),
     * and a high-resolution timestamp.
     *
     * IMPORTANT (Pascal LF-APP-003):
     *   Must be called AFTER LF_PrepareDone() has returned 1. Otherwise the
     *   generated name lacks the tunnel information and may not be unique.
     *
     * IMPORTANT (Pascal LF-APP-004):
     *   The returned pointer is valid for ONLY 5 SECONDS. Copy the string
     *   immediately before the pointer becomes invalid.
     *
     * @return Pointer to a null-terminated UTF-8 string (do not free).
     *         Returns an empty string "" on failure.
     */
    const char* LF_Generate_AppName(void);

    /**
     * @brief Retrieves the application name associated with the given handle.
     *
     * Same 5-second validity rule as LF_Generate_AppName (Pascal LF-APP-004).
     * Copy the string immediately.
     *
     * @param app_hnd  Application handle.
     * @return Pointer to a null-terminated UTF-8 string (do not free).
     *         Returns an empty string "" on failure.
     */
    const char* LF_Get_AppName(TAppHnd app_hnd);

    /**
     * @brief Binds the application to all currently unbound LingoFuse clients.
     *
     * Must be called AFTER LF_PrepareDone() has returned 1 and while the
     * simulated main thread is active. A client is eligible for binding only if
     * it has no app attached yet. Each client can host at most one application.
     *
     * @param app_hnd  Application handle.
     * @return Number of clients successfully bound. 0 means either the main
     *         thread is not active or all clients are already occupied.
     */
    int LF_BindApp(TAppHnd app_hnd);

    /* ============================================================================
     * API REGISTRATION - app-bound namespace
     * ============================================================================ */

     /**
      * @brief Registers a Call API (request-response).
      *
      * @param app_hnd      Application handle.
      * @param method_name  UTF-8, null-terminated API name (case-insensitive).
      * @param desc         UTF-8, null-terminated description. A NULL value is
      *                     treated as an empty string by this wrapper.
      * @param trigger      User-supplied pointer passed back to the callback.
      * @param on_call      Callback function (must use LF_CDECL).
      * @return 1 on success, 0 on failure (e.g., duplicate API name).
      */
    int LF_RegisterCall(TAppHnd app_hnd,
        const char* method_name,
        const char* desc,
        void* trigger,
        LF_CallFunc on_call);

    /**
     * @brief Registers a Notify API (one-way).
     *
     * @param app_hnd      Application handle.
     * @param method_name  UTF-8, null-terminated API name (case-insensitive).
     * @param desc         UTF-8, null-terminated description. A NULL value is
     *                     treated as an empty string by this wrapper.
     * @param trigger      User-supplied pointer passed back to the callback.
     * @param on_notify    Callback function (must use LF_CDECL).
     * @return 1 on success, 0 on failure (e.g., duplicate API name).
     */
    int LF_RegisterNotify(TAppHnd app_hnd,
        const char* method_name,
        const char* desc,
        void* trigger,
        LF_NotifyFunc on_notify);

    /**
     * @brief Unregisters a previously registered API by name.
     *
     * The removal takes effect locally immediately. A network broadcast is
     * triggered; remote peers will stop seeing the API within approximately
     * 3 seconds (Pascal LF-CHK-001).
     *
     * @return 1 if the API was found and removed, 0 otherwise.
     */
    int LF_Unregister(TAppHnd app_hnd, const char* method_name);

    /* ============================================================================
     * API REGISTRATION - process-wide P2P namespace
     * ============================================================================
     *
     * The process-wide P2P namespace is INDEPENDENT of any App:
     *   - APIs registered here are reachable via UID addressing and P2PName
     *     addressing ONLY.
     *   - They are NOT reachable via App-name addressing, even if the API
     *     name happens to match an App name.
     *   - They live on the process-wide LF_P2P_APP and survive until
     *     LF_Shutdown().
     *
     * Typical use: globally-discoverable utility APIs (health probes,
     * capability discovery, identity echo, etc.) that any client in the mesh
     * can call by UID or by P2PName without knowing the target's App name.
     * ============================================================================ */

     /**
      * @brief Registers a process-wide Call API (request-response).
      *
      * @return 1 on success, 0 on failure (e.g., duplicate name in the P2P
      *         namespace).
      */
    int LF_Register_P2P_Call(const char* method_name,
        const char* desc,
        void* trigger,
        LF_CallFunc on_call);

    /**
     * @brief Registers a process-wide Notify API (one-way).
     *
     * @return 1 on success, 0 on failure (e.g., duplicate name in the P2P
     *         namespace).
     */
    int LF_Register_P2P_Notify(const char* method_name,
        const char* desc,
        void* trigger,
        LF_NotifyFunc on_notify);

    /**
     * @brief Removes a process-wide P2P API by name.
     *
     * Does NOT affect app-bound APIs of the same name.
     *
     * @return 1 if the API was found and removed, 0 otherwise.
     */
    int LF_Unregister_P2P(const char* method_name);

    /* ============================================================================
     * LOCAL EXECUTION - bypass the network and invoke the callback directly
     * ============================================================================ */

     /**
      * @brief Executes a Call API locally within the same process.
      *
      * @param app_hnd  Application handle.
      * @param param    Input data handle (not freed by this function).
      * @return A new result data handle (must be freed by the caller).
      *         Never NULL on success; if the underlying call fails, an empty
      *         handle (size 0) is returned.
      */
    TDataHnd LF_LocalCall(TAppHnd app_hnd, TDataHnd param);

    /**
     * @brief Executes a Notify API locally within the same process.
     *
     * @param app_hnd  Application handle.
     * @param param    Input data handle (not freed by this function).
     */
    void LF_LocalNotify(TAppHnd app_hnd, TDataHnd param);

    /* ============================================================================
     * NETWORK PREPARATION
     * ============================================================================ */

     /**
      * @brief Clears any previously prepared services and clients.
      *
      * Call this before preparing a new set to avoid conflicts. Does not affect
      * already running services/clients; it only clears the preparation queue.
      */
    void LF_ResetPrepare(void);

    /**
     * @brief Prepares a C4 service listening on @p listening_addr and advertised
     *        as @p physics_addr.
      *
      * If the simulated main thread is already running (after LF_PrepareDone),
      * the service is created and started immediately; otherwise it is queued.
      *
      * @return A tag ID, or -1 if the address is a duplicate/invalid.
      */
    int LF_PrepareService(const char* listening_addr, const char* physics_addr);

    /**
     * @brief Prepares a client connecting to @p physics_addr and optionally
     *        attaching @p app_hnd.
     *
     * IMPORTANT (Pascal LF-NET-001):
     *   The same physical address can be used for only ONE client. A second
     *   call with the same address returns -1 and logs a "repeat connection"
     *   error, UNLESS the `Overlap_Connection` option is set to True via
     *   LF_SetOption() BEFORE the call.
     *
     * @return A tag ID, or -1 if the address is a duplicate.
     */
    int LF_PrepareClient(const char* physics_addr, TAppHnd app_hnd);

    /**
     * @brief Starts the LingoFuse framework with all prepared services and clients.
     *
     * Blocks until the framework is initialised (or until the configured timeout
     * expires, depending on `Wait_Connection_ReadyOk`).
     *
     * IMPORTANT (Pascal LF-NET-003):
     *   Returns 1 ONLY ONCE per process (without an intervening LF_Shutdown()).
     *   A second call returns 0, even though the framework is already running.
     *   Do not interpret 0 on the second call as a failure.
     *
     * @return 1 on success, 0 on failure or repeated call.
     */
    int LF_PrepareDone(void);

    /**
     * @brief Signals the simulated main thread to exit gracefully.
     *
     * [PITFALL] LF_ExitMainThread also flushes the data handle pool, releasing
     *   every outstanding handle - including those created with
     *   LF_CreateData_Permanent. Do not use any data handle after this call.
     */
    void LF_ExitMainThread(void);

    /* ============================================================================
     * REMOTE INVOCATION - app-name addressing
     * ============================================================================
     *
     * Routing is LOCAL-FIRST: if the caller process itself hosts an App with
     * the matching name and API, the call is serviced locally without touching
     * the network.
     * ============================================================================ */

     /**
      * @brief Calls a remote API and waits for a response.
      *
      * On timeout or failure, an EMPTY data handle (size 0) is returned, NOT a
      * NULL pointer. Always check LF_GetSize(result) > 0 to detect failures.
      *
      * @param app_name    Target application name (UTF-8).
      * @param param       Input data handle (not freed by this function).
      * @param timeout_ms  Timeout in milliseconds. 0 means infinite wait.
      * @return A new result data handle (must be freed by the caller).
      */
    TDataHnd LF_Call(const char* app_name, TDataHnd param, uint64_t timeout_ms);

    /**
     * @brief Asynchronous variant of LF_Call.
     *
     * Returns 1 immediately after the request is queued. The OnResult callback
     * fires later on a TCompute worker thread once the response arrives, or
     * never if the request could not be queued.
     *
     * @param app_name    Target application name (UTF-8).
     * @param param       Input data handle (not freed by this function).
     * @param data        Opaque pointer forwarded verbatim to @p on_result.
     *                    The library neither owns nor frees it.
     * @param on_result   Callback invoked with the result handle. See
     *                    LF_AsyncCallOnResult for the ownership contract.
     * @return 1 if the request was queued, 0 otherwise.
     */
    int LF_Async_Call(const char* app_name,
        TDataHnd param,
        void* data,
        LF_AsyncCallOnResult on_result);

    /**
     * @brief Asynchronous variant with FIFO ordering per (app, api) pair.
     *
     * Same ownership and threading contract as LF_Async_Call.
     */
    int LF_Async_Sequenced_Call(const char* app_name,
        TDataHnd param,
        void* data,
        LF_AsyncCallOnResult on_result);

    /**
     * @brief Sends a one-way notification to a remote application.
     *
     * Order of delivery is NOT guaranteed. Use LF_Sequenced_Notify() if
     * FIFO ordering per (app, api) pair is required.
     */
    void LF_Notify(const char* app_name, TDataHnd param);

    /**
     * @brief Sends a one-way notification with FIFO ordering per (app, api) pair.
     */
    void LF_Sequenced_Notify(const char* app_name, TDataHnd param);

    /* ============================================================================
     * REMOTE INVOCATION - UID addressing
     * ============================================================================
     *
     * UID addressing routes to the exact client whose TunnelLink produced the
     * given 32-byte UID. The UID is regenerated on every reconnect: a caller
     * that caches a UID MUST re-probe it after a link loss.
     *
     * UID routing is LOCAL-FIRST, matching app-name routing.
     *
     * A UID can address ANY API registered on the target -- whether app-bound
     * (LF_RegisterCall) or process-wide (LF_Register_P2P_Call) -- without
     * requiring the caller to know the target App name.
     *
     * {!!!!!  ARGUMENT-ROLE TP2P_UID  !!!!!}
     * The first parameter of each function below is the ARGUMENT-role
     * `TP2P_UID` (the struct, not a pointer). It is passed by value in a
     * cdecl call, matching the Pascal-side `array[0..31] of Byte`. This is
     * a DIFFERENT role from the LF_Get_P2P_UID RETURN value (which is a
     * pointer). Do NOT conflate the two.
     * ============================================================================ */

     /**
      * @brief Calls a remote API by UID. Same ownership rule as LF_Call.
      */
    TDataHnd LF_UID_Call(TP2P_UID uid, TDataHnd param, uint64_t timeout_ms);

    /**
     * @brief Asynchronous variant of LF_UID_Call.
     *        Same ownership contract as LF_Async_Call.
     */
    int LF_UID_Async_Call(TP2P_UID uid,
        TDataHnd param,
        void* data,
        LF_AsyncCallOnResult on_result);

    /**
     * @brief Asynchronous sequenced variant of LF_UID_Call.
     */
    int LF_UID_Async_Sequenced_Call(TP2P_UID uid,
        TDataHnd param,
        void* data,
        LF_AsyncCallOnResult on_result);

    /**
     * @brief Sends a one-way notification by UID.
     */
    void LF_UID_Notify(TP2P_UID uid, TDataHnd param);

    /**
     * @brief Sends a one-way sequenced notification by UID.
     */
    void LF_UID_Sequenced_Notify(TP2P_UID uid, TDataHnd param);

    /* ============================================================================
     * REMOTE INVOCATION - P2PName addressing
     * ============================================================================
     *
     * P2PName addressing routes to any client in a user-defined group. The
     * server-side dispatcher picks a target using one of two strategies:
     *
     *   - Load balancing (Cycle_Anchor): the target with the smallest anchor
     *     value is chosen, and its anchor is then advanced.
     *
     *   - Sticky affinity (FixedSequenced, governed by the runtime option
     *     "Fixed_Sequenced_Time", default 20 seconds).
     *
     * IMPORTANT: P2PName routing is NOT local-first. Even when the caller
     * process itself hosts a client in the target group, the call is
     * forwarded to the server for dispatch.
     * ============================================================================ */

     /**
      * @brief Calls a remote API by P2P group name. Same ownership rule as
      *        LF_Call.
      */
    TDataHnd LF_P2PNAME_Call(const char* p2p_name,
        TDataHnd param,
        uint64_t timeout_ms);

    /**
     * @brief Asynchronous variant of LF_P2PNAME_Call.
     */
    int LF_P2PNAME_Async_Call(const char* p2p_name,
        TDataHnd param,
        void* data,
        LF_AsyncCallOnResult on_result);

    /**
     * @brief Asynchronous sequenced variant of LF_P2PNAME_Call.
     */
    int LF_P2PNAME_Async_Sequenced_Call(const char* p2p_name,
        TDataHnd param,
        void* data,
        LF_AsyncCallOnResult on_result);

    /**
     * @brief Sends a one-way notification by P2P group name.
     */
    void LF_P2PNAME_Notify(const char* p2p_name, TDataHnd param);

    /**
     * @brief Sends a one-way sequenced notification by P2P group name.
     */
    void LF_P2PNAME_Sequenced_Notify(const char* p2p_name, TDataHnd param);

    /* ============================================================================
     * QUERIES
     * ============================================================================
     *
     * All queries consult a LOCALLY CACHED view of the mesh, updated by
     * periodic broadcasts with a typical propagation delay of about 3 seconds.
     * A query can return false negatives shortly after a registration and
     * false positives shortly after an unregistration. Use them as probing
     * tools, not as authoritative existence tests. For critical decisions,
     * call the target API directly and handle timeouts gracefully.
     * ============================================================================ */

     /**
      * @brief True if the simulated main thread is currently running.
      */
    int LF_CheckMainThread(void);

    /**
     * @brief True if an application with the given name is available.
     */
    int LF_CheckApp(const char* app_name);

    /**
     * @brief True if the given API is available for the given application.
     */
    int LF_CheckApi(const char* app_name, const char* api_name);

    /**
     * @brief True if a client with the given UID is currently registered.
     *
     * The UID is passed as the ARGUMENT-role `TP2P_UID` (the struct, not a
     * pointer). See the "UID TYPE" section in the file-level docstring.
     */
    int LF_Check_UID(TP2P_UID uid);

    /**
     * @brief True if a client with the given UID exposes the named API.
     *
     * The UID is passed as the ARGUMENT-role `TP2P_UID` (the struct).
     */
    int LF_Check_UID_Api(TP2P_UID uid, const char* api_name);

    /**
     * @brief True if a client with the given P2P group name is registered.
     */
    int LF_Check_P2PNAME(const char* p2p_name);

    /**
     * @brief True if a client in the given P2P group exposes the named API.
     */
    int LF_Check_P2PNAME_Api(const char* p2p_name, const char* api_name);

    /* ============================================================================
     * OPTIONS - runtime configuration
     * ============================================================================ */

     /**
      * @brief Adjusts a global runtime option.
      *
      * Supported option keys (case-insensitive, aliases accepted):
      *
      *   === Authentication ===
      *   "password" / "passwd"        C4 P2PVM authentication token.
      *
      *   === Logging & Debugging ===
      *   "Quiet"                      Suppress most internal logging.
      *   "ShowThreadID"               Show thread IDs in log output.
      *   "ConsoleOutput"              Enable/disable console logging.
      *   "debug"                      Execute a C4 console debug command.
      *
      *   === Connection Readiness ===
      *   "Overlap_Connection"         Allow multiple client tunnels to the
      *                                same physical address.
      *   "Wait_Connection_ReadyOk"    Whether LF_PrepareDone blocks until
      *                                all prepared clients are online.
      *   "Wait_Connection_Timeout"    Timeout for the above wait, ms.
      *
      *   === IPC ===
      *   "IPC_Serv_ThreadCount"       IPC server thread count.
      *   "IPC_Serv_MaxQueueLength"    IPC inbound queue length.
      *   "IPC_Serv_MaxMsgSize"        Max IPC message size.
      *
      *   === Sequenced Notifications ===
      *   "Fixed_Sequenced_Time"       Sticky-affinity window, ms.
      *
      *   === Data Handle Pool ===
      *   "DataHandle_Idle_Timeout"    Idle-reclaim threshold, ms.
      *   "DataHandle_Pool_Scan_Interval"
      *                                Reclaim scan rate-limit, ms.
      *
      *   === P2P ===
      *   "LF_P2P_name"                This process's P2P group name.
      *
      *   === Command Flushing ===
      *   "No_Reponse_Cmd_NULL_Flush_Threshold"
      *                                Null-flush threshold for one-way
      *                                Notify messages.
      *
      * Unknown options are silently ignored. Changes are not persisted across
      * restarts.
      *
      * @param option  UTF-8, null-terminated option name.
      * @param value   UTF-8, null-terminated value.
      */
    void LF_SetOption(const char* option, const char* value);

    /**
     * @brief Reads a runtime option.
     *
     * The returned pointer is a transient buffer released ~5 seconds after
     * the call. COPY THE STRING IMMEDIATELY if you need to retain it.
     *
     * @param option  UTF-8, null-terminated option name.
     * @return A UTF-8, null-terminated value, or an empty string "" for an
     *         unknown option. Do NOT free the returned pointer.
     */
    const char* LF_GetOption(const char* option);

    /* ============================================================================
     * STATUS AND DIAGNOSTICS
     * ============================================================================ */

     /**
      * @brief Returns the number of pending log messages in the status queue.
      *
      * The queue holds up to 1000 messages; older messages are discarded when
      * the limit is reached.
      *
      * IMPORTANT: Relies on the simulated main thread to process the queue.
      * Use it only after the framework is fully initialised.
      */
    int LF_GetStatusCount(void);

    /**
     * @brief Retrieves the next log message from the status queue (FIFO).
     *
     * Returns a pointer to an internal static buffer (UTF-8, null-terminated).
     * The pointer is valid only until the next call to this function; COPY
     * THE STRING IMMEDIATELY if you need to retain it.
     *
     * @return Pointer to the message, or an empty string "" if the queue is
     *         empty. Do NOT free the returned pointer.
     */
    const char* LF_GetStatus(void);

    /**
     * @brief Injects a custom log message into the status queue.
      *
      * @param status  UTF-8, null-terminated message string.
      */
    void LF_PostStatus(const char* status);

    /* ============================================================================
     * NETWORK EVENTS - process-global connect/disconnect notifications
     * ============================================================================ */

     /**
      * @brief Installs or clears the global network event handlers.
      *
      * Both handlers are process-global; there is no per-client registration.
      *
      * "Connect" semantics:
      *   Fires the FIRST time a client receives a service API-info broadcast.
      *   This is NOT the TCP handshake; it is the earliest point at which the
      *   client can actually route remote calls. Fires at most once per
      *   connection lifecycle (but again after an auto-reconnect).
      *
      * "Disconnect" semantics:
      *   Fires once per physical link loss. Automatic reconnects do NOT emit
      *   a Disconnect for the reconnect attempt itself.
      *
      * Threading contract (CRITICAL):
      *   - Callbacks run on a BACKGROUND WORKER THREAD.
      *   - The @c addr argument is valid ONLY during the callback invocation.
      *     Copy the string inside the callback if you need to retain it.
      *   - Never call blocking LingoFuse functions inside these callbacks.
      *   - In managed languages, keep a strong reference to the delegate.
      *
      * Passing NULL for either argument disables that particular event.
      * LF_Shutdown() automatically clears both handlers before teardown.
      */
    void LF_Set_Network_Event(LF_NetworkEventFunc on_connect,
        LF_NetworkEventFunc on_disconnect);

    /* ============================================================================
     * SHUTDOWN
     * ============================================================================ */

     /**
      * @brief Gracefully terminates the entire LingoFuse framework.
      *
      * Steps performed:
      *   1. Clears network event callbacks.
      *   2. Stops all sequenced notification threads.
      *   3. Frees all remaining data handles (including any permanent handle
      *      still alive in the global app/queue pools).
      *   4. Exits the simulated main thread.
      *   5. Clears the global application pool (destroying all TLF_App objects).
      *   6. Unloads the IPC library.
      *
      * After LF_Shutdown(), the library is fully reset and may be re-initialised
      * by calling the preparation functions again. Safe to call multiple times.
      *
      * Cleanup order:
      *   LF_ExitMainThread -> LF_FreeApp(app) -> LF_Shutdown
      */
    void LF_Shutdown(void);

    /* ============================================================================
     * HELPER FUNCTIONS - implemented by this C wrapper, NOT exported from the DLL
     * ----------------------------------------------------------------------------
     * These mirror the Pascal helper functions in `lingofuse_import.pas` and
     * rely on LF_WriteBuffer / LF_ReadBuffer / LF_GetBuffer / LF_SetPos.
     * All helpers use little-endian byte order, matching the library's wire format.
     * ============================================================================ */

     /* ---- Buffer offset accessor --------------------------------------------- */

     /**
      * @brief Returns a pointer to the buffer at the given byte offset.
      *
      * The pointer is valid as long as the handle is not resized or freed.
      */
    void* LF_GetBufferOffset(TDataHnd hnd, int64_t offset);

    /* ---- Atomic write helpers (return 1 on success, 0 on failure) ----------- */

    int LF_WriteInt8(TDataHnd hnd, int8_t   value);
    int LF_WriteUInt8(TDataHnd hnd, uint8_t  value);
    int LF_WriteInt16(TDataHnd hnd, int16_t  value);
    int LF_WriteUInt16(TDataHnd hnd, uint16_t value);
    int LF_WriteInt32(TDataHnd hnd, int32_t  value);
    int LF_WriteUInt32(TDataHnd hnd, uint32_t value);
    int LF_WriteInt64(TDataHnd hnd, int64_t  value);
    int LF_WriteUInt64(TDataHnd hnd, uint64_t value);
    int LF_WriteSingle(TDataHnd hnd, float    value);
    int LF_WriteDouble(TDataHnd hnd, double   value);

    /**
     * @brief Writes a UTF-8 string followed by a null terminator (#0).
     *
     * Empty strings ("") write exactly one byte: #0. A NULL @p value is
     * treated as a failure and returns 0 immediately.
     */
    int LF_WriteString(TDataHnd hnd, const char* value);

    /**
     * @brief Writes a raw byte sequence followed by a null terminator (#0).
     *
     * Unlike LF_WriteString, this does NOT stop at embedded #0 bytes; it
     * writes exactly @p length bytes and appends one additional #0 byte.
     */
    int LF_WriteStringBytes(TDataHnd hnd, const void* data, int64_t length);

    /**
     * @brief Writes a 32-byte UID as raw bytes at the current position.
     *
     * No terminator is appended: this is a fixed 32-byte write, matching
     * Pascal's `m64.WritePtr(@UID, SizeOf(TP2P_UID___))`.
     *
     * NOTE: The @p uid argument uses the ARGUMENT-role `TP2P_UID` (the
     * struct, passed by value). This is a DIFFERENT role from the
     * LF_Get_P2P_UID RETURN value (which is a pointer). See the "UID TYPE"
     * section in the file-level docstring.
     */
    int LF_WriteUid(TDataHnd hnd, TP2P_UID uid);

    /* ---- Atomic read helpers (return 1 on success, 0 on failure) ------------ */

    int LF_ReadInt8(TDataHnd hnd, int8_t* out);
    int LF_ReadUInt8(TDataHnd hnd, uint8_t* out);
    int LF_ReadInt16(TDataHnd hnd, int16_t* out);
    int LF_ReadUInt16(TDataHnd hnd, uint16_t* out);
    int LF_ReadInt32(TDataHnd hnd, int32_t* out);
    int LF_ReadUInt32(TDataHnd hnd, uint32_t* out);
    int LF_ReadInt64(TDataHnd hnd, int64_t* out);
    int LF_ReadUInt64(TDataHnd hnd, uint64_t* out);
    int LF_ReadSingle(TDataHnd hnd, float* out);
    int LF_ReadDouble(TDataHnd hnd, double* out);

    /**
     * @brief Reads a null-terminated UTF-8 string from the current position.
     *
     * Behavior (matching Pascal's fault-tolerant LF_ReadString):
     *
     *   Case 1 - A #0 is found within the buffer: copy the bytes up to (but
     *            not including) the #0, advance the cursor past the #0.
     *
     *   Case 2 - No #0 is found before the end of the buffer (fault-tolerant):
     *            copy all remaining bytes, advance the cursor to
     *            (buffer size + 1). The underlying library implicitly grows
     *            the buffer by one byte to accommodate the new position.
     *
     *   Case 3 - Cursor at or past end of buffer: return 0, set @p buf to "".
     *
     *   Case 4 - @p buf too small: return 0, cursor unchanged (retryable).
     *
     * On success, @p buf is always null-terminated.
     * This wrapper does NOT validate UTF-8.
     *
     * @return 1 on success, 0 on failure.
     */
    int LF_ReadString(TDataHnd hnd, char* buf, size_t buf_size);

    /**
     * @brief Reads a byte sequence terminated by #0 or the end of the buffer.
     *
     * Same Cases 1-4 as LF_ReadString, but the bytes are returned undecoded.
     *
     * @return Number of bytes copied (>= 0) on success, -1 on failure.
     *         An empty string (just a #0 byte) is a valid input and yields
     *         a return value of 0 with the cursor advanced past the #0.
     */
    int64_t LF_ReadStringBytes(TDataHnd hnd, void* buf, int64_t buf_size);

    /**
     * @brief Reads a 32-byte UID from the current position.
     *
     * A fixed 32-byte read, symmetric with LF_WriteUid. No terminator is
     * consumed or appended.
     *
     * NOTE: @p out uses the ARGUMENT-role `TP2P_UID*` (pointer to the
     * struct). This is a DIFFERENT role from the LF_Get_P2P_UID RETURN
     * value (which is a `const TP2P_UID*`). Do NOT conflate the two.
     *
     * @return 1 on success (32 bytes read), 0 on failure (fewer bytes
     *         available; cursor position is undefined on failure).
     */
    int LF_ReadUid(TDataHnd hnd, TP2P_UID* out);

#ifdef __cplusplus
}
#endif

#endif /* LINGOFUSE_H_INCLUDED */