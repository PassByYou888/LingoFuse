//! RAII wrapper around a native LingoFuse data handle.
//!
//! [`DataHandle`] owns a `TDataHnd` and releases it deterministically
//! on [`Drop`]. It provides byte-level, scalar, and NUL-framed string
//! I/O on top of the underlying buffer.
//!
//! ## Two kinds of handles
//!
//! The native library provides two flavours, distinguished only by the
//! constructor used:
//!
//! | Kind          | Constructor                     | Auto-recycled? | Release on `Drop` |
//! |---------------|---------------------------------|:--------------:|:-----------------:|
//! | Auto-recycled | [`DataHandle::new`]             | Yes (10 min / 5 s scan) | Marked for pool release |
//! | Permanent     | [`DataHandle::create_permanent`] | No             | Synchronous       |
//!
//! Both kinds **must be explicitly dropped** to avoid leaks in the
//! common case. The auto-reclaimer is a safety net, not a substitute
//! for [`Drop`].
//!
//! ## Ownership
//!
//! A `DataHandle` is either **owning** or **borrowing**:
//!
//! - **Owning** — created by [`DataHandle::new`] or
//!   [`DataHandle::create_permanent`]. `Drop` calls `LF_FreeData`.
//! - **Borrowing** — created by [`DataHandle::from_raw`] with
//!   `owned = false`. `Drop` is a no-op; the native layer owns the
//!   underlying resource and releases it when the surrounding callback
//!   returns.
//!
//! Borrowing is used for the `input` / `output` handles passed into a
//! registered callback. Freeing them from Rust would be a double-free.
//! The Stage 2 [`crate::app_handle`] layer constructs borrows through
//! [`DataHandle::from_raw`].
//!
//! ## Threading
//!
//! The native library is thread-safe, but a single data handle must not
//! be written concurrently. `DataHandle` is `Send` (it can be moved
//! between threads) and `Sync` (immutable access via `&self` is safe),
//! but every read/write method takes `&mut self`, so the Rust borrow
//! checker prevents concurrent mutation without any extra work.
//!
//! ## I/O failure semantics
//!
//! Two symmetric read families are offered:
//!
//! | Family              | Behaviour on short read |
//! |---------------------|-------------------------|
//! | [`DataHandle::read_bytes`] | Returns fewer bytes; never fails for a short read |
//! | [`DataHandle::read_bytes_exact`] | Returns [`ErrorCode::ReadFailed`](crate::error::ErrorCode::ReadFailed) |
//! | [`DataHandle::try_read_bytes`] | Returns `None` |
//!
//! Writes always demand the full byte count. A short write is a hard
//! failure and produces [`ErrorCode::WriteFailed`](crate::error::ErrorCode::WriteFailed).
//!
//! ## Scalar I/O
//!
//! All scalar reads and writes use little-endian byte order, matching
//! the cross-language wire contract. Scalars are handled through the
//! [`Scalar`] trait, so `handle.write(42i32)` and
//! `handle.read::<i32>()` work for every supported type. See
//! [`Scalar`] for the implementor list.

use std::ffi::CString;

use crate::error::{Error, ErrorCode};
use crate::sys::{self, DataHnd, NativeLibrary};

// ============================================================================
// DataHandle
// ============================================================================

/// RAII wrapper around a native LingoFuse data handle.
///
/// See the module documentation for the ownership model and the I/O
/// semantics.
///
/// # Example
///
/// ```no_run
/// use lingofuse::data_handle::DataHandle;
///
/// let mut h = DataHandle::new("echo")?;
/// h.write_string("hello")?;
/// h.set_position(0)?;
/// assert_eq!(h.read_string()?, "hello");
/// # Ok::<(), lingofuse::error::Error>(())
/// ```
pub struct DataHandle {
    /// The `'static` function table. Resolved once at construction so
    /// that every subsequent method avoids the `OnceLock` lookup.
    lib: &'static NativeLibrary,

    /// The raw native pointer, or `None` after an owning handle has
    /// been disposed.
    raw: Option<DataHnd>,

    /// `true` when `Drop` should call `LF_FreeData`.
    owned: bool,
}

impl DataHandle {
    // -----------------------------------------------------------------
    // Construction
    // -----------------------------------------------------------------

