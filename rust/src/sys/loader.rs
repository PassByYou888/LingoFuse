//! Runtime loading of the LingoFuse native shared library.
//!
//! This module locates, loads, and resolves the platform-specific
//! LingoFuse shared library, exposing every one of the 37 C-ABI exports
//! as a typed function pointer in [`NativeLibrary`].
//!
//! ## Loading model
//!
//! The library is loaded **lazily** through a process-wide [`OnceLock`].
//! The first successful call to [`get_library`] (or [`load_library`])
//! performs the load and resolves every symbol; later calls return the
//! cached instance.
//!
//! If loading fails, the error is cached as well. There is no automatic
//! retry: if you install the native library after the first failed
//! attempt, you must restart the process. This matches the C++ and
//! JavaScript bindings and avoids a class of subtle races where a
//! partially-initialised library would be reused.
//!
//! ## Library lifetime
//!
//! The underlying [`libloading::Library`] is intentionally **leaked**
//! (`Box::leak`). The function pointers resolved from it are only valid
//! while the library is loaded, so leaking is the simplest correct way
//! to give them a `'static` lifetime. Process exit is the only point at
//! which the native library is unloaded. This is exactly what the C++,
//! C#, Python, and JavaScript bindings do.
//!
//! The native library's own lifecycle is managed by the framework:
//! `LF_Shutdown` resets the internal state without unloading the shared
//! object. Do not attempt to `dlclose` / `FreeLibrary` the native
//! library from Rust.
//!
//! ## Search order
//!
//! The loader tries, in order:
//!
//! 1. Each candidate path returned by [`build_search_paths`]:
//!    1. The directory containing the current executable.
//!    2. The current working directory.
//! 2. The bare platform file name, letting the operating system loader
//!    resolve it against its own search path (`PATH` on Windows,
//!    `LD_LIBRARY_PATH` on Linux, `DYLD_LIBRARY_PATH` on macOS).
//!
//! Every failed candidate is recorded and included in the error message
//! of [`LoadError::LibraryNotFound`].
//!
//! ## Threading
//!
//! [`NativeLibrary`] is `Send` and `Sync`. The `OnceLock` guarantees
//! that the load runs exactly once, even under concurrent first use.
//! The native functions themselves are documented as thread-safe; only
//! a single data handle's write path requires external serialisation.

use std::error::Error;
use std::fmt;
use std::path::PathBuf;
use std::sync::OnceLock;

use libloading::{Library, Symbol};

use super::bindings::{
    LfBindAppFn, LfCallFn, LfCheckApiFn, LfCheckAppFn,
    LfCheckMainThreadFn, LfCreateAppFn, LfCreateDataFn,
    LfCreateDataPermanentFn, LfExitMainThreadFn, LfFreeAppFn, LfFreeDataFn,
    LfGenerateAppNameFn, LfGetAppNameFn, LfGetBufferFn, LfGetPosFn,
    LfGetSizeFn, LfGetStatusCountFn, LfGetStatusFn, LfLocalCallFn,
    LfLocalNotifyFn, LfNotifyFn, LfPostStatusFn, LfPrepareClientFn,
    LfPrepareDoneFn, LfPrepareServiceFn, LfReadBufferFn, LfRegisterCallFn,
    LfRegisterNotifyFn, LfResetPrepareFn, LfSequencedNotifyFn,
    LfSetNetworkEventFn, LfSetOptionFn, LfSetPosFn, LfSetSizeFn,
    LfShutdownFn, LfUnregisterFn, LfWriteBufferFn,
};

// ============================================================================
// LoadError
// ============================================================================

/// Errors that can occur while loading the native library or resolving
/// a required symbol.
#[derive(Debug)]
pub enum LoadError {
    /// The platform-specific shared library could not be located.
    ///
    /// `attempted` lists every file-system path that was tried before
    /// the OS loader was asked to resolve the bare file name.
    /// `last_error` carries the message from the most recent failed
    /// attempt (the OS loader's own diagnostic, when available).
    LibraryNotFound {
        /// Every path that was attempted, in order.
        attempted: Vec<PathBuf>,
        /// The message from the most recent load failure, if any.
        last_error: Option<String>,
    },

    /// The library was loaded, but a required exported symbol is
    /// missing. This typically indicates a version mismatch between the
    /// Rust binding and the installed native library, or an incorrectly
    /// built native library.
    SymbolMissing {
        /// The missing symbol's C name, without the trailing NUL.
        symbol: &'static str,
        /// The underlying `libloading` error.
        source: libloading::Error,
    },

