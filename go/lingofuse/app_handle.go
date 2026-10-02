package lingofuse

import (
	"strings"
	"sync"

	"github.com/PassByYou888/LingoFuse/go/sys"
)

// CallHandler is the Go signature for a Call (request-response) API.
//
// The input handle is read-only; the output handle is write-only.
// The handles are borrowed: the native layer owns them and releases
// them as soon as the handler returns. Do not call Close on them.
//
// The handler runs on a background worker thread owned by the native
// library. It must not block and must not call any blocking
// LingoFuse function (Call, LocalCall, PrepareDone, Shutdown); doing
// so deadlocks.
type CallHandler func(input, output *DataHandle)

// NotifyHandler is the Go signature for a Notify (one-way) API.
// Same threading and lifetime contract as CallHandler.
type NotifyHandler func(input *DataHandle)

// registration records the state required to unregister a single API
// and to release its callback slot.
type registration struct {
	trigger  uintptr
	cFuncPtr uintptr
	apiName  string
	isCall   bool
}

// AppHandle is a RAII wrapper around a native LingoFuse application
// handle (sys.AppHnd).
//
// LF_FreeApp performs only the first stage of a two-stage
// destruction: the object is detached from all clients and its
// sequenced-notification threads are stopped, but the underlying
// TLF_App remains alive in the global pool until Shutdown. After
// Close, the handle is invalid and must not be reused.
//
// An AppHandle is not safe for concurrent use by multiple
// goroutines. Every public method takes the internal mutex, so
// individual calls are safe, but the caller must not rely on
// cross-method atomicity.
type AppHandle struct {
	mu         sync.Mutex
	handle     sys.AppHnd
	name       string
	closed     bool
	registered map[string]registration
}

// ---------------------------------------------------------------------------
// Construction
// ---------------------------------------------------------------------------

// NewAppHandle creates a new application with the given name and
// description.
//
// The name should be unique on the mesh; case-insensitive matching
// applies at lookup time. An empty description is allowed.
func NewAppHandle(name, description string) (*AppHandle, error) {
	if err := sys.LoadLibrary(); err != nil {
		return nil, wrapErr(ErrLibraryLoadFailed, err,
			"NewAppHandle: native library not available")
	}

	var scope sys.CStringScope
	cName := scope.Add(name)
	cDesc := scope.Add(description)
	raw := sys.LF_CreateApp(cName, cDesc)
	scope.Release()

	if raw == 0 {
		return nil, newErr(ErrGeneric,
			"NewAppHandle: LF_CreateApp returned a null handle for %q",
			name)
	}

	return &AppHandle{
		handle:     raw,
		name:       name,
		registered: make(map[string]registration),
	}, nil
}

// ---------------------------------------------------------------------------
// Identity and state
// ---------------------------------------------------------------------------

// Name returns the application name passed to NewAppHandle.
func (a *AppHandle) Name() string { return a.name }

// Raw returns the raw native handle, or 0 after Close.
func (a *AppHandle) Raw() sys.AppHnd {
	a.mu.Lock()
	defer a.mu.Unlock()
	return a.handle
}

// IsValid reports whether the handle is valid and not yet closed.
func (a *AppHandle) IsValid() bool {
	a.mu.Lock()
	defer a.mu.Unlock()
	return !a.closed && a.handle != 0
}

// ---------------------------------------------------------------------------
// API registration
// ---------------------------------------------------------------------------

