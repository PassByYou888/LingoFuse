! =============================================================================
! test_lf_fortran_f.f90
!
! End-to-end test for the Fortran binding.
!
! Mirrors the C test (test_lf_fortran.c) so that a passing result on
! both sides proves the bridge is symmetric and stable.
!
! =============================================================================
! DESIGN NOTES
! =============================================================================
!
!   - The Fortran kinds c_int8_t / c_int16_t / c_int32_t are SIGNED.
!     Fortran has no unsigned integer types. The test therefore uses
!     values that fit comfortably inside the signed kinds. Unsigned
!     boundary values (255, 65535, 0xDEADBEEF, ...) are exercised by
!     the C test (test_lf_fortran.c), which has native unsigned types
!     available. The Fortran side only needs to prove that the ABI
!     plumbing is correct, which a sign-neutral value does just as
!     well.
!
!   - Callback procedures live in a module so that the test program
!     can name them through `use` and pass their addresses through
!     c_funloc with the correct interface in scope.
!
!   - c_ptr values are compared with c_associated(), which is the
!     Fortran 2008 standard way. Direct == / /= on c_ptr is not
!     permitted by the strict standard.
!
!   - Process exit uses `stop 1`, which is standard Fortran 2008.
!     The GNU extension `call exit()` is intentionally not used.
!
!   - The async dispatch-failure test is LAST because it starts the
!     framework (lf_prepare_done) and then tears it down.
!
!   - Unused dummy arguments in bind(C) callbacks are referenced in a
!     dead branch. Fortran 2008 has no "unused" attribute and no
!     portable pragma; referencing the argument in an unreachable
!     `if` branch is the standard way to suppress
!     -Wunused-dummy-argument without changing behaviour.
!
! =============================================================================
! COVERED CONTRACTS
! =============================================================================
!
!   Section  1  DataHandle scalar round-trip           (20 assertions)
!   Section  2  DataHandle string round-trip            ( 4 assertions)
!   Section  3  DataHandle JSON round-trip              ( 3 assertions)
!   Section  4  UID binary I/O                          ( 8 assertions)
!   Section  5  UID <-> hex helpers                     (10 assertions)
!   Section  6  P2P identity accessors                  ( 6 assertions)
!   Section  7  Local call round-trip                   ( 9 assertions)
!   Section  8  Duplicate registration rejection        ( 3 assertions)
!   Section  9  App unregister                          ( 3 assertions)
!   Section 10  Process-wide P2P registration           ( 8 assertions)
!   Section 11  App name copy helper                    ( 3 assertions)
!   Section 12  Options - generic accessors             ( 5 assertions)
!   Section 13  Options - typed shortcuts               (20 assertions)
!   Section 14  Query functions (offline)               ( 8 assertions)
!   Section 15  Async dispatch failure                  ( 4 assertions)
!
! All comments and status output are in English.
! =============================================================================


! =============================================================================
! Module holding the bind(C) callback procedures.
! =============================================================================
module lf_fortran_test_callbacks
  use iso_c_binding
  use lf_fortran_mod
  implicit none
  private

  ! ---- Exported callbacks and their associated state ----
  public :: add_callback, log_callback, async_test_callback
  public :: g_async_cb_count, g_async_cb_last_result_null
  public :: g_last_notify
  public :: reset_async_counters

  integer :: g_async_cb_count = 0
  logical :: g_async_cb_last_result_null = .false.
  character(len=512) :: g_last_notify = ''

