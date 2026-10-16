! =============================================================================
! cross_node.f90
!
! Fortran worker node for the cross-language demo.
!
! =============================================================================
! REGISTERED APIS
! =============================================================================
!
! App-bound (under application "demo"):
!
!   add       (int32 a, int32 b) -> int32
!       Little-endian int32 pair in, little-endian int32 out.
!
!   inv_seri  (uint8, uint16, uint32, uint64, string(NUL), float32)
!             -> (float32, string(NUL), uint64, uint32, uint16, uint8)
!       Reads a typed sequence and echoes it back in reverse order.
!
!   whoami    () -> (32-byte UID)(NUL-terminated UTF-8 P2PName)
!       Returns the CALLER'S identity, as read from the framework's
!       side data on the inbound request. This is the standard
!       "whoami" pattern: a client can discover its own session UID
!       and P2P group name by calling this API on any mesh peer.
!
! Process-wide P2P (registered under LF_P2P_APP):
!
!   p2p_ping  () -> "pong"
!       Reachable via UID or P2PName addressing, NOT via App name.
!       Demonstrates that a process-wide API can be called by any
!       peer that knows the target's UID or P2P group.
!
! =============================================================================
! P2P GROUP MEMBERSHIP
! =============================================================================
!
! The node joins the P2P group "demo_group". A caller can therefore
! reach it with:
!
!     lf_call_p2pname('demo_group', req, ms)
!
! The server-side dispatcher picks a target among the group members
! (load balancing / sticky affinity). In this single-node demo, the
! node is the only member, so the call is always dispatched to it.
!
! =============================================================================
! WIRE FORMAT
! =============================================================================
!
! The wire format is identical to every other LingoFuse binding, so a
! C++, C#, Rust, Go, Python, or JavaScript caller can drive this node
! unchanged.
!
! =============================================================================

module cross_node_callbacks
  use iso_c_binding
  use lf_fortran_mod
  implicit none
  private
  public :: add_callback, inv_seri_callback
  public :: whoami_callback, p2p_ping_callback

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

  ! -----------------------------------------------------------------
  ! whoami() -> (32-byte UID)(NUL-terminated UTF-8 P2PName)
  !
  ! Reads the caller's identity from the framework-injected side data
  ! on the input handle, then echoes it back. This is the standard
  ! pattern by which a client discovers its own session UID:
  !
  !     client -> LF_Call('demo', whoami, ...)
  !                   |
  !                   v
  !     server-side whoami callback:
  !         uid  = LF_Get_P2P_UID(input)    <- the CALLER's UID
  !         name = LF_Get_P2P_Name(input)   <- the CALLER's P2P group
  !                   |
  !                   v
  !     writes [32-byte uid][name\0] to output
  !
  ! The framework's side-data fields are only valid on the `input`
  ! handle of a callback. Our bridge copies them into stack buffers
  ! immediately, so this callback never touches the library's
  ! transient ~5s pointers.
  ! -----------------------------------------------------------------
  subroutine whoami_callback(input, output) bind(C)
    type(c_ptr), value :: input
    type(c_ptr), value :: output
    integer(c_int8_t) :: uid(LF_UID_BYTE_COUNT)
    character(len=:), allocatable :: name
    integer(c_int) :: rc
    integer :: i

    rc = lf_data_get_p2p_uid(input, uid)
    if (rc /= 1) return
    call lf_data_get_p2p_name(input, name)

    ! Write the identity back as [32 bytes UID][NUL-terminated UTF-8 name]
    if (lf_data_write_uid(output, uid) /= 1) return
    if (lf_data_write_string(output, name) /= 1) return

    ! Console trace: print the first 8 bytes of the UID in hex.
    write(*, '(A)', advance='no') '[Node] whoami: uid='
    do i = 1, 8
      write(*, '(Z2.2)', advance='no') iand(int(uid(i), c_int), 255)
    end do
    write(*, '(A,A,A)') '.. name="', name, '"'
  end subroutine whoami_callback

  ! -----------------------------------------------------------------
  ! p2p_ping() -> "pong"
  !
  ! Registered as a process-wide P2P API. Reachable via UID or
  ! P2PName addressing only. Demonstrates that a globally-discoverable
  ! utility API can be called by any peer in the mesh.
  ! -----------------------------------------------------------------
  subroutine p2p_ping_callback(input, output) bind(C)
    type(c_ptr), value :: input
    type(c_ptr), value :: output

    ! Suppress -Wunused-dummy-argument. The input handle carries no
    ! payload for this API, so it is intentionally unused. Fortran
    ! 2008 has no "unused" attribute and no portable pragma;
    ! referencing the argument in an unreachable branch is the
    ! standard workaround. CONTINUE is a no-op.
    if (c_associated(input)) continue

    write(*, '(A)') '[Node] p2p_ping received'

    if (lf_data_write_string(output, 'pong') /= 1) return
  end subroutine p2p_ping_callback

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

  ! -----------------------------------------------------------------
  ! Join the P2P group "demo_group".
  !
  ! The framework reports this group name to the server on the next
  ! outbound request. From that point on, any peer that knows the
  ! group name can reach this node with lf_call_p2pname().
  ! -----------------------------------------------------------------
  call lf_set_opt_p2p_name('demo_group')

  ! -----------------------------------------------------------------
  ! Create the "demo" app and register the app-bound APIs.
  ! -----------------------------------------------------------------
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

  rc = lf_app_register_call(app, 'whoami', &
                            'return caller UID (32 bytes) + P2PName', &
                            c_funloc(whoami_callback))
  if (rc /= 1) then
    write(*, '(A)') '[FATAL] Failed to register API "whoami".'
    stop 1
  end if

  ! -----------------------------------------------------------------
  ! Register a process-wide P2P API.
  !
  ! p2p_ping is reachable via UID addressing and P2PName addressing
  ! ONLY. It is NOT reachable via App-name addressing, even though
  ! its name does not collide with any app-bound API.
  ! -----------------------------------------------------------------
  rc = lf_register_p2p_call('p2p_ping', &
                            'return the string "pong"', &
                            c_funloc(p2p_ping_callback))
  if (rc /= 1) then
    write(*, '(A)') '[FATAL] Failed to register P2P API "p2p_ping".'
    stop 1
  end if

  write(*, '(A)') &
    "[Node] Registered app-bound APIs 'add', 'inv_seri', 'whoami'"
  write(*, '(A)') &
    "[Node] Registered P2P API 'p2p_ping'"
  write(*, '(A)') &
    "[Node] Joined P2P group 'demo_group'"

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