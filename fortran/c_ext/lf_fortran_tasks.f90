! =============================================================================
! lf_fortran_tasks.f90
!
! Optional extension module: callback-free asynchronous invocation.
!
! =============================================================================
! WHAT THIS MODULE IS FOR
! =============================================================================
!
! The core lf_fortran_mod module exposes asynchronous calls in the
! standard way: the caller supplies a bind(C) callback via c_funloc,
! and the framework invokes it on a TCompute worker thread when the
! result arrives. That is the "closest to Erlang" form Fortran can
! express, but it still requires the caller to declare a callback
! procedure in a module and to bridge any needed context through a
! user_data pointer.
!
! This module offers the alternative "task handle" model:
!
!     type(lf_task) :: t
!     t = lf_async_submit('demo', req)   ! returns immediately
!     ...
!     if (lf_task_is_ready(t)) then
!         v = lf_task_read_int32(t)
!         call lf_task_free(t)
!     end if
!
! The caller never writes a callback. Under the hood, a SINGLE shared
! callback (task_callback) is registered with the framework for every
! submission; it copies the result payload into a per-task slot and
! marks the slot as completed.
!
! =============================================================================
! DESIGN NOTES
! =============================================================================
!
!   * Slot table.
!     MAX_TASKS slots are managed by this module. Each slot has a
!     state field (0 = free, 1 = pending, 2 = completed) and a fixed
!     payload buffer. The payload size is controlled by
!     lf_task_set_max_payload; the default is 64 KiB.
!
!   * Slot allocation is lazy.
!     The payload buffers are allocated on the FIRST call to
!     lf_async_submit (or lf_async_submit_uid / _p2pname), never
!     inside a callback. Allocation from a non-main thread is not
!     portable across Fortran runtimes, so we avoid it entirely.
!
!   * Thread safety.
!     Fortran 2008 has neither coarrays nor a portable interlocked
!     intrinsic available under -std=f2008. The few shared fields that
!     are touched from both the caller thread and the TCompute worker
!     thread are therefore accessed through three tiny C helpers
!     (lf_task_atomic_cas_int / lf_task_atomic_store_int /
!     lf_task_atomic_load_int) declared in lf_task_support.h.
!
!     The C helpers use GCC/Clang __atomic_* builtins (or the MSVC
!     Interlocked* family) with explicit acquire/release ordering. The
!     Fortran side performs no reordering of its own between the state
!     transition and the payload reads/writes because every state
!     access crosses an external function call, which acts as a full
!     compiler barrier.
!
!   * Result lifetime.
!     The framework owns the result handle and releases it the
!     instant the callback returns. task_callback therefore copies
!     the entire payload out of the handle BEFORE returning. The
!     copied bytes live in the slot until lf_task_free.
!
!   * Byte order.
!     The task_* read functions use Fortran's TRANSFER intrinsic,
!     which reinterprets the byte pattern. LingoFuse only supports
!     little-endian platforms (see LingoFuse.h), so TRANSFER produces
!     the expected value on every supported target.
!
!   * Slot exhaustion.
!     If all MAX_TASKS slots are in use (pending or completed but not
!     yet freed), lf_async_submit returns a task with slot = 0. The
!     caller must check lf_task_is_valid. The module never evicts a
!     slot that the caller has not freed.
!
! =============================================================================
! USAGE EXAMPLE
! =============================================================================
!
!     program demo
!       use iso_c_binding
!       use lf_fortran_mod
!       use lf_fortran_tasks
!       implicit none
!
!       type(c_ptr)   :: req
!       type(lf_task) :: t
!       integer(c_int32_t) :: sum
!       integer :: i
!
!       ! ... prepare the framework ...
!
!       req = lf_data_create('add')
!       rc = lf_data_write_int32(req, 5_c_int32_t)
!       rc = lf_data_write_int32(req, 7_c_int32_t)
!
!       t = lf_async_submit('demo', req)
!       call lf_data_destroy(req)
!
!       if (.not. lf_task_is_valid(t)) then
!         print *, 'could not allocate a task slot'
!         stop 1
!       end if
!
!       do i = 1, 500
!         if (lf_task_is_ready(t)) exit
!         call sleep_ms(10)
!       end do
!
!       if (lf_task_is_ok(t)) then
!         sum = lf_task_read_int32(t)
!         print *, '5 + 7 =', sum
!       end if
!       call lf_task_free(t)
!
!     end program
!
! =============================================================================
! All comments and status output are in English.
! =============================================================================

