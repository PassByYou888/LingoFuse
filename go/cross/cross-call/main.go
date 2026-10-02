// =============================================================================
//  main.go
// -----------------------------------------------------------------------------
//  Concurrent load tester for the "ipc:cross" endpoint.
//
//  Go port of CrossCall.cpp / CrossCall.cs / cross-call.js /
//  cross_call.lpr. It connects as a pure consumer (no application is
//  exposed) and spawns several goroutines. Each goroutine repeatedly
//  invokes one of two remote APIs on the "demo" application at random:
//
//    add       (int32 a, int32 b)                       -> int32
//    inv_seri  (uint8, uint16, uint32, uint64,
//               string(NUL), float)                      -> reversed types
//
//  Both APIs use the raw ABI channel. No JSON is involved at any
//  point. Every byte written matches what the C++ / C# / Pascal /
//  Python / JS clients write for the same logical call, so this
//  program can drive a node written in any of those languages.
//
//  Log sampling:
//      With 32 goroutines and a 1 ms pause, the process issues tens of
//      thousands of calls per second. Printing every call would make
//      the log I/O itself the bottleneck. Each worker therefore only
//      logs one out of every logEveryNthCall iterations; the aggregate
//      counters remain exact.
//
//  Cleanup order (matching Pascal LF-CLEAN-001):
//      ExitMainThread  ->  Shutdown
//
//  Both operations are idempotent; the deferred call runs them on
//  every exit path.
// =============================================================================

package main

import (
	"bufio"
	"fmt"
	"math/rand"
	"os"
	"strconv"
	"sync"
	"sync/atomic"
	"time"

	"github.com/PassByYou888/LingoFuse/go/lingofuse"
)

// -----------------------------------------------------------------------------
//  Configuration (must match the other language demos)
// -----------------------------------------------------------------------------

const (
	targetApp = "demo"
	endpoint  = "ipc:cross"

	workerThreads   = 32
	testSeconds     = 10
	callTimeoutMs   = 1000
	pauseMs         = 1
	logEveryNthCall = 5000

	numberMin = 1
	numberMax = 1000
)

// -----------------------------------------------------------------------------
//  Thread-safe line output
// -----------------------------------------------------------------------------

var logMu sync.Mutex

func logf(format string, args ...any) {
	logMu.Lock()
	fmt.Printf(format, args...)
	logMu.Unlock()
}

// -----------------------------------------------------------------------------
//  Aggregate statistics
// -----------------------------------------------------------------------------

type stats struct {
	totalCalls   atomic.Int64
	successCalls atomic.Int64
	failedCalls  atomic.Int64
	addCalls     atomic.Int64
	invSeriCalls atomic.Int64
}

// -----------------------------------------------------------------------------
//  main
// -----------------------------------------------------------------------------

func main() {
	fmt.Println("=== Cross Call (Client, Go) ===")
	if err := run(); err != nil {
		fmt.Fprintf(os.Stderr, "[FATAL] %v\n", err)
		os.Exit(1)
	}
	fmt.Println("[Call] Bye.")
}

func run() error {
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

	defer func() {
		_ = lingofuse.ExitMainThread()
		_ = lingofuse.Shutdown()
	}()

	// Pure consumer: no application is exposed.
	if _, err := lingofuse.PrepareClient(endpoint, nil); err != nil {
		return fmt.Errorf("PrepareClient(%q): %w", endpoint, err)
	}

	started, err := lingofuse.PrepareDone()
	if err != nil {
		return fmt.Errorf("PrepareDone: %w", err)
	}
	if !started {
		return fmt.Errorf("PrepareDone returned false")
	}

	fmt.Printf("[Call] Connected to %s. Starting %d-second load test with %d goroutines...\n",
		endpoint, testSeconds, workerThreads)

	var st stats
	var stop atomic.Bool

	startTime := time.Now()

	var wg sync.WaitGroup
	wg.Add(workerThreads)
	for i := 0; i < workerThreads; i++ {
		go func(idx int) {
			defer wg.Done()
			worker(idx, &stop, &st)
		}(i)
	}

	time.Sleep(testSeconds * time.Second)
	stop.Store(true)
	wg.Wait()

	elapsed := time.Since(startTime).Seconds()

	total := st.totalCalls.Load()
	success := st.successCalls.Load()
	failed := st.failedCalls.Load()
	addCalls := st.addCalls.Load()
	invSeriCalls := st.invSeriCalls.Load()

	successRate := 0.0
	if total > 0 {
		successRate = 100.0 * float64(success) / float64(total)
	}
	throughput := 0.0
	if elapsed > 0 {
		throughput = float64(total) / elapsed
	}
	successThroughput := 0.0
	if elapsed > 0 {
		successThroughput = float64(success) / elapsed
	}

	fmt.Println()
	fmt.Println("[Call] Load test summary")
	fmt.Printf("         duration          : %.3f s\n", elapsed)
	fmt.Printf("         total calls       : %d\n", total)
	fmt.Printf("         success           : %d (%.2f %%)\n", success, successRate)
	fmt.Printf("         failed            : %d\n", failed)
	fmt.Printf("         add calls         : %d\n", addCalls)
	fmt.Printf("         inv_seri calls    : %d\n", invSeriCalls)
	fmt.Printf("         throughput        : %.2f calls/s\n", throughput)
	fmt.Printf("         success throughput: %.2f calls/s\n", successThroughput)

	fmt.Println("[Call] Press Enter to exit...")
	reader := bufio.NewReader(os.Stdin)
	_, _ = reader.ReadString('\n')

	return nil
}

