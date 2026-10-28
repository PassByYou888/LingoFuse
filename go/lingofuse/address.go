package lingofuse

import (
	"context"
	"time"

	"github.com/PassByYou888/LingoFuse/go/sys"
)

// ---------------------------------------------------------------------------
// Addressing targets
// ---------------------------------------------------------------------------
//
// LingoFuse supports three orthogonal addressing modes for remote
// invocation. Each mode is represented by a concrete Go type
// implementing the Target interface:
//
//	AppTarget      -- address a logical App by name.
//	UIDTarget      -- address a specific session by its 32-byte UID.
//	P2PNameTarget  -- address a group of clients sharing a P2P name.
//
// All three share the same call surface, so a program can switch
// between addressing modes without rewriting its call sites.
//
// Routing semantics differ per mode:
//
//	AppTarget       LOCAL-FIRST: if the caller process itself hosts
//	                an App with the matching name and API, the call
//	                is serviced locally without touching the network.
//
//	UIDTarget       LOCAL-FIRST, matching AppTarget. A UID is a
//	                session identifier regenerated on every
//	                TunnelLink; callers that cache a UID MUST
//	                re-probe after a link loss.
//
//	P2PNameTarget   NOT local-first. Even when the caller process
//	                itself hosts a client in the target group, the
//	                call is forwarded to the server for dispatch.
//	                This preserves the server-side load-balancing
//	                state.
//
// {!!!!!  UID IS CAPTURED BY VALUE AND PASSED BY POINTER  !!!!!}
// The FFI layer declares UID parameters as `*sys.TP2P_UID`, because
// purego does not support struct or array arguments on Windows amd64.
// Every closure in UIDTarget's targetCore therefore takes the address
// of a LOCAL copy of the captured UID before calling the FFI
// primitive. See sys/bindings.go for the full rationale.

// Target is the common interface for the three addressing modes.
//
// Implementations are immutable after construction and are safe to
// share across goroutines.
//
// {!!!!!  CALLBACK SAFETY: BLOCKING METHODS MUST NOT RUN IN A CALLBACK  !!!!!}
// The synchronous methods on this interface -- Call, CallCtx,
// SequencedCall, and SequencedCallCtx -- BLOCK the calling goroutine
// until the remote peer replies (or the timeout expires).
//
// They MUST NOT be called from inside a registered LingoFuse callback:
//
//   - CallHandler
//   - NotifyHandler
//   - an LF_AsyncCallOnResult function (delivered as AsyncResult)
//   - a network event handler installed via SetNetworkEvent
//
// Doing so deadlocks the TCompute worker thread that is currently
// servicing the callback: the framework's internal locks are held
// during callback dispatch, and the synchronous call family needs
// the SAME locks to deliver its response.
//
// This rule is documented in the C++ binding (LingoFuse.hpp, the
// "CALLBACK CONTEXT" section) and in the Python binding (lingofuse
// .client, the "Callback Contract" note). The Go binding enforces
// the same contract; the framework cannot detect a violation, so
// the responsibility lies with the caller.
//
// If a callback needs to issue a follow-up request, it MUST use one
// of the ASYNCHRONOUS methods instead:
//
//	CallAsync / CallAsyncWithTimeout  -- non-blocking, callback-driven
//	SequencedCallAsync                -- non-blocking, FIFO-ordered
//
// These methods return immediately. Their result is delivered to a
// separate callback that runs on a DIFFERENT worker thread; the
// original callback returns at once, releasing the lock the
// synchronous family would have needed.
type Target interface {
	// Call sends a blocking request bounded by timeoutMs
	// milliseconds. A timeout value of 0 means "use the default"
	// (5000 ms).
	//
	// The returned *DataHandle is caller-owned; the caller MUST
	// Close it. An empty response (Size == 0) is reported as a
	// non-nil handle, not as an error.
	//
	// {!!!!!  MUST NOT BE CALLED FROM WITHIN A CALLBACK  !!!!!}
	// See the Target interface docstring ("Callback safety") for
	// the full rationale. Use CallAsync when issuing a request from
	// inside a registered LingoFuse callback.
	Call(api string, payload any, timeoutMs uint64) (*DataHandle, error)

	// CallCtx is Call with a context-based cancellation. Cancelling
	// ctx stops the Go-side wait but does NOT cancel the C-side
	// request.
	//
	// {!!!!!  MUST NOT BE CALLED FROM WITHIN A CALLBACK  !!!!!}
	// Same restriction as Call.
	CallCtx(ctx context.Context, api string, payload any) (*DataHandle, error)

	// CallAsync issues a non-blocking request. The callback fires
	// exactly once, either asynchronously on a worker thread (with
	// a result) or synchronously on the caller's goroutine (with a
	// dispatch error).
	//
	// This is the ONLY correct way to issue a request from inside
	// another LingoFuse callback.
	CallAsync(api string, payload any, cb func(AsyncResult)) error

	// CallAsyncWithTimeout is CallAsync with a Go-side timeout. A
	// non-positive timeout disables the timeout entirely.
	CallAsyncWithTimeout(
		api string,
		payload any,
		timeout time.Duration,
		cb func(AsyncResult),
	) error

	// SequencedCall is Call with FIFO ordering per (target, api).
	//
	// {!!!!!  MUST NOT BE CALLED FROM WITHIN A CALLBACK  !!!!!}
	// Same restriction as Call.
	SequencedCall(api string, payload any, timeoutMs uint64) (*DataHandle, error)

	// SequencedCallCtx is SequencedCall with context cancellation.
	//
	// {!!!!!  MUST NOT BE CALLED FROM WITHIN A CALLBACK  !!!!!}
	// Same restriction as Call.
	SequencedCallCtx(ctx context.Context, api string, payload any) (*DataHandle, error)

	// SequencedCallAsync is CallAsync with FIFO ordering.
	SequencedCallAsync(api string, payload any, cb func(AsyncResult)) error

	// Notify sends a one-way notification.
	//
	// Unlike the Call family, Notify does not wait for a response.
	// It is therefore SAFE to call from inside a callback, subject
	// to the general rule that a callback must return promptly.
	Notify(api string, payload any) error

	// SequencedNotify is Notify with FIFO ordering per (target, api).
	SequencedNotify(api string, payload any) error

	// Describe returns a short human-readable description of this
	// target.
	Describe() string
}