    /// The current platform is not supported by LingoFuse.
    ///
    /// The crate recognises Windows (32- and 64-bit), macOS, and any
    /// other Unix. If the compile target falls outside that set,
    /// [`select_platform_file_name`] returns an empty string and this
    /// error is produced.
    PlatformUnsupported {
        /// `std::env::consts::OS` value for the current target.
        os: String,
        /// `std::env::consts::ARCH` value for the current target.
        arch: String,
    },
}

impl fmt::Display for LoadError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            LoadError::LibraryNotFound {
                attempted,
                last_error,
            } => {
                write!(f, "failed to load the LingoFuse native library")?;
                if !attempted.is_empty() {
                    write!(f, "; tried:")?;
                    for p in attempted {
                        write!(f, "\n  - {}", p.display())?;
                    }
                }
                write!(
                    f,
                    "\nplace the platform library next to the executable, \
                     in the current working directory, or on the system \
                     loader search path"
                )?;
                if let Some(e) = last_error {
                    write!(f, "\nlast error: {}", e)?;
                }
                Ok(())
            }
            LoadError::SymbolMissing { symbol, source } => write!(
                f,
                "the native library is missing the required symbol \
                 '{}' (version mismatch?): {}",
                symbol, source
            ),
            LoadError::PlatformUnsupported { os, arch } => write!(
                f,
                "the platform '{}' / '{}' is not supported by LingoFuse",
                os, arch
            ),
        }
    }
}

impl Error for LoadError {
    fn source(&self) -> Option<&(dyn Error + 'static)> {
        match self {
            LoadError::SymbolMissing { source, .. } => Some(source),
            _ => None,
        }
    }
}

// ============================================================================
// NativeLibrary
// ============================================================================

/// A fully resolved set of LingoFuse C-ABI function pointers.
///
/// Every field is a function pointer with the same signature as the
/// corresponding C export. Field names use Rust's `snake_case`
/// convention; the mapping to the C names is one-to-one and is
/// documented on each field.
///
/// ## Construction
///
/// Do not construct this type manually. Obtain a reference through
/// [`get_library`] or [`load_library`]. The `OnceLock` that owns the
/// instance guarantees that the load runs exactly once per process.
///
/// ## Threading
///
/// `NativeLibrary` is `Send + Sync`. The function pointers are `Copy`
/// and immutable, so concurrent access is safe without synchronisation.
///
/// ## Lifetime
///
/// The instance is a `'static` singleton. It is never dropped; the
/// underlying shared object is unloaded only when the process exits.
pub struct NativeLibrary {
    // --- Data handle operations (10) ---

    /// `LF_CreateData` — create a new auto-recycled data handle.
    pub lf_create_data: LfCreateDataFn,

    /// `LF_CreateData_Permanent` — create a new permanent data handle.
    pub lf_create_data_permanent: LfCreateDataPermanentFn,

    /// `LF_FreeData` — release a data handle.
    pub lf_free_data: LfFreeDataFn,

    /// `LF_GetBuffer` — raw pointer to the handle's buffer.
    pub lf_get_buffer: LfGetBufferFn,

    /// `LF_WriteBuffer` — write bytes at the current cursor.
    pub lf_write_buffer: LfWriteBufferFn,

    /// `LF_ReadBuffer` — read bytes at the current cursor.
    pub lf_read_buffer: LfReadBufferFn,

    /// `LF_GetPos` — current read/write cursor.
    pub lf_get_pos: LfGetPosFn,

    /// `LF_SetPos` — set the read/write cursor.
    pub lf_set_pos: LfSetPosFn,

    /// `LF_GetSize` — total buffer size in bytes.
    pub lf_get_size: LfGetSizeFn,

    /// `LF_SetSize` — resize the buffer.
    pub lf_set_size: LfSetSizeFn,

    // --- Application handle operations (5) ---

    /// `LF_CreateApp` — create a new application.
    pub lf_create_app: LfCreateAppFn,

    /// `LF_FreeApp` — detach an application (stage one of two).
    pub lf_free_app: LfFreeAppFn,

    /// `LF_Generate_AppName` — unique name (5 s pointer validity).
    pub lf_generate_app_name: LfGenerateAppNameFn,

    /// `LF_Get_AppName` — name of an existing handle (5 s validity).
    pub lf_get_app_name: LfGetAppNameFn,

