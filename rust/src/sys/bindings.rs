//! Type definitions and function-pointer aliases for the LingoFuse C ABI.
//!
//! This module is the Rust mirror of `LingoFuse.h`. It contains:
//!
//! - The two opaque handle types: [`DataHnd`] and [`AppHnd`].
//! - The 32-byte P2P identity struct: [`LfP2PUid`].
//! - The four callback prototypes: [`LfCallFunc`], [`LfNotifyFunc`],
//!   [`LfNetworkEventFunc`], [`LfAsyncCallOnResult`].
//! - The 59 function-pointer typedefs, one per exported C function.
//!
//! Every declaration in this file is a **pure declaration**. There is no
//! runtime state, no loading, and no function call. The loader in
//! [`crate::sys::loader`] resolves the actual symbols into fields of
//! `NativeLibrary` whose types are the function-pointer typedefs defined
//! here.
//!
//! ## Calling convention
//!
//! All C functions use the `cdecl` calling convention, which Rust spells
//! `extern "C"` on every platform that LingoFuse supports. On Windows
//! x86-64, `cdecl` is the only convention, so `extern "C"` is a no-op
//! distinction; on Windows x86-32, `extern "C"` maps to `cdecl` as
//! required.
//!
//! ## String parameters
//!
//! Every `const char*` parameter is a **UTF-8, NUL-terminated** string.
//! Rust's [`std::ffi::CString`] produces exactly that representation.
//! The native library stores and returns strings in the same encoding;
//! `LF_Get_Status` and `LF_Generate_AppName` return pointers into
//! **temporary buffers** with documented lifetimes (see the individual
//! typedefs).
//!
//! ## Byte buffer parameters
//!
//! `LF_WriteBuffer` / `LF_ReadBuffer` take a raw `void*` plus an `i64`
//! byte count. The buffer is **not** NUL-terminated; the count is
//! authoritative. This is a different protocol layer from the string
//! parameter convention above.
//!
//! ## UID type - `LfP2PUid`
//!
//! The Pascal-side type `TP2P_UID___` is `array[0..31] of Byte`. In C
//! there are no function-returnable arrays, so the C header wraps the
//! 32-byte value in a struct, and this module mirrors that struct as
//! [`LfP2PUid`].
//!
//! The same Pascal type plays **two distinct roles** at the C ABI:
//!
//! | Role     | Where it appears                                             | C type               |
//! |----------|--------------------------------------------------------------|----------------------|
//! | Argument | `LF_UID_Call`, `LF_UID_Notify`, `LF_Check_UID`, `LF_WriteUid`| `TP2P_UID` (by value)|
//! | Return   | `LF_Get_P2P_UID`                                             | `const TP2P_UID*`    |
//!
//! The two roles must **not** be unified at the typedef level:
//!
//! - Argument-role typedefs take `LfP2PUid` **by value**.
//! - Return-role typedefs return `*const LfP2PUid`.
//!
//! The higher-level `Uid` newtype in [`crate::uid`] provides a safe
//! Rust abstraction over both roles.
//!
//! ## Async callback contract
//!
//! [`LfAsyncCallOnResult`] is the prototype for every asynchronous call
//! result delivery. The `result` parameter is a `DataHnd` **owned by the
//! framework**; it is released immediately after the callback returns.
//! The callback MUST:
//!
//! - Read or copy everything it needs inside the callback body.
//! - NOT call `LF_FreeData` on the handle.
//! - NOT retain the handle past its own return.
//!
//! This is the opposite of the synchronous family (`LF_Call` /
//! `LF_UID_Call` / `LF_P2PNAME_Call`), whose returned handle is owned by
//! the caller and MUST be released with `LF_FreeData`.
//!
//! ## Handle lifetime summary
//!
//! | Kind              | Created by                     | Released by      | Auto-reclaimed? |
//! |-------------------|--------------------------------|------------------|-----------------|
//! | Data (auto)       | `LF_CreateData`                | `LF_FreeData`    | Yes, 10 min idle, 5 s scan |
//! | Data (permanent)  | `LF_CreateData_Permanent`      | `LF_FreeData`    | No              |
//! | App               | `LF_CreateApp`                 | `LF_FreeApp`     | No (two-stage)  |
//!
//! Both data-handle kinds must be explicitly freed. The auto-reclaimer
//! is a safety net, not a substitute for `LF_FreeData`.

#![allow(non_camel_case_types)]

use std::ffi::{c_char, c_void};

// ============================================================================
// Opaque handle types
// ============================================================================

/// Opaque handle to a LingoFuse data buffer (`TDataHnd` in C).
///
/// A data handle wraps an API name and a byte buffer with a read/write
/// cursor. It is the fundamental primitive of every LingoFuse call:
/// request payloads are written into a data handle, and response
/// payloads are read out of one.
///
/// ## Kinds
///
/// Two flavours exist, distinguished only by how they were created:
///
/// - **Auto-recycled**, created by `LF_CreateData`. Added to the
///   library's idle pool. The pool scans every **5 seconds** and frees
///   any handle idle for more than **10 minutes**. Every accessor call
///   refreshes the idle timestamp.
///
/// - **Permanent**, created by `LF_CreateData_Permanent`. Not added to
///   the pool. Never auto-reclaimed.
///
/// `LF_FreeData` on an auto handle only marks it deleted; the actual
/// release happens on the next pool scan (at most 5 seconds later). On
/// a permanent handle the release is synchronous.
///
/// ## Ownership
///
/// The handle is a raw pointer. It must be freed with `LF_FreeData`;
/// it must never be dereferenced directly.
///
/// ## Threading
///
/// The handle is safe to pass across threads. It must **not** be written
/// concurrently from multiple threads; reads are safe while another
/// thread reads (but not while another thread writes).
#[repr(transparent)]
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct DataHnd(pub *mut c_void);

impl DataHnd {
    /// The null handle. Safe to pass to `LF_FreeData`; the native layer
    /// ignores it.
    pub const NULL: DataHnd = DataHnd(std::ptr::null_mut());

