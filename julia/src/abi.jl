# abi.jl - Raw ccall bindings for the 59 exported LF_* functions.
#
# See the original header comment in git history for the blocking
# classification rationale. This revision:
#
#   1. Extends the binding set from 37 to all 59 symbols exported by
#      LingoFuse.lpr, adding:
#         - 2 identity accessors: LF_Get_P2P_UID, LF_Get_P2P_Name
#         - 3 process-wide P2P registration functions
#         - 6 UID-addressed invocation primitives (Call / Async_Call /
#           Async_Sequenced_Call / Notify / Sequenced_Notify)
#         - 6 P2PName-addressed invocation primitives
#         - 6 async variants of the App-name family (Async_Call and
#           Async_Sequenced_Call; the other four App-name symbols were
#           already present in the 37-symbol set)
#         - 4 UID / P2PName health checks
#
#   2. Promotes LF_LocalCall / LF_LocalNotify / LF_Notify /
#      LF_Sequenced_Notify to @threadcall. All four can trigger a
#      callback synchronously (via local-first routing for Call /
#      Notify, or directly for LocalCall / LocalNotify), and a
#      callback running on the calling Julia thread would stall the
#      stop-the-world GC whenever the consumer (or any other thread)
#      allocates. This is the same failure mode as described in
#      c_ext/SHIM_MECHANISM_GUIDE.md §4.5.
#
#   3. Dispatches every synchronous remote invocation (LF_Call,
#      LF_UID_Call, LF_P2PNAME_Call) through @threadcall for the same
#      reason: the call blocks the calling thread until the response
#      arrives or the timeout expires.
#
#   4. Leaves the async primitives on plain ccall. They return
#      immediately after queueing the request; a plain ccall keeps the
#      per-call overhead negligible. The response is delivered later
#      by the C shim through the consumer event queue.
#
# Every wrapper uses LINGOFUSE_LIBRARY_PATH as its library argument.
#
# UID ABI note
# ------------
# The six UID-addressed primitives accept the UID BY VALUE. The C ABI
# declares the parameter as TP2P_UID___ (Pascal: array[0..31] of Byte).
# On x86-64, a >16-byte aggregate is classified MEMORY by the psABI
# and is passed on the stack; Julia's NTuple{32, UInt8} falls into the
# same ABI class, so a plain by-value argument is correct.

const LF_UNKNOWN  = Cint(0)
const LF_CALL__   = Cint(1)
const LF_NOTIFY__ = Cint(2)

# ================================================================== #
# Data handle (12)                                                    #
# ================================================================== #

function LF_CreateData(method_name::AbstractString)::Ptr{Cvoid}
    return ccall((:LF_CreateData, LINGOFUSE_LIBRARY_PATH),
                 Ptr{Cvoid}, (Cstring,), method_name)
end

function LF_CreateData_Permanent(method_name::AbstractString)::Ptr{Cvoid}
    return ccall((:LF_CreateData_Permanent, LINGOFUSE_LIBRARY_PATH),
                 Ptr{Cvoid}, (Cstring,), method_name)
end

function LF_FreeData(hnd::Ptr{Cvoid})::Cvoid
    return ccall((:LF_FreeData, LINGOFUSE_LIBRARY_PATH),
                 Cvoid, (Ptr{Cvoid},), hnd)
end

function LF_GetBuffer(hnd::Ptr{Cvoid})::Ptr{Cvoid}
    return ccall((:LF_GetBuffer, LINGOFUSE_LIBRARY_PATH),
                 Ptr{Cvoid}, (Ptr{Cvoid},), hnd)
end

function LF_WriteBuffer(hnd::Ptr{Cvoid},
                        buff::Ptr{UInt8},
                        size::Int64)::Int64
    return ccall((:LF_WriteBuffer, LINGOFUSE_LIBRARY_PATH),
                 Int64,
                 (Ptr{Cvoid}, Ptr{UInt8}, Int64),
                 hnd, buff, size)
end

function LF_ReadBuffer(hnd::Ptr{Cvoid},
                       buff::Ptr{UInt8},
                       size::Int64)::Int64
    return ccall((:LF_ReadBuffer, LINGOFUSE_LIBRARY_PATH),
                 Int64,
                 (Ptr{Cvoid}, Ptr{UInt8}, Int64),
                 hnd, buff, size)
