package lingofuse

import (
	"context"
	"sync/atomic"
	"time"

	"github.com/PassByYou888/LingoFuse/go/sys"
)

// ---------------------------------------------------------------------------
// AsyncResult
// ---------------------------------------------------------------------------
//
// AsyncResult is the single value delivered by every asynchronous
// call path in this package: CallAsync, CallAsyncWithTimeout,
// SequencedCallAsync, and the CallCtx / SequencedCallCtx helpers that
// are built on top of them.
//
// Field semantics:
//
//	Value  -- the response handle, or nil when Err is non-nil.
//	          The handle is BORROWED: the native layer owns the
//	          underlying buffer and releases it the instant the
//	          callback returns. The callback MUST consume whatever
//	          it needs inside its own body.
//
//	Err    -- non-nil when the request could not be dispatched, when
//	          the user-supplied timeout fired before the callback
//	          arrived, or when the framework reported a failure.
//	          When Err is non-nil, Value is always nil.
//
// The AsyncResult value itself is safe to pass to another goroutine,
// but the *DataHandle it carries is not.
type AsyncResult struct {
	Value *DataHandle
	Err   error
}

// ---------------------------------------------------------------------------
// Timeouts
// ---------------------------------------------------------------------------

// drainTimeout bounds how long a caller-side context cancellation
// keeps a drain goroutine alive while it waits for the C-side
// callback to fire.
//
// {!!!!!  WHY THIS EXISTS  !!!!!}
// When a CallCtx / SequencedCallCtx caller cancels its context, the
// underlying C request is NOT cancelled. The callback may still
// arrive on a TWorker thread, and the drain goroutine spawned by
// callCtxImpl waits on the result channel to release the borrowed
// DataHandle. Without an upper bound, a request whose peer never
// responds (for example, after a hard network partition) would leave
// the drain goroutine blocked forever. Every such cancellation
// leaks roughly 2 KB of stack until process exit.
//
// The drainTimeout is deliberately generous: the AsyncBridge grace
// period (default 60 s) is the intended upper bound on how long a
// late callback may still arrive, and the drain goroutine should
// outlive it so the borrowed handle is properly released. Five
// minutes comfortably exceeds the grace period even if an operator
// raises it via LINGOFUSE_ASYNC_RECLAIM_GRACE.
//
// When the timeout fires, the drain goroutine simply returns. The
// channel (capacity 1) still holds whatever the callback eventually
// delivers; the channel and its contents are garbage-collected along
// with the goroutine's stack. A late callback that tries to send on
// a full channel blocks until the send completes; a callback that
// finds the channel unreachable (because the goroutine exited and
// the channel was collected) simply sends into a channel no one will
// read, which is safe.
const drainTimeout = 5 * time.Minute

// ---------------------------------------------------------------------------
// Dispatch primitives (internal)
// ---------------------------------------------------------------------------
//
// {!!!!!  SINGLE SHARED TRAMPOLINE  !!!!!}
// The C ABI requires an LFAsyncCallOnResult callback for every async
// request. The sys package installs ONE shared trampoline for the
// whole process, and distinguishes concurrent requests by an opaque
// uintptr ID that the C ABI forwards verbatim to the callback. This
// file is the layer that allocates those IDs, wraps the user's
// callback in a Go closure, and hands the closure to sys for
// registry storage.
//
// {!!!!!  DISPATCH FAILURE IS REPORTED SYNCHRONOUSLY  !!!!!}
// When the native LF_*_Async_Call function returns a value other than
// 1, the callback will NEVER fire. Rather than leaving the caller to
// poll or timeout, this layer invokes the user callback SYNCHRONOUSLY
// on the caller's own goroutine with Err = ErrAsyncDispatchFailed.

// dispatchAsync issues one asynchronous call and delivers the result
// to cb.
func dispatchAsync(
	issueFn func(dataID, cbPtr uintptr) int32,
	cb func(AsyncResult),
) error {
	var trampoline sys.LfAsyncCallOnResult = func(
		_ uintptr,
		rawResult sys.DataHnd,
	) uintptr {
		var value *DataHandle
		if rawResult != 0 {
			value = fromRaw(rawResult, false)
		}
		cb(AsyncResult{Value: value})
		return 0
	}

	dataID, cbPtr := sys.RegisterAsyncCallback(trampoline)

	rc := issueFn(dataID, cbPtr)
	if rc != 1 {
		sys.UnregisterCallback(dataID)
		cb(AsyncResult{Err: newErr(ErrAsyncDispatchFailed,
			"async dispatch rejected by native layer (rc=%d)", rc)})
		return nil
	}
	return nil
}

