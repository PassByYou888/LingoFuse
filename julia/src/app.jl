# app.jl - RAII wrapper around a native LingoFuse application handle.
#
# Responsibilities
# ----------------
#   - Own the native TAppHnd and release it on dispose!.
#   - Provide a Julia-friendly API for registering Call / Notify
#     endpoints, invoking them locally, and binding to clients.
#   - Hide the C shim's user_id machinery behind Julia closures.
#
# Warmup
# ------
# Every register_*! call performs a "warmup" invocation of the
# supplied handler on the main thread before returning. The warmup
# forces Julia to JIT-compile the handler and its dependencies,
# removing the risk of a first-invocation compilation happening on
# the callback consumer thread.
#
# This matters because the earlier iteration of this binding observed
# a hang when an anonymous closure was JIT-compiled for the first
# time on the consumer thread inside a callback. The mechanism was
# not fully identified, but the warmup eliminates it entirely, at a
# cost of one extra handler call at registration time.
#
# The warmup is best-effort: any exception it raises is swallowed,
# because a handler that refuses an empty payload must still be
# registrable. It can be disabled with `warmup = false`.
#
# IMPORTANT: the warmup calls the supplied handler with THREE synthetic
# payloads (see _warmup_handler below). Any SIDE EFFECT the handler
# performs during these calls is NOT suppressed. Handlers with
# observable side effects (logging, state mutation, I/O, network,
# database) must either tolerate being called with empty / small
# payloads, or be registered with `warmup = false`. See the docstrings
# of register_call! / register_notify! for the full contract.
#
# Two-stage destruction
# ---------------------
# dispose! calls LF_FreeApp, which detaches the application from all
# clients and stops its sequenced notification threads. The underlying
# native object remains in the global pool until LF_Shutdown is called;
# the Julia handle becomes invalid immediately.

# ------------------------------------------------------------------ #
# Struct and constructor                                             #
# ------------------------------------------------------------------ #

"""
    App(name::AbstractString, desc::AbstractString = "")

Create a new application with the given name and description.

The application name must be non-empty and is used for routing on the
mesh. Matching is case-insensitive at lookup time.

A finalizer is installed on the returned object; explicit `dispose!`
is strongly recommended for deterministic resource release.
"""
mutable struct App
    handle::Ptr{Cvoid}
    name::String
    disposed::Bool
end

function App(name::AbstractString, desc::AbstractString = "")
    isempty(name) && throw(ArgumentError("App name must be non-empty"))
    h = LF_CreateApp(name, desc)
    if h == C_NULL
        throw(LingoFuseRegistrationError(String(name), "<create>"))
    end
    obj = App(h, String(name), false)
    finalizer(_finalize_app!, obj)
    return obj
end

# Finalizer: do NOT modify any field and do NOT allocate.
function _finalize_app!(app::App)
    h = app.handle
    if h != C_NULL
        LF_FreeApp(h)
    end
    return
end

# ------------------------------------------------------------------ #
# Lifetime                                                           #
# ------------------------------------------------------------------ #

"""
    dispose!(app::App) -> Nothing

Detach the application from all clients and stop its sequenced
notification threads. Idempotent.

The underlying native object remains in the global pool until
`LF_Shutdown` is called; the handle is invalid after this returns.
"""
function dispose!(app::App)
    if app.disposed
        return nothing
    end
    app.disposed = true
    h = app.handle
    app.handle = C_NULL
    if h != C_NULL
        LF_FreeApp(h)
    end
    return nothing
end

"""
    is_disposed(app::App) -> Bool

Return `true` when the application has been detached.
"""
is_disposed(app::App)::Bool = app.disposed

function _ensure_valid(app::App)
    if app.disposed || app.handle == C_NULL
        throw(LingoFuseObjectDisposedError("App"))
    end
    return
end

# ------------------------------------------------------------------ #
# Identity                                                           #
# ------------------------------------------------------------------ #

"""
    app_name(app::App) -> String

Return the name supplied to the constructor.
"""
app_name(app::App)::String = app.name

# ------------------------------------------------------------------ #
# Warmup                                                             #
# ------------------------------------------------------------------ #
#
# A handler registered through the shim is invoked on the callback
# consumer thread. If Julia has not yet compiled that particular
# handler shape, the first invocation triggers compilation on the
# consumer thread.
#
# The warmup below forces compilation of the handler's invocation
# path on the CALLING thread, before the handler is handed to the
# shim. Three payload shapes are used, because the compiler may
# specialise differently for an empty vector, a tiny vector, and a
# moderately large vector:
#
#     UInt8[]                       empty Vector{UInt8}
#     UInt8[0x00, 0x01]             2-byte non-empty
#     zeros(UInt8, 256)             256-byte non-empty
#
# The invocation goes through Base.invokelatest for the same reason
# the consumer does: a handler defined inside a function body (for
# example, an anonymous closure created in a script) belongs to a
# world age newer than the one captured by any pre-existing task.
# Using invokelatest here is defensive and keeps the warmup path
# identical to the consumer path.
#
# The warmup is deliberately tolerant: any exception raised by a
# handler for a shape it does not expect is swallowed. A handler
# that refuses an empty payload must still be registrable; only the
# first *real* invocation matters for correctness.
#
# The warmup is also safe for Notify handlers, which accept the same
# single Vector{UInt8} argument and normally ignore their return
# value.

