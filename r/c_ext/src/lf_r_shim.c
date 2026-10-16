/* ============================================================================
 * lf_r_shim.c
 * ----------------------------------------------------------------------------
 * C shim layer for the LingoFuse R bridge. (v2.0)
 *
 * Compiled by Rtools gcc as C. This is the ONLY file in the bridge
 * that includes R headers.
 *
 * Version history
 * ---------------
 *   v1.0  Initial release: STEP 1-3b entry points (build probes,
 *         runtime loading, DataHandle, AppHandle, network prep,
 *         app-name invocation, callee job queue).
 *
 *   v2.0  Full coverage of the 59-symbol C ABI, plus the modern
 *         asynchronous layer.
 *
 *         New in v2.0:
 *           - UID addressing helpers (raw(32) <-> uint8_t[32])
 *           - P2PName addressing
 *           - Process-wide P2P registration
 *           - Local execution
 *           - Runtime options (set / get)
 *           - Status queue (count / get / post)
 *           - Async entry points (6 variants) + release + queries
 *           - Network events
 *           - Side data extraction
 *           - Misc: generate_app_name / app_bind / app_unregister /
 *                   data_set_size / data_get_buffer
 *
 * All user-facing strings and error messages are in English.
 * ========================================================================== */

#include <R.h>
#include <Rinternals.h>
#include <R_ext/Rdynload.h>

#include <stdint.h>
#include <string.h>

#include "lf_r_shim.h"

/* ============================================================================
 * Small helpers
 * ========================================================================== */

static const char* s_get_utf8(SEXP x, const char* arg_name)
{
    if (TYPEOF(x) != STRSXP || LENGTH(x) != 1) {
        Rf_error("Argument '%s' must be a length-1 character vector.",
                 arg_name);
    }
    SEXP elt = STRING_ELT(x, 0);
    if (elt == NA_STRING) {
        Rf_error("Argument '%s' must not be NA.", arg_name);
    }
    return Rf_translateCharUTF8(elt);
}

static void* s_get_externalptr(SEXP x, const char* arg_name)
{
    if (TYPEOF(x) != EXTPTRSXP) {
        Rf_error("Argument '%s' must be an externalptr.", arg_name);
    }
    return R_ExternalPtrAddr(x);
}

static SEXP s_mk_utf8_string(const char* s)
{
    if (s == NULL) s = "";
    SEXP out = PROTECT(Rf_allocVector(STRSXP, 1));
    SET_STRING_ELT(out, 0, Rf_mkCharCE(s, CE_UTF8));
    UNPROTECT(1);
    return out;
}

/* Validate a raw vector of length exactly 32. Returns a pointer to
 * its underlying bytes. The caller must not retain this pointer
 * beyond the current call. */
static const uint8_t* s_get_uid32(SEXP x, const char* arg_name)
{
    if (TYPEOF(x) != RAWSXP) {
        Rf_error("Argument '%s' must be a raw vector.", arg_name);
    }
    if (XLENGTH(x) != 32) {
        Rf_error("Argument '%s' must be a length-32 raw vector (got %lld).",
                 arg_name, (long long)XLENGTH(x));
    }
    return (const uint8_t*)RAW(x);
}

static int64_t s_get_int64(SEXP x, const char* arg_name)
{
    if (TYPEOF(x) != REALSXP && TYPEOF(x) != INTSXP) {
        Rf_error("Argument '%s' must be a numeric scalar.", arg_name);
    }
    if (LENGTH(x) != 1) {
        Rf_error("Argument '%s' must be a length-1 numeric vector.",
                 arg_name);
    }
    if (TYPEOF(x) == REALSXP) {
        double d = REAL(x)[0];
        if (!R_FINITE(d)) {
            Rf_error("Argument '%s' must be finite.", arg_name);
        }
        return (int64_t)d;
    }
    return (int64_t)INTEGER(x)[0];
}

static uint64_t s_get_uint64_timeout(SEXP x, const char* arg_name)
{
    int64_t v = s_get_int64(x, arg_name);
    if (v < 0) {
        Rf_error("Argument '%s' must be non-negative.", arg_name);
    }
    return (uint64_t)v;
}

/* ============================================================================
 * Finalizers for externalptr wrappers
 * ========================================================================== */

static void data_externalptr_finalizer(SEXP ext)
{
    void* p = R_ExternalPtrAddr(ext);
    if (p != NULL) {
        lf_impl_data_free(p);
        R_ClearExternalPtr(ext);
    }
}

static void app_externalptr_finalizer(SEXP ext)
{
    void* p = R_ExternalPtrAddr(ext);
    if (p != NULL) {
        lf_impl_app_free(p);
        R_ClearExternalPtr(ext);
    }
}

/* The job externalptr finalizer runs when the R side abandons a Job
 * without calling lf_job_complete. It wakes the waiting worker and
 * releases the R side's reference. Idempotent with job_complete. */
static void job_externalptr_finalizer(SEXP ext)
{
    void* p = R_ExternalPtrAddr(ext);
    if (p != NULL) {
        lf_impl_job_abandon(p);
        R_ClearExternalPtr(ext);
    }
}

/* ============================================================================
 * SECTION 1 - Build chain probes
 * ========================================================================== */

static SEXP r_ping(void) { return Rf_mkString(lf_impl_ping()); }
static SEXP r_echo(SEXP x) { return x; }

static SEXP r_info(void)
{
    SEXP result = PROTECT(Rf_allocVector(VECSXP, 3));
    SEXP names  = PROTECT(Rf_allocVector(STRSXP, 3));

    SET_STRING_ELT(names, 0, Rf_mkChar("version"));
    SET_STRING_ELT(names, 1, Rf_mkChar("stage"));
    SET_STRING_ELT(names, 2, Rf_mkChar("compiled"));

    SET_VECTOR_ELT(result, 0, Rf_mkString(lf_impl_version()));
    SET_VECTOR_ELT(result, 1, Rf_mkString(lf_impl_stage()));
    SET_VECTOR_ELT(result, 2, Rf_mkString(lf_impl_compiled()));

    Rf_setAttrib(result, R_NamesSymbol, names);
    UNPROTECT(2);
    return result;
}

/* ============================================================================
 * SECTION 2 - Runtime loading
 * ========================================================================== */

static SEXP r_load_library(SEXP dir_sexp)
{
    const char* dir = s_get_utf8(dir_sexp, "runtime_dir");
    if (!lf_impl_load_library(dir)) {
        Rf_error("Failed to load LingoFuse runtime: %s",
                 lf_impl_last_error());
    }
    return s_mk_utf8_string(lf_impl_loaded_path());
}

static SEXP r_unload_library(void)
{
    lf_impl_unload_library();
    return R_NilValue;
}

static SEXP r_is_loaded(void)
{
    return Rf_ScalarLogical(lf_impl_is_loaded() ? TRUE : FALSE);
}

static SEXP r_loaded_path(void)
{
    return s_mk_utf8_string(lf_impl_loaded_path());
}

static SEXP r_last_error(void)
{
    return s_mk_utf8_string(lf_impl_last_error());
}

/* ============================================================================
 * SECTION 3 - DataHandle
 * ========================================================================== */

static SEXP r_data_create(SEXP api_name_sexp)
{
    const char* api_name = s_get_utf8(api_name_sexp, "api_name");
    void* hnd = lf_impl_data_create(api_name);
    if (!hnd) Rf_error("lf_impl_data_create failed for API '%s'", api_name);
    SEXP ext = PROTECT(R_MakeExternalPtr(hnd, R_NilValue, R_NilValue));
    R_RegisterCFinalizerEx(ext, data_externalptr_finalizer, TRUE);
    UNPROTECT(1);
    return ext;
}