    /// Returns `true` when the wrapped pointer is null.
    #[inline]
    pub fn is_null(self) -> bool {
        self.0.is_null()
    }
}

impl Default for DataHnd {
    #[inline]
    fn default() -> Self {
        DataHnd::NULL
    }
}

/// Opaque handle to a LingoFuse application (`TAppHnd` in C).
///
/// An application is a named container for a set of related APIs. It is
/// the unit of network routing: a caller targets `(app_name, api_name)`,
/// and the mesh dispatches the call to one of the clients that hosts
/// that app.
///
/// ## Lifetime
///
/// `LF_FreeApp` performs only the **first stage** of a two-stage
/// destruction. The native object is detached from all clients and its
/// sequenced-notification threads are stopped, but the underlying
/// `TLF_App` remains alive in the global pool until `LF_Shutdown` is
/// called. After `LF_FreeApp`, the handle is invalid and must not be
/// reused.
///
/// ## Null
///
/// A null `AppHnd` is the expected argument for `LF_PrepareClient` when
/// the client is a **pure consumer** that does not expose an app.
#[repr(transparent)]
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct AppHnd(pub *mut c_void);

impl AppHnd {
    /// The null handle. Safe to pass to `LF_FreeApp` and to
    /// `LF_PrepareClient` (as a pure consumer).
    pub const NULL: AppHnd = AppHnd(std::ptr::null_mut());

    /// Returns `true` when the wrapped pointer is null.
    #[inline]
    pub fn is_null(self) -> bool {
        self.0.is_null()
    }
}

impl Default for AppHnd {
    #[inline]
    fn default() -> Self {
        AppHnd::NULL
    }
}

// ============================================================================
// P2P UID value type
// ============================================================================

/// The 32-byte P2P session identifier, in ABI form.
///
/// This is the C-ABI mirror of the Pascal type `TP2P_UID___`
/// (`array[0..31] of Byte`). The C header wraps the array in a struct so
/// that it can be passed by value across the cdecl boundary; this Rust
/// type mirrors that struct exactly.
///
/// ## Role distinction
///
/// This type is used **by value** in argument position only. The
/// return-role instance (`LF_Get_P2P_UID`) returns a `*const LfP2PUid`,
/// not a value.
///
/// See the module-level documentation for the full ABI note, and
/// [`crate::uid::Uid`] for the safe Rust abstraction that unifies both
/// roles.
///
/// ## Layout
///
/// `#[repr(C)]` with a single `[u8; 32]` field. On x86-64 (both System V
/// AMD64 and Microsoft x64), a >16-byte aggregate is classified MEMORY
/// by the psABI and is therefore passed on the stack. FPC's
/// `array[0..31] of Byte` falls into the same MEMORY class, so this
/// struct is ABI-compatible for the argument-role positions.
#[repr(C)]
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct LfP2PUid {
    /// The 32 raw UID octets, in wire order.
    pub bytes: [u8; 32],
}

impl LfP2PUid {
    /// The all-zero UID ("null UID").
    pub const NULL: LfP2PUid = LfP2PUid { bytes: [0u8; 32] };

    /// Builds a `LfP2PUid` from a fixed-size byte array.
    #[inline]
    pub const fn from_bytes(bytes: [u8; 32]) -> Self {
        LfP2PUid { bytes }
    }

    /// Returns `true` when all 32 bytes are zero.
    #[inline]
    pub fn is_null(&self) -> bool {
        self.bytes.iter().all(|&b| b == 0)
    }
}

impl Default for LfP2PUid {
    #[inline]
    fn default() -> Self {
        LfP2PUid::NULL
    }
}

// ============================================================================
// Callback prototypes
// ============================================================================

/// Callback for a Call (request-response) API.
///
/// # Parameters
///
/// - `trigger`: The user-supplied pointer passed at registration time.
///   Returned unchanged.
/// - `input`: A **read-only** data handle containing the request payload.
///   The native layer owns it; the callback must not free it.
/// - `output`: A **writable** data handle. Everything written into it is
///   marshalled back to the caller as the response.
///
/// # Contract
///
/// - Must use the `extern "C"` calling convention.
/// - Must not unwind. Rust panics must be caught inside the callback
///   (typically with `std::panic::catch_unwind`).
/// - Must not call any blocking LingoFuse function (`LF_Call`,
///   `LF_LocalCall`, `LF_PrepareDone`, `LF_Shutdown`); doing so
///   deadlocks.
/// - Must not free `input` or `output`.
/// - Must return promptly. A long-running callback occupies a worker
///   thread from the native pool.
///
/// # Writing to `input` / reading from `output`
///
/// Writing to `input` or reading from `output` is undefined behaviour.
/// The ABI does not prevent it; the resulting buffer state is corrupted.
pub type LfCallFunc = unsafe extern "C" fn(
    trigger: *mut c_void,
    input: DataHnd,
    output: DataHnd,
);

/// Callback for a Notify (one-way) API.
///
/// # Parameters
///
/// - `trigger`: The user-supplied pointer passed at registration time.
/// - `input`: A **read-only** data handle containing the notification
///   payload. The native layer owns it; the callback must not free it.
///
/// # Contract
///
/// Identical to [`LfCallFunc`], minus the `output` parameter. In
/// particular: no unwinding, no blocking calls, return promptly.
pub type LfNotifyFunc = unsafe extern "C" fn(
    trigger: *mut c_void,
    input: DataHnd,
);

/// Callback for a network connect / disconnect event.
///
/// # Parameters
///
/// - `addr`: A UTF-8, NUL-terminated endpoint string. The buffer is
///   valid **only during the callback invocation**; the native library
///   frees it as soon as the callback returns. Copy the string
///   immediately (for example with `std::ffi::CStr::from_ptr(...).to_owned()`)
///   if you need to retain it.
///
/// # Semantics
///
/// - **Connect**: Fires the first time a client receives a service
///   API-info broadcast. This is **not** the TCP handshake; it is the
///   earliest point at which remote calls can be routed. Fires once per
///   connection lifecycle, and again after an auto-reconnect.
/// - **Disconnect**: Fires once per physical link loss. An automatic
///   reconnect does not emit a Disconnect for the reconnect attempt
///   itself; it emits a new Connect once the client is back online.
///
/// # Contract
///
/// - Must use the `extern "C"` calling convention.
/// - Must not unwind. Rust panics must be caught inside the callback.
/// - Must not block. This callback runs on a background worker thread
///   owned by the native library; blocking it starves the pool.
/// - Must not touch UI controls directly.
pub type LfNetworkEventFunc = unsafe extern "C" fn(addr: *const c_char);

