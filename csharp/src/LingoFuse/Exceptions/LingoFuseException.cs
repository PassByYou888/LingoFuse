// ============================================================================
// Exception hierarchy for the LingoFuse .NET binding.
// ============================================================================
//
// Every failure raised by the binding is an instance of LingoFuseException
// or of one of its subclasses. User code should catch:
//
//     - LingoFuseException            for a single, catch-all handler;
//     - one of the specific subclasses for finer-grained recovery.
//
// ----------------------------------------------------------------------------
// DESIGN RULES
// ----------------------------------------------------------------------------
//   1. No subclass derives from a platform-specific type. The library
//      remains portable across .NET runtimes.
//
//   2. Every subclass exposes the structured data it needs. For example,
//      LingoFuseCallException carries TargetApp / TargetApi so that a
//      caller can build a precise diagnostic without parsing the message.
//
//   3. The message text is meant for developers, not for end users. It is
//      in English and describes the technical cause, not the business
//      meaning of the failure.
//
//   4. The exception hierarchy mirrors the layer at which the failure
//      occurred:
//          - library load  ->  LingoFuseLibraryLoadException
//          - registration  ->  LingoFuseRegistrationException
//          - remote call   ->  LingoFuseCallException
//          - I/O on a handle -> LingoFuseIoException
//          - state error   ->  LingoFuseStateException
//          - use after dispose -> LingoFuseObjectDisposedException
//
// ----------------------------------------------------------------------------
// EXCEPTION POLICY
// ----------------------------------------------------------------------------
// The .NET binding follows a single, uniform policy. Every public method
// declares which of the following it may throw, and any deviation is a bug:
//
//   ArgumentNullException             a reference argument is null
//   ArgumentOutOfRangeException       a numeric argument is outside its range
//   LingoFuseObjectDisposedException  the receiver has been disposed
//   LingoFuseStateException           the receiver is in the wrong state
//   LingoFuseRegistrationException    an API could not be registered
//   LingoFuseCallException            a remote call failed
//   LingoFuseIoException              an I/O operation on a handle failed
//   LingoFuseLibraryLoadException     the native library could not be loaded
//   LingoFuseException                anything else related to LingoFuse
//
// Methods that promise a non-throwing contract use a Try* name and
// return a boolean or a nullable instead of throwing.
// ============================================================================

using System;

namespace LingoFuse;

// ============================================================================
// Base class
// ============================================================================

/// <summary>
/// Base class for all LingoFuse exceptions.
/// </summary>
/// <remarks>
/// Catch this type for a single, catch-all handler around any LingoFuse
/// operation. Catch a specific subclass when the recovery path depends on
/// the kind of failure.
/// </remarks>
public class LingoFuseException : Exception
{
    /// <summary>Initialise with the default message.</summary>
    public LingoFuseException()
        : base("A LingoFuse operation failed.")
    {
    }

    /// <summary>Initialise with a custom message.</summary>
    public LingoFuseException(string message)
        : base(message)
    {
    }

    /// <summary>Initialise with a custom message and an inner exception.</summary>
    public LingoFuseException(string message, Exception innerException)
        : base(message, innerException)
    {
    }
}

// ============================================================================
// Library load
// ============================================================================

/// <summary>
/// Raised when the native LingoFuse library cannot be located or loaded.
/// </summary>
/// <remarks>
/// Typical causes:
///   - the DLL / .so / .dylib is not next to the executable;
///   - it is not on the loader search path;
///   - it has an architecture mismatch (a 64-bit host trying to load a
///     32-bit library, or vice versa);
///   - a dependent native library (for example z_ipc_64.dll) is missing.
/// </remarks>
public sealed class LingoFuseLibraryLoadException : LingoFuseException
{
    /// <summary>The logical name of the library that failed to load.</summary>
    public string LibraryName { get; }

    /// <summary>Initialise with the library name that could not be loaded.</summary>
    public LingoFuseLibraryLoadException(string libraryName)
        : base($"Failed to load the LingoFuse native library '{libraryName}'.")
    {
        LibraryName = libraryName;
    }

    /// <summary>Initialise with a custom message and the library name.</summary>
    public LingoFuseLibraryLoadException(string libraryName, string message)
        : base(message)
    {
        LibraryName = libraryName;
    }