// ---------------------------------------------------------------------------
// targetCore -- the shared implementation behind every Target
// ---------------------------------------------------------------------------
//
// The three addressing modes differ ONLY in how they invoke the
// native layer. Everything else -- serialization, timeout handling,
// callback wrapping, dispatch-failure recovery -- is identical.
//
// targetCore captures the shared behaviour by storing five function
// pointers, one per native call family. Concrete targets set these
// pointers in their constructor and gain all of the Target interface
// methods via Go's method promotion.
type targetCore struct {
	describe     string
	syncCall     func(apiName string, hnd sys.DataHnd, timeoutMs uint64) sys.DataHnd
	asyncCall    func(apiName string, hnd sys.DataHnd, dataID uintptr, cbPtr uintptr) int32
	asyncSeqCall func(apiName string, hnd sys.DataHnd, dataID uintptr, cbPtr uintptr) int32
	syncNotify   func(apiName string, hnd sys.DataHnd)
	seqNotify    func(apiName string, hnd sys.DataHnd)
}

// Describe returns the human-readable description configured at
// construction time.
func (c *targetCore) Describe() string { return c.describe }

// encodePayload builds or accepts a DataHandle for apiName.
//
// {!!!!!  TWO PAYLOAD FORMS ARE ACCEPTED  !!!!!}
//
//	Form A -- *DataHandle (caller-owned, passthrough)
//	    The caller has already built the payload (possibly from a
//	    template, a pool, or a previous call). encodePayload returns
//	    it verbatim and reports owned = false, so the call sites do
//	    NOT close it. The caller retains full lifetime control.
//
//	Form B -- any other value (JSON payload, built here)
//	    A fresh auto-recycled DataHandle is created, the value is
//	    serialized as UTF-8 JSON, and the handle is returned with
//	    owned = true. The call sites close it with defer.
//
// A nil payload is treated as Form B with an empty body: a new
// DataHandle is returned (owned = true) with no JSON written. This
// is the canonical "no arguments" call.
//
// {!!!!!  WHY Form A EXISTS  !!!!!}
// Without Form A, a caller that passes an already-built DataHandle
// would trigger a JSON serialization of that handle. encoding/json
// cannot serialize the sync.Mutex embedded in DataHandle, so every
// such call would fail with ErrWriteFailed -- even though the
// handle itself is perfectly valid. Form A fixes that: it treats
// *DataHandle as a pre-built payload, not as a value to serialize.
//
// {!!!!!  WHY THE "owned" FLAG EXISTS  !!!!!}
// Form B handles are created by this function and MUST be released
// by the caller of encodePayload (via defer Close). Form A handles
// are owned by the caller of the Target method (the user) and MUST
// NOT be released by Target methods. Passing the ownership bit
// explicitly is the only way to avoid a double-free on Form A and a
// leak on Form B.
func encodePayload(apiName string, payload any) (h *DataHandle, owned bool, err error) {
	if hnd, ok := payload.(*DataHandle); ok {
		if hnd == nil {
			return nil, false, newErr(ErrInvalidArgument,
				"encodePayload: payload is a nil *DataHandle")
		}
		if !hnd.IsValid() {
			return nil, false, newErr(ErrNullHandle,
				"encodePayload: payload *DataHandle is closed")
		}
		return hnd, false, nil
	}

	h, err = NewDataHandle(apiName)
	if err != nil {
		return nil, false, err
	}
	if payload == nil {
		return h, true, nil
	}
	if err := WriteJSON(h, payload); err != nil {
		h.Close()
		return nil, false, err
	}
	return h, true, nil
}