// RegisterCall registers a Call (request-response) API.
//
// The handler runs on a native worker thread. See CallHandler for
// the callback contract.
func (a *AppHandle) RegisterCall(
	apiName, description string,
	handler CallHandler,
) error {
	if handler == nil {
		return newErr(ErrInvalidArgument,
			"AppHandle.RegisterCall: handler must not be nil")
	}

	a.mu.Lock()
	defer a.mu.Unlock()

	if a.closed || a.handle == 0 {
		return newErr(ErrNullHandle,
			"AppHandle.RegisterCall: app is closed")
	}

	key := strings.ToLower(apiName)
	if _, exists := a.registered[key]; exists {
		return newErr(ErrRegistrationFailed,
			"AppHandle.RegisterCall: API %q is already registered locally",
			apiName)
	}

	lowLevel := func(_ uintptr, input, output sys.DataHnd) uintptr {
		// Recover must be registered before the handler is invoked
		// so that a panic from the handler is caught.
		defer func() { _ = recover() }()

		ih := fromRaw(input, false)
		oh := fromRaw(output, false)
		handler(ih, oh)
		return 0
	}

	trigger, cPtr := sys.RegisterCallCallback(lowLevel)

	var scope sys.CStringScope
	cName := scope.Add(apiName)
	cDesc := scope.Add(description)
	rc := sys.LF_RegisterCall(a.handle, cName, cDesc, trigger, cPtr)
	scope.Release()

	if rc != 1 {
		// The native layer refused the registration. The trigger
		// was never handed to the library, so releasing the slot
		// here is safe.
		sys.UnregisterCallback(trigger)
		return newErr(ErrRegistrationFailed,
			"AppHandle.RegisterCall: LF_RegisterCall rejected %q",
			apiName)
	}

	a.registered[key] = registration{
		trigger:  trigger,
		cFuncPtr: cPtr,
		apiName:  apiName,
		isCall:   true,
	}
	return nil
}

// RegisterNotify registers a Notify (one-way) API.
//
// Same contract as RegisterCall, minus the output handle.
func (a *AppHandle) RegisterNotify(
	apiName, description string,
	handler NotifyHandler,
) error {
	if handler == nil {
		return newErr(ErrInvalidArgument,
			"AppHandle.RegisterNotify: handler must not be nil")
	}

	a.mu.Lock()
	defer a.mu.Unlock()

	if a.closed || a.handle == 0 {
		return newErr(ErrNullHandle,
			"AppHandle.RegisterNotify: app is closed")
	}

	key := strings.ToLower(apiName)
	if _, exists := a.registered[key]; exists {
		return newErr(ErrRegistrationFailed,
			"AppHandle.RegisterNotify: API %q is already registered locally",
			apiName)
	}

	lowLevel := func(_ uintptr, input sys.DataHnd) uintptr {
		defer func() { _ = recover() }()
		ih := fromRaw(input, false)
		handler(ih)
		return 0
	}

	trigger, cPtr := sys.RegisterNotifyCallback(lowLevel)

	var scope sys.CStringScope
	cName := scope.Add(apiName)
	cDesc := scope.Add(description)
	rc := sys.LF_RegisterNotify(a.handle, cName, cDesc, trigger, cPtr)
	scope.Release()

	if rc != 1 {
		sys.UnregisterCallback(trigger)
		return newErr(ErrRegistrationFailed,
			"AppHandle.RegisterNotify: LF_RegisterNotify rejected %q",
			apiName)
	}

	a.registered[key] = registration{
		trigger:  trigger,
		cFuncPtr: cPtr,
		apiName:  apiName,
		isCall:   false,
	}
	return nil
}

// Unregister removes a previously registered API.
//
// Returns true when the API was found and removed locally, false
// when it was not registered. The local effect is immediate; a
// network broadcast propagates the removal to remote peers within
// approximately 3 seconds.
func (a *AppHandle) Unregister(apiName string) (bool, error) {
	a.mu.Lock()
	defer a.mu.Unlock()

	if a.closed || a.handle == 0 {
		return false, newErr(ErrNullHandle,
			"AppHandle.Unregister: app is closed")
	}

	var scope sys.CStringScope
	cName := scope.Add(apiName)
	rc := sys.LF_Unregister(a.handle, cName)
	scope.Release()

	if rc != 1 {
		return false, nil
	}

	key := strings.ToLower(apiName)
	if reg, ok := a.registered[key]; ok {
		sys.UnregisterCallback(reg.trigger)
		delete(a.registered, key)
	}
	return true, nil
}

