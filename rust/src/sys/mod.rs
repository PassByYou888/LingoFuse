//! Low-level FFI layer for the LingoFuse native library.
//!
//! This module is the **only** place in the crate where native code is
//! invoked. Every higher-level wrapper goes through the type
//! definitions and the function-pointer table declared here.
//!
//! ## Structure
//!
//! - [`bindings`]: Type definitions and function-pointer aliases for
//!   the 59 C-ABI exports. Pure declarations; no runtime state.
//!
//! - [`loader`]: Runtime loading of the platform-specific shared
//!   library (`LingoFuse64.dll` / `liblingofuse.so` /
//!   `liblingofuse.dylib`) and resolution of every exported symbol
//!   into [`loader::NativeLibrary`].
//!
//! ## Loading contract
//!
//! The native library is loaded **lazily**. The first call to
//! [`loader::get_library`] triggers the load and resolves every symbol.
//! A missing library or a missing symbol produces a
//! [`loader::LoadError`].
//!
//! Applications that want a clear startup failure should call
//! [`loader::load_library`] explicitly at program start:
//!
//! ```no_run
//! lingofuse::sys::load_library().expect("LingoFuse runtime not available");
//! ```
//!
//! ## Export count
//!
//! `LingoFuse.h` declares **59** exported `LF_*` functions across seven
//! groups:
//!
//! | Group                                    | Count |
//! |------------------------------------------|:-----:|
//! | Data handle operations                   |  12   |
//! | Application handle operations            |   5   |
//! | API registration, app-bound              |   3   |
//! | API registration, process-wide P2P       |   3   |
//! | Local execution                          |   2   |
//! | Network preparation                      |   5   |
//! | Remote invocation, app-name addressing   |   5   |
//! | Remote invocation, UID addressing        |   5   |
//! | Remote invocation, P2PName addressing    |   5   |
//! | Queries                                  |   7   |
//! | Options                                  |   2   |
//! | Status                                   |   3   |
//! | Network events                           |   1   |
//! | Shutdown                                 |   1   |
//! | **Total**                                | **59**|
//!
//! The corresponding function-pointer table is
//! [`loader::NativeLibrary`], whose fields are laid out in the same
//! order as the `RESOLVE` sequence in `LingoFuse.c`.
//!
//! ## Unsafe
//!
//! Every native function call is `unsafe`. The caller must respect the
//! contracts documented in the individual function-pointer types; in
//! particular:
//!
//! - The library must be loaded before any function pointer is called.
//! - Handles must be freed with the corresponding free function.
//! - Callbacks must follow the `extern "C"` calling convention and
//!   must not unwind.
//! - A callback must not call any blocking LingoFuse function
//!   (`LF_Call`, `LF_LocalCall`, `LF_PrepareDone`, `LF_Shutdown`); doing
//!   so deadlocks.
//!
//! The higher-level safe wrappers enforce these invariants.

pub mod bindings;
pub mod loader;

// ---------------------------------------------------------------------------
// Raw handle types, the UID value type, and callback prototypes
// ---------------------------------------------------------------------------
//
// Re-exported here so that a higher-level wrapper only needs
// `use lingofuse::sys::{AppHnd, DataHnd, LfP2PUid, ...}` instead of
// reaching into `bindings` directly.

pub use bindings::{
    AppHnd,
    DataHnd,
    LfAsyncCallOnResult,
    LfCallFunc,
    LfNetworkEventFunc,
    LfNotifyFunc,
    LfP2PUid,
};

// ---------------------------------------------------------------------------
// Loader surface
// ---------------------------------------------------------------------------

pub use loader::{
    get_library,
    is_loaded,
    load_library,
    LoadError,
    NativeLibrary,
};