// ============================================================================
// File: csharp/src/LingoFuse_cs/AsyncResult.cs
// ============================================================================
// AsyncResult — the value passed to a callback-style asynchronous
// completion handler.
// ============================================================================
// ROLE
// ----
// AsyncResult is the single argument of every callback registered
// through the LingoFuse.Async facade. It mirrors the C++ class
// lingofuse::AsyncResult and the Pascal OnResult(Data, Result_)
// callback contract:
//
//   * Ok == true   -> a result handle was produced. The handle may
//                     carry zero bytes (remote timeout / empty
//                     response) or a non-empty payload.
//
//   * Ok == false  -> the request was rejected before dispatch. The
//                     framework will never invoke the callback again;
//                     the callback is being invoked synchronously on
//                     the caller's thread to signal this failure.
//
// Three convenience readers (ReadString, ReadAllBytes, ReadJson<T>)
// copy data out of the borrowed handle. They all throw when Ok is
// false, so a caller that forgot to check Ok receives a clear
// exception rather than silently-empty data.
//
// LIFETIME (READ THIS)
// --------------------
// An AsyncResult value is valid ONLY for the duration of the user
// callback body. The framework releases the underlying handle the
// instant the callback returns. Any attempt to read from the handle
// after that point is use-after-free.
//
// A value-type copy of AsyncResult is safe to store, but accessing its
// Handle, ReadString, ReadAllBytes, or ReadJson member after the
// callback has returned is not. This matches the contract of the C++
// AsyncResult::handle() and the Pascal Result_ parameter exactly.
//
// The word "borrowed" appears throughout the codebase: the underlying
// DataHandle does not own the native pointer (owned == false), so its
// Dispose is a no-op and it must never be passed to LF_FreeData.
//
// EXCEPTIONS
// ----------
//   Ok == false                      -> Handle, ReadString,
//                                       ReadAllBytes, ReadJson<T>
//                                       all throw InvalidOperationException.
//   Ok == true, Size == 0            -> ReadString returns "",
//                                       ReadAllBytes returns an empty
//                                       array, ReadJson<T> throws
//                                       InvalidOperationException.
//   Ok == true, Size > 0             -> the reader behaves as its
//                                       DataHandle counterpart.
// ============================================================================

using System;

namespace LingoFuse;

