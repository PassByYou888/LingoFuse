// =============================================================================
//  main.go
// -----------------------------------------------------------------------------
//  Worker node that registers the "add" and "inv_seri" Call APIs.
//
//  Go port of CrossNode.cpp / CrossNode.cs / cross-node.js /
//  cross_node.lpr. Wire format is byte-for-byte identical to every
//  other LingoFuse binding:
//
//    add       (int32 a, int32 b)                       -> int32
//        Reads two 32-bit signed integers (little-endian) and writes
//        their sum.
//
//    inv_seri  (uint8, uint16, uint32, uint64,
//               string(NUL), float)                      -> same types reversed
//        Reads a fixed sequence of typed values and echoes them back
//        in reverse order. Used to exercise the binary wire format.
//
//  A Go CrossNode is directly interoperable with a C++ / C# / Pascal
//  / Python / JS CrossCall client, and vice versa.
//
//  Startup:
//      1. Start the coordinator first (any language).
//      2. Run this program. It connects as a client, exposes "demo",
//         and waits for Enter.
//      3. Run one or more callers (any language).
//
//  The two APIs MUST be registered before PrepareClient because the
//  Init_App_Info broadcast carries the API list as a snapshot.
//
//  Cleanup order (matching Pascal LF-CLEAN-001):
//      ExitMainThread  ->  app.Close  ->  Shutdown
//
//  All operations are idempotent.
// =============================================================================

package main

import (
	"bufio"
	"fmt"
	"os"
	"strconv"
	"sync"

	"github.com/PassByYou888/LingoFuse/go/lingofuse"
)

const (
	endpoint = "ipc:cross"
	appName  = "demo"
)

// logMu serialises multi-line output from the native callback
// worker threads. fmt.Printf to os.Stdout is atomic for small
// writes on all supported platforms, but the mutex makes the
// guarantee explicit and keeps output readable.
var logMu sync.Mutex

func logf(format string, args ...any) {
	logMu.Lock()
	fmt.Printf(format, args...)
	logMu.Unlock()
}

func main() {
	fmt.Println("=== Cross Node (Worker, Go) ===")

	if err := run(); err != nil {
		fmt.Fprintf(os.Stderr, "[FATAL] %v\n", err)
		os.Exit(1)
	}
	fmt.Println("[Node] Bye.")
}

func run() error {
	// Deployment mode: do not block PrepareDone waiting for the
	// service endpoint. The node can start before the coordinator; it
	// connects automatically once the endpoint becomes reachable.
	if err := lingofuse.SetOption("Wait_Ready", "False"); err != nil {
		return err
	}
	if err := lingofuse.SetOption("Overlap_Connection", "True"); err != nil {
		return err
	}

	if err := lingofuse.ResetPrepare(); err != nil {
		return err
	}

	app, err := lingofuse.NewAppHandle(appName, "Go worker node (ABI wire format)")
	if err != nil {
		return fmt.Errorf("NewAppHandle: %w", err)
	}

	// Cleanup runs on every exit path. The framework teardown is
	// idempotent, so calling it unconditionally is safe.
	defer func() {
		_ = lingofuse.ExitMainThread()
		app.Close()
		_ = lingofuse.Shutdown()
	}()

	// Register the two Call APIs. Registration MUST complete before
	// PrepareClient so the Init_App_Info broadcast carries the API
	// list.
	if err := app.RegisterCall("add",
		"add(int a, int b) -> int", handleAdd); err != nil {
		return fmt.Errorf("RegisterCall(add): %w", err)
	}
	if err := app.RegisterCall("inv_seri",
		"inv_seri() -> reversed typed sequence", handleInvSeri); err != nil {
		return fmt.Errorf("RegisterCall(inv_seri): %w", err)
	}

	// Connect to the coordinator as a client and expose "demo".
	if _, err := lingofuse.PrepareClient(endpoint, app); err != nil {
		return fmt.Errorf("PrepareClient(%q): %w", endpoint, err)
	}

	// Start the framework.
	started, err := lingofuse.PrepareDone()
	if err != nil {
		return fmt.Errorf("PrepareDone: %w", err)
	}
	if !started {
		return fmt.Errorf("PrepareDone returned false")
	}

	fmt.Printf("[Node] Registered APIs 'add' and 'inv_seri' under application '%s'.\n",
		appName)
	fmt.Println("[Node] Online. Press Enter to exit...")

	reader := bufio.NewReader(os.Stdin)
	_, _ = reader.ReadString('\n')

	fmt.Println("[Node] Shutting down...")
	return nil
}

