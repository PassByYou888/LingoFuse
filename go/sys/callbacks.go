package sys

import (
	"sync"
	"sync/atomic"
	"time"

	"github.com/ebitengine/purego"
)

// ---------------------------------------------------------------------------
// Callback registry
// ---------------------------------------------------------------------------
//
// The native library holds RAW C FUNCTION POINTERS to every callback
// the Go binding installs. It does NOT hold a Go reference to the
// corresponding Go function. If the Go function were garbage-
// collected while the C side still held its pointer, the next
// invocation would jump into freed memory.
//
// This registry therefore keeps a STRONG reference to every installed
// callback for as long as the C side might invoke it. Entries are
// added at install time and removed either when the API is
// unregistered (for API callbacks) or when the callback has fired
// exactly once (for async result callbacks).
//
// {!!!!!  WHY sync.Map  !!!!!}
// The access pattern is "write once, read once, delete once" per
// entry, with high concurrency across entries. sync.Map optimises
// exactly this pattern: it avoids the global mutex contention of a
// plain map+RWMutex for read-mostly workloads with frequent writes
// to disjoint keys.

var callbackRegistry sync.Map // uintptr -> any

var nextCallbackID atomic.Uintptr

// registerCallback stores fn under a fresh ID and returns that ID.
// The ID is a small positive integer.
func registerCallback(fn any) uintptr {
	id := nextCallbackID.Add(1)
	callbackRegistry.Store(id, fn)
	return id
}

// lookupCallback returns the value stored under id, or nil if the ID
// is unknown.
func lookupCallback(id uintptr) any {
	v, ok := callbackRegistry.Load(id)
	if !ok {
		return nil
	}
	return v
}

// UnregisterCallback removes the entry for id. Safe to call with an
// unknown or zero ID.
//
// Callers MUST invoke this when a callback will never fire again.
// For API callbacks (Call / Notify), that is at unregistration time.
// For async callbacks, either the trampoline removes the entry
// automatically after firing, or the dispatcher removes it after a
// dispatch failure.
func UnregisterCallback(id uintptr) {
	if id == 0 {
		return
	}
	callbackRegistry.Delete(id)
}

// ---------------------------------------------------------------------------
// Synchronous API callbacks (Call / Notify)
// ---------------------------------------------------------------------------
//
// These are the trampolines for the four API registration paths:
//
//	LF_RegisterCall              app-bound Call
//	LF_RegisterNotify            app-bound Notify
//	LF_Register_P2P_Call         process-wide P2P Call
//	LF_Register_P2P_Notify       process-wide P2P Notify
//
// All four share the same two trampolines because the C-side
// signatures are identical.

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
// (triggerID, cFuncPtr) pair required by LF_RegisterCall and
// LF_Register_P2P_Call.
func RegisterCallCallback(fn LfCallFunc) (trigger uintptr, cFuncPtr uintptr) {
	id := registerCallback(fn)
	ptr := purego.NewCallback(callTrampoline)
	return id, ptr
}

// RegisterNotifyCallback stores fn in the registry and returns the
// (triggerID, cFuncPtr) pair required by LF_RegisterNotify and
// LF_Register_P2P_Notify.
func RegisterNotifyCallback(fn LfNotifyFunc) (trigger uintptr, cFuncPtr uintptr) {
	id := registerCallback(fn)
	ptr := purego.NewCallback(notifyTrampoline)
	return id, ptr
}