module lf_fortran_tasks
  use iso_c_binding
  use lf_fortran_mod
  implicit none
  private

  ! ============================================================================
  ! Public API
  ! ============================================================================

  public :: lf_task

  public :: lf_async_submit, lf_async_submit_uid, lf_async_submit_p2pname

  public :: lf_task_is_valid, lf_task_is_ready, lf_task_is_ok

  public :: lf_task_read_int32,   lf_task_read_int64
  public :: lf_task_read_float32, lf_task_read_float64
  public :: lf_task_read_string
  public :: lf_task_read_size

  public :: lf_task_free
  public :: lf_task_set_max_payload

  ! ============================================================================
  ! Configuration
  ! ============================================================================

  integer, parameter :: MAX_TASKS = 64

  integer(c_int64_t), parameter :: DEFAULT_MAX_PAYLOAD = 65536_c_int64_t

  ! ============================================================================
  ! Public task handle
  ! ============================================================================

  type :: lf_task
    integer :: slot = 0   ! 0 = invalid, otherwise 1..MAX_TASKS
  end type lf_task

  ! ============================================================================
  ! C atomic helpers (declared in lf_task_support.h)
  !
  ! The Fortran side never performs atomic operations itself: it calls
  ! these functions, which are implemented in C using the compiler's
  ! native atomic builtins. Every call is an external function call,
  ! which acts as a compiler barrier for the Fortran side.
  ! ============================================================================

  interface
    function c_atomic_cas_int(x, expected, new_val) &
        bind(C, name="lf_task_atomic_cas_int") result(old)
      import :: c_int
      integer(c_int) :: x
      integer(c_int), value :: expected
      integer(c_int), value :: new_val
      integer(c_int) :: old
    end function c_atomic_cas_int

    subroutine c_atomic_store_int(x, val) &
        bind(C, name="lf_task_atomic_store_int")
      import :: c_int
      integer(c_int) :: x
      integer(c_int), value :: val
    end subroutine c_atomic_store_int

    function c_atomic_load_int(x) &
        bind(C, name="lf_task_atomic_load_int") result(val)
      import :: c_int
      integer(c_int) :: x
      integer(c_int) :: val
    end function c_atomic_load_int
  end interface

  ! ============================================================================
  ! Internal slot state
  ! ============================================================================

  type :: task_slot_t
    integer(c_int) :: state = 0_c_int        ! 0=free, 1=pending, 2=completed
    logical        :: ok = .false.
    integer(c_int64_t) :: payload_size = 0_c_int64_t
    character(kind=c_char), allocatable :: payload(:)
  end type task_slot_t

  type(task_slot_t) :: g_slots(MAX_TASKS)

  ! Spin lock, initialized to 0 = unlocked.
  integer(c_int) :: g_lock = 0_c_int

  ! Initialization state:
  !   0 = not initialized
  !   1 = in progress
  !   2 = done
  integer(c_int) :: g_initialized = 0_c_int

  ! Round-robin hint for the "find a free slot" scan.
  integer :: g_last_slot = 0

  ! Payload buffer size, configurable.
  integer(c_int64_t) :: g_max_payload = DEFAULT_MAX_PAYLOAD