/// Callback for an asynchronous Call result.
///
/// Used by every `LF_Async_*` function:
///
/// - `LF_Async_Call`
/// - `LF_Async_Sequenced_Call`
/// - `LF_UID_Async_Call`
/// - `LF_UID_Async_Sequenced_Call`
/// - `LF_P2PNAME_Async_Call`
/// - `LF_P2PNAME_Async_Sequenced_Call`
///
/// # Parameters
///
/// - `data`: The opaque pointer supplied by the caller at the call site.
///   The library neither owns nor frees it; ownership transfer is the
///   caller's responsibility, as documented at each call site.
/// - `result`: A `DataHnd` **owned by the framework**.
///
/// # Contract
///
/// The `result` handle is released IMMEDIATELY after this callback
/// returns. The callback MUST:
///
/// - Read or copy everything it needs inside the callback body.
/// - NOT call `LF_FreeData` on `result`.
/// - NOT retain the handle past the callback body.
///
/// This is the **opposite** of the synchronous family
/// (`LF_Call` / `LF_UID_Call` / `LF_P2PNAME_Call`), whose returned
/// handle is owned by the caller and MUST be released with
/// `LF_FreeData`.
///
/// # Threading
///
/// The callback runs on a `TCompute` worker thread. It is **not** the
/// caller's thread and **not** the simulated main thread. It must return
/// promptly and must not call any blocking LingoFuse function.
///
/// # Panic isolation
///
/// Rust wrappers around this ABI type wrap the user closure in
/// `std::panic::catch_unwind`. A panic is converted into a silent no-op
/// rather than undefined behaviour at the FFI boundary.
pub type LfAsyncCallOnResult = unsafe extern "C" fn(
    data: *mut c_void,
    result: DataHnd,
);

// ============================================================================
// Data handle function pointers (12)
// ============================================================================

/// `LF_CreateData` — create a new **auto-recycled** data handle.
///
/// # Parameters
///
/// - `method_name`: The API name as a UTF-8, NUL-terminated string. It
///   is stored in the handle and becomes the `MethodName` component of
///   the wire format. The name cannot be changed after creation.
///
/// # Returns
///
/// A non-null handle. The caller must release it with `LF_FreeData`.
///
/// # Auto-recycle behaviour
///
/// The handle is added to the library's idle pool. The pool scans every
/// 5 seconds and frees any handle idle for more than 10 minutes. Any
/// accessor refreshes the idle timer. `LF_FreeData` only marks the
/// handle deleted; the actual release happens on the next pool scan.
pub type LfCreateDataFn = unsafe extern "C" fn(
    method_name: *const c_char,
) -> DataHnd;

/// `LF_CreateData_Permanent` — create a new **permanent** data handle.
///
/// # Difference from `LF_CreateData`
///
/// - Not added to the idle pool.
/// - Never auto-reclaimed, no matter how long it has been idle.
/// - `LF_FreeData` releases it **synchronously** (not on a later scan).
///
/// # When to use
///
/// Handles that must survive for the entire lifetime of the process, or
/// for an unbounded period (cached request templates, long-lived scratch
/// buffers, global registries).
///
/// # Pitfall: `Permanent` means "not auto-reclaimed"
///
/// It does **not** mean "never released". You are responsible for
/// calling `LF_FreeData`. Losing the pointer leaks the handle for the
/// lifetime of the process.
///
/// # Pitfall: no-op window
///
/// `LF_FreeData` is a no-op while the simulated main thread is not
/// active (before `LF_PrepareDone` or after `LF_ExitMainThread`).
/// Permanent handles created in that window stay allocated until the
/// process terminates or `LF_Shutdown` runs.
pub type LfCreateDataPermanentFn = unsafe extern "C" fn(
    method_name: *const c_char,
) -> DataHnd;

/// `LF_FreeData` — release a data handle.
///
/// # Parameters
///
/// - `hnd`: The handle to release. A null handle is accepted and
///   ignored.
///
/// # Behaviour
///
/// - **Auto-recycled handle**: only marks the handle deleted. The
///   actual release happens on the next idle-pool scan (at most 5
///   seconds later).
/// - **Permanent handle**: releases it synchronously.
///
/// # Pitfall: no-op window
///
/// This call is a **no-op** while the simulated main thread is not
/// active, i.e. before `LF_PrepareDone` or after `LF_ExitMainThread`.
///
/// # Pitfall: async result handles
///
/// Do **not** call this function on the `result` argument of an
/// [`LfAsyncCallOnResult`] callback. That handle is owned by the
/// framework and released automatically when the callback returns.
pub type LfFreeDataFn = unsafe extern "C" fn(hnd: DataHnd);

/// `LF_GetBuffer` — return a raw pointer to the handle's internal buffer.
///
/// # Returns
///
/// A pointer to the start of the buffer, or null when the buffer is
/// empty.
///
/// # Pointer lifetime
///
/// The pointer is invalidated by any subsequent call that resizes the
/// buffer: `LF_WriteBuffer`, `LF_SetSize`, or `LF_SetPos` past the end.
/// It must not be freed by the caller.
pub type LfGetBufferFn = unsafe extern "C" fn(hnd: DataHnd) -> *mut c_void;

/// `LF_WriteBuffer` — write bytes at the current cursor.
///
/// The buffer grows as needed; the cursor advances by the number of
/// bytes written.
///
/// # Parameters
///
/// - `hnd`: The target handle.
/// - `buff`: A pointer to the source bytes. Must not be null when
///   `size > 0`.
/// - `size`: The number of bytes to write.
///
/// # Returns
///
/// The number of bytes actually written. A short write indicates a
/// serious failure (corrupt handle or out of memory).
pub type LfWriteBufferFn = unsafe extern "C" fn(
    hnd: DataHnd,
    buff: *const c_void,
    size: i64,
) -> i64;

