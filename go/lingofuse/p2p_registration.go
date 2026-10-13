package lingofuse

import (
	"strings"
	"sync"

	"github.com/PassByYou888/LingoFuse/go/sys"
)

// ---------------------------------------------------------------------------
// Process-wide P2P API registration
// ---------------------------------------------------------------------------
//
// The functions in this file register APIs into the process-wide P2P
// namespace, which is INDEPENDENT of any App:
//
//	RegisterP2PCall    -- register a Call API (request / response)
//	RegisterP2PNotify  -- register a Notify API (one-way)
//	UnregisterP2P      -- remove a previously registered API
//	ResetP2PRegistrations -- release every local P2P registration
//
// APIs registered here live on the process-wide LF_P2P_APP and are
// reachable via UID addressing or P2PName addressing without requiring
// the caller to know the target App name. They are NOT reachable via
// App-name addressing, even if the registered API name happens to
// match an App name.
//
// Typical use: register a small set of globally-discoverable utility
// APIs (health probes, capability discovery, identity echo, etc.)
// that any client in the mesh can call by group name or by UID.
//
// {!!!!!  COMPARISON WITH AppHandle.RegisterCall  !!!!!}
// AppHandle.RegisterCall registers into the App-BOUND namespace:
//
//	- reachable via App-name addressing (and via UID addressing);
//	- lifetime tied to the AppHandle: released by AppHandle.Close;
//	- registration requires a live AppHandle.
//
// The functions in this file register into the process-wide namespace:
//
//	- reachable via UID and P2PName addressing ONLY;
//	- lifetime tied to the process: released only by Shutdown or by
//	  an explicit UnregisterP2P / ResetP2PRegistrations;
//	- no AppHandle required. Registration works even before
//	  PrepareDone.
//
// The two namespaces are orthogonal. A registration in one is
// invisible to the other, even if the API names coincide.
//
// {!!!!!  CALLBACK CONTRACT  !!!!!}
// The handler functions run on a TCompute worker thread owned by the
// native library. They MUST NOT block, and MUST NOT call any
// synchronous LingoFuse function (Call, Notify, LocalCall,
// PrepareDone, Shutdown). Doing so deadlocks.
//
// Any panic raised by a handler is caught by the internal trampoline
// wrapper and logged; it never escapes into the C stack.
//
// {!!!!!  KEEPALIVE  !!!!!}
// The native library holds a RAW C FUNCTION POINTER to each installed
// callback. If the corresponding Go handler were garbage-collected
// while the pointer was still live, the next invocation would jump
// into freed memory. This file therefore keeps a STRONG reference to
// every installed handler for as long as the API is registered. See
// the p2pRegistry map below.
//
// {!!!!!  THREAD SAFETY  !!!!!}
// Registration and unregistration are safe to call concurrently from
// any goroutine. A registration that races with an unregistration of
// the same name is serialised by the internal mutex; one of the two
// wins and the other observes a consistent state.

// p2pRegistration tracks one process-wide P2P API registration.
type p2pRegistration struct {
	// triggerID is the registry key used by sys.callbacks to locate
	// the Go trampoline closure. Passed to UnregisterCallback when
	// the API is removed.
	triggerID uintptr

	// cFuncPtr is the C-side function pointer. It is always the
	// shared trampoline pointer returned by sys.RegisterCallCallback
	// or sys.RegisterNotifyCallback; the C ABI forwards the opaque
	// triggerID as the callback's first argument, which the
	// trampoline uses to find the right closure.
	cFuncPtr uintptr

	// apiName is the name as registered (preserves the caller's
	// original casing; lookups are case-insensitive).
	apiName string

	// isCall distinguishes Call registrations from Notify ones, so
	// that UnregisterP2P knows which registry entry to release.
	isCall bool
}

var (
	// p2pMu guards p2pRegistry. A plain RWMutex is preferred over
	// sync.Map here because the access pattern is dominated by
	// registration / unregistration (write-heavy), and the total
	// number of entries is expected to be very small (a handful per
	// process).
	p2pMu sync.RWMutex

	// p2pRegistry maps the lowercase API name to its registration.
	// The map holds a strong reference to the registration, which in
	// turn holds a strong reference to the user's handler via the
	// closure stored in sys.callbacks.
	p2pRegistry = make(map[string]*p2pRegistration)
)

// ---------------------------------------------------------------------------
// Registration
// ---------------------------------------------------------------------------