    /// `LF_BindApp` — bind an application to unbound clients.
    pub lf_bind_app: LfBindAppFn,

    // --- API registration (3) ---

    /// `LF_RegisterCall` — register a Call (request-response) API.
    pub lf_register_call: LfRegisterCallFn,

    /// `LF_RegisterNotify` — register a Notify (one-way) API.
    pub lf_register_notify: LfRegisterNotifyFn,

    /// `LF_Unregister` — remove a registered API.
    pub lf_unregister: LfUnregisterFn,

    // --- Local execution (2) ---

    /// `LF_LocalCall` — in-process Call, no network hop.
    pub lf_local_call: LfLocalCallFn,

    /// `LF_LocalNotify` — in-process Notify, no network hop.
    pub lf_local_notify: LfLocalNotifyFn,

    // --- Network preparation (5) ---

    /// `LF_ResetPrepare` — clear the preparation queue.
    pub lf_reset_prepare: LfResetPrepareFn,

    /// `LF_PrepareService` — prepare a listening C4 service.
    pub lf_prepare_service: LfPrepareServiceFn,

    /// `LF_PrepareClient` — prepare a C4 client connection.
    pub lf_prepare_client: LfPrepareClientFn,

    /// `LF_PrepareDone` — start the framework (returns 1 only once).
    pub lf_prepare_done: LfPrepareDoneFn,

    /// `LF_ExitMainThread` — request the simulated main thread to exit.
    /// Also flushes the data-handle pool.
    pub lf_exit_main_thread: LfExitMainThreadFn,

    // --- Remote invocation (3) ---

    /// `LF_Call` — synchronous remote call. Never returns a null
    /// handle; on timeout it returns a size-0 handle.
    pub lf_call: LfCallFn,

    /// `LF_Notify` — best-effort one-way notification.
    pub lf_notify: LfNotifyFn,

    /// `LF_Sequenced_Notify` — FIFO-ordered one-way notification.
    pub lf_sequenced_notify: LfSequencedNotifyFn,

    // --- Options and diagnostics (7) ---

    /// `LF_SetOption` — adjust a global runtime option.
    pub lf_set_option: LfSetOptionFn,

    /// `LF_GetStatusCount` — pending log-message count.
    pub lf_get_status_count: LfGetStatusCountFn,

    /// `LF_GetStatus` — retrieve the next log message (static buffer).
    pub lf_get_status: LfGetStatusFn,

    /// `LF_PostStatus` — inject a log message.
    pub lf_post_status: LfPostStatusFn,

    /// `LF_CheckMainThread` — is the simulated main thread running?
    pub lf_check_main_thread: LfCheckMainThreadFn,

    /// `LF_CheckApp` — is the named app visible on the mesh?
    pub lf_check_app: LfCheckAppFn,

    /// `LF_CheckApi` — is the named API visible on the mesh?
    pub lf_check_api: LfCheckApiFn,

    // --- Shutdown (1) ---

    /// `LF_Shutdown` — full shutdown and resource release.
    pub lf_shutdown: LfShutdownFn,

    // --- Network events (1) ---

    /// `LF_Set_Network_Event` — install/replace network event callbacks.
    pub lf_set_network_event: LfSetNetworkEventFn,
}

// The function pointers are plain `Copy` values (they are `extern "C"`
// function items). The only non-trivial concern would be a shared
// mutable state inside the native library, but the native library
// itself is documented as thread-safe. Therefore `Send` and `Sync` are
// safe to implement explicitly.
//
// SAFETY: The struct contains only function pointers and no interior
// mutability. Every field type is `Copy + Send + Sync`. The native
// library is documented as fully thread-safe.
unsafe impl Send for NativeLibrary {}
unsafe impl Sync for NativeLibrary {}

impl fmt::Debug for NativeLibrary {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        // Deliberately do not print the function pointer values: they
        // are ASLR-dependent and add no diagnostic value.
        f.debug_struct("NativeLibrary")
            .field("exports", &37usize)
            .finish_non_exhaustive()
    }
}

// ============================================================================
// Platform detection
// ============================================================================

