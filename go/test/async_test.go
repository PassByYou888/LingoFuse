package test

import (
	"bytes"
	"context"
	"errors"
	"runtime"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/PassByYou888/LingoFuse/go/lingofuse"
	"github.com/PassByYou888/LingoFuse/go/sys"
)

// ---------------------------------------------------------------------------
// Argument validation (does not require a live connection)
// ---------------------------------------------------------------------------

// TestCallAsyncNilCallbackRejected verifies that CallAsync rejects a
// nil callback BEFORE touching the native library. This makes the
// test runnable in a CI environment without the shared library.
func TestCallAsyncNilCallbackRejected(t *testing.T) {
	tgt := lingofuse.App("Calc")
	err := tgt.CallAsync("add", nil, nil)
	if err == nil {
		t.Fatalf("CallAsync with nil callback returned nil error")
	}
	var le *lingofuse.Error
	if !errors.As(err, &le) {
		t.Fatalf("CallAsync error is not *lingofuse.Error: %T", err)
	}
	if le.Code != lingofuse.ErrInvalidArgument {
		t.Fatalf("CallAsync error code = %v, want ErrInvalidArgument",
			le.Code)
	}
}

func TestCallAsyncWithTimeoutNilCallbackRejected(t *testing.T) {
	tgt := lingofuse.App("Calc")
	err := tgt.CallAsyncWithTimeout("add", nil, time.Second, nil)
	if err == nil {
		t.Fatalf("CallAsyncWithTimeout with nil callback returned nil error")
	}
	var le *lingofuse.Error
	if !errors.As(err, &le) || le.Code != lingofuse.ErrInvalidArgument {
		t.Fatalf("unexpected error: %v", err)
	}
}

func TestSequencedCallAsyncNilCallbackRejected(t *testing.T) {
	tgt := lingofuse.App("Calc")
	err := tgt.SequencedCallAsync("add", nil, nil)
	if err == nil {
		t.Fatalf("SequencedCallAsync with nil callback returned nil error")
	}
	var le *lingofuse.Error
	if !errors.As(err, &le) || le.Code != lingofuse.ErrInvalidArgument {
		t.Fatalf("unexpected error: %v", err)
	}
}

// ---------------------------------------------------------------------------
// Context-bounded calls
// ---------------------------------------------------------------------------

// TestCallCtxAlreadyCancelled verifies that a CallCtx with an
// already-cancelled context returns ctx.Err() without blocking.
//
// This test does require the native library (the payload handle is
// created before the async dispatch). It skips cleanly when the
// library is unavailable.
func TestCallCtxAlreadyCancelled(t *testing.T) {
	requireLibrary(t)

	ctx, cancel := context.WithCancel(context.Background())
	cancel() // already cancelled

	// We do NOT expect this to reach the wire: the context is
	// checked as soon as the dispatch returns and the selector
	// runs. The result is the context's error.
	//
	// Note: the call may still be dispatched to the native layer
	// before the selector fires, because dispatch is not
	// synchronous with respect to ctx. That is intentional: the
	// cancellation semantics are "stop the Go-side wait", not
	// "cancel the C-side request".
	_, err := lingofuse.App("NoSuchApp_ctx_test").
		CallCtx(ctx, "nothing", nil)

	if !errors.Is(err, context.Canceled) {
		t.Fatalf("CallCtx with cancelled ctx returned %v, want "+
			"context.Canceled", err)
	}
}

// ---------------------------------------------------------------------------
// AsyncResult semantics
// ---------------------------------------------------------------------------

// TestAsyncResultZeroValue verifies that the zero value of AsyncResult
// carries no result handle and no error. This is the value a caller
// sees when the callback has not yet fired.
func TestAsyncResultZeroValue(t *testing.T) {
	var r lingofuse.AsyncResult
	if r.Value != nil {
		t.Fatalf("zero AsyncResult has non-nil Value")
	}
	if r.Err != nil {
		t.Fatalf("zero AsyncResult has non-nil Err")
	}
}

// TestAsyncResultErrorField verifies that an error-only result
// carries the error and a nil Value, matching the documented
// contract.
func TestAsyncResultErrorField(t *testing.T) {
	sentinel := errors.New("intentional")
	r := lingofuse.AsyncResult{Err: sentinel}
	if r.Value != nil {
		t.Fatalf("error-only AsyncResult has non-nil Value")
	}
	if !errors.Is(r.Err, sentinel) {
		t.Fatalf("Err = %v, want %v", r.Err, sentinel)
	}
}

// ---------------------------------------------------------------------------
// Error code plumbing
// ---------------------------------------------------------------------------

// TestErrAsyncDispatchFailedString verifies the human-readable form
// of the new error code. This is a pure Go test.
func TestErrAsyncDispatchFailedString(t *testing.T) {
	le := &lingofuse.Error{Code: lingofuse.ErrAsyncDispatchFailed}
	got := le.Error()
	if !strings.Contains(got, "async dispatch failed") {
		t.Fatalf("Error() = %q; want it to mention 'async dispatch failed'",
			got)
	}
}

// TestErrorIsMatching verifies that errors.Is matches on the Code
// field, which is the documented contract of *lingofuse.Error.
func TestErrorIsMatching(t *testing.T) {
	original := &lingofuse.Error{Code: lingofuse.ErrTimeout, Message: "a"}
	target := &lingofuse.Error{Code: lingofuse.ErrTimeout}
	if !errors.Is(original, target) {
		t.Fatalf("errors.Is(ErrTimeout, ErrTimeout) = false")
	}
	other := &lingofuse.Error{Code: lingofuse.ErrCallFailed}
	if errors.Is(original, other) {
		t.Fatalf("errors.Is(ErrTimeout, ErrCallFailed) = true")
	}
}