// ---------------------------------------------------------------------------
// Asynchronous result callback (LF_Async_Call family)
// ---------------------------------------------------------------------------
//
// {!!!!!  SINGLE SHARED TRAMPOLINE  !!!!!}
// The asynchronous callback is fundamentally different from the
// synchronous ones. It is invoked EXACTLY ONCE per request, and the
// request-specific context must be carried through the opaque `data`
// pointer that the C ABI forwards verbatim.
//
// One trampoline per request (via purego.NewCallback per call) would
// leak executable memory at roughly 100 bytes per call, because
// purego's callbacks are never released. A single shared trampoline
// for the whole process avoids that entirely.
//
// The single trampoline is created once, at package init, and its C
// function pointer is reused for every asynchronous request. Requests
// are distinguished by the opaque `data` ID, which the registry maps
// to the caller's Go closure.
//
// {!!!!!  REGISTRY LIFETIME  !!!!!}
// Each async request registers its closure under a fresh ID BEFORE
// the C ABI is called. The registry entry is removed in one of two
// ways:
//
//   - Normal completion: the trampoline uses LoadAndDelete, so the
//     entry disappears as the callback fires.
//
//   - Dispatch failure (LF_Async_Call returned non-1): the callback
//     will never fire, so the dispatcher must call UnregisterCallback
//     explicitly.
//
// Either way, no entry survives past the lifetime of its request.

var asyncTrampolinePtr uintptr

// asyncResultTrampoline is invoked on a native worker thread by the
// LingoFuse framework. It MUST:
//
//  1. never block,
//  2. never call any blocking LingoFuse function,
//  3. never let a Go panic escape into the C stack,
//  4. never call LF_FreeData on the result handle (the framework
//     owns it and releases it immediately after this returns),
//  5. remove the registry entry so that the callback closure can be
//     garbage-collected.
func asyncResultTrampoline(data uintptr, result DataHnd) uintptr {
	defer func() { _ = recover() }()

	v, ok := callbackRegistry.LoadAndDelete(data)
	if !ok {
		return 0
	}

	fn, ok := v.(LfAsyncCallOnResult)
	if !ok {
		return 0
	}
	return fn(data, result)
}

// RegisterAsyncCallback stores fn in the registry and returns the
// (dataID, cFuncPtr) pair required by LF_Async_Call and its
// UID_* / P2PName_* siblings.
func RegisterAsyncCallback(fn LfAsyncCallOnResult) (dataID uintptr, cFuncPtr uintptr) {
	id := registerCallback(fn)
	return id, asyncTrampolinePtr
}

// ---------------------------------------------------------------------------
// Network event callbacks
// ---------------------------------------------------------------------------
//
// LF_Set_Network_Event installs a pair of process-global callbacks.
// Their C function pointers are STABLE for the process lifetime: they
// are created once, at init, and never replaced. The user-supplied
// handler is stored under a fixed registry ID, and swapped when
// SetNetworkEventHandlers is called.

var (
	networkConnectID    uintptr
	networkDisconnectID uintptr

	networkConnectPtr    uintptr
	networkDisconnectPtr uintptr
)

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

// ---------------------------------------------------------------------------
// Deadlock watchdog
// ---------------------------------------------------------------------------
//
// {!!!!!  WHAT IT IS  !!!!!}
// A recursive timer that keeps at least one pending event in the Go
// runtime's timer heap at all times. This prevents the deadlock
// detector from producing a FALSE POSITIVE when a goroutine blocks
// on a native callback that the runtime cannot see.
//
// {!!!!!  WHY IT EXISTS  !!!!!}
// purego does not use cgo, so the Go runtime is not aware of the
// native worker threads that the LingoFuse framework uses to invoke
// asynchronous callbacks. When the user's goroutine blocks waiting
// for such a callback (for example, on a sync.WaitGroup), the
// runtime sees:
//
//   - no runnable goroutines,
//   - no spinning Ps,
//   - no Ms blocked in syscall,
//   - no pending timers,
//
// and concludes that the program is deadlocked. It then calls
// throw("all goroutines are asleep - deadlock!"), which aborts the
// process before the native callback ever has a chance to fire.
//
// This is a FALSE POSITIVE: the C side is genuinely working and
// will invoke the callback in a few microseconds. The runtime
// simply cannot see the C threads.
//
// {!!!!!  WHY IT IS CONFIGURABLE  !!!!!}
// The watchdog is a workaround, not a feature: it masks the
// runtime's own deadlock detection, which is a genuinely useful
// diagnostic for code that has a real deadlock between goroutines.
// Applications that do not need native-callback blocking (for
// example, a CLI that only ever issues synchronous LingoFuse calls)
// can disable the watchdog to preserve the runtime's detector.
//
// {!!!!!  DEFAULT  !!!!!}
// The watchdog is ENABLED by default. This is the safe choice: a
// false-positive abort is a hard crash and is very hard to diagnose,
// while a masked real deadlock typically manifests as a hang that a
// SIGQUIT can diagnose. Callers that prefer the runtime's detector
// can call DisableDeadlockWatchdog at process start.
//
// {!!!!!  COST  !!!!!}
// Negligible. The timer fires once per hour and immediately
// reschedules itself. Between fires it is a single entry in the
// runtime's timer heap, invisible to user code and consuming a few
// dozen bytes of memory.