static SEXP r_data_create_permanent(SEXP api_name_sexp)
{
    const char* api_name = s_get_utf8(api_name_sexp, "api_name");
    void* hnd = lf_impl_data_create_permanent(api_name);
    if (!hnd) Rf_error("lf_impl_data_create_permanent failed for '%s'",
                       api_name);
    SEXP ext = PROTECT(R_MakeExternalPtr(hnd, R_NilValue, R_NilValue));
    R_RegisterCFinalizerEx(ext, data_externalptr_finalizer, TRUE);
    UNPROTECT(1);
    return ext;
}

static SEXP r_data_free(SEXP ext_sexp)
{
    if (TYPEOF(ext_sexp) != EXTPTRSXP) {
        Rf_error("lf_data_free: argument must be an externalptr");
    }
    void* hnd = R_ExternalPtrAddr(ext_sexp);
    if (hnd == NULL) return R_NilValue;
    lf_impl_data_free(hnd);
    R_ClearExternalPtr(ext_sexp);
    return R_NilValue;
}

static SEXP r_data_write_buffer(SEXP ext_sexp, SEXP raw_sexp)
{
    void* hnd = s_get_externalptr(ext_sexp, "handle");
    if (hnd == NULL) Rf_error("lf_data_write_buffer: handle is NULL");
    if (TYPEOF(raw_sexp) != RAWSXP) {
        Rf_error("lf_data_write_buffer: data must be a raw vector");
    }
    R_xlen_t len = XLENGTH(raw_sexp);
    int64_t written = lf_impl_data_write_buffer(hnd, RAW(raw_sexp),
                                                (int64_t)len);
    if (written < 0) Rf_error("lf_data_write_buffer: native call failed");
    return Rf_ScalarReal((double)written);
}

static SEXP r_data_read_buffer(SEXP ext_sexp, SEXP n_sexp)
{
    void* hnd = s_get_externalptr(ext_sexp, "handle");
    if (hnd == NULL) Rf_error("lf_data_read_buffer: handle is NULL");

    double n_d = Rf_asReal(n_sexp);
    if (!R_FINITE(n_d) || n_d < 0) {
        Rf_error("lf_data_read_buffer: n must be finite and non-negative");
    }
    if (n_d > (double)R_XLEN_T_MAX) {
        Rf_error("lf_data_read_buffer: n is too large");
    }
    R_xlen_t n = (R_xlen_t)n_d;
    if (n == 0) return Rf_allocVector(RAWSXP, 0);

    SEXP result = PROTECT(Rf_allocVector(RAWSXP, n));
    int64_t got = lf_impl_data_read_buffer(hnd, RAW(result), (int64_t)n);
    if (got < 0) {
        UNPROTECT(1);
        Rf_error("lf_data_read_buffer: native call failed");
    }
    if (got == (int64_t)n) { UNPROTECT(1); return result; }

    SEXP shrunk = PROTECT(Rf_allocVector(RAWSXP, (R_xlen_t)got));
    if (got > 0) memcpy(RAW(shrunk), RAW(result), (size_t)got);
    UNPROTECT(2);
    return shrunk;
}

static SEXP r_data_get_size(SEXP ext_sexp)
{
    void* hnd = s_get_externalptr(ext_sexp, "handle");
    if (hnd == NULL) Rf_error("lf_data_get_size: handle is NULL");
    int64_t sz = lf_impl_data_get_size(hnd);
    if (sz < 0) Rf_error("lf_data_get_size: native call failed");
    return Rf_ScalarReal((double)sz);
}

static SEXP r_data_get_pos(SEXP ext_sexp)
{
    void* hnd = s_get_externalptr(ext_sexp, "handle");
    if (hnd == NULL) Rf_error("lf_data_get_pos: handle is NULL");
    int64_t pos = lf_impl_data_get_pos(hnd);
    if (pos < 0) Rf_error("lf_data_get_pos: native call failed");
    return Rf_ScalarReal((double)pos);
}

static SEXP r_data_set_pos(SEXP ext_sexp, SEXP pos_sexp)
{
    void* hnd = s_get_externalptr(ext_sexp, "handle");
    if (hnd == NULL) Rf_error("lf_data_set_pos: handle is NULL");
    double pos_d = Rf_asReal(pos_sexp);
    if (!R_FINITE(pos_d) || pos_d < 0) {
        Rf_error("lf_data_set_pos: pos must be finite and non-negative");
    }
    if (lf_impl_data_set_pos(hnd, (int64_t)pos_d) != 0) {
        Rf_error("lf_data_set_pos: native call failed");
    }
    return R_NilValue;
}

static SEXP r_data_set_size(SEXP ext_sexp, SEXP size_sexp)
{
    void* hnd = s_get_externalptr(ext_sexp, "handle");
    if (hnd == NULL) Rf_error("lf_data_set_size: handle is NULL");
    double size_d = Rf_asReal(size_sexp);
    if (!R_FINITE(size_d) || size_d < 0) {
        Rf_error("lf_data_set_size: size must be finite and non-negative");
    }
    if (lf_impl_data_set_size(hnd, (int64_t)size_d) != 0) {
        Rf_error("lf_data_set_size: native call failed");
    }
    return R_NilValue;
}

static SEXP r_data_get_buffer(SEXP ext_sexp)
{
    void* hnd = s_get_externalptr(ext_sexp, "handle");
    if (hnd == NULL) Rf_error("lf_data_get_buffer: handle is NULL");
    void* buf = lf_impl_data_get_buffer(hnd);
    if (buf == NULL) return R_NilValue;
    /* Return as an externalptr. The R side can feed it to a
     * specialised reader if needed; ordinary payload I/O should use
     * lf_data_read_buffer. */
    return R_MakeExternalPtr(buf, R_NilValue, R_NilValue);
}

/* ============================================================================
 * SECTION 4 - AppHandle
 * ========================================================================== */

static SEXP r_app_create(SEXP name_sexp, SEXP desc_sexp)
{
    const char* name = s_get_utf8(name_sexp, "name");
    const char* desc = s_get_utf8(desc_sexp, "description");
    void* app = lf_impl_app_create(name, desc);
    if (!app) Rf_error("lf_impl_app_create failed for '%s'", name);
    SEXP ext = PROTECT(R_MakeExternalPtr(app, R_NilValue, R_NilValue));
    R_RegisterCFinalizerEx(ext, app_externalptr_finalizer, TRUE);
    UNPROTECT(1);
    return ext;
}

static SEXP r_app_free(SEXP ext_sexp)
{
    if (TYPEOF(ext_sexp) != EXTPTRSXP) {
        Rf_error("lf_app_free: argument must be an externalptr");
    }
    void* app = R_ExternalPtrAddr(ext_sexp);
    if (app == NULL) return R_NilValue;
    lf_impl_app_free(app);
    R_ClearExternalPtr(ext_sexp);
    return R_NilValue;
}

static SEXP r_app_name(SEXP ext_sexp)
{
    void* app = s_get_externalptr(ext_sexp, "app");
    if (app == NULL) Rf_error("lf_app_name: app is NULL");
    const char* name = lf_impl_app_name(app);
    if (name == NULL) Rf_error("lf_app_name: native returned NULL");
    return s_mk_utf8_string(name);
}

static SEXP r_app_bind(SEXP ext_sexp)
{
    void* app = s_get_externalptr(ext_sexp, "app");
    if (app == NULL) Rf_error("lf_app_bind: app is NULL");
    return Rf_ScalarInteger(lf_impl_app_bind(app));
}