// -----------------------------------------------------------------------------
//  Callbacks
// -----------------------------------------------------------------------------
//  Callbacks execute on native worker threads. Inside them:
//    - DO NOT block.
//    - DO NOT call any blocking LingoFuse function (Call, LocalCall,
//      PrepareDone, Shutdown) — deadlock risk.
//    - DO NOT close the borrowed input / output handles.
// -----------------------------------------------------------------------------

// handleAdd implements add(int32, int32) -> int32.
func handleAdd(input, output *lingofuse.DataHandle) {
	a, err := input.ReadInt32()
	if err != nil {
		logf("[Node] add: failed to read first int32: %v\n", err)
		return
	}
	b, err := input.ReadInt32()
	if err != nil {
		logf("[Node] add: failed to read second int32: %v\n", err)
		return
	}
	c := a + b
	logf("[Node] add(%d, %d) = %d\n", a, b, c)
	if err := output.WriteInt32(c); err != nil {
		logf("[Node] add: write failed: %v\n", err)
	}
}

// handleInvSeri implements inv_seri -> reversed typed sequence.
func handleInvSeri(input, output *lingofuse.DataHandle) {
	b, err := input.ReadUint8()
	if err != nil {
		logf("[Node] inv_seri: read uint8: %v\n", err)
		return
	}
	w, err := input.ReadUint16()
	if err != nil {
		logf("[Node] inv_seri: read uint16: %v\n", err)
		return
	}
	c, err := input.ReadUint32()
	if err != nil {
		logf("[Node] inv_seri: read uint32: %v\n", err)
		return
	}
	u64, err := input.ReadUint64()
	if err != nil {
		logf("[Node] inv_seri: read uint64: %v\n", err)
		return
	}
	s, err := input.ReadString()
	if err != nil {
		logf("[Node] inv_seri: read string: %v\n", err)
		return
	}
	f, err := input.ReadSingle()
	if err != nil {
		logf("[Node] inv_seri: read single: %v\n", err)
		return
	}

	logf("[Node] inv_seri received: [%d, %d, %d, %d, \"%s\", %s]\n",
		b, w, c, u64, s, formatFloat32(f))

	// Reply in reverse field order, matching CrossNode.cpp.
	if err := output.WriteSingle(f); err != nil {
		logf("[Node] inv_seri: write single: %v\n", err)
		return
	}
	if err := output.WriteString(s); err != nil {
		logf("[Node] inv_seri: write string: %v\n", err)
		return
	}
	if err := output.WriteUint64(u64); err != nil {
		logf("[Node] inv_seri: write uint64: %v\n", err)
		return
	}
	if err := output.WriteUint32(c); err != nil {
		logf("[Node] inv_seri: write uint32: %v\n", err)
		return
	}
	if err := output.WriteUint16(w); err != nil {
		logf("[Node] inv_seri: write uint16: %v\n", err)
		return
	}
	if err := output.WriteUint8(b); err != nil {
		logf("[Node] inv_seri: write uint8: %v\n", err)
		return
	}

	logf("[Node] inv_seri replied:  [%s, \"%s\", %d, %d, %d, %d]\n",
		formatFloat32(f), s, u64, c, w, b)
}

// formatFloat32 matches the C++ std::ostream default: six significant
// digits, no trailing zeros.
func formatFloat32(v float32) string {
	return strconv.FormatFloat(float64(v), 'g', 6, 32)
}
