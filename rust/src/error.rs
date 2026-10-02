//! Structured exception hierarchy for the LingoFuse Rust binding.
//!
//! Every failure raised by the safe wrappers is an [`Error`] carrying an
//! [`ErrorCode`]. Application code can catch a single type and dispatch
//! on the code, mirroring the C++ `lingofuse::Error` /
//! `lingofuse::ErrorCode` design and the C# `LingoFuseException`
//! hierarchy.
//!
//! ## Layers
//!
//! | Code                     | Where it originates |
//! |--------------------------|---------------------|
//! | `LibraryLoadFailed`      | [`crate::sys::loader`] |
//! | `NullHandle`             | A handle operation on a null/disposed handle |
//! | `InvalidArgument`        | Caller-side argument validation |
//! | `WriteFailed`            | A short write into a data handle |
//! | `ReadFailed`             | A short read from a data handle |
//! | `CallFailed`             | A remote call that returned a null handle |
//! | `RegistrationFailed`     | `register_call` / `register_notify` rejected |
//! | `NotConnected`           | An operation that requires a running framework |
//! | `Timeout`                | A remote call that timed out (rarely used; see note) |
//! | `Generic`                | Anything else |
//!
//! ## Timeout and the C ABI
//!
//! The C ABI does **not** report a remote-call timeout as an error. It
//! returns a size-0 handle. The Stage 2 `framework::call` helper
//! therefore returns `Err(Error::timeout(...))` when the returned
//! handle is empty, so that the caller sees a clean failure. Callers
//! that need to distinguish "timeout" from "empty response" should use
//! the raw `try_call`-style helper instead.
//!
//! ## Source chain
//!
//! Where a lower-level error exists (most notably
//! [`crate::sys::LoadError`]), it is attached as the
//! [`std::error::Error::source`] of the [`Error`]. This lets a caller
//! walk the chain with `error.source()` or with the `anyhow` / `eyre`
//! ecosystem without extra work.

use std::error::Error as StdError;
use std::fmt;

use crate::sys::LoadError;

// ============================================================================
// ErrorCode
// ============================================================================

/// A category tag for an [`Error`].
///
/// The set is deliberately closed: new failure modes are added here,
/// not invented at the call site.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum ErrorCode {
    /// Unclassified error.
    Generic,

    /// The native LingoFuse shared library could not be loaded, or a
    /// required symbol was missing. See [`crate::sys::LoadError`] for
    /// the underlying diagnostic.
    LibraryLoadFailed,

    /// An operation was attempted on a null or already-disposed handle.
    NullHandle,

    /// A caller-side argument failed validation (for example a
    /// non-positive timeout, a name containing an interior NUL, etc.).
    InvalidArgument,

    /// A write into a data handle wrote fewer bytes than requested.
    /// The handle is likely corrupt or the process is out of memory;
    /// there is no useful recovery path.
    WriteFailed,

    /// A read from a data handle returned fewer bytes than requested.
    /// This is the exact-read failure mode; partial reads use the
    /// non-throwing `try_read_*` family.
    ReadFailed,

    /// A remote call returned a null handle. The C ABI documents this
    /// as never happening for `LF_Call`; a null here means a deeper
    /// transport failure.
    CallFailed,

    /// `register_call` / `register_notify` was rejected by the native
    /// layer. Almost always a duplicate API name.
    RegistrationFailed,

    /// An operation requires the framework to be running (the
    /// simulated main thread to be active) but it is not.
    NotConnected,

    /// A remote call timed out. Note that the C ABI does **not**
    /// produce this code directly; see the module documentation.
    Timeout,
}

impl fmt::Display for ErrorCode {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        let s = match self {
            ErrorCode::Generic => "generic error",
            ErrorCode::LibraryLoadFailed => "library load failed",
            ErrorCode::NullHandle => "null handle",
            ErrorCode::InvalidArgument => "invalid argument",
            ErrorCode::WriteFailed => "write failed",
            ErrorCode::ReadFailed => "read failed",
            ErrorCode::CallFailed => "call failed",
            ErrorCode::RegistrationFailed => "registration failed",
            ErrorCode::NotConnected => "not connected",
            ErrorCode::Timeout => "timeout",
        };
        f.write_str(s)
    }
}

// ============================================================================
// Error
// ============================================================================

/// The single error type produced by the safe wrappers.
///
/// # Example
///
/// ```no_run
/// use lingofuse::error::ErrorCode;
///
/// match do_something() {
///     Ok(()) => {}
///     Err(e) if e.code() == ErrorCode::Timeout => { /* retry */ }
///     Err(e) => eprintln!("fatal: {}", e),
/// }
/// # fn do_something() -> Result<(), lingofuse::error::Error> { Ok(()) }
/// ```
pub struct Error {
    code: ErrorCode,
    message: String,
    source: Option<Box<dyn StdError + Send + Sync + 'static>>,
}

impl Error {
    /// Builds a new error with the given code and message.
    pub fn new(code: ErrorCode, message: impl Into<String>) -> Self {
        Error {
            code,
            message: message.into(),
            source: None,
        }
    }

    /// Builds a new error with the given code, message, and source.
    ///
    /// The source is preserved for the [`std::error::Error::source`]
    /// chain and can be downcast by callers that need the original
    /// failure.
    pub fn with_source(
        code: ErrorCode,
        message: impl Into<String>,
        source: impl StdError + Send + Sync + 'static,
    ) -> Self {
        Error {
            code,
            message: message.into(),
            source: Some(Box::new(source)),
        }
    }

