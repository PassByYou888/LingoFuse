/**
 * @file test_uid_probe.c
 * @brief Diagnostic probe for the calling convention of LF_Get_P2P_UID.
 *
 * Purpose
 * -------
 * The current C ABI revision declares:
 *
 *     const TP2P_UID* LF_Get_P2P_UID(TDataHnd hnd);
 *
 * i.e. LF_Get_P2P_UID returns a POINTER to a 32-byte UID, not the value
 * itself. The pointer is allocated by the Pascal side via New and is
 * scheduled for automatic release about 5 seconds after the call
 * (DelayFreeMem(5.0, ...)).
 *
 * An earlier revision of the same function returned the 32-byte UID BY
 * VALUE, which on x64 (both System V AMD64 and Microsoft x64) uses the
 * SRet hidden-pointer convention for >16-byte aggregate returns. That
 * version required a ctypes Structure workaround in the Python binding
 * and a struct-by-value typedef in the C wrapper.
 *
 * The purpose of this probe is to verify, WITHOUT trusting the header,
 * that the loaded DLL actually implements the pointer-return convention
 * that the header now declares. A divergence would show up as either:
 *
 *     (a) an SRet-style prologue at the start of the function
 *         (mov [rsp+XX], rcx as the very first instruction), or
 *     (b) a crash / garbage result when the function is called with the
 *         new pointer-return signature.
 *
 * The probe therefore performs TWO independent checks:
 *
 *     Check 1 (read-only): dump the first 64 bytes of the function's
 *         machine code and analyse the prologue.
 *
 *     Check 2 (safe call): call LF_Get_P2P_UID(NULL). The library
 *         documents that a NULL handle produces a pointer to a
 *         zero-filled UID. Both the non-NULL-ness of the returned
 *         pointer and the zero-fill of its 32 bytes are checked. If the
 *         DLL used a different ABI, this call would either return a
 *         bogus pointer or crash outright; the probe reports which.
 *
 * The second check is intentionally limited to the NULL handle case so
 * that the probe never depends on the network, an App, or an active
 * client session. It is a pure ABI sanity check.
 *
 * How to run
 * ----------
 *   cd <Binary>
 *   .\test_uid_probe.exe
 *
 * Share the output with the framework maintainer if the probe reports a
 * mismatch between the header and the DLL.
 *
 * Windows only
 * ------------
 * The probe uses GetModuleHandleA / GetProcAddress to locate the loaded
 * DLL. On non-Windows platforms the target is not built (see CMakeLists).
 */

#if defined(_WIN32) && !defined(_CRT_SECURE_NO_WARNINGS)
#  define _CRT_SECURE_NO_WARNINGS
#endif

#include "LingoFuse.h"

#if !defined(_WIN32)
#  error "test_uid_probe.c is Windows-only."
#endif

#include <windows.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

 /* ============================================================================
  *  Helpers
  * ============================================================================ */

static int uid_is_all_zero(const TP2P_UID* u) {
    int i;
    for (i = 0; i < 32; ++i) {
        if (u->bytes[i] != 0) return 0;
    }
    return 1;
}

static void uid_to_hex(const TP2P_UID* u, char out[65]) {
    static const char hex[] = "0123456789abcdef";
    int i;
    for (i = 0; i < 32; ++i) {
        out[i * 2] = hex[(u->bytes[i] >> 4) & 0x0F];
        out[i * 2 + 1] = hex[u->bytes[i] & 0x0F];
    }
    out[64] = '\0';
}