static SEXP r_app_unregister(SEXP ext_sexp, SEXP api_sexp)
{
    void* app = s_get_externalptr(ext_sexp, "app");
    if (app == NULL) Rf_error("lf_app_unregister: app is NULL");
    const char* api = s_get_utf8(api_sexp, "api_name");
    return Rf_ScalarInteger(lf_impl_app_unregister(app, api));
}

static SEXP r_generate_app_name(void)
{
    return s_mk_utf8_string(lf_impl_generate_app_name());
}

/* ============================================================================
 * SECTION 5 - Network preparation
 * ========================================================================== */

static SEXP r_reset_prepare(void)
{
    if (lf_impl_reset_prepare() != 0) {
        Rf_error("lf_reset_prepare: runtime not loaded");
    }
    return R_NilValue;
}

static SEXP r_prepare_service(SEXP listen_sexp, SEXP physics_sexp)
{
    const char* listen  = s_get_utf8(listen_sexp, "listen_addr");
    const char* physics = s_get_utf8(physics_sexp, "physics_addr");
    return Rf_ScalarInteger(lf_impl_prepare_service(listen, physics));
}

static SEXP r_prepare_client(SEXP endpoint_sexp)
{
    const char* ep = s_get_utf8(endpoint_sexp, "endpoint");
    return Rf_ScalarInteger(lf_impl_prepare_client(ep));
}

static SEXP r_prepare_client_with_app(SEXP endpoint_sexp, SEXP app_sexp)
{
    const char* ep = s_get_utf8(endpoint_sexp, "endpoint");
    void* app = s_get_externalptr(app_sexp, "app");
    if (app == NULL) {
        Rf_error("lf_prepare_client_with_app: app is NULL");
    }
    return Rf_ScalarInteger(lf_impl_prepare_client_with_app(ep, app));
}

static SEXP r_prepare_done(void)
{
    return Rf_ScalarInteger(lf_impl_prepare_done());
}

static SEXP r_exit_main_thread(void)
{
    lf_impl_exit_main_thread();
    return R_NilValue;
}

static SEXP r_check_main_thread(void)
{
    return Rf_ScalarLogical(lf_impl_check_main_thread() ? TRUE : FALSE);
}

static SEXP r_check_app(SEXP app_sexp)
{
    const char* app = s_get_utf8(app_sexp, "app_name");
    return Rf_ScalarLogical(lf_impl_check_app(app) ? TRUE : FALSE);
}

static SEXP r_check_api(SEXP app_sexp, SEXP api_sexp)
{
    const char* app = s_get_utf8(app_sexp, "app_name");
    const char* api = s_get_utf8(api_sexp, "api_name");
    return Rf_ScalarLogical(lf_impl_check_api(app, api) ? TRUE : FALSE);
}

/* ============================================================================
 * SECTION 6 - App-name invocation
 * ========================================================================== */

static SEXP r_call(SEXP app_sexp, SEXP api_sexp,
                   SEXP payload_sexp, SEXP timeout_sexp)
{
    const char* app     = s_get_utf8(app_sexp, "app_name");
    const char* api     = s_get_utf8(api_sexp, "api_name");
    const char* payload = s_get_utf8(payload_sexp, "payload");
    uint64_t timeout    = s_get_uint64_timeout(timeout_sexp, "timeout_ms");

    int64_t out_len = 0;
    const char* result = lf_impl_call(app, api, payload, timeout, &out_len);
    if (result == NULL) Rf_error("lf_call: %s", lf_impl_last_error());
    return s_mk_utf8_string(result);
}

static SEXP r_notify(SEXP app_sexp, SEXP api_sexp, SEXP payload_sexp)
{
    const char* app     = s_get_utf8(app_sexp, "app_name");
    const char* api     = s_get_utf8(api_sexp, "api_name");
    const char* payload = s_get_utf8(payload_sexp, "payload");
    if (lf_impl_notify(app, api, payload) != 0) {
        Rf_error("lf_notify: native call failed");
    }
    return R_NilValue;
}

static SEXP r_sequenced_notify(SEXP app_sexp, SEXP api_sexp,
                               SEXP payload_sexp)
{
    const char* app     = s_get_utf8(app_sexp, "app_name");
    const char* api     = s_get_utf8(api_sexp, "api_name");
    const char* payload = s_get_utf8(payload_sexp, "payload");
    if (lf_impl_sequenced_notify(app, api, payload) != 0) {
        Rf_error("lf_sequenced_notify: native call failed");
    }
    return R_NilValue;
}

static SEXP r_call_bin(SEXP app_sexp, SEXP api_sexp,
                       SEXP req_sexp, SEXP timeout_sexp)
{
    const char* app = s_get_utf8(app_sexp, "app_name");
    const char* api = s_get_utf8(api_sexp, "api_name");
    if (TYPEOF(req_sexp) != RAWSXP) {
        Rf_error("lf_call_bin: req must be a raw vector");
    }
    R_xlen_t req_len = XLENGTH(req_sexp);
    uint64_t timeout = s_get_uint64_timeout(timeout_sexp, "timeout_ms");

    int64_t out_len = 0;
    const char* result = lf_impl_call_bin(
        app, api, RAW(req_sexp), (int64_t)req_len, timeout, &out_len);
    if (result == NULL) Rf_error("lf_call_bin: %s", lf_impl_last_error());

    SEXP out = PROTECT(Rf_allocVector(RAWSXP, (R_xlen_t)out_len));
    if (out_len > 0) memcpy(RAW(out), result, (size_t)out_len);
    UNPROTECT(1);
    return out;
}

static SEXP r_notify_bin(SEXP app_sexp, SEXP api_sexp, SEXP req_sexp)
{
    const char* app = s_get_utf8(app_sexp, "app_name");
    const char* api = s_get_utf8(api_sexp, "api_name");
    if (TYPEOF(req_sexp) != RAWSXP) {
        Rf_error("lf_notify_bin: req must be a raw vector");
    }
    R_xlen_t req_len = XLENGTH(req_sexp);
    if (lf_impl_notify_bin(app, api, RAW(req_sexp),
                           (int64_t)req_len) != 0) {
        Rf_error("lf_notify_bin: native call failed");
    }
    return R_NilValue;
}

/* ============================================================================
 * SECTION 7 - UID invocation
 * ========================================================================== */

static SEXP r_uid_call(SEXP uid_sexp, SEXP api_sexp,
                       SEXP payload_sexp, SEXP timeout_sexp)
{
    const uint8_t* uid  = s_get_uid32(uid_sexp, "uid");
    const char* api     = s_get_utf8(api_sexp, "api_name");
    const char* payload = s_get_utf8(payload_sexp, "payload");
    uint64_t timeout    = s_get_uint64_timeout(timeout_sexp, "timeout_ms");

    int64_t out_len = 0;
    const char* result = lf_impl_uid_call(
        uid, api, payload, timeout, &out_len);
    if (result == NULL) Rf_error("lf_uid_call: %s", lf_impl_last_error());
    return s_mk_utf8_string(result);
}

static SEXP r_uid_notify(SEXP uid_sexp, SEXP api_sexp, SEXP payload_sexp)
{
    const uint8_t* uid  = s_get_uid32(uid_sexp, "uid");
    const char* api     = s_get_utf8(api_sexp, "api_name");
    const char* payload = s_get_utf8(payload_sexp, "payload");
    if (lf_impl_uid_notify(uid, api, payload) != 0) {
        Rf_error("lf_uid_notify: native call failed");
    }
    return R_NilValue;
}

