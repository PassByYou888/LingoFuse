//! # LingoFuse Rust Binding
//!
//! A Rust binding for the [LingoFuse](https://github.com/PassByYou888/LingoFuse)
//! distributed RPC framework.
//!
//! ## Status
//!
//! | Stage | Layer | Status |
//! |:-----:|-------|:------:|
//! | 1 | C-ABI (`sys`) | ✅ complete |
//! | 2 | Safe wrappers (`error`, `data_handle`, `io`, ...) | 🚧 in progress |
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
//! - [`data_handle`]: RAII [`data_handle::DataHandle`] with byte, scalar,
//!   and NUL-framed string I/O.
//!
//! - [`io`]: The unified JSON / string / byte I/O layer for data
//!   handles. This is the **only** sanctioned path for moving structured
//!   data to and from a handle; it enforces the cross-language wire
//!   contract (compact UTF-8, no `\uXXXX` escapes, NUL framing).
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

#![deny(unsafe_op_in_unsafe_fn)]
#![warn(missing_docs)]
#![warn(clippy::all)]

pub mod app_handle;
pub mod data_handle;
pub mod error;
pub mod framework;
pub mod io;
pub mod network_events;
pub mod status;
pub mod sys;