    /// Creates a new **auto-recycled** data handle bound to the given
    /// API name. The underlying buffer starts empty.
    ///
    /// The handle is added to the library's idle pool. The pool scans
    /// every 5 seconds and frees any handle idle for more than 10
    /// minutes. Use [`DataHandle::create_permanent`] when the handle
    /// must survive for the entire process lifetime.
    ///
    /// # Errors
    ///
    /// - [`ErrorCode::LibraryLoadFailed`] if the native library is not
    ///   available.
    /// - [`ErrorCode::InvalidArgument`] if `api_name` contains an
    ///   interior NUL.
    /// - [`ErrorCode::Generic`] if the native allocator fails.
    pub fn new(api_name: &str) -> Result<Self, Error> {
        let lib = sys::get_library().map_err(|e| Error::from_load(e))?;
        let c_name = CString::new(api_name).map_err(|_| {
            Error::invalid_argument(
                "DataHandle::new",
                "api_name contains an interior NUL",
            )
        })?;
        // SAFETY: `lib` is a valid `'static` function table; `c_name`
        // is a UTF-8, NUL-terminated string. The contract of
        // `LF_CreateData` is documented in `bindings.rs`.
        let hnd = unsafe { (lib.lf_create_data)(c_name.as_ptr()) };
        if hnd.is_null() {
            return Err(Error::new(
                ErrorCode::Generic,
                format!("LF_CreateData failed for API '{}'", api_name),
            ));
        }
        Ok(DataHandle {
            lib,
            raw: Some(hnd),
            owned: true,
        })
    }

    /// Creates a new **permanent** data handle bound to the given API
    /// name. The underlying buffer starts empty.
    ///
    /// # Difference from [`DataHandle::new`]
    ///
    /// - Not added to the idle pool.
    /// - Never auto-reclaimed.
    /// - `Drop` releases it **synchronously**.
    ///
    /// # Pitfall
    ///
    /// "Permanent" means "not auto-reclaimed", **not** "never
    /// released". Losing the [`DataHandle`] without dropping it leaks
    /// the handle for the lifetime of the process.
    ///
    /// # Errors
    ///
    /// Same as [`DataHandle::new`].
    pub fn create_permanent(api_name: &str) -> Result<Self, Error> {
        let lib = sys::get_library().map_err(|e| Error::from_load(e))?;
        let c_name = CString::new(api_name).map_err(|_| {
            Error::invalid_argument(
                "DataHandle::create_permanent",
                "api_name contains an interior NUL",
            )
        })?;
        // SAFETY: same as `new`.
        let hnd = unsafe { (lib.lf_create_data_permanent)(c_name.as_ptr()) };
        if hnd.is_null() {
            return Err(Error::new(
                ErrorCode::Generic,
                format!(
                    "LF_CreateData_Permanent failed for API '{}'",
                    api_name
                ),
            ));
        }
        Ok(DataHandle {
            lib,
            raw: Some(hnd),
            owned: true,
        })
    }

    /// Wraps an existing raw handle. Intended for internal use inside
    /// callbacks, where the native layer already owns the resource.
    ///
    /// # Ownership
    ///
    /// - `owned = true`: [`Drop`] calls `LF_FreeData`. Use this only
    ///   when you received the handle from a source that transfers
    ///   ownership (for example `LF_LocalCall`'s return value).
    /// - `owned = false`: [`Drop`] is a no-op. Use this for the
    ///   `input` / `output` handles passed into a callback body.
    ///
    /// # Errors
    ///
    /// - [`ErrorCode::LibraryLoadFailed`] if the native library is not
    ///   available.
    pub fn from_raw(raw: DataHnd, owned: bool) -> Result<Self, Error> {
        let lib = sys::get_library().map_err(|e| Error::from_load(e))?;
        Ok(DataHandle {
            lib,
            raw: if raw.is_null() { None } else { Some(raw) },
            owned,
        })
    }

    // -----------------------------------------------------------------
    // Identity and state
    // -----------------------------------------------------------------

    /// Returns the raw native pointer, or `None` after an owning handle
    /// has been disposed.
    ///
    /// # Safety (caller responsibility)
    ///
    /// The returned pointer is valid only as long as the
    /// [`DataHandle`] has not been dropped. Do not store it beyond the
    /// handle's lifetime.
    pub fn raw(&self) -> Option<DataHnd> {
        self.raw
    }

    /// Returns `true` while the handle is valid and usable.
    #[inline]
    pub fn is_valid(&self) -> bool {
        self.raw.is_some()
    }