// -----------------------------------------------------------------------------
//  Worker body
// -----------------------------------------------------------------------------

func worker(idx int, stop *atomic.Bool, st *stats) {
	// Per-goroutine rand source: safer than the global source under
	// concurrency (Go 1.20+ auto-seeds the global source, but explicit
	// per-goroutine seeding removes any doubt).
	rng := rand.New(rand.NewSource(time.Now().UnixNano() ^ int64(idx)))

	iter := int64(0)
	for !stop.Load() {
		iter++
		doLog := (iter % logEveryNthCall) == 0

		if rng.Intn(2) == 0 {
			// ---- add ----
			a := numberMin + rng.Intn(numberMax-numberMin+1)
			b := numberMin + rng.Intn(numberMax-numberMin+1)
			sum, ok := remoteAdd(int32(a), int32(b))

			st.totalCalls.Add(1)
			st.addCalls.Add(1)
			if ok {
				st.successCalls.Add(1)
				if doLog {
					logf("[Call %d] add(%d, %d) = %d\n", idx, a, b, sum)
				}
			} else {
				st.failedCalls.Add(1)
				if doLog {
					logf("[Call %d] add(%d, %d) timed out or failed.\n", idx, a, b)
				}
			}
		} else {
			// ---- inv_seri ----
			text, ok := remoteInvSeri()

			st.totalCalls.Add(1)
			st.invSeriCalls.Add(1)
			if ok {
				st.successCalls.Add(1)
				if doLog {
					logf("[Call %d] %s\n", idx, text)
				}
			} else {
				st.failedCalls.Add(1)
				if doLog {
					logf("[Call %d] inv_seri timed out or failed.\n", idx)
				}
			}
		}

		if pauseMs > 0 {
			time.Sleep(time.Duration(pauseMs) * time.Millisecond)
		}
	}
}

// -----------------------------------------------------------------------------
//  Remote call wrappers — raw ABI
// -----------------------------------------------------------------------------

// remoteAdd invokes the remote "add" API.
//
// Request : int32 (little-endian) + int32 (little-endian)
// Reply   : int32 (little-endian)
func remoteAdd(a, b int32) (int32, bool) {
	param, err := lingofuse.NewDataHandle("add")
	if err != nil {
		return 0, false
	}
	defer param.Close()

	if err := param.WriteInt32(a); err != nil {
		return 0, false
	}
	if err := param.WriteInt32(b); err != nil {
		return 0, false
	}

	res, ok, err := lingofuse.TryCall(targetApp, param, callTimeoutMs)
	if err != nil || !ok || res == nil {
		return 0, false
	}
	defer res.Close()

	sum, err := res.ReadInt32()
	if err != nil {
		return 0, false
	}
	return sum, true
}

// remoteInvSeri invokes the remote "inv_seri" API.
//
// Request : uint8, uint16, uint32, uint64, string(NUL), float
// Reply   : float, string(NUL), uint64, uint32, uint16, uint8
//
// Same constants as the C++ / C# / Pascal / JS counterparts.
func remoteInvSeri() (string, bool) {
	const (
		b   uint8   = 200
		w   uint16  = 0x10
		c   uint32  = 0x2F
		u64 uint64  = 0x3F
		s           = "hello world"
		f   float32 = 3.14
	)

	param, err := lingofuse.NewDataHandle("inv_seri")
	if err != nil {
		return "", false
	}
	defer param.Close()

	if err := param.WriteUint8(b); err != nil {
		return "", false
	}
	if err := param.WriteUint16(w); err != nil {
		return "", false
	}
	if err := param.WriteUint32(c); err != nil {
		return "", false
	}
	if err := param.WriteUint64(u64); err != nil {
		return "", false
	}
	if err := param.WriteString(s); err != nil {
		return "", false
	}
	if err := param.WriteSingle(f); err != nil {
		return "", false
	}

	res, ok, err := lingofuse.TryCall(targetApp, param, callTimeoutMs)
	if err != nil || !ok || res == nil {
		return "", false
	}
	defer res.Close()

	// Read the reply fields in the reverse order the node wrote them.
	rf, err := res.ReadSingle()
	if err != nil {
		return "", false
	}
	rs, err := res.ReadString()
	if err != nil {
		return "", false
	}
	ru64, err := res.ReadUint64()
	if err != nil {
		return "", false
	}
	rc, err := res.ReadUint32()
	if err != nil {
		return "", false
	}
	rw, err := res.ReadUint16()
	if err != nil {
		return "", false
	}
	rb, err := res.ReadUint8()
	if err != nil {
		return "", false
	}

	return fmt.Sprintf(
		"reply: [%d, %d, %d, %d, \"%s\", %s]  original: [%d, %d, %d, %d, \"%s\", %s]",
		rb, rw, rc, ru64, rs, formatFloat32(rf),
		b, w, c, u64, s, formatFloat32(f),
	), true
}

// formatFloat32 matches the C++ std::ostream default: six significant
// digits, no trailing zeros.
func formatFloat32(v float32) string {
	return strconv.FormatFloat(float64(v), 'g', 6, 32)
}