end

function LF_GetPos(hnd::Ptr{Cvoid})::Int64
    return ccall((:LF_GetPos, LINGOFUSE_LIBRARY_PATH),
                 Int64, (Ptr{Cvoid},), hnd)
end

function LF_SetPos(hnd::Ptr{Cvoid}, pos::Int64)::Cvoid
    return ccall((:LF_SetPos, LINGOFUSE_LIBRARY_PATH),
                 Cvoid, (Ptr{Cvoid}, Int64), hnd, pos)
end

function LF_GetSize(hnd::Ptr{Cvoid})::Int64
    return ccall((:LF_GetSize, LINGOFUSE_LIBRARY_PATH),
                 Int64, (Ptr{Cvoid},), hnd)
end

function LF_SetSize(hnd::Ptr{Cvoid}, size::Int64)::Cvoid
    return ccall((:LF_SetSize, LINGOFUSE_LIBRARY_PATH),
                 Cvoid, (Ptr{Cvoid}, Int64), hnd, size)
end

# ------------------------------------------------------------------ #
# Identity accessors (2)                                              #
# ------------------------------------------------------------------ #
#
# Both read "side data" written into the payload header by the SENDER's
# transport layer. They are meaningful ONLY on the input handle of a
# registered callback; on any other handle (an output handle, or a
# handle the caller created itself) the C side logs a warning and
# returns a zero UID / empty string.
#
# LF_Get_P2P_UID returns a POINTER to a 32-byte UID
# (Pascal: function ... : PP2P_UID___ = ^TUID___).
# The pointer is allocated by the C side and scheduled for automatic
# release about 5 seconds after the call. The caller MUST copy the 32
# bytes immediately and MUST NOT free the pointer.
#
# LF_Get_P2P_Name returns a pointer to a NUL-terminated UTF-8 string,
# also released ~5 seconds after the call. unsafe_string copies the
# bytes into a fresh Julia String before the wrapper returns, so the
# Julia-side value is safe to retain indefinitely.

function LF_Get_P2P_UID(hnd::Ptr{Cvoid})::Ptr{LFShimUID}
    return ccall((:LF_Get_P2P_UID, LINGOFUSE_LIBRARY_PATH),
                 Ptr{LFShimUID}, (Ptr{Cvoid},), hnd)
end

function LF_Get_P2P_Name(hnd::Ptr{Cvoid})::String
    p = ccall((:LF_Get_P2P_Name, LINGOFUSE_LIBRARY_PATH),
              Ptr{UInt8}, (Ptr{Cvoid},), hnd)
    p == C_NULL && return ""
    return unsafe_string(p)
end

# ================================================================== #
# Application handle (5)                                              #
# ================================================================== #

function LF_CreateApp(app_name::AbstractString,
                      desc::AbstractString)::Ptr{Cvoid}
    return ccall((:LF_CreateApp, LINGOFUSE_LIBRARY_PATH),
                 Ptr{Cvoid}, (Cstring, Cstring), app_name, desc)
end

function LF_FreeApp(app_hnd::Ptr{Cvoid})::Cvoid
    return ccall((:LF_FreeApp, LINGOFUSE_LIBRARY_PATH),
                 Cvoid, (Ptr{Cvoid},), app_hnd)
end

function LF_Generate_AppName()::String
    p = ccall((:LF_Generate_AppName, LINGOFUSE_LIBRARY_PATH),
              Ptr{UInt8}, ())
    p == C_NULL && return ""
    return unsafe_string(p)
end

function LF_Get_AppName(app_hnd::Ptr{Cvoid})::String
    p = ccall((:LF_Get_AppName, LINGOFUSE_LIBRARY_PATH),
              Ptr{UInt8}, (Ptr{Cvoid},), app_hnd)
    p == C_NULL && return ""
    return unsafe_string(p)
end

function LF_BindApp(app_hnd::Ptr{Cvoid})::Cint
    return ccall((:LF_BindApp, LINGOFUSE_LIBRARY_PATH),
                 Cint, (Ptr{Cvoid},), app_hnd)
end

# ================================================================== #
# API registration - app-bound (3)                                    #
# ================================================================== #

