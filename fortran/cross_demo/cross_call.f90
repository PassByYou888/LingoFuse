! =============================================================================
! cross_call.f90
!
! Fortran caller for the cross-language demo.
!
! =============================================================================
! WHAT THIS PROGRAM EXERCISES
! =============================================================================
!
! The caller runs five independent test sections against the Fortran
! worker node (cross_node.f90). Each section corresponds to a distinct
! LingoFuse addressing mode or invocation style:
!
!   Section A: App-name addressing       (baseline)
!       LF_Call('demo', 'add', ...)      x20
!       LF_Call('demo', 'inv_seri', ...) x5
!
!   Section B: Identity discovery
!       LF_Call('demo', 'whoami', ...)   x1
!       -> reveals the caller's own UID and P2P group name
!
!   Section C: UID addressing
!       LF_UID_Call(my_uid, 'add', ...)  x5
!       -> routes to the exact client whose session UID matches
!
!   Section D: P2PName group addressing
!       LF_P2PNAME_Call('demo_group', 'add', ...) x5
!       -> dispatches to any client in the group
!
!   Section E: P2P API reachability via UID
!       LF_UID_Call(my_uid, 'p2p_ping', ...) x1
!       -> proves that a process-wide (P2P) registered API is
!          reachable through UID addressing, even though it is NOT
!          reachable through App-name addressing.
!
!   Section F: Asynchronous invocation
!       LF_Async_Call('demo', 'add', ..., on_add_result) x1
!       -> the callback fires on a TCompute worker thread; the main
!          thread polls a module-level flag until the callback sets it.
!
! =============================================================================
! THE "WHOAMI" PATTERN
! =============================================================================
!
! The caller does not know its own UID at start-up. It discovers it by
! calling the "whoami" API on the worker node. The worker's whoami
! callback reads the CALLER's UID and P2P group name from the
! framework-injected side data on the inbound request, and echoes them
! back. This is the standard LingoFuse pattern for session identity
! discovery.
!
! UID caching and reconnection:
!   The session UID is regenerated on every TunnelLink. A caller that
!   caches its UID across a link loss MUST re-probe it after the
!   reconnection completes. This demo performs a single whoami probe
!   at start-up, which is correct for a single-connection run.
!
! =============================================================================
! ASYNCHRONOUS CALLBACKS - "CLOSEST TO ERLANG"
! =============================================================================
!
! Fortran 2008 does not allow anonymous bind(C) procedures, so a
! callback must be a module procedure or an external procedure. The
! registration pattern is therefore:
!
!     1. Declare the callback in a module with bind(C).
!     2. Pass its address to the async entry point with c_funloc().
!     3. Use module-level state to bridge the callback and the main
!        thread, because Fortran has no closures.
!
! This is the closest Fortran can get to an Erlang-style inline
! handler:
!
!     rc = lf_async_call('demo', req, c_funloc(on_add_result), c_null_ptr)
!
! WARNING - MODULE STATE IS NOT THREAD-SAFE IN GENERAL:
!   The callback runs on a TCompute worker thread. The main thread
!   reads the same module variables. On x86-64, aligned 32-bit
!   integer and logical operations are atomic, which is sufficient
!   for this single-shot demo. Production code should use an explicit
!   interlocked primitive (e.g. the Win32 InterlockedIncrement family)
!   or a CriticalSection.
!
! =============================================================================
! NOTES ON THE MODULE'S API SHAPES
! =============================================================================
!
!   - lf_data_write_* are FUNCTIONS that return an integer status.
!     They must be called as `rc = lf_data_write_xxx(...)` or inside
!     an `if` condition, NOT with the `call` keyword.
!
!   - lf_data_read_string, lf_data_read_json, lf_data_read_string_bytes
!     are SUBROUTINES and are invoked with `call`.
!
!   - lf_check_app / lf_check_api / lf_check_uid / lf_check_p2pname
!     and lf_check_main_thread return Fortran LOGICAL values, not
!     integer status codes. Use them directly in `if (...)` conditions.
!
!   - lf_call / lf_local_call / lf_call_uid / lf_call_p2pname return
!     a data handle that is NEVER NULL on the normal path (it is NULL
!     only when the arguments are invalid). Detect call failure by
!     checking lf_data_get_size(resp) == 0.
!
!   - Fortran has no unsigned kinds. Values for the "unsigned" APIs
!     are chosen to fit inside the corresponding signed kinds. The
!     C test exercises the unsigned boundaries.
!
! =============================================================================


