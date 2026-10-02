package test

import (
	"fmt"
	"os"
	"sync/atomic"
	"testing"
	"time"

	"github.com/PassByYou888/LingoFuse/go/lingofuse"
)

// uniqueEndpoint builds a process-unique IPC endpoint name. The
// nanosecond timestamp separates rapid successive runs; the PID
// separates concurrent test invocations.
func uniqueEndpoint(prefix string) string {
	return fmt.Sprintf("ipc:%s_%d_%d", prefix, os.Getpid(), time.Now().UnixNano())
}

// setupFramework prepares a self-connected service + client with a
// single App, then starts the framework. The returned cleanup runs in
// the order documented for the native layer:
//
//	ExitMainThread -> app.Close -> Shutdown
func setupFramework(t *testing.T, appName string) *lingofuse.AppHandle {
	t.Helper()
	ensureLib(t)

	set := func(name, value string) {
		t.Helper()
		if err := lingofuse.SetOption(name, value); err != nil {
			t.Fatalf("SetOption(%s=%s): %v", name, value, err)
		}
	}
	set("Overlap_Connection", "True")
	set("Wait_Connection_ReadyOk", "False")
	set("Quiet", "True")

	if err := lingofuse.ResetPrepare(); err != nil {
		t.Fatalf("ResetPrepare: %v", err)
	}

	app, err := lingofuse.NewAppHandle(appName, "Go e2e test")
	if err != nil {
		t.Fatalf("NewAppHandle: %v", err)
	}

	endpoint := uniqueEndpoint("go_e2e")
	if _, err := lingofuse.PrepareService(endpoint, endpoint); err != nil {
		app.Close()
		t.Fatalf("PrepareService: %v", err)
	}
	if _, err := lingofuse.PrepareClient(endpoint, app); err != nil {
		app.Close()
		t.Fatalf("PrepareClient: %v", err)
	}

	ok, err := lingofuse.PrepareDone()
	if err != nil {
		app.Close()
		t.Fatalf("PrepareDone: %v", err)
	}
	if !ok {
		app.Close()
		t.Fatal("PrepareDone returned false")
	}

	t.Cleanup(func() {
		_ = lingofuse.ExitMainThread()
		app.Close()
		_ = lingofuse.Shutdown()
	})

	return app
}

// ---------------------------------------------------------------------------
// Test 1 — LocalCall round-trip
// ---------------------------------------------------------------------------

func TestE2E_LocalCallRoundtrip(t *testing.T) {
	app := setupFramework(t, "GoE2ELocalCall")

	type addArgs struct {
		A int `json:"a"`
		B int `json:"b"`
	}
	type addResult struct {
		Sum int `json:"sum"`
	}

	err := app.RegisterCall("add", "add two ints",
		func(input, output *lingofuse.DataHandle) {
			var args addArgs
			if err := lingofuse.ReadJSON(input, &args); err != nil {
				return
			}
			_ = lingofuse.WriteJSON(output, addResult{Sum: args.A + args.B})
		})
	if err != nil {
		t.Fatalf("RegisterCall: %v", err)
	}

	req, err := lingofuse.NewDataHandle("add")
	if err != nil {
		t.Fatal(err)
	}
	defer req.Close()

	if err := lingofuse.WriteJSON(req, addArgs{A: 40, B: 2}); err != nil {
		t.Fatal(err)
	}
	if err := req.SetPosition(0); err != nil {
		t.Fatal(err)
	}

	res, err := app.LocalCall(req)
	if err != nil {
		t.Fatalf("LocalCall: %v", err)
	}
	defer res.Close()

	sz, err := res.Size()
	if err != nil {
		t.Fatal(err)
	}
	if sz == 0 {
		t.Fatal("empty response")
	}

	var out addResult
	if err := lingofuse.ReadJSON(res, &out); err != nil {
		t.Fatal(err)
	}
	if out.Sum != 42 {
		t.Fatalf("sum = %d, want 42", out.Sum)
	}
}

// ---------------------------------------------------------------------------
// Test 2 — Notify delivery
// ---------------------------------------------------------------------------