// ---------------------------------------------------------------------------
// Callback panic isolation
// ---------------------------------------------------------------------------

// TestAsyncDispatchFailurePathSyncCallback exercises the synchronous
// callback path that runs when the native layer rejects a request
// before dispatch.
//
// The target App does not exist and no live connection is
// established in this process, so LF_Async_Call returns a value
// other than 1. dispatchAsync is contractually required to invoke
// the user callback synchronously with ErrAsyncDispatchFailed, on
// the caller's goroutine.
//
// This test therefore:
//
//  1. Observes that the callback fires exactly once.
//  2. Observes that it fires on the caller's goroutine.
//  3. Observes that the error code is ErrAsyncDispatchFailed.
//
// When the native library rejects the request as expected, the test
// passes. If the library were already connected and the request
// succeeded, the callback would fire later on a worker thread and
// the sentinel assertion below would fail -- which is the correct
// signal that the environment is not what this test assumes.
//
// {!!!!!  LIBRARY REQUIRED  !!!!!}
// The payload handle is created before the async dispatch, so this
// test needs the native library even though it does not need a live
// connection.
func TestAsyncDispatchFailurePathSyncCallback(t *testing.T) {
	requireLibrary(t)

	// If the process already has a live connection (e.g. because
	// another test ran Connect earlier), the dispatch may succeed,
	// and this test's synchronous-callback assumption would not
	// hold. Skip in that case: the synchronous error path is
	// exercised by the dedicated unit tests in the sys package,
	// which construct a synthetic failure.
	if lingofuse.IsConnected() {
		t.Skip("process already connected; dispatch-failure path not " +
			"reachable")
	}

	callerGoroutine := goroutineID()
	done := make(chan struct{})
	var (
		callbackRan   bool
		sameGoroutine bool
		errCode       lingofuse.ErrorCode
	)

	tgt := lingofuse.App("NoSuchApp_async_dispatch_test")
	cerr := tgt.CallAsync("nothing", nil, func(r lingofuse.AsyncResult) {
		callbackRan = true
		sameGoroutine = goroutineID() == callerGoroutine
		if r.Value != nil {
			t.Errorf("dispatch-failure callback has non-nil Value")
		}
		var le *lingofuse.Error
		if errors.As(r.Err, &le) {
			errCode = le.Code
		}
		close(done)
	})
	if cerr != nil {
		t.Fatalf("CallAsync returned error: %v", cerr)
	}

	// dispatchAsync's failure path invokes the callback
	// synchronously, so the channel must already be closed.
	select {
	case <-done:
	case <-time.After(2 * time.Second):
		t.Fatalf("dispatch-failure callback was not invoked synchronously")
	}

	if !callbackRan {
		t.Fatalf("callback did not run")
	}
	if !sameGoroutine {
		t.Fatalf("dispatch-failure callback ran on a different goroutine; " +
			"the sync-fallback contract is broken")
	}
	if errCode != lingofuse.ErrAsyncDispatchFailed {
		t.Fatalf("dispatch-failure callback err code = %v, want "+
			"ErrAsyncDispatchFailed", errCode)
	}
}

// ---------------------------------------------------------------------------
// goroutineID — a tiny helper for the sync-fallback assertion
// ---------------------------------------------------------------------------
//
// Go does not expose a public API for the current goroutine ID. We
// use a well-known runtime trick: parse the first integer out of the
// runtime.Stack header. This is only used for test assertions, never
// for production behaviour.

func goroutineID() uint64 {
	var buf [64]byte
	n := runtime.Stack(buf[:], false)
	// Format: "goroutine <id> [<state>]:\n..."
	fields := bytes.Fields(buf[:n])
	if len(fields) < 2 {
		return 0
	}
	id, err := strconv.ParseUint(string(fields[1]), 10, 64)
	if err != nil {
		return 0
	}
	return id
}

// ---------------------------------------------------------------------------
// Async dispatch on UID / P2PName targets
// ---------------------------------------------------------------------------

// TestUIDTargetCallAsyncNilCallbackRejected verifies that the UID
// target applies the same nil-callback guard as the App target.
func TestUIDTargetCallAsyncNilCallbackRejected(t *testing.T) {
	var uid sys.TP2P_UID
	tgt := lingofuse.UID(uid)
	err := tgt.CallAsync("api", nil, nil)
	if err == nil {
		t.Fatalf("UIDTarget.CallAsync with nil callback returned nil error")
	}
	var le *lingofuse.Error
	if !errors.As(err, &le) || le.Code != lingofuse.ErrInvalidArgument {
		t.Fatalf("unexpected error: %v", err)
	}
}

// TestP2PTargetCallAsyncNilCallbackRejected verifies the same for the
// P2PName target.
func TestP2PTargetCallAsyncNilCallbackRejected(t *testing.T) {
	tgt := lingofuse.P2P("g")
	err := tgt.CallAsync("api", nil, nil)
	if err == nil {
		t.Fatalf("P2PNameTarget.CallAsync with nil callback returned nil error")
	}
	var le *lingofuse.Error
	if !errors.As(err, &le) || le.Code != lingofuse.ErrInvalidArgument {
		t.Fatalf("unexpected error: %v", err)
	}
}