function LF_RegisterCall(app_hnd::Ptr{Cvoid},
                         name::AbstractString,
                         desc::AbstractString,
                         trigger::Ptr{Cvoid},
                         callback::Ptr{Cvoid})::Cint
    return ccall((:LF_RegisterCall, LINGOFUSE_LIBRARY_PATH),
                 Cint,
                 (Ptr{Cvoid}, Cstring, Cstring, Ptr{Cvoid}, Ptr{Cvoid}),
                 app_hnd, name, desc, trigger, callback)
end

function LF_RegisterNotify(app_hnd::Ptr{Cvoid},
                           name::AbstractString,
                           desc::AbstractString,
                           trigger::Ptr{Cvoid},
                           callback::Ptr{Cvoid})::Cint
    return ccall((:LF_RegisterNotify, LINGOFUSE_LIBRARY_PATH),
                 Cint,
                 (Ptr{Cvoid}, Cstring, Cstring, Ptr{Cvoid}, Ptr{Cvoid}),
                 app_hnd, name, desc, trigger, callback)
end

function LF_Unregister(app_hnd::Ptr{Cvoid},
                       name::AbstractString)::Cint
    return ccall((:LF_Unregister, LINGOFUSE_LIBRARY_PATH),
                 Cint, (Ptr{Cvoid}, Cstring), app_hnd, name)
end

# ================================================================== #
# API registration - process-wide P2P (3)                             #
# ================================================================== #
#
# The P2P namespace is INDEPENDENT of any App. APIs registered here
# are reachable via UID addressing and P2PName addressing ONLY. They
# are NOT reachable via App-name addressing.
#
# Lifetime: survives until LF_Shutdown. Not torn down by LF_FreeApp.

function LF_Register_P2P_Call(name::AbstractString,
                              desc::AbstractString,
                              trigger::Ptr{Cvoid},
                              callback::Ptr{Cvoid})::Cint
    return ccall((:LF_Register_P2P_Call, LINGOFUSE_LIBRARY_PATH),
                 Cint,
                 (Cstring, Cstring, Ptr{Cvoid}, Ptr{Cvoid}),
                 name, desc, trigger, callback)
end

function LF_Register_P2P_Notify(name::AbstractString,
                                desc::AbstractString,
                                trigger::Ptr{Cvoid},
                                callback::Ptr{Cvoid})::Cint
    return ccall((:LF_Register_P2P_Notify, LINGOFUSE_LIBRARY_PATH),
                 Cint,
                 (Cstring, Cstring, Ptr{Cvoid}, Ptr{Cvoid}),
                 name, desc, trigger, callback)
end

function LF_Unregister_P2P(name::AbstractString)::Cint
    return ccall((:LF_Unregister_P2P, LINGOFUSE_LIBRARY_PATH),
                 Cint, (Cstring,), name)
end

# ================================================================== #
# Local execution (2) - BLOCKING                                      #
# ================================================================== #
#
# Both functions invoke a registered callback synchronously on the
# calling thread. The callback is the C shim's trampoline, which
# blocks until the Julia consumer completes the event; the Julia
# consumer allocates Julia heap objects while it works. The calling
# thread must therefore be at a safepoint for the duration, i.e. it
# must be inside @threadcall, not a plain ccall.

function LF_LocalCall(app_hnd::Ptr{Cvoid},
                      param::Ptr{Cvoid})::Ptr{Cvoid}
    trace("abi: LF_LocalCall ENTER")
    r = @threadcall((:LF_LocalCall, LINGOFUSE_LIBRARY_PATH),
                    Ptr{Cvoid},
                    (Ptr{Cvoid}, Ptr{Cvoid}),
                    app_hnd, param)
    trace("abi: LF_LocalCall EXIT  result=$(r)")
    return r
end

function LF_LocalNotify(app_hnd::Ptr{Cvoid},
                        param::Ptr{Cvoid})::Cvoid
    trace("abi: LF_LocalNotify ENTER")
    @threadcall((:LF_LocalNotify, LINGOFUSE_LIBRARY_PATH),
                Cvoid,
                (Ptr{Cvoid}, Ptr{Cvoid}),
                app_hnd, param)
    trace("abi: LF_LocalNotify EXIT")
    return nothing
end

# ================================================================== #
# Network preparation (5)                                             #
# ================================================================== #

