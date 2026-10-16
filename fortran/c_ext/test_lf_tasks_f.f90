! =============================================================================
! test_lf_tasks_f.f90
!
! Test suite for the task-handle async module (lf_fortran_tasks).
!
! =============================================================================
! WHAT THIS SUITE VERIFIES
! =============================================================================
!
!   1.  Invalid task handling.
!   2.  Async submission against a local app, with a full round trip.
!   3.  Dispatch-failure path (target app does not exist).
!   4.  Slot exhaustion and reuse.
!
! =============================================================================
! PRE-REQUISITES FOR THE LOCAL-ROUND-TRIP TEST
! =============================================================================
!
! The test_async_submit_local section uses an IPC endpoint to route
! the async call through the mesh. For a self-contained single-process
! test, BOTH sides of that endpoint MUST be prepared before
! lf_prepare_done is called:
!
!     lf_prepare_service('ipc:lf_task_test', 'ipc:lf_task_test')
!     lf_prepare_client ('ipc:lf_task_test', app)
!
! Preparing only the client produces the C4 script
!
!     KeepAlive("ipc:lf_task_test", ...)
!
! with no matching
!
!     Service("Listen", ...)
!
! command in the prepare queue. LF_PrepareDone then waits for a
! connection that can never be established, Init_Succeeded remains
! False, and LF_PrepareDone returns 0. Every downstream check fails
! with "no connection".
!
! The dispatch-failure and slot-exhaustion sections do NOT prepare
! any client, so their prepare queues are empty. LF_PrepareDone sees
! an empty queue, Init_Succeeded becomes True immediately, and the
! call returns 1.
!
! All comments and status output are in English.
! =============================================================================

module test_tasks_callbacks
  use iso_c_binding
  use lf_fortran_mod
  implicit none
  private
  public :: add_callback

contains

  ! Local app callback for the "add" API.
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

end module test_tasks_callbacks


program test_lf_tasks
  use iso_c_binding
  use lf_fortran_mod
  use lf_fortran_tasks
  use test_tasks_callbacks
  implicit none

  integer :: g_passed = 0
  integer :: g_failed = 0

  write(*, '(A)') '=== LingoFuse task-handle async test suite ==='

  call test_invalid_task()
  call test_async_submit_local()
  call test_dispatch_failure()
  call test_slot_exhaustion()

  write(*, '(A)') ''
  write(*, '(A)') '=== Summary ==='
  write(*, '(A,I0)') '  Passed: ', g_passed
  write(*, '(A,I0)') '  Failed: ', g_failed

  if (g_failed == 0) then
    write(*, '(A)') ''
    write(*, '(A)') '[OK] All task-handle tests passed.'
  else
    write(*, '(A)') ''
    write(*, '(A,I0,A)') '[ERROR] ', g_failed, ' test(s) failed.'
    stop 1
  end if

