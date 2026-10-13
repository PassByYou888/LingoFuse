//! # LingoFuse Rust Binding
//!
//! A Rust binding for the [LingoFuse](https://github.com/PassByYou888/LingoFuse)
//! distributed RPC framework.
//!
//! ## Status
//!
//! | Stage | Layer                                              | Status       |
//! |:-----:|----------------------------------------------------|:------------:|
//! | 1     | C-ABI (`sys`)                                      | complete     |
//! | 2     | Safe wrappers (`error`, `data_handle`, `io`, ...)  | complete     |
//! | 3     | UID / options / P2P / async (`uid`, `options`, ...)| complete     |
//!
//! All 59 exported C-ABI symbols declared in `LingoFuse.h` are covered
//! by the crate's public surface.
//!
//! ## Layer overview
//!
//! - [`sys`]: Low-level, raw FFI. All functions are `unsafe` and there
//!   is no lifetime management. Use this layer only if you need direct
//!   access to the C ABI, or if you are building the higher-level
//!   wrappers.
//!
//! - [`error`]: The single error type and its `ErrorCode` category tag.
//!
//! - [`uid`]: The 32-byte P2P session identifier, as a `Copy` newtype
//!   with hex conversion and `Debug`/`Display`.
//!
//! - [`data_handle`]: RAII [`data_handle::DataHandle`] with byte, scalar,
//!   and NUL-framed string I/O. Also exposes the sender's P2P identity
//!   through `DataHandle::p2p_uid` / `DataHandle::p2p_name`, which read
//!   side data injected into the input handle of a callback.
//!
//! - [`io`]: The unified JSON / string / byte I/O layer for data
//!   handles. This is the **only** sanctioned path for moving structured
//!   data to and from a handle; it enforces the cross-language wire
//!   contract (compact UTF-8, no `\uXXXX` escapes, NUL framing).
//!
//! - [`app_handle`]: RAII [`app_handle::AppHandle`] for registering
//!   Call / Notify APIs on a named application.
//!
//! - [`p2p`]: Process-wide P2P API registration, independent of any
//!   application. Reachable through UID and P2PName addressing only.
//!
//! - [`framework`]: Process-wide operations: network preparation,
//!   synchronous invocation by App name, UID, or P2PName; health checks;
//!   and application name generation.
//!
//! - [`async_call`]: Modern asynchronous invocation with closures. Each
//!   addressing scheme has a callback-style entry point
//!   ([`async_call::call_async`] and friends) and a blocking-style one
//!   ([`async_call::call_async_wait`] and friends).
//!
//! - [`options`]: Typed getters and setters for the runtime options.
//!   The stringly-typed `framework::set_option` / `framework::get_option`
//!   are wrapped in `options::set_quiet`, `options::set_wait_connection_timeout`,
//!   and so on.
//!
//! - [`network_events`]: Process-global connect / disconnect handlers.
//!
//! - [`status`]: The status queue and its diagnostic accessors.
//!
//! ## Library loading
//!
//! The native LingoFuse shared library is loaded **at runtime**, not
//! linked at build time. The first call into [`sys`] triggers the load.
//! See [`sys::loader`] for the search order and the loading contract.
//!
//! The platform-specific file names are:
//!
//! | Platform        | File name             |
//! |-----------------|-----------------------|
//! | Windows 64-bit  | `LingoFuse64.dll`     |
//! | Windows 32-bit  | `LingoFuse32.dll`     |
//! | Linux / BSD     | `liblingofuse.so`     |
//! | macOS           | `liblingofuse.dylib`  |
//!
//! ## Quick start
//!
//! ```no_run
//! use lingofuse::data_handle::DataHandle;
//! use lingofuse::io;
//! use serde::{Deserialize, Serialize};
//!
//! #[derive(Serialize, Deserialize)]
//! struct Request { a: i32, b: i32 }
//!
//! #[derive(Serialize, Deserialize)]
//! struct Response { result: i32 }
//!
//! fn main() -> Result<(), lingofuse::error::Error> {
//!     let mut h = DataHandle::new("add")?;
//!     io::write_json(&mut h, &Request { a: 5, b: 7 })?;
//!     h.set_position(0)?;
//!     // ... call ...
//!     Ok(())
//! }
//! ```
//!
//! ## Address schemes
//!
//! Three addressing schemes are supported for both synchronous and
//! asynchronous invocation:
//!
//! | Scheme   | Key                          | Local-first? | Load-balanced? |
//! |----------|------------------------------|:------------:|:--------------:|
//! | App name | UTF-8 string                 |     yes      |       no       |
//! | UID      | 32-byte session identifier   |     yes      |       no       |
//! | P2PName  | UTF-8 group name             |      no      |      yes       |
//!
//! See [`framework`] and [`async_call`] for the exact function names.
//!
//! ## Thread safety
//!
//! All LingoFuse C-ABI functions are thread-safe. However, a single
//! `DataHandle` must not be written concurrently; the Rust borrow
//! checker enforces this through `&mut self` on every mutating method.
//!
//! ## Memory
//!
//! Two flavours of data handle exist in the native library:
//!
//! - **Auto-recycled** (`DataHandle::new`): idle handles are reclaimed
//!   after **10 minutes**, scanned every **5 seconds**.
//!
//! - **Permanent** (`DataHandle::create_permanent`): never
//!   auto-reclaimed; released synchronously on drop.
//!
//! Both kinds must be explicitly dropped. The auto-reclaimer is a safety
//! net, not a substitute for ownership.
//!
//! ## Async result ownership
//!
//! The asynchronous family (`LF_Async_Call` and its UID / P2PName
//! variants) hands the callback a **framework-owned** result handle that
//! is released the moment the callback returns. The safe wrapper in
//! [`async_call`] enforces this by delivering a **borrowed**
//! [`data_handle::DataHandle`] inside the closure, and by returning a
//! copied `Vec<u8>` from the blocking-style entry points. Do not call
//! `dispose` on a callback handle, and do not retain it past the
//! callback body.

#![deny(unsafe_op_in_unsafe_fn)]
#![warn(missing_docs)]
#![warn(clippy::all)]

pub mod app_handle;
pub mod async_call;
pub mod data_handle;
pub mod error;
pub mod framework;
pub mod io;
pub mod network_events;
pub mod options;
pub mod p2p;
pub mod status;
pub mod sys;
pub mod uid;