// ---------------------------------------------------------------------------
// targetCore: synchronous calls
// ---------------------------------------------------------------------------

// Call issues a blocking request and returns the response handle.
//
// {!!!!!  EMPTY RESPONSE IS NOT AN ERROR  !!!!!}
// A successful call whose response body is empty yields a non-nil
// handle with Size == 0.
//
// {!!!!!  MUST NOT BE CALLED FROM WITHIN A CALLBACK  !!!!!}
// See the Target interface docstring. Calling this from inside a
// registered LingoFuse callback deadlocks the worker thread that is
// servicing the callback.
func (c *targetCore) Call(api string, payload any, timeoutMs uint64) (*DataHandle, error) {
	if timeoutMs == 0 {
		timeoutMs = 5000
	}

	hnd, owned, err := encodePayload(api, payload)
	if err != nil {
		return nil, err
	}
	if owned {
		defer hnd.Close()
	}

	raw := c.syncCall(api, hnd.Raw(), timeoutMs)
	if raw == 0 {
		return nil, newErr(ErrCallFailed,
			"%s: %s: native layer returned a null handle",
			c.describe, api)
	}
	return fromRaw(raw, true), nil
}

// SequencedCall issues a blocking FIFO-ordered request.
//
// {!!!!!  NO NATIVE SYNCHRONOUS SEQUENCED CALL  !!!!!}
// The C ABI exposes only an ASYNCHRONOUS sequenced-call primitive.
// This method therefore implements the blocking behaviour on top of
// the async primitive by waiting on a context with a timeout.
//
// {!!!!!  MUST NOT BE CALLED FROM WITHIN A CALLBACK  !!!!!}
// Same restriction as Call. Use SequencedCallAsync from a callback.
func (c *targetCore) SequencedCall(api string, payload any, timeoutMs uint64) (*DataHandle, error) {
	if timeoutMs == 0 {
		timeoutMs = 5000
	}
	ctx, cancel := context.WithTimeout(
		context.Background(),
		time.Duration(timeoutMs)*time.Millisecond,
	)
	defer cancel()
	return c.SequencedCallCtx(ctx, api, payload)
}

// ---------------------------------------------------------------------------
// targetCore: context-bounded calls
// ---------------------------------------------------------------------------

// CallCtx issues a blocking request bounded by ctx.
//
// Cancelling ctx stops the Go-side wait but does NOT cancel the
// C-side request; see the docstring of callCtxImpl in async.go.
//
// {!!!!!  MUST NOT BE CALLED FROM WITHIN A CALLBACK  !!!!!}
// Same restriction as Call.
func (c *targetCore) CallCtx(
	ctx context.Context,
	api string,
	payload any,
) (*DataHandle, error) {
	return callCtxImpl(ctx, func(cb func(AsyncResult)) error {
		return c.CallAsync(api, payload, cb)
	})
}

