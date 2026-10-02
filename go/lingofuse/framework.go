package lingofuse

import (
	"github.com/PassByYou888/LingoFuse/go/sys"
)

// ---------------------------------------------------------------------------
// Framework — the process-wide facade
// ---------------------------------------------------------------------------
//
// This file mirrors the C++ lingofuse::Framework free-function set
// and the Rust framework module. It exposes every process-wide
// operation that the native library provides but that does not fit
// the DataHandle or AppHandle abstractions:
//
//   - Network preparation (ResetPrepare, PrepareService,
//     PrepareClient, PrepareDone, ExitMainThread).
//   - Runtime options (SetOption).
//   - Application name generation and query (GenerateAppName,
//     GetAppName).
//   - Remote invocation (Call, TryCall, Notify, SequencedNotify).
//   - Process-wide shutdown (Shutdown).
//
// Every function forwards to exactly one native export. No caching,
// no state, no lifecycle coordination.

// ---------------------------------------------------------------------------
// Network preparation
// ---------------------------------------------------------------------------

// ResetPrepare clears the preparation queue.
//
// Running services and clients are not affected. Only the pending
// list of services and clients to be created by the next PrepareDone
// is cleared.
func ResetPrepare() error {
	if err := sys.LoadLibrary(); err != nil {
		return wrapErr(ErrLibraryLoadFailed, err,
			"ResetPrepare: native library not available")
	}
	sys.LF_ResetPrepare()
	return nil
}

// PrepareService prepares a C4 service.
//
// listeningAddr is the local binding address. May be a TCP address
// ("0.0.0.0:9898") or an IPC name ("ipc:my_service").
//
// physicsAddr is the address advertised to clients. Usually equal to
// listeningAddr.
//
// Returns the internal tag assigned to this service. The tag is
// non-negative on success.
func PrepareService(listeningAddr, physicsAddr string) (int, error) {
	if err := sys.LoadLibrary(); err != nil {
		return 0, wrapErr(ErrLibraryLoadFailed, err,
			"PrepareService: native library not available")
	}

	var scope sys.CStringScope
	l := scope.Add(listeningAddr)
	p := scope.Add(physicsAddr)
	tag := sys.LF_PrepareService(l, p)
	scope.Release()

	if tag < 0 {
		return 0, newErr(ErrGeneric,
			"PrepareService: native layer rejected %q (duplicate address?)",
			listeningAddr)
	}
	return int(tag), nil
}

// PrepareClient prepares a C4 client.
//
// physicsAddr is the address of the target service. app is the
// application to expose, or nil for a pure consumer.
//
// Without Overlap_Connection=True, the same physical address can host
// only one client per process. A second PrepareClient on the same
// address returns an error and silently discards the app. Set
// Overlap_Connection=True via SetOption before the call to allow
// multiple independent tunnels to the same address.
//
// Returns the internal tag assigned to this client.
func PrepareClient(physicsAddr string, app *AppHandle) (int, error) {
	if err := sys.LoadLibrary(); err != nil {
		return 0, wrapErr(ErrLibraryLoadFailed, err,
			"PrepareClient: native library not available")
	}

	var appHnd sys.AppHnd
	if app != nil {
		appHnd = app.Raw()
		if appHnd == 0 {
			return 0, newErr(ErrNullHandle,
				"PrepareClient: app is closed")
		}
	}

	var scope sys.CStringScope
	addr := scope.Add(physicsAddr)
	tag := sys.LF_PrepareClient(addr, appHnd)
	scope.Release()

	if tag < 0 {
		return 0, newErr(ErrGeneric,
			"PrepareClient: native layer rejected %q (duplicate address?)",
			physicsAddr)
	}
	return int(tag), nil
}

// PrepareDone starts the framework with the prepared services and
// clients.
//
// Returns:
//
//   - (true, nil)  on the first successful start.
//   - (false, nil) on a second call without an intervening Shutdown.
//     This is NOT a failure: the framework is already running.
//
// Blocking: by default (Wait_Connection_ReadyOk=True), this call
// blocks until every prepared client is online, or until
// Wait_Connection_Timeout milliseconds have elapsed. Configure both
// via SetOption before calling.
func PrepareDone() (bool, error) {
	if err := sys.LoadLibrary(); err != nil {
		return false, wrapErr(ErrLibraryLoadFailed, err,
			"PrepareDone: native library not available")
	}
	ret := sys.LF_PrepareDone()
	return ret == 1, nil
}