contains

  ! ============================================================================
  ! Spin lock primitives
  ! ============================================================================

  subroutine task_lock()
    integer(c_int) :: old
    do
      old = c_atomic_cas_int(g_lock, 0_c_int, 1_c_int)
      if (old == 0_c_int) exit
    end do
  end subroutine task_lock

  subroutine task_unlock()
    call c_atomic_store_int(g_lock, 0_c_int)
  end subroutine task_unlock

  ! ============================================================================
  ! Lazy initialization
  !
  ! Runs exactly once per process. The winner allocates the payload
  ! buffers on the calling thread; the loser waits for the winner to
  ! finish. After this returns, every slot is in the "free" state and
  ! every payload buffer is allocated.
  ! ============================================================================

  subroutine ensure_initialized()
    integer(c_int) :: old
    integer :: i

    old = c_atomic_cas_int(g_initialized, 0_c_int, 1_c_int)

    if (old == 0_c_int) then
      ! ---- Winner: perform the actual initialization ----
      call task_lock
      do i = 1, MAX_TASKS
        if (.not. allocated(g_slots(i)%payload)) then
          allocate(character(kind=c_char) :: &
                   g_slots(i)%payload(g_max_payload))
          g_slots(i)%payload = c_null_char
        end if
        g_slots(i)%state        = 0_c_int
        g_slots(i)%ok           = .false.
        g_slots(i)%payload_size = 0_c_int64_t
      end do
      g_last_slot = 0
      call task_unlock
      call c_atomic_store_int(g_initialized, 2_c_int)
    else
      ! ---- Loser: wait until the winner finishes ----
      do
        old = c_atomic_load_int(g_initialized)
        if (old == 2_c_int) exit
      end do
    end if
  end subroutine ensure_initialized

  ! ============================================================================
  ! Slot acquisition
  !
  ! Returns 1..MAX_TASKS on success, 0 if no free slot is available.
  ! The returned slot is marked "pending" before this function returns.
  ! ============================================================================

  function acquire_slot() result(idx)
    integer :: idx
    integer :: i, start
    logical :: found
    integer(c_int) :: old

    idx   = 0
    found = .false.

    call task_lock
    start = g_last_slot + 1
    if (start > MAX_TASKS) start = 1
    do i = 0, MAX_TASKS - 1
      idx = start + i
      if (idx > MAX_TASKS) idx = idx - MAX_TASKS
      old = c_atomic_load_int(g_slots(idx)%state)
      if (old == 0_c_int) then
        ! Claim the slot: 0 (free) -> 1 (pending).
        old = c_atomic_cas_int(g_slots(idx)%state, 0_c_int, 1_c_int)
        if (old == 0_c_int) then
          g_slots(idx)%ok           = .false.
          g_slots(idx)%payload_size = 0_c_int64_t
          g_last_slot               = idx
          found                     = .true.
          exit
        end if
      end if
    end do
    call task_unlock

    if (.not. found) idx = 0
  end function acquire_slot

  ! ============================================================================
  ! The shared callback
  !
  ! Invoked by the framework on a TCompute worker thread. Copies the
  ! complete result payload into the slot's buffer while the handle is
  ! still valid, then marks the slot as completed.
  !
  ! The user_data argument carries the slot index as a packed integer
  ! (slot_index - 1). We use TRANSFER to move the integer through the
  ! c_ptr without allocating a heap cell per call.
  ! ============================================================================

  subroutine task_callback(user_data, result) bind(C)
    type(c_ptr), value :: user_data
    type(c_ptr), value :: result
    integer(c_intptr_t) :: packed
    integer :: idx
    integer(c_int64_t) :: sz, n

    ! Recover the slot index.
    packed = transfer(user_data, packed)
    idx = int(packed) + 1

    if (idx < 1 .or. idx > MAX_TASKS) return
    if (.not. allocated(g_slots(idx)%payload)) return

    if (c_associated(result)) then
      sz = lf_data_get_size(result)
      if (sz > 0) then
        if (sz > g_max_payload) sz = g_max_payload
        call lf_data_set_position(result, 0_c_int64_t)
        n = lf_data_read_all_bytes(result, g_slots(idx)%payload, sz)
        if (n > 0) then
          g_slots(idx)%payload_size = n
          g_slots(idx)%ok           = .true.
        else
          g_slots(idx)%payload_size = 0_c_int64_t
          g_slots(idx)%ok           = .false.
        end if
      else
        ! Empty but successful result. Mark as OK with size 0.
        g_slots(idx)%payload_size = 0_c_int64_t
        g_slots(idx)%ok           = .true.
      end if
    else
      ! Dispatch failed; the framework released nothing, and we
      ! record a failure result.
      g_slots(idx)%payload_size = 0_c_int64_t
      g_slots(idx)%ok           = .false.
    end if

    ! Publish completion LAST, with an atomic store, so that a caller
    ! polling from another thread sees the payload before the state
    ! transition.
    call c_atomic_store_int(g_slots(idx)%state, 2_c_int)
  end subroutine task_callback

  ! ============================================================================
  ! Submission entry points
  ! ============================================================================

  function lf_async_submit(app, p) result(t)
    character(len=*), intent(in) :: app
    type(c_ptr), value :: p
    type(lf_task) :: t
    type(c_ptr)     :: packed_ptr
    integer(c_intptr_t) :: idx_val
    integer(c_int)  :: rc

    t%slot = 0
    call ensure_initialized
    t%slot = acquire_slot()
    if (t%slot == 0) return

    idx_val    = int(t%slot - 1, c_intptr_t)
    packed_ptr = transfer(idx_val, packed_ptr)

    rc = lf_async_call(app, p, c_funloc(task_callback), packed_ptr)
    if (rc /= 1) then
      ! Dispatch failed. The bridge invoked task_callback synchronously
      ! on this thread with a NULL result, so the slot state is already
      ! 2 and ok = .false. We still return a valid task handle; the
      ! caller can check lf_task_is_ok to distinguish the failure.
    end if
  end function lf_async_submit

  function lf_async_submit_uid(uid, p) result(t)
    integer(c_int8_t), intent(in) :: uid(LF_UID_BYTE_COUNT)
    type(c_ptr), value :: p
    type(lf_task) :: t
    type(c_ptr)     :: packed_ptr
    integer(c_intptr_t) :: idx_val
    integer(c_int)  :: rc

    t%slot = 0
    call ensure_initialized
    t%slot = acquire_slot()
    if (t%slot == 0) return

    idx_val    = int(t%slot - 1, c_intptr_t)
    packed_ptr = transfer(idx_val, packed_ptr)

    rc = lf_async_call_uid(uid, p, c_funloc(task_callback), packed_ptr)
    if (rc /= 1) then
      ! See comment in lf_async_submit.
    end if
  end function lf_async_submit_uid

  function lf_async_submit_p2pname(p2p, p) result(t)
    character(len=*), intent(in) :: p2p
    type(c_ptr), value :: p
    type(lf_task) :: t
    type(c_ptr)     :: packed_ptr
    integer(c_intptr_t) :: idx_val
    integer(c_int)  :: rc

    t%slot = 0
    call ensure_initialized
    t%slot = acquire_slot()
    if (t%slot == 0) return

    idx_val    = int(t%slot - 1, c_intptr_t)
    packed_ptr = transfer(idx_val, packed_ptr)

    rc = lf_async_call_p2pname(p2p, p, c_funloc(task_callback), packed_ptr)
    if (rc /= 1) then
      ! See comment in lf_async_submit.
    end if
  end function lf_async_submit_p2pname

  ! ============================================================================
  ! Query
  ! ============================================================================

  function lf_task_is_valid(t) result(v)
    type(lf_task), intent(in) :: t
    logical :: v
    v = (t%slot >= 1 .and. t%slot <= MAX_TASKS)
  end function lf_task_is_valid

  function lf_task_is_ready(t) result(v)
    type(lf_task), intent(in) :: t
    logical :: v
    integer(c_int) :: s

    if (.not. lf_task_is_valid(t)) then
      v = .false.
      return
    end if

    s = c_atomic_load_int(g_slots(t%slot)%state)
    v = (s == 2_c_int)
  end function lf_task_is_ready

  function lf_task_is_ok(t) result(v)
    type(lf_task), intent(in) :: t
    logical :: v

    if (.not. lf_task_is_ready(t)) then
      v = .false.
      return
    end if
    v = g_slots(t%slot)%ok
  end function lf_task_is_ok

  function lf_task_read_size(t) result(sz)
    type(lf_task), intent(in) :: t
    integer(c_int64_t) :: sz

    if (.not. lf_task_is_ready(t)) then
      sz = -1_c_int64_t
      return
    end if
    sz = g_slots(t%slot)%payload_size
  end function lf_task_read_size

  ! ============================================================================
  ! Read
  !
  ! The read functions use TRANSFER to reinterpret the byte stream
  ! as the requested type. Little-endian is guaranteed on every
  ! supported platform.
  ! ============================================================================

  function lf_task_read_int32(t) result(v)
    type(lf_task), intent(in) :: t
    integer(c_int32_t) :: v
    character(kind=c_char) :: bytes(4)
    integer :: i

    v = 0_c_int32_t
    if (.not. lf_task_is_ready(t)) return
    if (g_slots(t%slot)%payload_size < 4_c_int64_t) return

    do i = 1, 4
      bytes(i) = g_slots(t%slot)%payload(i)
    end do
    v = transfer(bytes, v)
  end function lf_task_read_int32

  function lf_task_read_int64(t) result(v)
    type(lf_task), intent(in) :: t
    integer(c_int64_t) :: v
    character(kind=c_char) :: bytes(8)
    integer :: i

    v = 0_c_int64_t
    if (.not. lf_task_is_ready(t)) return
    if (g_slots(t%slot)%payload_size < 8_c_int64_t) return

    do i = 1, 8
      bytes(i) = g_slots(t%slot)%payload(i)
    end do
    v = transfer(bytes, v)
  end function lf_task_read_int64

  function lf_task_read_float32(t) result(v)
    type(lf_task), intent(in) :: t
    real(c_float) :: v
    character(kind=c_char) :: bytes(4)
    integer :: i

    v = 0.0_c_float
    if (.not. lf_task_is_ready(t)) return
    if (g_slots(t%slot)%payload_size < 4_c_int64_t) return

    do i = 1, 4
      bytes(i) = g_slots(t%slot)%payload(i)
    end do
    v = transfer(bytes, v)
  end function lf_task_read_float32

  function lf_task_read_float64(t) result(v)
    type(lf_task), intent(in) :: t
    real(c_double) :: v
    character(kind=c_char) :: bytes(8)
    integer :: i

    v = 0.0_c_double
    if (.not. lf_task_is_ready(t)) return
    if (g_slots(t%slot)%payload_size < 8_c_int64_t) return

    do i = 1, 8
      bytes(i) = g_slots(t%slot)%payload(i)
    end do
    v = transfer(bytes, v)
  end function lf_task_read_float64

  ! Read a NUL-terminated UTF-8 string. Stops at the first NUL. If no
  ! NUL is present, returns the entire remaining payload.
  subroutine lf_task_read_string(t, s)
    type(lf_task), intent(in) :: t
    character(len=:), allocatable, intent(out) :: s
    integer(c_int64_t) :: i, n

    if (.not. lf_task_is_ready(t)) then
      allocate(character(len=0) :: s)
      return
    end if

    n = g_slots(t%slot)%payload_size
    if (n <= 0) then
      allocate(character(len=0) :: s)
      return
    end if

    ! Find the first NUL.
    do i = 1, n
      if (g_slots(t%slot)%payload(i) == c_null_char) then
        n = i - 1
        exit
      end if
    end do

    allocate(character(len=int(n)) :: s)
    do i = 1, n
      s(i:i) = g_slots(t%slot)%payload(i)
    end do
  end subroutine lf_task_read_string

  ! ============================================================================
  ! Free
  !
  ! Returns the slot to the free pool. The task handle is zeroed so
  ! that a second free is a no-op. Freeing a pending task does NOT
  ! cancel the request: the framework will still invoke the callback,
  ! and task_callback will still write into the slot -- which, after
  ! free, is back in the free pool and could be reused by a new
  ! submission. To avoid this, lf_task_free refuses to free a slot
  ! that is still pending.
  ! ============================================================================

  subroutine lf_task_free(t)
    type(lf_task), intent(inout) :: t
    integer(c_int) :: s

    if (.not. lf_task_is_valid(t)) then
      t%slot = 0
      return
    end if

    s = c_atomic_load_int(g_slots(t%slot)%state)
    if (s == 1_c_int) then
      ! Still pending; the framework will still call the callback.
      ! Refuse to release the slot to avoid a use-after-free in
      ! task_callback. The caller must wait for the task to become
      ! ready before calling lf_task_free.
      return
    end if

    call task_lock
    call c_atomic_store_int(g_slots(t%slot)%state, 0_c_int)
    g_slots(t%slot)%ok           = .false.
    g_slots(t%slot)%payload_size = 0_c_int64_t
    call task_unlock

    t%slot = 0
  end subroutine lf_task_free

  ! ============================================================================
  ! Configuration
  ! ============================================================================

  subroutine lf_task_set_max_payload(bytes)
    integer(c_int64_t), intent(in) :: bytes
    if (bytes > 0_c_int64_t) g_max_payload = bytes
  end subroutine lf_task_set_max_payload

end module lf_fortran_tasks