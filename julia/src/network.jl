# network.jl - Network preparation, lifecycle, and diagnostics.
#
# Mirrors the LF_Prepare* / LF_Exit* / LF_Shutdown / LF_Check* /
# LF_Set* / LF_Get* family from abi.jl and presents it with idiomatic
# Julia signatures:
#
#   - String arguments are typed as AbstractString.
#   - App handles are accepted as an `App` object or `nothing`.
#   - Boolean-valued LF_* return codes are converted to `Bool`.
#   - Tag-valued return codes are returned as `Cint` so callers can
#     inspect both the success case (tag >= 0) and the failure case
#     (tag == -1).
#
# The C ABI semantics are preserved exactly:
#
#   - `prepare_service` / `prepare_client` queue a preparation request.
#     The request is materialised when `prepare_done` runs.
#   - `prepare_done` blocks until the simulated main thread starts.
#     It returns 1 on the first successful call per process and 0 on
#     any subsequent call without an intervening `shutdown`.
#   - `exit_main_thread` stops the simulated main thread but does not
#     release resources. `shutdown` releases everything and is safe
#     to call multiple times.
#
# Blocking calls (prepare_done, exit_main_thread, shutdown) reach the
# native library through the @threadcall wrappers in abi.jl, so the
# calling Julia thread stays at a GC safepoint throughout.

# ================================================================== #
# Preparation                                                        #
# ================================================================== #

"""
    reset_prepare() -> Nothing

Clear any previously prepared services and clients.

Already running services and clients are not affected; only the
preparation queue is emptied. Call this before preparing a new set
to avoid duplicate-address errors from a previous run.
"""
function reset_prepare()::Nothing
    LF_ResetPrepare()
    return nothing
end

"""
    prepare_service(listening_addr::AbstractString,
                    physics_addr::AbstractString) -> Cint

Queue a C4 service for preparation.

- `listening_addr` is the local binding address (`"0.0.0.0:9898"` or
  `"ipc:name"`).
- `physics_addr` is the address advertised to clients. For IPC both
  are usually identical; for TCP they may differ when the service is
  behind NAT or binds a wildcard address.

Returns the internal tag ID (a small positive integer) on success,
or -1 for a duplicate or invalid address. The service is not
materialised until `prepare_done` runs.
"""
function prepare_service(listening_addr::AbstractString,
                         physics_addr::AbstractString)::Cint
    return LF_PrepareService(listening_addr, physics_addr)
end

"""
    prepare_client(physics_addr::AbstractString,
                   app::Union{App,Nothing} = nothing) -> Cint

Queue a C4 client for preparation.

- `physics_addr` is the address of the target service.
- `app` is the `App` to expose on the mesh, or `nothing` for a pure
  consumer.

Returns the internal tag ID on success, or -1 for a duplicate
address. The client is not materialised until `prepare_done` runs.

By default only one client per address is allowed. Set the
`Overlap_Connection` option to `"True"` via [`set_option`](@ref)
before this call to permit multiple clients on the same address.
"""
function prepare_client(physics_addr::AbstractString,
                        app::Union{App,Nothing} = nothing)::Cint
    h = app === nothing ? Ptr{Cvoid}(0) : app.handle
    return LF_PrepareClient(physics_addr, h)
end

"""
    prepare_done() -> Cint

Start the LingoFuse framework with all prepared services and clients.

Blocks until initialisation completes or the configured timeout
expires (default 30 seconds; see the `Wait_Connection_Timeout`
option). The call is dispatched through `@threadcall` so the
calling Julia thread stays at a GC safepoint.

Returns 1 on the first successful call per process. A subsequent
call without an intervening `shutdown` returns 0, which is not a
failure; it means the framework is already running.
"""
function prepare_done()::Cint
    return LF_PrepareDone()
end

# ================================================================== #
# Runtime options                                                    #
# ================================================================== #

"""
    set_option(option::AbstractString, value::AbstractString) -> Nothing

Adjust a global runtime option. Unknown option names are silently
ignored by the native layer.

Common options include:

    "Quiet"                    "True" / "False"
    "ConsoleOutput"            "True" / "False"
    "ShowThreadID"             "True" / "False"
    "Overlap_Connection"       "True" / "False"
    "Wait_Connection_ReadyOk"  "True" / "False"
    "Wait_Connection_Timeout"  milliseconds as a decimal string
    "Fixed_Sequenced_Time"     milliseconds as a decimal string

See the LingoFuse documentation for the complete list, including
the IPC_* and DataHandle_* options.
"""
function set_option(option::AbstractString,
                    value::AbstractString)::Nothing
    LF_SetOption(option, value)
    return nothing