// ExitMainThread requests the simulated main thread to exit.
//
// Pitfall: this also flushes the data-handle pool, releasing every
// outstanding handle — including handles created by CreatePermanent.
// Do not use any DataHandle after this call returns.
//
// This does not release all resources; call Shutdown for a full
// cleanup.
func ExitMainThread() error {
	if err := sys.LoadLibrary(); err != nil {
		return wrapErr(ErrLibraryLoadFailed, err,
			"ExitMainThread: native library not available")
	}
	sys.LF_ExitMainThread()
	return nil
}

// ---------------------------------------------------------------------------
// Runtime options
// ---------------------------------------------------------------------------

// SetOption adjusts a global runtime option.
//
// Unknown option names are silently ignored by the native layer (no
// error, no warning). Double-check the name.
//
// Common options:
//
//	Overlap_Connection       bool   false  allow multiple clients per address
//	Wait_Connection_ReadyOk  bool   true   PrepareDone waits for clients
//	Wait_Connection_Timeout  int    30000  wait timeout, milliseconds
//	Quiet                    bool   false  suppress internal log output
//	ShowThreadID             bool   false  include thread IDs in logs
//	ConsoleOutput            bool   auto   console logging on/off
//	Fixed_Sequenced_Time     int    20000  sequenced-notify fallback (ms)
//
// Boolean values: "True"/"False"/"1"/"0"/"Yes"/"No" (case-insensitive).
// Use "True"/"False" by preference.
func SetOption(option, value string) error {
	if err := sys.LoadLibrary(); err != nil {
		return wrapErr(ErrLibraryLoadFailed, err,
			"SetOption: native library not available")
	}
	var scope sys.CStringScope
	opt := scope.Add(option)
	val := scope.Add(value)
	sys.LF_SetOption(opt, val)
	scope.Release()
	return nil
}

// ---------------------------------------------------------------------------
// Application name generation and query
// ---------------------------------------------------------------------------

// GenerateAppName generates a globally unique application name.
//
// Precondition: must be called after PrepareDone returned (true,
// nil). Before that, the generated name lacks the C4 tunnel
// information and may not be unique on the mesh.
//
// The native function returns a pointer valid for approximately 5
// seconds; this function copies the string immediately, so the
// returned value is safe to hold indefinitely.
func GenerateAppName() (string, error) {
	if err := sys.LoadLibrary(); err != nil {
		return "", wrapErr(ErrLibraryLoadFailed, err,
			"GenerateAppName: native library not available")
	}
	return sys.GoString(sys.LF_Generate_AppName()), nil
}

// GetAppName returns the name of an existing application handle.
//
// Same 5-second pointer-validity rule as GenerateAppName; this
// function copies the string immediately.
func GetAppName(app *AppHandle) (string, error) {
	if app == nil {
		return "", newErr(ErrInvalidArgument,
			"GetAppName: app must not be nil")
	}
	if err := sys.LoadLibrary(); err != nil {
		return "", wrapErr(ErrLibraryLoadFailed, err,
			"GetAppName: native library not available")
	}
	h := app.Raw()
	if h == 0 {
		return "", newErr(ErrNullHandle,
			"GetAppName: app is closed")
	}
	return sys.GoString(sys.LF_Get_AppName(h)), nil
}

// ---------------------------------------------------------------------------
// Remote invocation
// ---------------------------------------------------------------------------