! =============================================================================
! Module holding the async callback and its associated state.
!
! See the file-level docstring section "ASYNCHRONOUS CALLBACKS" for
! the thread-safety caveat.
! =============================================================================
module cross_call_async
  use iso_c_binding
  use lf_fortran_mod
  implicit none
  private

  public :: on_add_result
  public :: async_done, async_ok, async_result
  public :: reset_async_state

  logical            :: async_done   = .false.
  logical            :: async_ok     = .false.
  integer(c_int32_t) :: async_result = 0_c_int32_t

contains

  ! -----------------------------------------------------------------
  ! Async callback for the add() API.
  !
  ! The framework owns `result`. It is valid only inside this
  ! callback and is released the instant we return. Any data the
  ! caller wants to keep MUST be copied out of it here.
  !
  ! A NULL `result` means the request could not be dispatched (no
  ! connection, invalid target, ...). The bridge invokes this
  ! callback synchronously in that case, on the caller's thread.
  ! -----------------------------------------------------------------
  subroutine on_add_result(user_data, result) bind(C)
    type(c_ptr), value :: user_data, result
    integer(c_int32_t) :: v

    ! Suppress -Wunused-dummy-argument. The user_data pointer is part
    ! of the async callback signature but is intentionally unused in
    ! this demo. Fortran 2008 has no "unused" attribute and no
    ! portable pragma; referencing the argument in an unreachable
    ! branch is the standard workaround. CONTINUE is a no-op.
    if (c_associated(user_data)) continue

    if (.not. c_associated(result)) then
      async_ok     = .false.
      async_result = 0_c_int32_t
      async_done   = .true.
      return
    end if

    v = 0_c_int32_t
    if (lf_data_read_int32(result, v) == 1) then
      async_result = v
      async_ok     = .true.
    else
      async_ok     = .false.
    end if
    async_done = .true.
  end subroutine on_add_result

  subroutine reset_async_state()
    async_done   = .false.
    async_ok     = .false.
    async_result = 0_c_int32_t
  end subroutine reset_async_state

end module cross_call_async


program cross_call
  use iso_c_binding
  use lf_fortran_mod
  use cross_call_async
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

  ! ---- Shared state ----
  integer(c_int64_t) :: n_ok, n_fail
  integer(c_int8_t)  :: my_uid(LF_UID_BYTE_COUNT)
  character(len=:), allocatable :: my_name
  logical :: have_identity

  ! ---- Scratch variables shared by the internal subroutines ----
  integer(c_int)     :: rc
  integer            :: i
  integer(c_int64_t) :: sz
  type(c_ptr)        :: req, resp
  integer(c_int32_t) :: a, b, s
  logical            :: seen

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
    if (lf_check_app('demo')) then
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

  n_ok = 0
  n_fail = 0
  have_identity = .false.

  ! -----------------------------------------------------------------
  ! Section A: App-name addressing (the baseline)
  ! -----------------------------------------------------------------
  call run_section_a_add()
  call run_section_a_inv_seri()

  ! -----------------------------------------------------------------
  ! Section B: Identity discovery via whoami
  ! -----------------------------------------------------------------
  call run_section_b_whoami()

  ! -----------------------------------------------------------------
  ! Section C: UID addressing (requires an identity)
  ! -----------------------------------------------------------------
  if (have_identity) then
    call run_section_c_uid_add()
    call run_section_c_uid_p2p_ping()
  else
    write(*, '(A)') ''
    write(*, '(A)') '[Call] Section C: SKIPPED (no identity)'
    n_fail = n_fail + 1
  end if

  ! -----------------------------------------------------------------
  ! Section D: P2PName group addressing
  ! -----------------------------------------------------------------
  call run_section_d_p2pname_add()

  ! -----------------------------------------------------------------
  ! Section E: Asynchronous invocation
  ! -----------------------------------------------------------------
  call run_section_e_async_add()

  ! -----------------------------------------------------------------
  ! Summary
  ! -----------------------------------------------------------------
  write(*, '(A)') ''
  write(*, '(A)') '[Call] Summary'
  write(*, '(A,I0)') '         success : ', n_ok
  write(*, '(A,I0)') '         failed  : ', n_fail

  call lf_exit_main_thread()
  call lf_shutdown()
  call lf_free_library()

  write(*, '(A)') '[Call] Bye.'

  if (n_fail > 0) stop 1

