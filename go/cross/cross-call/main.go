// Command cross-call is the concurrent load tester of the
// cross-language demo.
//
// It connects to the coordinator at "ipc:cross" as a pure consumer
// (no application attached) and spawns 32 goroutines. Each goroutine
// repeatedly invokes one of two remote APIs on the "demo" application
// at random:
//
//	add      (int32 a, int32 b)                    -> int32
//	inv_seri (uint8, uint16, uint32, uint64,
//	          string(NUL), float32)                 -> reversed
//
// {!!!!!  WIRE FORMAT IS BYTE-FOR-BYTE IDENTICAL  !!!!!}
// Both APIs use the raw ABI channel. No JSON is involved at any
// point. Every byte written matches what the C++, C#, Pascal, Rust,
// and JavaScript clients write for the same logical call.
//
// {!!!!!  INTEROP  !!!!!}
// The load test may be run against a Go node (this language), or
// against a worker implemented in any other language:
//
//	./cross-call            -> Go cross-node
//	./cross-call            -> C++ CrossNode.exe
//	./cross-call            -> C# CrossNode.exe
//	...
//
// The only requirement is that the coordinator endpoint matches and
// the wire format is as documented above -- which it is, by
// construction of the demo.
//
// Usage:
//
//	cross-call
//	cross-call -endpoint ipc:cross -app demo
//
// Press Ctrl+C to stop the load test early; otherwise it runs for the
// configured duration and prints a summary.
package main

import (
	"flag"
	"fmt"
	"math/rand"
	"os"
	"sync"
	"sync/atomic"
	"time"

	"github.com/PassByYou888/LingoFuse/go/lingofuse"
)

// ---------------------------------------------------------------------------
// Configuration (MUST match the other language demos)
// ---------------------------------------------------------------------------

const (
	defaultEndpoint = "ipc:cross"
	defaultAppName  = "demo"

	// kWorkerThreads is the number of concurrent caller goroutines.
	kWorkerThreads = 32

	// kTestSeconds is the total load-test duration.
	kTestSeconds = 10

	// kCallTimeoutMs is the per-call timeout in milliseconds.
	kCallTimeoutMs = 1000

	// kPauseMs is the pause between iterations, in milliseconds.
	kPauseMs = 1

	// kLogEveryNthCall samples the per-call log to avoid making I/O
	// the bottleneck. Aggregate counters remain exact.
	kLogEveryNthCall = 5000

	// Range for the random integers passed to add.
	kNumberMin = 1
	kNumberMax = 1000
)

func main() {
	endpoint := flag.String("endpoint", defaultEndpoint,
		"LingoFuse endpoint of the coordinator.")
	appName := flag.String("app", defaultAppName,
		"Name of the target App.")
	flag.Parse()

	if err := run(*endpoint, *appName); err != nil {
		fmt.Fprintf(os.Stderr, "[FATAL] %v\n", err)
		os.Exit(1)
	}
}

// ---------------------------------------------------------------------------
// Statistics
// ---------------------------------------------------------------------------
//
// Pure counters. Configuration values such as the target App name are
// passed to `worker` as ordinary function parameters, so the stats
// struct stays a plain aggregate with no mixed concerns.
type stats struct {
	total    atomic.Uint64
	success  atomic.Uint64
	failed   atomic.Uint64
	addCalls atomic.Uint64
	invCalls atomic.Uint64
}

// ---------------------------------------------------------------------------
// Remote call wrappers (raw ABI, no JSON)
// ---------------------------------------------------------------------------

// remoteAdd invokes the remote "add" API via the raw ABI channel.
//
//	request : [a: int32 LE] [b: int32 LE]
//	reply   : [sum: int32 LE]
//
// Returns (sum, true) on success, (0, false) on timeout or failure.
func remoteAdd(appName string, a, b int32) (int32, bool) {
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

	res, err := lingofuse.Call(appName, param, kCallTimeoutMs)
	if err != nil {
		return 0, false
	}
	defer res.Close()

	sz, err := res.Size()
	if err != nil || sz == 0 {
		return 0, false
	}
	if err := res.SetPosition(0); err != nil {
		return 0, false
	}
	v, err := res.ReadInt32()
	if err != nil {
		return 0, false
	}
	return v, true
}