    /// <summary>
    /// Initialise with a custom message, the library name, and an inner
    /// exception.
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

// ============================================================================
// Remote call
// ============================================================================

/// <summary>
/// Raised when a remote Call fails: null handle from the native layer,
/// timeout, or an unreachable target application.
/// </summary>
/// <remarks>
/// The C ABI reports a failed Call as an empty handle (size 0), never as a
/// NULL pointer. This exception is the managed representation of that
/// failure, and it is also raised when the native layer itself returns a
/// NULL handle (indicating a more fundamental transport problem).
/// </remarks>
public sealed class LingoFuseCallException : LingoFuseException
{
    /// <summary>Name of the target application, when known.</summary>
    public string? TargetApp { get; }

    /// <summary>Name of the target API, when known.</summary>
    public string? TargetApi { get; }

    /// <summary>Initialise with a custom message.</summary>
    public LingoFuseCallException(string message)
        : base(message)
    {
    }

    /// <summary>
    /// Initialise with a custom message and the target identification.
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

// ============================================================================
// API registration
// ============================================================================

/// <summary>
/// Raised when an API registration request fails, typically because the
/// API name is already in use within the target application.
/// </summary>
public sealed class LingoFuseRegistrationException : LingoFuseException
{
    /// <summary>Name of the API that could not be registered.</summary>
    public string ApiName { get; }

    /// <summary>Initialise with the API name that failed to register.</summary>
    public LingoFuseRegistrationException(string apiName)
        : base($"Failed to register API '{apiName}': " +
               "the name is already in use or invalid.")
    {
        ApiName = apiName;
    }

    /// <summary>Initialise with a custom message and the API name.</summary>
    public LingoFuseRegistrationException(string apiName, string message)
        : base(message)
    {
        ApiName = apiName;
    }
}

// ============================================================================
// Object disposed
// ============================================================================

/// <summary>
/// Raised when an operation is attempted on an object that has already
/// been disposed.
/// </summary>
public sealed class LingoFuseObjectDisposedException : LingoFuseException
{
    /// <summary>Name of the disposed object (for diagnostics).</summary>
    public string ObjectName { get; }

    /// <summary>Initialise with the object name.</summary>
    public LingoFuseObjectDisposedException(string objectName)
        : base($"The {objectName} has already been disposed.")
    {
        ObjectName = objectName;
    }
}

// ============================================================================
// Invalid state
// ============================================================================

/// <summary>
/// Raised when the framework or a host object is used in an invalid
/// state: for example, calling <c>Start()</c> twice, or calling a method
/// that requires a live connection on a disconnected client.
/// </summary>
public sealed class LingoFuseStateException : LingoFuseException
{
    /// <summary>Initialise with a custom message.</summary>
    public LingoFuseStateException(string message)
        : base(message)
    {
    }
}

// ============================================================================
// I/O on a data handle
// ============================================================================

/// <summary>
/// Raised when a low-level I/O operation on a data handle fails: a short
/// read when the caller asked for a fixed number of bytes, or a short
/// write when the native layer accepted fewer bytes than requested.
/// </summary>
/// <remarks>
/// This exception is reserved for the byte-level contract of a data
/// handle. It is NOT raised for argument validation errors; those use
/// the standard .NET exceptions (<see cref="ArgumentNullException"/>,
/// <see cref="ArgumentOutOfRangeException"/>).
///
/// The <see cref="Operation"/> property names the failing operation
/// (for example "ReadInt32"), so a diagnostic handler can produce a
/// precise message without parsing the exception's text.
/// </remarks>
public sealed class LingoFuseIoException : LingoFuseException
{
    /// <summary>Name of the failing I/O operation, when known.</summary>
    public string? Operation { get; }

    /// <summary>Initialise with a custom message.</summary>
    public LingoFuseIoException(string message)
        : base(message)
    {
    }

    /// <summary>
    /// Initialise with a custom message and the name of the failing
    /// operation.
    /// </summary>
    public LingoFuseIoException(string message, string? operation)
        : base(message)
    {
        Operation = operation;
    }

    /// <summary>
    /// Initialise with a custom message, the name of the failing
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