contains

  ! ============================================================================
  ! Section A.1: App-name addressed add() calls
  ! ============================================================================
  subroutine run_section_a_add()
    write(*, '(A)') ''
    write(*, '(A)') '[Call] Section A.1: 20 add() calls via App name'

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
      call lf_data_destroy(req)

      if (.not. c_associated(resp)) then
        n_fail = n_fail + 1
        cycle
      end if

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
    end do
  end subroutine run_section_a_add

  ! ============================================================================
  ! Section A.2: App-name addressed inv_seri() calls
  ! ============================================================================
  subroutine run_section_a_inv_seri()
    character(len=*), parameter :: send_s = 'hello world'
    integer(c_int8_t)   :: send_b
    integer(c_int16_t)  :: send_w
    integer(c_int32_t)  :: send_c
    integer(c_int64_t)  :: send_u64
    real(c_float)       :: send_f

    integer(c_int8_t)   :: recv_b
    integer(c_int16_t)  :: recv_w
    integer(c_int32_t)  :: recv_c
    integer(c_int64_t)  :: recv_u64
    real(c_float)       :: recv_f
    character(len=:), allocatable :: recv_s

    write(*, '(A)') ''
    write(*, '(A)') '[Call] Section A.2: 5 inv_seri() calls via App name'

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

      if (lf_data_write_uint8(req, send_b)   /= 1) goto 900
      if (lf_data_write_uint16(req, send_w)  /= 1) goto 900
      if (lf_data_write_uint32(req, send_c)  /= 1) goto 900
      if (lf_data_write_uint64(req, send_u64) /= 1) goto 900
      if (lf_data_write_string(req, send_s)  /= 1) goto 900
      if (lf_data_write_float32(req, send_f) /= 1) goto 900

      resp = lf_call('demo', req, 3000_c_int64_t)
      call lf_data_destroy(req)

      if (.not. c_associated(resp)) then
        n_fail = n_fail + 1
        cycle
      end if

      ! Read in reversed order.
      rc = lf_data_read_float32(resp, recv_f)
      call lf_data_read_string(resp, recv_s)
      rc = lf_data_read_uint64(resp, recv_u64)
      rc = lf_data_read_uint32(resp, recv_c)
      rc = lf_data_read_uint16(resp, recv_w)
      rc = lf_data_read_uint8(resp, recv_b)
      call lf_data_destroy(resp)

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
      cycle