// remoteInvSeri invokes the remote "inv_seri" API and formats the
// reply. The reply format is a string identical to what CrossCall.cpp
// prints.
func remoteInvSeri(appName string) (string, bool) {
	// Same constants as the C++ / C# / Pascal / Rust / JS counterparts.
	const (
		b uint8   = 200
		w uint16  = 0x10
		c uint32  = 0x2F
		u uint64  = 0x3F
		s string  = "hello world"
		f float32 = 3.14
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
	if err := param.WriteUint64(u); err != nil {
		return "", false
	}
	if err := param.WriteString(s); err != nil {
		return "", false
	}
	if err := param.WriteSingle(f); err != nil {
		return "", false
	}

	res, err := lingofuse.Call(appName, param, kCallTimeoutMs)
	if err != nil {
		return "", false
	}
	defer res.Close()

	sz, err := res.Size()
	if err != nil || sz == 0 {
		return "", false
	}
	if err := res.SetPosition(0); err != nil {
		return "", false
	}

	rf, err := res.ReadSingle()
	if err != nil {
		return "", false
	}
	rs, err := res.ReadString()
	if err != nil {
		return "", false
	}
	ru, err := res.ReadUint64()
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
		"reply: [%d, %d, %d, %d, %q, %v]  original: [%d, %d, %d, %d, %q, %v]",
		rb, rw, rc, ru, rs, rf,
		b, w, c, u, s, f,
	), true
}

// ---------------------------------------------------------------------------
// Worker goroutine
// ---------------------------------------------------------------------------

func worker(index int, targetApp string, stop *atomic.Bool, st *stats) {
	rng := rand.New(rand.NewSource(
		int64(index)*2654435761 + time.Now().UnixNano(),
	))

	iter := uint64(0)
	for !stop.Load() {
		iter++
		doLog := (iter % kLogEveryNthCall) == 0

		if rng.Intn(2) == 0 {
			// --- add ---
			a := int32(rng.Intn(kNumberMax-kNumberMin+1) + kNumberMin)
			b := int32(rng.Intn(kNumberMax-kNumberMin+1) + kNumberMin)

			result, ok := remoteAdd(targetApp, a, b)
			st.total.Add(1)
			st.addCalls.Add(1)
			if ok {
				st.success.Add(1)
				if doLog {
					fmt.Printf("[Call %d] add(%d, %d) = %d\n",
						index, a, b, result)
				}
			} else {
				st.failed.Add(1)
				if doLog {
					fmt.Printf(
						"[Call %d] add(%d, %d) timed out or failed.\n",
						index, a, b)
				}
			}
		} else {
			// --- inv_seri ---
			text, ok := remoteInvSeri(targetApp)
			st.total.Add(1)
			st.invCalls.Add(1)
			if ok {
				st.success.Add(1)
				if doLog {
					fmt.Printf("[Call %d] %s\n", index, text)
				}
			} else {
				st.failed.Add(1)
				if doLog {
					fmt.Printf(
						"[Call %d] inv_seri timed out or failed.\n",
						index)
				}
			}
		}

		if kPauseMs > 0 {
			time.Sleep(time.Duration(kPauseMs) * time.Millisecond)
		}
	}
}

// ---------------------------------------------------------------------------
// Main logic
// ---------------------------------------------------------------------------

func run(endpoint, appName string) error {
	fmt.Println("=== Cross Call (Client) ===")

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
	// Pure consumer: no application is exposed.
	if _, err := lingofuse.PrepareClient(endpoint, nil); err != nil {
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
		"[Call] Connected to %s. Starting %d-second load test "+
			"with %d threads...\n",
		endpoint, kTestSeconds, kWorkerThreads,
	)

	st := &stats{}

	var stop atomic.Bool
	var wg sync.WaitGroup

	start := time.Now()

	for i := 0; i < kWorkerThreads; i++ {
		wg.Add(1)
		go func(idx int) {
			defer wg.Done()
			worker(idx, appName, &stop, st)
		}(i)
	}

	time.Sleep(time.Duration(kTestSeconds) * time.Second)
	stop.Store(true)
	wg.Wait()

	elapsed := time.Since(start).Seconds()

	total := st.total.Load()
	success := st.success.Load()
	failed := st.failed.Load()
	addCalls := st.addCalls.Load()
	invCalls := st.invCalls.Load()

	var successRate, throughput, successThroughput float64
	if total > 0 {
		successRate = 100.0 * float64(success) / float64(total)
	}
	if elapsed > 0 {
		throughput = float64(total) / elapsed
		successThroughput = float64(success) / elapsed
	}

	fmt.Println()
	fmt.Println("[Call] Load test summary")
	fmt.Printf("         duration          : %.3f s\n", elapsed)
	fmt.Printf("         total calls       : %d\n", total)
	fmt.Printf("         success           : %d (%.2f %%)\n",
		success, successRate)
	fmt.Printf("         failed            : %d\n", failed)
	fmt.Printf("         add calls         : %d\n", addCalls)
	fmt.Printf("         inv_seri calls    : %d\n", invCalls)
	fmt.Printf("         throughput        : %.2f calls/s\n", throughput)
	fmt.Printf("         success throughput: %.2f calls/s\n",
		successThroughput)

	fmt.Println()
	fmt.Println("[Call] Shutting down...")

	if err := lingofuse.ExitMainThread(); err != nil {
		fmt.Fprintf(os.Stderr, "[Call] ExitMainThread: %v\n", err)
	}
	if err := lingofuse.Shutdown(); err != nil {
		return fmt.Errorf("Shutdown: %w", err)
	}
	fmt.Println("[Call] Bye.")
	return nil
}
