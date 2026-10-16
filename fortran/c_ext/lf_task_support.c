/**
 * @file lf_task_support.c
 * @brief Implementation of the C atomic primitives.
 *
 * See lf_task_support.h for the contract.
 *
 * Two implementations are provided:
 *
 *   - MSVC:    InterlockedCompareExchange / InterlockedExchange.
 *   - GCC/Clang: __atomic_* builtins with explicit memory ordering.
 *
 * The MinGW-w64 toolchain used by the Fortran binding takes the
 * GCC/Clang path.
 *
 * All comments are in English.
 */

#include "lf_task_support.h"

#if defined(_MSC_VER) && !defined(__clang__)

/* ============================================================================
 * MSVC path
 * ============================================================================
 *
 * The Interlocked family operates on `volatile LONG*`. LONG is a
 * 32-bit signed integer on all Windows targets, matching the `int`
 * parameter type used by the C API above.
 * ============================================================================ */

#include <windows.h>

int lf_task_atomic_cas_int(int* ptr, int expected, int new_val) {
    return (int)InterlockedCompareExchange(
        (volatile LONG*)ptr,
        (LONG)new_val,
        (LONG)expected);
}

void lf_task_atomic_store_int(int* ptr, int val) {
    InterlockedExchange((volatile LONG*)ptr, (LONG)val);
}

int lf_task_atomic_load_int(const int* ptr) {
    /* InterlockedCompareExchange returns the original value; passing
       0/0 as expected/desired performs a full memory barrier read. */
    return (int)InterlockedCompareExchange(
        (volatile LONG*)ptr,
        0,
        0);
}

#else

/* ============================================================================
 * GCC / Clang path (used by MinGW-w64)
 * ============================================================================
 *
 * The __atomic_* builtins are available in GCC 4.7 and later, and in
 * all supported Clang versions. They expand to lock-free machine
 * instructions on x86-64, and to the corresponding library calls on
 * platforms without native atomics.
 *
 * We use:
 *   - __ATOMIC_ACQ_REL on the CAS success path,
 *   - __ATOMIC_ACQUIRE on the CAS failure path,
 *   - __ATOMIC_RELEASE for the store,
 *   - __ATOMIC_ACQUIRE for the load.
 *
 * This pairing is sufficient to publish the payload buffer and the
 * "ok" flag from the callback thread to the polling thread.
 * ============================================================================ */

int lf_task_atomic_cas_int(int* ptr, int expected, int new_val) {
    int old = expected;
    __atomic_compare_exchange_n(
        ptr,
        &old,
        new_val,
        0,                 /* strong */
        __ATOMIC_ACQ_REL,  /* success ordering */
        __ATOMIC_ACQUIRE); /* failure ordering */
    return old;
}

void lf_task_atomic_store_int(int* ptr, int val) {
    __atomic_store_n(ptr, val, __ATOMIC_RELEASE);
}

int lf_task_atomic_load_int(const int* ptr) {
    return __atomic_load_n(ptr, __ATOMIC_ACQUIRE);
}

#endif