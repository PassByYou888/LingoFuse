/**
 * @file lf_task_support.h
 * @brief C atomic primitives for the Fortran task-handle module.
 *
 * The Fortran 2008 standard does not permit ATOMIC_CAS / ATOMIC_DEFINE
 * / ATOMIC_REF on non-coarray variables. They are Fortran 2018
 * coarray intrinsics. To provide portable atomic operations to the
 * Fortran task-handle module (lf_fortran_tasks), the atomicity is
 * implemented here, in C, using the compiler's native atomic
 * builtins.
 *
 * The Fortran side declares matching `bind(C)` interfaces to these
 * three functions and uses them exclusively to read and write the
 * small shared state that is accessed from both:
 *
 *     - the caller thread (submitting and polling),
 *     - the TCompute worker thread (task_callback).
 *
 * ============================================================================
 * SEMANTICS
 * ============================================================================
 *
 *   lf_task_atomic_cas_int(ptr, expected, new_val)
 *       Atomically compares *ptr with expected.
 *       If equal: stores new_val and returns the OLD value (= expected).
 *       If not equal: leaves *ptr unchanged and returns the OLD value
 *                     (which differs from expected).
 *       The caller therefore treats "return == expected" as success.
 *       Memory ordering: acquire-release on success, acquire on failure.
 *
 *   lf_task_atomic_store_int(ptr, val)
 *       Atomically stores val. Memory ordering: release.
 *
 *   lf_task_atomic_load_int(ptr)
 *       Atomically loads *ptr. Memory ordering: acquire.
 *
 * The acquire/release pairing is what makes the payload buffer and the
 * "ok" flag safely visible to the reader once the state field has
 * transitioned to "completed".
 *
 * ============================================================================
 * PORTABILITY
 * ============================================================================
 *
 * On every supported MinGW / GCC / Clang build, the implementation
 * uses the __atomic_* builtins (GCC 4.7+). On MSVC, it falls back to
 * the Interlocked* family. Both paths produce identical observable
 * behaviour.
 *
 * All comments are in English.
 */

#ifndef LF_TASK_SUPPORT_H_INCLUDED
#define LF_TASK_SUPPORT_H_INCLUDED

#ifdef __cplusplus
extern "C" {
#endif

/**
 * Atomic compare-and-swap on a 32-bit signed integer.
 *
 * @return The value that *ptr held BEFORE the call.
 *         If the return value equals `expected`, the swap succeeded.
 */
int lf_task_atomic_cas_int(int* ptr, int expected, int new_val);

/**
 * Atomic store with release semantics.
 */
void lf_task_atomic_store_int(int* ptr, int val);

/**
 * Atomic load with acquire semantics.
 */
int lf_task_atomic_load_int(const int* ptr);

#ifdef __cplusplus
}
#endif

#endif /* LF_TASK_SUPPORT_H_INCLUDED */