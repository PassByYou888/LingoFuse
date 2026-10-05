# error.jl - Exception hierarchy for the LingoFuse Julia binding.
#
# Mirrors the error model of the Python binding (lingofuse.errors) and
# the C++ binding (lingofuse::Error). Every exception raised by this
# package derives from LingoFuseError, so a caller can install a single
# catch-all handler:
#
#     try
#         ...
#     catch e
#         e isa LingoFuseError || rethrow()
#         @error "LingoFuse failure" exception = e
#     end
#
# Design notes
# ------------
# - Each type carries structured fields (rather than a pre-formatted
#   message string) so that programmatic dispatch is possible without
#   parsing text.
#
# - Each type implements Base.showerror for human-readable display.
#
# - LingoFuseCallbackError stores the original thrown value as `Any`,
#   because a user callback may throw a non-Exception value (a string,
#   a number, or any Julia object).

"""
    LingoFuseError <: Exception

Base type for every exception raised by the LingoFuse Julia binding.

Catch this type to handle any failure originating from the binding.
"""
abstract type LingoFuseError <: Exception end

# ------------------------------------------------------------------ #
# Load-time failures                                                 #
# ------------------------------------------------------------------ #

"""
    LingoFuseLoadError <: LingoFuseError

Raised when a shared library cannot be located or loaded.

Fields
------
- `library_path::String`: the path the loader attempted to use.
- `message::String`:      a human-readable description of the failure.
"""
struct LingoFuseLoadError <: LingoFuseError
    library_path::String
    message::String
end

# ------------------------------------------------------------------ #
# Remote-call failures                                               #
# ------------------------------------------------------------------ #

"""
    LingoFuseCallError <: LingoFuseError

Raised when a remote Call fails: the native layer returned a null
handle, the target application was unreachable, or the caller supplied
an invalid argument.
"""
struct LingoFuseCallError <: LingoFuseError
    app_name::String
    message::String
end

"""
    LingoFuseTimeoutError <: LingoFuseError

Raised when a synchronous call exceeds its timeout budget.
"""
struct LingoFuseTimeoutError <: LingoFuseError
    app_name::String
    timeout_ms::UInt64
end

# ------------------------------------------------------------------ #
# Registration failures                                              #
# ------------------------------------------------------------------ #

"""
    LingoFuseRegistrationError <: LingoFuseError

Raised when an API name is already registered on the target
application, or when the native registration call otherwise fails.
"""
struct LingoFuseRegistrationError <: LingoFuseError
    app_name::String
    api_name::String
end

# ------------------------------------------------------------------ #
# Lifetime violations                                                #
# ------------------------------------------------------------------ #

"""
    LingoFuseObjectDisposedError <: LingoFuseError

Raised when a `DataHandle` or `App` is used after having been
disposed. All operations on a disposed handle throw this error; the
wrapper does not silently return a stale pointer.
"""
struct LingoFuseObjectDisposedError <: LingoFuseError
    object_kind::String
end

# ------------------------------------------------------------------ #
# I/O failures                                                       #
# ------------------------------------------------------------------ #

"""
    LingoFuseIoError <: LingoFuseError

Raised by the byte-level I/O layer when a read or write fails, when a
requested length is invalid, or when the handle position is out of
range.
"""
struct LingoFuseIoError <: LingoFuseError
    operation::String
    message::String
end

# ------------------------------------------------------------------ #
# Callback isolation                                                 #
# ------------------------------------------------------------------ #

"""
    LingoFuseCallbackError <: LingoFuseError

Wraps an exception raised inside a user callback. The original value
is preserved in `cause` so it can be inspected after being propagated
through the C shim's boundary.
"""
struct LingoFuseCallbackError <: LingoFuseError
    source::String
    cause::Any
end

# ------------------------------------------------------------------ #
# State violations                                                   #
# ------------------------------------------------------------------ #

"""
    LingoFuseStateError <: LingoFuseError

Raised when an operation is attempted at a point where the package
state does not permit it: for example, when the callback consumer is
required but not running, or when the Julia process was started with
an insufficient number of threads.
"""
struct LingoFuseStateError <: LingoFuseError
    message::String
end

# ------------------------------------------------------------------ #
# Human-readable display                                             #
# ------------------------------------------------------------------ #

Base.showerror(io::IO, e::LingoFuseLoadError) =
    print(io, "LingoFuseLoadError(", e.library_path, "): ", e.message)

Base.showerror(io::IO, e::LingoFuseCallError) =
    print(io, "LingoFuseCallError(", e.app_name, "): ", e.message)

Base.showerror(io::IO, e::LingoFuseTimeoutError) =
    print(io, "LingoFuseTimeoutError(", e.app_name,
          "): exceeded ", e.timeout_ms, " ms")

Base.showerror(io::IO, e::LingoFuseRegistrationError) =
    print(io, "LingoFuseRegistrationError(", e.app_name,
          "): API '", e.api_name, "' already registered")

Base.showerror(io::IO, e::LingoFuseObjectDisposedError) =
    print(io, "LingoFuseObjectDisposedError: ", e.object_kind,
          " has already been disposed")

Base.showerror(io::IO, e::LingoFuseIoError) =
    print(io, "LingoFuseIoError(", e.operation, "): ", e.message)

Base.showerror(io::IO, e::LingoFuseCallbackError) =
    print(io, "LingoFuseCallbackError(", e.source, "): ", e.cause)

Base.showerror(io::IO, e::LingoFuseStateError) =
    print(io, "LingoFuseStateError: ", e.message)