static SEXP r_uid_sequenced_notify(SEXP uid_sexp, SEXP api_sexp,
                                   SEXP payload_sexp)
{
    const uint8_t* uid  = s_get_uid32(uid_sexp, "uid");
    const char* api     = s_get_utf8(api_sexp, "api_name");
    const char* payload = s_get_utf8(payload_sexp, "payload");
    if (lf_impl_uid_sequenced_notify(uid, api, payload) != 0) {
        Rf_error("lf_uid_sequenced_notify: native call failed");
    }
    return R_NilValue;
}

static SEXP r_uid_call_bin(SEXP uid_sexp, SEXP api_sexp,
                           SEXP req_sexp, SEXP timeout_sexp)
{
    const uint8_t* uid = s_get_uid32(uid_sexp, "uid");
    const char* api    = s_get_utf8(api_sexp, "api_name");
    if (TYPEOF(req_sexp) != RAWSXP) {
        Rf_error("lf_uid_call_bin: req must be a raw vector");
    }
    R_xlen_t req_len = XLENGTH(req_sexp);
    uint64_t timeout = s_get_uint64_timeout(timeout_sexp, "timeout_ms");

    int64_t out_len = 0;
    const char* result = lf_impl_uid_call_bin(
        uid, api, RAW(req_sexp), (int64_t)req_len, timeout, &out_len);
    if (result == NULL) {
        Rf_error("lf_uid_call_bin: %s", lf_impl_last_error());
    }
    SEXP out = PROTECT(Rf_allocVector(RAWSXP, (R_xlen_t)out_len));
    if (out_len > 0) memcpy(RAW(out), result, (size_t)out_len);
    UNPROTECT(1);
    return out;
}

static SEXP r_uid_notify_bin(SEXP uid_sexp, SEXP api_sexp, SEXP req_sexp)
{
    const uint8_t* uid = s_get_uid32(uid_sexp, "uid");
    const char* api    = s_get_utf8(api_sexp, "api_name");
    if (TYPEOF(req_sexp) != RAWSXP) {
        Rf_error("lf_uid_notify_bin: req must be a raw vector");
    }
    R_xlen_t req_len = XLENGTH(req_sexp);
    if (lf_impl_uid_notify_bin(uid, api, RAW(req_sexp),
                               (int64_t)req_len) != 0) {
        Rf_error("lf_uid_notify_bin: native call failed");
    }
    return R_NilValue;
}

/* ============================================================================
 * SECTION 8 - P2PName invocation
 * ========================================================================== */

static SEXP r_p2pname_call(SEXP group_sexp, SEXP api_sexp,
                           SEXP payload_sexp, SEXP timeout_sexp)
{
    const char* group   = s_get_utf8(group_sexp, "group_name");
    const char* api     = s_get_utf8(api_sexp, "api_name");
    const char* payload = s_get_utf8(payload_sexp, "payload");
    uint64_t timeout    = s_get_uint64_timeout(timeout_sexp, "timeout_ms");

    int64_t out_len = 0;
    const char* result = lf_impl_p2pname_call(
        group, api, payload, timeout, &out_len);
    if (result == NULL) Rf_error("lf_p2pname_call: %s",
                                 lf_impl_last_error());
    return s_mk_utf8_string(result);
}

static SEXP r_p2pname_notify(SEXP group_sexp, SEXP api_sexp,
                             SEXP payload_sexp)
{
    const char* group   = s_get_utf8(group_sexp, "group_name");
    const char* api     = s_get_utf8(api_sexp, "api_name");
    const char* payload = s_get_utf8(payload_sexp, "payload");
    if (lf_impl_p2pname_notify(group, api, payload) != 0) {
        Rf_error("lf_p2pname_notify: native call failed");
    }
    return R_NilValue;
}

static SEXP r_p2pname_sequenced_notify(SEXP group_sexp, SEXP api_sexp,
                                       SEXP payload_sexp)
{
    const char* group   = s_get_utf8(group_sexp, "group_name");
    const char* api     = s_get_utf8(api_sexp, "api_name");
    const char* payload = s_get_utf8(payload_sexp, "payload");
    if (lf_impl_p2pname_sequenced_notify(group, api, payload) != 0) {
        Rf_error("lf_p2pname_sequenced_notify: native call failed");
    }
    return R_NilValue;
}

static SEXP r_p2pname_call_bin(SEXP group_sexp, SEXP api_sexp,
                               SEXP req_sexp, SEXP timeout_sexp)
{
    const char* group = s_get_utf8(group_sexp, "group_name");
    const char* api   = s_get_utf8(api_sexp, "api_name");
    if (TYPEOF(req_sexp) != RAWSXP) {
        Rf_error("lf_p2pname_call_bin: req must be a raw vector");
    }
    R_xlen_t req_len = XLENGTH(req_sexp);
    uint64_t timeout = s_get_uint64_timeout(timeout_sexp, "timeout_ms");

    int64_t out_len = 0;
    const char* result = lf_impl_p2pname_call_bin(
        group, api, RAW(req_sexp), (int64_t)req_len, timeout, &out_len);
    if (result == NULL) {
        Rf_error("lf_p2pname_call_bin: %s", lf_impl_last_error());
    }
    SEXP out = PROTECT(Rf_allocVector(RAWSXP, (R_xlen_t)out_len));
    if (out_len > 0) memcpy(RAW(out), result, (size_t)out_len);
    UNPROTECT(1);
    return out;
}

static SEXP r_p2pname_notify_bin(SEXP group_sexp, SEXP api_sexp,
                                 SEXP req_sexp)
{
    const char* group = s_get_utf8(group_sexp, "group_name");
    const char* api   = s_get_utf8(api_sexp, "api_name");
    if (TYPEOF(req_sexp) != RAWSXP) {
        Rf_error("lf_p2pname_notify_bin: req must be a raw vector");
    }
    R_xlen_t req_len = XLENGTH(req_sexp);
    if (lf_impl_p2pname_notify_bin(group, api, RAW(req_sexp),
                                    (int64_t)req_len) != 0) {
        Rf_error("lf_p2pname_notify_bin: native call failed");
    }
    return R_NilValue;
}

/* ============================================================================
 * SECTION 9 - Local execution
 * ========================================================================== */

static SEXP r_local_call(SEXP app_sexp, SEXP api_sexp, SEXP payload_sexp)
{
    void* app = s_get_externalptr(app_sexp, "app");
    if (app == NULL) Rf_error("lf_c_local_call: app is NULL");
    const char* api     = s_get_utf8(api_sexp, "api_name");
    const char* payload = s_get_utf8(payload_sexp, "payload");

    int64_t out_len = 0;
    const char* result = lf_impl_local_call(app, api, payload, &out_len);
    if (result == NULL) {
        Rf_error("lf_c_local_call: %s", lf_impl_last_error());
    }
    return s_mk_utf8_string(result);
}

static SEXP r_local_notify(SEXP app_sexp, SEXP api_sexp, SEXP payload_sexp)
{
    void* app = s_get_externalptr(app_sexp, "app");
    if (app == NULL) Rf_error("lf_c_local_notify: app is NULL");
    const char* api     = s_get_utf8(api_sexp, "api_name");
    const char* payload = s_get_utf8(payload_sexp, "payload");
    if (lf_impl_local_notify(app, api, payload) != 0) {
        Rf_error("lf_c_local_notify: native call failed");
    }
    return R_NilValue;
}

