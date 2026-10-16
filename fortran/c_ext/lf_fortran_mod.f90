! =============================================================================
! lf_fortran_mod.f90
!
! Fortran module binding the C ABI declared in lf_fortran.h.
!
! =============================================================================
! DESIGN
! =============================================================================
!
!   - All C types are accessed through iso_c_binding.
!   - All handles are `type(c_ptr)`.
!   - Fortran strings (default `character(len=*)`) are converted to
!     NUL-terminated c_char arrays internally, so the user never has
!     to build a C string by hand.
!   - Read operations that produce text use an `allocatable character`
!     result and query the buffer size first, so the user never has to
!     guess a buffer length.
!   - Callbacks are plain Fortran procedures with `bind(C)`. The user
!     obtains their address with `c_funloc` and passes the resulting
!     `type(c_funptr)` to the registration routine.
!
! =============================================================================
! UID REPRESENTATION
! =============================================================================
!
! A LingoFuse session UID is a 32-byte binary value. On the Fortran
! side it is represented as:
!
!     integer(c_int8_t) :: uid(LF_UID_BYTE_COUNT)
!
! The `c_int8_t` element type is the only portable 8-bit integer type
! in Fortran. Signedness is irrelevant: the UID is treated as an
! opaque byte sequence throughout.
!
! Use the exported constant `LF_UID_BYTE_COUNT` (= 32) for the array
! bound. The helper `lf_uid_to_hex` / `lf_uid_from_hex` translate
! between the byte array and a 64-character lowercase hex string, which
! is convenient for logging, tracing, and cross-process identity
! exchange.
!
! =============================================================================
! ASYNCHRONOUS CALLBACKS
! =============================================================================
!
! Fortran has no anonymous functions and no lambdas. A `bind(C)`
! callback must be a module procedure (or an external procedure) that
! is visible at the call site. The registration pattern is therefore:
!
!     1. Declare the callback in a module (or in the program's
!        `contains` section) with `bind(C)`.
!     2. Pass its address to the registration routine with
!        `c_funloc(...)`.
!
! Example:
!
!     module my_handlers
!       use iso_c_binding
!       use lf_fortran_mod
!       implicit none
!       private
!       public :: on_result
!     contains
!       subroutine on_result(user_data, result) bind(C)
!         type(c_ptr), value :: user_data, result
!         ! business logic here
!       end subroutine
!     end module
!
!     ! ... in the program ...
!     use my_handlers
!     rc = lf_async_call('demo', req, c_funloc(on_result), c_null_ptr)
!
! The `LF_ASYNC_CALLBACK` abstract interface is exported so that user
! modules can declare their callbacks against the correct signature
! and the compiler can check them.
!
! =============================================================================
! OPTIONS
! =============================================================================
!
! Two levels of access are provided:
!
!   1. Generic:
!        call lf_set_option('Name', 'Value')
!        call lf_get_option('Name', out [, status])
!
!   2. Typed shortcuts for the 16 options documented in LingoFuse.h.
!      Boolean setters take a Fortran `logical`. Boolean getters
!      return a Fortran `logical`. String getters return an
!      `allocatable character`.
!
! All shortcuts are implemented on top of the generic accessors, so
! they always reflect the underlying library's behaviour exactly.
!
! =============================================================================
! All comments and diagnostic output are in English.
! =============================================================================

