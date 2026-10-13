// Command cross-node is the worker node of the cross-language demo.
//
// It connects to the coordinator at the IPC endpoint "ipc:cross" and
// registers the two Call APIs that every other language binds exposes:
//
//	add      (int32 a, int32 b)                    -> int32
//	inv_seri (uint8, uint16, uint32, uint64,
//	          string(NUL), float32)                 -> reversed
//
// {!!!!!  WIRE FORMAT IS BYTE-FOR-BYTE IDENTICAL  !!!!!}
// The Go node reads and writes exactly the same bytes as the C++, C#,
// Pascal, Rust, and JavaScript demos. All integers and floats are
// little-endian; the string is UTF-8 with a trailing NUL.
//
// There is NO JSON on the wire. The high-level WriteJSON / ReadJSON
// helpers are deliberately not used here, because the cross-language
// demo validates the raw ABI channel.
//
// {!!!!!  INTEROP  !!!!!}
// Any combination works:
//
//	C++ CrossCall.exe  -> Go cross-node   (this file)
//	Go cross-call      -> C++ CrossNode.exe
//	C# CrossCall.exe   -> Rust cross_node
//	...
//
// The only requirements are that the coordinator endpoint matches and
// the API names and wire format are agreed on -- which they are, by
// construction of the demo.
//
// Usage:
//
//	cross-node
//	cross-node -endpoint ipc:cross -app demo
//
// Press Ctrl+C to shut down.
package main

import (
	"flag"
	"fmt"
	"os"
	"os/signal"
	"syscall"

	"github.com/PassByYou888/LingoFuse/go/lingofuse"
)

const (
	// defaultEndpoint MUST match the other language demos.
	defaultEndpoint = "ipc:cross"

	// defaultAppName MUST match the other language demos.
	defaultAppName = "demo"
)

func main() {
	endpoint := flag.String("endpoint", defaultEndpoint,
		"LingoFuse endpoint of the coordinator.")
	appName := flag.String("app", defaultAppName,
		"Name of the App this node exposes.")
	flag.Parse()

	if err := run(*endpoint, *appName); err != nil {
		fmt.Fprintf(os.Stderr, "[FATAL] %v\n", err)
		os.Exit(1)
	}
}

// ---------------------------------------------------------------------------
// add(int32, int32) -> int32
// ---------------------------------------------------------------------------

// addCallback reads two little-endian int32 values and writes their
// sum as a little-endian int32. The exact byte sequence:
//
//	request : [a: 4 bytes LE] [b: 4 bytes LE]
//	response: [sum: 4 bytes LE]
func addCallback(in, out *lingofuse.DataHandle) {
	a, err := in.ReadInt32()
	if err != nil {
		fmt.Fprintln(os.Stderr, "[Node] add: failed to read parameter a")
		return
	}
	b, err := in.ReadInt32()
	if err != nil {
		fmt.Fprintln(os.Stderr, "[Node] add: failed to read parameter b")
		return
	}
	c := a + b

	fmt.Printf("[Node] add(%d, %d) = %d\n", a, b, c)

	_ = out.WriteInt32(c)
}

// ---------------------------------------------------------------------------
// inv_seri() -> reversed typed sequence
// ---------------------------------------------------------------------------