/* ============================================================================
 * SECTION 10 - Runtime options
 * ========================================================================== */

static SEXP r_set_option(SEXP name_sexp, SEXP value_sexp)
{
    const char* name  = s_get_utf8(name_sexp, "name");
    const char* value = s_get_utf8(value_sexp, "value");
    lf_impl_set_option(name, value);
    return R_NilValue;
}

static SEXP r_get_option(SEXP name_sexp)
{
    const char* name = s_get_utf8(name_sexp, "name");
    return s_mk_utf8_string(lf_impl_get_option(name));
}

/* ============================================================================
 * SECTION 11 - Status queue
 * ========================================================================== */

static SEXP r_get_status_count(void)
{
    return Rf_ScalarInteger(lf_impl_get_status_count());
}

static SEXP r_get_status(void)
{
    return s_mk_utf8_string(lf_impl_get_status());
}

static SEXP r_post_status(SEXP text_sexp)
{
    const char* text = s_get_utf8(text_sexp, "text");
    lf_impl_post_status(text);
    return R_NilValue;
}

/* ============================================================================
 * SECTION 12 - Health checks for UID / P2PName
 * ========================================================================== */

static SEXP r_check_uid(SEXP uid_sexp)
{
    const uint8_t* uid = s_get_uid32(uid_sexp, "uid");
    return Rf_ScalarLogical(lf_impl_check_uid(uid) ? TRUE : FALSE);
}

static SEXP r_check_uid_api(SEXP uid_sexp, SEXP api_sexp)
{
    const uint8_t* uid = s_get_uid32(uid_sexp, "uid");
    const char* api    = s_get_utf8(api_sexp, "api_name");
    return Rf_ScalarLogical(
        lf_impl_check_uid_api(uid, api) ? TRUE : FALSE);
}

static SEXP r_check_p2pname(SEXP group_sexp)
{
    const char* group = s_get_utf8(group_sexp, "group_name");
    return Rf_ScalarLogical(
        lf_impl_check_p2pname(group) ? TRUE : FALSE);
}

static SEXP r_check_p2pname_api(SEXP group_sexp, SEXP api_sexp)
{
    const char* group = s_get_utf8(group_sexp, "group_name");
    const char* api   = s_get_utf8(api_sexp, "api_name");
    return Rf_ScalarLogical(
        lf_impl_check_p2pname_api(group, api) ? TRUE : FALSE);
}

/* ============================================================================
 * SECTION 13 - Process-wide P2P registration
 * ========================================================================== */

static SEXP r_register_p2p_call(SEXP api_sexp, SEXP desc_sexp)
{
    const char* api  = s_get_utf8(api_sexp, "api_name");
    const char* desc = s_get_utf8(desc_sexp, "description");
    return Rf_ScalarInteger(lf_impl_register_p2p_call(api, desc, NULL));
}

static SEXP r_register_p2p_notify(SEXP api_sexp, SEXP desc_sexp)
{
    const char* api  = s_get_utf8(api_sexp, "api_name");
    const char* desc = s_get_utf8(desc_sexp, "description");
    return Rf_ScalarInteger(lf_impl_register_p2p_notify(api, desc, NULL));
}

static SEXP r_unregister_p2p(SEXP api_sexp)
{
    const char* api = s_get_utf8(api_sexp, "api_name");
    return Rf_ScalarInteger(lf_impl_unregister_p2p(api));
}

/* ============================================================================
 * SECTION 14 - Callee: registration + Job
 * ========================================================================== */

static SEXP r_register_call(SEXP app_sexp, SEXP api_sexp, SEXP desc_sexp)
{
    void* app = s_get_externalptr(app_sexp, "app");
    if (app == NULL) Rf_error("lf_register_call: app is NULL");
    const char* api  = s_get_utf8(api_sexp, "api_name");
    const char* desc = s_get_utf8(desc_sexp, "description");
    return Rf_ScalarInteger(lf_impl_register_call_raw(app, api, desc, NULL));
}

static SEXP r_register_notify(SEXP app_sexp, SEXP api_sexp, SEXP desc_sexp)
{
    void* app = s_get_externalptr(app_sexp, "app");
    if (app == NULL) Rf_error("lf_register_notify: app is NULL");
    const char* api  = s_get_utf8(api_sexp, "api_name");
    const char* desc = s_get_utf8(desc_sexp, "description");
    return Rf_ScalarInteger(
        lf_impl_register_notify_raw(app, api, desc, NULL));
}

static SEXP r_poll_job(SEXP timeout_sexp)
{
    double t = Rf_asReal(timeout_sexp);
    int64_t ms = 0;
    if (R_FINITE(t) && t > 0) ms = (int64_t)t;

    void* job = lf_impl_poll_job(ms);
    if (job == NULL) return R_NilValue;
    SEXP ext = PROTECT(R_MakeExternalPtr(job, R_NilValue, R_NilValue));
    R_RegisterCFinalizerEx(ext, job_externalptr_finalizer, TRUE);
    UNPROTECT(1);
    return ext;
}

static SEXP r_job_kind(SEXP job_sexp)
{
    void* job = s_get_externalptr(job_sexp, "job");
    if (job == NULL) Rf_error("lf_job_kind: job is NULL");
    return Rf_ScalarInteger(lf_impl_job_kind(job));
}

static SEXP r_job_registry_space(SEXP job_sexp)
{
    void* job = s_get_externalptr(job_sexp, "job");
    if (job == NULL) Rf_error("lf_job_registry_space: job is NULL");
    return Rf_ScalarInteger(lf_impl_job_registry_space(job));
}

static SEXP r_job_api_name(SEXP job_sexp)
{
    void* job = s_get_externalptr(job_sexp, "job");
    if (job == NULL) Rf_error("lf_job_api_name: job is NULL");
    const char* name = lf_impl_job_api_name(job);
    if (name == NULL) Rf_error("lf_job_api_name: native returned NULL");
    return s_mk_utf8_string(name);
}

static SEXP r_job_is_call(SEXP job_sexp)
{
    void* job = s_get_externalptr(job_sexp, "job");
    if (job == NULL) Rf_error("lf_job_is_call: job is NULL");
    return Rf_ScalarLogical(lf_impl_job_is_call(job) ? TRUE : FALSE);
}

static SEXP r_job_input_size(SEXP job_sexp)
{
    void* job = s_get_externalptr(job_sexp, "job");
    if (job == NULL) Rf_error("lf_job_input_size: job is NULL");
    int64_t n = lf_impl_job_get_input_size(job);
    if (n < 0) Rf_error("lf_job_input_size: native call failed");
    return Rf_ScalarReal((double)n);
}

/* String-mode input: reads the payload and strips a single trailing
 * NUL. Returns a length-1 character vector. */
static SEXP r_job_get_input(SEXP job_sexp)
{
    void* job = s_get_externalptr(job_sexp, "job");
    if (job == NULL) Rf_error("lf_job_get_input: job is NULL");

    int64_t n = lf_impl_job_get_input_size(job);
    if (n < 0) Rf_error("lf_job_get_input: native call failed");
    if (n == 0) return s_mk_utf8_string("");

    SEXP raw = PROTECT(Rf_allocVector(RAWSXP, (R_xlen_t)n));
    int64_t got = lf_impl_job_get_input(job, RAW(raw), n);
    if (got < 0) {
        UNPROTECT(1);
        Rf_error("lf_job_get_input: native call failed");
    }
    if (got > 0 && ((const char*)RAW(raw))[got - 1] == '\0') {
        got--;
    }
    SEXP str = PROTECT(Rf_allocVector(STRSXP, 1));
    SET_STRING_ELT(str, 0,
                   Rf_mkCharLenCE((const char*)RAW(raw), (int)got, CE_UTF8));
    UNPROTECT(2);
    return str;
}