    /// Returns `true` when this instance owns the native handle.
    #[inline]
    pub fn is_owning(&self) -> bool {
        self.owned
    }

    // -----------------------------------------------------------------
    // Position and size
    // -----------------------------------------------------------------

    /// Returns the current read/write cursor position, in bytes.
    pub fn position(&self) -> Result<i64, Error> {
        let hnd = self.require_handle("DataHandle::position")?;
        // SAFETY: `hnd` is a live handle.
        Ok(unsafe { (self.lib.lf_get_pos)(hnd) })
    }

    /// Sets the read/write cursor.
    ///
    /// A position past the current size implicitly grows the buffer;
    /// the new bytes are uninitialised.
    pub fn set_position(&mut self, pos: i64) -> Result<(), Error> {
        if pos < 0 {
            return Err(Error::invalid_argument(
                "DataHandle::set_position",
                "position must be non-negative",
            ));
        }
        let hnd = self.require_handle("DataHandle::set_position")?;
        // SAFETY: `hnd` is a live handle; `pos` is non-negative.
        unsafe { (self.lib.lf_set_pos)(hnd, pos) };
        Ok(())
    }

    /// Returns the total buffer size, in bytes.
    pub fn size(&self) -> Result<i64, Error> {
        let hnd = self.require_handle("DataHandle::size")?;
        // SAFETY: `hnd` is a live handle.
        Ok(unsafe { (self.lib.lf_get_size)(hnd) })
    }

    /// Resizes the buffer.
    ///
    /// Growing leaves the new bytes uninitialised; shrinking discards
    /// the trailing bytes.
    pub fn set_size(&mut self, size: i64) -> Result<(), Error> {
        if size < 0 {
            return Err(Error::invalid_argument(
                "DataHandle::set_size",
                "size must be non-negative",
            ));
        }
        let hnd = self.require_handle("DataHandle::set_size")?;
        // SAFETY: `hnd` is a live handle; `size` is non-negative.
        unsafe { (self.lib.lf_set_size)(hnd, size) };
        Ok(())
    }

    // -----------------------------------------------------------------
    // Byte I/O
    // -----------------------------------------------------------------

    /// Appends `data` at the current cursor. The buffer grows as needed;
    /// the cursor advances by the number of bytes written.
    ///
    /// An empty `data` is a no-op.
    ///
    /// # Errors
    ///
    /// - [`ErrorCode::NullHandle`] if the handle is not valid.
    /// - [`ErrorCode::WriteFailed`] if the native layer wrote fewer
    ///   bytes than requested.
    pub fn write_bytes(&mut self, data: &[u8]) -> Result<(), Error> {
        if data.is_empty() {
            return Ok(());
        }
        let hnd = self.require_handle("DataHandle::write_bytes")?;
        // SAFETY: `hnd` is a live handle; `data` is a valid slice and
        // its length fits in `i64` for any physically realisable
        // buffer.
        let written = unsafe {
            (self.lib.lf_write_buffer)(
                hnd,
                data.as_ptr() as *const std::os::raw::c_void,
                data.len() as i64,
            )
        };
        if written != data.len() as i64 {
            return Err(Error::write_failed(
                "DataHandle::write_bytes",
                data.len(),
                written,
            ));
        }
        Ok(())
    }

    /// Reads **up to** `count` bytes. The cursor advances by the number
    /// of bytes actually read.
    ///
    /// Never fails for a short read. Returns an empty vector when the
    /// cursor is already at or past the end of the buffer.
    pub fn read_bytes(&mut self, count: usize) -> Result<Vec<u8>, Error> {
        if count == 0 {
            return Ok(Vec::new());
        }
        let hnd = self.require_handle("DataHandle::read_bytes")?;
        let mut buf = vec![0u8; count];
        // SAFETY: `hnd` is a live handle; `buf` is a valid
        // `count`-byte writable slice.
        let read = unsafe {
            (self.lib.lf_read_buffer)(
                hnd,
                buf.as_mut_ptr() as *mut std::os::raw::c_void,
                count as i64,
            )
        };
        if read <= 0 {
            return Ok(Vec::new());
        }
        buf.truncate(read as usize);
        Ok(buf)
    }