900   continue
      n_fail = n_fail + 1
      call lf_data_destroy(req)
    end do
  end subroutine run_section_a_inv_seri

  ! ============================================================================
  ! Section B: Identity discovery via whoami
  ! ============================================================================
  subroutine run_section_b_whoami()
    character(len=:), allocatable :: hex_str

    write(*, '(A)') ''
    write(*, '(A)') '[Call] Section B: whoami (identity discovery)'

    req = lf_data_create('whoami')
    if (.not. c_associated(req)) then
      n_fail = n_fail + 1
      return
    end if

    resp = lf_call('demo', req, 3000_c_int64_t)
    call lf_data_destroy(req)

    if (.not. c_associated(resp)) then
      n_fail = n_fail + 1
      write(*, '(A)') '[Call] whoami call failed'
      return
    end if

    sz = lf_data_get_size(resp)
    if (sz < int(LF_UID_BYTE_COUNT, c_int64_t) + 1_c_int64_t) then
      n_fail = n_fail + 1
      write(*, '(A)') '[Call] whoami response too short'
      call lf_data_destroy(resp)
      return
    end if

    call lf_data_set_position(resp, 0_c_int64_t)
    rc = lf_data_read_uid(resp, my_uid)
    if (rc /= 1) then
      n_fail = n_fail + 1
      call lf_data_destroy(resp)
      return
    end if
    call lf_data_read_string(resp, my_name)
    call lf_data_destroy(resp)

    have_identity = .true.
    n_ok = n_ok + 1

    call lf_uid_to_hex(my_uid, hex_str)
    write(*, '(A,A)') '[Call] my UID     = ', hex_str
    write(*, '(A,A,A)') '[Call] my P2PName = "', my_name, '"'

    ! Sanity check: the framework reports the same UID via LF_Check_UID.
    if (lf_check_uid(my_uid)) then
      n_ok = n_ok + 1
      write(*, '(A)') '[Call] LF_Check_UID confirms our UID is registered'
    else
      n_fail = n_fail + 1
      write(*, '(A)') '[Call] LF_Check_UID did NOT confirm our UID'
    end if
    if (lf_check_uid_api(my_uid, 'add')) then
      n_ok = n_ok + 1
      write(*, '(A)') '[Call] LF_Check_UID_Api confirms we expose "add"'
    else
      n_fail = n_fail + 1
      write(*, '(A)') '[Call] LF_Check_UID_Api did NOT confirm "add"'
    end if
  end subroutine run_section_b_whoami

  ! ============================================================================
  ! Section C.1: UID addressed add() calls
  ! ============================================================================
  subroutine run_section_c_uid_add()
    write(*, '(A)') ''
    write(*, '(A)') '[Call] Section C.1: 5 add() calls via UID'

    do i = 1, 5
      a = int(100 + i, c_int32_t)
      b = int(200 + i, c_int32_t)

      req = lf_data_create('add')
      if (.not. c_associated(req)) then
        n_fail = n_fail + 1
        cycle
      end if
      if (lf_data_write_int32(req, a) /= 1) goto 910
      if (lf_data_write_int32(req, b) /= 1) goto 910

      resp = lf_call_uid(my_uid, req, 3000_c_int64_t)
      call lf_data_destroy(req)

      if (.not. c_associated(resp)) then
        n_fail = n_fail + 1
        cycle
      end if

      sz = lf_data_get_size(resp)
      if (sz == 4_c_int64_t) then
        rc = lf_data_read_int32(resp, s)
        if (rc == 1 .and. s == a + b) then
          n_ok = n_ok + 1
          write(*, '(A,I0,A,I0,A,I0,A)') &
            '[Call] UID add(', a, ', ', b, ') = ', s, ''
        else
          n_fail = n_fail + 1
        end if
      else
        n_fail = n_fail + 1
      end if
      call lf_data_destroy(resp)
      cycle