/* ============================================================================
 *  Prologue analysis heuristics
 * ============================================================================
 *
 * On Windows x64, the compiler emits ONE of the following patterns for a
 * function whose formal signature is `const TP2P_UID* f(TDataHnd)`:
 *
 *   Pattern A -- POINTER RETURN (matches the current header).
 *
 *       The single pointer argument is passed in RCX. The compiler may
 *       save it (typically as the first stack slot, `mov [rsp+8], rcx`)
 *       or spill it later, but it does NOT treat RCX as a hidden SRet
 *       pointer, because there is no hidden pointer. The function
 *       eventually returns a pointer value in RAX.
 *
 *   Pattern B -- SRet STRUCT RETURN (the OLD, superseded ABI).
 *
 *       The caller allocates a 32-byte return buffer and passes its
 *       address in RCX. The single logical argument (TDataHnd) is
 *       therefore shifted to RDX. The prologue typically saves RCX to
 *       a fixed stack slot as the FIRST store:
 *
 *           mov [rsp+8], rcx      ; 48 89 4C 24 08
 *           mov [rsp+10h], rdx    ; 48 89 54 24 10
 *
 *       The function eventually returns the hidden pointer in RAX (per
 *       the psABI convention), but the caller reads the 32 bytes from
 *       its own buffer, not from RAX.
 *
 * {!!!!!  WHY THE PROLOGUE ALONE IS NOT DEFINITIVE  !!!!!}
 * A pointer-returning function may ALSO begin with `mov [rsp+8], rcx`
 * if the compiler decides to spill the first argument there. So the
 * prologue is a HINT, not a proof. That is precisely why this probe
 * performs an independent safe-call check below.
 *
 * The prologue analysis here is therefore reported as "observed pattern"
 * with a corresponding interpretation, and the safe-call result is
 * treated as the authoritative verdict.
 * ============================================================================ */

typedef enum PrologueHint_e {
    PROLOGUE_HINT_UNKNOWN = 0,
    PROLOGUE_HINT_SRET_LOOKING,
    PROLOGUE_HINT_POINTER_LOOKING
} PrologueHint;

static PrologueHint analyse_prologue(const unsigned char* code, int n) {
    /*
     * Very small, intentionally conservative heuristic:
     *
     *   - If the first 4 bytes are `48 89 4C 24` (mov [rsp+disp8], rcx)
     *     AND the next 4 bytes are another `48 89 54 24` (mov [rsp+disp8], rdx),
     *     the two-instruction sequence is the classic SRet prologue.
     *
     *   - If the first 4 bytes are `48 83 EC` (sub rsp, imm8), the
     *     compiler is opening a frame; no SRet conclusion can be drawn
     *     from the first instruction alone. The probe reports it as
     *     "pointer-looking" only when no `mov [rsp+disp8], rcx` store
     *     appears in the first 16 bytes.
     *
     *   - If the first 4 bytes are `48 89 5C 24` (mov [rsp+disp8], rbx)
     *     or `40 53` (push rbx), the function is saving a callee-saved
     *     register before touching the arguments, which is consistent
     *     with (but not proof of) a normal pointer-returning body.
     *
     *   - Anything else is reported as UNKNOWN.
     */
    if (n < 8) return PROLOGUE_HINT_UNKNOWN;

    /* Classic SRet signature: two consecutive "mov [rsp+disp8], reg"
       stores of rcx and then rdx. */
    if (code[0] == 0x48 && code[1] == 0x89 && code[2] == 0x4C && code[3] == 0x24 &&
        code[4] == 0x48 && code[5] == 0x89 && code[6] == 0x54 && code[7] == 0x24) {
        return PROLOGUE_HINT_SRET_LOOKING;
    }

    /* Standard frame opening; scan a few bytes ahead for a stored rcx. */
    if (code[0] == 0x48 && code[1] == 0x83 && code[2] == 0xEC) {
        int i;
        for (i = 3; i + 3 < n && i < 16; ++i) {
            if (code[i] == 0x48 && code[i + 1] == 0x89 &&
                code[i + 2] == 0x4C && code[i + 3] == 0x24) {
                /* Still ambiguous: could be a spilled argument or an SRet
                   pointer. Do NOT claim SRet; report UNKNOWN. */
                return PROLOGUE_HINT_UNKNOWN;
            }
        }
        return PROLOGUE_HINT_POINTER_LOOKING;
    }

    /* Saving rbx or rdi at the top is a normal pointer-returning prologue. */
    if ((code[0] == 0x48 && code[1] == 0x89 && code[2] == 0x5C && code[3] == 0x24) ||
        (code[0] == 0x40 && code[1] == 0x53)) {
        return PROLOGUE_HINT_POINTER_LOOKING;
    }

    return PROLOGUE_HINT_UNKNOWN;
}

/* ============================================================================
 *  main
 * ============================================================================ */