/// `LF_ReadBuffer` — read bytes at the current cursor.
///
/// The cursor advances by the number of bytes actually read.
///
/// # Parameters
///
/// - `hnd`: The source handle.
/// - `buff`: A pointer to the destination buffer. Must not be null when
///   `size > 0`.
/// - `size`: The maximum number of bytes to read.
///
/// # Returns
///
/// The number of bytes actually read. This may be less than `size` when
/// the buffer ends early. It is never negative.
pub type LfReadBufferFn = unsafe extern "C" fn(
    hnd: DataHnd,
    buff: *mut c_void,
    size: i64,
) -> i64;

/// `LF_GetPos` — return the current read/write cursor.
pub type LfGetPosFn = unsafe extern "C" fn(hnd: DataHnd) -> i64;

/// `LF_SetPos` — set the current read/write cursor.
///
/// A position past the current size implicitly grows the buffer; the
/// new bytes are uninitialised.
///
/// # Pitfall
///
/// Setting a very large position reserves a very large buffer
/// immediately. Use reasonable values.
pub type LfSetPosFn = unsafe extern "C" fn(hnd: DataHnd, pos: i64);

/// `LF_GetSize` — return the total buffer size, in bytes.
pub type LfGetSizeFn = unsafe extern "C" fn(hnd: DataHnd) -> i64;

/// `LF_SetSize` — resize the buffer.
///
/// Growing the buffer leaves the new bytes uninitialised. Shrinking the
/// buffer discards the trailing bytes.
pub type LfSetSizeFn = unsafe extern "C" fn(hnd: DataHnd, size: i64);

/// `LF_Get_P2P_UID` — read the sender's injected UID from an INPUT handle.
///
/// # Side-data semantics
///
/// This function does **not** read a property of the handle itself. It
/// reads the "side data" that the sender's transport layer writes into
/// every request payload before transmission. The receiver therefore
/// sees the UID only inside the `Data_Param` of the **input** handle
/// that the framework delivers to a registered callback.
///
/// **Valid only on input handles:**
///
/// - The `input` argument of a `LfCallFunc` callback.
/// - The `input` argument of a `LfNotifyFunc` callback.
/// - The input handle of a local call / notify.
///
/// **Invalid on:**
///
/// - Output handles (no `Data_Param`).
/// - Caller-created handles (`LF_CreateData` / `LF_CreateData_Permanent`).
///
/// In the invalid cases the native library logs a warning and returns a
/// pointer to a zero-filled UID.
///
/// # Return value
///
/// A pointer to a 32-byte [`LfP2PUid`], allocated by the native library
/// and scheduled for automatic release approximately **5 seconds** after
/// the call. The caller MUST:
///
/// 1. Copy the 32 bytes immediately if the value is to be retained.
/// 2. NOT call any deallocation function on the pointer.
/// 3. NOT retain the pointer beyond the ~5-second window.
///
/// [`crate::uid::Uid::from_ptr`] (added in a later batch) encapsulates
/// all three rules.
pub type LfGetP2PUidFn = unsafe extern "C" fn(hnd: DataHnd) -> *const LfP2PUid;

/// `LF_Get_P2P_Name` — read the sender's injected P2P name from an INPUT handle.
///
/// # Side-data semantics
///
/// Same identity-injection mechanism as [`LfGetP2PUidFn`]. This function
/// reads the `FromP2PName` field that the sender's transport layer wrote
/// into the payload header; it does NOT read a property of the handle
/// itself.
///
/// **Valid only on input handles**: the `input` argument of a
/// `LfCallFunc` / `LfNotifyFunc` callback, or the input of a local call.
/// On output handles and on caller-created handles, the native library
/// logs a warning and returns an empty string.
///
/// # Return value
///
/// A pointer to a UTF-8, NUL-terminated string in a transient buffer
/// released approximately **5 seconds** after the call. The caller MUST
/// copy the string immediately if it is to be retained, and MUST NOT
/// free the pointer.
pub type LfGetP2PNameFn = unsafe extern "C" fn(hnd: DataHnd) -> *const c_char;

// ============================================================================
// Application handle function pointers (5)
// ============================================================================

/// `LF_CreateApp` — create a new application.
///
/// # Parameters
///
/// - `app_name`: UTF-8, NUL-terminated. Should be unique on the mesh.
///   Case-insensitive matching applies at lookup time.
/// - `desc`: UTF-8, NUL-terminated, human-readable description. A null
///   pointer is treated as an empty string by the C wrapper, but the
///   native library itself expects a non-null string; passing an empty
///   string is safer.
///
/// # Returns
///
/// A non-null handle. The caller must release it with `LF_FreeApp`.
pub type LfCreateAppFn = unsafe extern "C" fn(
    app_name: *const c_char,
    desc: *const c_char,
) -> AppHnd;

/// `LF_FreeApp` — detach an application from all clients.
///
/// # Two-stage destruction
///
/// This is only the **first stage**. The application is detached from
/// all clients and its sequenced-notification threads are stopped, but
/// the underlying object remains in the global pool until `LF_Shutdown`
/// is called. After this call the handle is invalid and must not be
/// reused.
///
/// # Shutdown guard
///
/// The native implementation returns immediately (does nothing) when
/// the framework is not active - i.e. before `LF_PrepareDone` or after
/// `LF_Shutdown`. Always call `LF_FreeApp` **before** `LF_Shutdown`.
pub type LfFreeAppFn = unsafe extern "C" fn(app_hnd: AppHnd);

/// `LF_Generate_AppName` — generate a globally unique application name.
///
/// # Preconditions
///
/// Must be called **after** `LF_PrepareDone` returns `1`. Otherwise the
/// generated name lacks the C4 tunnel information and may not be
/// unique on the mesh.
///
/// # Return value
///
/// A pointer into a temporary buffer that is **valid for approximately
/// 5 seconds**. The library frees the underlying memory after that
/// time. Copy the string immediately (e.g. via
/// `CStr::from_ptr(...).to_owned()`). Returns an empty string on
/// failure.
pub type LfGenerateAppNameFn = unsafe extern "C" fn() -> *const c_char;