/* Binary-mode input: reads the payload verbatim as a raw vector. */
static SEXP r_job_get_input_bin(SEXP job_sexp)
{
    void* job = s_get_externalptr(job_sexp, "job");
    if (job == NULL) Rf_error("lf_job_get_input_bin: job is NULL");
    int64_t n = lf_impl_job_get_input_size(job);
    if (n < 0) Rf_error("lf_job_get_input_bin: native call failed");
    if (n == 0) return Rf_allocVector(RAWSXP, 0);

    SEXP raw = PROTECT(Rf_allocVector(RAWSXP, (R_xlen_t)n));
    int64_t got = lf_impl_job_get_input(job, RAW(raw), n);
    if (got < 0) {
        UNPROTECT(1);
        Rf_error("lf_job_get_input_bin: native call failed");
    }
    if (got == n) { UNPROTECT(1); return raw; }
    SEXP shrunk = PROTECT(Rf_allocVector(RAWSXP, (R_xlen_t)got));
    if (got > 0) memcpy(RAW(shrunk), RAW(raw), (size_t)got);
    UNPROTECT(2);
    return shrunk;
}

/* Side data */
static SEXP r_job_sender_uid_valid(SEXP job_sexp)
{
    void* job = s_get_externalptr(job_sexp, "job");
    if (job == NULL) Rf_error("lf_job_sender_uid_valid: job is NULL");
    return Rf_ScalarLogical(
        lf_impl_job_sender_uid_valid(job) ? TRUE : FALSE);
}

static SEXP r_job_sender_uid(SEXP job_sexp)
{
    void* job = s_get_externalptr(job_sexp, "job");
    if (job == NULL) Rf_error("lf_job_sender_uid: job is NULL");
    if (!lf_impl_job_sender_uid_valid(job)) return R_NilValue;

    SEXP out = PROTECT(Rf_allocVector(RAWSXP, 32));
    int ok = lf_impl_job_sender_uid(job, RAW(out), 32);
    if (!ok) {
        UNPROTECT(1);
        return R_NilValue;
    }
    UNPROTECT(1);
    return out;
}

static SEXP r_job_sender_p2p_name(SEXP job_sexp)
{
    void* job = s_get_externalptr(job_sexp, "job");
    if (job == NULL) Rf_error("lf_job_sender_p2p_name: job is NULL");
    const char* p = lf_impl_job_sender_p2p_name(job);
    return s_mk_utf8_string(p ? p : "");
}

/* String-mode completion */
static SEXP r_job_complete(SEXP job_sexp, SEXP output_sexp)
{
    void* job = s_get_externalptr(job_sexp, "job");
    if (job == NULL) return R_NilValue;

    const char* output = s_get_utf8(output_sexp, "output");
    int64_t len = (output != NULL) ? (int64_t)strlen(output) : 0;
    lf_impl_job_complete(job, output, len);
    R_ClearExternalPtr(job_sexp);
    return R_NilValue;
}

/* Binary-mode completion */
static SEXP r_job_complete_bin(SEXP job_sexp, SEXP out_sexp)
{
    void* job = s_get_externalptr(job_sexp, "job");
    if (job == NULL) return R_NilValue;
    if (TYPEOF(out_sexp) != RAWSXP) {
        Rf_error("lf_job_complete_bin: out must be a raw vector");
    }
    R_xlen_t len = XLENGTH(out_sexp);
    lf_impl_job_complete(job, RAW(out_sexp), (int64_t)len);
    R_ClearExternalPtr(job_sexp);
    return R_NilValue;
}

/* Explicit abandon (rarely needed; the finalizer handles the common case) */
static SEXP r_job_abandon(SEXP job_sexp)
{
    if (TYPEOF(job_sexp) != EXTPTRSXP) return R_NilValue;
    void* job = R_ExternalPtrAddr(job_sexp);
    if (job == NULL) return R_NilValue;
    lf_impl_job_abandon(job);
    R_ClearExternalPtr(job_sexp);
    return R_NilValue;
}

static SEXP r_set_job_timeout_ms(SEXP ms_sexp)
{
    double ms = Rf_asReal(ms_sexp);
    if (!R_FINITE(ms) || ms < 0) ms = 0;
    lf_impl_set_job_timeout_ms((int64_t)ms);
    return R_NilValue;
}

static SEXP r_pending_job_count(void)
{
    return Rf_ScalarReal((double)lf_impl_pending_job_count());
}

/* ============================================================================
 * SECTION 15 - Asynchronous calls
 * ========================================================================== */

static SEXP r_async_call(SEXP app_sexp, SEXP api_sexp,
                         SEXP payload_sexp, SEXP timeout_sexp)
{
    const char* app     = s_get_utf8(app_sexp, "app_name");
    const char* api     = s_get_utf8(api_sexp, "api_name");
    const char* payload = s_get_utf8(payload_sexp, "payload");
    uint64_t timeout    = s_get_uint64_timeout(timeout_sexp, "timeout_ms");
    return Rf_ScalarReal((double)lf_impl_async_call(
        app, api, payload, timeout));
}

static SEXP r_async_sequenced_call(SEXP app_sexp, SEXP api_sexp,
                                   SEXP payload_sexp, SEXP timeout_sexp)
{
    const char* app     = s_get_utf8(app_sexp, "app_name");
    const char* api     = s_get_utf8(api_sexp, "api_name");
    const char* payload = s_get_utf8(payload_sexp, "payload");
    uint64_t timeout    = s_get_uint64_timeout(timeout_sexp, "timeout_ms");
    return Rf_ScalarReal((double)lf_impl_async_sequenced_call(
        app, api, payload, timeout));
}

static SEXP r_uid_async_call(SEXP uid_sexp, SEXP api_sexp,
                             SEXP payload_sexp, SEXP timeout_sexp)
{
    const uint8_t* uid  = s_get_uid32(uid_sexp, "uid");
    const char* api     = s_get_utf8(api_sexp, "api_name");
    const char* payload = s_get_utf8(payload_sexp, "payload");
    uint64_t timeout    = s_get_uint64_timeout(timeout_sexp, "timeout_ms");
    return Rf_ScalarReal((double)lf_impl_uid_async_call(
        uid, api, payload, timeout));
}

static SEXP r_uid_async_sequenced_call(SEXP uid_sexp, SEXP api_sexp,
                                       SEXP payload_sexp,
                                       SEXP timeout_sexp)
{
    const uint8_t* uid  = s_get_uid32(uid_sexp, "uid");
    const char* api     = s_get_utf8(api_sexp, "api_name");
    const char* payload = s_get_utf8(payload_sexp, "payload");
    uint64_t timeout    = s_get_uint64_timeout(timeout_sexp, "timeout_ms");
    return Rf_ScalarReal((double)lf_impl_uid_async_sequenced_call(
        uid, api, payload, timeout));
}

static SEXP r_p2pname_async_call(SEXP group_sexp, SEXP api_sexp,
                                 SEXP payload_sexp, SEXP timeout_sexp)
{
    const char* group   = s_get_utf8(group_sexp, "group_name");
    const char* api     = s_get_utf8(api_sexp, "api_name");
    const char* payload = s_get_utf8(payload_sexp, "payload");
    uint64_t timeout    = s_get_uint64_timeout(timeout_sexp, "timeout_ms");
    return Rf_ScalarReal((double)lf_impl_p2pname_async_call(
        group, api, payload, timeout));
}

