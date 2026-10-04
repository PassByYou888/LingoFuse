! =============================================================================
! lf_fortran_mod.f90
!
! Fortran module binding the C ABI declared in lf_fortran.h.
!
! Design:
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
! All comments and diagnostic output are in English.
! =============================================================================

module lf_fortran_mod
  use iso_c_binding
  implicit none
  private

  ! -----------------------------------------------------------------
  ! Public API
  ! -----------------------------------------------------------------
  public :: lf_load_library, lf_free_library

  public :: lf_app_create, lf_app_destroy
  public :: lf_app_register_call, lf_app_register_notify

  public :: lf_data_create, lf_data_create_permanent, lf_data_destroy

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

  public :: lf_data_write_bytes, lf_data_read_bytes, lf_data_read_all_bytes
  public :: lf_data_write_string, lf_data_write_string_bytes
  public :: lf_data_read_string,  lf_data_read_string_bytes
  public :: lf_data_write_json,   lf_data_read_json

  public :: lf_data_get_position, lf_data_set_position
  public :: lf_data_get_size,     lf_data_set_size

  public :: lf_reset_prepare
  public :: lf_prepare_service, lf_prepare_client
  public :: lf_prepare_done,    lf_exit_main_thread, lf_shutdown

  public :: lf_call, lf_local_call, lf_notify, lf_sequenced_notify

  public :: lf_set_option
  public :: lf_check_main_thread, lf_check_app, lf_check_api
  public :: lf_generate_app_name, lf_get_app_name
  public :: lf_get_status_count, lf_get_status, lf_post_status

  public :: lf_set_network_event

  ! -----------------------------------------------------------------
  ! Callback abstract interfaces
  !
  ! User procedures passed to c_funloc() must have bind(C) and match
  ! the corresponding interface exactly.
  ! -----------------------------------------------------------------
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
  end interface

  ! -----------------------------------------------------------------
  ! Raw C interfaces (private)
  ! -----------------------------------------------------------------
  interface
    function c_lf_load_library() bind(C, name="lf_load_library") &
        result(rc)
      import :: c_int
      integer(c_int) :: rc
    end function

    subroutine c_lf_free_library() bind(C, name="lf_free_library")
    end subroutine

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

    function c_lf_prepare_done() bind(C, name="lf_prepare_done") &
        result(rc)
      import :: c_int
      integer(c_int) :: rc
    end function

    subroutine c_lf_exit_main_thread() bind(C, name="lf_exit_main_thread")
    end subroutine

    subroutine c_lf_shutdown() bind(C, name="lf_shutdown")
    end subroutine

    function c_lf_call(app, p, ms) &
        bind(C, name="lf_call") result(h)
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

    subroutine c_lf_set_option(o, v) bind(C, name="lf_set_option")
      import :: c_char
      character(kind=c_char), dimension(*) :: o
      character(kind=c_char), dimension(*) :: v
    end subroutine

    function c_lf_check_main_thread() &
        bind(C, name="lf_check_main_thread") result(rc)
      import :: c_int
      integer(c_int) :: rc
    end function

    function c_lf_check_app(a) bind(C, name="lf_check_app") &
        result(rc)
      import :: c_int, c_char
      character(kind=c_char), dimension(*) :: a
      integer(c_int) :: rc
    end function

    function c_lf_check_api(a, b) bind(C, name="lf_check_api") &
        result(rc)
      import :: c_int, c_char
      character(kind=c_char), dimension(*) :: a
      character(kind=c_char), dimension(*) :: b
      integer(c_int) :: rc
    end function

    function c_lf_generate_app_name(buf, n) &
        bind(C, name="lf_generate_app_name") result(rc)
      import :: c_int64_t, c_char
      character(kind=c_char), dimension(*) :: buf
      integer(c_int64_t), value :: n
      integer(c_int64_t) :: rc
    end function

    function c_lf_get_app_name(app, buf, n) &
        bind(C, name="lf_get_app_name") result(rc)
      import :: c_ptr, c_int64_t, c_char
      type(c_ptr), value :: app
      character(kind=c_char), dimension(*) :: buf
      integer(c_int64_t), value :: n
      integer(c_int64_t) :: rc
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

    subroutine c_lf_set_network_event(c, d) &
        bind(C, name="lf_set_network_event")
      import :: c_funptr
      type(c_funptr), value :: c
      type(c_funptr), value :: d
    end subroutine
  end interface

