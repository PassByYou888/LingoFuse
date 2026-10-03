// =============================================================================
//  error.zig - Error set for the LingoFuse Zig binding.
// -----------------------------------------------------------------------------
//  Every fallible operation in this binding returns `Error!T`. The
//  set deliberately mirrors the hierarchy used by the C++, C#, and
//  Rust bindings, so that a developer who has used one binding can
//  recognise the failure modes in another.
//
//  Variant reference
//  -----------------
//
//  LibraryLoadFailed
//      The native shared library could not be loaded, or a required
//      symbol was missing.
//
//  NullHandle
//      An operation was attempted on a null or already-released
//      handle.
//
//  InvalidArgument
//      A caller-side argument failed validation (negative size,
//      interior NUL in a string parameter, and similar pre-flight
//      checks).
//
//  WriteFailed
//      A write into a data handle wrote fewer bytes than requested.
//
//  ReadFailed
//      A read from a data handle returned fewer bytes than requested.
//
//  CallFailed
//      A remote call returned a null handle.
//
//  RegistrationFailed
//      `LF_RegisterCall` / `LF_RegisterNotify` was rejected, usually
//      because the API name is already taken.
//
//  NotConnected
//      The operation requires a running framework but the framework
//      is not running.
//
//  Timeout
//      A remote call timed out. The C ABI surfaces this as a size-0
//      handle; this variant is produced by the Zig layer based on the
//      handle size.
//
//  OutOfMemory
//      A Zig-side allocation failed.
// =============================================================================
pub const Error = error{
    LibraryLoadFailed,
    NullHandle,
    InvalidArgument,
    WriteFailed,
    ReadFailed,
    CallFailed,
    RegistrationFailed,
    NotConnected,
    Timeout,
    OutOfMemory,
};