910   continue
      n_fail = n_fail + 1
      call lf_data_destroy(req)
    end do
  end subroutine run_section_c_uid_add

  ! ============================================================================
  ! Section C.2: UID addressed p2p_ping() call
  ! ============================================================================
  subroutine run_section_c_uid_p2p_ping()
    character(len=:), allocatable :: text

    write(*, '(A)') ''
    write(*, '(A)') '[Call] Section C.2: p2p_ping() via UID'

    req = lf_data_create('p2p_ping')
    if (.not. c_associated(req)) then
      n_fail = n_fail + 1
      return
    end if

    resp = lf_call_uid(my_uid, req, 3000_c_int64_t)
    call lf_data_destroy(req)

    if (.not. c_associated(resp)) then
      n_fail = n_fail + 1
      write(*, '(A)') '[Call] UID p2p_ping call failed'
      return
    end if

    sz = lf_data_get_size(resp)
    if (sz == 0_c_int64_t) then
      n_fail = n_fail + 1
      write(*, '(A)') '[Call] UID p2p_ping returned empty result'
      call lf_data_destroy(resp)
      return
    end if

    call lf_data_set_position(resp, 0_c_int64_t)
    call lf_data_read_string(resp, text)
    call lf_data_destroy(resp)

    if (text == 'pong') then
      n_ok = n_ok + 1
      write(*, '(A)') '[Call] UID p2p_ping = "pong"'
    else
      n_fail = n_fail + 1
      write(*, '(A,A,A)') '[Call] UID p2p_ping returned "', text, '"'
    end if
  end subroutine run_section_c_uid_p2p_ping

  ! ============================================================================
  ! Section D: P2PName group addressed add() calls
  ! ============================================================================
  subroutine run_section_d_p2pname_add()
    write(*, '(A)') ''
    write(*, '(A)') &
      '[Call] Section D: 5 add() calls via P2PName group (demo_group)'

    do i = 1, 5
      a = int(1000 + i, c_int32_t)
      b = int(2000 + i, c_int32_t)

      req = lf_data_create('add')
      if (.not. c_associated(req)) then
        n_fail = n_fail + 1
        cycle
      end if
      if (lf_data_write_int32(req, a) /= 1) goto 920
      if (lf_data_write_int32(req, b) /= 1) goto 920

      resp = lf_call_p2pname('demo_group', req, 3000_c_int64_t)
      call lf_data_destroy(req)

      if (.not. c_associated(resp)) then
        n_fail = n_fail + 1
        cycle
      end if

      sz = lf_data_get_size(resp)
      if (sz == 4_c_int64_t) then
        rc = lf_data_read_int32(resp, s)
        if (rc == 1 .and. s == a + b) then
          n_ok = n_ok + 1
          write(*, '(A,I0,A,I0,A,I0,A)') &
            '[Call] P2PName add(', a, ', ', b, ') = ', s, ''
        else
          n_fail = n_fail + 1
        end if
      else
        n_fail = n_fail + 1
      end if
      call lf_data_destroy(resp)
      cycle

920   continue
      n_fail = n_fail + 1
      call lf_data_destroy(req)
    end do
  end subroutine run_section_d_p2pname_add

  ! ============================================================================
  ! Section E: Asynchronous invocation
  ! ============================================================================
  subroutine run_section_e_async_add()
    type(c_ptr) :: areq
    integer(c_int) :: arc
    integer :: wait_iter

    write(*, '(A)') ''
    write(*, '(A)') '[Call] Section E: 1 async add() call'

    call reset_async_state()

    areq = lf_data_create('add')
    if (.not. c_associated(areq)) then
      n_fail = n_fail + 1
      return
    end if
    if (lf_data_write_int32(areq, 11_c_int32_t) /= 1 .or. &
        lf_data_write_int32(areq, 22_c_int32_t) /= 1) then
      n_fail = n_fail + 1
      call lf_data_destroy(areq)
      return
    end if

    ! Issue the async call. The bridge copies the request payload
    ! synchronously, so we may destroy the input handle immediately
    ! after this call returns.
    arc = lf_async_call('demo', areq, c_funloc(on_add_result), c_null_ptr)
    call lf_data_destroy(areq)

    if (arc /= 1) then
      ! Dispatch failed. The bridge invoked our callback synchronously
      ! on this thread, with a NULL result. Both branches below use
      ! the same module state, so the handling is unified.
      if (async_ok .and. async_result == 33_c_int32_t) then
        n_ok = n_ok + 1
        write(*, '(A,I0)') &
          '[Call] async add(11, 22) = ', async_result, ' (sync fallback)'
      else
        n_fail = n_fail + 1
        write(*, '(A)') '[Call] async dispatch failed'
      end if
      return
    end if

    ! Dispatch succeeded. Wait for the callback, with a bounded poll.
    wait_iter = 0
    do while (.not. async_done .and. wait_iter < 500)
      call c_sleep_ms(10_c_int32_t)
      wait_iter = wait_iter + 1
    end do

    if (.not. async_done) then
      n_fail = n_fail + 1
      write(*, '(A)') '[Call] async add timed out'
    else if (async_ok .and. async_result == 33_c_int32_t) then
      n_ok = n_ok + 1
      write(*, '(A,I0)') &
        '[Call] async add(11, 22) = ', async_result
    else
      n_fail = n_fail + 1
      write(*, '(A)') '[Call] async add returned unexpected result'
    end if
  end subroutine run_section_e_async_add

end program cross_call