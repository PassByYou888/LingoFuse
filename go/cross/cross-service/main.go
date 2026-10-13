// Command cross-service is the coordinator of the cross-language demo.
//
// It creates the IPC endpoint "ipc:cross" and holds the mesh together.
// It does NOT register any business API and does NOT create a client;
// its sole purpose is to be the discovery anchor that nodes and callers
// connect to.
//
// The default endpoint matches the C++, C#, Pascal, Rust, and
// JavaScript counterparts, so any language can play any role.
//
// Usage:
//
//	cross-service
//	cross-service -endpoint ipc:cross_alt
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

// defaultEndpoint is the IPC endpoint name. It MUST match the other
// language demos (C++ CrossService.cpp, C# CrossService.cs, Rust
// cross_service.rs, JS cross-service.js).
const defaultEndpoint = "ipc:cross"

func main() {
	endpoint := flag.String("endpoint", defaultEndpoint,
		"LingoFuse endpoint to listen on. Accepts TCP (host:port) "+
			"or IPC (ipc:name) forms.")
	flag.Parse()

	if err := run(*endpoint); err != nil {
		fmt.Fprintf(os.Stderr, "[FATAL] %v\n", err)
		os.Exit(1)
	}
}

func run(endpoint string) error {
	fmt.Println("=== Cross Service (Coordinator) ===")

	// Match the C++/C#/Rust/JS options exactly.
	if err := lingofuse.SetOptQuiet(true); err != nil {
		return fmt.Errorf("SetOptQuiet: %w", err)
	}
	if err := lingofuse.SetOptWaitConnectionReadyOk(true); err != nil {
		return fmt.Errorf("SetOptWaitConnectionReadyOk: %w", err)
	}
	if err := lingofuse.SetOptOverlapConnection(true); err != nil {
		return fmt.Errorf("SetOptOverlapConnection: %w", err)
	}
	if err := lingofuse.SetOptWaitConnectionTimeout(10000); err != nil {
		return fmt.Errorf("SetOptWaitConnectionTimeout: %w", err)
	}

	if err := lingofuse.ResetPrepare(); err != nil {
		return fmt.Errorf("ResetPrepare: %w", err)
	}

	tag, err := lingofuse.PrepareService(endpoint, endpoint)
	if err != nil {
		return fmt.Errorf("PrepareService: %w", err)
	}
	fmt.Printf("[Service] Prepared service endpoint %s (tag=%d).\n",
		endpoint, tag)

	ok, err := lingofuse.PrepareDone()
	if err != nil {
		return fmt.Errorf("PrepareDone: %w", err)
	}
	if !ok {
		// A second PrepareDone returns false without error. Accept
		// that as long as the main thread is genuinely running.
		active, _ := lingofuse.CheckMainThread()
		if !active {
			return fmt.Errorf(
				"PrepareDone returned false and the main thread " +
					"is not running")
		}
	}

	fmt.Printf("[Service] IPC service '%s' is running. "+
		"Press Ctrl+C to exit...\n", endpoint)

	sigCh := make(chan os.Signal, 1)
	signal.Notify(sigCh, os.Interrupt, syscall.SIGTERM)
	<-sigCh

	fmt.Println("\n[Service] Shutting down...")

	if err := lingofuse.ExitMainThread(); err != nil {
		fmt.Fprintf(os.Stderr, "[Service] ExitMainThread: %v\n", err)
	}
	if err := lingofuse.Shutdown(); err != nil {
		return fmt.Errorf("Shutdown: %w", err)
	}

	fmt.Println("[Service] Bye.")
	return nil
}