// Call performs a synchronous remote call.
//
// Returns a new DataHandle owning the response. The handle is never
// nil on success. On timeout or unreachable target, the native layer
// returns a handle with Size == 0. Callers that need to distinguish
// "timeout" from "empty response" should check the returned handle's
// Size, or use TryCall for a clean boolean API.
//
// The param handle is NOT consumed; the caller retains ownership.
//
// Deadlock warning: do not call this function from inside a
// registered callback. See AppHandle.
func Call(appName string, param *DataHandle, timeoutMs uint64) (*DataHandle, error) {
	if param == nil {
		return nil, newErr(ErrInvalidArgument,
			"Call: param must not be nil")
	}
	if err := sys.LoadLibrary(); err != nil {
		return nil, wrapErr(ErrLibraryLoadFailed, err,
			"Call: native library not available")
	}

	ph := param.Raw()
	if ph == 0 {
		return nil, newErr(ErrNullHandle,
			"Call: param is closed")
	}

	var scope sys.CStringScope
	name := scope.Add(appName)
	res := sys.LF_Call(name, ph, timeoutMs)
	scope.Release()

	if res == 0 {
		return nil, newErr(ErrCallFailed,
			"Call: native layer returned a null handle")
	}
	return fromRaw(res, true), nil
}

// TryCall is the idiomatic Go wrapper around Call.
//
// Returns:
//
//   - (handle, true,  nil)  on a non-empty response.
//   - (nil,    false, nil)  on timeout or unreachable target.
//   - (nil,    false, err)  on a null handle or a load failure.
//
// Ownership: when the function returns a non-nil handle, the caller
// is responsible for calling Close on it. When it returns nil, the
// underlying empty handle has already been released by this function.
func TryCall(appName string, param *DataHandle, timeoutMs uint64) (*DataHandle, bool, error) {
	res, err := Call(appName, param, timeoutMs)
	if err != nil {
		return nil, false, err
	}
	sz, err := res.Size()
	if err != nil {
		res.Close()
		return nil, false, err
	}
	if sz == 0 {
		res.Close()
		return nil, false, nil
	}
	return res, true, nil
}

// Notify sends a one-way notification.
//
// Delivery order is NOT guaranteed. Use SequencedNotify when FIFO
// ordering is required for a given (app_name, api_name) pair.
//
// The param handle is NOT consumed; the caller retains ownership.
func Notify(appName string, param *DataHandle) error {
	if param == nil {
		return newErr(ErrInvalidArgument,
			"Notify: param must not be nil")
	}
	if err := sys.LoadLibrary(); err != nil {
		return wrapErr(ErrLibraryLoadFailed, err,
			"Notify: native library not available")
	}

	ph := param.Raw()
	if ph == 0 {
		return newErr(ErrNullHandle,
			"Notify: param is closed")
	}

	var scope sys.CStringScope
	name := scope.Add(appName)
	sys.LF_Notify(name, ph)
	scope.Release()
	return nil
}

// SequencedNotify sends a one-way notification with FIFO ordering
// guaranteed for the same (app_name, api_name) pair.
//
// Different pairs are independent and unordered with respect to each
// other.
//
// The param handle is NOT consumed; the caller retains ownership.
func SequencedNotify(appName string, param *DataHandle) error {
	if param == nil {
		return newErr(ErrInvalidArgument,
			"SequencedNotify: param must not be nil")
	}
	if err := sys.LoadLibrary(); err != nil {
		return wrapErr(ErrLibraryLoadFailed, err,
			"SequencedNotify: native library not available")
	}

	ph := param.Raw()
	if ph == 0 {
		return newErr(ErrNullHandle,
			"SequencedNotify: param is closed")
	}

	var scope sys.CStringScope
	name := scope.Add(appName)
	sys.LF_Sequenced_Notify(name, ph)
	scope.Release()
	return nil
}

// ---------------------------------------------------------------------------
// Shutdown
// ---------------------------------------------------------------------------

// Shutdown gracefully terminates the framework, releasing all
// resources.
//
// Steps performed by the native layer:
//
//  1. Clears the network-event callbacks.
//  2. Stops all sequenced-notification threads.
//  3. Frees all remaining data handles — including any permanent
//     handle still alive.
//  4. Exits the simulated main thread.
//  5. Clears the global application pool.
//  6. Unloads the IPC library.
//
// After Shutdown, every AppHandle still alive becomes invalid. The
// framework may be re-initialised by calling the preparation
// functions again. Safe to call multiple times.
func Shutdown() error {
	if err := sys.LoadLibrary(); err != nil {
		return wrapErr(ErrLibraryLoadFailed, err,
			"Shutdown: native library not available")
	}
	sys.LF_Shutdown()
	return nil
}
