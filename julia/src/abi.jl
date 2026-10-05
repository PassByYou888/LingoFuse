# abi.jl - Raw ccall bindings for the 37 exported LF_* functions.
#
# See the original header comment in git history for the blocking
# classification rationale. This revision:
#
#   1. Promotes LF_LocalCall / LF_LocalNotify / LF_Notify /
#      LF_Sequenced_Notify to @threadcall. All four can trigger a
#      callback synchronously, and a callback running on the calling
#      Julia thread would stall the stop-the-world GC whenever the
#      consumer (or any other thread) allocates. This is the same
#      failure mode as SHIM_MECHANISM_GUIDE.md §4.5.
#
#   2. Adds trace output around every blocking call.
#
# Every wrapper uses LINGOFUSE_LIBRARY_PATH as its library argument.

const LF_UNKNOWN  = Cint(0)
const LF_CALL__   = Cint(1)
const LF_NOTIFY__ = Cint(2)

# ================================================================== #
# Data handle (10)                                                    #
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
# API registration (3)                                                #
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
# Local execution (2) - BLOCKING                                      #
# ================================================================== #
#
# Both functions invoke a registered callback synchronously on the
# calling thread. If the callback is a C shim trampoline, it blocks
# until the Julia consumer completes the event, and the Julia
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
# Remote invocation (3)                                               #
# ================================================================== #

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
# Options and diagnostics (7)                                         #
# ================================================================== #

function LF_SetOption(option::AbstractString,
                      value::AbstractString)::Cvoid
    return ccall((:LF_SetOption, LINGOFUSE_LIBRARY_PATH),
                 Cvoid, (Cstring, Cstring), option, value)
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
# Network events (1)                                                  #
# ================================================================== #

function LF_Set_Network_Event(on_connect::Ptr{Cvoid},
                              on_disconnect::Ptr{Cvoid})::Cvoid
    return ccall((:LF_Set_Network_Event, LINGOFUSE_LIBRARY_PATH),
                 Cvoid, (Ptr{Cvoid}, Ptr{Cvoid}),
                 on_connect, on_disconnect)
end

# ================================================================== #
# Exports                                                             #
# ================================================================== #

export LF_CreateData, LF_CreateData_Permanent, LF_FreeData,
       LF_GetBuffer, LF_WriteBuffer, LF_ReadBuffer,
       LF_GetPos, LF_SetPos, LF_GetSize, LF_SetSize,
       LF_CreateApp, LF_FreeApp, LF_Generate_AppName,
       LF_Get_AppName, LF_BindApp,
       LF_RegisterCall, LF_RegisterNotify, LF_Unregister,
       LF_LocalCall, LF_LocalNotify,
       LF_ResetPrepare, LF_PrepareService, LF_PrepareClient,
       LF_PrepareDone, LF_ExitMainThread,
       LF_Call, LF_Notify, LF_Sequenced_Notify,
       LF_SetOption, LF_GetStatusCount, LF_GetStatus, LF_PostStatus,
       LF_CheckMainThread, LF_CheckApp, LF_CheckApi,
       LF_Shutdown, LF_Set_Network_Event,
       LF_UNKNOWN, LF_CALL__, LF_NOTIFY__