static SEXP r_p2pname_async_sequenced_call(SEXP group_sexp, SEXP api_sexp,
                                           SEXP payload_sexp,
                                           SEXP timeout_sexp)
{
    const char* group   = s_get_utf8(group_sexp, "group_name");
    const char* api     = s_get_utf8(api_sexp, "api_name");
    const char* payload = s_get_utf8(payload_sexp, "payload");
    uint64_t timeout    = s_get_uint64_timeout(timeout_sexp, "timeout_ms");
    return Rf_ScalarReal((double)lf_impl_p2pname_async_sequenced_call(
        group, api, payload, timeout));
}

/* AsyncResult job queries */
static SEXP r_job_callback_id(SEXP job_sexp)
{
    void* job = s_get_externalptr(job_sexp, "job");
    if (job == NULL) Rf_error("lf_job_callback_id: job is NULL");
    return Rf_ScalarReal((double)lf_impl_job_callback_id(job));
}

static SEXP r_job_result(SEXP job_sexp)
{
    void* job = s_get_externalptr(job_sexp, "job");
    if (job == NULL) Rf_error("lf_job_result: job is NULL");
    return s_mk_utf8_string(lf_impl_job_result(job));
}

static SEXP r_job_error(SEXP job_sexp)
{
    void* job = s_get_externalptr(job_sexp, "job");
    if (job == NULL) Rf_error("lf_job_error: job is NULL");
    return s_mk_utf8_string(lf_impl_job_error(job));
}

static SEXP r_job_error_kind(SEXP job_sexp)
{
    void* job = s_get_externalptr(job_sexp, "job");
    if (job == NULL) Rf_error("lf_job_error_kind: job is NULL");
    return Rf_ScalarInteger(lf_impl_job_error_kind(job));
}

static SEXP r_async_release(SEXP id_sexp)
{
    int64_t id = s_get_int64(id_sexp, "callback_id");
    lf_impl_async_release(id);
    return R_NilValue;
}

static SEXP r_async_slot_count(void)
{
    return Rf_ScalarReal((double)lf_impl_async_slot_count());
}

/* ============================================================================
 * SECTION 16 - Network events
 * ========================================================================== */

/* The R side never passes the two C function pointers directly.
 * Instead, it calls this function with two logicals that select
 * which of the four pre-installed trampolines should be active.
 *
 * This avoids any need for the R layer to construct C function
 * pointers, and keeps the C++-layer trampolines private. */

/* Forward declarations of the trampolines that live in the C++
 * layer. They are extern "C" so C can name them. */
extern void net_connect_trampoline(const char* addr);
extern void net_disconnect_trampoline(const char* addr);

static SEXP r_set_network_event_impl(SEXP enable_connect_sexp,
                                     SEXP enable_disconnect_sexp)
{
    int enable_connect = Rf_asLogical(enable_connect_sexp);
    int enable_disconnect = Rf_asLogical(enable_disconnect_sexp);
    if (enable_connect == NA_LOGICAL) enable_connect = 0;
    if (enable_disconnect == NA_LOGICAL) enable_disconnect = 0;

    lf_impl_set_network_event(
        enable_connect    ? net_connect_trampoline    : NULL,
        enable_disconnect ? net_disconnect_trampoline : NULL);
    return R_NilValue;
}

static SEXP r_job_event_kind(SEXP job_sexp)
{
    void* job = s_get_externalptr(job_sexp, "job");
    if (job == NULL) Rf_error("lf_job_event_kind: job is NULL");
    return s_mk_utf8_string(lf_impl_job_event_kind(job));
}

static SEXP r_job_event_addr(SEXP job_sexp)
{
    void* job = s_get_externalptr(job_sexp, "job");
    if (job == NULL) Rf_error("lf_job_event_addr: job is NULL");
    return s_mk_utf8_string(lf_impl_job_event_addr(job));
}

/* ============================================================================
 * SECTION 17 - Shutdown
 * ========================================================================== */

static SEXP r_shutdown(void)
{
    lf_impl_shutdown();
    return R_NilValue;
}

/* ============================================================================
 * Registration table
 * ========================================================================== */

