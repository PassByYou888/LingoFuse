! =============================================================================
! cross_node.f90
!
! Fortran worker node for the cross-language demo.
!
! Registers two Call APIs under application "demo":
!
!   add       (int32 a, int32 b) -> int32
!       Little-endian int32 pair in, little-endian int32 out.
!
!   inv_seri  (uint8, uint16, uint32, uint64, string(NUL), float32)
!             -> (float32, string(NUL), uint64, uint32, uint16, uint8)
!       Reads a typed sequence and echoes it back in reverse order.
!
! The wire format is identical to every other LingoFuse binding, so a
! C++, C#, Rust, Go, Python, or JavaScript caller can drive this node
! unchanged.
! =============================================================================

module cross_node_callbacks
  use iso_c_binding
  use lf_fortran_mod
  implicit none
  private
  public :: add_callback, inv_seri_callback

contains

  ! -----------------------------------------------------------------
  ! add(int32 a, int32 b) -> int32
  ! -----------------------------------------------------------------
  subroutine add_callback(input, output) bind(C)
    type(c_ptr), value :: input
    type(c_ptr), value :: output
    integer(c_int32_t) :: a, b, s

    if (lf_data_read_int32(input, a) /= 1) return
    if (lf_data_read_int32(input, b) /= 1) return

    s = a + b

    write(*, '(A,I0,A,I0,A,I0,A)') &
      '[Node] add(', a, ', ', b, ') = ', s, ''

    if (lf_data_write_int32(output, s) /= 1) return
  end subroutine add_callback

  ! -----------------------------------------------------------------
  ! inv_seri() -> reversed typed sequence
  ! -----------------------------------------------------------------
  subroutine inv_seri_callback(input, output) bind(C)
    type(c_ptr), value :: input
    type(c_ptr), value :: output
    integer(c_int8_t)   :: b
    integer(c_int16_t)  :: w
    integer(c_int32_t)  :: c
    integer(c_int64_t)  :: u64
    real(c_float)       :: f
    character(len=:), allocatable :: s

    if (lf_data_read_uint8(input, b)   /= 1) return
    if (lf_data_read_uint16(input, w)  /= 1) return
    if (lf_data_read_uint32(input, c)  /= 1) return
    if (lf_data_read_uint64(input, u64) /= 1) return
    call lf_data_read_string(input, s)
    if (lf_data_read_float32(input, f) /= 1) return

    write(*, '(A,I0,A,I0,A,I0,A,I0,A,A,A,F0.2,A)') &
      '[Node] inv_seri received: [', int(b), ', ', int(w), ', ', &
      int(c), ', ', u64, ', "', s, '", ', f, ']'

    if (lf_data_write_float32(output, f) /= 1) return
    if (lf_data_write_string(output, s) /= 1) return
    if (lf_data_write_uint64(output, u64) /= 1) return
    if (lf_data_write_uint32(output, c) /= 1) return
    if (lf_data_write_uint16(output, w) /= 1) return
    if (lf_data_write_uint8(output, b) /= 1) return

    write(*, '(A,F0.2,A,A,A,I0,A,I0,A,I0,A,I0,A)') &
      '[Node] inv_seri replied: [', f, ', "', s, '", ', u64, ', ', &
      int(c), ', ', int(w), ', ', int(b), ']'
  end subroutine inv_seri_callback

end module cross_node_callbacks


program cross_node
  use iso_c_binding
  use lf_fortran_mod
  use cross_node_callbacks
  implicit none

  type(c_ptr) :: app
  integer(c_int) :: rc
  character(len=8) :: line

  write(*, '(A)') '=== Cross Node (Fortran worker) ==='

  if (lf_load_library() /= 1) then
    write(*, '(A)') '[FATAL] lf_load_library failed.'
    stop 1
  end if

  app = lf_app_create('demo', 'Fortran worker node')
  if (.not. c_associated(app)) then
    write(*, '(A)') '[FATAL] lf_app_create failed.'
    stop 1
  end if

  rc = lf_app_register_call(app, 'add', &
                            'add(int a, int b) -> int', &
                            c_funloc(add_callback))
  if (rc /= 1) then
    write(*, '(A)') '[FATAL] Failed to register API "add".'
    stop 1
  end if

  rc = lf_app_register_call(app, 'inv_seri', &
                            'inv_seri() -> reversed typed sequence', &
                            c_funloc(inv_seri_callback))
  if (rc /= 1) then
    write(*, '(A)') '[FATAL] Failed to register API "inv_seri".'
    stop 1
  end if

  write(*, '(A)') &
    "[Node] Registered APIs 'add' and 'inv_seri' under application 'demo'."

  ! Deployment mode: allow the node to start before the beacon.
  call lf_set_option('Wait_Ready', 'False')

  call lf_reset_prepare()

  rc = lf_prepare_client('ipc:cross', app)
  if (rc < 0) then
    write(*, '(A)') '[FATAL] lf_prepare_client failed.'
    stop 1
  end if

  rc = lf_prepare_done()
  if (rc /= 1) then
    write(*, '(A)') '[FATAL] lf_prepare_done failed.'
    stop 1
  end if

  write(*, '(A)') '[Node] Online. Press Enter to exit...'
  read(*, '(A)') line

  call lf_exit_main_thread()
  call lf_app_destroy(app)
  call lf_shutdown()
  call lf_free_library()

  write(*, '(A)') '[Node] Bye.'
end program cross_node