function _warmup_handler(handler::Function)
    payloads = (
        UInt8[],
        UInt8[0x00, 0x01],
        zeros(UInt8, 256),
    )
    for p in payloads
        try
            Base.invokelatest(handler, p)
        catch
            # Swallow: a handler that rejects an unexpected payload
            # shape is legitimate; the warmup exists only to force
            # compilation of the invocation path.
        end
    end
    return nothing
end

# ------------------------------------------------------------------ #
# API registration                                                   #
# ------------------------------------------------------------------ #

"""
    register_call!(app::App, api_name, desc, handler; warmup = true) -> Bool

Register a Call API whose handler receives the request payload as a
`Vector{UInt8}` and may return a `Vector{UInt8}` to produce a
response. Returning `nothing` or an empty vector produces an empty
response.

Returns `true` on success and `false` when the native layer rejects
the registration (typically a duplicate API name).

Warmup contract
---------------
When `warmup` is `true` (the default), the supplied handler is
invoked up to THREE times on the calling thread, with three synthetic
payloads (empty, two bytes, 256 bytes), before this function returns.
This forces JIT compilation ahead of time and avoids first-call
compilation on the callback consumer thread.

The warmup calls are best-effort with respect to exceptions: any
exception the handler raises during a warmup call is swallowed.

HOWEVER, SIDE EFFECTS OF THE WARMUP CALLS ARE NOT SUPPRESSED. If the
handler has observable side effects (logging, state mutation, I/O,
network access, database access), those effects will be produced up
to three times at registration. Handlers with side effects must
either tolerate being called with empty / small payloads, or be
registered with `warmup = false`.

Registration succeeds regardless of whether the warmup calls
themselves succeeded.
"""
function register_call!(app::App,
                        api_name::AbstractString,
                        desc::AbstractString,
                        handler::Function;
                        warmup::Bool = true)::Bool
    _ensure_valid(app)
    ok = register_call_with_handler(app.handle, api_name, desc, handler)
    if ok && warmup
        _warmup_handler(handler)
    end
    return ok
end

"""
    register_notify!(app::App, api_name, desc, handler; warmup = true) -> Bool

Register a Notify API whose handler receives the notification payload
as a `Vector{UInt8}`. The handler's return value is ignored.

See [`register_call!`](@ref) for the warmup semantics, including the
side-effect warning.
"""
function register_notify!(app::App,
                          api_name::AbstractString,
                          desc::AbstractString,
                          handler::Function;
                          warmup::Bool = true)::Bool
    _ensure_valid(app)
    ok = register_notify_with_handler(app.handle, api_name, desc, handler)
    if ok && warmup
        _warmup_handler(handler)
    end
    return ok
end

"""
    unregister!(app::App, api_name) -> Bool

Unregister an API by name. Returns `true` if the API was found and
removed, `false` otherwise. Local effect is immediate; the network
broadcast propagates within a few seconds.

Note that the Julia-side handler closure is retained until the
callback consumer is stopped; it is not released by this call. This
is an intentional choice: tracking which closure belongs to which
API name would require a second registry, and a closure is only a
small amount of memory. The registry is cleared on
`stop_callback_consumer`.
"""
function unregister!(app::App, api_name::AbstractString)::Bool
    _ensure_valid(app)
    return LF_Unregister(app.handle, api_name) == 1
end

# ------------------------------------------------------------------ #
# Local execution                                                    #
# ------------------------------------------------------------------ #

"""
    local_call(app::App, param::DataHandle) -> DataHandle

Invoke a Call API synchronously within the current process, bypassing
the network. The input handle is not consumed.

Returns a new `DataHandle` carrying the result. When the target API
is not registered the returned handle has size 0. The caller is
responsible for disposing the result.
"""
function local_call(app::App, param::DataHandle)::DataHandle
    _ensure_valid(app)
    _ensure_valid(param)
    h = LF_LocalCall(app.handle, param.handle)
    if h == C_NULL
        throw(LingoFuseCallError(app.name, "LF_LocalCall returned a null handle"))
    end
    return _wrap_data_handle(h, true)
end

"""
    local_notify(app::App, param::DataHandle) -> Nothing

Invoke a Notify API synchronously within the current process. The
input handle is not consumed.
"""
function local_notify(app::App, param::DataHandle)
    _ensure_valid(app)
    _ensure_valid(param)
    LF_LocalNotify(app.handle, param.handle)
    return nothing
end

# ------------------------------------------------------------------ #
# Client binding                                                     #
# ------------------------------------------------------------------ #

"""
    bind(app::App) -> Int

Bind the application to all currently unbound clients. Returns the
number of clients bound. Zero means no free client was available, or
the simulated main thread is not running.

This must be called after `LF_PrepareDone` has returned 1.
"""
function bind(app::App)::Int
    _ensure_valid(app)
    return Int(LF_BindApp(app.handle))
end

# ------------------------------------------------------------------ #
# Exports                                                            #
# ------------------------------------------------------------------ #

export App,
       dispose!,
       is_disposed,
       app_name,
       register_call!,
       register_notify!,
       unregister!,
       local_call,
       local_notify,
       bind