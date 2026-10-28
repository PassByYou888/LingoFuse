# network.jl - Network preparation, lifecycle, and diagnostics.

function reset_prepare()::Nothing
    LF_ResetPrepare()
    return nothing
end

function prepare_service(listening_addr::AbstractString,
                         physics_addr::AbstractString)::Cint
    return LF_PrepareService(listening_addr, physics_addr)
end

function prepare_client(physics_addr::AbstractString,
                        app::Union{App,Nothing} = nothing)::Cint
    h = app === nothing ? Ptr{Cvoid}(0) : app.handle
    return LF_PrepareClient(physics_addr, h)
end

function prepare_done()::Cint
    return LF_PrepareDone()
end

function set_option(option::AbstractString,
                    value::AbstractString)::Nothing
    LF_SetOption(option, value)
    return nothing
end

function check_main_thread()::Bool
    return LF_CheckMainThread() != 0
end

function check_app(app_name::AbstractString)::Bool
    return LF_CheckApp(app_name) != 0
end

function check_api(app_name::AbstractString,
                   api_name::AbstractString)::Bool
    return LF_CheckApi(app_name, api_name) != 0
end

function check_uid(uid::NTuple{32, UInt8})::Bool
    return LF_Check_UID(uid) != 0
end

function check_uid_api(uid::NTuple{32, UInt8},
                       api_name::AbstractString)::Bool
    return LF_Check_UID_Api(uid, api_name) != 0
end

function check_p2pname(p2p_name::AbstractString)::Bool
    return LF_Check_P2PNAME(p2p_name) != 0
end

function check_p2pname_api(p2p_name::AbstractString,
                           api_name::AbstractString)::Bool
    return LF_Check_P2PNAME_Api(p2p_name, api_name) != 0
end

function generate_app_name()::String
    return LF_Generate_AppName()
end

function get_app_name(app::App)::String
    return LF_Get_AppName(app.handle)
end

function status_count()::Int
    return Int(LF_GetStatusCount())
end

function get_status()::String
    return LF_GetStatus()
end

function post_status(msg::AbstractString)::Nothing
    LF_PostStatus(msg)
    return nothing
end

function exit_main_thread()::Nothing
    LF_ExitMainThread()
    return nothing
end

function shutdown()::Nothing
    LF_Shutdown()
    return nothing
end

export reset_prepare,
       prepare_service,
       prepare_client,
       prepare_done,
       set_option,
       check_main_thread,
       check_app,
       check_api,
       check_uid,
       check_uid_api,
       check_p2pname,
       check_p2pname_api,
       generate_app_name,
       get_app_name,
       status_count,
       get_status,
       post_status,
       exit_main_thread,
       shutdown