// invSeriCallback reads a fixed sequence of typed values and writes
// them back in reverse order. The exact byte sequence:
//
//	request :
//	    [b:   uint8]
//	    [w:   uint16 LE]
//	    [c:   uint32 LE]
//	    [u64: uint64 LE]
//	    [s:   UTF-8 with a trailing NUL]
//	    [f:   float32 LE]
//
//	response:
//	    [f:   float32 LE]
//	    [s:   UTF-8 with a trailing NUL]
//	    [u64: uint64 LE]
//	    [c:   uint32 LE]
//	    [w:   uint16 LE]
//	    [b:   uint8]
func invSeriCallback(in, out *lingofuse.DataHandle) {
	b, err := in.ReadUint8()
	if err != nil {
		fmt.Fprintln(os.Stderr, "[Node] inv_seri: failed to read b")
		return
	}
	w, err := in.ReadUint16()
	if err != nil {
		fmt.Fprintln(os.Stderr, "[Node] inv_seri: failed to read w")
		return
	}
	c, err := in.ReadUint32()
	if err != nil {
		fmt.Fprintln(os.Stderr, "[Node] inv_seri: failed to read c")
		return
	}
	u64, err := in.ReadUint64()
	if err != nil {
		fmt.Fprintln(os.Stderr, "[Node] inv_seri: failed to read u64")
		return
	}
	s, err := in.ReadString()
	if err != nil {
		fmt.Fprintln(os.Stderr, "[Node] inv_seri: failed to read s")
		return
	}
	f, err := in.ReadSingle()
	if err != nil {
		fmt.Fprintln(os.Stderr, "[Node] inv_seri: failed to read f")
		return
	}

	fmt.Printf(
		"[Node] inv_seri received: [%d, %d, %d, %d, %q, %v]\n",
		b, w, c, u64, s, f,
	)

	// Reply in reverse order, matching CrossNode.cpp exactly.
	_ = out.WriteSingle(f)
	_ = out.WriteString(s)
	_ = out.WriteUint64(u64)
	_ = out.WriteUint32(c)
	_ = out.WriteUint16(w)
	_ = out.WriteUint8(b)

	fmt.Printf(
		"[Node] inv_seri replied:  [%v, %q, %d, %d, %d, %d]\n",
		f, s, u64, c, w, b,
	)
}

// ---------------------------------------------------------------------------
// Startup
// ---------------------------------------------------------------------------

func run(endpoint, appName string) error {
	fmt.Println("=== Cross Node (Worker) ===")

	if err := lingofuse.SetOptQuiet(true); err != nil {
		return fmt.Errorf("SetOptQuiet: %w", err)
	}
	// The node is a client. When multiple nodes run against the same
	// coordinator from the same host, they must not collide on the
	// local endpoint; Overlap_Connection allows multiple client
	// tunnels per physical address.
	if err := lingofuse.SetOptOverlapConnection(true); err != nil {
		return fmt.Errorf("SetOptOverlapConnection: %w", err)
	}
	// Deployment mode: do not block PrepareDone waiting for the
	// coordinator. The node may start before the coordinator is up.
	if err := lingofuse.SetOptWaitConnectionReadyOk(false); err != nil {
		return fmt.Errorf("SetOptWaitConnectionReadyOk: %w", err)
	}

	// Register the APIs BEFORE preparing the client, so the App is
	// visible on the mesh the moment the client comes online.
	app, err := lingofuse.NewAppHandle(appName, "Go worker node")
	if err != nil {
		return fmt.Errorf("NewAppHandle: %w", err)
	}
	defer app.Close()

	if err := app.RegisterCall("add",
		"add(int a, int b) -> int", addCallback); err != nil {
		return fmt.Errorf("RegisterCall(add): %w", err)
	}
	if err := app.RegisterCall("inv_seri",
		"inv_seri() -> reversed typed sequence",
		invSeriCallback); err != nil {
		return fmt.Errorf("RegisterCall(inv_seri): %w", err)
	}

	if err := lingofuse.ResetPrepare(); err != nil {
		return fmt.Errorf("ResetPrepare: %w", err)
	}
	if _, err := lingofuse.PrepareClient(endpoint, app); err != nil {
		return fmt.Errorf("PrepareClient: %w", err)
	}

	ok, err := lingofuse.PrepareDone()
	if err != nil {
		return fmt.Errorf("PrepareDone: %w", err)
	}
	if !ok {
		active, _ := lingofuse.CheckMainThread()
		if !active {
			return fmt.Errorf(
				"PrepareDone returned false and the main thread " +
					"is not running")
		}
	}

	fmt.Printf(
		"[Node] Registered APIs 'add' and 'inv_seri' under "+
			"application '%s'.\n", appName)
	fmt.Println("[Node] Online. Press Ctrl+C to exit...")

	sigCh := make(chan os.Signal, 1)
	signal.Notify(sigCh, os.Interrupt, syscall.SIGTERM)
	<-sigCh

	fmt.Println("\n[Node] Shutting down...")
	if err := lingofuse.ExitMainThread(); err != nil {
		fmt.Fprintf(os.Stderr, "[Node] ExitMainThread: %v\n", err)
	}
	if err := lingofuse.Shutdown(); err != nil {
		return fmt.Errorf("Shutdown: %w", err)
	}
	fmt.Println("[Node] Bye.")
	return nil
}