// ---------------------------------------------------------------------------
// Local execution
// ---------------------------------------------------------------------------

// LocalCall invokes a Call API locally within the same process.
//
// The param handle is NOT consumed by this call; the caller retains
// ownership. The returned DataHandle owns the response and must be
// closed by the caller.
//
// When the target API is not registered locally, the returned handle
// has Size == 0. Callers that need to distinguish "empty response"
// from "missing API" should check the returned handle's Size.
func (a *AppHandle) LocalCall(param *DataHandle) (*DataHandle, error) {
	if param == nil {
		return nil, newErr(ErrInvalidArgument,
			"AppHandle.LocalCall: param must not be nil")
	}

	// Snapshot the raw pointer under param's lock, then release it
	// before acquiring a.mu. This avoids holding two locks at once
	// and eliminates a lock-order hazard with future extensions.
	ph := param.Raw()

	a.mu.Lock()
	defer a.mu.Unlock()

	if a.closed || a.handle == 0 {
		return nil, newErr(ErrNullHandle,
			"AppHandle.LocalCall: app is closed")
	}
	if ph == 0 {
		return nil, newErr(ErrNullHandle,
			"AppHandle.LocalCall: param is closed")
	}

	res := sys.LF_LocalCall(a.handle, ph)
	if res == 0 {
		return nil, newErr(ErrCallFailed,
			"AppHandle.LocalCall: native layer returned a null handle")
	}
	return fromRaw(res, true), nil
}

// LocalNotify invokes a Notify API locally within the same process.
//
// The param handle is NOT consumed by this call.
func (a *AppHandle) LocalNotify(param *DataHandle) error {
	if param == nil {
		return newErr(ErrInvalidArgument,
			"AppHandle.LocalNotify: param must not be nil")
	}

	ph := param.Raw()

	a.mu.Lock()
	defer a.mu.Unlock()

	if a.closed || a.handle == 0 {
		return newErr(ErrNullHandle,
			"AppHandle.LocalNotify: app is closed")
	}
	if ph == 0 {
		return newErr(ErrNullHandle,
			"AppHandle.LocalNotify: param is closed")
	}

	sys.LF_LocalNotify(a.handle, ph)
	return nil
}

// ---------------------------------------------------------------------------
// Client binding
// ---------------------------------------------------------------------------

// Bind attaches the application to all currently unbound clients.
//
// Must be called after the framework has started (after
// PrepareDone returned true).
//
// Returns the number of clients bound. Zero means either the main
// thread is not active, or all clients already host an application.
func (a *AppHandle) Bind() (int, error) {
	a.mu.Lock()
	defer a.mu.Unlock()

	if a.closed || a.handle == 0 {
		return 0, newErr(ErrNullHandle,
			"AppHandle.Bind: app is closed")
	}
	return int(sys.LF_BindApp(a.handle)), nil
}

// ---------------------------------------------------------------------------
// Lifetime
// ---------------------------------------------------------------------------

// Close performs the first stage of the two-stage native destruction.
// Idempotent.
//
// The application is detached from all clients and its sequenced
// threads are stopped. The underlying native object remains in the
// global pool until Framework.Shutdown is called.
//
// Callback slots for every locally-registered API are released
// before the native handle is freed, so an in-flight callback that
// observes an empty registry returns safely.
func (a *AppHandle) Close() {
	if a == nil {
		return
	}

	a.mu.Lock()
	defer a.mu.Unlock()

	if a.closed {
		return
	}
	a.closed = true

	// Release callback slots first. This guarantees that a native
	// callback which fires between now and LF_FreeApp observes an
	// empty registry and returns without touching user code.
	for _, reg := range a.registered {
		sys.UnregisterCallback(reg.trigger)
	}
	a.registered = nil

	h := a.handle
	a.handle = 0
	if h != 0 {
		sys.LF_FreeApp(h)
	}
}