static const R_CallMethodDef CallEntries[] = {
    /* ---- SECTION 1: build chain probes ---- */
    {"lf_ping",          (DL_FUNC) &r_ping,          0},
    {"lf_echo",          (DL_FUNC) &r_echo,          1},
    {"lf_info",          (DL_FUNC) &r_info,          0},

    /* ---- SECTION 2: runtime loading ---- */
    {"lf_load_library",   (DL_FUNC) &r_load_library,   1},
    {"lf_unload_library", (DL_FUNC) &r_unload_library, 0},
    {"lf_is_loaded",      (DL_FUNC) &r_is_loaded,      0},
    {"lf_loaded_path",    (DL_FUNC) &r_loaded_path,    0},
    {"lf_last_error",     (DL_FUNC) &r_last_error,     0},

    /* ---- SECTION 3: DataHandle ---- */
    {"lf_data_create",           (DL_FUNC) &r_data_create,           1},
    {"lf_data_create_permanent", (DL_FUNC) &r_data_create_permanent, 1},
    {"lf_data_free",             (DL_FUNC) &r_data_free,             1},
    {"lf_data_write_buffer",     (DL_FUNC) &r_data_write_buffer,     2},
    {"lf_data_read_buffer",      (DL_FUNC) &r_data_read_buffer,      2},
    {"lf_data_get_size",         (DL_FUNC) &r_data_get_size,         1},
    {"lf_data_get_pos",          (DL_FUNC) &r_data_get_pos,          1},
    {"lf_data_set_pos",          (DL_FUNC) &r_data_set_pos,          2},
    {"lf_data_set_size",         (DL_FUNC) &r_data_set_size,         2},
    {"lf_data_get_buffer",       (DL_FUNC) &r_data_get_buffer,       1},

    /* ---- SECTION 4: AppHandle ---- */
    {"lf_app_create",       (DL_FUNC) &r_app_create,       2},
    {"lf_app_free",         (DL_FUNC) &r_app_free,         1},
    {"lf_app_name",         (DL_FUNC) &r_app_name,         1},
    {"lf_app_bind",         (DL_FUNC) &r_app_bind,         1},
    {"lf_app_unregister",   (DL_FUNC) &r_app_unregister,   2},
    {"lf_generate_app_name",(DL_FUNC) &r_generate_app_name,0},

    /* ---- SECTION 5: network preparation ---- */
    {"lf_reset_prepare",           (DL_FUNC) &r_reset_prepare,            0},
    {"lf_prepare_service",         (DL_FUNC) &r_prepare_service,          2},
    {"lf_prepare_client",          (DL_FUNC) &r_prepare_client,           1},
    {"lf_prepare_client_with_app", (DL_FUNC) &r_prepare_client_with_app,  2},
    {"lf_prepare_done",            (DL_FUNC) &r_prepare_done,             0},
    {"lf_exit_main_thread",        (DL_FUNC) &r_exit_main_thread,         0},
    {"lf_check_main_thread",       (DL_FUNC) &r_check_main_thread,        0},
    {"lf_check_app",               (DL_FUNC) &r_check_app,                1},
    {"lf_check_api",               (DL_FUNC) &r_check_api,                2},

    /* ---- SECTION 6: App-name invocation ---- */
    {"lf_call",              (DL_FUNC) &r_call,              4},
    {"lf_notify",            (DL_FUNC) &r_notify,            3},
    {"lf_sequenced_notify",  (DL_FUNC) &r_sequenced_notify,  3},
    {"lf_call_bin",          (DL_FUNC) &r_call_bin,          4},
    {"lf_notify_bin",        (DL_FUNC) &r_notify_bin,        3},

    /* ---- SECTION 7: UID invocation ---- */
    {"lf_uid_call",              (DL_FUNC) &r_uid_call,              4},
    {"lf_uid_notify",            (DL_FUNC) &r_uid_notify,            3},
    {"lf_uid_sequenced_notify",  (DL_FUNC) &r_uid_sequenced_notify,  3},
    {"lf_uid_call_bin",          (DL_FUNC) &r_uid_call_bin,          4},
    {"lf_uid_notify_bin",        (DL_FUNC) &r_uid_notify_bin,        3},

    /* ---- SECTION 8: P2PName invocation ---- */
    {"lf_p2pname_call",              (DL_FUNC) &r_p2pname_call,              4},
    {"lf_p2pname_notify",            (DL_FUNC) &r_p2pname_notify,            3},
    {"lf_p2pname_sequenced_notify",  (DL_FUNC) &r_p2pname_sequenced_notify,  3},
    {"lf_p2pname_call_bin",          (DL_FUNC) &r_p2pname_call_bin,          4},
    {"lf_p2pname_notify_bin",        (DL_FUNC) &r_p2pname_notify_bin,        3},

    /* ---- SECTION 9: local execution ---- */
    {"lf_c_local_call",     (DL_FUNC) &r_local_call,    3},
    {"lf_c_local_notify",   (DL_FUNC) &r_local_notify,  3},

    /* ---- SECTION 10: options ---- */
    {"lf_set_option", (DL_FUNC) &r_set_option, 2},
    {"lf_get_option", (DL_FUNC) &r_get_option, 1},

    /* ---- SECTION 11: status ---- */
    {"lf_get_status_count", (DL_FUNC) &r_get_status_count, 0},
    {"lf_get_status",       (DL_FUNC) &r_get_status,       0},
    {"lf_post_status",      (DL_FUNC) &r_post_status,      1},

    /* ---- SECTION 12: UID / P2PName health checks ---- */
    {"lf_check_uid",           (DL_FUNC) &r_check_uid,           1},
    {"lf_check_uid_api",       (DL_FUNC) &r_check_uid_api,       2},
    {"lf_check_p2pname",       (DL_FUNC) &r_check_p2pname,       1},
    {"lf_check_p2pname_api",   (DL_FUNC) &r_check_p2pname_api,   2},

    /* ---- SECTION 13: process-wide P2P registration ---- */
    {"lf_register_p2p_call",   (DL_FUNC) &r_register_p2p_call,   2},
    {"lf_register_p2p_notify", (DL_FUNC) &r_register_p2p_notify, 2},
    {"lf_unregister_p2p",      (DL_FUNC) &r_unregister_p2p,      1},

    /* ---- SECTION 14: callee ---- */
    {"lf_register_call",      (DL_FUNC) &r_register_call,      3},
    {"lf_register_notify",    (DL_FUNC) &r_register_notify,    3},
    {"lf_poll_job",           (DL_FUNC) &r_poll_job,           1},
    {"lf_job_kind",           (DL_FUNC) &r_job_kind,           1},
    {"lf_job_registry_space", (DL_FUNC) &r_job_registry_space, 1},
    {"lf_job_api_name",       (DL_FUNC) &r_job_api_name,       1},
    {"lf_job_is_call",        (DL_FUNC) &r_job_is_call,        1},
    {"lf_job_input_size",     (DL_FUNC) &r_job_input_size,     1},
    {"lf_job_get_input",      (DL_FUNC) &r_job_get_input,      1},
    {"lf_job_get_input_bin",  (DL_FUNC) &r_job_get_input_bin,  1},
    {"lf_job_sender_uid_valid",(DL_FUNC) &r_job_sender_uid_valid, 1},
    {"lf_job_sender_uid",     (DL_FUNC) &r_job_sender_uid,     1},
    {"lf_job_sender_p2p_name",(DL_FUNC) &r_job_sender_p2p_name,1},
    {"lf_job_complete",       (DL_FUNC) &r_job_complete,       2},
    {"lf_job_complete_bin",   (DL_FUNC) &r_job_complete_bin,   2},
    {"lf_job_abandon",        (DL_FUNC) &r_job_abandon,        1},
    {"lf_set_job_timeout_ms", (DL_FUNC) &r_set_job_timeout_ms, 1},
    {"lf_pending_job_count",  (DL_FUNC) &r_pending_job_count,  0},

    /* ---- SECTION 15: asynchronous ---- */
    {"lf_async_call",                 (DL_FUNC) &r_async_call,                  4},
    {"lf_async_sequenced_call",       (DL_FUNC) &r_async_sequenced_call,        4},
    {"lf_uid_async_call",             (DL_FUNC) &r_uid_async_call,              4},
    {"lf_uid_async_sequenced_call",   (DL_FUNC) &r_uid_async_sequenced_call,    4},
    {"lf_p2pname_async_call",         (DL_FUNC) &r_p2pname_async_call,          4},
    {"lf_p2pname_async_sequenced_call",(DL_FUNC) &r_p2pname_async_sequenced_call,4},
    {"lf_job_callback_id",            (DL_FUNC) &r_job_callback_id,             1},
    {"lf_job_result",                 (DL_FUNC) &r_job_result,                  1},
    {"lf_job_error",                  (DL_FUNC) &r_job_error,                   1},
    {"lf_job_error_kind",             (DL_FUNC) &r_job_error_kind,              1},
    {"lf_async_release",              (DL_FUNC) &r_async_release,               1},
    {"lf_async_slot_count",           (DL_FUNC) &r_async_slot_count,            0},

    /* ---- SECTION 16: network events ---- */
    {"lf_set_network_event_impl", (DL_FUNC) &r_set_network_event_impl, 2},
    {"lf_job_event_kind",         (DL_FUNC) &r_job_event_kind,         1},
    {"lf_job_event_addr",         (DL_FUNC) &r_job_event_addr,         1},

    /* ---- SECTION 17: shutdown ---- */
    {"lf_shutdown", (DL_FUNC) &r_shutdown, 0},

    {NULL, NULL, 0}
};

/* The name of the package initialisation routine must match the R
 * package name: R CMD INSTALL looks for R_init_<pkgname>. Since this
 * same source file is compiled both by R CMD SHLIB (for the
 * standalone bridge DLL used by the R scripts under c_ext/tests/)
 * and by R CMD INSTALL (for the lingofuse package), the name is
 * selected at compile time via the LF_R_INIT_NAME macro.
 *
 *   * c_ext/tests scripts build with the default:
 *       R_init_lfR_bridge
 *
 *   * The lingofuse package sets
 *       -DLF_R_INIT_NAME=R_init_lingofuse
 *     in its src/Makevars[.win] file.
 *
 * R_useDynamicSymbols(TRUE) is required: the R scripts under
 * c_ext/tests/ call .Call("lf_echo", ...) by string name, which only
 * works when dynamic symbol lookup is enabled. The lingofuse package
 * uses the same setting; it is harmless there and keeps the two
 * build paths identical. */
#ifndef LF_R_INIT_NAME
#  define LF_R_INIT_NAME R_init_lfR_bridge
#endif

void LF_R_INIT_NAME(DllInfo *dll)
{
    R_registerRoutines(dll, NULL, CallEntries, NULL, NULL);
    R_useDynamicSymbols(dll, TRUE);
}