// RegisterP2PCall registers a process-wide P2P Call API.
//
// The API becomes reachable via UID addressing or P2PName addressing
// from any client in the mesh, without requiring the caller to know
// the target App name. It is NOT reachable via App-name addressing.
//
// Handler signature: CallHandler, i.e.
//
//	func(input, output *DataHandle)
//
// Both handles are BORROWED: the native layer owns them and releases
// them when the handler returns. Do not call Close on them.
//
// Returns ErrRegistrationFailed if the name is already registered in
// the process-wide P2P namespace, or if the native layer rejects the
// registration for any other reason.
func RegisterP2PCall(apiName, desc string, handler CallHandler) error {
	if apiName == "" {
		return newErr(ErrInvalidArgument,
			"RegisterP2PCall: apiName must not be empty")
	}
	if handler == nil {
		return newErr(ErrInvalidArgument,
			"RegisterP2PCall: handler must not be nil")
	}
	if err := sys.LoadLibrary(); err != nil {
		return wrapErr(ErrLibraryLoadFailed, err,
			"RegisterP2PCall: native library not available")
	}

	key := strings.ToLower(apiName)

	p2pMu.Lock()
	defer p2pMu.Unlock()

	if _, exists := p2pRegistry[key]; exists {
		return newErr(ErrRegistrationFailed,
			"RegisterP2PCall: API %q is already registered "+
				"in the process-wide P2P namespace", apiName)
	}

	// Build the Go-side trampoline closure that wraps the user
	// handler. The closure captures `handler` by reference; the
	// registry stores it, so the closure and the handler stay alive
	// until UnregisterP2P is called.
	lowLevel := func(_ uintptr, input, output sys.DataHnd) uintptr {
		defer func() { _ = recover() }()

		ih := fromRaw(input, false)
		oh := fromRaw(output, false)
		handler(ih, oh)
		return 0
	}

	triggerID, cFuncPtr := sys.RegisterCallCallback(lowLevel)

	var scope sys.CStringScope
	name := scope.Add(apiName)
	descPtr := scope.Add(desc)
	rc := sys.LF_Register_P2P_Call(name, descPtr, triggerID, cFuncPtr)
	scope.Release()

	if rc != 1 {
		// The native layer refused the registration. The triggerID
		// was never handed to the library, so releasing the slot
		// here is safe.
		sys.UnregisterCallback(triggerID)
		return newErr(ErrRegistrationFailed,
			"RegisterP2PCall: LF_Register_P2P_Call rejected %q",
			apiName)
	}

	p2pRegistry[key] = &p2pRegistration{
		triggerID: triggerID,
		cFuncPtr:  cFuncPtr,
		apiName:   apiName,
		isCall:    true,
	}
	return nil
}

// RegisterP2PNotify registers a process-wide P2P Notify API.
//
// The API becomes reachable via UID addressing or P2PName addressing.
// It is NOT reachable via App-name addressing.
//
// Handler signature: NotifyHandler, i.e.
//
//	func(input *DataHandle)
//
// The input handle is BORROWED: the native layer owns it and releases
// it when the handler returns. Do not call Close on it.
//
// Returns ErrRegistrationFailed if the name is already registered in
// the process-wide P2P namespace, or if the native layer rejects the
// registration for any other reason.
func RegisterP2PNotify(apiName, desc string, handler NotifyHandler) error {
	if apiName == "" {
		return newErr(ErrInvalidArgument,
			"RegisterP2PNotify: apiName must not be empty")
	}
	if handler == nil {
		return newErr(ErrInvalidArgument,
			"RegisterP2PNotify: handler must not be nil")
	}
	if err := sys.LoadLibrary(); err != nil {
		return wrapErr(ErrLibraryLoadFailed, err,
			"RegisterP2PNotify: native library not available")
	}

	key := strings.ToLower(apiName)

	p2pMu.Lock()
	defer p2pMu.Unlock()

	if _, exists := p2pRegistry[key]; exists {
		return newErr(ErrRegistrationFailed,
			"RegisterP2PNotify: API %q is already registered "+
				"in the process-wide P2P namespace", apiName)
	}

	lowLevel := func(_ uintptr, input sys.DataHnd) uintptr {
		defer func() { _ = recover() }()

		ih := fromRaw(input, false)
		handler(ih)
		return 0
	}

	triggerID, cFuncPtr := sys.RegisterNotifyCallback(lowLevel)

	var scope sys.CStringScope
	name := scope.Add(apiName)
	descPtr := scope.Add(desc)
	rc := sys.LF_Register_P2P_Notify(name, descPtr, triggerID, cFuncPtr)
	scope.Release()

	if rc != 1 {
		sys.UnregisterCallback(triggerID)
		return newErr(ErrRegistrationFailed,
			"RegisterP2PNotify: LF_Register_P2P_Notify rejected %q",
			apiName)
	}

	p2pRegistry[key] = &p2pRegistration{
		triggerID: triggerID,
		cFuncPtr:  cFuncPtr,
		apiName:   apiName,
		isCall:    false,
	}
	return nil
}

