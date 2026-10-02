package sys

import (
	"sync"
	"sync/atomic"

	"github.com/ebitengine/purego"
)

var callbackRegistry sync.Map // uintptr -> any

var nextCallbackID atomic.Uintptr

func registerCallback(fn any) uintptr {
	id := nextCallbackID.Add(1)
	callbackRegistry.Store(id, fn)
	return id
}

func lookupCallback(id uintptr) any {
	v, ok := callbackRegistry.Load(id)
	if !ok {
		return nil
	}
	return v
}

// UnregisterCallback removes the entry for id. Safe to call with an
// unknown or zero ID.
func UnregisterCallback(id uintptr) {
	if id == 0 {
		return
	}
	callbackRegistry.Delete(id)
}

func callTrampoline(trigger uintptr, input DataHnd, output DataHnd) uintptr {
	defer func() { _ = recover() }()
	v := lookupCallback(trigger)
	if v == nil {
		return 0
	}
	fn, ok := v.(LfCallFunc)
	if !ok {
		return 0
	}
	return fn(trigger, input, output)
}

func notifyTrampoline(trigger uintptr, input DataHnd) uintptr {
	defer func() { _ = recover() }()
	v := lookupCallback(trigger)
	if v == nil {
		return 0
	}
	fn, ok := v.(LfNotifyFunc)
	if !ok {
		return 0
	}
	return fn(trigger, input)
}

// RegisterCallCallback stores fn in the registry and returns the
// (triggerID, cFuncPtr) pair required by LF_RegisterCall. Callers
// must call UnregisterCallback(triggerID) when the API is
// unregistered or the application is disposed.
func RegisterCallCallback(fn LfCallFunc) (trigger uintptr, cFuncPtr uintptr) {
	id := registerCallback(fn)
	ptr := purego.NewCallback(callTrampoline)
	return id, ptr
}

// RegisterNotifyCallback stores fn in the registry and returns the
// (triggerID, cFuncPtr) pair required by LF_RegisterNotify.
func RegisterNotifyCallback(fn LfNotifyFunc) (trigger uintptr, cFuncPtr uintptr) {
	id := registerCallback(fn)
	ptr := purego.NewCallback(notifyTrampoline)
	return id, ptr
}

var (
	networkConnectID    uintptr
	networkDisconnectID uintptr

	networkConnectPtr    uintptr
	networkDisconnectPtr uintptr
)

func init() {
	networkConnectID = registerCallback(LfNetworkEventFunc(nil))
	networkDisconnectID = registerCallback(LfNetworkEventFunc(nil))
	networkConnectPtr = purego.NewCallback(connectTrampoline)
	networkDisconnectPtr = purego.NewCallback(disconnectTrampoline)
}

func connectTrampoline(addr *byte) uintptr {
	defer func() { _ = recover() }()
	if v := lookupCallback(networkConnectID); v != nil {
		if fn, ok := v.(LfNetworkEventFunc); ok && fn != nil {
			return fn(addr)
		}
	}
	return 0
}

func disconnectTrampoline(addr *byte) uintptr {
	defer func() { _ = recover() }()
	if v := lookupCallback(networkDisconnectID); v != nil {
		if fn, ok := v.(LfNetworkEventFunc); ok && fn != nil {
			return fn(addr)
		}
	}
	return 0
}

// SetNetworkEventHandlers stores the two handlers under the fixed
// network event IDs. Pass nil to disable an event.
func SetNetworkEventHandlers(onConnect, onDisconnect LfNetworkEventFunc) {
	callbackRegistry.Store(networkConnectID, onConnect)
	callbackRegistry.Store(networkDisconnectID, onDisconnect)
}

// NetworkConnectPtr returns the C function pointer for the connect
// trampoline (stable for the process lifetime).
func NetworkConnectPtr() uintptr { return networkConnectPtr }

// NetworkDisconnectPtr returns the C function pointer for the
// disconnect trampoline.
func NetworkDisconnectPtr() uintptr { return networkDisconnectPtr }