contains

  ! add(int32 a, int32 b) -> int32
  subroutine add_callback(input, output) bind(C)
    type(c_ptr), value :: input
    type(c_ptr), value :: output
    integer(c_int32_t) :: a, b, s
    integer(c_int)     :: rc

    rc = lf_data_read_int32(input, a)
    if (rc /= 1) return
    rc = lf_data_read_int32(input, b)
    if (rc /= 1) return
    s = a + b
    rc = lf_data_write_int32(output, s)
  end subroutine add_callback

  ! log(string) -> (void)
  subroutine log_callback(input) bind(C)
    type(c_ptr), value :: input
    character(len=:), allocatable :: s
    call lf_data_read_string(input, s)
    if (len(s) > 0 .and. len(s) <= len(g_last_notify)) then
      g_last_notify = s
    end if
  end subroutine log_callback

  ! async callback: records invocation count and whether result is NULL
  subroutine async_test_callback(user_data, result) bind(C)
    type(c_ptr), value :: user_data, result

    ! Suppress -Wunused-dummy-argument. Fortran 2008 has no "unused"
    ! attribute and no portable pragma; referencing the argument in
    ! an unreachable branch is the standard workaround. The condition
    ! is never actually evaluated for its effect: CONTINUE is a no-op.
    if (c_associated(user_data)) continue

    g_async_cb_count = g_async_cb_count + 1
    g_async_cb_last_result_null = .not. c_associated(result)
  end subroutine async_test_callback

  ! ---- helpers ----
  subroutine reset_async_counters()
    g_async_cb_count = 0
    g_async_cb_last_result_null = .false.
  end subroutine reset_async_counters

end module lf_fortran_test_callbacks


! =============================================================================
! Test program
! =============================================================================
program test_lf_fortran
  use iso_c_binding
  use lf_fortran_mod
  use lf_fortran_test_callbacks
  implicit none

  integer :: g_passed = 0
  integer :: g_failed = 0

  write(*, '(A)') '=== LingoFuse Fortran bridge test suite ==='

  ! Sections 1..14: offline (framework not started)
  call test_scalars()
  call test_strings()
  call test_json()
  call test_uid_binary()
  call test_uid_hex()
  call test_p2p_identity()
  call test_local_call()
  call test_duplicate()
  call test_app_unregister()
  call test_p2p_registration()
  call test_app_name()
  call test_options_generic()
  call test_options_typed()
  call test_query_offline()

  ! Section 15: LAST -- starts and stops the framework.
  call test_async_dispatch_failure()

  write(*, '(A)') ''
  write(*, '(A)') '=== Summary ==='
  write(*, '(A,I0)') '  Passed: ', g_passed
  write(*, '(A,I0)') '  Failed: ', g_failed

  if (g_failed == 0) then
    write(*, '(A)') ''
    write(*, '(A)') '[OK] All Fortran tests passed.'
  else
    write(*, '(A)') ''
    write(*, '(A,I0,A)') '[ERROR] ', g_failed, ' test(s) failed.'
    stop 1
  end if