module lf_fortran_mod
  use iso_c_binding
  implicit none
  private

  ! ============================================================================
  ! Public constants
  !
  ! Declared BEFORE any `public ::` list so that gfortran sees the
  ! declaration first. The `public` attribute on the declaration itself
  ! is the only place that specifies its access; do NOT add it to a
  ! `public ::` list as well, or the compiler will complain about a
  ! duplicate ACCESS specification.
  ! ============================================================================

  integer, parameter, public :: LF_UID_BYTE_COUNT = 32

  ! ============================================================================
  ! Public API
  ! ============================================================================

  ! ---- Library lifecycle ----
  public :: lf_load_library, lf_free_library
  public :: lf_shutdown, lf_exit_main_thread

  ! ---- Application handle ----
  public :: lf_app_create, lf_app_destroy
  public :: lf_app_register_call, lf_app_register_notify
  public :: lf_app_unregister, lf_bind_app
  public :: lf_get_app_name, lf_generate_app_name

  ! ---- Process-wide P2P registration ----
  public :: lf_register_p2p_call, lf_register_p2p_notify, lf_unregister_p2p

  ! ---- Data handle: creation / destruction ----
  public :: lf_data_create, lf_data_create_permanent, lf_data_destroy

  ! ---- Data handle: scalar I/O ----
  public :: lf_data_write_int8,   lf_data_write_int16
  public :: lf_data_write_int32,  lf_data_write_int64
  public :: lf_data_write_uint8,  lf_data_write_uint16
  public :: lf_data_write_uint32, lf_data_write_uint64
  public :: lf_data_write_float32, lf_data_write_float64

  public :: lf_data_read_int8,   lf_data_read_int16
  public :: lf_data_read_int32,  lf_data_read_int64
  public :: lf_data_read_uint8,  lf_data_read_uint16
  public :: lf_data_read_uint32, lf_data_read_uint64
  public :: lf_data_read_float32, lf_data_read_float64

  ! ---- Data handle: byte / string / JSON ----
  public :: lf_data_write_bytes, lf_data_read_bytes, lf_data_read_all_bytes
  public :: lf_data_write_string, lf_data_write_string_bytes
  public :: lf_data_read_string,  lf_data_read_string_bytes
  public :: lf_data_write_json,   lf_data_read_json

  ! ---- Data handle: cursor / size ----
  public :: lf_data_get_position, lf_data_set_position
  public :: lf_data_get_size,     lf_data_set_size

  ! ---- UID: binary I/O and hex helpers ----
  public :: lf_data_write_uid, lf_data_read_uid
  public :: lf_uid_to_hex,     lf_uid_from_hex

  ! ---- P2P identity accessors ----
  public :: lf_data_get_p2p_uid, lf_data_get_p2p_name

  ! ---- Network preparation ----
  public :: lf_reset_prepare
  public :: lf_prepare_service, lf_prepare_client
  public :: lf_prepare_done

  ! ---- Remote invocation: app name ----
  public :: lf_call, lf_local_call, lf_notify, lf_sequenced_notify

  ! ---- Remote invocation: UID ----
  public :: lf_call_uid, lf_notify_uid, lf_sequenced_notify_uid
  public :: lf_check_uid, lf_check_uid_api

  ! ---- Remote invocation: P2PName ----
  public :: lf_call_p2pname, lf_notify_p2pname, lf_sequenced_notify_p2pname
  public :: lf_check_p2pname, lf_check_p2pname_api

  ! ---- Asynchronous invocation ----
  public :: lf_async_call, lf_async_sequenced_call
  public :: lf_async_call_uid, lf_async_sequenced_call_uid
  public :: lf_async_call_p2pname, lf_async_sequenced_call_p2pname
  public :: LF_ASYNC_CALLBACK

  ! ---- Options: generic ----
  public :: lf_set_option, lf_get_option

  ! ---- Options: typed shortcuts (16 groups) ----
  public :: lf_set_opt_password,           lf_get_opt_password
  public :: lf_set_opt_debug,              lf_get_opt_debug
  public :: lf_set_opt_quiet,              lf_get_opt_quiet
  public :: lf_set_opt_show_thread_id,     lf_get_opt_show_thread_id
  public :: lf_set_opt_console_output,     lf_get_opt_console_output
  public :: lf_set_opt_overlap_connection, lf_get_opt_overlap_connection
  public :: lf_set_opt_wait_ready_ok,      lf_get_opt_wait_ready_ok
  public :: lf_set_opt_wait_timeout,       lf_get_opt_wait_timeout
  public :: lf_set_opt_ipc_thread_count,   lf_get_opt_ipc_thread_count
  public :: lf_set_opt_ipc_max_queue,      lf_get_opt_ipc_max_queue
  public :: lf_set_opt_ipc_max_msg_size,   lf_get_opt_ipc_max_msg_size
  public :: lf_set_opt_fixed_sequenced_time, lf_get_opt_fixed_sequenced_time
  public :: lf_set_opt_p2p_name,           lf_get_opt_p2p_name
  public :: lf_set_opt_data_idle_timeout,  lf_get_opt_data_idle_timeout
  public :: lf_set_opt_data_scan_interval, lf_get_opt_data_scan_interval
  public :: lf_set_opt_null_flush_threshold, lf_get_opt_null_flush_threshold

  ! ---- Queries and diagnostics ----
  public :: lf_check_main_thread, lf_check_app, lf_check_api
  public :: lf_get_status_count,  lf_get_status, lf_post_status

  ! ---- Network events ----
  public :: lf_set_network_event
  public :: LF_NETWORK_CALLBACK

  ! ============================================================================
  ! Callback abstract interfaces
  !
  ! User procedures passed to c_funloc() must have bind(C) and match
  ! the corresponding interface exactly.
  ! ============================================================================

  abstract interface
    subroutine LF_CALL_CALLBACK(input, output) bind(C)
      import :: c_ptr
      type(c_ptr), value :: input
      type(c_ptr), value :: output
    end subroutine LF_CALL_CALLBACK

    subroutine LF_NOTIFY_CALLBACK(input) bind(C)
      import :: c_ptr
      type(c_ptr), value :: input
    end subroutine LF_NOTIFY_CALLBACK

    subroutine LF_NETWORK_CALLBACK(addr) bind(C)
      import :: c_char
      character(kind=c_char), dimension(*) :: addr
    end subroutine LF_NETWORK_CALLBACK

    subroutine LF_ASYNC_CALLBACK(user_data, result) bind(C)
      import :: c_ptr
      type(c_ptr), value :: user_data
      type(c_ptr), value :: result
    end subroutine LF_ASYNC_CALLBACK
  end interface

  ! ============================================================================
  ! Raw C interfaces (private)
  ! ============================================================================

  interface
    ! ---- Library lifecycle ----------------------------------------------
    function c_lf_load_library() bind(C, name="lf_load_library") result(rc)
      import :: c_int
      integer(c_int) :: rc
    end function

    subroutine c_lf_free_library() bind(C, name="lf_free_library")
    end subroutine

    subroutine c_lf_shutdown() bind(C, name="lf_shutdown")
    end subroutine

    subroutine c_lf_exit_main_thread() bind(C, name="lf_exit_main_thread")
    end subroutine

    ! ---- Application handle ----------------------------------------------
    function c_lf_app_create(name, desc) &
        bind(C, name="lf_app_create") result(h)
      import :: c_ptr, c_char
      character(kind=c_char), dimension(*) :: name
      character(kind=c_char), dimension(*) :: desc
      type(c_ptr) :: h
    end function

    subroutine c_lf_app_destroy(app) bind(C, name="lf_app_destroy")
      import :: c_ptr
      type(c_ptr), value :: app
    end subroutine

    function c_lf_app_register_call(app, api, desc, cb) &
        bind(C, name="lf_app_register_call") result(rc)
      import :: c_ptr, c_char, c_int, c_funptr
      type(c_ptr), value :: app
      character(kind=c_char), dimension(*) :: api
      character(kind=c_char), dimension(*) :: desc
      type(c_funptr), value :: cb
      integer(c_int) :: rc
    end function

    function c_lf_app_register_notify(app, api, desc, cb) &
        bind(C, name="lf_app_register_notify") result(rc)
      import :: c_ptr, c_char, c_int, c_funptr
      type(c_ptr), value :: app
      character(kind=c_char), dimension(*) :: api
      character(kind=c_char), dimension(*) :: desc
      type(c_funptr), value :: cb
      integer(c_int) :: rc
    end function

    function c_lf_app_unregister(app, api) &
        bind(C, name="lf_app_unregister") result(rc)
      import :: c_ptr, c_char, c_int
      type(c_ptr), value :: app
      character(kind=c_char), dimension(*) :: api
      integer(c_int) :: rc
    end function

    function c_lf_bind_app(app) &
        bind(C, name="lf_bind_app") result(rc)
      import :: c_ptr, c_int
      type(c_ptr), value :: app
      integer(c_int) :: rc
    end function

    function c_lf_get_app_name(app, buf, n) &
        bind(C, name="lf_get_app_name") result(rc)
      import :: c_ptr, c_int64_t, c_char
      type(c_ptr), value :: app
      character(kind=c_char), dimension(*) :: buf
      integer(c_int64_t), value :: n
      integer(c_int64_t) :: rc
    end function

    function c_lf_generate_app_name(buf, n) &
        bind(C, name="lf_generate_app_name") result(rc)
      import :: c_int64_t, c_char
      character(kind=c_char), dimension(*) :: buf
      integer(c_int64_t), value :: n
      integer(c_int64_t) :: rc
    end function

    ! ---- Process-wide P2P registration -----------------------------------
    function c_lf_register_p2p_call(api, desc, cb) &
        bind(C, name="lf_register_p2p_call") result(rc)
      import :: c_char, c_int, c_funptr
      character(kind=c_char), dimension(*) :: api
      character(kind=c_char), dimension(*) :: desc
      type(c_funptr), value :: cb
      integer(c_int) :: rc
    end function

    function c_lf_register_p2p_notify(api, desc, cb) &
        bind(C, name="lf_register_p2p_notify") result(rc)
      import :: c_char, c_int, c_funptr
      character(kind=c_char), dimension(*) :: api
      character(kind=c_char), dimension(*) :: desc
      type(c_funptr), value :: cb
      integer(c_int) :: rc
    end function

    function c_lf_unregister_p2p(api) &
        bind(C, name="lf_unregister_p2p") result(rc)
      import :: c_char, c_int
      character(kind=c_char), dimension(*) :: api
      integer(c_int) :: rc
    end function

    ! ---- Data handle ------------------------------------------------------
    function c_lf_data_create(api) &
        bind(C, name="lf_data_create") result(h)
      import :: c_ptr, c_char
      character(kind=c_char), dimension(*) :: api
      type(c_ptr) :: h
    end function

    function c_lf_data_create_permanent(api) &
        bind(C, name="lf_data_create_permanent") result(h)
      import :: c_ptr, c_char
      character(kind=c_char), dimension(*) :: api
      type(c_ptr) :: h
    end function

    subroutine c_lf_data_destroy(h) bind(C, name="lf_data_destroy")
      import :: c_ptr
      type(c_ptr), value :: h
    end subroutine

    ! ---- Scalar write -----------------------------------------------------
    function c_lf_data_write_int8(h, v) &
        bind(C, name="lf_data_write_int8") result(rc)
      import :: c_ptr, c_int, c_int8_t
      type(c_ptr), value :: h
      integer(c_int8_t), value :: v
      integer(c_int) :: rc
    end function

    function c_lf_data_write_int16(h, v) &
        bind(C, name="lf_data_write_int16") result(rc)
      import :: c_ptr, c_int, c_int16_t
      type(c_ptr), value :: h
      integer(c_int16_t), value :: v
      integer(c_int) :: rc
    end function

    function c_lf_data_write_int32(h, v) &
        bind(C, name="lf_data_write_int32") result(rc)
      import :: c_ptr, c_int, c_int32_t
      type(c_ptr), value :: h
      integer(c_int32_t), value :: v
      integer(c_int) :: rc
    end function

    function c_lf_data_write_int64(h, v) &
        bind(C, name="lf_data_write_int64") result(rc)
      import :: c_ptr, c_int, c_int64_t
      type(c_ptr), value :: h
      integer(c_int64_t), value :: v
      integer(c_int) :: rc
    end function

    function c_lf_data_write_uint8(h, v) &
        bind(C, name="lf_data_write_uint8") result(rc)
      import :: c_ptr, c_int, c_int8_t
      type(c_ptr), value :: h
      integer(c_int8_t), value :: v
      integer(c_int) :: rc
    end function

    function c_lf_data_write_uint16(h, v) &
        bind(C, name="lf_data_write_uint16") result(rc)
      import :: c_ptr, c_int, c_int16_t
      type(c_ptr), value :: h
      integer(c_int16_t), value :: v
      integer(c_int) :: rc
    end function

    function c_lf_data_write_uint32(h, v) &
        bind(C, name="lf_data_write_uint32") result(rc)
      import :: c_ptr, c_int, c_int32_t
      type(c_ptr), value :: h
      integer(c_int32_t), value :: v
      integer(c_int) :: rc
    end function

    function c_lf_data_write_uint64(h, v) &
        bind(C, name="lf_data_write_uint64") result(rc)
      import :: c_ptr, c_int, c_int64_t
      type(c_ptr), value :: h
      integer(c_int64_t), value :: v
      integer(c_int) :: rc
    end function

    function c_lf_data_write_float32(h, v) &
        bind(C, name="lf_data_write_float32") result(rc)
      import :: c_ptr, c_int, c_float
      type(c_ptr), value :: h
      real(c_float), value :: v
      integer(c_int) :: rc
    end function

    function c_lf_data_write_float64(h, v) &
        bind(C, name="lf_data_write_float64") result(rc)
      import :: c_ptr, c_int, c_double
      type(c_ptr), value :: h
      real(c_double), value :: v
      integer(c_int) :: rc
    end function

    ! ---- Scalar read ------------------------------------------------------
    function c_lf_data_read_int8(h, o) &
        bind(C, name="lf_data_read_int8") result(rc)
      import :: c_ptr, c_int, c_int8_t
      type(c_ptr), value :: h
      integer(c_int8_t) :: o
      integer(c_int) :: rc
    end function

    function c_lf_data_read_int16(h, o) &
        bind(C, name="lf_data_read_int16") result(rc)
      import :: c_ptr, c_int, c_int16_t
      type(c_ptr), value :: h
      integer(c_int16_t) :: o
      integer(c_int) :: rc
    end function

    function c_lf_data_read_int32(h, o) &
        bind(C, name="lf_data_read_int32") result(rc)
      import :: c_ptr, c_int, c_int32_t
      type(c_ptr), value :: h
      integer(c_int32_t) :: o
      integer(c_int) :: rc
    end function

    function c_lf_data_read_int64(h, o) &
        bind(C, name="lf_data_read_int64") result(rc)
      import :: c_ptr, c_int, c_int64_t
      type(c_ptr), value :: h
      integer(c_int64_t) :: o
      integer(c_int) :: rc
    end function

    function c_lf_data_read_uint8(h, o) &
        bind(C, name="lf_data_read_uint8") result(rc)
      import :: c_ptr, c_int, c_int8_t
      type(c_ptr), value :: h
      integer(c_int8_t) :: o
      integer(c_int) :: rc
    end function

    function c_lf_data_read_uint16(h, o) &
        bind(C, name="lf_data_read_uint16") result(rc)
      import :: c_ptr, c_int, c_int16_t
      type(c_ptr), value :: h
      integer(c_int16_t) :: o
      integer(c_int) :: rc
    end function

    function c_lf_data_read_uint32(h, o) &
        bind(C, name="lf_data_read_uint32") result(rc)
      import :: c_ptr, c_int, c_int32_t
      type(c_ptr), value :: h
      integer(c_int32_t) :: o
      integer(c_int) :: rc
    end function

    function c_lf_data_read_uint64(h, o) &
        bind(C, name="lf_data_read_uint64") result(rc)
      import :: c_ptr, c_int, c_int64_t
      type(c_ptr), value :: h
      integer(c_int64_t) :: o
      integer(c_int) :: rc
    end function

    function c_lf_data_read_float32(h, o) &
        bind(C, name="lf_data_read_float32") result(rc)
      import :: c_ptr, c_int, c_float
      type(c_ptr), value :: h
      real(c_float) :: o
      integer(c_int) :: rc
    end function

    function c_lf_data_read_float64(h, o) &
        bind(C, name="lf_data_read_float64") result(rc)
      import :: c_ptr, c_int, c_double
      type(c_ptr), value :: h
      real(c_double) :: o
      integer(c_int) :: rc
    end function

    ! ---- Byte / string / JSON I/O ----------------------------------------
    function c_lf_data_write_bytes(h, data, n) &
        bind(C, name="lf_data_write_bytes") result(rc)
      import :: c_ptr, c_int, c_int64_t, c_char
      type(c_ptr), value :: h
      character(kind=c_char), dimension(*) :: data
      integer(c_int64_t), value :: n
      integer(c_int) :: rc
    end function

    function c_lf_data_read_bytes(h, data, n) &
        bind(C, name="lf_data_read_bytes") result(rc)
      import :: c_ptr, c_int64_t, c_char
      type(c_ptr), value :: h
      character(kind=c_char), dimension(*) :: data
      integer(c_int64_t), value :: n
      integer(c_int64_t) :: rc
    end function

    function c_lf_data_read_all_bytes(h, data, n) &
        bind(C, name="lf_data_read_all_bytes") result(rc)
      import :: c_ptr, c_int64_t, c_char
      type(c_ptr), value :: h
      character(kind=c_char), dimension(*) :: data
      integer(c_int64_t), value :: n
      integer(c_int64_t) :: rc
    end function

    function c_lf_data_write_string(h, s) &
        bind(C, name="lf_data_write_string") result(rc)
      import :: c_ptr, c_int, c_char
      type(c_ptr), value :: h
      character(kind=c_char), dimension(*) :: s
      integer(c_int) :: rc
    end function

    function c_lf_data_write_string_bytes(h, data, n) &
        bind(C, name="lf_data_write_string_bytes") result(rc)
      import :: c_ptr, c_int, c_int64_t, c_char
      type(c_ptr), value :: h
      character(kind=c_char), dimension(*) :: data
      integer(c_int64_t), value :: n
      integer(c_int) :: rc
    end function

    function c_lf_data_read_string(h, buf, n) &
        bind(C, name="lf_data_read_string") result(rc)
      import :: c_ptr, c_int64_t, c_char
      type(c_ptr), value :: h
      character(kind=c_char), dimension(*) :: buf
      integer(c_int64_t), value :: n
      integer(c_int64_t) :: rc
    end function

    function c_lf_data_read_string_bytes(h, buf, n) &
        bind(C, name="lf_data_read_string_bytes") result(rc)
      import :: c_ptr, c_int64_t, c_char
      type(c_ptr), value :: h
      character(kind=c_char), dimension(*) :: buf
      integer(c_int64_t), value :: n
      integer(c_int64_t) :: rc
    end function

    function c_lf_data_write_json(h, s) &
        bind(C, name="lf_data_write_json") result(rc)
      import :: c_ptr, c_int, c_char
      type(c_ptr), value :: h
      character(kind=c_char), dimension(*) :: s
      integer(c_int) :: rc
    end function

    function c_lf_data_read_json(h, buf, n) &
        bind(C, name="lf_data_read_json") result(rc)
      import :: c_ptr, c_int64_t, c_char
      type(c_ptr), value :: h
      character(kind=c_char), dimension(*) :: buf
      integer(c_int64_t), value :: n
      integer(c_int64_t) :: rc
    end function

    ! ---- Cursor / size ----------------------------------------------------
    function c_lf_data_get_position(h) &
        bind(C, name="lf_data_get_position") result(p)
      import :: c_ptr, c_int64_t
      type(c_ptr), value :: h
      integer(c_int64_t) :: p
    end function

    subroutine c_lf_data_set_position(h, p) &
        bind(C, name="lf_data_set_position")
      import :: c_ptr, c_int64_t
      type(c_ptr), value :: h
      integer(c_int64_t), value :: p
    end subroutine

    function c_lf_data_get_size(h) &
        bind(C, name="lf_data_get_size") result(s)
      import :: c_ptr, c_int64_t
      type(c_ptr), value :: h
      integer(c_int64_t) :: s
    end function

    subroutine c_lf_data_set_size(h, s) &
        bind(C, name="lf_data_set_size")
      import :: c_ptr, c_int64_t
      type(c_ptr), value :: h
      integer(c_int64_t), value :: s
    end subroutine

    ! ---- UID binary I/O ---------------------------------------------------
    function c_lf_data_write_uid(h, uid) &
        bind(C, name="lf_data_write_uid") result(rc)
      import :: c_ptr, c_int, c_int8_t
      type(c_ptr), value :: h
      integer(c_int8_t), dimension(*) :: uid
      integer(c_int) :: rc
    end function

    function c_lf_data_read_uid(h, uid) &
        bind(C, name="lf_data_read_uid") result(rc)
      import :: c_ptr, c_int, c_int8_t
      type(c_ptr), value :: h
      integer(c_int8_t), dimension(*) :: uid
      integer(c_int) :: rc
    end function

    ! ---- P2P identity -----------------------------------------------------
    function c_lf_data_get_p2p_uid(h, uid) &
        bind(C, name="lf_data_get_p2p_uid") result(rc)
      import :: c_ptr, c_int, c_int8_t
      type(c_ptr), value :: h
      integer(c_int8_t), dimension(*) :: uid
      integer(c_int) :: rc
    end function

    function c_lf_data_get_p2p_name(h, buf, n) &
        bind(C, name="lf_data_get_p2p_name") result(rc)
      import :: c_ptr, c_int64_t, c_char
      type(c_ptr), value :: h
      character(kind=c_char), dimension(*) :: buf
      integer(c_int64_t), value :: n
      integer(c_int64_t) :: rc
    end function

    ! ---- UID <-> hex ------------------------------------------------------
    function c_lf_uid_to_hex(uid, hex) &
        bind(C, name="lf_uid_to_hex") result(rc)
      import :: c_int, c_int8_t, c_char
      integer(c_int8_t), dimension(*) :: uid
      character(kind=c_char), dimension(*) :: hex
      integer(c_int) :: rc
    end function

    function c_lf_uid_from_hex(hex, uid) &
        bind(C, name="lf_uid_from_hex") result(rc)
      import :: c_int, c_int8_t, c_char
      character(kind=c_char), dimension(*) :: hex
      integer(c_int8_t), dimension(*) :: uid
      integer(c_int) :: rc
    end function

    ! ---- Network preparation ---------------------------------------------
    subroutine c_lf_reset_prepare() bind(C, name="lf_reset_prepare")
    end subroutine

    function c_lf_prepare_service(a, b) &
        bind(C, name="lf_prepare_service") result(rc)
      import :: c_int, c_char
      character(kind=c_char), dimension(*) :: a
      character(kind=c_char), dimension(*) :: b
      integer(c_int) :: rc
    end function

    function c_lf_prepare_client(a, app) &
        bind(C, name="lf_prepare_client") result(rc)
      import :: c_int, c_char, c_ptr
      character(kind=c_char), dimension(*) :: a
      type(c_ptr), value :: app
      integer(c_int) :: rc
    end function

    function c_lf_prepare_done() &
        bind(C, name="lf_prepare_done") result(rc)
      import :: c_int
      integer(c_int) :: rc
    end function

    ! ---- Sync calls: app name --------------------------------------------
    function c_lf_call(app, p, ms) bind(C, name="lf_call") result(h)
      import :: c_ptr, c_char, c_int64_t
      character(kind=c_char), dimension(*) :: app
      type(c_ptr), value :: p
      integer(c_int64_t), value :: ms
      type(c_ptr) :: h
    end function

    function c_lf_local_call(app, p) &
        bind(C, name="lf_local_call") result(h)
      import :: c_ptr
      type(c_ptr), value :: app
      type(c_ptr), value :: p
      type(c_ptr) :: h
    end function

    subroutine c_lf_notify(app, p) bind(C, name="lf_notify")
      import :: c_ptr, c_char
      character(kind=c_char), dimension(*) :: app
      type(c_ptr), value :: p
    end subroutine

    subroutine c_lf_sequenced_notify(app, p) &
        bind(C, name="lf_sequenced_notify")
      import :: c_ptr, c_char
      character(kind=c_char), dimension(*) :: app
      type(c_ptr), value :: p
    end subroutine

    ! ---- Sync calls: UID -------------------------------------------------
    function c_lf_call_uid(uid, p, ms) &
        bind(C, name="lf_call_uid") result(h)
      import :: c_ptr, c_int8_t, c_int64_t
      integer(c_int8_t), dimension(*) :: uid
      type(c_ptr), value :: p
      integer(c_int64_t), value :: ms
      type(c_ptr) :: h
    end function

    subroutine c_lf_notify_uid(uid, p) bind(C, name="lf_notify_uid")
      import :: c_ptr, c_int8_t
      integer(c_int8_t), dimension(*) :: uid
      type(c_ptr), value :: p
    end subroutine

    subroutine c_lf_sequenced_notify_uid(uid, p) &
        bind(C, name="lf_sequenced_notify_uid")
      import :: c_ptr, c_int8_t
      integer(c_int8_t), dimension(*) :: uid
      type(c_ptr), value :: p
    end subroutine

    function c_lf_check_uid(uid) &
        bind(C, name="lf_check_uid") result(rc)
      import :: c_int, c_int8_t
      integer(c_int8_t), dimension(*) :: uid
      integer(c_int) :: rc
    end function

    function c_lf_check_uid_api(uid, api) &
        bind(C, name="lf_check_uid_api") result(rc)
      import :: c_int, c_int8_t, c_char
      integer(c_int8_t), dimension(*) :: uid
      character(kind=c_char), dimension(*) :: api
      integer(c_int) :: rc
    end function

    ! ---- Sync calls: P2PName ---------------------------------------------
    function c_lf_call_p2pname(p2p, p, ms) &
        bind(C, name="lf_call_p2pname") result(h)
      import :: c_ptr, c_char, c_int64_t
      character(kind=c_char), dimension(*) :: p2p
      type(c_ptr), value :: p
      integer(c_int64_t), value :: ms
      type(c_ptr) :: h
    end function

    subroutine c_lf_notify_p2pname(p2p, p) &
        bind(C, name="lf_notify_p2pname")
      import :: c_ptr, c_char
      character(kind=c_char), dimension(*) :: p2p
      type(c_ptr), value :: p
    end subroutine

    subroutine c_lf_sequenced_notify_p2pname(p2p, p) &
        bind(C, name="lf_sequenced_notify_p2pname")
      import :: c_ptr, c_char
      character(kind=c_char), dimension(*) :: p2p
      type(c_ptr), value :: p
    end subroutine

    function c_lf_check_p2pname(p2p) &
        bind(C, name="lf_check_p2pname") result(rc)
      import :: c_int, c_char
      character(kind=c_char), dimension(*) :: p2p
      integer(c_int) :: rc
    end function

    function c_lf_check_p2pname_api(p2p, api) &
        bind(C, name="lf_check_p2pname_api") result(rc)
      import :: c_int, c_char
      character(kind=c_char), dimension(*) :: p2p
      character(kind=c_char), dimension(*) :: api
      integer(c_int) :: rc
    end function

    ! ---- Async calls -----------------------------------------------------
    function c_lf_async_call(app, p, cb, ud) &
        bind(C, name="lf_async_call") result(rc)
      import :: c_ptr, c_char, c_int, c_funptr
      character(kind=c_char), dimension(*) :: app
      type(c_ptr), value :: p
      type(c_funptr), value :: cb
      type(c_ptr), value :: ud
      integer(c_int) :: rc
    end function

    function c_lf_async_sequenced_call(app, p, cb, ud) &
        bind(C, name="lf_async_sequenced_call") result(rc)
      import :: c_ptr, c_char, c_int, c_funptr
      character(kind=c_char), dimension(*) :: app
      type(c_ptr), value :: p
      type(c_funptr), value :: cb
      type(c_ptr), value :: ud
      integer(c_int) :: rc
    end function

    function c_lf_async_call_uid(uid, p, cb, ud) &
        bind(C, name="lf_async_call_uid") result(rc)
      import :: c_ptr, c_int8_t, c_int, c_funptr
      integer(c_int8_t), dimension(*) :: uid
      type(c_ptr), value :: p
      type(c_funptr), value :: cb
      type(c_ptr), value :: ud
      integer(c_int) :: rc
    end function

    function c_lf_async_sequenced_call_uid(uid, p, cb, ud) &
        bind(C, name="lf_async_sequenced_call_uid") result(rc)
      import :: c_ptr, c_int8_t, c_int, c_funptr
      integer(c_int8_t), dimension(*) :: uid
      type(c_ptr), value :: p
      type(c_funptr), value :: cb
      type(c_ptr), value :: ud
      integer(c_int) :: rc
    end function

    function c_lf_async_call_p2pname(p2p, p, cb, ud) &
        bind(C, name="lf_async_call_p2pname") result(rc)
      import :: c_ptr, c_char, c_int, c_funptr
      character(kind=c_char), dimension(*) :: p2p
      type(c_ptr), value :: p
      type(c_funptr), value :: cb
      type(c_ptr), value :: ud
      integer(c_int) :: rc
    end function

    function c_lf_async_sequenced_call_p2pname(p2p, p, cb, ud) &
        bind(C, name="lf_async_sequenced_call_p2pname") result(rc)
      import :: c_ptr, c_char, c_int, c_funptr
      character(kind=c_char), dimension(*) :: p2p
      type(c_ptr), value :: p
      type(c_funptr), value :: cb
      type(c_ptr), value :: ud
      integer(c_int) :: rc
    end function

    ! ---- Options: generic -------------------------------------------------
    subroutine c_lf_set_option(o, v) bind(C, name="lf_set_option")
      import :: c_char
      character(kind=c_char), dimension(*) :: o
      character(kind=c_char), dimension(*) :: v
    end subroutine

    function c_lf_get_option(o, buf, n) &
        bind(C, name="lf_get_option") result(rc)
      import :: c_char, c_int64_t
      character(kind=c_char), dimension(*) :: o
      character(kind=c_char), dimension(*) :: buf
      integer(c_int64_t), value :: n
      integer(c_int64_t) :: rc
    end function

    ! ---- Queries ---------------------------------------------------------
    function c_lf_check_main_thread() &
        bind(C, name="lf_check_main_thread") result(rc)
      import :: c_int
      integer(c_int) :: rc
    end function

    function c_lf_check_app(a) bind(C, name="lf_check_app") result(rc)
      import :: c_int, c_char
      character(kind=c_char), dimension(*) :: a
      integer(c_int) :: rc
    end function

    function c_lf_check_api(a, b) bind(C, name="lf_check_api") result(rc)
      import :: c_int, c_char
      character(kind=c_char), dimension(*) :: a
      character(kind=c_char), dimension(*) :: b
      integer(c_int) :: rc
    end function

    function c_lf_get_status_count() &
        bind(C, name="lf_get_status_count") result(rc)
      import :: c_int
      integer(c_int) :: rc
    end function

    function c_lf_get_status(buf, n) &
        bind(C, name="lf_get_status") result(rc)
      import :: c_int64_t, c_char
      character(kind=c_char), dimension(*) :: buf
      integer(c_int64_t), value :: n
      integer(c_int64_t) :: rc
    end function

    subroutine c_lf_post_status(m) bind(C, name="lf_post_status")
      import :: c_char
      character(kind=c_char), dimension(*) :: m
    end subroutine

    ! ---- Network events --------------------------------------------------
    subroutine c_lf_set_network_event(c, d) &
        bind(C, name="lf_set_network_event")
      import :: c_funptr
      type(c_funptr), value :: c
      type(c_funptr), value :: d
    end subroutine
  end interface

