# p2p.jl - Process-wide P2P API registration.
#
# The process-wide P2P namespace is INDEPENDENT of any App. APIs
# registered here are reachable via UID addressing and P2PName
# addressing ONLY. They are NOT reachable via App-name addressing.
#
# Lifetime: survives until LF_Shutdown / lf_shim_shutdown. Not torn
# down by LF_FreeApp. This is what makes P2P APIs suitable for
# globally-discoverable utility functions (health probes, whoami,
# capability discovery) that any client in the mesh can call by UID
# or by P2P group name.
#
# Comparison with app-bound registration (App.register_call!):
#
#                      App-bound          Process-wide P2P
#   Route via App name    yes                 no
#   Route via UID         yes                 yes
#   Route via P2PName     yes                 yes
#   Lifetime              App                 process
#   Registered via        App.register_*!     register_p2p_*!
#
# Both namespaces can hold an API with the same name; they do not
# conflict. A UID- or P2PName-addressed call searches the P2P
# namespace first, then the App-bound one.
#
# do-block calling convention
# ---------------------------
# Like the App registration functions, the P2P registration
# functions come in two flavours, selected by the type of the FIRST
# positional argument:
#
#   register_p2p_call!(api_name, desc, handler; warmup)
#       -- handler-last form
#
#   register_p2p_call!(handler, api_name, desc; warmup)
#       -- handler-first form, required by Julia's do-block syntax:
#
#              register_p2p_call!("health", "probe") do in_bytes
#                  ...
#              end
#
# Both forms are exactly equivalent.

# -------------------------------------------------------------------- #
# User-facing registration                                            #
# -------------------------------------------------------------------- #

"""
    register_p2p_call!(api_name, desc, handler; warmup = true) -> Bool

Register a process-wide P2P Call API.

The API becomes reachable via UID addressing and P2PName addressing
from any client in the mesh, without requiring the caller to know
the target App name. It is NOT reachable via App-name addressing,
even if the API name happens to match an App name.

Arguments:
    api_name    Unique API name within the process-wide P2P
                namespace.
    desc        Human-readable description.
    handler     The callback. Signature:
                    Function(Vector{UInt8}) -> Union{Vector{UInt8}, Nothing}
                It receives the request payload and may return a
                response payload. Returning `nothing` or an empty
                vector produces an empty response.

Returns `true` on success, `false` when the name is already
registered in the P2P namespace, or when the native layer rejects
the registration.

Warmup contract
---------------
When `warmup` is `true` (the default), the handler is invoked up to
THREE times on the calling thread, with three synthetic payloads
(empty, two bytes, 256 bytes), before this function returns. This
forces JIT compilation ahead of time and avoids first-call
compilation on the callback consumer thread.

The warmup calls are best-effort with respect to exceptions: any
exception the handler raises during a warmup call is swallowed.

SIDE EFFECTS OF THE WARMUP CALLS ARE NOT SUPPRESSED. If the handler
has observable side effects (logging, state mutation, I/O, network
access, database access), those effects will be produced up to
three times at registration. Handlers with side effects must either
tolerate being called with empty / small payloads, or be registered
with `warmup = false`.

Threading
---------
The handler runs on the callback consumer thread. It MUST NOT
block, and MUST NOT call any synchronous LingoFuse function
(call / notify / future / shutdown). Doing so will deadlock the
framework.
"""
function register_p2p_call!(api_name::AbstractString,
                            desc::AbstractString,
                            handler::Function;
                            warmup::Bool = true)::Bool
    isempty(api_name) &&
        throw(ArgumentError("P2P API name must be non-empty"))
    ok = register_p2p_call_with_handler(api_name, desc, handler)
    if ok && warmup
        _warmup_handler(handler)
    end
    return ok
end

"""
    register_p2p_call!(handler::Function, api_name, desc;
                       warmup = true) -> Bool

do-block variant of `register_p2p_call!`.

This method exists solely so that the idiomatic Julia do-block
syntax works:

    register_p2p_call!("health", "probe") do in_bytes
        ...
    end

The do-block rewrite places the trailing block as the FIRST
positional argument, so the dispatcher must see a `Function` there.
The arguments after the handler are the same as in the handler-last
form, in the same order: `(api_name, desc)`.

This method is exactly equivalent to the handler-last form.
"""
function register_p2p_call!(handler::Function,
                            api_name::AbstractString,
                            desc::AbstractString;
                            warmup::Bool = true)::Bool
    return register_p2p_call!(api_name, desc, handler;
                              warmup = warmup)
end

"""
    register_p2p_notify!(api_name, desc, handler; warmup = true) -> Bool

Register a process-wide P2P Notify API.

The API becomes reachable via UID addressing and P2PName addressing.
It is NOT reachable via App-name addressing.

Arguments:
    api_name    Unique API name within the process-wide P2P
                namespace.
    desc        Human-readable description.
    handler     The callback. Signature:
                    Function(Vector{UInt8}) -> Any
                The return value is ignored. See `register_p2p_call!`
                for the warmup contract and the threading rules.
"""
function register_p2p_notify!(api_name::AbstractString,
                              desc::AbstractString,
                              handler::Function;
                              warmup::Bool = true)::Bool
    isempty(api_name) &&
        throw(ArgumentError("P2P API name must be non-empty"))
    ok = register_p2p_notify_with_handler(api_name, desc, handler)
    if ok && warmup
        _warmup_handler(handler)
    end
    return ok
end

"""
    register_p2p_notify!(handler::Function, api_name, desc;
                         warmup = true) -> Bool

do-block variant of `register_p2p_notify!`. See the do-block variant
of `register_p2p_call!` for the full rationale.
"""
function register_p2p_notify!(handler::Function,
                              api_name::AbstractString,
                              desc::AbstractString;
                              warmup::Bool = true)::Bool
    return register_p2p_notify!(api_name, desc, handler;
                                warmup = warmup)
end

"""
    unregister_p2p!(api_name) -> Bool

Remove a previously registered process-wide P2P API.

The removal is immediate locally. Remote peers may still see the API
for up to ~3 seconds until the network broadcast propagates.

Returns `true` if the API was found and removed, `false` otherwise.

The Julia-side handler closure is retained until the callback
consumer is stopped; it is not released by this call. This matches
the App.unregister! behaviour. See app.jl for the rationale.
"""
function unregister_p2p!(api_name::AbstractString)::Bool
    isempty(api_name) && return false
    return shim_unregister_p2p(api_name)
end

# -------------------------------------------------------------------- #
# Internal: registration with a raw handler                           #
# -------------------------------------------------------------------- #
#
# These two functions touch the shim. They allocate a handler token
# from the shared registry (callback.jl's HANDLERS), register with
# the shim, and release the token if the shim rejects the
# registration.

function register_p2p_call_with_handler(name::AbstractString,
                                        desc::AbstractString,
                                        handler::Function)::Bool
    uid = _alloc_uid(handler)
    ok  = shim_register_p2p_call(name, desc, uid)
    ok || _release_uid(uid)
    return ok
end

function register_p2p_notify_with_handler(name::AbstractString,
                                          desc::AbstractString,
                                          handler::Function)::Bool
    uid = _alloc_uid(handler)
    ok  = shim_register_p2p_notify(name, desc, uid)
    ok || _release_uid(uid)
    return ok
end

# -------------------------------------------------------------------- #
# Exports                                                             #
# -------------------------------------------------------------------- #

export register_p2p_call!,
       register_p2p_notify!,
       unregister_p2p!,
       register_p2p_call_with_handler,
       register_p2p_notify_with_handler