/// `LF_Get_AppName` — return the name of an application handle.
///
/// # Return value
///
/// Same 5-second validity rule as `LF_Generate_AppName`. The returned
/// pointer targets a temporary buffer; copy the string immediately.
/// Returns an empty string when `app_hnd` is null.
pub type LfGetAppNameFn = unsafe extern "C" fn(
    app_hnd: AppHnd,
) -> *const c_char;

/// `LF_BindApp` — bind an application to all currently unbound clients.
///
/// # Preconditions
///
/// - The framework must be running (`LF_PrepareDone` returned `1`).
/// - The application must be valid (not freed).
///
/// # Returns
///
/// The number of clients bound. Zero means either the main thread is
/// not active, or all clients already host an application. Each client
/// can host at most one application.
pub type LfBindAppFn = unsafe extern "C" fn(app_hnd: AppHnd) -> i32;

// ============================================================================
// API registration function pointers (3 + 3)
// ============================================================================

/// `LF_RegisterCall` — register a Call (request-response) API.
///
/// # Parameters
///
/// - `app_hnd`: The hosting application handle.
/// - `method_name`: UTF-8, NUL-terminated API name. Case-insensitive
///   matching applies at lookup time.
/// - `desc`: UTF-8, NUL-terminated description.
/// - `trigger`: User-supplied pointer, returned unchanged to the
///   callback.
/// - `on_call`: The callback. Must use `extern "C"` and must not unwind.
///
/// # Returns
///
/// `1` on success, `0` on failure (usually a duplicate API name).
pub type LfRegisterCallFn = unsafe extern "C" fn(
    app_hnd: AppHnd,
    method_name: *const c_char,
    desc: *const c_char,
    trigger: *mut c_void,
    on_call: LfCallFunc,
) -> i32;

/// `LF_RegisterNotify` — register a Notify (one-way) API.
///
/// Same contract as [`LfRegisterCallFn`], minus the output handle.
pub type LfRegisterNotifyFn = unsafe extern "C" fn(
    app_hnd: AppHnd,
    method_name: *const c_char,
    desc: *const c_char,
    trigger: *mut c_void,
    on_notify: LfNotifyFunc,
) -> i32;

/// `LF_Unregister` — remove a previously registered API.
///
/// # Return value
///
/// `1` if the API was found and removed, `0` otherwise.
///
/// # Propagation delay
///
/// The local effect is immediate. A network broadcast propagates the
/// removal to remote peers within approximately 3 seconds. During that
/// window, a remote caller may still route to this API and receive an
/// empty response.
pub type LfUnregisterFn = unsafe extern "C" fn(
    app_hnd: AppHnd,
    method_name: *const c_char,
) -> i32;

/// `LF_Register_P2P_Call` — register a process-wide P2P Call API.
///
/// # Difference from `LF_RegisterCall`
///
/// P2P APIs are registered on the process-wide `LF_P2P_APP` and are
/// reachable via UID addressing and P2PName addressing only. They are
/// **not** reachable via App-name addressing, even if the API name
/// happens to match a registered App name.
///
/// # Typical use
///
/// Globally discoverable utility APIs (health probes, capability
/// discovery, identity echo) that any client in the mesh can call by
/// UID or by P2PName without knowing the target's App name.
///
/// # Returns
///
/// `1` on success, `0` on failure (usually a duplicate name in the P2P
/// namespace).
pub type LfRegisterP2PCallFn = unsafe extern "C" fn(
    method_name: *const c_char,
    desc: *const c_char,
    trigger: *mut c_void,
    on_call: LfCallFunc,
) -> i32;

/// `LF_Register_P2P_Notify` — register a process-wide P2P Notify API.
///
/// Same contract as [`LfRegisterP2PCallFn`], minus the output handle.
pub type LfRegisterP2PNotifyFn = unsafe extern "C" fn(
    method_name: *const c_char,
    desc: *const c_char,
    trigger: *mut c_void,
    on_notify: LfNotifyFunc,
) -> i32;

/// `LF_Unregister_P2P` — remove a process-wide P2P API by name.
///
/// Does **not** affect app-bound APIs of the same name.
///
/// # Return value
///
/// `1` if the API was found and removed, `0` otherwise.
pub type LfUnregisterP2PFn = unsafe extern "C" fn(
    method_name: *const c_char,
) -> i32;

// ============================================================================
// Local execution function pointers (2)
// ============================================================================

/// `LF_LocalCall` — invoke a Call API in-process, bypassing the network.
///
/// # Parameters
///
/// - `app_hnd`: The application that owns the target API.
/// - `param`: The input data handle. It is **not** consumed by this
///   call; the caller retains ownership.
///
/// # Returns
///
/// A new result handle owning the response. The caller must release it
/// with `LF_FreeData`. When the target API is not registered locally,
/// the returned handle has size `0`.
///
/// # Note
///
/// This bypasses the C4 mesh entirely. It does not exercise the network
/// path and it does not observe load balancing.
pub type LfLocalCallFn = unsafe extern "C" fn(
    app_hnd: AppHnd,
    param: DataHnd,
) -> DataHnd;

/// `LF_LocalNotify` — invoke a Notify API in-process.
///
/// The input handle is not consumed; the caller retains ownership.
pub type LfLocalNotifyFn = unsafe extern "C" fn(
    app_hnd: AppHnd,
    param: DataHnd,
);

// ============================================================================
// Network preparation function pointers (5)
// ============================================================================

/// `LF_ResetPrepare` — clear the preparation queue.
///
/// Running services and clients are **not** affected. Only the pending
/// list of services/clients to be created by the next `LF_PrepareDone`
/// is cleared.
pub type LfResetPrepareFn = unsafe extern "C" fn();