/// Returns the platform-specific shared library file name.
///
/// The mapping matches the C++, C#, Python, and JavaScript bindings:
///
/// | Target                          | File name            |
/// |---------------------------------|----------------------|
/// | `windows` + 64-bit              | `LingoFuse64.dll`    |
/// | `windows` + 32-bit              | `LingoFuse32.dll`    |
/// | `macos`                         | `liblingofuse.dylib` |
/// | other `unix` (Linux, *BSD, ...) | `liblingofuse.so`    |
/// | anything else                   | `""`                 |
///
/// An empty return value indicates an unsupported target. Callers must
/// treat that as an error (see [`LoadError::PlatformUnsupported`]).
pub fn select_platform_file_name() -> &'static str {
    if cfg!(all(target_os = "windows", target_pointer_width = "64")) {
        "LingoFuse64.dll"
    } else if cfg!(all(target_os = "windows", target_pointer_width = "32")) {
        "LingoFuse32.dll"
    } else if cfg!(target_os = "macos") {
        "liblingofuse.dylib"
    } else if cfg!(unix) {
        "liblingofuse.so"
    } else {
        ""
    }
}

/// Returns the list of file-system paths the loader should try before
/// falling back to the operating system's own loader search path.
///
/// The current order is:
///
/// 1. The directory containing the current executable.
/// 2. The current working directory.
///
/// Both are evaluated at call time; a missing or inaccessible directory
/// is silently skipped. The returned paths are absolute where possible
/// and always include the platform file name as their final component.
pub fn build_search_paths(file_name: &str) -> Vec<PathBuf> {
    let mut paths = Vec::with_capacity(2);

    if let Ok(exe) = std::env::current_exe() {
        if let Some(dir) = exe.parent() {
            paths.push(dir.join(file_name));
        }
    }

    if let Ok(cwd) = std::env::current_dir() {
        paths.push(cwd.join(file_name));
    }

    paths
}

// ============================================================================
// Raw loading
// ============================================================================

/// Loads the shared library, trying every file-system candidate first
/// and the OS loader search path last.
///
/// This function performs no symbol resolution. It returns a
/// [`Library`] whose handle the caller is expected to keep alive for
/// as long as the resolved symbols are in use.
///
/// When every explicit candidate fails, the diagnostic from the final
/// OS-loader attempt is preserved and returned to the caller. The
/// diagnostics from the earlier explicit-path attempts are not kept:
/// in practice they are all "file not found", and the `attempted` list
/// already records every path that was tried.
fn load_raw(file_name: &str) -> Result<Library, LoadError> {
    if file_name.is_empty() {
        return Err(LoadError::PlatformUnsupported {
            os: std::env::consts::OS.to_string(),
            arch: std::env::consts::ARCH.to_string(),
        });
    }

    let mut attempted: Vec<PathBuf> = Vec::new();

    // 1. Try every explicit path. Record each failure so that the
    //    final error can list them.
    for path in build_search_paths(file_name) {
        // SAFETY: We assume the caller has not loaded the same library
        // through an incompatible mechanism. Loading is done exactly
        // once by `load_native`, guarded by a `OnceLock`.
        match unsafe { Library::new(&path) } {
            Ok(lib) => return Ok(lib),
            Err(_) => attempted.push(path),
        }
    }

    // 2. Fall back to the OS loader search path with the bare name.
    // SAFETY: same as above.
    match unsafe { Library::new(file_name) } {
        Ok(lib) => Ok(lib),
        Err(e) => Err(LoadError::LibraryNotFound {
            attempted,
            last_error: Some(e.to_string()),
        }),
    }
}

// ============================================================================
// Symbol resolution
// ============================================================================

/// Resolves one exported symbol into a typed function pointer.
///
/// The caller supplies the C name as a string literal (without the
/// trailing NUL); the macro appends the NUL internally, which is what
/// `libloading` requires.
///
/// # Safety
///
/// The caller must be certain that:
///
/// - `$lib` was loaded successfully and will remain loaded for at
///   least as long as the returned pointer is used;
/// - the C symbol has exactly the signature of `$ty`. A mismatch
///   between the C prototype and the Rust typedef is undefined
///   behaviour at every subsequent call site.
///
/// The macro is only used inside [`load_native`], where both conditions
/// hold by construction: the library has just been loaded and leaked,
/// and every `$ty` is a function-pointer typedef from
/// [`super::bindings`] that mirrors `LingoFuse.h` one-for-one.
macro_rules! resolve {
    ($lib:expr, $c_name:literal, $ty:ty) => {{
        // SAFETY: forwarded from the macro's caller. The symbol name is
        // NUL-terminated via `concat!`.
        let symbol: Symbol<$ty> =
            unsafe { $lib.get(concat!($c_name, "\0").as_bytes()) }
                .map_err(|e| LoadError::SymbolMissing {
                    symbol: $c_name,
                    source: e,
                })?;
        // `Symbol<T>` implements `Deref<Target = T>`; dereferencing is
        // safe. All `extern "C" fn` types are `Copy`.
        *symbol
    }};
}