// dispatchAsyncWithTimeout is dispatchAsync plus a Go-side timeout.
func dispatchAsyncWithTimeout(
	issueFn func(dataID, cbPtr uintptr) int32,
	timeout time.Duration,
	cb func(AsyncResult),
) error {
	if timeout <= 0 {
		return dispatchAsync(issueFn, cb)
	}

	var fired atomic.Bool

	deliver := func(r AsyncResult) {
		if fired.CompareAndSwap(false, true) {
			cb(r)
		}
	}

	var trampoline sys.LfAsyncCallOnResult = func(
		_ uintptr,
		rawResult sys.DataHnd,
	) uintptr {
		var value *DataHandle
		if rawResult != 0 {
			value = fromRaw(rawResult, false)
		}
		deliver(AsyncResult{Value: value})
		return 0
	}

	dataID, cbPtr := sys.RegisterAsyncCallback(trampoline)

	rc := issueFn(dataID, cbPtr)
	if rc != 1 {
		sys.UnregisterCallback(dataID)
		deliver(AsyncResult{Err: newErr(ErrAsyncDispatchFailed,
			"async dispatch rejected by native layer (rc=%d)", rc)})
		return nil
	}

	time.AfterFunc(timeout, func() {
		sys.UnregisterCallback(dataID)
		deliver(AsyncResult{Err: newErr(ErrTimeout,
			"async call timed out after %s; the C-side request "+
				"may still be in flight and its result will be "+
				"discarded", timeout)})
	})

	return nil
}

// ---------------------------------------------------------------------------
// Context helpers (internal)
// ---------------------------------------------------------------------------

type ctxResult struct {
	value *DataHandle
	err   error
}

// callCtxImpl is the shared implementation behind CallCtx and
// SequencedCallCtx.
//
// {!!!!!  FAST PATH: ctx IS CHECKED BEFORE DISPATCH  !!!!!}
// If the context is already done when this function is called, it
// returns ctx.Err() immediately and does NOT dispatch the request.
// This matches the behaviour of every other Go API that accepts a
// context, and it lets callers abort cheaply without generating a
// spurious dispatch attempt.
//
// {!!!!!  CONTEXT CANCELLATION IS NOT REQUEST CANCELLATION  !!!!!}
// If the context is cancelled while the request is in flight, the
// underlying C request is NOT cancelled. The framework continues to
// process it, and the callback will fire on a worker thread. To avoid
// leaking the borrowed result handle, a small drain goroutine is
// spawned to wait for the callback and release whatever it delivers.
//
// The channel is buffered (cap=1) so the worker thread never blocks,
// even if the caller has already given up.
//
// The drain goroutine is bounded by drainTimeout: if the C request
// never produces a callback within that window, the goroutine exits
// rather than waiting forever. See the drainTimeout docstring for
// the full rationale.
func callCtxImpl(
	ctx context.Context,
	issue func(cb func(AsyncResult)) error,
) (*DataHandle, error) {
	// Fast path: already cancelled or already timed out. Do not
	// dispatch at all.
	if err := ctx.Err(); err != nil {
		return nil, err
	}

	ch := make(chan ctxResult, 1)

	if err := issue(func(r AsyncResult) {
		ch <- ctxResult{r.Value, r.Err}
	}); err != nil {
		return nil, err
	}

	select {
	case r := <-ch:
		return r.value, r.err
	case <-ctx.Done():
		// Spawn a drain goroutine so that the eventual callback
		// has somewhere to deliver its (already borrowed) result.
		//
		// The goroutine is bounded by drainTimeout. If the C
		// request never completes, the goroutine exits rather
		// than blocking forever. Any late callback that arrives
		// after the drain goroutine has exited will fill the
		// buffered channel (capacity 1) and then the channel and
		// its contents will be garbage-collected along with the
		// goroutine's stack.
		go func() {
			select {
			case r := <-ch:
				if r.value != nil {
					r.value.Close()
				}
			case <-time.After(drainTimeout):
				// The C request never produced a callback
				// within the drain window. Abandon the drain
				// goroutine; the borrowed handle (if any) will
				// be released by the framework's own lifetime
				// management, and any late callback will find
				// a channel no one is reading.
			}
		}()
		return nil, ctx.Err()
	}
}