function LF_ResetPrepare()::Cvoid
    return ccall((:LF_ResetPrepare, LINGOFUSE_LIBRARY_PATH), Cvoid, ())
end

function LF_PrepareService(listening_addr::AbstractString,
                           physics_addr::AbstractString)::Cint
    return ccall((:LF_PrepareService, LINGOFUSE_LIBRARY_PATH),
                 Cint, (Cstring, Cstring),
                 listening_addr, physics_addr)
end

function LF_PrepareClient(physics_addr::AbstractString,
                          app_hnd::Ptr{Cvoid})::Cint
    return ccall((:LF_PrepareClient, LINGOFUSE_LIBRARY_PATH),
                 Cint, (Cstring, Ptr{Cvoid}), physics_addr, app_hnd)
end

function LF_PrepareDone()::Cint
    trace("abi: LF_PrepareDone ENTER")
    r = @threadcall((:LF_PrepareDone, LINGOFUSE_LIBRARY_PATH),
                    Cint, ())
    trace("abi: LF_PrepareDone EXIT  result=$(r)")
    return r
end

function LF_ExitMainThread()::Cvoid
    trace("abi: LF_ExitMainThread ENTER")
    @threadcall((:LF_ExitMainThread, LINGOFUSE_LIBRARY_PATH), Cvoid, ())
    trace("abi: LF_ExitMainThread EXIT")
    return nothing
end

# ================================================================== #
# Remote invocation - app-name addressing (5)                         #
# ================================================================== #
#
# LF_Call blocks until the response arrives or the timeout expires,
# so it goes through @threadcall. LF_Notify / LF_Sequenced_Notify can
# trigger a callback synchronously when the target App is hosted in
# this process (local-first routing), so they also go through
# @threadcall.
#
# LF_Async_Call / LF_Async_Sequenced_Call return immediately; a plain
# ccall is correct and keeps the per-call overhead negligible. The
# response is delivered later by the C shim.

function LF_Call(app_name::AbstractString,
                 param::Ptr{Cvoid},
                 timeout_ms::UInt64)::Ptr{Cvoid}
    trace("abi: LF_Call ENTER  app=$(app_name)")
    name_str = String(app_name)
    name_ptr = Base.unsafe_convert(Ptr{UInt8}, name_str)
    r = GC.@preserve name_str begin
        @threadcall((:LF_Call, LINGOFUSE_LIBRARY_PATH),
                    Ptr{Cvoid},
                    (Ptr{UInt8}, Ptr{Cvoid}, UInt64),
                    name_ptr, param, timeout_ms)
    end
    trace("abi: LF_Call EXIT  result=$(r)")
    return r
end

function LF_Async_Call(app_name::AbstractString,
                       param::Ptr{Cvoid},
                       data::Ptr{Cvoid},
                       callback::Ptr{Cvoid})::Cint
    return ccall((:LF_Async_Call, LINGOFUSE_LIBRARY_PATH),
                 Cint,
                 (Cstring, Ptr{Cvoid}, Ptr{Cvoid}, Ptr{Cvoid}),
                 app_name, param, data, callback)
end

function LF_Async_Sequenced_Call(app_name::AbstractString,
                                 param::Ptr{Cvoid},
                                 data::Ptr{Cvoid},
                                 callback::Ptr{Cvoid})::Cint
    return ccall((:LF_Async_Sequenced_Call, LINGOFUSE_LIBRARY_PATH),
                 Cint,
                 (Cstring, Ptr{Cvoid}, Ptr{Cvoid}, Ptr{Cvoid}),
                 app_name, param, data, callback)
end

function LF_Notify(app_name::AbstractString,
                   param::Ptr{Cvoid})::Cvoid
    trace("abi: LF_Notify ENTER  app=$(app_name)")
    name_str = String(app_name)
    name_ptr = Base.unsafe_convert(Ptr{UInt8}, name_str)
    GC.@preserve name_str begin
        @threadcall((:LF_Notify, LINGOFUSE_LIBRARY_PATH),
                    Cvoid,
                    (Ptr{UInt8}, Ptr{Cvoid}),
                    name_ptr, param)
    end
    trace("abi: LF_Notify EXIT")
    return nothing
end