// ============================================================================
// Public loading entry points
// ============================================================================

/// The process-wide singleton. `Ok` holds the resolved function
/// pointer table; `Err` holds the diagnostic from the failed load.
///
/// A failed load is cached on purpose: installing the native library
/// after a failed attempt is not supported and requires a process
/// restart. This avoids a class of races where a partially initialised
/// library could be reused.
static INSTANCE: OnceLock<Result<NativeLibrary, LoadError>> = OnceLock::new();

/// Performs the load and symbol resolution.
///
/// This function leaks the underlying [`Library`] so that the function
/// pointers resolved from it acquire a `'static` lifetime. The native
/// library is therefore loaded for the entire process lifetime, exactly
/// as the C++, C#, Python, and JavaScript bindings do.
fn load_native() -> Result<NativeLibrary, LoadError> {
    let file_name = select_platform_file_name();
    let lib: &'static Library = Box::leak(Box::new(load_raw(file_name)?));

    // Each `resolve!` expands to a local `unsafe { lib.get(...) }` plus
    // a safe dereference, so no outer `unsafe` block is needed here.
    // The safety argument is captured in the macro's own doc comment.
    let native = NativeLibrary {
        // --- Data handle operations (10) ---
        lf_create_data: resolve!(lib, "LF_CreateData", LfCreateDataFn),
        lf_create_data_permanent: resolve!(
            lib,
            "LF_CreateData_Permanent",
            LfCreateDataPermanentFn
        ),
        lf_free_data: resolve!(lib, "LF_FreeData", LfFreeDataFn),
        lf_get_buffer: resolve!(lib, "LF_GetBuffer", LfGetBufferFn),
        lf_write_buffer: resolve!(lib, "LF_WriteBuffer", LfWriteBufferFn),
        lf_read_buffer: resolve!(lib, "LF_ReadBuffer", LfReadBufferFn),
        lf_get_pos: resolve!(lib, "LF_GetPos", LfGetPosFn),
        lf_set_pos: resolve!(lib, "LF_SetPos", LfSetPosFn),
        lf_get_size: resolve!(lib, "LF_GetSize", LfGetSizeFn),
        lf_set_size: resolve!(lib, "LF_SetSize", LfSetSizeFn),

        // --- Application handle operations (5) ---
        lf_create_app: resolve!(lib, "LF_CreateApp", LfCreateAppFn),
        lf_free_app: resolve!(lib, "LF_FreeApp", LfFreeAppFn),
        lf_generate_app_name: resolve!(
            lib,
            "LF_Generate_AppName",
            LfGenerateAppNameFn
        ),
        lf_get_app_name: resolve!(lib, "LF_Get_AppName", LfGetAppNameFn),
        lf_bind_app: resolve!(lib, "LF_BindApp", LfBindAppFn),

        // --- API registration (3) ---
        lf_register_call: resolve!(
            lib,
            "LF_RegisterCall",
            LfRegisterCallFn
        ),
        lf_register_notify: resolve!(
            lib,
            "LF_RegisterNotify",
            LfRegisterNotifyFn
        ),
        lf_unregister: resolve!(lib, "LF_Unregister", LfUnregisterFn),

        // --- Local execution (2) ---
        lf_local_call: resolve!(lib, "LF_LocalCall", LfLocalCallFn),
        lf_local_notify: resolve!(lib, "LF_LocalNotify", LfLocalNotifyFn),

        // --- Network preparation (5) ---
        lf_reset_prepare: resolve!(
            lib,
            "LF_ResetPrepare",
            LfResetPrepareFn
        ),
        lf_prepare_service: resolve!(
            lib,
            "LF_PrepareService",
            LfPrepareServiceFn
        ),
        lf_prepare_client: resolve!(
            lib,
            "LF_PrepareClient",
            LfPrepareClientFn
        ),
        lf_prepare_done: resolve!(lib, "LF_PrepareDone", LfPrepareDoneFn),
        lf_exit_main_thread: resolve!(
            lib,
            "LF_ExitMainThread",
            LfExitMainThreadFn
        ),

        // --- Remote invocation (3) ---
        lf_call: resolve!(lib, "LF_Call", LfCallFn),
        lf_notify: resolve!(lib, "LF_Notify", LfNotifyFn),
        lf_sequenced_notify: resolve!(
            lib,
            "LF_Sequenced_Notify",
            LfSequencedNotifyFn
        ),

        // --- Options and diagnostics (7) ---
        lf_set_option: resolve!(lib, "LF_SetOption", LfSetOptionFn),
        lf_get_status_count: resolve!(
            lib,
            "LF_GetStatusCount",
            LfGetStatusCountFn
        ),
        lf_get_status: resolve!(lib, "LF_GetStatus", LfGetStatusFn),
        lf_post_status: resolve!(lib, "LF_PostStatus", LfPostStatusFn),
        lf_check_main_thread: resolve!(
            lib,
            "LF_CheckMainThread",
            LfCheckMainThreadFn
        ),
        lf_check_app: resolve!(lib, "LF_CheckApp", LfCheckAppFn),
        lf_check_api: resolve!(lib, "LF_CheckApi", LfCheckApiFn),

        // --- Shutdown (1) ---
        lf_shutdown: resolve!(lib, "LF_Shutdown", LfShutdownFn),

        // --- Network events (1) ---
        lf_set_network_event: resolve!(
            lib,
            "LF_Set_Network_Event",
            LfSetNetworkEventFn
        ),
    };

    Ok(native)
}