    /// Reads **exactly** `count` bytes.
    ///
    /// On a short read the cursor is left unchanged and
    /// [`ErrorCode::ReadFailed`] is returned.
    pub fn read_bytes_exact(&mut self, count: usize) -> Result<Vec<u8>, Error> {
        if count == 0 {
            return Ok(Vec::new());
        }
        let saved = self.position()?;
        let buf = self.read_bytes(count)?;
        if buf.len() != count {
            self.set_position(saved)?;
            return Err(Error::read_failed(
                "DataHandle::read_bytes_exact",
                count,
                buf.len(),
            ));
        }
        Ok(buf)
    }

    /// Non-throwing counterpart of [`DataHandle::read_bytes_exact`].
    ///
    /// Returns `Some(bytes)` on success and `None` on a short read
    /// (the cursor is restored). A null/disposed handle still returns
    /// `Err`.
    pub fn try_read_bytes(
        &mut self,
        count: usize,
    ) -> Result<Option<Vec<u8>>, Error> {
        if count == 0 {
            return Ok(Some(Vec::new()));
        }
        let saved = self.position()?;
        let buf = self.read_bytes(count)?;
        if buf.len() != count {
            self.set_position(saved)?;
            return Ok(None);
        }
        Ok(Some(buf))
    }

    /// Reads every remaining byte from the current cursor to the end of
    /// the buffer and advances the cursor to the end.
    pub fn read_all_bytes(&mut self) -> Result<Vec<u8>, Error> {
        let pos = self.position()?;
        let total = self.size()?;
        if pos >= total {
            return Ok(Vec::new());
        }
        let remaining = (total - pos) as usize;
        self.read_bytes(remaining)
    }

    // -----------------------------------------------------------------
    // Scalar I/O
    // -----------------------------------------------------------------

    /// Writes a scalar value in little-endian byte order.
    ///
    /// See [`Scalar`] for the supported types.
    pub fn write<S: Scalar>(&mut self, value: S) -> Result<(), Error> {
        value.write_to(self)
    }

    /// Reads a scalar value in little-endian byte order.
    ///
    /// See [`Scalar`] for the supported types.
    pub fn read<S: Scalar>(&mut self) -> Result<S, Error> {
        S::read_from(self)
    }

    // -----------------------------------------------------------------
    // NUL-framed string I/O
    // -----------------------------------------------------------------

    /// Writes `value` as UTF-8 bytes, followed by a single NUL byte.
    ///
    /// An empty string writes exactly one byte (the NUL), matching the
    /// Pascal, Python, C++, C#, and JavaScript bindings.
    pub fn write_string(&mut self, value: &str) -> Result<(), Error> {
        self.write_bytes(value.as_bytes())?;
        self.write_bytes(&[0u8])?;
        Ok(())
    }

    /// Reads a UTF-8 string from the current cursor, stopping at the
    /// first NUL byte.
    ///
    /// If no NUL is present before the end of the buffer, the entire
    /// remaining buffer is consumed and returned. Invalid UTF-8 byte
    /// sequences are decoded with replacement characters (`U+FFFD`),
    /// matching the fault-tolerant policy of every other binding.
    pub fn read_string(&mut self) -> Result<String, Error> {
        let bytes = self.read_until_nul()?;
        Ok(String::from_utf8_lossy(&bytes).into_owned())
    }

    /// Non-throwing counterpart of [`DataHandle::read_string`].
    ///
    /// Returns `None` only when the cursor is at or past the end of the
    /// buffer. An empty string (a single NUL) returns
    /// `Some(String::new())`.
    pub fn try_read_string(&mut self) -> Result<Option<String>, Error> {
        if self.position()? >= self.size()? {
            return Ok(None);
        }
        Ok(Some(self.read_string()?))
    }

    // -----------------------------------------------------------------
    // Lifetime
    // -----------------------------------------------------------------

    /// Releases the native handle when ownership applies. Idempotent.
    ///
    /// Normally you never need to call this: the [`Drop`] implementation
    /// calls it automatically. Call it explicitly when you need to
    /// release the handle **before** the `DataHandle` goes out of scope
    /// (for example to drop a long-lived permanent handle inside a
    /// function that will keep running).
    ///
    /// For an owning **auto-recycled** handle this only marks the handle
    /// as deleted; the actual release happens on the next pool scan.
    /// For an owning **permanent** handle the release is synchronous.
    ///
    /// For a **borrowed** handle this is a no-op.
    pub fn dispose(&mut self) {
        if !self.owned {
            return;
        }
        if let Some(hnd) = self.raw.take() {
            // SAFETY: `hnd` was created by `LF_CreateData` or
            // `LF_CreateData_Permanent`, was not previously freed, and
            // is about to be removed from `self.raw`, so no other
            // method can touch it.
            unsafe { (self.lib.lf_free_data)(hnd) };
        }
    }

