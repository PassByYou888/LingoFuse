using System;

namespace LingoFuse;

// ============================================================================
// Exception hierarchy for the LingoFuse .NET binding.
// ============================================================================
//
// Every failure raised by the binding is an instance of
// LingoFuseException or of one of its subclasses. User code can catch
// the base type for a single, catch-all handler.
//
// The hierarchy mirrors the layer at which the failure occurred:
//
//     base class            LingoFuseException
//     library load          LingoFuseLibraryLoadException
//     remote call           LingoFuseCallException
//     I/O on a handle       LingoFuseIoException
//     use after dispose     LingoFuseObjectDisposedException
//
// Only these five types exist. Custom exception types for
// registration errors, state errors, or any other condition that
// cannot actually be raised by the current implementation are
// deliberately absent. If a new failure mode is introduced, its
// exception type is added here — not invented at the call site.
//
// ============================================================================

/// <summary>
/// Base class for all LingoFuse exceptions.
/// </summary>
public class LingoFuseException : Exception
{
    /// <summary>Initialize with the default message.</summary>
    public LingoFuseException()
        : base("A LingoFuse operation failed.")
    {
    }

    /// <summary>Initialize with a custom message.</summary>
    public LingoFuseException(string message)
        : base(message)
    {
    }

    /// <summary>Initialize with a custom message and an inner exception.</summary>
    public LingoFuseException(string message, Exception innerException)
        : base(message, innerException)
    {
    }
}

/// <summary>
/// Raised when the native LingoFuse library cannot be located or
/// loaded by the platform resolver.
/// </summary>
/// <remarks>
/// Typical causes:
///   - the DLL / .so / .dylib is not next to the executable and is
///     not on the loader search path;
///   - it has an architecture mismatch (a 64-bit host trying to load
///     a 32-bit library, or vice versa);
///   - a dependent native library is missing.
/// </remarks>
public sealed class LingoFuseLibraryLoadException : LingoFuseException
{
    /// <summary>
    /// The logical or platform-specific library name that failed to
    /// load.
    /// </summary>
    public string LibraryName { get; }

    /// <summary>Initialize with the library name that could not be loaded.</summary>
    public LingoFuseLibraryLoadException(string libraryName)
        : base($"Failed to load the LingoFuse native library '{libraryName}'.")
    {
        LibraryName = libraryName;
    }

    /// <summary>Initialize with a custom message and the library name.</summary>
    public LingoFuseLibraryLoadException(string libraryName, string message)
        : base(message)
    {
        LibraryName = libraryName;
    }

    /// <summary>
    /// Initialize with a custom message, the library name, and an
    /// inner exception.
    /// </summary>
    public LingoFuseLibraryLoadException(
        string libraryName,
        string message,
        Exception innerException)
        : base(message, innerException)
    {
        LibraryName = libraryName;
    }
}

/// <summary>
/// Raised when a remote Call fails: null handle from the native layer,
/// timeout, or an unreachable target application.
/// </summary>
/// <remarks>
/// The C ABI reports a failed Call as an empty handle (size 0), never
/// as a NULL pointer. This exception is the managed representation of
/// that failure, and it is also raised when the native layer itself
/// returns a NULL handle (a more fundamental transport problem).
/// </remarks>
public sealed class LingoFuseCallException : LingoFuseException
{
    /// <summary>Name of the target application, when known.</summary>
    public string? TargetApp { get; }

    /// <summary>Name of the target API, when known.</summary>
    public string? TargetApi { get; }

    /// <summary>Initialize with a custom message.</summary>
    public LingoFuseCallException(string message)
        : base(message)
    {
    }

    /// <summary>
    /// Initialize with a custom message and the target identification.
    /// </summary>
    public LingoFuseCallException(
        string message,
        string? targetApp,
        string? targetApi)
        : base(message)
    {
        TargetApp = targetApp;
        TargetApi = targetApi;
    }
}

/// <summary>
/// Raised when a low-level I/O operation on a data handle fails: a
/// short read when the caller asked for a fixed number of bytes, or a
/// short write when the native layer accepted fewer bytes than
/// requested.
/// </summary>
/// <remarks>
/// This exception is reserved for the byte-level contract of a data
/// handle. Argument validation errors use the standard .NET
/// exceptions (<see cref="ArgumentNullException"/>,
/// <see cref="ArgumentOutOfRangeException"/>).
///
/// The <see cref="Operation"/> property names the failing operation
/// (for example "ReadBytesExact") so a diagnostic handler can produce
/// a precise message without parsing the exception text.
/// </remarks>
public sealed class LingoFuseIoException : LingoFuseException
{
    /// <summary>Name of the failing I/O operation, when known.</summary>
    public string? Operation { get; }

    /// <summary>Initialize with a custom message.</summary>
    public LingoFuseIoException(string message)
        : base(message)
    {
    }

    /// <summary>
    /// Initialize with a custom message and the name of the failing
    /// operation.
    /// </summary>
    public LingoFuseIoException(string message, string? operation)
        : base(message)
    {
        Operation = operation;
    }

    /// <summary>
    /// Initialize with a custom message, the name of the failing
    /// operation, and an inner exception.
    /// </summary>
    public LingoFuseIoException(
        string message,
        string? operation,
        Exception innerException)
        : base(message, innerException)
    {
        Operation = operation;
    }
}

/// <summary>
/// Raised when an operation is attempted on an object that has already
/// been disposed.
/// </summary>
public sealed class LingoFuseObjectDisposedException : LingoFuseException
{
    /// <summary>Name of the disposed object (for diagnostics).</summary>
    public string ObjectName { get; }

    /// <summary>Initialize with the object name.</summary>
    public LingoFuseObjectDisposedException(string objectName)
        : base($"The {objectName} has already been disposed.")
    {
        ObjectName = objectName;
    }
}