int main(void) {
    HMODULE         dll;
    void* proc;
    const unsigned char* code;
    int             i;
    PrologueHint    hint;
    int             safe_call_ok = 0;
    int             safe_call_crash = 0;

    printf("======================================================================\n");
    printf("  LF_Get_P2P_UID calling-convention probe\n");
    printf("======================================================================\n");
    printf("  Purpose : verify that the loaded DLL implements the\n");
    printf("            pointer-return convention declared in LingoFuse.h:\n");
    printf("\n");
    printf("                const TP2P_UID* LF_Get_P2P_UID(TDataHnd);\n");
    printf("\n");
    printf("  The probe performs two independent checks:\n");
    printf("    1. Read-only machine-code prologue dump + heuristic.\n");
    printf("    2. Safe call of LF_Get_P2P_UID(NULL), which the library\n");
    printf("       documents as returning a pointer to a zero-filled UID.\n");
    printf("  The safe call is the authoritative check.\n\n");

    /* ------------------------------------------------------------------
     * Step 1: load the DLL via the standard wrapper.
     * ------------------------------------------------------------------ */
    if (LF_LoadLibrary() != 1) {
        fprintf(stderr, "FATAL: LF_LoadLibrary failed\n");
        return 1;
    }

    /* ------------------------------------------------------------------
     * Step 2: locate the loaded module.
     * ------------------------------------------------------------------ */
    dll = GetModuleHandleA("LingoFuse64.dll");
    if (dll == NULL) {
        dll = GetModuleHandleA("LingoFuse32.dll");
    }
    if (dll == NULL) {
        fprintf(stderr, "FATAL: GetModuleHandleA failed: %lu\n",
            (unsigned long)GetLastError());
        return 1;
    }
    printf("DLL base address  : %p\n", (void*)dll);

    /* ------------------------------------------------------------------
     * Step 3: locate the exported symbol.
     *
     * GetProcAddress returns the ADDRESS OF THE DLL'S FUNCTION. We do not
     * call it through the wrong signature; we only read its machine code.
     * The actual call is made in Step 5 through the C wrapper's forwarder
     * `LF_Get_P2P_UID`, which uses the header's signature. That is the
     * correct way to test the header/DLL agreement.
     * ------------------------------------------------------------------ */
    proc = (void*)GetProcAddress(dll, "LF_Get_P2P_UID");
    if (proc == NULL) {
        fprintf(stderr, "FATAL: GetProcAddress(\"LF_Get_P2P_UID\") failed: %lu\n",
            (unsigned long)GetLastError());
        return 1;
    }
    printf("LF_Get_P2P_UID    : %p\n\n", proc);

    /* ------------------------------------------------------------------
     * Check 1: dump the first 64 bytes of machine code.
     * ------------------------------------------------------------------ */
    code = (const unsigned char*)proc;
    printf("Check 1 -- machine-code prologue (first 64 bytes):\n");
    for (i = 0; i < 64; ++i) {
        printf("%02X ", code[i]);
        if ((i + 1) % 16 == 0) printf("\n");
    }
    printf("\n");

    hint = analyse_prologue(code, 64);
    switch (hint) {
    case PROLOGUE_HINT_SRET_LOOKING:
        printf("  Heuristic hint : SRet-looking\n");
        printf("  First 8 bytes  : %02X %02X %02X %02X %02X %02X %02X %02X\n",
            code[0], code[1], code[2], code[3],
            code[4], code[5], code[6], code[7]);
        printf("  Note           : two consecutive 'mov [rsp+disp8], rcx/rdx'\n");
        printf("                   stores are the classic SRet prologue. This\n");
        printf("                   HINT does not prove the ABI; see Check 2.\n");
        break;
    case PROLOGUE_HINT_POINTER_LOOKING:
        printf("  Heuristic hint : pointer-returning-looking\n");
        printf("  Note           : the first few instructions look like a\n");
        printf("                   normal function frame with no SRet store.\n");
        break;
    default:
        printf("  Heuristic hint : unrecognized / inconclusive\n");
        printf("  First 8 bytes  : %02X %02X %02X %02X %02X %02X %02X %02X\n",
            code[0], code[1], code[2], code[3],
            code[4], code[5], code[6], code[7]);
        printf("  Note           : a manual disassembly is required to\n");
        printf("                   interpret this prologue. Check 2 below is\n");
        printf("                   still authoritative.\n");
        break;
    }
    printf("\n");

    /* ------------------------------------------------------------------
     * Check 2: safe call of LF_Get_P2P_UID(NULL).
     *
     * The library documents that a NULL handle produces a pointer to a
     * zero-filled UID. The call goes through the C wrapper's forwarder,
     * which uses the header's signature. If the header and DLL agree on
     * the ABI, the call returns a valid pointer and the 32 bytes behind
     * it are zero.
     *
     * If the header and DLL do NOT agree, this call may:
     *   - crash outright (access violation),
     *   - return a bogus pointer that dereferencing would crash on, or
     *   - return a plausible-looking pointer whose 32 bytes are not
     *     zero (garbage from an SRet buffer).
     *
     * We deliberately keep this call tiny and observable. There is no
     * network, no App, and no client involved.
     * ------------------------------------------------------------------ */
    printf("Check 2 -- safe call: LF_Get_P2P_UID(NULL)\n");

    __try {
        const TP2P_UID* uid_ptr = LF_Get_P2P_UID(NULL);

        if (uid_ptr == NULL) {
            printf("  Result         : returned NULL\n");
            printf("  Interpretation : the library was not loaded, OR the\n");
            printf("                   wrapper's null check tripped. This is\n");
            printf("                   NOT an ABI verdict.\n");
        }
        else {
            char hex[65];
            memset(hex, 0, sizeof(hex));
            uid_to_hex(uid_ptr, hex);

            printf("  Returned ptr   : %p\n", (const void*)uid_ptr);
            printf("  UID (hex)      : %s\n", hex);
            printf("  All-zero?      : %s\n",
                uid_is_all_zero(uid_ptr) ? "YES" : "NO");

            if (uid_is_all_zero(uid_ptr)) {
                printf("  Interpretation : the DLL returned a pointer to a\n");
                printf("                   zero-filled UID, exactly as the\n");
                printf("                   header documents. The pointer-return\n");
                printf("                   ABI is confirmed.\n");
                safe_call_ok = 1;
            }
            else {
                printf("  Interpretation : the returned 32 bytes are NOT\n");
                printf("                   zero. Either the DLL implements a\n");
                printf("                   different ABI, or the memory behind\n");
                printf("                   the pointer is stale garbage.\n");
            }
        }
    }
    __except (EXCEPTION_EXECUTE_HANDLER) {
        safe_call_crash = 1;
        printf("  Result         : ACCESS VIOLATION\n");
        printf("  Interpretation : the call crashed. This is the strongest\n");
        printf("                   possible signal that the header and the DLL\n");
        printf("                   disagree on the return ABI.\n");
    }
    printf("\n");

    /* ------------------------------------------------------------------
     * Final verdict
     * ------------------------------------------------------------------ */
    printf("======================================================================\n");
    printf("  Final verdict\n");
    printf("======================================================================\n");

    if (safe_call_crash) {
        printf("  RESULT: ABI MISMATCH (safe call crashed)\n");
        printf("\n");
        printf("  The header declares a pointer-return convention, but calling\n");
        printf("  LF_Get_P2P_UID with that signature crashed. The DLL is\n");
        printf("  implementing a different return convention.\n");
        printf("\n");
        printf("  Next steps:\n");
        printf("    - Report this to the framework maintainer with the full\n");
        printf("      prologue dump above.\n");
        printf("    - DO NOT apply a caller-side workaround; the fix belongs\n");
        printf("      on the ABI boundary, not in every caller.\n");
        return 2;
    }

    if (safe_call_ok) {
        printf("  RESULT: POINTER-RETURN ABI CONFIRMED\n");
        printf("\n");
        printf("  The DLL returned a non-NULL pointer to a zero-filled UID for\n");
        printf("  a NULL handle, exactly as the header documents. The two\n");
        printf("  independent checks are consistent with the header:\n");
        printf("     - prologue hint : %s\n",
            hint == PROLOGUE_HINT_POINTER_LOOKING
            ? "pointer-returning-looking"
            : (hint == PROLOGUE_HINT_SRET_LOOKING
                ? "SRet-looking (do NOT trust this alone)"
                : "inconclusive"));
        printf("     - safe call     : non-NULL, zero-filled\n");
        return 0;
    }

    printf("  RESULT: INCONCLUSIVE\n");
    printf("\n");
    printf("  The safe call did not crash, but it did not produce the\n");
    printf("  expected non-NULL zero-filled result either. Collect the\n");
    printf("  prologue dump above and the check-2 output, and share them\n");
    printf("  with the framework maintainer.\n");
    return 3;
}