// ============================================================================
// Public API
// ============================================================================

/// Returns the process-wide [`NativeLibrary`] singleton, loading it on
/// first call.
///
/// # Errors
///
/// - [`LoadError::LibraryNotFound`] if no candidate path yielded a
///   loadable library and the OS loader could not resolve the bare
///   file name.
/// - [`LoadError::SymbolMissing`] if the library loaded but a required
///   export is absent. This almost always means the installed native
///   library is older or newer than this binding expects.
/// - [`LoadError::PlatformUnsupported`] on a target that LingoFuse does
///   not support.
///
/// The error is cached; a second call returns the same error. Installing
/// the library after a failed attempt requires a process restart.
///
/// # Example
///
/// ```no_run
/// let lib = lingofuse::sys::get_library()
///     .expect("LingoFuse runtime not available");
/// // lib.lf_create_data, lib.lf_call, ... are now usable.
/// ```
pub fn get_library() -> Result<&'static NativeLibrary, &'static LoadError> {
    INSTANCE.get_or_init(load_native).as_ref()
}

/// Eagerly loads the native library.
///
/// This is a convenience wrapper around [`get_library`] with the same
/// behaviour and the same error set. Use it at the very start of a
/// program when you want a missing runtime to fail fast, rather than
/// at the first unrelated call site.
///
/// # Example
///
/// ```no_run
/// fn main() -> Result<(), Box<dyn std::error::Error>> {
///     lingofuse::sys::load_library()?;
///     // ... rest of the program ...
///     Ok(())
/// }
/// ```
pub fn load_library() -> Result<&'static NativeLibrary, &'static LoadError> {
    get_library()
}

/// Returns `true` when the native library is currently loaded and
/// usable.
///
/// This is `false` both before the first load attempt and after a
/// failed attempt. It never triggers a load itself.
pub fn is_loaded() -> bool {
    matches!(INSTANCE.get(), Some(Ok(_)))
}

// ============================================================================
// Tests
// ============================================================================

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn platform_file_name_is_non_empty_on_supported_targets() {
        // The crate supports Windows (32/64), macOS, and Unix. On any
        // of those, the name must not be empty.
        let name = select_platform_file_name();
        if cfg!(any(target_os = "windows", target_os = "macos", unix)) {
            assert!(
                !name.is_empty(),
                "platform file name must be non-empty on a supported target"
            );
            // Every candidate must end with the platform file name.
            for p in build_search_paths(name) {
                let last = p.file_name().and_then(|s| s.to_str());
                assert_eq!(last, Some(name));
            }
        }
    }

    #[test]
    fn is_loaded_reflects_singleton_state() {
        // Before any load attempt the singleton is empty, so
        // `is_loaded` must be `false`.
        if INSTANCE.get().is_none() {
            assert!(!is_loaded());
        }
        // Once a load has been attempted, `is_loaded` mirrors the
        // cached result. This test only asserts the invariant; it does
        // not force a load, because the native library may not be
        // present in the test environment.
        if let Some(res) = INSTANCE.get() {
            assert_eq!(is_loaded(), res.is_ok());
        }
    }
}