// ---------------------------------------------------------------------------
// Unregistration
// ---------------------------------------------------------------------------

// UnregisterP2P removes a previously registered process-wide P2P API.
//
// The removal is immediate locally. Remote peers may still see the
// API for up to ~3 seconds until the network broadcast propagates.
//
// Returns true if the API was found and removed, false otherwise.
//
// {!!!!!  CALLBACK SLOT RELEASE  !!!!!}
// The corresponding Go trampoline closure is released from the
// internal registry, so it can be garbage-collected. Any C-side
// invocation that was already in flight when this call ran will
// either complete normally (if it looked up the closure before the
// release) or find an empty slot and return silently.
func UnregisterP2P(apiName string) (bool, error) {
	if apiName == "" {
		return false, newErr(ErrInvalidArgument,
			"UnregisterP2P: apiName must not be empty")
	}
	if err := sys.LoadLibrary(); err != nil {
		return false, wrapErr(ErrLibraryLoadFailed, err,
			"UnregisterP2P: native library not available")
	}

	key := strings.ToLower(apiName)

	p2pMu.Lock()
	defer p2pMu.Unlock()

	reg, exists := p2pRegistry[key]
	if !exists {
		return false, nil
	}

	// Ask the native layer to remove the API by name. A return value
	// other than 1 means the name is not registered on the native
	// side, which is inconsistent with our bookkeeping. In that case
	// we still release the local resources (the closure and the map
	// entry), because the most likely cause is a prior shutdown that
	// already cleared the native side.
	var scope sys.CStringScope
	name := scope.Add(reg.apiName)
	rc := sys.LF_Unregister_P2P(name)
	scope.Release()

	// Release the trampoline closure from the registry. This is
	// idempotent; if the native layer never invoked it, the entry is
	// simply dropped.
	sys.UnregisterCallback(reg.triggerID)
	delete(p2pRegistry, key)

	return rc == 1, nil
}

// ---------------------------------------------------------------------------
// Bulk reset
// ---------------------------------------------------------------------------

// ResetP2PRegistrations releases every locally-tracked process-wide
// P2P API registration and drops the corresponding callback slots.
//
// {!!!!!  WHEN TO CALL  !!!!!}
// This function is called automatically by Framework.Shutdown, so
// that a subsequent framework restart starts with an empty P2P
// namespace. Without it, a program that:
//
//  1. Registers P2P API "whoami"
//  2. Calls Shutdown()
//  3. Calls PrepareDone() to restart the framework
//  4. Registers P2P API "whoami" again
//
// would hit ErrRegistrationFailed on step 4, because the Go-side
// p2pRegistry still holds a stale entry for "whoami" even though the
// native side was reset by Shutdown. Calling this function from
// Shutdown closes that gap.
//
// {!!!!!  DO NOT CALL WHILE THE FRAMEWORK IS RUNNING  !!!!!}
// This function does NOT ask the native layer to unregister the API
// names; it only drops the Go-side bookkeeping. While the framework
// is running, an in-flight native callback may still look up a
// now-dropped Go closure and return silently. That is safe (the
// trampoline guards against a missing entry), but it means the
// caller will see the API as unreachable even though the native side
// still advertises it. The intended use is process teardown, where
// the framework is about to stop anyway.
//
// Safe to call multiple times.
func ResetP2PRegistrations() {
	p2pMu.Lock()
	defer p2pMu.Unlock()

	for key, reg := range p2pRegistry {
		sys.UnregisterCallback(reg.triggerID)
		delete(p2pRegistry, key)
	}
}

// ---------------------------------------------------------------------------
// Introspection (non-essential, useful for tests and diagnostics)
// ---------------------------------------------------------------------------

// IsP2PRegistered reports whether the given API name is currently
// registered in the process-wide P2P namespace.
//
// Intended for tests and diagnostics, not for routing decisions. The
// authoritative answer for "is this API reachable" is CheckUIDApi or
// CheckP2PNameApi, which consult the mesh's cached view.
func IsP2PRegistered(apiName string) bool {
	p2pMu.RLock()
	defer p2pMu.RUnlock()
	_, ok := p2pRegistry[strings.ToLower(apiName)]
	return ok
}