    // -----------------------------------------------------------------
    // Internal helpers
    // -----------------------------------------------------------------

    fn require_handle(&self, op: &str) -> Result<DataHnd, Error> {
        self.raw.ok_or_else(|| Error::null_handle(op))
    }

    /// Reads bytes up to the first NUL, or the entire remaining buffer
    /// if no NUL is present. Advances the cursor past the NUL (or one
    /// byte past the end of the buffer when none was found), matching
    /// the fault-tolerant read behaviour of every other binding.
    fn read_until_nul(&mut self) -> Result<Vec<u8>, Error> {
        let start = self.position()?;
        let total = self.size()?;
        if start >= total {
            return Ok(Vec::new());
        }

        let raw = self.read_bytes((total - start) as usize)?;
        if raw.is_empty() {
            return Ok(Vec::new());
        }

        match raw.iter().position(|&b| b == 0) {
            Some(nul) => {
                // Found a NUL. Restore the cursor to just past it.
                let new_pos = start + nul as i64 + 1;
                self.set_position(new_pos)?;
                let mut v = raw;
                v.truncate(nul);
                Ok(v)
            }
            None => {
                // No NUL found. The native fault-tolerant rule moves
                // the cursor to one byte past the end of the buffer.
                let new_pos = start + raw.len() as i64 + 1;
                self.set_position(new_pos)?;
                Ok(raw)
            }
        }
    }
}

impl Drop for DataHandle {
    fn drop(&mut self) {
        self.dispose();
    }
}

// DataHandle can be moved between threads (`Send`) and accessed through
// a shared reference (`Sync`). Both are safe:
//
// - `Send`: the native library is documented as thread-safe; moving the
//   handle transfers exclusive ownership, so no concurrent access is
//   possible during the move.
// - `Sync`: every mutating method takes `&mut self`, which the borrow
//   checker prevents from being called concurrently. The methods that
//   take `&self` (`size`, `position`, `raw`, `is_valid`, `is_owning`)
//   call into the native layer in a way that the native documentation
//   describes as thread-safe; none of them mutate the handle.
unsafe impl Send for DataHandle {}
unsafe impl Sync for DataHandle {}

impl std::fmt::Debug for DataHandle {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("DataHandle")
            .field("valid", &self.is_valid())
            .field("owned", &self.owned)
            .finish_non_exhaustive()
    }
}

// ============================================================================
// Scalar trait
// ============================================================================

/// A scalar type that can be written to or read from a [`DataHandle`]
/// in little-endian byte order.
///
/// Implemented for `i8`, `u8`, `i16`, `u16`, `i32`, `u32`, `i64`,
/// `u64`, `f32`, and `f64`.
///
/// # Example
///
/// ```no_run
/// # use lingofuse::data_handle::DataHandle;
/// # fn f() -> Result<(), lingofuse::error::Error> {
/// let mut h = DataHandle::new("calc")?;
/// h.write(5i32)?;
/// h.write(7i32)?;
/// h.set_position(0)?;
/// let a: i32 = h.read()?;
/// let b: i32 = h.read()?;
/// assert_eq!(a + b, 12);
/// # Ok(()) }
/// ```
pub trait Scalar: Sized {
    /// The number of bytes this scalar occupies on the wire.
    const SIZE: usize;

    /// Writes the value to the handle at the current cursor.
    fn write_to(self, handle: &mut DataHandle) -> Result<(), Error>;

    /// Reads a value from the handle at the current cursor.
    fn read_from(handle: &mut DataHandle) -> Result<Self, Error>;
}

macro_rules! impl_scalar {
    ($ty:ty) => {
        impl Scalar for $ty {
            const SIZE: usize = std::mem::size_of::<$ty>();

            fn write_to(self, handle: &mut DataHandle) -> Result<(), Error> {
                handle.write_bytes(&self.to_le_bytes())
            }

            fn read_from(handle: &mut DataHandle) -> Result<Self, Error> {
                let bytes = handle.read_bytes_exact(Self::SIZE)?;
                // `try_into` cannot fail here: `read_bytes_exact`
                // guarantees the length, and `SIZE == size_of::<$ty>()`.
                let arr: [u8; std::mem::size_of::<$ty>()] =
                    bytes.try_into().map_err(|_| {
                        Error::read_failed(
                            "Scalar::read_from",
                            Self::SIZE,
                            0,
                        )
                    })?;
                Ok(<$ty>::from_le_bytes(arr))
            }
        }
    };
}

