// Package sys is the low-level FFI layer for the LingoFuse native
// library. It is the ONLY place in the Go binding where native code
// is invoked.
//
// This file mirrors the C++ header LingoFuse.h and the Rust module
// bindings.rs one-to-one. Every exported C function has exactly one
// corresponding package-level function variable, resolved at load
// time by loader.go.
package sys

// ---------------------------------------------------------------------------
// Opaque handle types
// ---------------------------------------------------------------------------

// DataHnd is an opaque handle to a LingoFuse data buffer (TDataHnd).
//
// Two kinds exist:
//   - Auto-recycled (created by LF_CreateData): added to the idle pool,
//     which scans every 5 seconds and frees handles idle for more than
//     10 minutes.
//   - Permanent (created by LF_CreateData_Permanent): not added to the
//     pool, never auto-reclaimed.
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

// LfCallFunc is the Go representation of the C callback
//   void (*)(void* trigger, TDataHnd input, TDataHnd output)
//
// In Go, a void return is represented as returning uintptr(0).
type LfCallFunc func(trigger uintptr, input DataHnd, output DataHnd) uintptr

// LfNotifyFunc is the Go representation of
//   void (*)(void* trigger, TDataHnd input)
type LfNotifyFunc func(trigger uintptr, input DataHnd) uintptr

// LfNetworkEventFunc is the Go representation of
//   void (*)(const char* addr)
type LfNetworkEventFunc func(addr *byte) uintptr

// ---------------------------------------------------------------------------
// Function pointer table
// ---------------------------------------------------------------------------
//
// Each variable is populated once by loader.go and is nil before that.
// Calling any of these before LoadLibrary succeeds is a nil-pointer
// panic — mirroring the "must call LF_LoadLibrary first" rule of the
// C++ binding.

var (
	// --- Data handle operations (10) ---

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

	// --- Application handle operations (5) ---

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

	// --- API registration (3) ---

	// LF_RegisterCall registers a Call (request-response) API.
	//
	// onCall is a uintptr returned by purego.NewCallback; use
	// callbacks.go to obtain one.
	LF_RegisterCall func(appHnd AppHnd, methodName, desc *byte, trigger uintptr, onCall uintptr) int32

	// LF_RegisterNotify registers a Notify (one-way) API.
	LF_RegisterNotify func(appHnd AppHnd, methodName, desc *byte, trigger uintptr, onNotify uintptr) int32

	// LF_Unregister removes a registered API.
	LF_Unregister func(appHnd AppHnd, methodName *byte) int32

	// --- Local execution (2) ---

	// LF_LocalCall invokes a Call API in-process.
	LF_LocalCall func(appHnd AppHnd, param DataHnd) DataHnd

	// LF_LocalNotify invokes a Notify API in-process.
	LF_LocalNotify func(appHnd AppHnd, param DataHnd)

	// --- Network preparation (5) ---

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

	// --- Remote invocation (3) ---

	// LF_Call performs a synchronous remote call.
	LF_Call func(appName *byte, param DataHnd, timeoutMs uint64) DataHnd

	// LF_Notify sends a one-way notification.
	LF_Notify func(appName *byte, param DataHnd)

	// LF_Sequenced_Notify sends a FIFO-ordered one-way notification.
	LF_Sequenced_Notify func(appName *byte, param DataHnd)

	// --- Options and diagnostics (7) ---

	// LF_SetOption adjusts a global runtime option.
	LF_SetOption func(option, value *byte)

	// LF_GetStatusCount returns the pending log-message count.
	LF_GetStatusCount func() int32

	// LF_GetStatus retrieves the next log message (static buffer).
	LF_GetStatus func() *byte

	// LF_PostStatus injects a log message.
	LF_PostStatus func(status *byte)

	// LF_CheckMainThread reports whether the simulated main thread runs.
	LF_CheckMainThread func() int32

	// LF_CheckApp reports whether the named app is visible.
	LF_CheckApp func(appName *byte) int32

	// LF_CheckApi reports whether the named API is visible.
	LF_CheckApi func(appName, apiName *byte) int32

	// --- Shutdown (1) ---

	// LF_Shutdown performs a full shutdown and resource release.
	LF_Shutdown func()

	// --- Network events (1) ---

	// LF_Set_Network_Event installs/replaces network event callbacks.
	//
	// Both arguments are uintptr values returned by
	// purego.NewCallback; pass 0 to disable either event.
	LF_Set_Network_Event func(onConnect, onDisconnect uintptr)
)