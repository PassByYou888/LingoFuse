! =============================================================================
! test_lf_fortran_f.f90
!
! End-to-end test for the Fortran binding.
!
! Mirrors the C test (test_lf_fortran.c) so that a passing result on
! both sides proves the bridge is symmetric and stable.
!
! Design notes:
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
! All comments and status output are in English.
! =============================================================================

! -----------------------------------------------------------------------------
! Module holding the bind(C) callback procedures.
!
! Putting them in a module lets the test program name them without an
! external interface block, and lets gfortran see the correct
! interface for c_funloc.
! -----------------------------------------------------------------------------
module lf_fortran_test_callbacks
  use iso_c_binding
  use lf_fortran_mod
  implicit none
  private
  public :: add_callback, log_callback

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
  end subroutine log_callback

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

  call test_scalars()
  call test_strings()
  call test_json()
  call test_local_call()
  call test_duplicate()
  call test_app_name()

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

  ! -----------------------------------------------------------------
  ! Scalar round-trips
  !
  ! All values used here are chosen to fit inside the signed Fortran
  ! kinds. Unsigned boundary values are covered by the C test.
  ! -----------------------------------------------------------------
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
    call check(lf_data_write_int8(h,  int(-100, c_int8_t))     == 1, 'write int8')
    call check(lf_data_write_int16(h, int(-30000, c_int16_t))  == 1, 'write int16')
    call check(lf_data_write_int32(h, int(-1000000, c_int32_t)) == 1, 'write int32')
    call check(lf_data_write_int64(h, int(-10000000000_c_int64_t, c_int64_t)) == 1, &
               'write int64')

    ! ---- Unsigned functions, exercised with sign-neutral values ----
    ! Fortran has no unsigned kinds; c_int8_t / c_int16_t / c_int32_t
    ! are signed. Byte-level unsigned correctness is verified by the
    ! C test, which has true unsigned types.
    call check(lf_data_write_uint8(h,  int(100, c_int8_t))    == 1, 'write uint8')
    call check(lf_data_write_uint16(h, int(30000, c_int16_t)) == 1, 'write uint16')
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

  ! -----------------------------------------------------------------
  ! String round-trip
  !
  ! The C side already exercises UTF-8 / emoji. Here we only verify
  ! the plumbing with a plain ASCII string, which is enough to catch
  ! ABI and buffer-size errors.
  ! -----------------------------------------------------------------
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

  ! -----------------------------------------------------------------
  ! JSON round-trip
  ! -----------------------------------------------------------------
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

  ! -----------------------------------------------------------------
  ! Local call round-trip
  ! -----------------------------------------------------------------
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

  ! -----------------------------------------------------------------
  ! Duplicate registration rejection
  ! -----------------------------------------------------------------
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

  ! -----------------------------------------------------------------
  ! App name copy helper
  ! -----------------------------------------------------------------
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

  ! -----------------------------------------------------------------
  ! Test helper
  ! -----------------------------------------------------------------
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