end

# ================================================================== #
# Diagnostics and health checks                                      #
# ================================================================== #

"""
    check_main_thread() -> Bool

Return `true` when the simulated main thread is running.
"""
function check_main_thread()::Bool
    return LF_CheckMainThread() != 0
end

"""
    check_app(app_name::AbstractString) -> Bool

Probe whether an application with the given name is available.

The lookup uses a local cache updated by network broadcasts with a
propagation delay of about 3 seconds. The result is a diagnostic
probe, not an authoritative existence test: false negatives
immediately after registration and false positives shortly after
unregistration are both normal.
"""
function check_app(app_name::AbstractString)::Bool
    return LF_CheckApp(app_name) != 0
end

"""
    check_api(app_name::AbstractString,
              api_name::AbstractString) -> Bool

Probe whether the named API is available for the given application.
Same cache-based caveat as [`check_app`](@ref).
"""
function check_api(app_name::AbstractString,
                   api_name::AbstractString)::Bool
    return LF_CheckApi(app_name, api_name) != 0
end

"""
    generate_app_name() -> String

Generate a globally unique application name.

Must be called after `prepare_done` has returned 1; otherwise the
generated name lacks the C4 tunnel information and may not be
unique.

The native function returns a pointer valid for about 5 seconds.
This wrapper copies the string immediately, so the returned value
is safe to retain indefinitely.
"""
function generate_app_name()::String
    return LF_Generate_AppName()
end

"""
    get_app_name(app::App) -> String

Return the name of the given application handle. Same 5-second
validity rule as [`generate_app_name`](@ref); the wrapper copies
the string immediately.
"""
function get_app_name(app::App)::String
    return LF_Get_AppName(app.handle)
end

"""
    status_count() -> Int

Return the number of pending messages in the internal status queue.
The queue holds up to 1000 messages; older entries are dropped when
full.
"""
function status_count()::Int
    return Int(LF_GetStatusCount())
end

"""
    get_status() -> String

Return the next status message from the internal queue, or an empty
string when the queue is empty.

The native function returns a pointer into a static buffer that is
overwritten by the next call; the wrapper copies the string
immediately.
"""
function get_status()::String
    return LF_GetStatus()
end

"""
    post_status(msg::AbstractString) -> Nothing

Inject a user-supplied message into the status queue. The message is
queued even when the simulated main thread is not running; it
becomes observable once the main thread starts processing the
queue.
"""
function post_status(msg::AbstractString)::Nothing
    LF_PostStatus(msg)
    return nothing
end

# ================================================================== #
# Lifecycle                                                          #
# ================================================================== #

"""
    exit_main_thread() -> Nothing

Request the simulated main thread to exit. Blocks until the thread
has stopped; the call is dispatched through `@threadcall`.

Does not release resources. Call [`shutdown`](@ref) afterwards for a
full cleanup.

The native implementation also flushes the data handle pool,
releasing every outstanding handle, including permanent ones. Do
not use any data handle after this returns.
"""
function exit_main_thread()::Nothing
    LF_ExitMainThread()
    return nothing
end

"""
    shutdown() -> Nothing

Release all LingoFuse resources. Blocks until the release completes;
the call is dispatched through `@threadcall`.

Every data handle and application handle still alive becomes
invalid. Safe to call multiple times.

After `shutdown`, the framework can be re-initialised by calling
`reset_prepare` / `prepare_service` / `prepare_client` /
`prepare_done` again.
"""
function shutdown()::Nothing
    LF_Shutdown()
    return nothing
end

# ================================================================== #
# Exports                                                            #
# ================================================================== #

export reset_prepare,
       prepare_service,
       prepare_client,
       prepare_done,
       set_option,
       check_main_thread,
       check_app,
       check_api,
       generate_app_name,
       get_app_name,
       status_count,
       get_status,
       post_status,
       exit_main_thread,
       shutdown