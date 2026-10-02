//! Low-level FFI layer for the LingoFuse native library.
//!
//! This module is the **only** place in the crate where native code is
//! invoked. Every higher-level wrapper goes through the type
//! definitions and the function-pointer table declared here.
//!
//! ## Structure
//!
//! - [`bindings`]: Type definitions and function-pointer aliases for
//!   the 37 C-ABI exports. Pure declarations; no runtime state.
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
//! The Stage 2 safe wrappers enforce these invariants.

pub mod bindings;
pub mod loader;

// Re-export the raw handle types and callback prototypes so that a
// Stage 2 wrapper only needs `use lingofuse::sys::{DataHnd, AppHnd, ...}`.
pub use bindings::{
    AppHnd, DataHnd, LfCallFunc, LfNetworkEventFunc, LfNotifyFunc,
};

// Re-export the loader surface.
pub use loader::{
    get_library, is_loaded, load_library, LoadError, NativeLibrary,
};