contains

  ! ============================================================================
  ! Test 1: invalid task handling
  ! ============================================================================
  subroutine test_invalid_task()
    type(lf_task) :: t

    write(*, '(A)') ''
    write(*, '(A)') '=== Invalid task handling ==='

    t%slot = 0
    call check(.not. lf_task_is_valid(t), 'slot 0 is invalid')
    call check(.not. lf_task_is_ready(t), 'slot 0 is not ready')
    call check(.not. lf_task_is_ok(t),    'slot 0 is not ok')
    call check(lf_task_read_size(t) == -1_c_int64_t, 'read_size returns -1')
    call check(lf_task_read_int32(t) == 0_c_int32_t, 'read_int32 returns 0')

    call lf_task_free(t)   ! must be a no-op
    call check(t%slot == 0, 'free on invalid is a no-op')
  end subroutine test_invalid_task

  ! ============================================================================
  ! Test 2: async submission against a local app
  !
  ! This test exercises the full mesh path: a service and a client
  ! are created on the same process, a local app is bound to the
  ! client, and the async call is routed through the mesh back to
  ! that same process.
  !
  ! See the file-level docstring for why BOTH sides of the endpoint
  ! must be prepared.
  ! ============================================================================
  subroutine test_async_submit_local()
    type(c_ptr)   :: app, req
    type(lf_task) :: t
    integer(c_int)     :: rc
    integer(c_int32_t) :: sum
    integer :: i
    logical :: ready

    write(*, '(A)') ''
    write(*, '(A)') '=== Async submission with local app ==='

    ! ---- Prepare a fresh framework with a local app ----
    call lf_reset_prepare()

    app = lf_app_create('TaskTestApp', 'task async test')
    call check(c_associated(app), 'app created')

    rc = lf_app_register_call(app, 'add', 'add two ints', &
                              c_funloc(add_callback))
    call check(rc == 1, 'add registered')

    ! -----------------------------------------------------------------
    ! Prepare BOTH sides of the IPC endpoint.
    !
    ! Without the matching service, LF_PrepareDone would register a
    ! KeepAlive command for a listener that does not exist, time out
    ! waiting for the connection, and return 0. Every downstream check
    ! would then fail with "no connection".
    !
    ! A return value of -1 from LF_PrepareService indicates a duplicate
    ! or invalid address; any non-negative value is a valid tag.
    ! -----------------------------------------------------------------
    rc = lf_prepare_service('ipc:lf_task_test', 'ipc:lf_task_test')
    call check(rc >= 0, 'prepare_service accepted')

    rc = lf_prepare_client('ipc:lf_task_test', app)
    call check(rc >= 0, 'prepare_client accepted')

    rc = lf_prepare_done()
    call check(rc == 1, 'prepare_done succeeded')

    ! Wait for the local app to appear on the mesh.
    ready = .false.
    do i = 1, 50
      if (lf_check_app('TaskTestApp')) then
        ready = .true.
        exit
      end if
      call sleep_ms(100)
    end do
    call check(ready, 'app visible on the mesh')

    ! ---- Submit an async call ----
    req = lf_data_create('add')
    call check(c_associated(req), 'request handle created')
    rc = lf_data_write_int32(req, 5_c_int32_t)
    rc = lf_data_write_int32(req, 7_c_int32_t)

    t = lf_async_submit('TaskTestApp', req)
    call lf_data_destroy(req)

    call check(lf_task_is_valid(t), 'task slot acquired')

    ! Wait for the task to become ready.
    ready = .false.
    do i = 1, 500
      if (lf_task_is_ready(t)) then
        ready = .true.
        exit
      end if
      call sleep_ms(10)
    end do
    call check(ready, 'task became ready within 5 seconds')

    call check(lf_task_is_ok(t), 'task reports success')

    sum = lf_task_read_int32(t)
    call check(sum == 12_c_int32_t, '5 + 7 = 12 via task handle')

    call lf_task_free(t)
    call check(.not. lf_task_is_valid(t), 'task handle invalid after free')

    ! ---- Tear down ----
    call lf_exit_main_thread()
    call lf_app_destroy(app)
    call lf_shutdown()
  end subroutine test_async_submit_local

  ! ============================================================================
  ! Test 3: dispatch failure
  !
  ! An empty prepare queue is enough: LF_PrepareDone returns 1
  ! immediately because Init_Succeeded is set unconditionally when
  ! there is nothing to wait for. LF_Async_Call then finds no client
  ! and returns 0, triggering the synchronous dispatch-failure path.
  ! ============================================================================
  subroutine test_dispatch_failure()
    type(c_ptr)   :: req
    type(lf_task) :: t
    integer       :: i
    logical :: ready
    integer(c_int) :: rc

    write(*, '(A)') ''
    write(*, '(A)') '=== Dispatch failure ==='

    ! Prepare a minimal framework with NO service and NO client.
    call lf_reset_prepare()
    rc = lf_prepare_done()
    call check(rc == 1, 'prepare_done for dispatch-failure test')

    req = lf_data_create('anything')
    call check(c_associated(req), 'request handle created')
    rc = lf_data_write_int32(req, 0_c_int32_t)

    t = lf_async_submit('__no_such_app__', req)
    call lf_data_destroy(req)

    call check(lf_task_is_valid(t), 'task slot acquired')

    ! Because dispatch fails, the callback runs synchronously and the
    ! task should already be ready when lf_async_submit returns.
    ready = .false.
    do i = 1, 100
      if (lf_task_is_ready(t)) then
        ready = .true.
        exit
      end if
      call sleep_ms(10)
    end do
    call check(ready, 'task became ready')
    call check(.not. lf_task_is_ok(t), 'task reports failure')

    call lf_task_free(t)

    call lf_exit_main_thread()
    call lf_shutdown()
  end subroutine test_dispatch_failure

  ! ============================================================================
  ! Test 4: slot exhaustion and reuse
  !
  ! Also uses an empty prepare queue. Every submission fails
  ! synchronously (no client), so each slot transitions to
  ! "completed with ok = .false." and can be freed.
  ! ============================================================================
  subroutine test_slot_exhaustion()
    type(lf_task), allocatable :: tasks(:)
    type(c_ptr)   :: req
    integer       :: i, valid_count, invalid_count
    integer       :: max_slots
    integer(c_int) :: rc

    write(*, '(A)') ''
    write(*, '(A)') '=== Slot exhaustion and reuse ==='

    call lf_reset_prepare()
    rc = lf_prepare_done()
    call check(rc == 1, 'prepare_done for slot-exhaustion test')

    max_slots = 256
    allocate(tasks(max_slots))

    valid_count   = 0
    invalid_count = 0

    do i = 1, max_slots
      req = lf_data_create('nothing')
      if (.not. c_associated(req)) then
        tasks(i)%slot = 0
        invalid_count = invalid_count + 1
        cycle
      end if
      tasks(i) = lf_async_submit('__no_such_app__', req)
      call lf_data_destroy(req)

      if (lf_task_is_valid(tasks(i))) then
        valid_count = valid_count + 1
      else
        invalid_count = invalid_count + 1
      end if
    end do

    call check(valid_count > 0, 'at least one slot was acquired')
    call check(invalid_count > 0, 'at least one slot was exhausted')

    ! Free all tasks so the next submission can reuse slots.
    do i = 1, max_slots
      if (lf_task_is_valid(tasks(i))) then
        call lf_task_free(tasks(i))
      end if
    end do

    ! Verify a fresh submission still succeeds.
    req = lf_data_create('nothing')
    if (c_associated(req)) then
      tasks(1) = lf_async_submit('__no_such_app__', req)
      call lf_data_destroy(req)
      call check(lf_task_is_valid(tasks(1)), &
                 'slot is reusable after free')
      call lf_task_free(tasks(1))
    end if

    deallocate(tasks)

    call lf_exit_main_thread()
    call lf_shutdown()
  end subroutine test_slot_exhaustion

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

  ! Portable sleep. On Windows we call Sleep() from kernel32.
  ! Non-Windows builds must supply an equivalent.
  !
  ! The inner dummy argument is named `ms_val` to avoid masking the
  ! outer `ms` argument of this host procedure, which some compilers
  ! warn about with -Wsurprising.
  subroutine sleep_ms(ms)
    integer, intent(in) :: ms
    interface
      subroutine c_sleep(ms_val) bind(C, name="Sleep")
        import :: c_int32_t
        integer(c_int32_t), value :: ms_val
      end subroutine c_sleep
    end interface
    call c_sleep(int(ms, c_int32_t))
  end subroutine sleep_ms

end program test_lf_tasks