contains

  ! ============================================================================
  ! Helper: Fortran string -> NUL-terminated c_char array
  ! ============================================================================
  subroutine to_c_str(src, dst)
    character(len=*), intent(in) :: src
    character(kind=c_char), allocatable, intent(out) :: dst(:)
    integer :: n, i
    n = len_trim(src)
    allocate(dst(n + 1))
    do i = 1, n
      dst(i) = src(i:i)
    end do
    dst(n + 1) = c_null_char
  end subroutine to_c_str

  ! ============================================================================
  ! Helper: NUL-terminated c_char buffer -> allocatable Fortran string
  !
  ! Returns a string of length 0 when the source is empty.
  ! ============================================================================
  subroutine copy_c_buf_to_string(buf, n, out)
    character(kind=c_char), dimension(*), intent(in) :: buf
    integer(c_int64_t), intent(in) :: n
    character(len=:), allocatable, intent(out) :: out
    integer :: i
    if (n <= 0) then
      allocate(character(len=0) :: out)
      return
    end if
    allocate(character(len=int(n)) :: out)
    do i = 1, int(n)
      out(i:i) = buf(i)
    end do
  end subroutine copy_c_buf_to_string

  ! ============================================================================
  ! Library lifecycle
  ! ============================================================================
  function lf_load_library() result(rc)
    integer(c_int) :: rc
    rc = c_lf_load_library()
  end function

  subroutine lf_free_library()
    call c_lf_free_library()
  end subroutine

  subroutine lf_shutdown()
    call c_lf_shutdown()
  end subroutine

  subroutine lf_exit_main_thread()
    call c_lf_exit_main_thread()
  end subroutine

  ! ============================================================================
  ! Application handle
  ! ============================================================================
  function lf_app_create(name, desc) result(h)
    character(len=*), intent(in) :: name
    character(len=*), intent(in) :: desc
    type(c_ptr) :: h
    character(kind=c_char), allocatable :: c_name(:), c_desc(:)
    call to_c_str(name, c_name)
    call to_c_str(desc, c_desc)
    h = c_lf_app_create(c_name, c_desc)
  end function

  subroutine lf_app_destroy(app)
    type(c_ptr), value :: app
    call c_lf_app_destroy(app)
  end subroutine

  function lf_app_register_call(app, api, desc, cb) result(rc)
    type(c_ptr), value :: app
    character(len=*), intent(in) :: api
    character(len=*), intent(in) :: desc
    type(c_funptr), value :: cb
    integer(c_int) :: rc
    character(kind=c_char), allocatable :: c_api(:), c_desc(:)
    call to_c_str(api, c_api)
    call to_c_str(desc, c_desc)
    rc = c_lf_app_register_call(app, c_api, c_desc, cb)
  end function

  function lf_app_register_notify(app, api, desc, cb) result(rc)
    type(c_ptr), value :: app
    character(len=*), intent(in) :: api
    character(len=*), intent(in) :: desc
    type(c_funptr), value :: cb
    integer(c_int) :: rc
    character(kind=c_char), allocatable :: c_api(:), c_desc(:)
    call to_c_str(api, c_api)
    call to_c_str(desc, c_desc)
    rc = c_lf_app_register_notify(app, c_api, c_desc, cb)
  end function

  function lf_app_unregister(app, api) result(rc)
    type(c_ptr), value :: app
    character(len=*), intent(in) :: api
    integer(c_int) :: rc
    character(kind=c_char), allocatable :: c_api(:)
    call to_c_str(api, c_api)
    rc = c_lf_app_unregister(app, c_api)
  end function

  function lf_bind_app(app) result(rc)
    type(c_ptr), value :: app
    integer(c_int) :: rc
    rc = c_lf_bind_app(app)
  end function

  subroutine lf_get_app_name(app, out, status)
    type(c_ptr), value :: app
    character(len=:), allocatable, intent(out) :: out
    integer(c_int64_t), optional, intent(out) :: status
    character(kind=c_char) :: buf(4096)
    integer(c_int64_t) :: n
    ! size(buf) is used instead of the GNU extension sizeof(buf):
    ! each element of a character(kind=c_char) array is exactly one
    ! byte, so size(buf) equals the byte size of the buffer.
    n = c_lf_get_app_name(app, buf, int(size(buf), c_int64_t))
    if (n < 0) then
      allocate(character(len=0) :: out)
      if (present(status)) status = n
      return
    end if
    call copy_c_buf_to_string(buf, n, out)
    if (present(status)) status = n
  end subroutine

  subroutine lf_generate_app_name(out, status)
    character(len=:), allocatable, intent(out) :: out
    integer(c_int64_t), optional, intent(out) :: status
    character(kind=c_char) :: buf(4096)
    integer(c_int64_t) :: n
    n = c_lf_generate_app_name(buf, int(size(buf), c_int64_t))
    if (n < 0) then
      allocate(character(len=0) :: out)
      if (present(status)) status = n
      return
    end if
    call copy_c_buf_to_string(buf, n, out)
    if (present(status)) status = n
  end subroutine

  ! ============================================================================
  ! Process-wide P2P registration
  ! ============================================================================
  function lf_register_p2p_call(api, desc, cb) result(rc)
    character(len=*), intent(in) :: api
    character(len=*), intent(in) :: desc
    type(c_funptr), value :: cb
    integer(c_int) :: rc
    character(kind=c_char), allocatable :: c_api(:), c_desc(:)
    call to_c_str(api, c_api)
    call to_c_str(desc, c_desc)
    rc = c_lf_register_p2p_call(c_api, c_desc, cb)
  end function

  function lf_register_p2p_notify(api, desc, cb) result(rc)
    character(len=*), intent(in) :: api
    character(len=*), intent(in) :: desc
    type(c_funptr), value :: cb
    integer(c_int) :: rc
    character(kind=c_char), allocatable :: c_api(:), c_desc(:)
    call to_c_str(api, c_api)
    call to_c_str(desc, c_desc)
    rc = c_lf_register_p2p_notify(c_api, c_desc, cb)
  end function

  function lf_unregister_p2p(api) result(rc)
    character(len=*), intent(in) :: api
    integer(c_int) :: rc
    character(kind=c_char), allocatable :: c_api(:)
    call to_c_str(api, c_api)
    rc = c_lf_unregister_p2p(c_api)
  end function

  ! ============================================================================
  ! Data handle: creation / destruction
  ! ============================================================================
  function lf_data_create(api) result(h)
    character(len=*), intent(in) :: api
    type(c_ptr) :: h
    character(kind=c_char), allocatable :: c_api(:)
    call to_c_str(api, c_api)
    h = c_lf_data_create(c_api)
  end function

  function lf_data_create_permanent(api) result(h)
    character(len=*), intent(in) :: api
    type(c_ptr) :: h
    character(kind=c_char), allocatable :: c_api(:)
    call to_c_str(api, c_api)
    h = c_lf_data_create_permanent(c_api)
  end function

  subroutine lf_data_destroy(h)
    type(c_ptr), value :: h
    call c_lf_data_destroy(h)
  end subroutine

  ! ============================================================================
  ! Data handle: scalar writes
  ! ============================================================================
  function lf_data_write_int8(h, v) result(rc)
    type(c_ptr), value :: h
    integer(c_int8_t), value :: v
    integer(c_int) :: rc
    rc = c_lf_data_write_int8(h, v)
  end function
  function lf_data_write_int16(h, v) result(rc)
    type(c_ptr), value :: h
    integer(c_int16_t), value :: v
    integer(c_int) :: rc
    rc = c_lf_data_write_int16(h, v)
  end function
  function lf_data_write_int32(h, v) result(rc)
    type(c_ptr), value :: h
    integer(c_int32_t), value :: v
    integer(c_int) :: rc
    rc = c_lf_data_write_int32(h, v)
  end function
  function lf_data_write_int64(h, v) result(rc)
    type(c_ptr), value :: h
    integer(c_int64_t), value :: v
    integer(c_int) :: rc
    rc = c_lf_data_write_int64(h, v)
  end function

  function lf_data_write_uint8(h, v) result(rc)
    type(c_ptr), value :: h
    integer(c_int8_t), value :: v
    integer(c_int) :: rc
    rc = c_lf_data_write_uint8(h, v)
  end function
  function lf_data_write_uint16(h, v) result(rc)
    type(c_ptr), value :: h
    integer(c_int16_t), value :: v
    integer(c_int) :: rc
    rc = c_lf_data_write_uint16(h, v)
  end function
  function lf_data_write_uint32(h, v) result(rc)
    type(c_ptr), value :: h
    integer(c_int32_t), value :: v
    integer(c_int) :: rc
    rc = c_lf_data_write_uint32(h, v)
  end function
  function lf_data_write_uint64(h, v) result(rc)
    type(c_ptr), value :: h
    integer(c_int64_t), value :: v
    integer(c_int) :: rc
    rc = c_lf_data_write_uint64(h, v)
  end function

  function lf_data_write_float32(h, v) result(rc)
    type(c_ptr), value :: h
    real(c_float), value :: v
    integer(c_int) :: rc
    rc = c_lf_data_write_float32(h, v)
  end function
  function lf_data_write_float64(h, v) result(rc)
    type(c_ptr), value :: h
    real(c_double), value :: v
    integer(c_int) :: rc
    rc = c_lf_data_write_float64(h, v)
  end function

  ! ============================================================================
  ! Data handle: scalar reads
  ! ============================================================================
  function lf_data_read_int8(h, o) result(rc)
    type(c_ptr), value :: h
    integer(c_int8_t), intent(out) :: o
    integer(c_int) :: rc
    rc = c_lf_data_read_int8(h, o)
  end function
  function lf_data_read_int16(h, o) result(rc)
    type(c_ptr), value :: h
    integer(c_int16_t), intent(out) :: o
    integer(c_int) :: rc
    rc = c_lf_data_read_int16(h, o)
  end function
  function lf_data_read_int32(h, o) result(rc)
    type(c_ptr), value :: h
    integer(c_int32_t), intent(out) :: o
    integer(c_int) :: rc
    rc = c_lf_data_read_int32(h, o)
  end function
  function lf_data_read_int64(h, o) result(rc)
    type(c_ptr), value :: h
    integer(c_int64_t), intent(out) :: o
    integer(c_int) :: rc
    rc = c_lf_data_read_int64(h, o)
  end function

  function lf_data_read_uint8(h, o) result(rc)
    type(c_ptr), value :: h
    integer(c_int8_t), intent(out) :: o
    integer(c_int) :: rc
    rc = c_lf_data_read_uint8(h, o)
  end function
  function lf_data_read_uint16(h, o) result(rc)
    type(c_ptr), value :: h
    integer(c_int16_t), intent(out) :: o
    integer(c_int) :: rc
    rc = c_lf_data_read_uint16(h, o)
  end function
  function lf_data_read_uint32(h, o) result(rc)
    type(c_ptr), value :: h
    integer(c_int32_t), intent(out) :: o
    integer(c_int) :: rc
    rc = c_lf_data_read_uint32(h, o)
  end function
  function lf_data_read_uint64(h, o) result(rc)
    type(c_ptr), value :: h
    integer(c_int64_t), intent(out) :: o
    integer(c_int) :: rc
    rc = c_lf_data_read_uint64(h, o)
  end function

  function lf_data_read_float32(h, o) result(rc)
    type(c_ptr), value :: h
    real(c_float), intent(out) :: o
    integer(c_int) :: rc
    rc = c_lf_data_read_float32(h, o)
  end function
  function lf_data_read_float64(h, o) result(rc)
    type(c_ptr), value :: h
    real(c_double), intent(out) :: o
    integer(c_int) :: rc
    rc = c_lf_data_read_float64(h, o)
  end function

  ! ============================================================================
  ! Data handle: byte / string / JSON
  ! ============================================================================
  function lf_data_write_bytes(h, data, n) result(rc)
    type(c_ptr), value :: h
    character(kind=c_char), dimension(*), intent(in) :: data
    integer(c_int64_t), value :: n
    integer(c_int) :: rc
    rc = c_lf_data_write_bytes(h, data, n)
  end function

  function lf_data_read_bytes(h, data, n) result(rc)
    type(c_ptr), value :: h
    character(kind=c_char), dimension(*), intent(inout) :: data
    integer(c_int64_t), value :: n
    integer(c_int64_t) :: rc
    rc = c_lf_data_read_bytes(h, data, n)
  end function

  function lf_data_read_all_bytes(h, data, n) result(rc)
    type(c_ptr), value :: h
    character(kind=c_char), dimension(*), intent(inout) :: data
    integer(c_int64_t), value :: n
    integer(c_int64_t) :: rc
    rc = c_lf_data_read_all_bytes(h, data, n)
  end function

  function lf_data_write_string(h, s) result(rc)
    type(c_ptr), value :: h
    character(len=*), intent(in) :: s
    integer(c_int) :: rc
    character(kind=c_char), allocatable :: c_s(:)
    call to_c_str(s, c_s)
    rc = c_lf_data_write_string(h, c_s)
  end function

  function lf_data_write_string_bytes(h, data, n) result(rc)
    type(c_ptr), value :: h
    character(kind=c_char), dimension(*), intent(in) :: data
    integer(c_int64_t), value :: n
    integer(c_int) :: rc
    rc = c_lf_data_write_string_bytes(h, data, n)
  end function

  ! Read a NUL-terminated string into an allocatable Fortran string.
  subroutine lf_data_read_string(h, out, status)
    type(c_ptr), value :: h
    character(len=:), allocatable, intent(out) :: out
    integer(c_int64_t), optional, intent(out) :: status
    character(kind=c_char), allocatable :: buf(:)
    integer(c_int64_t) :: n, sz

    sz = c_lf_data_get_size(h)
    if (sz <= 0) then
      allocate(character(len=0) :: out)
      if (present(status)) status = -1
      return
    end if

    allocate(buf(sz + 1))
    n = c_lf_data_read_string(h, buf, sz + 1)
    if (n < 0) then
      allocate(character(len=0) :: out)
      if (present(status)) status = -1
      return
    end if

    call copy_c_buf_to_string(buf, n, out)
    if (present(status)) status = n
  end subroutine

  subroutine lf_data_read_string_bytes(h, data, n, status)
    type(c_ptr), value :: h
    character(kind=c_char), dimension(*), intent(inout) :: data
    integer(c_int64_t), value :: n
    integer(c_int64_t), optional, intent(out) :: status
    integer(c_int64_t) :: rc
    rc = c_lf_data_read_string_bytes(h, data, n)
    if (present(status)) status = rc
  end subroutine

  function lf_data_write_json(h, s) result(rc)
    type(c_ptr), value :: h
    character(len=*), intent(in) :: s
    integer(c_int) :: rc
    character(kind=c_char), allocatable :: c_s(:)
    call to_c_str(s, c_s)
    rc = c_lf_data_write_json(h, c_s)
  end function

  subroutine lf_data_read_json(h, out, status)
    type(c_ptr), value :: h
    character(len=:), allocatable, intent(out) :: out
    integer(c_int64_t), optional, intent(out) :: status
    ! JSON is read with the same mechanics as a NUL-terminated string.
    call lf_data_read_string(h, out, status)
  end subroutine

  ! ============================================================================
  ! Data handle: cursor / size
  ! ============================================================================
  function lf_data_get_position(h) result(p)
    type(c_ptr), value :: h
    integer(c_int64_t) :: p
    p = c_lf_data_get_position(h)
  end function

  subroutine lf_data_set_position(h, p)
    type(c_ptr), value :: h
    integer(c_int64_t), intent(in) :: p
    call c_lf_data_set_position(h, p)
  end subroutine

  function lf_data_get_size(h) result(s)
    type(c_ptr), value :: h
    integer(c_int64_t) :: s
    s = c_lf_data_get_size(h)
  end function

  subroutine lf_data_set_size(h, s)
    type(c_ptr), value :: h
    integer(c_int64_t), intent(in) :: s
    call c_lf_data_set_size(h, s)
  end subroutine

  ! ============================================================================
  ! UID: binary I/O
  ! ============================================================================
  function lf_data_write_uid(h, uid) result(rc)
    type(c_ptr), value :: h
    integer(c_int8_t), intent(in) :: uid(LF_UID_BYTE_COUNT)
    integer(c_int) :: rc
    rc = c_lf_data_write_uid(h, uid)
  end function

  function lf_data_read_uid(h, uid) result(rc)
    type(c_ptr), value :: h
    integer(c_int8_t), intent(out) :: uid(LF_UID_BYTE_COUNT)
    integer(c_int) :: rc
    rc = c_lf_data_read_uid(h, uid)
  end function

  ! ============================================================================
  ! UID: hex helpers
  ! ============================================================================
  subroutine lf_uid_to_hex(uid, out)
    integer(c_int8_t), intent(in) :: uid(LF_UID_BYTE_COUNT)
    character(len=:), allocatable, intent(out) :: out
    character(kind=c_char) :: hex_buf(65)
    integer(c_int) :: rc
    integer :: i

    rc = c_lf_uid_to_hex(uid, hex_buf)
    if (rc /= 1) then
      allocate(character(len=0) :: out)
      return
    end if
    allocate(character(len=64) :: out)
    do i = 1, 64
      out(i:i) = hex_buf(i)
    end do
  end subroutine

  function lf_uid_from_hex(hex, uid) result(rc)
    character(len=*), intent(in) :: hex
    integer(c_int8_t), intent(out) :: uid(LF_UID_BYTE_COUNT)
    integer(c_int) :: rc
    character(kind=c_char), allocatable :: c_hex(:)
    call to_c_str(hex, c_hex)
    rc = c_lf_uid_from_hex(c_hex, uid)
  end function

  ! ============================================================================
  ! P2P identity accessors
  ! ============================================================================
  function lf_data_get_p2p_uid(h, uid) result(rc)
    type(c_ptr), value :: h
    integer(c_int8_t), intent(out) :: uid(LF_UID_BYTE_COUNT)
    integer(c_int) :: rc
    rc = c_lf_data_get_p2p_uid(h, uid)
  end function

  subroutine lf_data_get_p2p_name(h, out, status)
    type(c_ptr), value :: h
    character(len=:), allocatable, intent(out) :: out
    integer(c_int64_t), optional, intent(out) :: status
    character(kind=c_char) :: buf(4096)
    integer(c_int64_t) :: n

    n = c_lf_data_get_p2p_name(h, buf, int(size(buf), c_int64_t))
    if (n < 0) then
      allocate(character(len=0) :: out)
      if (present(status)) status = n
      return
    end if
    call copy_c_buf_to_string(buf, n, out)
    if (present(status)) status = n
  end subroutine

  ! ============================================================================
  ! Network preparation
  ! ============================================================================
  subroutine lf_reset_prepare()
    call c_lf_reset_prepare()
  end subroutine

  function lf_prepare_service(a, b) result(rc)
    character(len=*), intent(in) :: a
    character(len=*), intent(in) :: b
    integer(c_int) :: rc
    character(kind=c_char), allocatable :: ca(:), cb(:)
    call to_c_str(a, ca)
    call to_c_str(b, cb)
    rc = c_lf_prepare_service(ca, cb)
  end function

  function lf_prepare_client(a, app) result(rc)
    character(len=*), intent(in) :: a
    type(c_ptr), value :: app
    integer(c_int) :: rc
    character(kind=c_char), allocatable :: ca(:)
    call to_c_str(a, ca)
    rc = c_lf_prepare_client(ca, app)
  end function

  function lf_prepare_done() result(rc)
    integer(c_int) :: rc
    rc = c_lf_prepare_done()
  end function

  ! ============================================================================
  ! Sync calls: app name
  ! ============================================================================
  function lf_call(app, p, ms) result(h)
    character(len=*), intent(in) :: app
    type(c_ptr), value :: p
    integer(c_int64_t), intent(in) :: ms
    type(c_ptr) :: h
    character(kind=c_char), allocatable :: c_app(:)
    call to_c_str(app, c_app)
    h = c_lf_call(c_app, p, ms)
  end function

  function lf_local_call(app, p) result(h)
    type(c_ptr), value :: app
    type(c_ptr), value :: p
    type(c_ptr) :: h
    h = c_lf_local_call(app, p)
  end function

  subroutine lf_notify(app, p)
    character(len=*), intent(in) :: app
    type(c_ptr), value :: p
    character(kind=c_char), allocatable :: c_app(:)
    call to_c_str(app, c_app)
    call c_lf_notify(c_app, p)
  end subroutine

  subroutine lf_sequenced_notify(app, p)
    character(len=*), intent(in) :: app
    type(c_ptr), value :: p
    character(kind=c_char), allocatable :: c_app(:)
    call to_c_str(app, c_app)
    call c_lf_sequenced_notify(c_app, p)
  end subroutine

  ! ============================================================================
  ! Sync calls: UID
  ! ============================================================================
  function lf_call_uid(uid, p, ms) result(h)
    integer(c_int8_t), intent(in) :: uid(LF_UID_BYTE_COUNT)
    type(c_ptr), value :: p
    integer(c_int64_t), intent(in) :: ms
    type(c_ptr) :: h
    h = c_lf_call_uid(uid, p, ms)
  end function

  subroutine lf_notify_uid(uid, p)
    integer(c_int8_t), intent(in) :: uid(LF_UID_BYTE_COUNT)
    type(c_ptr), value :: p
    call c_lf_notify_uid(uid, p)
  end subroutine

  subroutine lf_sequenced_notify_uid(uid, p)
    integer(c_int8_t), intent(in) :: uid(LF_UID_BYTE_COUNT)
    type(c_ptr), value :: p
    call c_lf_sequenced_notify_uid(uid, p)
  end subroutine

  function lf_check_uid(uid) result(v)
    integer(c_int8_t), intent(in) :: uid(LF_UID_BYTE_COUNT)
    logical :: v
    integer(c_int) :: r
    r = c_lf_check_uid(uid)
    v = (r /= 0)
  end function

  function lf_check_uid_api(uid, api) result(v)
    integer(c_int8_t), intent(in) :: uid(LF_UID_BYTE_COUNT)
    character(len=*), intent(in) :: api
    logical :: v
    integer(c_int) :: r
    character(kind=c_char), allocatable :: c_api(:)
    call to_c_str(api, c_api)
    r = c_lf_check_uid_api(uid, c_api)
    v = (r /= 0)
  end function

  ! ============================================================================
  ! Sync calls: P2PName
  ! ============================================================================
  function lf_call_p2pname(p2p, p, ms) result(h)
    character(len=*), intent(in) :: p2p
    type(c_ptr), value :: p
    integer(c_int64_t), intent(in) :: ms
    type(c_ptr) :: h
    character(kind=c_char), allocatable :: c_p2p(:)
    call to_c_str(p2p, c_p2p)
    h = c_lf_call_p2pname(c_p2p, p, ms)
  end function

  subroutine lf_notify_p2pname(p2p, p)
    character(len=*), intent(in) :: p2p
    type(c_ptr), value :: p
    character(kind=c_char), allocatable :: c_p2p(:)
    call to_c_str(p2p, c_p2p)
    call c_lf_notify_p2pname(c_p2p, p)
  end subroutine

  subroutine lf_sequenced_notify_p2pname(p2p, p)
    character(len=*), intent(in) :: p2p
    type(c_ptr), value :: p
    character(kind=c_char), allocatable :: c_p2p(:)
    call to_c_str(p2p, c_p2p)
    call c_lf_sequenced_notify_p2pname(c_p2p, p)
  end subroutine

  function lf_check_p2pname(p2p) result(v)
    character(len=*), intent(in) :: p2p
    logical :: v
    integer(c_int) :: r
    character(kind=c_char), allocatable :: c_p2p(:)
    call to_c_str(p2p, c_p2p)
    r = c_lf_check_p2pname(c_p2p)
    v = (r /= 0)
  end function

  function lf_check_p2pname_api(p2p, api) result(v)
    character(len=*), intent(in) :: p2p
    character(len=*), intent(in) :: api
    logical :: v
    integer(c_int) :: r
    character(kind=c_char), allocatable :: c_p2p(:), c_api(:)
    call to_c_str(p2p, c_p2p)
    call to_c_str(api, c_api)
    r = c_lf_check_p2pname_api(c_p2p, c_api)
    v = (r /= 0)
  end function

  ! ============================================================================
  ! Async calls
  !
  ! Every entry point takes a `type(c_funptr), value` callback. The user
  ! supplies the callback's address with `c_funloc(procedure)`.
  ! ============================================================================
  function lf_async_call(app, p, cb, ud) result(rc)
    character(len=*), intent(in) :: app
    type(c_ptr), value :: p
    type(c_funptr), value :: cb
    type(c_ptr), value :: ud
    integer(c_int) :: rc
    character(kind=c_char), allocatable :: c_app(:)
    call to_c_str(app, c_app)
    rc = c_lf_async_call(c_app, p, cb, ud)
  end function

  function lf_async_sequenced_call(app, p, cb, ud) result(rc)
    character(len=*), intent(in) :: app
    type(c_ptr), value :: p
    type(c_funptr), value :: cb
    type(c_ptr), value :: ud
    integer(c_int) :: rc
    character(kind=c_char), allocatable :: c_app(:)
    call to_c_str(app, c_app)
    rc = c_lf_async_sequenced_call(c_app, p, cb, ud)
  end function

  function lf_async_call_uid(uid, p, cb, ud) result(rc)
    integer(c_int8_t), intent(in) :: uid(LF_UID_BYTE_COUNT)
    type(c_ptr), value :: p
    type(c_funptr), value :: cb
    type(c_ptr), value :: ud
    integer(c_int) :: rc
    rc = c_lf_async_call_uid(uid, p, cb, ud)
  end function

  function lf_async_sequenced_call_uid(uid, p, cb, ud) result(rc)
    integer(c_int8_t), intent(in) :: uid(LF_UID_BYTE_COUNT)
    type(c_ptr), value :: p
    type(c_funptr), value :: cb
    type(c_ptr), value :: ud
    integer(c_int) :: rc
    rc = c_lf_async_sequenced_call_uid(uid, p, cb, ud)
  end function

  function lf_async_call_p2pname(p2p, p, cb, ud) result(rc)
    character(len=*), intent(in) :: p2p
    type(c_ptr), value :: p
    type(c_funptr), value :: cb
    type(c_ptr), value :: ud
    integer(c_int) :: rc
    character(kind=c_char), allocatable :: c_p2p(:)
    call to_c_str(p2p, c_p2p)
    rc = c_lf_async_call_p2pname(c_p2p, p, cb, ud)
  end function

  function lf_async_sequenced_call_p2pname(p2p, p, cb, ud) result(rc)
    character(len=*), intent(in) :: p2p
    type(c_ptr), value :: p
    type(c_funptr), value :: cb
    type(c_ptr), value :: ud
    integer(c_int) :: rc
    character(kind=c_char), allocatable :: c_p2p(:)
    call to_c_str(p2p, c_p2p)
    rc = c_lf_async_sequenced_call_p2pname(c_p2p, p, cb, ud)
  end function

  ! ============================================================================
  ! Options: generic
  ! ============================================================================
  subroutine lf_set_option(option, value)
    character(len=*), intent(in) :: option
    character(len=*), intent(in) :: value
    character(kind=c_char), allocatable :: c_opt(:), c_val(:)
    call to_c_str(option, c_opt)
    call to_c_str(value, c_val)
    call c_lf_set_option(c_opt, c_val)
  end subroutine

  subroutine lf_get_option(option, out, status)
    character(len=*), intent(in) :: option
    character(len=:), allocatable, intent(out) :: out
    integer(c_int64_t), optional, intent(out) :: status
    character(kind=c_char), allocatable :: c_opt(:)
    character(kind=c_char) :: buf(4096)
    integer(c_int64_t) :: n

    call to_c_str(option, c_opt)
    n = c_lf_get_option(c_opt, buf, int(size(buf), c_int64_t))
    if (n < 0) then
      allocate(character(len=0) :: out)
      if (present(status)) status = n
      return
    end if
    call copy_c_buf_to_string(buf, n, out)
    if (present(status)) status = n
  end subroutine

  ! ============================================================================
  ! Options: typed shortcuts
  !
  ! Boolean setters take a Fortran `logical`; boolean getters return a
  ! Fortran `logical`. All shortcuts are implemented on top of the
  ! generic accessors, so they always reflect the library's behaviour.
  ! ============================================================================

  ! Internal helper: write a Fortran logical as a canonical "True"/"False".
  subroutine set_bool_option(name, value)
    character(len=*), intent(in) :: name
    logical, intent(in) :: value
    if (value) then
      call lf_set_option(name, 'True')
    else
      call lf_set_option(name, 'False')
    end if
  end subroutine

  ! Internal helper: read a boolean option.
  function get_bool_option(name) result(v)
    character(len=*), intent(in) :: name
    logical :: v
    character(len=:), allocatable :: s
    call lf_get_option(name, s)
    v = (s == 'True' .or. s == 'true' .or. s == 'TRUE')
  end function

  ! Internal helper: read a 64-bit signed integer option.
  function get_i64_option(name) result(v)
    character(len=*), intent(in) :: name
    integer(c_int64_t) :: v
    character(len=:), allocatable :: s
    integer :: ios
    call lf_get_option(name, s)
    if (len_trim(s) == 0) then
      v = 0
      return
    end if
    read(s, *, iostat=ios) v
    if (ios /= 0) v = 0
  end function

  ! Internal helper: read a 32-bit signed integer option.
  function get_i32_option(name) result(v)
    character(len=*), intent(in) :: name
    integer(c_int) :: v
    character(len=:), allocatable :: s
    integer :: ios
    call lf_get_option(name, s)
    if (len_trim(s) == 0) then
      v = 0
      return
    end if
    read(s, *, iostat=ios) v
    if (ios /= 0) v = 0
  end function

  ! Internal helper: write a 64-bit signed integer option.
  subroutine set_i64_option(name, value)
    character(len=*), intent(in) :: name
    integer(c_int64_t), intent(in) :: value
    character(len=64) :: s
    write(s, '(I0)') value
    call lf_set_option(name, trim(s))
  end subroutine

  ! Internal helper: write a 32-bit signed integer option.
  subroutine set_i32_option(name, value)
    character(len=*), intent(in) :: name
    integer(c_int), intent(in) :: value
    character(len=64) :: s
    write(s, '(I0)') value
    call lf_set_option(name, trim(s))
  end subroutine

  ! ---- Authentication ---------------------------------------------------

  subroutine lf_set_opt_password(value)
    character(len=*), intent(in) :: value
    call lf_set_option('password', value)
  end subroutine

  subroutine lf_get_opt_password(out, status)
    character(len=:), allocatable, intent(out) :: out
    integer(c_int64_t), optional, intent(out) :: status
    call lf_get_option('password', out, status)
  end subroutine

  ! ---- Logging and diagnostics -----------------------------------------

  subroutine lf_set_opt_debug(value)
    character(len=*), intent(in) :: value
    call lf_set_option('debug', value)
  end subroutine

  subroutine lf_get_opt_debug(out, status)
    character(len=:), allocatable, intent(out) :: out
    integer(c_int64_t), optional, intent(out) :: status
    call lf_get_option('debug', out, status)
  end subroutine

  subroutine lf_set_opt_quiet(value)
    logical, intent(in) :: value
    call set_bool_option('Quiet', value)
  end subroutine

  function lf_get_opt_quiet() result(v)
    logical :: v
    v = get_bool_option('Quiet')
  end function

  subroutine lf_set_opt_show_thread_id(value)
    logical, intent(in) :: value
    call set_bool_option('ShowThreadID', value)
  end subroutine

  function lf_get_opt_show_thread_id() result(v)
    logical :: v
    v = get_bool_option('ShowThreadID')
  end function

  subroutine lf_set_opt_console_output(value)
    logical, intent(in) :: value
    call set_bool_option('ConsoleOutput', value)
  end subroutine

  function lf_get_opt_console_output() result(v)
    logical :: v
    v = get_bool_option('ConsoleOutput')
  end function

  ! ---- Connection readiness --------------------------------------------

  subroutine lf_set_opt_overlap_connection(value)
    logical, intent(in) :: value
    call set_bool_option('Overlap_Connection', value)
  end subroutine

  function lf_get_opt_overlap_connection() result(v)
    logical :: v
    v = get_bool_option('Overlap_Connection')
  end function

  subroutine lf_set_opt_wait_ready_ok(value)
    logical, intent(in) :: value
    call set_bool_option('Wait_Connection_ReadyOk', value)
  end subroutine

  function lf_get_opt_wait_ready_ok() result(v)
    logical :: v
    v = get_bool_option('Wait_Connection_ReadyOk')
  end function

  subroutine lf_set_opt_wait_timeout(value)
    integer(c_int64_t), intent(in) :: value
    call set_i64_option('Wait_Connection_Timeout', value)
  end subroutine

  function lf_get_opt_wait_timeout() result(v)
    integer(c_int64_t) :: v
    v = get_i64_option('Wait_Connection_Timeout')
  end function

  ! ---- IPC -------------------------------------------------------------

  subroutine lf_set_opt_ipc_thread_count(value)
    integer(c_int), intent(in) :: value
    call set_i32_option('IPC_Serv_ThreadCount', value)
  end subroutine

  function lf_get_opt_ipc_thread_count() result(v)
    integer(c_int) :: v
    v = get_i32_option('IPC_Serv_ThreadCount')
  end function

  subroutine lf_set_opt_ipc_max_queue(value)
    integer(c_int), intent(in) :: value
    call set_i32_option('IPC_Serv_MaxQueueLength', value)
  end subroutine

  function lf_get_opt_ipc_max_queue() result(v)
    integer(c_int) :: v
    v = get_i32_option('IPC_Serv_MaxQueueLength')
  end function

  subroutine lf_set_opt_ipc_max_msg_size(value)
    integer(c_int), intent(in) :: value
    call set_i32_option('IPC_Serv_MaxMsgSize', value)
  end subroutine

  function lf_get_opt_ipc_max_msg_size() result(v)
    integer(c_int) :: v
    v = get_i32_option('IPC_Serv_MaxMsgSize')
  end function

  ! ---- Sequenced notifications -----------------------------------------

  subroutine lf_set_opt_fixed_sequenced_time(value)
    integer(c_int64_t), intent(in) :: value
    call set_i64_option('Fixed_Sequenced_Time', value)
  end subroutine

  function lf_get_opt_fixed_sequenced_time() result(v)
    integer(c_int64_t) :: v
    v = get_i64_option('Fixed_Sequenced_Time')
  end function

  ! ---- P2P group name --------------------------------------------------

  subroutine lf_set_opt_p2p_name(value)
    character(len=*), intent(in) :: value
    call lf_set_option('LF_P2P_name', value)
  end subroutine

  subroutine lf_get_opt_p2p_name(out, status)
    character(len=:), allocatable, intent(out) :: out
    integer(c_int64_t), optional, intent(out) :: status
    call lf_get_option('LF_P2P_name', out, status)
  end subroutine

  ! ---- Data handle pool ------------------------------------------------

  subroutine lf_set_opt_data_idle_timeout(value)
    integer(c_int64_t), intent(in) :: value
    call set_i64_option('DataHandle_Idle_Timeout', value)
  end subroutine

  function lf_get_opt_data_idle_timeout() result(v)
    integer(c_int64_t) :: v
    v = get_i64_option('DataHandle_Idle_Timeout')
  end function

  subroutine lf_set_opt_data_scan_interval(value)
    integer(c_int64_t), intent(in) :: value
    call set_i64_option('DataHandle_Pool_Scan_Interval', value)
  end subroutine

  function lf_get_opt_data_scan_interval() result(v)
    integer(c_int64_t) :: v
    v = get_i64_option('DataHandle_Pool_Scan_Interval')
  end function

  ! ---- Command flushing ------------------------------------------------

  subroutine lf_set_opt_null_flush_threshold(value)
    integer(c_int), intent(in) :: value
    call set_i32_option('No_Reponse_Cmd_NULL_Flush_Threshold', value)
  end subroutine

  function lf_get_opt_null_flush_threshold() result(v)
    integer(c_int) :: v
    v = get_i32_option('No_Reponse_Cmd_NULL_Flush_Threshold')
  end function

  ! ============================================================================
  ! Queries and diagnostics
  ! ============================================================================
  function lf_check_main_thread() result(v)
    logical :: v
    integer(c_int) :: r
    r = c_lf_check_main_thread()
    v = (r /= 0)
  end function

  function lf_check_app(a) result(v)
    character(len=*), intent(in) :: a
    logical :: v
    integer(c_int) :: r
    character(kind=c_char), allocatable :: ca(:)
    call to_c_str(a, ca)
    r = c_lf_check_app(ca)
    v = (r /= 0)
  end function

  function lf_check_api(a, b) result(v)
    character(len=*), intent(in) :: a, b
    logical :: v
    integer(c_int) :: r
    character(kind=c_char), allocatable :: ca(:), cb(:)
    call to_c_str(a, ca)
    call to_c_str(b, cb)
    r = c_lf_check_api(ca, cb)
    v = (r /= 0)
  end function

  function lf_get_status_count() result(rc)
    integer(c_int) :: rc
    rc = c_lf_get_status_count()
  end function

  subroutine lf_get_status(out, status)
    character(len=:), allocatable, intent(out) :: out
    integer(c_int64_t), optional, intent(out) :: status
    character(kind=c_char) :: buf(4096)
    integer(c_int64_t) :: n

    n = c_lf_get_status(buf, int(size(buf), c_int64_t))
    if (n < 0) then
      allocate(character(len=0) :: out)
      if (present(status)) status = n
      return
    end if
    call copy_c_buf_to_string(buf, n, out)
    if (present(status)) status = n
  end subroutine

  subroutine lf_post_status(m)
    character(len=*), intent(in) :: m
    character(kind=c_char), allocatable :: cm(:)
    call to_c_str(m, cm)
    call c_lf_post_status(cm)
  end subroutine

  ! ============================================================================
  ! Network events
  ! ============================================================================
  subroutine lf_set_network_event(on_connect, on_disconnect)
    type(c_funptr), value :: on_connect
    type(c_funptr), value :: on_disconnect
    call c_lf_set_network_event(on_connect, on_disconnect)
  end subroutine

end module lf_fortran_mod