contains

  ! ============================================================================
  ! Section 1: scalar round-trips
  ! ============================================================================
  subroutine test_scalars()
    type(c_ptr) :: h
    integer(c_int8_t)   :: i8, u8
    integer(c_int16_t)  :: i16, u16
    integer(c_int32_t)  :: i32, u32
    integer(c_int64_t)  :: i64, u64
    real(c_float)       :: f32
    real(c_double)      :: f64
    integer(c_int)      :: rc

    write(*, '(A)') ''
    write(*, '(A)') '=== DataHandle scalar round-trip ==='

    h = lf_data_create('scalar_test')
    call check(c_associated(h), 'handle created')

    ! ---- Signed values ----
    call check(lf_data_write_int8(h,  int(-100, c_int8_t))      == 1, 'write int8')
    call check(lf_data_write_int16(h, int(-30000, c_int16_t))   == 1, 'write int16')
    call check(lf_data_write_int32(h, int(-1000000, c_int32_t)) == 1, 'write int32')
    call check(lf_data_write_int64(h, int(-10000000000_c_int64_t, c_int64_t)) == 1, &
               'write int64')

    ! ---- Unsigned functions, exercised with sign-neutral values ----
    call check(lf_data_write_uint8(h,  int(100, c_int8_t))     == 1, 'write uint8')
    call check(lf_data_write_uint16(h, int(30000, c_int16_t))  == 1, 'write uint16')
    call check(lf_data_write_uint32(h, int(2000000000, c_int32_t)) == 1, &
               'write uint32')
    call check(lf_data_write_uint64(h, int(10000000000_c_int64_t, c_int64_t)) == 1, &
               'write uint64')

    ! ---- Floating-point values ----
    call check(lf_data_write_float32(h, 3.14_c_float) == 1, 'write float32')
    call check(lf_data_write_float64(h, 2.718281828_c_double) == 1, 'write float64')

    ! ---- Read back ----
    call lf_data_set_position(h, 0_c_int64_t)

    rc = lf_data_read_int8(h, i8)
    call check(rc == 1 .and. i8 == int(-100, c_int8_t), 'read int8')
    rc = lf_data_read_int16(h, i16)
    call check(rc == 1 .and. i16 == int(-30000, c_int16_t), 'read int16')
    rc = lf_data_read_int32(h, i32)
    call check(rc == 1 .and. i32 == int(-1000000, c_int32_t), 'read int32')
    rc = lf_data_read_int64(h, i64)
    call check(rc == 1 .and. i64 == int(-10000000000_c_int64_t, c_int64_t), &
               'read int64')

    rc = lf_data_read_uint8(h, u8)
    call check(rc == 1 .and. u8 == int(100, c_int8_t), 'read uint8')
    rc = lf_data_read_uint16(h, u16)
    call check(rc == 1 .and. u16 == int(30000, c_int16_t), 'read uint16')
    rc = lf_data_read_uint32(h, u32)
    call check(rc == 1 .and. u32 == int(2000000000, c_int32_t), 'read uint32')
    rc = lf_data_read_uint64(h, u64)
    call check(rc == 1 .and. u64 == int(10000000000_c_int64_t, c_int64_t), &
               'read uint64')

    rc = lf_data_read_float32(h, f32)
    call check(rc == 1 .and. abs(f32 - 3.14_c_float) < 1.0e-4_c_float, &
               'read float32')
    rc = lf_data_read_float64(h, f64)
    call check(rc == 1 .and. abs(f64 - 2.718281828_c_double) < 1.0e-6_c_double, &
               'read float64')

    call lf_data_destroy(h)
  end subroutine test_scalars

  ! ============================================================================
  ! Section 2: string round-trip
  ! ============================================================================
  subroutine test_strings()
    type(c_ptr) :: h
    character(len=:), allocatable :: out
    integer(c_int64_t) :: expected_size

    write(*, '(A)') ''
    write(*, '(A)') '=== DataHandle string round-trip ==='

    h = lf_data_create('string_test')
    call check(c_associated(h), 'handle created')

    call check(lf_data_write_string(h, 'Hello, world') == 1, 'write string')

    expected_size = int(len('Hello, world') + 1, c_int64_t)
    call check(lf_data_get_size(h) == expected_size, 'size includes NUL')

    call lf_data_set_position(h, 0_c_int64_t)
    call lf_data_read_string(h, out)
    call check(out == 'Hello, world', 'read string')

    call lf_data_destroy(h)
  end subroutine test_strings

  ! ============================================================================
  ! Section 3: JSON round-trip
  ! ============================================================================
  subroutine test_json()
    type(c_ptr) :: h
    character(len=:), allocatable :: out

    write(*, '(A)') ''
    write(*, '(A)') '=== DataHandle JSON round-trip ==='

    h = lf_data_create('json_test')
    call check(c_associated(h), 'handle created')

    call check(lf_data_write_json(h, '{"a":1}') == 1, 'write json')
    call lf_data_set_position(h, 0_c_int64_t)
    call lf_data_read_json(h, out)
    call check(out == '{"a":1}', 'read json')

    call lf_data_destroy(h)
  end subroutine test_json

  ! ============================================================================
  ! Section 4: UID binary I/O
  ! ============================================================================
  subroutine test_uid_binary()
    type(c_ptr) :: h
    integer(c_int8_t) :: uid1(LF_UID_BYTE_COUNT)
    integer(c_int8_t) :: uid2(LF_UID_BYTE_COUNT)
    integer(c_int8_t) :: r1(LF_UID_BYTE_COUNT)
    integer(c_int8_t) :: r2(LF_UID_BYTE_COUNT)
    integer :: i
    logical :: all_match

    write(*, '(A)') ''
    write(*, '(A)') '=== UID binary I/O ==='

    h = lf_data_create('uid_test')
    call check(c_associated(h), 'handle created')

    ! ---- Deterministic byte patterns ----
    do i = 1, LF_UID_BYTE_COUNT
      uid1(i) = int(i, c_int8_t)              ! 1..32
      uid2(i) = int(-i, c_int8_t)             ! -1..-32
    end do

    ! ---- Two sequential writes ----
    call check(lf_data_write_uid(h, uid1) == 1, 'write uid #1')
    call check(lf_data_write_uid(h, uid2) == 1, 'write uid #2')
    call check(lf_data_get_size(h) == 64_c_int64_t, 'size == 64 after two writes')
    call check(lf_data_get_position(h) == 64_c_int64_t, 'position == 64 after two writes')

    ! ---- Read back in order ----
    call lf_data_set_position(h, 0_c_int64_t)
    r1 = 0_c_int8_t
    r2 = 0_c_int8_t
    call check(lf_data_read_uid(h, r1) == 1, 'read uid #1')
    call check(lf_data_read_uid(h, r2) == 1, 'read uid #2')
    call check(lf_data_get_position(h) == 64_c_int64_t, 'position == 64 after two reads')

    all_match = .true.
    do i = 1, LF_UID_BYTE_COUNT
      if (r1(i) /= uid1(i)) all_match = .false.
      if (r2(i) /= uid2(i)) all_match = .false.
    end do
    call check(all_match, 'both UIDs match byte-for-byte')

    call lf_data_destroy(h)
  end subroutine test_uid_binary

  ! ============================================================================
  ! Section 5: UID <-> hex helpers
  ! ============================================================================
  subroutine test_uid_hex()
    integer(c_int8_t) :: uid(LF_UID_BYTE_COUNT)
    integer(c_int8_t) :: back(LF_UID_BYTE_COUNT)
    integer(c_int8_t) :: sentinel(LF_UID_BYTE_COUNT)
    character(len=:), allocatable :: hex_out
    character(len=64) :: upper
    integer(c_int) :: rc
    integer :: i
    logical :: all_match

    write(*, '(A)') ''
    write(*, '(A)') '=== UID <-> hex helpers ==='

    ! ---- Build a deterministic UID ----
    do i = 1, LF_UID_BYTE_COUNT
      uid(i) = int(mod(i * 7, 120) - 60, c_int8_t)   ! range [-60, 59]
    end do

    ! ---- UID -> hex ----
    call lf_uid_to_hex(uid, hex_out)
    call check(len(hex_out) == 64, 'hex string length is 64')

    ! ---- hex -> UID (lowercase) ----
    back = 0_c_int8_t
    rc = lf_uid_from_hex(hex_out, back)
    call check(rc == 1, 'hex -> uid accepted')

    all_match = .true.
    do i = 1, LF_UID_BYTE_COUNT
      if (back(i) /= uid(i)) all_match = .false.
    end do
    call check(all_match, 'round-trip is byte-identical')

    ! ---- hex -> UID (uppercase accepted) ----
    do i = 1, 64
      if (hex_out(i:i) >= 'a' .and. hex_out(i:i) <= 'f') then
        upper(i:i) = achar(iachar(hex_out(i:i)) - 32)
      else
        upper(i:i) = hex_out(i:i)
      end if
    end do
    back = 0_c_int8_t
    rc = lf_uid_from_hex(upper, back)
    call check(rc == 1, 'uppercase hex accepted')

    all_match = .true.
    do i = 1, LF_UID_BYTE_COUNT
      if (back(i) /= uid(i)) all_match = .false.
    end do
    call check(all_match, 'uppercase round-trip is byte-identical')

    ! ---- Invalid hex is rejected and output is untouched ----
    sentinel = 42_c_int8_t
    rc = lf_uid_from_hex( &
        'zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz'// &
        'zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz', sentinel)
    call check(rc == 0, 'invalid hex rejected')

    all_match = .true.
    do i = 1, LF_UID_BYTE_COUNT
      if (sentinel(i) /= 42_c_int8_t) all_match = .false.
    end do
    call check(all_match, 'output untouched on invalid hex')

    ! ---- Empty hex is rejected ----
    sentinel = 99_c_int8_t
    rc = lf_uid_from_hex('', sentinel)
    call check(rc == 0, 'empty hex rejected')
  end subroutine test_uid_hex

  ! ============================================================================
  ! Section 6: P2P identity accessors (self-created handle)
  ! ============================================================================
  subroutine test_p2p_identity()
    type(c_ptr) :: h
    integer(c_int8_t) :: uid(LF_UID_BYTE_COUNT)
    character(len=:), allocatable :: name
    integer(c_int) :: rc
    integer :: i
    logical :: all_zero

    write(*, '(A)') ''
    write(*, '(A)') '=== P2P identity accessors (self-created handle) ==='

    h = lf_data_create('p2p_identity_test')
    call check(c_associated(h), 'handle created')

    call check(lf_data_write_string(h, 'some payload') == 1, 'write payload')

    ! ---- UID accessor returns success and 32 zero bytes ----
    uid = 42_c_int8_t
    rc = lf_data_get_p2p_uid(h, uid)
    call check(rc == 1, 'get_p2p_uid returns 1 for self-created handle')

    all_zero = .true.
    do i = 1, LF_UID_BYTE_COUNT
      if (uid(i) /= 0_c_int8_t) all_zero = .false.
    end do
    call check(all_zero, 'UID is zero-filled')

    ! ---- Name accessor returns success and an empty string ----
    call lf_data_get_p2p_name(h, name)
    call check(len(name) == 0, 'P2P name is empty')

    ! ---- NULL handle is rejected ----
    call check(lf_data_get_p2p_uid(c_null_ptr, uid) == 0, 'null handle UID rejected')

    call lf_data_destroy(h)
  end subroutine test_p2p_identity

  ! ============================================================================
  ! Section 7: local call round-trip
  ! ============================================================================
  subroutine test_local_call()
    type(c_ptr) :: app, req, resp
    integer(c_int32_t) :: sum
    integer(c_int) :: rc
    integer(c_int64_t) :: sz

    write(*, '(A)') ''
    write(*, '(A)') '=== Local call round-trip ==='

    app = lf_app_create('TestFApp', 'Fortran bridge test')
    call check(c_associated(app), 'app created')

    rc = lf_app_register_call(app, 'add', 'add two ints', &
                              c_funloc(add_callback))
    call check(rc == 1, 'register add')

    rc = lf_app_register_notify(app, 'log', 'log a message', &
                                c_funloc(log_callback))
    call check(rc == 1, 'register log')

    req = lf_data_create('add')
    call check(c_associated(req), 'request handle created')
    call check(lf_data_write_int32(req, 5_c_int32_t) == 1, 'write a')
    call check(lf_data_write_int32(req, 7_c_int32_t) == 1, 'write b')

    resp = lf_local_call(app, req)
    call check(c_associated(resp), 'response handle created')

    sz = lf_data_get_size(resp)
    call check(sz == 4_c_int64_t, 'response size == 4')

    rc = lf_data_read_int32(resp, sum)
    call check(rc == 1 .and. sum == 12_c_int32_t, '5 + 7 == 12')

    call lf_data_destroy(resp)
    call lf_data_destroy(req)
    call lf_app_destroy(app)
  end subroutine test_local_call

  ! ============================================================================
  ! Section 8: duplicate registration rejection
  ! ============================================================================
  subroutine test_duplicate()
    type(c_ptr) :: app
    integer(c_int) :: rc

    write(*, '(A)') ''
    write(*, '(A)') '=== Duplicate registration rejection ==='

    app = lf_app_create('TestFAppDup', 'dup test')
    call check(c_associated(app), 'app created')

    rc = lf_app_register_call(app, 'dup', 'first', &
                              c_funloc(add_callback))
    call check(rc == 1, 'first registration accepted')

    rc = lf_app_register_call(app, 'dup', 'second', &
                              c_funloc(add_callback))
    call check(rc == 0, 'second registration rejected')

    call lf_app_destroy(app)
  end subroutine test_duplicate

  ! ============================================================================
  ! Section 9: App unregister
  ! ============================================================================
  subroutine test_app_unregister()
    type(c_ptr) :: app
    integer(c_int) :: rc

    write(*, '(A)') ''
    write(*, '(A)') '=== App unregister ==='

    app = lf_app_create('TestFAppUnreg', 'unreg test')
    call check(c_associated(app), 'app created')

    rc = lf_app_register_call(app, 'temp', 'temp api', &
                              c_funloc(add_callback))
    call check(rc == 1, 'register temp')

    rc = lf_app_unregister(app, 'temp')
    call check(rc == 1, 'first unregister accepted')

    rc = lf_app_unregister(app, 'temp')
    call check(rc == 0, 'second unregister rejected')

    call lf_app_destroy(app)
  end subroutine test_app_unregister

  ! ============================================================================
  ! Section 10: Process-wide P2P registration
  ! ============================================================================
  subroutine test_p2p_registration()
    integer(c_int) :: rc

    write(*, '(A)') ''
    write(*, '(A)') '=== Process-wide P2P registration ==='

    rc = lf_register_p2p_call('test_p2p_ping', 'test ping', &
                              c_funloc(add_callback))
    call check(rc == 1, 'register_p2p_call accepted')

    rc = lf_register_p2p_notify('test_p2p_log', 'test log', &
                                c_funloc(log_callback))
    call check(rc == 1, 'register_p2p_notify accepted')

    rc = lf_register_p2p_call('test_p2p_ping', 'dup', &
                              c_funloc(add_callback))
    call check(rc == 0, 'duplicate P2P registration rejected')

    rc = lf_unregister_p2p('test_p2p_ping')
    call check(rc == 1, 'unregister_p2p_call accepted')

    rc = lf_unregister_p2p('test_p2p_ping')
    call check(rc == 0, 'second unregister_p2p rejected')

    rc = lf_unregister_p2p('test_p2p_log')
    call check(rc == 1, 'unregister_p2p_notify accepted')

    rc = lf_register_p2p_call('test_p2p_ping', 'reregister', &
                              c_funloc(add_callback))
    call check(rc == 1, 're-register P2P accepted')
    rc = lf_unregister_p2p('test_p2p_ping')
    call check(rc == 1, 'final cleanup unregister accepted')
  end subroutine test_p2p_registration

  ! ============================================================================
  ! Section 11: App name copy helper
  ! ============================================================================
  subroutine test_app_name()
    type(c_ptr) :: app
    character(len=:), allocatable :: name
    integer(c_int64_t) :: rc

    write(*, '(A)') ''
    write(*, '(A)') '=== App name copy helper ==='

    app = lf_app_create('TestFAppName', 'name test')
    call check(c_associated(app), 'app created')

    call lf_get_app_name(app, name, rc)
    call check(rc == int(len('TestFAppName'), c_int64_t), 'name length')
    call check(name == 'TestFAppName', 'name value')

    call lf_app_destroy(app)
  end subroutine test_app_name

  ! ============================================================================
  ! Section 12: Options - generic accessors
  ! ============================================================================
  subroutine test_options_generic()
    character(len=:), allocatable :: out
    integer(c_int64_t) :: n

    write(*, '(A)') ''
    write(*, '(A)') '=== Options - generic accessors ==='

    call lf_set_option('LF_P2P_name', 'test_group_xyz')
    call lf_get_option('LF_P2P_name', out, n)
    call check(n == int(len('test_group_xyz'), c_int64_t), &
               'get_option p2p name length')
    call check(out == 'test_group_xyz', 'get_option p2p name value')
    call lf_set_option('LF_P2P_name', '')

    call lf_set_option('__not_a_real_option__', 'ignored')
    call lf_get_option('__not_a_real_option__', out, n)
    call check(n == 0_c_int64_t, 'unknown option returns length 0')
    call check(len(out) == 0, 'unknown option returns empty string')

    call lf_set_option('Quiet', 'True')
    call lf_get_option('Quiet', out, n)
    call check(out == 'True', 'generic Quiet round-trip')
    call lf_set_option('Quiet', 'False')
  end subroutine test_options_generic

  ! ============================================================================
  ! Section 13: Options - typed shortcuts
  ! ============================================================================
  subroutine test_options_typed()
    character(len=:), allocatable :: s

    write(*, '(A)') ''
    write(*, '(A)') '=== Options - typed shortcuts ==='

    call lf_set_opt_password('hunter2')
    call lf_get_opt_password(s)
    call check(s == '********', 'password getter returns the mask')

    call lf_set_opt_quiet(.true.)
    call check(lf_get_opt_quiet(), 'quiet set true / get true')
    call lf_set_opt_quiet(.false.)
    call check(.not. lf_get_opt_quiet(), 'quiet set false / get false')

    call lf_set_opt_show_thread_id(.false.)
    call check(.not. lf_get_opt_show_thread_id(), 'show_thread_id false')
    call lf_set_opt_show_thread_id(.true.)
    call check(lf_get_opt_show_thread_id(), 'show_thread_id true')
    call lf_set_opt_show_thread_id(.false.)

    call lf_set_opt_console_output(.true.)
    call check(lf_get_opt_console_output(), 'console_output true')
    call lf_set_opt_console_output(.false.)
    call check(.not. lf_get_opt_console_output(), 'console_output false')
    call lf_set_opt_console_output(.true.)

    call lf_set_opt_overlap_connection(.true.)
    call check(lf_get_opt_overlap_connection(), 'overlap_connection true')
    call lf_set_opt_overlap_connection(.false.)
    call check(.not. lf_get_opt_overlap_connection(), 'overlap_connection false')

    call lf_set_opt_wait_ready_ok(.false.)
    call check(.not. lf_get_opt_wait_ready_ok(), 'wait_ready_ok false')
    call lf_set_opt_wait_ready_ok(.true.)
    call check(lf_get_opt_wait_ready_ok(), 'wait_ready_ok true')

    call lf_set_opt_wait_timeout(12345_c_int64_t)
    call check(lf_get_opt_wait_timeout() == 12345_c_int64_t, &
               'wait_timeout round-trip')
    call lf_set_opt_wait_timeout(30000_c_int64_t)

    call lf_set_opt_ipc_thread_count(4_c_int)
    call check(lf_get_opt_ipc_thread_count() == 4_c_int, &
               'ipc_thread_count round-trip')

    call lf_set_opt_ipc_max_queue(512_c_int)
    call check(lf_get_opt_ipc_max_queue() == 512_c_int, &
               'ipc_max_queue round-trip')

    call lf_set_opt_ipc_max_msg_size(2097152_c_int)
    call check(lf_get_opt_ipc_max_msg_size() == 2097152_c_int, &
               'ipc_max_msg_size round-trip')

    call lf_set_opt_fixed_sequenced_time(25000_c_int64_t)
    call check(lf_get_opt_fixed_sequenced_time() == 25000_c_int64_t, &
               'fixed_sequenced_time round-trip')
    call lf_set_opt_fixed_sequenced_time(20000_c_int64_t)

    call lf_set_opt_p2p_name('typed_opt_group')
    call lf_get_opt_p2p_name(s)
    call check(s == 'typed_opt_group', 'p2p name round-trip')
    call lf_set_opt_p2p_name('')

    call lf_set_opt_data_idle_timeout(600000_c_int64_t)
    call check(lf_get_opt_data_idle_timeout() == 600000_c_int64_t, &
               'data_idle_timeout round-trip')

    call lf_set_opt_data_scan_interval(5000_c_int64_t)
    call check(lf_get_opt_data_scan_interval() == 5000_c_int64_t, &
               'data_scan_interval round-trip')

    call lf_set_opt_null_flush_threshold(1000_c_int)
    call check(lf_get_opt_null_flush_threshold() == 1000_c_int, &
               'null_flush_threshold round-trip')
    call lf_set_opt_null_flush_threshold(5000_c_int)
  end subroutine test_options_typed

  ! ============================================================================
  ! Section 14: Query functions (offline)
  ! ============================================================================
  subroutine test_query_offline()
    integer(c_int8_t) :: zero_uid(LF_UID_BYTE_COUNT)
    integer :: i

    write(*, '(A)') ''
    write(*, '(A)') '=== Query functions (offline) ==='

    call check(.not. lf_check_main_thread(), 'check_main_thread false offline')

    call check(.not. lf_check_app('__no_such_app_xyz__'), &
               'check_app unknown false')
    call check(.not. lf_check_api('__no_such_app_xyz__', '__no_such_api__'), &
               'check_api unknown false')

    do i = 1, LF_UID_BYTE_COUNT
      zero_uid(i) = 0_c_int8_t
    end do
    call check(.not. lf_check_uid(zero_uid), 'check_uid all-zero false')
    call check(.not. lf_check_uid_api(zero_uid, '__no_such_api__'), &
               'check_uid_api all-zero false')

    call check(.not. lf_check_p2pname('__no_such_group_xyz__'), &
               'check_p2pname unknown false')
    call check(.not. lf_check_p2pname_api('__no_such_group_xyz__', &
                                           '__no_such_api__'), &
               'check_p2pname_api unknown false')
  end subroutine test_query_offline

  ! ============================================================================
  ! Section 15: Async dispatch failure
  ! ============================================================================
  subroutine test_async_dispatch_failure()
    type(c_ptr) :: req
    integer(c_int) :: rc

    write(*, '(A)') ''
    write(*, '(A)') '=== Async dispatch failure path ==='

    call lf_set_opt_wait_ready_ok(.true.)
    call lf_set_opt_wait_timeout(15000_c_int64_t)
    call lf_set_opt_overlap_connection(.true.)

    call lf_reset_prepare()
    rc = lf_prepare_done()
    call check(rc == 1, 'prepare_done succeeded')

    call reset_async_counters()

    req = lf_data_create('anything')
    call check(c_associated(req), 'request handle created')
    rc = lf_data_write_int32(req, 0_c_int32_t)

    rc = lf_async_call('__no_such_app_xyz__', req, &
                       c_funloc(async_test_callback), c_null_ptr)
    call check(rc == 0, 'async dispatch failed as expected')
    call check(g_async_cb_count == 1, 'callback invoked exactly once')
    call check(g_async_cb_last_result_null, 'result handle is NULL')

    call lf_data_destroy(req)

    call lf_exit_main_thread()
    call lf_shutdown()
  end subroutine test_async_dispatch_failure

  ! ============================================================================
  ! Test helper
  ! ============================================================================
  subroutine check(cond, msg)
    logical, intent(in) :: cond
    character(len=*), intent(in) :: msg
    if (cond) then
      g_passed = g_passed + 1
    else
      g_failed = g_failed + 1
      write(*, '(A,A)') '[FAIL] ', trim(msg)
    end if
  end subroutine check

end program test_lf_fortran