// SequencedCallCtx is SequencedCall with context cancellation.
//
// {!!!!!  MUST NOT BE CALLED FROM WITHIN A CALLBACK  !!!!!}
// Same restriction as Call.
func (c *targetCore) SequencedCallCtx(
	ctx context.Context,
	api string,
	payload any,
) (*DataHandle, error) {
	return callCtxImpl(ctx, func(cb func(AsyncResult)) error {
		return c.SequencedCallAsync(api, payload, cb)
	})
}

// ---------------------------------------------------------------------------
// targetCore: asynchronous calls
// ---------------------------------------------------------------------------

// CallAsync issues a non-blocking request.
//
// The callback fires exactly once. See dispatchAsync in async.go for
// the full contract.
//
// This is the correct way to issue a request from inside another
// LingoFuse callback. It returns immediately; the result is
// delivered to cb on a separate worker thread.
func (c *targetCore) CallAsync(
	api string,
	payload any,
	cb func(AsyncResult),
) error {
	if cb == nil {
		return newErr(ErrInvalidArgument,
			"%s: CallAsync: cb must not be nil", c.describe)
	}

	hnd, owned, err := encodePayload(api, payload)
	if err != nil {
		return err
	}
	if owned {
		defer hnd.Close()
	}

	return dispatchAsync(
		func(dataID, cbPtr uintptr) int32 {
			return c.asyncCall(api, hnd.Raw(), dataID, cbPtr)
		},
		cb,
	)
}

// CallAsyncWithTimeout is CallAsync with a Go-side timeout. See
// dispatchAsyncWithTimeout in async.go for the full contract.
func (c *targetCore) CallAsyncWithTimeout(
	api string,
	payload any,
	timeout time.Duration,
	cb func(AsyncResult),
) error {
	if cb == nil {
		return newErr(ErrInvalidArgument,
			"%s: CallAsyncWithTimeout: cb must not be nil", c.describe)
	}

	hnd, owned, err := encodePayload(api, payload)
	if err != nil {
		return err
	}
	if owned {
		defer hnd.Close()
	}

	return dispatchAsyncWithTimeout(
		func(dataID, cbPtr uintptr) int32 {
			return c.asyncCall(api, hnd.Raw(), dataID, cbPtr)
		},
		timeout,
		cb,
	)
}

// SequencedCallAsync is CallAsync with FIFO ordering per (target, api).
func (c *targetCore) SequencedCallAsync(
	api string,
	payload any,
	cb func(AsyncResult),
) error {
	if cb == nil {
		return newErr(ErrInvalidArgument,
			"%s: SequencedCallAsync: cb must not be nil", c.describe)
	}

	hnd, owned, err := encodePayload(api, payload)
	if err != nil {
		return err
	}
	if owned {
		defer hnd.Close()
	}

	return dispatchAsync(
		func(dataID, cbPtr uintptr) int32 {
			return c.asyncSeqCall(api, hnd.Raw(), dataID, cbPtr)
		},
		cb,
	)
}

// ---------------------------------------------------------------------------
// targetCore: one-way notifications
// ---------------------------------------------------------------------------

// Notify sends a one-way notification.
//
// Delivery order is NOT guaranteed. Use SequencedNotify when FIFO
// ordering is required for a given (target, api) pair.
//
// This method does not wait for a response, so it is safe to call
// from inside a callback. The callback should still return promptly
// to avoid occupying the worker thread.
func (c *targetCore) Notify(api string, payload any) error {
	hnd, owned, err := encodePayload(api, payload)
	if err != nil {
		return err
	}
	if owned {
		defer hnd.Close()
	}

	c.syncNotify(api, hnd.Raw())
	return nil
}

// SequencedNotify is Notify with FIFO ordering per (target, api).
func (c *targetCore) SequencedNotify(api string, payload any) error {
	hnd, owned, err := encodePayload(api, payload)
	if err != nil {
		return err
	}
	if owned {
		defer hnd.Close()
	}

	c.seqNotify(api, hnd.Raw())
	return nil
}

