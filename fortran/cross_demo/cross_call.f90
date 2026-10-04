! =============================================================================
! cross_call.f90
!
! Fortran caller for the cross-language demo.
!
! Connects to "ipc:cross" as a pure consumer and issues a fixed number
! of add() and inv_seri() calls against application "demo". Reports a
! success / failure summary.
!
! This program is the same-language baseline. cross_call_cpp.cpp is
! the cross-language counterpart: it issues the exact same requests
! over the exact same wire format.
!
! Both callers wait for "demo" to appear on the mesh before issuing
! any call, because mesh discovery is broadcast-based and has an
! approximately 3-second propagation delay.
!
! Notes on the module's API shapes:
!
!   - lf_data_write_* are FUNCTIONS that return an integer status.
!     They must be called as `rc = lf_data_write_xxx(...)` or inside
!     an `if` condition, NOT with the `call` keyword.
!
!   - lf_data_read_string, lf_data_read_json, lf_data_read_string_bytes
!     are SUBROUTINES and are invoked with `call`.
!
!   - Fortran has no unsigned kinds. Values for the "unsigned" APIs
!     are chosen to fit inside the corresponding signed kinds. The
!     C test exercises the unsigned boundaries.
! =============================================================================

program cross_call
  use iso_c_binding
  use lf_fortran_mod
  implicit none

  ! Portable sleep. On Windows we call the Win32 Sleep function
  ! directly; it takes milliseconds and has no return value.
  ! On non-Windows systems this interface will simply not link; the
  ! demo is currently only supported on Windows. Add a POSIX
  ! equivalent if you port it.
  interface
    subroutine c_sleep_ms(ms) bind(C, name="Sleep")
      import :: c_int32_t
      integer(c_int32_t), value :: ms
    end subroutine c_sleep_ms
  end interface

  integer(c_int) :: rc, i
  type(c_ptr) :: req, resp
  integer(c_int32_t) :: a, b, s
  integer(c_int64_t) :: n_ok, n_fail, sz
  logical :: seen

  ! inv_seri round-trip fields
  integer(c_int8_t)   :: send_b
  integer(c_int16_t)  :: send_w
  integer(c_int32_t)  :: send_c
  integer(c_int64_t)  :: send_u64
  real(c_float)       :: send_f
  character(len=*), parameter :: send_s = 'hello world'

  integer(c_int8_t)   :: recv_b
  integer(c_int16_t)  :: recv_w
  integer(c_int32_t)  :: recv_c
  integer(c_int64_t)  :: recv_u64
  real(c_float)       :: recv_f
  character(len=:), allocatable :: recv_s

  write(*, '(A)') '=== Cross Call (Fortran client) ==='

  if (lf_load_library() /= 1) then
    write(*, '(A)') '[FATAL] lf_load_library failed.'
    stop 1
  end if

  call lf_set_option('Wait_Ready', 'False')
  call lf_reset_prepare()

  rc = lf_prepare_client('ipc:cross', c_null_ptr)
  if (rc < 0) then
    write(*, '(A)') '[FATAL] lf_prepare_client failed.'
    stop 1
  end if

  rc = lf_prepare_done()
  if (rc /= 1) then
    write(*, '(A)') '[FATAL] lf_prepare_done failed.'
    stop 1
  end if

  write(*, '(A)') '[Call] Connected to ipc:cross.'

  ! -----------------------------------------------------------------
  ! Wait for "demo" to appear on the mesh.
  ! -----------------------------------------------------------------
  write(*, '(A)') "[Call] Waiting for 'demo' to appear on the mesh..."
  seen = .false.
  do i = 1, 50
    if (lf_check_app('demo') /= 0) then
      seen = .true.
      exit
    end if
    call c_sleep_ms(200_c_int32_t)
  end do

  if (.not. seen) then
    write(*, '(A)') "[FATAL] 'demo' did not appear within 10 seconds."
    write(*, '(A)') '        Make sure cross_node.exe is running.'
    stop 1
  end if
  write(*, '(A)') "[Call] 'demo' is online. Starting calls."

  ! ---------------------------------------------------------------
  ! add() round-trips
  ! ---------------------------------------------------------------
  write(*, '(A)') ''
  write(*, '(A)') '[Call] Running 20 add() calls...'

  n_ok = 0
  n_fail = 0
  do i = 1, 20
    a = int(i, c_int32_t)
    b = int(i * 2, c_int32_t)

    req = lf_data_create('add')
    if (.not. c_associated(req)) then
      n_fail = n_fail + 1
      cycle
    end if

    if (lf_data_write_int32(req, a) /= 1) then
      n_fail = n_fail + 1
      call lf_data_destroy(req)
      cycle
    end if
    if (lf_data_write_int32(req, b) /= 1) then
      n_fail = n_fail + 1
      call lf_data_destroy(req)
      cycle
    end if

    resp = lf_call('demo', req, 3000_c_int64_t)

    if (c_associated(resp)) then
      sz = lf_data_get_size(resp)
      if (sz == 4_c_int64_t) then
        rc = lf_data_read_int32(resp, s)
        if (rc == 1 .and. s == a + b) then
          n_ok = n_ok + 1
          write(*, '(A,I0,A,I0,A,I0,A)') &
            '[Call] add(', a, ', ', b, ') = ', s, ''
        else
          n_fail = n_fail + 1
        end if
      else
        n_fail = n_fail + 1
      end if
      call lf_data_destroy(resp)
    else
      n_fail = n_fail + 1
    end if

    call lf_data_destroy(req)
  end do

  ! ---------------------------------------------------------------
  ! inv_seri() round-trips
  ! ---------------------------------------------------------------
  write(*, '(A)') ''
  write(*, '(A)') '[Call] Running 5 inv_seri() calls...'

  ! Values chosen to fit inside the signed Fortran kinds.
  send_b   = int(100, c_int8_t)
  send_w   = int(16, c_int16_t)
  send_c   = int(47, c_int32_t)
  send_u64 = int(63, c_int64_t)
  send_f   = 3.14_c_float

  do i = 1, 5
    req = lf_data_create('inv_seri')
    if (.not. c_associated(req)) then
      n_fail = n_fail + 1
      cycle
    end if

    if (lf_data_write_uint8(req, send_b)   /= 1) then
      n_fail = n_fail + 1
      call lf_data_destroy(req)
      cycle
    end if
    if (lf_data_write_uint16(req, send_w)  /= 1) then
      n_fail = n_fail + 1
      call lf_data_destroy(req)
      cycle
    end if
    if (lf_data_write_uint32(req, send_c)  /= 1) then
      n_fail = n_fail + 1
      call lf_data_destroy(req)
      cycle
    end if
    if (lf_data_write_uint64(req, send_u64) /= 1) then
      n_fail = n_fail + 1
      call lf_data_destroy(req)
      cycle
    end if
    if (lf_data_write_string(req, send_s)  /= 1) then
      n_fail = n_fail + 1
      call lf_data_destroy(req)
      cycle
    end if
    if (lf_data_write_float32(req, send_f) /= 1) then
      n_fail = n_fail + 1
      call lf_data_destroy(req)
      cycle
    end if

    resp = lf_call('demo', req, 3000_c_int64_t)

    if (c_associated(resp)) then
      ! Read in reversed order.
      rc = lf_data_read_float32(resp, recv_f)
      call lf_data_read_string(resp, recv_s)
      rc = lf_data_read_uint64(resp, recv_u64)
      rc = lf_data_read_uint32(resp, recv_c)
      rc = lf_data_read_uint16(resp, recv_w)
      rc = lf_data_read_uint8(resp, recv_b)

      if (abs(recv_f - send_f) < 1.0e-4_c_float .and. &
          recv_s == send_s .and. &
          recv_u64 == send_u64 .and. &
          recv_c == send_c .and. &
          recv_w == send_w .and. &
          recv_b == send_b) then
        n_ok = n_ok + 1
        write(*, '(A,I0,A,A,A)') &
          '[Call] inv_seri #', i, ' ok: "', recv_s, '"'
      else
        n_fail = n_fail + 1
        write(*, '(A,I0,A)') '[Call] inv_seri #', i, ' mismatch'
      end if

      call lf_data_destroy(resp)
    else
      n_fail = n_fail + 1
      write(*, '(A,I0,A)') '[Call] inv_seri #', i, ' call failed'
    end if

    call lf_data_destroy(req)
  end do

  ! ---------------------------------------------------------------
  ! Summary
  ! ---------------------------------------------------------------
  write(*, '(A)') ''
  write(*, '(A)') '[Call] Summary'
  write(*, '(A,I0)') '         success : ', n_ok
  write(*, '(A,I0)') '         failed  : ', n_fail

  call lf_exit_main_thread()
  call lf_shutdown()
  call lf_free_library()

  write(*, '(A)') '[Call] Bye.'

  if (n_fail > 0) stop 1
end program cross_call