impl_scalar!(i8);
impl_scalar!(u8);
impl_scalar!(i16);
impl_scalar!(u16);
impl_scalar!(i32);
impl_scalar!(u32);
impl_scalar!(i64);
impl_scalar!(u64);
impl_scalar!(f32);
impl_scalar!(f64);

// ============================================================================
// Tests
// ============================================================================

#[cfg(test)]
mod tests {
    use super::*;

    /// Skips the test silently when the native library is not present,
    /// matching the integration-test convention.
    fn try_handle(api: &str) -> Option<DataHandle> {
        match DataHandle::new(api) {
            Ok(h) => Some(h),
            Err(e) if e.code() == ErrorCode::LibraryLoadFailed => {
                eprintln!("[SKIP] native library not available: {}", e);
                None
            }
            Err(e) => panic!("unexpected construction failure: {}", e),
        }
    }

    #[test]
    fn byte_roundtrip() {
        let Some(mut h) = try_handle("test_bytes") else { return; };
        h.write_bytes(&[1, 2, 3, 4]).unwrap();
        assert_eq!(h.size().unwrap(), 4);
        h.set_position(0).unwrap();
        assert_eq!(h.read_bytes(4).unwrap(), vec![1, 2, 3, 4]);
    }

    #[test]
    fn scalar_roundtrip() {
        let Some(mut h) = try_handle("test_scalar") else { return; };
        h.write(42i32).unwrap();
        h.write(3.5f64).unwrap();
        h.write(0xAABBCCDDu32).unwrap();
        h.set_position(0).unwrap();
        assert_eq!(h.read::<i32>().unwrap(), 42);
        assert_eq!(h.read::<f64>().unwrap(), 3.5);
        assert_eq!(h.read::<u32>().unwrap(), 0xAABBCCDD);
    }

    #[test]
    fn string_roundtrip() {
        let Some(mut h) = try_handle("test_string") else { return; };
        h.write_string("hello, 世界").unwrap();
        h.set_position(0).unwrap();
        assert_eq!(h.read_string().unwrap(), "hello, 世界");
    }

    #[test]
    fn empty_string_roundtrip() {
        let Some(mut h) = try_handle("test_empty_string") else { return; };
        h.write_string("").unwrap();
        assert_eq!(h.size().unwrap(), 1, "empty string writes a single NUL");
        h.set_position(0).unwrap();
        assert_eq!(h.read_string().unwrap(), "");
    }

    #[test]
    fn exact_read_failure_restores_cursor() {
        let Some(mut h) = try_handle("test_exact_fail") else { return; };
        h.write_bytes(&[1, 2]).unwrap();
        h.set_position(0).unwrap();
        let err = h.read_bytes_exact(4).unwrap_err();
        assert_eq!(err.code(), ErrorCode::ReadFailed);
        assert_eq!(h.position().unwrap(), 0, "cursor must be restored");
    }

    #[test]
    fn try_read_returns_none_without_error() {
        let Some(mut h) = try_handle("test_try_read") else { return; };
        h.write_bytes(&[1, 2]).unwrap();
        h.set_position(0).unwrap();
        assert!(h.try_read_bytes(4).unwrap().is_none());
        assert_eq!(h.position().unwrap(), 0);
        assert!(h.try_read_bytes(2).unwrap().is_some());
    }

    #[test]
    fn read_without_nul_consumes_remaining() {
        let Some(mut h) = try_handle("test_no_nul") else { return; };
        // Write raw JSON with no trailing NUL.
        h.write_bytes(b"{\"a\":1}").unwrap();
        h.set_position(0).unwrap();
        assert_eq!(h.read_string().unwrap(), "{\"a\":1}");
    }

    #[test]
    fn drop_is_idempotent() {
        let Some(h) = try_handle("test_drop") else { return; };
        drop(h);
        // A second drop would be UB, but the borrow checker prevents
        // it. This test only confirms the first drop did not panic.
    }
}