// ---------------------------------------------------------------------------
// AppTarget
// ---------------------------------------------------------------------------

// AppTarget addresses a logical App by name.
//
// Routing is LOCAL-FIRST: if the caller process itself hosts an App
// with the matching name and the requested API, the call is serviced
// locally without touching the network.
type AppTarget struct {
	targetCore
	name string
}

// NewAppTarget returns a Target that addresses the named App.
func NewAppTarget(name string) *AppTarget {
	return &AppTarget{
		targetCore: targetCore{
			describe: "app(" + name + ")",
			syncCall: func(api string, hnd sys.DataHnd, timeoutMs uint64) sys.DataHnd {
				var scope sys.CStringScope
				n := scope.Add(name)
				res := sys.LF_Call(n, hnd, timeoutMs)
				scope.Release()
				return res
			},
			asyncCall: func(api string, hnd sys.DataHnd, dataID, cbPtr uintptr) int32 {
				var scope sys.CStringScope
				n := scope.Add(name)
				rc := sys.LF_Async_Call(n, hnd, dataID, cbPtr)
				scope.Release()
				return rc
			},
			asyncSeqCall: func(api string, hnd sys.DataHnd, dataID, cbPtr uintptr) int32 {
				var scope sys.CStringScope
				n := scope.Add(name)
				rc := sys.LF_Async_Sequenced_Call(n, hnd, dataID, cbPtr)
				scope.Release()
				return rc
			},
			syncNotify: func(api string, hnd sys.DataHnd) {
				var scope sys.CStringScope
				n := scope.Add(name)
				sys.LF_Notify(n, hnd)
				scope.Release()
			},
			seqNotify: func(api string, hnd sys.DataHnd) {
				var scope sys.CStringScope
				n := scope.Add(name)
				sys.LF_Sequenced_Notify(n, hnd)
				scope.Release()
			},
		},
		name: name,
	}
}

// Name returns the App name this target addresses.
func (t *AppTarget) Name() string { return t.name }

// String implements fmt.Stringer.
func (t *AppTarget) String() string { return t.describe }

// ---------------------------------------------------------------------------
// UIDTarget
// ---------------------------------------------------------------------------

// UIDTarget addresses a specific session by its 32-byte UID.
//
// Routing is LOCAL-FIRST, matching AppTarget.
//
// {!!!!!  HOW TO OBTAIN A UID  !!!!!}
// A UID is a session identifier generated by the framework during
// TunnelLink. It is NOT a property of any handle the caller creates.
// It is SIDE DATA injected by the SENDER'S transport layer into every
// outbound payload before transmission.
//
// To learn a client's own UID, use the "whoami" pattern: register a
// Call API whose handler reads the caller's UID from its INPUT handle:
//
//	func whoami(inp, out *DataHandle) {
//	    uid, _ := inp.GetP2PUID()
//	    _ = out.WriteString(sys.FormatUIDHex(uid))
//	}
//
// The client then calls whoami and caches the returned 32-byte value.
// Because the UID is regenerated on every TunnelLink, the client MUST
// re-probe after a link loss.
type UIDTarget struct {
	targetCore
	uid sys.TP2P_UID
}

// NewUIDTarget returns a Target that addresses the given UID.
//
// {!!!!!  UID IS CAPTURED BY VALUE AND PASSED BY POINTER  !!!!!}
// The `uid` parameter is captured by value by each closure below.
// Every closure then takes the address of a LOCAL copy of that value
// before calling the FFI primitive. This is required because the
// underlying C ABI passes a 32-byte aggregate by reference, and
// purego on Windows amd64 does not support struct arguments. Passing
// a pointer to a local copy matches the ABI exactly.
func NewUIDTarget(uid sys.TP2P_UID) *UIDTarget {
	hex := sys.FormatUIDHex(uid)
	return &UIDTarget{
		targetCore: targetCore{
			describe: "uid(" + hex + ")",
			syncCall: func(api string, hnd sys.DataHnd, timeoutMs uint64) sys.DataHnd {
				localUID := uid
				return sys.LF_UID_Call(&localUID, hnd, timeoutMs)
			},
			asyncCall: func(api string, hnd sys.DataHnd, dataID, cbPtr uintptr) int32 {
				localUID := uid
				return sys.LF_UID_Async_Call(&localUID, hnd, dataID, cbPtr)
			},
			asyncSeqCall: func(api string, hnd sys.DataHnd, dataID, cbPtr uintptr) int32 {
				localUID := uid
				return sys.LF_UID_Async_Sequenced_Call(&localUID, hnd, dataID, cbPtr)
			},
			syncNotify: func(api string, hnd sys.DataHnd) {
				localUID := uid
				sys.LF_UID_Notify(&localUID, hnd)
			},
			seqNotify: func(api string, hnd sys.DataHnd) {
				localUID := uid
				sys.LF_UID_Sequenced_Notify(&localUID, hnd)
			},
		},
		uid: uid,
	}
}

