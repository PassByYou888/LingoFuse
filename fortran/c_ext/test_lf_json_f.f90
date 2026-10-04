! =============================================================================
! test_lf_json_f.f90
!
! Fortran JSON test suite for the LingoFuse bridge.
!
! Mirrors the C++ suite (test_lingofuse_json.cpp) in spirit: every
! JSON-related primitive is exercised through the Fortran API and
! data handles. There is no Fortran-side JSON parser involved; the
! tests verify byte-level correctness, NUL framing, UTF-8 pass-through,
! cursor behaviour, and error handling.
!
! API shapes in lf_fortran_mod:
!
!   Functions returning an integer status (use `rc = xxx(...)` or
!   `if (xxx(...) /= 1)`):
!       lf_data_write_int8   .. lf_data_write_float64
!       lf_data_write_string
!       lf_data_write_string_bytes
!       lf_data_write_json
!       lf_data_write_bytes
!       lf_data_read_int8    .. lf_data_read_float64
!       lf_data_read_bytes
!       lf_data_read_all_bytes
!       lf_data_get_position, lf_data_get_size
!
!   Subroutines (use `call xxx(...)`):
!       lf_data_read_string
!       lf_data_read_json
!       lf_data_read_string_bytes
!       lf_data_set_position, lf_data_set_size
!       lf_data_destroy
!
! All comments and status output are in English.
! =============================================================================

program test_lf_json_f
  use iso_c_binding
  use lf_fortran_mod
  implicit none

  integer :: g_passed = 0
  integer :: g_failed = 0

  write(*, '(A)') '=== LingoFuse Fortran JSON test suite ==='

  call test_basic_json()
  call test_nul_termination()
  call test_wire_format()
  call test_utf8()
  call test_raw_bytes()
  call test_fault_tolerant()
  call test_cursor()
  call test_buffer_too_small()
  call test_multiple_payloads()
  call test_large_json()

  write(*, '(A)') ''
  write(*, '(A)') '=== Summary ==='
  write(*, '(A,I0)') '  Passed: ', g_passed
  write(*, '(A,I0)') '  Failed: ', g_failed

  if (g_failed == 0) then
    write(*, '(A)') ''
    write(*, '(A)') '[OK] All Fortran JSON tests passed.'
  else
    write(*, '(A)') ''
    write(*, '(A,I0,A)') '[ERROR] ', g_failed, ' test(s) failed.'
    stop 1
  end if