var (
	deadlockWatchdogEnabled  atomic.Bool
	deadlockWatchdogInterval = time.Hour
)

// DisableDeadlockWatchdog turns off the LingoFuse deadlock watchdog.
//
// {!!!!!  READ THE TRADE-OFF  !!!!!}
// Disabling the watchdog restores the Go runtime's built-in
// deadlock detector, which WILL fire (and abort the process) when a
// goroutine blocks on a native async callback and no other goroutine
// is runnable. This is a hard crash with no recovery path.
//
// Call this only when:
//   - the application never blocks on a native async callback, OR
//   - the application installs its own always-pending timer (for
//     example, a real periodic heartbeat) and therefore does not
//     need the watchdog.
//
// Safe to call multiple times, before or after the watchdog has
// started. Once disabled, the watchdog cannot be re-enabled; call
// this at process start if you need it.
func DisableDeadlockWatchdog() {
	deadlockWatchdogEnabled.Store(false)
}

// IsDeadlockWatchdogEnabled reports the current watchdog state. The
// value reflects the last call to DisableDeadlockWatchdog, or the
// default (enabled) if no such call has been made.
func IsDeadlockWatchdogEnabled() bool {
	return deadlockWatchdogEnabled.Load()
}

// scheduleDeadlockWatchdog arms a recursive timer whose sole purpose
// is to keep the Go runtime's timer subsystem non-empty.
//
// The function never returns once scheduled; each firing simply
// schedules the next one. The timer is cleaned up automatically on
// process exit.
//
// {!!!!!  RESPECTS THE DISABLE FLAG  !!!!!}
// When DisableDeadlockWatchdog has been called, this function does
// NOT schedule the next iteration, so the watchdog stops after at
// most one more hour. Callers that want a hard stop should call
// DisableDeadlockWatchdog at process start; the flag is checked on
// every iteration.
func scheduleDeadlockWatchdog() {
	if !deadlockWatchdogEnabled.Load() {
		return
	}
	time.AfterFunc(deadlockWatchdogInterval, scheduleDeadlockWatchdog)
}

// ---------------------------------------------------------------------------
// Initialization
// ---------------------------------------------------------------------------

func init() {
	// Reserve two fixed registry slots for the network handlers.
	networkConnectID = registerCallback(LfNetworkEventFunc(nil))
	networkDisconnectID = registerCallback(LfNetworkEventFunc(nil))

	// Create the C-side trampolines exactly once. Their pointers are
	// reused for the entire process lifetime.
	networkConnectPtr = purego.NewCallback(connectTrampoline)
	networkDisconnectPtr = purego.NewCallback(disconnectTrampoline)

	// Create the shared async trampoline.
	asyncTrampolinePtr = purego.NewCallback(asyncResultTrampoline)

	// Enable and start the deadlock watchdog. See the
	// "Deadlock watchdog" section above for the full rationale.
	//
	// The watchdog is enabled by default because a false-positive
	// abort is a hard, undiagnosable crash. Applications that do
	// not need it can call DisableDeadlockWatchdog at process
	// start.
	deadlockWatchdogEnabled.Store(true)
	scheduleDeadlockWatchdog()
}
