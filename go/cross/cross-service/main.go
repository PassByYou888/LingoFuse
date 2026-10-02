// =============================================================================
//  main.go
// -----------------------------------------------------------------------------
//  Coordinator process for the IPC endpoint "ipc:cross".
//
//  Go port of CrossService.cpp / CrossService.cs / cross-service.js /
//  cross_service.lpr. Behaviour is identical:
//
//    1. Load the native LingoFuse library (lazily).
//    2. Configure the same deployment options as the other languages.
//    3. Create the IPC service endpoint "ipc:cross".
//    4. Prepare a self-connected client so the C4 mesh has at least
//       one physical tunnel to anchor the broadcast loop.
//    5. Start the framework.
//    6. Wait for Enter.
//    7. Shut down in the LF-CLEAN-001 order.
//
//  Any mix of language runtimes (C++ / C# / Pascal / Python / JS / Go)
//  can participate in the same mesh because the endpoint name, the
//  options, and the shutdown sequence all match.
//
//  Cleanup order (matching Pascal LF-CLEAN-001):
//      ExitMainThread  ->  Shutdown
//
//  Both operations are idempotent; the deferred call runs them on
//  every exit path (normal return, early return, or a panic unwinding
//  through run()).
// =============================================================================

package main

import (
	"bufio"
	"fmt"
	"os"

	"github.com/PassByYou888/LingoFuse/go/lingofuse"
)

const endpoint = "ipc:cross"

func main() {
	fmt.Println("=== Cross Service (Coordinator, Go) ===")

	if err := run(); err != nil {
		fmt.Fprintf(os.Stderr, "[FATAL] %v\n", err)
		os.Exit(1)
	}
	fmt.Println("[Service] Bye.")
}

func run() error {
	// Deployment options, identical to the C++ / C# / Pascal / JS
	// demos.
	if err := lingofuse.SetOption("Wait_Connection_ReadyOk", "True"); err != nil {
		return err
	}
	if err := lingofuse.SetOption("Overlap_Connection", "True"); err != nil {
		return err
	}
	if err := lingofuse.SetOption("Wait_Connection_Timeout", "10000"); err != nil {
		return err
	}

	if err := lingofuse.ResetPrepare(); err != nil {
		return err
	}

	// Deferred cleanup. Both operations are idempotent, so calling
	// them unconditionally is safe even when startup fails partway
	// through.
	defer func() {
		_ = lingofuse.ExitMainThread()
		_ = lingofuse.Shutdown()
	}()

	// 1. Create the IPC service endpoint.
	tag, err := lingofuse.PrepareService(endpoint, endpoint)
	if err != nil {
		return fmt.Errorf("PrepareService(%q): %w", endpoint, err)
	}
	fmt.Printf("[Service] Prepared service endpoint %s (tag=%d).\n", endpoint, tag)

	// 2. Prepare a client with no application. This gives the mesh at
	//    least one physical tunnel at the coordinator itself, which
	//    the C4 broadcast loop needs to make the endpoint reachable
	//    by other processes.
	clientTag, err := lingofuse.PrepareClient(endpoint, nil)
	if err != nil {
		return fmt.Errorf("PrepareClient(%q): %w", endpoint, err)
	}
	fmt.Printf("[Service] Prepared client tunnel (tag=%d).\n", clientTag)

	// 3. Start the framework.
	started, err := lingofuse.PrepareDone()
	if err != nil {
		return fmt.Errorf("PrepareDone: %w", err)
	}
	if !started {
		return fmt.Errorf("PrepareDone returned false")
	}

	fmt.Printf("[Service] IPC service '%s' is running. Press Enter to exit...\n",
		endpoint)

	// 4. Idle until the user presses Enter.
	reader := bufio.NewReader(os.Stdin)
	_, _ = reader.ReadString('\n')

	fmt.Println("[Service] Shutting down...")
	return nil
}