/// `LF_PrepareService` — prepare a C4 service.
///
/// # Parameters
///
/// - `listening_addr`: The local binding address. May be a TCP address
///   (`0.0.0.0:9898`) or an IPC name (`ipc:my_service`).
/// - `physics_addr`: The address advertised to clients. Usually equal
///   to `listening_addr`.
///
/// # Returns
///
/// An internal tag on success, or `-1` for a duplicate address.
///
/// # Duplicate detection
///
/// Two paths are checked: the running service pool and the pending
/// preparation list. A duplicate on either path produces `-1`.
pub type LfPrepareServiceFn = unsafe extern "C" fn(
    listening_addr: *const c_char,
    physics_addr: *const c_char,
) -> i32;

/// `LF_PrepareClient` — prepare a C4 client.
///
/// # Parameters
///
/// - `physics_addr`: The address of the target service.
/// - `app_hnd`: The application to expose, or a null handle for a pure
///   consumer.
///
/// # Returns
///
/// An internal tag on success, or `-1` for a duplicate address.
///
/// # Duplicate addresses
///
/// Without `Overlap_Connection=True`, the same physical address can
/// host only one client per process. A second `LF_PrepareClient` on the
/// same address returns `-1` and **silently discards** the app handle.
///
/// Set `Overlap_Connection=True` via `LF_SetOption` **before** the call
/// to allow multiple independent tunnels to the same address.
pub type LfPrepareClientFn = unsafe extern "C" fn(
    physics_addr: *const c_char,
    app_hnd: AppHnd,
) -> i32;

/// `LF_PrepareDone` — start the framework with the prepared services
/// and clients.
///
/// # Return value
///
/// - `1` on success.
/// - `0` on a second call in the same process without an intervening
///   `LF_Shutdown`. **This is not a failure**: the framework is already
///   running.
///
/// # Blocking
///
/// By default (`Wait_Connection_ReadyOk=True`), this call blocks until
/// every prepared client is online, or until `Wait_Connection_Timeout`
/// milliseconds have elapsed. Configure both via `LF_SetOption` before
/// calling.
///
/// Even after a timeout, this function returns `1`; it does not report
/// a partial failure. Callers that need a strong readiness guarantee
/// must poll `LF_CheckApp` / `LF_CheckApi` after `LF_PrepareDone`.
pub type LfPrepareDoneFn = unsafe extern "C" fn() -> i32;

/// `LF_ExitMainThread` — request the simulated main thread to exit.
///
/// # Pitfall
///
/// This also **flushes the data-handle pool**, releasing every
/// outstanding handle - including handles created with
/// `LF_CreateData_Permanent`. Do not use any data handle after this
/// call has returned.
///
/// This does not release all resources; call `LF_Shutdown` for a full
/// cleanup.
pub type LfExitMainThreadFn = unsafe extern "C" fn();

// ============================================================================
// Remote invocation function pointers (5 + 5 + 5)
// ============================================================================

/// `LF_Call` — synchronous remote call.
///
/// # Parameters
///
/// - `app_name`: Target application name (UTF-8, NUL-terminated).
/// - `param`: Input data handle. Not consumed; the caller retains
///   ownership.
/// - `timeout_ms`: Timeout in milliseconds. `0` means "wait
///   indefinitely".
///
/// # Returns
///
/// A new result handle. **Never null.** On timeout or unreachable
/// target, the returned handle has size `0`. Callers must check the
/// size to distinguish a failure from a valid empty response. The
/// caller must release the handle with `LF_FreeData`.
///
/// # Deadlock warning
///
/// Do not call this function from inside a registered callback. The
/// callback runs on a worker thread that may hold internal locks the
/// main thread needs to dispatch the response; the call self-locks.
pub type LfCallFn = unsafe extern "C" fn(
    app_name: *const c_char,
    param: DataHnd,
    timeout_ms: u64,
) -> DataHnd;

/// `LF_Async_Call` — asynchronous remote call.
///
/// # Parameters
///
/// - `app_name`: Target application name (UTF-8, NUL-terminated).
/// - `param`: Input data handle. Not consumed; the caller retains
///   ownership. The framework copies the payload synchronously inside
///   this call, so the handle may be destroyed immediately afterwards.
/// - `data`: Opaque pointer forwarded verbatim to `on_result`. The
///   library neither owns nor frees it.
/// - `on_result`: The callback. See [`LfAsyncCallOnResult`] for the
///   ownership contract of the delivered handle.
///
/// # Returns
///
/// `1` if the request was queued, `0` otherwise. On `0` the callback is
/// never invoked; the Rust wrapper is responsible for releasing the
/// `data` allocation and delivering a synchronous error to the caller.
pub type LfAsyncCallFn = unsafe extern "C" fn(
    app_name: *const c_char,
    param: DataHnd,
    data: *mut c_void,
    on_result: LfAsyncCallOnResult,
) -> i32;

/// `LF_Async_Sequenced_Call` — asynchronous call with FIFO ordering per
/// `(app, api)` pair.
///
/// Same ownership and threading contract as [`LfAsyncCallFn`].
pub type LfAsyncSequencedCallFn = unsafe extern "C" fn(
    app_name: *const c_char,
    param: DataHnd,
    data: *mut c_void,
    on_result: LfAsyncCallOnResult,
) -> i32;

/// `LF_Notify` — send a one-way notification.
///
/// # Delivery guarantees
///
/// - **No ordering guarantee** across different calls.
/// - **No delivery guarantee** (best-effort).
/// - No return value.
///
/// Use `LF_Sequenced_Notify` when FIFO ordering per `(app, api)` pair
/// is required.
pub type LfNotifyFn = unsafe extern "C" fn(
    app_name: *const c_char,
    param: DataHnd,
);

/// `LF_Sequenced_Notify` — send a FIFO-ordered one-way notification.
///
/// # Delivery guarantees
///
/// FIFO order is guaranteed **only for the same `(app, api)` pair**.
/// Different pairs are independent and unordered with respect to each
/// other.
///
/// # Implementation
///
/// A dedicated thread per `(app, api)` pair processes the queue. An
/// idle thread terminates after 5 minutes; the next notification
/// recreates it with a small startup latency.
pub type LfSequencedNotifyFn = unsafe extern "C" fn(
    app_name: *const c_char,
    param: DataHnd,
);