contains

  ! -----------------------------------------------------------------
  ! Helper: Fortran string -> NUL-terminated c_char array
  ! -----------------------------------------------------------------
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

  ! -----------------------------------------------------------------
  ! Library lifecycle
  ! -----------------------------------------------------------------
  function lf_load_library() result(rc)
    integer(c_int) :: rc
    rc = c_lf_load_library()
  end function

  subroutine lf_free_library()
    call c_lf_free_library()
  end subroutine

  ! -----------------------------------------------------------------
  ! Application
  ! -----------------------------------------------------------------
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

  ! -----------------------------------------------------------------
  ! Data handle
  ! -----------------------------------------------------------------
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

  ! ---- Scalar writes ----
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

  ! ---- Scalar reads ----
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

  ! ---- Byte / string ----
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
    integer(c_int64_t) :: n, sz, i

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

    allocate(character(len=int(n)) :: out)
    do i = 1, n
      out(i:i) = buf(i)
    end do
    if (present(status)) status = n
  end subroutine lf_data_read_string

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

  ! ---- Cursor / size ----
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

  ! -----------------------------------------------------------------
  ! Network preparation
  ! -----------------------------------------------------------------
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

  subroutine lf_exit_main_thread()
    call c_lf_exit_main_thread()
  end subroutine

  subroutine lf_shutdown()
    call c_lf_shutdown()
  end subroutine

  ! -----------------------------------------------------------------
  ! Remote invocation
  ! -----------------------------------------------------------------
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

  ! -----------------------------------------------------------------
  ! Options and diagnostics
  ! -----------------------------------------------------------------
  subroutine lf_set_option(o, v)
    character(len=*), intent(in) :: o
    character(len=*), intent(in) :: v
    character(kind=c_char), allocatable :: co(:), cv(:)
    call to_c_str(o, co)
    call to_c_str(v, cv)
    call c_lf_set_option(co, cv)
  end subroutine

  function lf_check_main_thread() result(rc)
    integer(c_int) :: rc
    rc = c_lf_check_main_thread()
  end function

  function lf_check_app(a) result(rc)
    character(len=*), intent(in) :: a
    integer(c_int) :: rc
    character(kind=c_char), allocatable :: ca(:)
    call to_c_str(a, ca)
    rc = c_lf_check_app(ca)
  end function

  function lf_check_api(a, b) result(rc)
    character(len=*), intent(in) :: a, b
    integer(c_int) :: rc
    character(kind=c_char), allocatable :: ca(:), cb(:)
    call to_c_str(a, ca)
    call to_c_str(b, cb)
    rc = c_lf_check_api(ca, cb)
  end function

  subroutine lf_generate_app_name(out, status)
    character(len=:), allocatable, intent(out) :: out
    integer(c_int64_t), optional, intent(out) :: status
    character(kind=c_char) :: buf(4096)
    integer(c_int64_t) :: n, i
    ! size(buf) is used instead of the GNU extension sizeof(buf):
    ! each element of a character(kind=c_char) array is exactly one
    ! byte, so size(buf) equals the byte size of the buffer.
    n = c_lf_generate_app_name(buf, int(size(buf), c_int64_t))
    if (n < 0) then
      allocate(character(len=0) :: out)
      if (present(status)) status = n
      return
    end if
    allocate(character(len=int(n)) :: out)
    do i = 1, n
      out(i:i) = buf(i)
    end do
    if (present(status)) status = n
  end subroutine

  subroutine lf_get_app_name(app, out, status)
    type(c_ptr), value :: app
    character(len=:), allocatable, intent(out) :: out
    integer(c_int64_t), optional, intent(out) :: status
    character(kind=c_char) :: buf(4096)
    integer(c_int64_t) :: n, i
    ! size(buf) replaces the GNU extension sizeof(buf); see the note
    ! in lf_generate_app_name.
    n = c_lf_get_app_name(app, buf, int(size(buf), c_int64_t))
    if (n < 0) then
      allocate(character(len=0) :: out)
      if (present(status)) status = n
      return
    end if
    allocate(character(len=int(n)) :: out)
    do i = 1, n
      out(i:i) = buf(i)
    end do
    if (present(status)) status = n
  end subroutine

  function lf_get_status_count() result(rc)
    integer(c_int) :: rc
    rc = c_lf_get_status_count()
  end function

  subroutine lf_get_status(out, status)
    character(len=:), allocatable, intent(out) :: out
    integer(c_int64_t), optional, intent(out) :: status
    character(kind=c_char) :: buf(4096)
    integer(c_int64_t) :: n, i
    ! size(buf) replaces the GNU extension sizeof(buf); see the note
    ! in lf_generate_app_name.
    n = c_lf_get_status(buf, int(size(buf), c_int64_t))
    if (n < 0) then
      allocate(character(len=0) :: out)
      if (present(status)) status = n
      return
    end if
    allocate(character(len=int(n)) :: out)
    do i = 1, n
      out(i:i) = buf(i)
    end do
    if (present(status)) status = n
  end subroutine

  subroutine lf_post_status(m)
    character(len=*), intent(in) :: m
    character(kind=c_char), allocatable :: cm(:)
    call to_c_str(m, cm)
    call c_lf_post_status(cm)
  end subroutine

  ! -----------------------------------------------------------------
  ! Network events
  ! -----------------------------------------------------------------
  subroutine lf_set_network_event(on_connect, on_disconnect)
    type(c_funptr), value :: on_connect
    type(c_funptr), value :: on_disconnect
    call c_lf_set_network_event(on_connect, on_disconnect)
  end subroutine

end module lf_fortran_mod