contains

  ! -----------------------------------------------------------------
  ! 1. Basic JSON round-trip
  ! -----------------------------------------------------------------
  subroutine test_basic_json()
    type(c_ptr) :: h
    character(len=:), allocatable :: out
    integer(c_int) :: rc

    write(*, '(A)') ''
    write(*, '(A)') '=== Basic JSON round-trip ==='

    ! ---- Simple object ----
    h = lf_data_create('json_basic_1')
    call check(c_associated(h), 'handle created')
    rc = lf_data_write_json(h, '{"a":1}')
    call check(rc == 1, 'write simple object')
    call lf_data_set_position(h, 0_c_int64_t)
    call lf_data_read_json(h, out)
    call check(str_eq(out, '{"a":1}'), 'read simple object')
    call lf_data_destroy(h)

    ! ---- Nested object ----
    h = lf_data_create('json_basic_2')
    rc = lf_data_write_json(h, '{"a":{"b":{"c":42}}}')
    call check(rc == 1, 'write nested object')
    call lf_data_set_position(h, 0_c_int64_t)
    call lf_data_read_json(h, out)
    call check(str_eq(out, '{"a":{"b":{"c":42}}}'), 'read nested object')
    call lf_data_destroy(h)

    ! ---- Array ----
    h = lf_data_create('json_basic_3')
    rc = lf_data_write_json(h, '[1,2,3,4,5]')
    call check(rc == 1, 'write array')
    call lf_data_set_position(h, 0_c_int64_t)
    call lf_data_read_json(h, out)
    call check(str_eq(out, '[1,2,3,4,5]'), 'read array')
    call lf_data_destroy(h)

    ! ---- Empty object ----
    h = lf_data_create('json_basic_4')
    rc = lf_data_write_json(h, '{}')
    call check(rc == 1, 'write empty object')
    call lf_data_set_position(h, 0_c_int64_t)
    call lf_data_read_json(h, out)
    call check(str_eq(out, '{}'), 'read empty object')
    call lf_data_destroy(h)

    ! ---- Empty array ----
    h = lf_data_create('json_basic_5')
    rc = lf_data_write_json(h, '[]')
    call check(rc == 1, 'write empty array')
    call lf_data_set_position(h, 0_c_int64_t)
    call lf_data_read_json(h, out)
    call check(str_eq(out, '[]'), 'read empty array')
    call lf_data_destroy(h)

    ! ---- JSON null ----
    h = lf_data_create('json_basic_6')
    rc = lf_data_write_json(h, 'null')
    call check(rc == 1, 'write null')
    call lf_data_set_position(h, 0_c_int64_t)
    call lf_data_read_json(h, out)
    call check(str_eq(out, 'null'), 'read null')
    call lf_data_destroy(h)

    ! ---- JSON boolean ----
    h = lf_data_create('json_basic_7')
    rc = lf_data_write_json(h, 'true')
    call check(rc == 1, 'write true')
    call lf_data_set_position(h, 0_c_int64_t)
    call lf_data_read_json(h, out)
    call check(str_eq(out, 'true'), 'read true')
    call lf_data_destroy(h)

    ! ---- Number with exponent ----
    h = lf_data_create('json_basic_8')
    rc = lf_data_write_json(h, '1.5e10')
    call check(rc == 1, 'write number')
    call lf_data_set_position(h, 0_c_int64_t)
    call lf_data_read_json(h, out)
    call check(str_eq(out, '1.5e10'), 'read number')
    call lf_data_destroy(h)

    ! ---- Escaped quotes inside a string ----
    h = lf_data_create('json_basic_9')
    rc = lf_data_write_json(h, '{"msg":"say \"hi\""}')
    call check(rc == 1, 'write escaped quotes')
    call lf_data_set_position(h, 0_c_int64_t)
    call lf_data_read_json(h, out)
    call check(str_eq(out, '{"msg":"say \"hi\""}'), 'read escaped quotes')
    call lf_data_destroy(h)
  end subroutine test_basic_json

  ! -----------------------------------------------------------------
  ! 2. NUL termination contract
  ! -----------------------------------------------------------------
  subroutine test_nul_termination()
    type(c_ptr) :: h
    character(len=:), allocatable :: out
    integer(c_int64_t) :: sz, n
    character(kind=c_char), dimension(16) :: buf
    integer(c_int) :: rc

    write(*, '(A)') ''
    write(*, '(A)') '=== NUL termination contract ==='

    ! ---- size = len(json) + 1 ----
    h = lf_data_create('json_nul_1')
    rc = lf_data_write_json(h, '{"a":1}')
    sz = lf_data_get_size(h)
    call check(sz == 8_c_int64_t, 'size = len(json) + 1')

    ! ---- last byte is NUL ----
    call lf_data_set_position(h, 0_c_int64_t)
    call lf_data_read_string_bytes(h, buf, 16_c_int64_t, n)
    call check(n == 7_c_int64_t, 'read_string_bytes returns 7')
    call check(ichar(buf(8)) == 0, 'last byte is NUL')

    call lf_data_destroy(h)

    ! ---- Empty payload (just the NUL) ----
    h = lf_data_create('json_nul_2')
    rc = lf_data_write_json(h, '')
    call check(rc == 1, 'write empty json')
    sz = lf_data_get_size(h)
    call check(sz == 1_c_int64_t, 'empty json: size = 1')
    call lf_data_set_position(h, 0_c_int64_t)
    call lf_data_read_json(h, out)
    call check(len(out) == 0, 'empty json reads as empty')
    call lf_data_destroy(h)
  end subroutine test_nul_termination

  ! -----------------------------------------------------------------
  ! 3. Wire format invariant
  !
  ! {"a":1} must produce exactly these 8 bytes:
  !   7B 22 61 22 3A 31 7D 00
  ! -----------------------------------------------------------------
  subroutine test_wire_format()
    type(c_ptr) :: h
    character(kind=c_char), dimension(16) :: raw_buf
    integer(c_int64_t) :: n
    integer :: b(8), i
    integer(c_int) :: rc

    write(*, '(A)') ''
    write(*, '(A)') '=== Wire format invariant ==='

    h = lf_data_create('json_wire')
    call check(c_associated(h), 'handle created')
    rc = lf_data_write_json(h, '{"a":1}')
    call check(rc == 1, 'write {"a":1}')

    call lf_data_set_position(h, 0_c_int64_t)
    n = lf_data_read_all_bytes(h, raw_buf, 16_c_int64_t)
    call check(n == 8_c_int64_t, 'wire size = 8')

    do i = 1, 8
      b(i) = ichar(raw_buf(i))
    end do

    call check(b(1) == 123, 'byte 1 = 0x7B (open brace)')
    call check(b(2) ==  34, 'byte 2 = 0x22 (quote)')
    call check(b(3) ==  97, 'byte 3 = 0x61 (a)')
    call check(b(4) ==  34, 'byte 4 = 0x22 (quote)')
    call check(b(5) ==  58, 'byte 5 = 0x3A (colon)')
    call check(b(6) ==  49, 'byte 6 = 0x31 (1)')
    call check(b(7) == 125, 'byte 7 = 0x7D (close brace)')
    call check(b(8) ==   0, 'byte 8 = 0x00 (NUL)')

    call lf_data_destroy(h)
  end subroutine test_wire_format

  ! -----------------------------------------------------------------
  ! 4. UTF-8 byte preservation
  !
  ! Multi-byte UTF-8 characters must pass through unchanged.
  ! The test constructs the byte sequences with char() so that the
  ! source file itself can stay ASCII-only.
  ! -----------------------------------------------------------------
  subroutine test_utf8()
    type(c_ptr) :: h
    character(len=:), allocatable :: out
    character(len=:), allocatable :: payload
    integer(c_int) :: rc

    write(*, '(A)') ''
    write(*, '(A)') '=== UTF-8 byte preservation ==='

    ! ---- Chinese: 中 is E4 B8 AD in UTF-8 ----
    payload = '{"msg":"' // char(228) // char(184) // char(173) // '"}'

    h = lf_data_create('json_utf8_1')
    rc = lf_data_write_json(h, payload)
    call check(rc == 1, 'write Chinese JSON')
    call lf_data_set_position(h, 0_c_int64_t)
    call lf_data_read_json(h, out)
    call check(str_eq(out, payload), 'Chinese UTF-8 round-trip')
    call lf_data_destroy(h)

    ! ---- Emoji: 🌍 is F0 9F 8C 8D in UTF-8 ----
    payload = '{"emoji":"' // char(240) // char(159) // char(140) // char(141) // '"}'

    h = lf_data_create('json_utf8_2')
    rc = lf_data_write_json(h, payload)
    call check(rc == 1, 'write emoji JSON')
    call lf_data_set_position(h, 0_c_int64_t)
    call lf_data_read_json(h, out)
    call check(str_eq(out, payload), 'Emoji UTF-8 round-trip')
    call lf_data_destroy(h)
  end subroutine test_utf8

  ! -----------------------------------------------------------------
  ! 5. Raw byte API
  ! -----------------------------------------------------------------
  subroutine test_raw_bytes()
    type(c_ptr) :: h
    integer(c_int64_t) :: n, sz
    character(kind=c_char), dimension(5) :: payload
    character(kind=c_char), dimension(8) :: buf
    integer(c_int) :: rc

    write(*, '(A)') ''
    write(*, '(A)') '=== Raw byte API ==='

    ! ---- Embedded NUL preserved in the buffer ----
    h = lf_data_create('json_raw_1')
    payload(1) = char(97, c_char)   ! 'a'
    payload(2) = char(0, c_char)
    payload(3) = char(98, c_char)   ! 'b'
    payload(4) = char(0, c_char)
    payload(5) = char(99, c_char)   ! 'c'

    rc = lf_data_write_string_bytes(h, payload, 5_c_int64_t)
    call check(rc == 1, 'write with embedded NULs')
    sz = lf_data_get_size(h)
    call check(sz == 6_c_int64_t, 'size = 5 data + 1 framing NUL')
    call lf_data_destroy(h)

    ! ---- read_string_bytes stops at the first NUL ----
    h = lf_data_create('json_raw_2')
    payload(1) = char(97, c_char)
    payload(2) = char(0, c_char)
    payload(3) = char(98, c_char)
    payload(4) = char(0, c_char)
    payload(5) = char(99, c_char)
    rc = lf_data_write_string_bytes(h, payload, 5_c_int64_t)
    call check(rc == 1, 'write payload')

    call lf_data_set_position(h, 0_c_int64_t)
    call lf_data_read_string_bytes(h, buf, 8_c_int64_t, n)
    call check(n == 1_c_int64_t, 'read_string_bytes stops at first NUL')
    call check(ichar(buf(1)) == 97, 'first byte is a')
    call lf_data_destroy(h)

    ! ---- read_all_bytes returns the entire buffer ----
    h = lf_data_create('json_raw_3')
    payload(1) = char(97, c_char)
    payload(2) = char(0, c_char)
    payload(3) = char(98, c_char)
    payload(4) = char(0, c_char)
    payload(5) = char(99, c_char)
    rc = lf_data_write_string_bytes(h, payload, 5_c_int64_t)
    call check(rc == 1, 'write payload')

    call lf_data_set_position(h, 0_c_int64_t)
    n = lf_data_read_all_bytes(h, buf, 8_c_int64_t)
    call check(n == 6_c_int64_t, 'read_all_bytes returns 6 (5 + framing)')
    call lf_data_destroy(h)

    ! ---- Empty string_bytes ----
    h = lf_data_create('json_raw_4')
    rc = lf_data_write_string_bytes(h, payload, 0_c_int64_t)
    call check(rc == 1, 'write empty string_bytes')
    sz = lf_data_get_size(h)
    call check(sz == 1_c_int64_t, 'empty payload: size = 1 (just NUL)')
    call lf_data_destroy(h)
  end subroutine test_raw_bytes

  ! -----------------------------------------------------------------
  ! 6. Fault-tolerant read
  ! -----------------------------------------------------------------
  subroutine test_fault_tolerant()
    type(c_ptr) :: h
    character(len=:), allocatable :: out
    integer(c_int64_t) :: sz
    character(kind=c_char), dimension(7) :: payload
    integer(c_int) :: rc

    write(*, '(A)') ''
    write(*, '(A)') '=== Fault-tolerant read ==='

    h = lf_data_create('json_fault')
    payload(1) = char(123, c_char)   ! {
    payload(2) = char(34, c_char)    ! "
    payload(3) = char(97, c_char)    ! a
    payload(4) = char(34, c_char)    ! "
    payload(5) = char(58, c_char)    ! :
    payload(6) = char(49, c_char)    ! 1
    payload(7) = char(125, c_char)   ! }
    ! No framing NUL appended.
    rc = lf_data_write_bytes(h, payload, 7_c_int64_t)
    call check(rc == 1, 'write raw bytes without NUL')

    sz = lf_data_get_size(h)
    call check(sz == 7_c_int64_t, 'no trailing NUL: size = 7')

    call lf_data_set_position(h, 0_c_int64_t)
    call lf_data_read_json(h, out)
    call check(str_eq(out, '{"a":1}'), 'fault-tolerant read of raw JSON')
    call lf_data_destroy(h)
  end subroutine test_fault_tolerant

  ! -----------------------------------------------------------------
  ! 7. Cursor and size
  ! -----------------------------------------------------------------
  subroutine test_cursor()
    type(c_ptr) :: h
    character(len=:), allocatable :: out1, out2
    integer(c_int64_t) :: pos, sz
    integer(c_int) :: rc

    write(*, '(A)') ''
    write(*, '(A)') '=== Cursor and size ==='

    h = lf_data_create('json_cursor')
    rc = lf_data_write_json(h, '{"x":1}')
    call check(rc == 1, 'write first')
    sz = lf_data_get_size(h)
    call check(sz == 8_c_int64_t, 'size after first write')

    rc = lf_data_write_json(h, '{"y":2}')
    call check(rc == 1, 'write second')
    sz = lf_data_get_size(h)
    call check(sz == 16_c_int64_t, 'size after second write')

    ! ---- Read both payloads by seeking back ----
    call lf_data_set_position(h, 0_c_int64_t)
    pos = lf_data_get_position(h)
    call check(pos == 0_c_int64_t, 'position = 0 after seek')

    call lf_data_read_json(h, out1)
    call check(str_eq(out1, '{"x":1}'), 'first payload')

    pos = lf_data_get_position(h)
    call check(pos == 8_c_int64_t, 'position = 8 after first read')

    call lf_data_read_json(h, out2)
    call check(str_eq(out2, '{"y":2}'), 'second payload')

    pos = lf_data_get_position(h)
    call check(pos == 16_c_int64_t, 'position = 16 after second read')

    call lf_data_destroy(h)
  end subroutine test_cursor

  ! -----------------------------------------------------------------
  ! 8. Buffer too small
  ! -----------------------------------------------------------------
  subroutine test_buffer_too_small()
    type(c_ptr) :: h
    integer(c_int64_t) :: n, pos_before, pos_after
    character(kind=c_char), dimension(4) :: small
    integer(c_int) :: rc

    write(*, '(A)') ''
    write(*, '(A)') '=== Buffer too small ==='

    h = lf_data_create('json_small_buf')
    rc = lf_data_write_json(h, '{"key":"value"}')
    call check(rc == 1, 'write payload')

    call lf_data_set_position(h, 0_c_int64_t)
    pos_before = lf_data_get_position(h)
    call lf_data_read_string_bytes(h, small, 4_c_int64_t, n)
    call check(n == -1_c_int64_t, 'small buffer rejected')
    pos_after = lf_data_get_position(h)
    call check(pos_after == pos_before, 'cursor unchanged on failure')

    call lf_data_destroy(h)
  end subroutine test_buffer_too_small

  ! -----------------------------------------------------------------
  ! 9. Multiple payloads in one handle
  ! -----------------------------------------------------------------
  subroutine test_multiple_payloads()
    type(c_ptr) :: h
    character(len=:), allocatable :: a, b, c
    integer(c_int) :: rc

    write(*, '(A)') ''
    write(*, '(A)') '=== Multiple payloads in one handle ==='

    h = lf_data_create('json_multi')
    rc = lf_data_write_json(h, '{"a":1}')
    call check(rc == 1, 'write first')
    rc = lf_data_write_json(h, '{"b":2}')
    call check(rc == 1, 'write second')
    rc = lf_data_write_json(h, '{"c":3}')
    call check(rc == 1, 'write third')

    call lf_data_set_position(h, 0_c_int64_t)
    call lf_data_read_json(h, a)
    call lf_data_read_json(h, b)
    call lf_data_read_json(h, c)

    call check(str_eq(a, '{"a":1}'), 'first payload')
    call check(str_eq(b, '{"b":2}'), 'second payload')
    call check(str_eq(c, '{"c":3}'), 'third payload')

    call lf_data_destroy(h)
  end subroutine test_multiple_payloads

  ! -----------------------------------------------------------------
  ! 10. Large payload
  ! -----------------------------------------------------------------
  subroutine test_large_json()
    type(c_ptr) :: h
    character(len=16384) :: big
    character(len=:), allocatable :: out
    integer :: p, i
    integer(c_int) :: rc

    write(*, '(A)') ''
    write(*, '(A)') '=== Large JSON payload ==='

    ! Build: {"items":[1,1,1,...,1]} with 5000 ones.
    big(1:10) = '{"items":['
    p = 10
    do i = 1, 5000
      if (i > 1) then
        p = p + 1
        big(p:p) = ','
      end if
      p = p + 1
      big(p:p) = '1'
    end do
    p = p + 1
    big(p:p) = ']'
    p = p + 1
    big(p:p) = '}'

    h = lf_data_create('json_large')
    rc = lf_data_write_json(h, big(1:p))
    call check(rc == 1, 'write large JSON')
    call lf_data_set_position(h, 0_c_int64_t)
    call lf_data_read_json(h, out)
    call check(len(out) == p, 'large JSON length preserved')
    call check(out == big(1:p), 'large JSON content preserved')

    call lf_data_destroy(h)
  end subroutine test_large_json

  ! -----------------------------------------------------------------
  ! Test helper: byte-exact string equality.
  !
  ! Fortran's `==` pads the shorter operand with spaces before
  ! comparing, so two strings of different lengths can compare equal.
  ! This helper requires lengths to match first, which is what
  ! "byte-exact" means for these tests.
  ! -----------------------------------------------------------------
  function str_eq(s1, s2) result(eq)
    character(len=*), intent(in) :: s1, s2
    logical :: eq
    if (len(s1) /= len(s2)) then
      eq = .false.
      return
    end if
    eq = (s1 == s2)
  end function str_eq

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

end program test_lf_json_f