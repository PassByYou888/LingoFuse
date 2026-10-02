package lingofuse

import (
	"sync"

	"github.com/PassByYou888/LingoFuse/go/sys"
)

// ---------------------------------------------------------------------------
// Network events
// ---------------------------------------------------------------------------
//
// LF_Set_Network_Event installs a pair of process-wide callbacks
// that fire when a LingoFuse client becomes online or goes offline.
//
// Semantics:
//
//	Connect    fires the FIRST time a client receives a service
//	           API-info broadcast. NOT the TCP handshake; the
//	           earliest point at which remote calls can be routed.
//	           Fires once per connection lifecycle, and again after
//	           an auto-reconnect.
//
//	Disconnect fires once per physical link loss. An automatic
//	           reconnect does NOT emit a Disconnect for the reconnect
//	           attempt itself; it emits a new Connect once the client
//	           is back online.
//
// Threading:
//
//	Callbacks run on a background worker thread owned by the native
//	library. They must not call any blocking LingoFuse function
//	(Call, LocalCall, PrepareDone, Shutdown); doing so deadlocks.
//
//	The addr argument is a UTF-8 endpoint string valid ONLY during
//	the callback invocation. This wrapper copies it into a Go string
//	before invoking the user handler.
//
// Global scope:
//
//	LF_Set_Network_Event is a process-wide slot. There is no
//	per-client registration. Installing new handlers replaces the
//	previous ones entirely; passing nil for a handler disables that
//	event.

// NetworkHandler is the Go signature for a network event handler.
// The addr parameter is a UTF-8 endpoint string.
type NetworkHandler func(addr string)

var (
	netEventMu        sync.Mutex
	netEventInstalled bool
	netEventOnConnect NetworkHandler
	netEventOnDisc    NetworkHandler
)

// SetNetworkEvent installs the process-global connect and disconnect
// handlers. Passing nil for either disables that event.
//
// This is a REPLACE operation, not a patch. Calling it a second time
// discards any previously installed handlers, including those whose
// corresponding argument is nil in the new call.
func SetNetworkEvent(onConnect, onDisconnect NetworkHandler) error {
	if err := sys.LoadLibrary(); err != nil {
		return wrapErr(ErrLibraryLoadFailed, err,
			"SetNetworkEvent: native library not available")
	}

	netEventMu.Lock()
	defer netEventMu.Unlock()

	netEventOnConnect = onConnect
	netEventOnDisc = onDisconnect

	// Build the C trampoline wrappers. They capture the handler via
	// the closure and copy the C string before dispatching.
	var connectFn sys.LfNetworkEventFunc
	if onConnect != nil {
		connectFn = func(addr *byte) uintptr {
			dispatchNetworkEvent(onConnect, addr)
			return 0
		}
	}
	var disconnectFn sys.LfNetworkEventFunc
	if onDisconnect != nil {
		disconnectFn = func(addr *byte) uintptr {
			dispatchNetworkEvent(onDisconnect, addr)
			return 0
		}
	}

	sys.SetNetworkEventHandlers(connectFn, disconnectFn)

	// Install in the native layer. Both pointers are stable for the
	// process lifetime; pass 0 to disable either event.
	var cPtr, dPtr uintptr
	if connectFn != nil {
		cPtr = sys.NetworkConnectPtr()
	}
	if disconnectFn != nil {
		dPtr = sys.NetworkDisconnectPtr()
	}
	sys.LF_Set_Network_Event(cPtr, dPtr)

	netEventInstalled = (onConnect != nil) || (onDisconnect != nil)
	return nil
}

// ClearNetworkEvent removes both handlers. Safe to call multiple
// times.
func ClearNetworkEvent() error {
	return SetNetworkEvent(nil, nil)
}

// IsNetworkEventInstalled reports whether at least one handler is
// currently installed.
func IsNetworkEventInstalled() bool {
	netEventMu.Lock()
	defer netEventMu.Unlock()
	return netEventInstalled
}

// dispatchNetworkEvent copies the C string and invokes the handler
// inside a panic-safe wrapper. The trampoline in sys already
// recovers, but catching here as well gives a clearer stack if the
// user handler panics.
func dispatchNetworkEvent(handler NetworkHandler, addr *byte) {
	// Copy the C string before the handler runs; the native buffer
	// is freed as soon as the callback returns.
	s := sys.GoString(addr)
	defer func() { _ = recover() }()
	handler(s)
}