function LF_Sequenced_Notify(app_name::AbstractString,
                             param::Ptr{Cvoid})::Cvoid
    trace("abi: LF_Sequenced_Notify ENTER  app=$(app_name)")
    name_str = String(app_name)
    name_ptr = Base.unsafe_convert(Ptr{UInt8}, name_str)
    GC.@preserve name_str begin
        @threadcall((:LF_Sequenced_Notify, LINGOFUSE_LIBRARY_PATH),
                    Cvoid,
                    (Ptr{UInt8}, Ptr{Cvoid}),
                    name_ptr, param)
    end
    trace("abi: LF_Sequenced_Notify EXIT")
    return nothing
end

# ================================================================== #
# Remote invocation - UID addressing (5)                              #
# ================================================================== #
#
# The UID is passed BY VALUE. LF_UID_Call blocks; the four Notify /
# Async primitives do not.
#
# UID routing is local-first, matching app-name routing. A UID can
# address ANY API registered on the target -- whether app-bound or
# process-wide -- without the caller knowing the target App name.

function LF_UID_Call(uid::LFShimUID,
                     param::Ptr{Cvoid},
                     timeout_ms::UInt64)::Ptr{Cvoid}
    trace("abi: LF_UID_Call ENTER  uid=$(uid_to_hex(uid))")
    r = @threadcall((:LF_UID_Call, LINGOFUSE_LIBRARY_PATH),
                    Ptr{Cvoid},
                    (LFShimUID, Ptr{Cvoid}, UInt64),
                    uid, param, timeout_ms)
    trace("abi: LF_UID_Call EXIT  result=$(r)")
    return r
end

function LF_UID_Async_Call(uid::LFShimUID,
                           param::Ptr{Cvoid},
                           data::Ptr{Cvoid},
                           callback::Ptr{Cvoid})::Cint
    return ccall((:LF_UID_Async_Call, LINGOFUSE_LIBRARY_PATH),
                 Cint,
                 (LFShimUID, Ptr{Cvoid}, Ptr{Cvoid}, Ptr{Cvoid}),
                 uid, param, data, callback)
end

function LF_UID_Async_Sequenced_Call(uid::LFShimUID,
                                     param::Ptr{Cvoid},
                                     data::Ptr{Cvoid},
                                     callback::Ptr{Cvoid})::Cint
    return ccall((:LF_UID_Async_Sequenced_Call, LINGOFUSE_LIBRARY_PATH),
                 Cint,
                 (LFShimUID, Ptr{Cvoid}, Ptr{Cvoid}, Ptr{Cvoid}),
                 uid, param, data, callback)
end

function LF_UID_Notify(uid::LFShimUID,
                       param::Ptr{Cvoid})::Cvoid
    trace("abi: LF_UID_Notify ENTER  uid=$(uid_to_hex(uid))")
    @threadcall((:LF_UID_Notify, LINGOFUSE_LIBRARY_PATH),
                Cvoid,
                (LFShimUID, Ptr{Cvoid}),
                uid, param)
    trace("abi: LF_UID_Notify EXIT")
    return nothing
end

function LF_UID_Sequenced_Notify(uid::LFShimUID,
                                 param::Ptr{Cvoid})::Cvoid
    trace("abi: LF_UID_Sequenced_Notify ENTER  uid=$(uid_to_hex(uid))")
    @threadcall((:LF_UID_Sequenced_Notify, LINGOFUSE_LIBRARY_PATH),
                Cvoid,
                (LFShimUID, Ptr{Cvoid}),
                uid, param)
    trace("abi: LF_UID_Sequenced_Notify EXIT")
    return nothing
end

# ================================================================== #
# Remote invocation - P2PName addressing (5)                          #
# ================================================================== #
#
# P2PName routing is NOT local-first: even when the caller process
# itself hosts a client in the target group, the call is forwarded to
# the server for dispatch. The server owns the load-balancing state.

function LF_P2PNAME_Call(p2p_name::AbstractString,
                         param::Ptr{Cvoid},
                         timeout_ms::UInt64)::Ptr{Cvoid}
    trace("abi: LF_P2PNAME_Call ENTER  group=$(p2p_name)")
    name_str = String(p2p_name)
    name_ptr = Base.unsafe_convert(Ptr{UInt8}, name_str)
    r = GC.@preserve name_str begin
        @threadcall((:LF_P2PNAME_Call, LINGOFUSE_LIBRARY_PATH),
                    Ptr{Cvoid},
                    (Ptr{UInt8}, Ptr{Cvoid}, UInt64),
                    name_ptr, param, timeout_ms)
    end
    trace("abi: LF_P2PNAME_Call EXIT  result=$(r)")
    return r