/// <summary>
/// The result of an asynchronous call issued through
/// <see cref="Async"/>.
/// </summary>
/// <remarks>
/// <para>
/// <b>Lifetime:</b> an AsyncResult is valid only inside the callback
/// body. The framework releases the underlying handle immediately
/// after the callback returns; any read after that point is
/// use-after-free.
/// </para>
/// <para>
/// <b>Dispatch failure:</b> when the native layer rejects the request
/// before queuing it, the callback is invoked synchronously on the
/// caller's thread with <see cref="Ok"/> set to <c>false</c>. This is
/// the single error path: dispatch failures and remote failures are
/// both observed by inspecting <see cref="Ok"/>.
/// </para>
/// </remarks>
public readonly struct AsyncResult
{
    // --------------------------------------------------------------------
    // Internal state
    // --------------------------------------------------------------------
    //
    // _handle is non-null exactly when _error is null (Ok == true).
    // _handle is a BORROWED DataHandle (owned == false) — its Dispose
    // is a no-op, so the callback body cannot accidentally free the
    // framework's buffer.
    //
    // When the framework returns a null handle (a rare "empty result"
    // path), the trampoline installs a fresh, owned, zero-size
    // DataHandle so that the callback always observes a valid
    // (if empty) handle. See Async.OnResult for the exact lifecycle.
    // --------------------------------------------------------------------

    private readonly DataHandle? _handle;
    private readonly string? _error;

    // --------------------------------------------------------------------
    // Internal factories — used only by Async.
    // --------------------------------------------------------------------

    internal AsyncResult(DataHandle handle)
    {
        _handle = handle;
        _error = null;
    }

    internal AsyncResult(string error)
    {
        _handle = null;
        _error = error;
    }

    internal static AsyncResult FromHandle(DataHandle handle)
        => new(handle);

    internal static AsyncResult FromError(string error)
        => new(error);

    // --------------------------------------------------------------------
    // Status
    // --------------------------------------------------------------------

    /// <summary>
    /// <c>true</c> when the framework produced a result handle
    /// (possibly empty); <c>false</c> when the request was rejected
    /// before dispatch.
    /// </summary>
    /// <remarks>
    /// <c>Ok == true</c> does <b>not</b> mean the response carries
    /// data. Check <see cref="Size"/> to distinguish "empty result"
    /// from "payload present".
    /// </remarks>
    public bool Ok => _error is null;

    /// <summary>
    /// Human-readable failure message. Non-null exactly when
    /// <see cref="Ok"/> is <c>false</c>.
    /// </summary>
    /// <remarks>
    /// The message text is not part of a stable contract; it is
    /// intended for logging and diagnostics only.
    /// </remarks>
    public string? Error => _error;

    /// <summary>
    /// Number of payload bytes. Returns 0 when <see cref="Ok"/> is
    /// <c>false</c>.
    /// </summary>
    public long Size => _handle?.Size ?? 0L;

    // --------------------------------------------------------------------
    // Borrowed handle
    // --------------------------------------------------------------------

    /// <summary>
    /// The borrowed native data handle.
    /// </summary>
    /// <remarks>
    /// <para>
    /// <b>Valid only inside the callback body.</b> Do not store it
    /// beyond the callback, do not pass it to another thread, and do
    /// not call <c>Dispose</c> on it. The framework releases the
    /// underlying buffer immediately after the callback returns.
    /// </para>
    /// <para>
    /// The returned <see cref="DataHandle"/> has <c>IsOwning ==
    /// false</c>: its <c>Dispose</c> is a no-op. That does not make it
    /// safe to retain.
    /// </para>
    /// </remarks>
    /// <exception cref="InvalidOperationException">
    /// Thrown when <see cref="Ok"/> is <c>false</c>.
    /// </exception>
    public DataHandle Handle
        => _handle
           ?? throw new InvalidOperationException(
               _error ?? "AsyncResult has no handle.");

    // --------------------------------------------------------------------
    // Convenience readers — all copy the data out.
    // --------------------------------------------------------------------

    /// <summary>
    /// Reads a NUL-framed UTF-8 string from the current cursor.
    /// </summary>
    /// <remarks>
    /// When <see cref="Size"/> is zero, returns an empty string. When
    /// <see cref="Ok"/> is <c>false</c>, throws.
    /// </remarks>
    /// <exception cref="InvalidOperationException">
    /// Thrown when <see cref="Ok"/> is <c>false</c>.
    /// </exception>
    public string ReadString()
    {
        if (_error is not null)
        {
            throw new InvalidOperationException(_error);
        }
        return _handle?.ReadString() ?? string.Empty;
    }

    /// <summary>
    /// Reads every remaining byte into a fresh array.
    /// </summary>
    /// <remarks>
    /// When <see cref="Size"/> is zero, returns an empty array. When
    /// <see cref="Ok"/> is <c>false</c>, throws.
    /// </remarks>
    /// <exception cref="InvalidOperationException">
    /// Thrown when <see cref="Ok"/> is <c>false</c>.
    /// </exception>
    public byte[] ReadAllBytes()
    {
        if (_error is not null)
        {
            throw new InvalidOperationException(_error);
        }
        return _handle?.ReadAllBytes() ?? Array.Empty<byte>();
    }

    /// <summary>
    /// Reads a NUL-framed JSON payload and deserializes it as
    /// <typeparamref name="T"/>.
    /// </summary>
    /// <remarks>
    /// The payload must be non-empty; this method throws when
    /// <see cref="Size"/> is zero, mirroring the C++ binding's
    /// behaviour for an empty result.
    /// </remarks>
    /// <exception cref="InvalidOperationException">
    /// Thrown when <see cref="Ok"/> is <c>false</c>, or when the
    /// result carries no payload.
    /// </exception>
    /// <exception cref="LingoFuseException">
    /// Thrown when the payload is not valid JSON or cannot be
    /// materialized as <typeparamref name="T"/>.
    /// </exception>
    public T ReadJson<T>()
    {
        if (_error is not null)
        {
            throw new InvalidOperationException(_error);
        }
        if (_handle is null)
        {
            throw new InvalidOperationException(
                "AsyncResult has no handle; nothing to deserialize.");
        }
        return LfIo.ReadJson<T>(_handle);
    }
}