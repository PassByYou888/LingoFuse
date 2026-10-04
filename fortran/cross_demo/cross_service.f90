! =============================================================================
! cross_service.f90
!
! Fortran beacon for the cross-language demo.
!
! Creates the IPC endpoint "ipc:cross" and idles until the user presses
! Enter. It does not register any API and does not attach an
! application. Its only job is to serve as the discovery anchor that
! the node and the caller connect to.
!
! Run this first, then start the node, then the caller.
! =============================================================================

program cross_service
  use iso_c_binding
  use lf_fortran_mod
  implicit none

  integer(c_int) :: rc
  character(len=8) :: line

  write(*, '(A)') '=== Cross Service (Fortran beacon) ==='

  if (lf_load_library() /= 1) then
    write(*, '(A)') '[FATAL] lf_load_library failed.'
    stop 1
  end if

  ! Deployment mode: do not block prepare_done waiting for clients.
  call lf_set_option('Wait_Ready', 'False')

  call lf_reset_prepare()

  rc = lf_prepare_service('ipc:cross', 'ipc:cross')
  if (rc < 0) then
    write(*, '(A)') '[FATAL] lf_prepare_service failed (duplicate address?).'
    stop 1
  end if

  rc = lf_prepare_done()
  if (rc /= 1) then
    write(*, '(A)') '[FATAL] lf_prepare_done failed.'
    stop 1
  end if

  write(*, '(A)') "[Service] IPC service 'ipc:cross' is running."
  write(*, '(A)') '[Service] Press Enter to exit...'
  read(*, '(A)') line

  call lf_exit_main_thread()
  call lf_shutdown()
  call lf_free_library()

  write(*, '(A)') '[Service] Bye.'
end program cross_service