end

function LF_P2PNAME_Async_Call(p2p_name::AbstractString,
                               param::Ptr{Cvoid},
                               data::Ptr{Cvoid},
                               callback::Ptr{Cvoid})::Cint
    return ccall((:LF_P2PNAME_Async_Call, LINGOFUSE_LIBRARY_PATH),
                 Cint,
                 (Cstring, Ptr{Cvoid}, Ptr{Cvoid}, Ptr{Cvoid}),
                 p2p_name, param, data, callback)
end

function LF_P2PNAME_Async_Sequenced_Call(p2p_name::AbstractString,
                                         param::Ptr{Cvoid},
                                         data::Ptr{Cvoid},
                                         callback::Ptr{Cvoid})::Cint
    return ccall((:LF_P2PNAME_Async_Sequenced_Call,
                  LINGOFUSE_LIBRARY_PATH),
                 Cint,
                 (Cstring, Ptr{Cvoid}, Ptr{Cvoid}, Ptr{Cvoid}),
                 p2p_name, param, data, callback)
end

function LF_P2PNAME_Notify(p2p_name::AbstractString,
                           param::Ptr{Cvoid})::Cvoid
    trace("abi: LF_P2PNAME_Notify ENTER  group=$(p2p_name)")
    name_str = String(p2p_name)
    name_ptr = Base.unsafe_convert(Ptr{UInt8}, name_str)
    GC.@preserve name_str begin
        @threadcall((:LF_P2PNAME_Notify, LINGOFUSE_LIBRARY_PATH),
                    Cvoid,
                    (Ptr{UInt8}, Ptr{Cvoid}),
                    name_ptr, param)
    end
    trace("abi: LF_P2PNAME_Notify EXIT")
    return nothing
end

function LF_P2PNAME_Sequenced_Notify(p2p_name::AbstractString,
                                     param::Ptr{Cvoid})::Cvoid
    trace("abi: LF_P2PNAME_Sequenced_Notify ENTER  group=$(p2p_name)")
    name_str = String(p2p_name)
    name_ptr = Base.unsafe_convert(Ptr{UInt8}, name_str)
    GC.@preserve name_str begin
        @threadcall((:LF_P2PNAME_Sequenced_Notify,
                     LINGOFUSE_LIBRARY_PATH),
                    Cvoid,
                    (Ptr{UInt8}, Ptr{Cvoid}),
                    name_ptr, param)
    end
    trace("abi: LF_P2PNAME_Sequenced_Notify EXIT")
    return nothing
end

# ================================================================== #
# Options and diagnostics (2 + 3 = 5)                                 #
# ================================================================== #

function LF_SetOption(option::AbstractString,
                      value::AbstractString)::Cvoid
    return ccall((:LF_SetOption, LINGOFUSE_LIBRARY_PATH),
                 Cvoid, (Cstring, Cstring), option, value)
end

function LF_GetOption(option::AbstractString)::String
    p = ccall((:LF_GetOption, LINGOFUSE_LIBRARY_PATH),
              Ptr{UInt8}, (Cstring,), option)
    p == C_NULL && return ""
    return unsafe_string(p)
end

function LF_GetStatusCount()::Cint
    return ccall((:LF_GetStatusCount, LINGOFUSE_LIBRARY_PATH), Cint, ())
end

function LF_GetStatus()::String
    p = ccall((:LF_GetStatus, LINGOFUSE_LIBRARY_PATH), Ptr{UInt8}, ())
    p == C_NULL && return ""
    return unsafe_string(p)
end

function LF_PostStatus(status::AbstractString)::Cvoid
    return ccall((:LF_PostStatus, LINGOFUSE_LIBRARY_PATH),
                 Cvoid, (Cstring,), status)
end

# ================================================================== #
# Health checks (7)                                                   #
# ================================================================== #

function LF_CheckMainThread()::Cint
    return ccall((:LF_CheckMainThread, LINGOFUSE_LIBRARY_PATH), Cint, ())