// UID returns the 32-byte UID this target addresses.
func (t *UIDTarget) UID() sys.TP2P_UID { return t.uid }

// String implements fmt.Stringer.
func (t *UIDTarget) String() string { return t.describe }

// ---------------------------------------------------------------------------
// P2PNameTarget
// ---------------------------------------------------------------------------

// P2PNameTarget addresses a group of clients that share a user-
// supplied P2P name.
//
// Routing is NOT local-first. Even when the caller process itself
// hosts a client in the target group, the call is forwarded to the
// server for dispatch. This preserves the server-side load-balancing
// state.
//
// {!!!!!  RELATION TO SIDE DATA  !!!!!}
// The group name passed to NewP2PNameTarget is a routing key the
// caller uses to address a target group. This is DIFFERENT from the
// P2P name that a receiver reads from a callback's INPUT handle via
// DataHandle.GetP2PName(). The latter is SIDE DATA injected by the
// sender's transport layer, identifying the sender.
type P2PNameTarget struct {
	targetCore
	group string
}

// NewP2PNameTarget returns a Target that addresses the named P2P group.
func NewP2PNameTarget(group string) *P2PNameTarget {
	return &P2PNameTarget{
		targetCore: targetCore{
			describe: "p2pname(" + group + ")",
			syncCall: func(api string, hnd sys.DataHnd, timeoutMs uint64) sys.DataHnd {
				var scope sys.CStringScope
				n := scope.Add(group)
				res := sys.LF_P2PNAME_Call(n, hnd, timeoutMs)
				scope.Release()
				return res
			},
			asyncCall: func(api string, hnd sys.DataHnd, dataID, cbPtr uintptr) int32 {
				var scope sys.CStringScope
				n := scope.Add(group)
				rc := sys.LF_P2PNAME_Async_Call(n, hnd, dataID, cbPtr)
				scope.Release()
				return rc
			},
			asyncSeqCall: func(api string, hnd sys.DataHnd, dataID, cbPtr uintptr) int32 {
				var scope sys.CStringScope
				n := scope.Add(group)
				rc := sys.LF_P2PNAME_Async_Sequenced_Call(n, hnd, dataID, cbPtr)
				scope.Release()
				return rc
			},
			syncNotify: func(api string, hnd sys.DataHnd) {
				var scope sys.CStringScope
				n := scope.Add(group)
				sys.LF_P2PNAME_Notify(n, hnd)
				scope.Release()
			},
			seqNotify: func(api string, hnd sys.DataHnd) {
				var scope sys.CStringScope
				n := scope.Add(group)
				sys.LF_P2PNAME_Sequenced_Notify(n, hnd)
				scope.Release()
			},
		},
		group: group,
	}
}

// Group returns the P2P group name this target addresses.
func (t *P2PNameTarget) Group() string { return t.group }

// String implements fmt.Stringer.
func (t *P2PNameTarget) String() string { return t.describe }

// ---------------------------------------------------------------------------
// Convenience constructors
// ---------------------------------------------------------------------------

// App is a shorthand for NewAppTarget.
func App(name string) *AppTarget { return NewAppTarget(name) }

// UID is a shorthand for NewUIDTarget.
func UID(uid sys.TP2P_UID) *UIDTarget { return NewUIDTarget(uid) }

// P2P is a shorthand for NewP2PNameTarget.
func P2P(group string) *P2PNameTarget { return NewP2PNameTarget(group) }
