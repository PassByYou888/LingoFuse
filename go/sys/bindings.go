// Package sys is the low-level FFI layer for the LingoFuse native
// library. It is the ONLY place in the Go binding where native code
// is invoked.
//
// This file mirrors the C++ header LingoFuse.h and the Rust module
// bindings.rs one-to-one. Every exported C function has exactly one
// corresponding package-level function variable, resolved at load
// time by loader.go.
//
// {!!!!!  UID PARAMETERS ARE DECLARED AS POINTERS  !!!!!}
// The C ABI declares UID arguments as `TP2P_UID___` (a 32-byte
// Pascal array) passed BY VALUE. On x86-64, an aggregate larger than
// 8 bytes is classified MEMORY by the psABI, which means the caller
// allocates space for the value and passes a POINTER to that space
// in the argument register.
//
// purego, the FFI library used by this binding, does not support
// struct or array arguments on Windows amd64. We therefore declare
// the Go-side parameter as `*TP2P_UID` and pass the address of a
// local copy of the value. This matches the ABI on every supported
// platform: purego places the pointer in the argument register, and
// the callee reads 32 bytes from it. See sys/uid.go for the full
// rationale and for the argument / return-role distinction.
package sys

// ---------------------------------------------------------------------------
// Opaque handle types
// ---------------------------------------------------------------------------

// DataHnd is an opaque handle to a LingoFuse data buffer (TDataHnd).
//
// Two kinds exist:
//   - Auto-recycled (created by LF_CreateData): added to the idle
//     pool, which scans every 5 seconds and frees handles idle for
//     more than 10 minutes.
//   - Permanent (created by LF_CreateData_Permanent): not added to
//     the pool, never auto-reclaimed.
//
// Both kinds must be freed with LF_FreeData. Never dereference this
// value.
type DataHnd = uintptr

// AppHnd is an opaque handle to a LingoFuse application (TAppHnd).
//
// LF_FreeApp performs only the first stage of a two-stage destruction:
// the object remains in the global pool until LF_Shutdown.
type AppHnd = uintptr

// ---------------------------------------------------------------------------
// Callback prototypes (as raw C function pointer types)
// ---------------------------------------------------------------------------
//
// In Go, a void return is represented as returning uintptr(0).

// LfCallFunc is the Go representation of the C callback
//
//	void (*)(void* trigger, TDataHnd input, TDataHnd output)
type LfCallFunc func(trigger uintptr, input DataHnd, output DataHnd) uintptr

// LfNotifyFunc is the Go representation of
//
//	void (*)(void* trigger, TDataHnd input)
type LfNotifyFunc func(trigger uintptr, input DataHnd) uintptr

// LfNetworkEventFunc is the Go representation of
//
//	void (*)(const char* addr)
type LfNetworkEventFunc func(addr *byte) uintptr

// LfAsyncCallOnResult is the Go representation of the C callback
//
//	void (*)(void* data, TDataHnd result)
//
// Parameters:
//
//	data   -- the opaque pointer the caller passed at the call site.
//	          The framework neither owns nor frees it. The Go binding
//	          uses it as a registry key (see callbacks.go), so it is
//	          always a small integer cast to uintptr.
//
//	result -- a DataHandle OWNED BY THE FRAMEWORK. It is released
//	          IMMEDIATELY after this callback returns (Pascal side:
//	          TLF_Async_Call_Bridge.Do_Th calls TLF_Data.Free_Data
//	          on the result handle right after invoking OnResult).
//	          The callback MUST NOT call LF_FreeData on it, and MUST
//	          NOT retain the pointer past its own return.
//
// Execution context: TCompute worker thread (NOT the calling thread
// and NOT the simulated main thread). The callback MUST NOT block,
// and MUST NOT call any synchronous LingoFuse function. Doing so will
// deadlock.
type LfAsyncCallOnResult func(data uintptr, result DataHnd) uintptr