end

function LF_CheckApp(app_name::AbstractString)::Cint
    return ccall((:LF_CheckApp, LINGOFUSE_LIBRARY_PATH),
                 Cint, (Cstring,), app_name)
end

function LF_CheckApi(app_name::AbstractString,
                     api_name::AbstractString)::Cint
    return ccall((:LF_CheckApi, LINGOFUSE_LIBRARY_PATH),
                 Cint, (Cstring, Cstring), app_name, api_name)
end

function LF_Check_UID(uid::LFShimUID)::Cint
    return ccall((:LF_Check_UID, LINGOFUSE_LIBRARY_PATH),
                 Cint, (LFShimUID,), uid)
end

function LF_Check_UID_Api(uid::LFShimUID,
                          api_name::AbstractString)::Cint
    return ccall((:LF_Check_UID_Api, LINGOFUSE_LIBRARY_PATH),
                 Cint, (LFShimUID, Cstring), uid, api_name)
end

function LF_Check_P2PNAME(p2p_name::AbstractString)::Cint
    return ccall((:LF_Check_P2PNAME, LINGOFUSE_LIBRARY_PATH),
                 Cint, (Cstring,), p2p_name)
end

function LF_Check_P2PNAME_Api(p2p_name::AbstractString,
                              api_name::AbstractString)::Cint
    return ccall((:LF_Check_P2PNAME_Api, LINGOFUSE_LIBRARY_PATH),
                 Cint, (Cstring, Cstring), p2p_name, api_name)
end

# ================================================================== #
# Network events (1)                                                  #
# ================================================================== #

function LF_Set_Network_Event(on_connect::Ptr{Cvoid},
                              on_disconnect::Ptr{Cvoid})::Cvoid
    return ccall((:LF_Set_Network_Event, LINGOFUSE_LIBRARY_PATH),
                 Cvoid, (Ptr{Cvoid}, Ptr{Cvoid}),
                 on_connect, on_disconnect)
end

# ================================================================== #
# Shutdown (1)                                                        #
# ================================================================== #

function LF_Shutdown()::Cvoid
    trace("abi: LF_Shutdown ENTER")
    @threadcall((:LF_Shutdown, LINGOFUSE_LIBRARY_PATH), Cvoid, ())
    trace("abi: LF_Shutdown EXIT")
    return nothing
end

# ================================================================== #
# Exports                                                             #
# ================================================================== #

export LF_CreateData, LF_CreateData_Permanent, LF_FreeData,
       LF_GetBuffer, LF_WriteBuffer, LF_ReadBuffer,
       LF_GetPos, LF_SetPos, LF_GetSize, LF_SetSize,
       LF_Get_P2P_UID, LF_Get_P2P_Name,
       LF_CreateApp, LF_FreeApp, LF_Generate_AppName,
       LF_Get_AppName, LF_BindApp,
       LF_RegisterCall, LF_RegisterNotify, LF_Unregister,
       LF_Register_P2P_Call, LF_Register_P2P_Notify, LF_Unregister_P2P,
       LF_LocalCall, LF_LocalNotify,
       LF_ResetPrepare, LF_PrepareService, LF_PrepareClient,
       LF_PrepareDone, LF_ExitMainThread,
       LF_Call, LF_Async_Call, LF_Async_Sequenced_Call,
       LF_Notify, LF_Sequenced_Notify,
       LF_UID_Call, LF_UID_Async_Call, LF_UID_Async_Sequenced_Call,
       LF_UID_Notify, LF_UID_Sequenced_Notify,
       LF_P2PNAME_Call, LF_P2PNAME_Async_Call,
       LF_P2PNAME_Async_Sequenced_Call,
       LF_P2PNAME_Notify, LF_P2PNAME_Sequenced_Notify,
       LF_CheckMainThread, LF_CheckApp, LF_CheckApi,
       LF_Check_UID, LF_Check_UID_Api,
       LF_Check_P2PNAME, LF_Check_P2PNAME_Api,
       LF_SetOption, LF_GetOption,
       LF_GetStatusCount, LF_GetStatus, LF_PostStatus,
       LF_Set_Network_Event,
       LF_Shutdown,
       LF_UNKNOWN, LF_CALL__, LF_NOTIFY__