// ----------------------------------------------------------------------------
// UID addressing
// ----------------------------------------------------------------------------
//
// All four functions below take an ARGUMENT-role `LfP2PUid` **by value**.
// The typedef must not be changed to a pointer: FPC passes a 32-byte
// Pascal array by value on the stack, and the Rust signature must match
// that convention exactly.

/// `LF_UID_Call` — synchronous remote call addressed by session UID.
///
/// UID routing is LOCAL-FIRST, matching App-name routing. A UID can
/// address any API registered on the target - whether app-bound or
/// process-wide - without the caller knowing the target's App name.
///
/// Same ownership contract as [`LfCallFn`].
pub type LfUidCallFn = unsafe extern "C" fn(
    uid: LfP2PUid,
    param: DataHnd,
    timeout_ms: u64,
) -> DataHnd;

/// `LF_UID_Async_Call` — asynchronous call addressed by session UID.
///
/// Same ownership contract as [`LfAsyncCallFn`].
pub type LfUidAsyncCallFn = unsafe extern "C" fn(
    uid: LfP2PUid,
    param: DataHnd,
    data: *mut c_void,
    on_result: LfAsyncCallOnResult,
) -> i32;

/// `LF_UID_Async_Sequenced_Call` — asynchronous, FIFO-ordered call
/// addressed by session UID.
pub type LfUidAsyncSequencedCallFn = unsafe extern "C" fn(
    uid: LfP2PUid,
    param: DataHnd,
    data: *mut c_void,
    on_result: LfAsyncCallOnResult,
) -> i32;

/// `LF_UID_Notify` — one-way notification addressed by session UID.
pub type LfUidNotifyFn = unsafe extern "C" fn(
    uid: LfP2PUid,
    param: DataHnd,
);

/// `LF_UID_Sequenced_Notify` — FIFO-ordered one-way notification
/// addressed by session UID.
pub type LfUidSequencedNotifyFn = unsafe extern "C" fn(
    uid: LfP2PUid,
    param: DataHnd,
);

// ----------------------------------------------------------------------------
// P2PName addressing
// ----------------------------------------------------------------------------
//
// P2PName routing is **NOT** local-first: the call is always forwarded
// to the server, which owns the load-balancing state. The server picks
// a target from the group using either Cycle_Anchor round-robin or the
// FixedSequenced sticky-affinity window, controlled by the
// `Fixed_Sequenced_Time` runtime option (default 20 seconds).

/// `LF_P2PNAME_Call` — synchronous remote call addressed by P2P group
/// name.
///
/// Same ownership contract as [`LfCallFn`].
pub type LfP2PNameCallFn = unsafe extern "C" fn(
    p2p_name: *const c_char,
    param: DataHnd,
    timeout_ms: u64,
) -> DataHnd;

/// `LF_P2PNAME_Async_Call` — asynchronous call addressed by P2P group
/// name.
///
/// Same ownership contract as [`LfAsyncCallFn`].
pub type LfP2PNameAsyncCallFn = unsafe extern "C" fn(
    p2p_name: *const c_char,
    param: DataHnd,
    data: *mut c_void,
    on_result: LfAsyncCallOnResult,
) -> i32;

/// `LF_P2PNAME_Async_Sequenced_Call` — asynchronous, FIFO-ordered call
/// addressed by P2P group name.
pub type LfP2PNameAsyncSequencedCallFn = unsafe extern "C" fn(
    p2p_name: *const c_char,
    param: DataHnd,
    data: *mut c_void,
    on_result: LfAsyncCallOnResult,
) -> i32;

/// `LF_P2PNAME_Notify` — one-way notification addressed by P2P group
/// name.
pub type LfP2PNameNotifyFn = unsafe extern "C" fn(
    p2p_name: *const c_char,
    param: DataHnd,
);

/// `LF_P2PNAME_Sequenced_Notify` — FIFO-ordered one-way notification
/// addressed by P2P group name.
pub type LfP2PNameSequencedNotifyFn = unsafe extern "C" fn(
    p2p_name: *const c_char,
    param: DataHnd,
);

// ============================================================================
// Options, diagnostics, and status function pointers (7)
// ============================================================================

/// `LF_SetOption` — adjust a global runtime option.
///
/// # Parameters
///
/// - `option`: UTF-8, NUL-terminated option name. Case-insensitive.
/// - `value`: UTF-8, NUL-terminated value.
///
/// # Behaviour
///
/// - Unknown option names are **silently ignored** (no error, no
///   warning). This makes typos invisible; double-check the name.
/// - Changes take effect immediately.
/// - Changes are **not** persisted across `LF_Shutdown` /
///   `LF_PrepareDone` cycles; reapply them.
///
/// # Common options
///
/// | Name                      | Type | Default | Purpose |
/// |---------------------------|------|---------|---------|
/// | `Overlap_Connection`      | bool | `False` | Allow multiple clients per address |
/// | `Wait_Connection_ReadyOk` | bool | `True`  | `LF_PrepareDone` waits for clients |
/// | `Wait_Connection_Timeout` | int  | `30000` | Wait timeout, milliseconds |
/// | `Quiet`                   | bool | `False` | Suppress internal log output |
/// | `ShowThreadID`            | bool | `False` | Include thread IDs in logs |
/// | `ConsoleOutput`           | bool | auto    | Console logging on/off |
/// | `Fixed_Sequenced_Time`    | int  | `20000` | Sequenced-notify fallback threshold (ms) |
///
/// Boolean values: `"True"` / `"False"` / `"1"` / `"0"` / `"Yes"` /
/// `"No"` (case-insensitive). Use `"True"` / `"False"` by preference.
pub type LfSetOptionFn = unsafe extern "C" fn(
    option: *const c_char,
    value: *const c_char,
);