// ---------------------------------------------------------------------------
// Function pointer table
// ---------------------------------------------------------------------------
//
// Each variable is populated once by loader.go and is nil before that.
// Calling any of these before LoadLibrary succeeds is a nil-pointer
// panic — mirroring the "must call LF_LoadLibrary first" rule of the
// C++ binding.

var (
	// =======================================================================
	// Data handle operations (12)
	// =======================================================================

	// LF_CreateData creates a new auto-recycled data handle.
	LF_CreateData func(methodName *byte) DataHnd

	// LF_CreateData_Permanent creates a new permanent data handle.
	LF_CreateData_Permanent func(methodName *byte) DataHnd

	// LF_FreeData releases a data handle. Nil is accepted and ignored.
	LF_FreeData func(hnd DataHnd)

	// LF_GetBuffer returns a raw pointer to the internal buffer.
	LF_GetBuffer func(hnd DataHnd) uintptr

	// LF_WriteBuffer writes bytes at the current cursor.
	LF_WriteBuffer func(hnd DataHnd, buff uintptr, size int64) int64

	// LF_ReadBuffer reads bytes at the current cursor.
	LF_ReadBuffer func(hnd DataHnd, buff uintptr, size int64) int64

	// LF_GetPos returns the current read/write cursor.
	LF_GetPos func(hnd DataHnd) int64

	// LF_SetPos sets the current read/write cursor.
	LF_SetPos func(hnd DataHnd, pos int64)

	// LF_GetSize returns the total buffer size in bytes.
	LF_GetSize func(hnd DataHnd) int64

	// LF_SetSize resizes the buffer.
	LF_SetSize func(hnd DataHnd, size int64)

	// LF_Get_P2P_UID returns a POINTER to a 32-byte UID.
	//
	// {!!!!!  SIDE DATA, NOT A HANDLE PROPERTY  !!!!!}
	// This function reads the FromUID field that the SENDER'S
	// transport layer injects into every request payload before
	// transmission. It is valid ONLY on an INPUT handle; on any
	// other handle it returns a pointer to a zero-filled UID.
	//
	// The pointer is allocated by the C side and released
	// automatically about 5 seconds after the call. Callers MUST
	// copy the 32 bytes immediately and MUST NOT free the pointer.
	//
	// See the docstring of TP2P_UID in uid.go for the ARGUMENT-role
	// / RETURN-role distinction: this function is the ONLY one that
	// uses the pointer-to-value representation.
	LF_Get_P2P_UID func(hnd DataHnd) *TP2P_UID

	// LF_Get_P2P_Name returns a pointer to a transient NUL-terminated
	// UTF-8 string.
	//
	// Same side-data contract as LF_Get_P2P_UID. The pointer is
	// released by the C side about 5 seconds after the call; callers
	// MUST copy the string immediately.
	LF_Get_P2P_Name func(hnd DataHnd) *byte

	// =======================================================================
	// Application handle operations (5)
	// =======================================================================

	// LF_CreateApp creates a new application.
	LF_CreateApp func(appName, desc *byte) AppHnd

	// LF_FreeApp detaches an application (stage one of two).
	LF_FreeApp func(appHnd AppHnd)

	// LF_Generate_AppName returns a temporary pointer valid for ~5 seconds.
	LF_Generate_AppName func() *byte

	// LF_Get_AppName returns the name of an existing handle (5 s validity).
	LF_Get_AppName func(appHnd AppHnd) *byte

	// LF_BindApp binds an application to unbound clients.
	LF_BindApp func(appHnd AppHnd) int32

	// =======================================================================
	// API registration, app-bound (3)
	// =======================================================================

	// LF_RegisterCall registers a Call (request-response) API.
	LF_RegisterCall func(appHnd AppHnd, methodName, desc *byte, trigger uintptr, onCall uintptr) int32

	// LF_RegisterNotify registers a Notify (one-way) API.
	LF_RegisterNotify func(appHnd AppHnd, methodName, desc *byte, trigger uintptr, onNotify uintptr) int32

	// LF_Unregister removes a registered API.
	LF_Unregister func(appHnd AppHnd, methodName *byte) int32

	// =======================================================================
	// API registration, process-wide P2P (3)
	// =======================================================================

	// LF_Register_P2P_Call registers a process-wide P2P Call API.
	//
	// P2P APIs are reachable via UID addressing and P2PName
	// addressing ONLY. They are NOT reachable via App-name
	// addressing, even if the registered name matches an App name.
	LF_Register_P2P_Call func(methodName, desc *byte, trigger uintptr, onCall uintptr) int32

	// LF_Register_P2P_Notify registers a process-wide P2P Notify API.
	LF_Register_P2P_Notify func(methodName, desc *byte, trigger uintptr, onNotify uintptr) int32

	// LF_Unregister_P2P removes a process-wide P2P API by name.
	//
	// Does NOT affect app-bound APIs of the same name.
	LF_Unregister_P2P func(methodName *byte) int32

	// =======================================================================
	// Local execution (2)
	// =======================================================================

	// LF_LocalCall invokes a Call API in-process.
	LF_LocalCall func(appHnd AppHnd, param DataHnd) DataHnd

	// LF_LocalNotify invokes a Notify API in-process.
	LF_LocalNotify func(appHnd AppHnd, param DataHnd)

	// =======================================================================
	// Network preparation (5)
	// =======================================================================

	// LF_ResetPrepare clears the preparation queue.
	LF_ResetPrepare func()

	// LF_PrepareService prepares a C4 service.
	LF_PrepareService func(listeningAddr, physicsAddr *byte) int32

	// LF_PrepareClient prepares a C4 client.
	LF_PrepareClient func(physicsAddr *byte, appHnd AppHnd) int32

	// LF_PrepareDone starts the framework (returns 1 only once).
	LF_PrepareDone func() int32

	// LF_ExitMainThread requests the simulated main thread to exit.
	LF_ExitMainThread func()

	// =======================================================================
	// Remote invocation, app-name addressing (5)
	// =======================================================================

	// LF_Call performs a synchronous remote call.
	LF_Call func(appName *byte, param DataHnd, timeoutMs uint64) DataHnd

	// LF_Async_Call performs an asynchronous remote call.
	//
	// Returns 1 if the request was queued, 0 otherwise. When the
	// return value is not 1, the callback is NEVER invoked.
	LF_Async_Call func(appName *byte, param DataHnd, data uintptr, onResult uintptr) int32

	// LF_Async_Sequenced_Call is like LF_Async_Call, but requests
	// are delivered in FIFO order per (app, api) pair.
	LF_Async_Sequenced_Call func(appName *byte, param DataHnd, data uintptr, onResult uintptr) int32

	// LF_Notify sends a one-way notification.
	LF_Notify func(appName *byte, param DataHnd)

	// LF_Sequenced_Notify sends a FIFO-ordered one-way notification.
	LF_Sequenced_Notify func(appName *byte, param DataHnd)

	// =======================================================================
	// Remote invocation, UID addressing (5)
	// =======================================================================
	//
	// The first parameter is a POINTER to the 32-byte UID. See the
	// package docstring and sys/uid.go for the full rationale on why
	// the Go-side representation is a pointer rather than a struct.

	// LF_UID_Call performs a synchronous remote call addressed by UID.
	LF_UID_Call func(uid *TP2P_UID, param DataHnd, timeoutMs uint64) DataHnd

	// LF_UID_Async_Call performs an asynchronous UID-addressed call.
	LF_UID_Async_Call func(uid *TP2P_UID, param DataHnd, data uintptr, onResult uintptr) int32

	// LF_UID_Async_Sequenced_Call is the FIFO-ordered variant.
	LF_UID_Async_Sequenced_Call func(uid *TP2P_UID, param DataHnd, data uintptr, onResult uintptr) int32

	// LF_UID_Notify sends a one-way notification addressed by UID.
	LF_UID_Notify func(uid *TP2P_UID, param DataHnd)

	// LF_UID_Sequenced_Notify is the FIFO-ordered variant.
	LF_UID_Sequenced_Notify func(uid *TP2P_UID, param DataHnd)

	// =======================================================================
	// Remote invocation, P2PName addressing (5)
	// =======================================================================

	// LF_P2PNAME_Call performs a synchronous call addressed by P2P
	// group name.
	//
	// Routing is NOT local-first: the call is always forwarded to
	// the server for dispatch, so that server-side load balancing
	// is preserved.
	LF_P2PNAME_Call func(p2pName *byte, param DataHnd, timeoutMs uint64) DataHnd

	// LF_P2PNAME_Async_Call performs an asynchronous P2PName-addressed call.
	LF_P2PNAME_Async_Call func(p2pName *byte, param DataHnd, data uintptr, onResult uintptr) int32

	// LF_P2PNAME_Async_Sequenced_Call is the FIFO-ordered variant.
	LF_P2PNAME_Async_Sequenced_Call func(p2pName *byte, param DataHnd, data uintptr, onResult uintptr) int32

	// LF_P2PNAME_Notify sends a one-way notification by P2P group name.
	LF_P2PNAME_Notify func(p2pName *byte, param DataHnd)

	// LF_P2PNAME_Sequenced_Notify is the FIFO-ordered variant.
	LF_P2PNAME_Sequenced_Notify func(p2pName *byte, param DataHnd)

	// =======================================================================
	// Queries (7)
	// =======================================================================

	// LF_CheckMainThread reports whether the simulated main thread runs.
	LF_CheckMainThread func() int32

	// LF_CheckApp reports whether the named app is visible.
	LF_CheckApp func(appName *byte) int32

	// LF_CheckApi reports whether the named API is visible.
	LF_CheckApi func(appName, apiName *byte) int32

	// LF_Check_UID reports whether a client with the given UID is
	// currently registered on the mesh.
	//
	// Uses a locally cached view with ~3-second propagation delay.
	LF_Check_UID func(uid *TP2P_UID) int32

	// LF_Check_UID_Api reports whether a client with the given UID
	// exposes the named API.
	LF_Check_UID_Api func(uid *TP2P_UID, apiName *byte) int32

	// LF_Check_P2PNAME reports whether at least one client has the
	// given P2P group name.
	LF_Check_P2PNAME func(p2pName *byte) int32

	// LF_Check_P2PNAME_Api reports whether at least one client in the
	// given group exposes the named API.
	LF_Check_P2PNAME_Api func(p2pName, apiName *byte) int32

	// =======================================================================
	// Runtime options (2)
	// =======================================================================

	// LF_SetOption adjusts a global runtime option.
	LF_SetOption func(option, value *byte)

	// LF_GetOption reads a global runtime option.
	//
	// Returns a pointer to a transient buffer released about 5
	// seconds after the call. Unknown option names yield an empty
	// string.
	LF_GetOption func(option *byte) *byte

	// =======================================================================
	// Status and diagnostics (3)
	// =======================================================================

	// LF_GetStatusCount returns the pending log-message count.
	LF_GetStatusCount func() int32

	// LF_GetStatus retrieves the next log message (static buffer).
	LF_GetStatus func() *byte

	// LF_PostStatus injects a log message.
	LF_PostStatus func(status *byte)

	// =======================================================================
	// Network events (1)
	// =======================================================================

	// LF_Set_Network_Event installs/replaces network event callbacks.
	//
	// Both arguments are uintptr values returned by
	// purego.NewCallback; pass 0 to disable either event.
	LF_Set_Network_Event func(onConnect, onDisconnect uintptr)

	// =======================================================================
	// Shutdown (1)
	// =======================================================================

	// LF_Shutdown performs a full shutdown and resource release.
	LF_Shutdown func()
)