func TestE2E_NotifyDelivered(t *testing.T) {
	app := setupFramework(t, "GoE2ENotify")

	var counter atomic.Int32
	err := app.RegisterNotify("log", "increment",
		func(input *lingofuse.DataHandle) {
			counter.Add(1)
		})
	if err != nil {
		t.Fatalf("RegisterNotify: %v", err)
	}

	req, err := lingofuse.NewDataHandle("log")
	if err != nil {
		t.Fatal(err)
	}
	defer req.Close()

	if err := lingofuse.WriteJSON(req, map[string]string{"msg": "hello"}); err != nil {
		t.Fatal(err)
	}
	if err := req.SetPosition(0); err != nil {
		t.Fatal(err)
	}

	if err := app.LocalNotify(req); err != nil {
		t.Fatalf("LocalNotify: %v", err)
	}
	if got := counter.Load(); got != 1 {
		t.Fatalf("counter = %d, want 1", got)
	}
}

// ---------------------------------------------------------------------------
// Test 3 — callback panic isolation
// ---------------------------------------------------------------------------

func TestE2E_CallbackPanicIsolation(t *testing.T) {
	app := setupFramework(t, "GoE2EPanic")

	err := app.RegisterCall("boom", "always panics",
		func(input, output *lingofuse.DataHandle) {
			panic("intentional panic for test")
		})
	if err != nil {
		t.Fatalf("RegisterCall: %v", err)
	}

	req, err := lingofuse.NewDataHandle("boom")
	if err != nil {
		t.Fatal(err)
	}
	defer req.Close()

	if err := req.WriteBytes([]byte{0}); err != nil {
		t.Fatal(err)
	}
	if err := req.SetPosition(0); err != nil {
		t.Fatal(err)
	}

	// The trampoline catches the panic; the response is empty and
	// the process survives.
	res, err := app.LocalCall(req)
	if err != nil {
		t.Fatalf("LocalCall: %v", err)
	}
	defer res.Close()

	sz, err := res.Size()
	if err != nil {
		t.Fatal(err)
	}
	if sz != 0 {
		t.Fatalf("size = %d, want 0", sz)
	}
}

// ---------------------------------------------------------------------------
// Test 4 — TryCall to an absent app
// ---------------------------------------------------------------------------

func TestE2E_TryCallToAbsentApp(t *testing.T) {
	ensureLib(t)

	if err := lingofuse.SetOption("Wait_Connection_ReadyOk", "False"); err != nil {
		t.Fatal(err)
	}
	if err := lingofuse.SetOption("Quiet", "True"); err != nil {
		t.Fatal(err)
	}
	if err := lingofuse.ResetPrepare(); err != nil {
		t.Fatal(err)
	}

	endpoint := uniqueEndpoint("go_e2e_absent")
	if _, err := lingofuse.PrepareService(endpoint, endpoint); err != nil {
		t.Fatalf("PrepareService: %v", err)
	}
	if _, err := lingofuse.PrepareClient(endpoint, nil); err != nil {
		t.Fatalf("PrepareClient: %v", err)
	}
	ok, err := lingofuse.PrepareDone()
	if err != nil {
		t.Fatalf("PrepareDone: %v", err)
	}
	if !ok {
		t.Fatal("PrepareDone returned false")
	}

	t.Cleanup(func() {
		_ = lingofuse.ExitMainThread()
		_ = lingofuse.Shutdown()
	})

	req, err := lingofuse.NewDataHandle("nonexistent")
	if err != nil {
		t.Fatal(err)
	}
	defer req.Close()

	if err := req.WriteBytes([]byte("{}")); err != nil {
		t.Fatal(err)
	}
	if err := req.SetPosition(0); err != nil {
		t.Fatal(err)
	}

	res, got, err := lingofuse.TryCall(
		"__definitely_absent_go_e2e__", req, 1000)
	if err != nil {
		t.Fatalf("TryCall: %v", err)
	}
	if got || res != nil {
		t.Fatalf("TryCall should return (nil, false, nil); got (%v, %v)",
			res, got)
	}
}

// ---------------------------------------------------------------------------
// Test 5 — Shutdown is idempotent
// ---------------------------------------------------------------------------

func TestE2E_ShutdownIdempotent(t *testing.T) {
	ensureLib(t)

	if err := lingofuse.Shutdown(); err != nil {
		t.Fatal(err)
	}
	if err := lingofuse.Shutdown(); err != nil {
		t.Fatal(err)
	}
}