/// `LF_GetOption` — read a global runtime option.
///
/// # Parameters
///
/// - `option`: UTF-8, NUL-terminated option name. Case-insensitive.
///
/// # Return value
///
/// A pointer to a UTF-8, NUL-terminated string in a transient buffer
/// released approximately **5 seconds** after the call. The caller MUST
/// copy the string immediately if it is to be retained, and MUST NOT
/// free the pointer.
///
/// Unknown option names return an empty string. Some options are
/// write-only; the `debug` option, for example, returns a fixed
/// placeholder string.
///
/// Boolean options are returned as `"True"` / `"False"`.
pub type LfGetOptionFn = unsafe extern "C" fn(
    option: *const c_char,
) -> *const c_char;

/// `LF_GetStatusCount` — number of pending log messages.
///
/// The queue is bounded at 1000 entries; older entries are dropped when
/// the buffer is full.
///
/// # Main-thread dependency
///
/// The queue is processed by the simulated main thread. Before
/// `LF_PrepareDone`, the count may be stale or zero.
pub type LfGetStatusCountFn = unsafe extern "C" fn() -> i32;

/// `LF_GetStatus` — retrieve the next log message.
///
/// # Return value
///
/// A pointer into a **process-wide static buffer** that the next call
/// to this function overwrites. Copy the string immediately. Returns
/// an empty string when the queue is empty.
///
/// # ABI limitation
///
/// An empty queue and an empty message both produce `""`. Use
/// `LF_GetStatusCount` first to disambiguate.
pub type LfGetStatusFn = unsafe extern "C" fn() -> *const c_char;

/// `LF_PostStatus` — inject a message into the status queue.
///
/// The message is queued even when the simulated main thread is not yet
/// running; it becomes observable once the main thread processes the
/// queue.
pub type LfPostStatusFn = unsafe extern "C" fn(status: *const c_char);

/// `LF_CheckMainThread` — `1` if the simulated main thread is running.
pub type LfCheckMainThreadFn = unsafe extern "C" fn() -> i32;

/// `LF_CheckApp` — `1` if the named application is available.
///
/// # Cache semantics
///
/// The lookup uses a local cache updated by network broadcasts with an
/// approximate **3-second propagation delay**. False negatives
/// immediately after registration, and false positives shortly after
/// unregistration, are both normal.
///
/// Do not use this as an authoritative existence test for critical
/// paths. Issue the call and handle the timeout instead.
pub type LfCheckAppFn = unsafe extern "C" fn(
    app_name: *const c_char,
) -> i32;

/// `LF_CheckApi` — `1` if the named API is available.
///
/// Same cache semantics and propagation delay as `LF_CheckApp`.
pub type LfCheckApiFn = unsafe extern "C" fn(
    app_name: *const c_char,
    api_name: *const c_char,
) -> i32;

/// `LF_Check_UID` — `1` if a client with the given UID is registered.
///
/// The UID is passed as the ARGUMENT-role `LfP2PUid` (the struct, by
/// value).
///
/// Same cache semantics and propagation delay as `LfCheckAppFn`.
pub type LfCheckUidFn = unsafe extern "C" fn(uid: LfP2PUid) -> i32;

/// `LF_Check_UID_Api` — `1` if a client with the given UID exposes the
/// named API.
///
/// Same cache semantics and propagation delay as `LfCheckAppFn`.
pub type LfCheckUidApiFn = unsafe extern "C" fn(
    uid: LfP2PUid,
    api_name: *const c_char,
) -> i32;

/// `LF_Check_P2PNAME` — `1` if a client with the given P2P group name
/// is registered.
///
/// Same cache semantics and propagation delay as `LfCheckAppFn`.
pub type LfCheckP2PNameFn = unsafe extern "C" fn(
    p2p_name: *const c_char,
) -> i32;

/// `LF_Check_P2PNAME_Api` — `1` if a client in the given P2P group
/// exposes the named API.
///
/// Same cache semantics and propagation delay as `LfCheckAppFn`.
pub type LfCheckP2PNameApiFn = unsafe extern "C" fn(
    p2p_name: *const c_char,
    api_name: *const c_char,
) -> i32;

// ============================================================================
// Shutdown function pointer (1)
// ============================================================================

/// `LF_Shutdown` — graceful full shutdown.
///
/// # Steps performed
///
/// 1. Clears the network-event callbacks.
/// 2. Stops all sequenced-notification threads.
/// 3. Frees all remaining data handles - **including any permanent
///    handle still alive**.
/// 4. Exits the simulated main thread.
/// 5. Clears the global application pool (destroying every `TLF_App`).
/// 6. Unloads the IPC library.
///
/// # After shutdown
///
/// - Every `AppHnd` still alive becomes invalid.
/// - The framework may be re-initialised by calling the preparation
///   functions again (`LF_ResetPrepare`, `LF_PrepareService`,
///   `LF_PrepareClient`, `LF_PrepareDone`).
/// - The process-wide "started" flag is reset, so the next
///   `LF_PrepareDone` returns `1` again.
///
/// Safe to call multiple times.
pub type LfShutdownFn = unsafe extern "C" fn();

// ============================================================================
// Network events function pointer (1)
// ============================================================================

/// `LF_Set_Network_Event` — install or clear the process-global network
/// event callbacks.
///
/// # Parameters
///
/// - `on_connect`: The connect callback, or `None` to disable the
///   event.
/// - `on_disconnect`: The disconnect callback, or `None` to disable the
///   event.
///
/// # Replace semantics
///
/// This is a **replace** operation, not a patch. Calling it a second
/// time discards any previously installed callbacks, including those
/// whose corresponding argument is `None` in the new call.
///
/// # Scope
///
/// The callbacks are process-global. There is no per-client
/// registration.
///
/// # Lifetime of the callback pointers
///
/// The native library stores the raw function pointers. The caller must
/// keep the corresponding Rust function items alive for as long as they
/// are installed. Static functions and top-level `extern "C" fn`
/// items are naturally `'static` and need no extra handling; capturing
/// closures do and must be kept in a `Box` or a similar stable
/// allocation.
pub type LfSetNetworkEventFn = unsafe extern "C" fn(
    on_connect: Option<LfNetworkEventFunc>,
    on_disconnect: Option<LfNetworkEventFunc>,
);