    /// Returns the category tag.
    pub fn code(&self) -> ErrorCode {
        self.code
    }

    /// Returns the human-readable message.
    ///
    /// This never includes the source chain; use
    /// [`std::error::Error::source`] to walk it.
    pub fn message(&self) -> &str {
        &self.message
    }

    // -----------------------------------------------------------------
    // Convenience constructors used by the rest of the crate.
    //
    // Some of them are reserved for later Stage 2 batches and are not
    // yet referenced from any call site. They carry `#[allow(dead_code)]`
    // so that the crate can keep a zero-warning policy while the code
    // matures; the doc comment on each records its intended consumer.
    // -----------------------------------------------------------------

    pub(crate) fn null_handle(op: &str) -> Self {
        Error::new(
            ErrorCode::NullHandle,
            format!("{}: handle is null or already disposed", op),
        )
    }

    pub(crate) fn invalid_argument(op: &str, detail: impl fmt::Display) -> Self {
        Error::new(
            ErrorCode::InvalidArgument,
            format!("{}: {}", op, detail),
        )
    }

    pub(crate) fn write_failed(op: &str, expected: usize, actual: i64) -> Self {
        Error::new(
            ErrorCode::WriteFailed,
            format!(
                "{}: requested {} bytes, wrote {}",
                op, expected, actual
            ),
        )
    }

    pub(crate) fn read_failed(op: &str, expected: usize, actual: usize) -> Self {
        Error::new(
            ErrorCode::ReadFailed,
            format!(
                "{}: requested {} bytes, only {} available",
                op, expected, actual
            ),
        )
    }

    /// Reserved for Stage 2 batch 3 (`app_handle.rs`) and batch 4
    /// (`framework.rs`). Not yet wired up.
    #[allow(dead_code)]
    pub(crate) fn call_failed(op: &str, detail: impl fmt::Display) -> Self {
        Error::new(
            ErrorCode::CallFailed,
            format!("{}: {}", op, detail),
        )
    }

    /// Reserved for Stage 2 batch 3 (`app_handle.rs`).
    #[allow(dead_code)]
    pub(crate) fn registration_failed(op: &str, name: &str) -> Self {
        Error::new(
            ErrorCode::RegistrationFailed,
            format!(
                "{}: '{}' is already registered or otherwise rejected",
                op, name
            ),
        )
    }

    /// Reserved for Stage 2 batch 4 (`framework.rs`).
    #[allow(dead_code)]
    pub(crate) fn not_connected(op: &str) -> Self {
        Error::new(
            ErrorCode::NotConnected,
            format!("{}: the framework is not running", op),
        )
    }

    /// Reserved for Stage 2 batch 4 (`framework.rs`).
    #[allow(dead_code)]
    pub(crate) fn timeout(op: &str, app: &str) -> Self {
        Error::new(
            ErrorCode::Timeout,
            format!(
                "{}: call to app '{}' timed out or reached an unreachable target",
                op, app
            ),
        )
    }

    /// Wraps a [`LoadError`] as an [`Error`] with `LibraryLoadFailed`.
    pub(crate) fn from_load(err: &'static LoadError) -> Self {
        Error {
            code: ErrorCode::LibraryLoadFailed,
            message: err.to_string(),
            // The load error is `'static`; boxing a reference to it
            // preserves the source chain without cloning.
            source: Some(Box::new(LoadErrorRef(err))),
        }
    }
}

/// A `'static` reference to a [`LoadError`], used to satisfy the
/// `Box<dyn Error + Send + Sync>` source requirement without cloning.
#[derive(Debug)]
struct LoadErrorRef(&'static LoadError);

impl fmt::Display for LoadErrorRef {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        fmt::Display::fmt(self.0, f)
    }
}

impl StdError for LoadErrorRef {
    fn source(&self) -> Option<&(dyn StdError + 'static)> {
        self.0.source()
    }
}

impl fmt::Debug for Error {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        let mut d = f.debug_struct("Error");
        d.field("code", &self.code)
            .field("message", &self.message);
        if let Some(src) = &self.source {
            d.field("source", src);
        }
        d.finish()
    }
}

impl fmt::Display for Error {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        // "code: message" is the documented format. The source chain
        // is not inlined; use `source()` to walk it.
        write!(f, "{}: {}", self.code, self.message)
    }
}

impl StdError for Error {
    fn source(&self) -> Option<&(dyn StdError + 'static)> {
        self.source
            .as_ref()
            .map(|b| &**b as &(dyn StdError + 'static))
    }
}

// ============================================================================
// From conversions
// ============================================================================

impl From<&'static LoadError> for Error {
    fn from(err: &'static LoadError) -> Self {
        Error::from_load(err)
    }
}

// ============================================================================
// Tests
// ============================================================================

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn display_includes_code_and_message() {
        let e = Error::new(ErrorCode::InvalidArgument, "bad input");
        assert_eq!(e.to_string(), "invalid argument: bad input");
        assert_eq!(e.code(), ErrorCode::InvalidArgument);
        assert_eq!(e.message(), "bad input");
    }

    #[test]
    fn source_chain_is_preserved() {
        let inner = std::io::Error::new(std::io::ErrorKind::Other, "inner");
        let e = Error::with_source(ErrorCode::Generic, "outer", inner);
        let src = e.source().expect("source must be present");
        assert_eq!(src.to_string(), "inner");
    }
}