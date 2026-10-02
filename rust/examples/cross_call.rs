//! Concurrent client / load tester for the "ipc:cross" endpoint.
//!
//! Rust port of the C++ `CrossCall.cpp`, C# `CrossCall.cs`, and
//! JavaScript `cross-call.js` demos. It connects as a pure consumer (no
//! application is exposed) and spawns several worker threads. Each
//! thread repeatedly invokes one of two remote APIs on the `demo`
//! application at random:
//!
//! ```text
//! add       (int32 a, int32 b)                    -> int32
//! inv_seri  (uint8, uint16, uint32, uint64,
//!            string(NUL), float)                   -> reversed types
//! ```
//!
//! Both APIs use the raw ABI channel. No JSON is involved at any point.
//! Every byte written matches what the C++ / C# / Pascal / Python /
//! JavaScript clients write for the same logical call.
//!
//! # Log sampling
//!
//! With 32 threads and a 1 ms pause per iteration, this process issues
//! many thousands of calls per second. Printing every call would make
//! the log I/O itself the bottleneck. Each worker therefore logs one
//! iteration out of every `LOG_EVERY_NTH_CALL`; the aggregate counters
//! remain exact.
//!
//! # Running
//!
//! Start the coordinator and at least one node first, then run this
//! script. Multiple instances may be launched in parallel.
//!
//! ```text
//! cargo run --example cross_call
//! ```

use std::process::ExitCode;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::Arc;
use std::thread;
use std::time::{Duration, Instant};

use lingofuse::data_handle::DataHandle;
use lingofuse::{framework, network_events, sys};

// ---------------------------------------------------------------------------
// Configuration (must match the other language demos)
// ---------------------------------------------------------------------------

/// Target application name.
const TARGET_APP: &str = "demo";

/// IPC endpoint name.
const ENDPOINT: &str = "ipc:cross";

/// Number of concurrent caller threads.
const WORKER_THREADS: usize = 32;

/// Total load-test duration in seconds.
const TEST_SECONDS: u64 = 10;

/// Per-call timeout in milliseconds.
const CALL_TIMEOUT_MS: u64 = 1000;

/// Pause between iterations, in milliseconds.
const PAUSE_MS: u64 = 1;

/// Log one iteration out of every N.
const LOG_EVERY_NTH_CALL: u64 = 5000;

/// Range for the random integers passed to `add`.
const NUMBER_MIN: i32 = 1;
const NUMBER_MAX: i32 = 1000;

// ---------------------------------------------------------------------------
// Statistics
// ---------------------------------------------------------------------------

/// Aggregate counters. All fields are atomic and updated with
/// `Ordering::Relaxed`; they are independent of each other and are only
/// read after every worker thread has been joined, so no ordering
/// guarantees are required between them.
struct Stats {
    total_calls: AtomicU64,
    success_calls: AtomicU64,
    failed_calls: AtomicU64,
    add_calls: AtomicU64,
    inv_seri_calls: AtomicU64,
}

impl Stats {
    fn new() -> Self {
        Self {
            total_calls: AtomicU64::new(0),
            success_calls: AtomicU64::new(0),
            failed_calls: AtomicU64::new(0),
            add_calls: AtomicU64::new(0),
            inv_seri_calls: AtomicU64::new(0),
        }
    }
}

// ---------------------------------------------------------------------------
// Remote call wrappers
// ---------------------------------------------------------------------------

/// Invoke the remote `add` API via the raw ABI channel.
///
/// Request : int32 (little-endian) + int32 (little-endian)
/// Reply   : int32 (little-endian)
///
/// Returns `Some(sum)` on success and `None` on timeout or failure.
fn remote_add(a: i32, b: i32) -> Option<i32> {
    let mut param = DataHandle::new("add").ok()?;
    param.write(a).ok()?;
    param.write(b).ok()?;

    let mut response = framework::try_call(TARGET_APP, &param, CALL_TIMEOUT_MS)
        .ok()??;

    response.read().ok()
}

/// Invoke the remote `inv_seri` API via the raw ABI channel.
///
/// Request : uint8, uint16, uint32, uint64, string(NUL), float
/// Reply   : float, string(NUL), uint64, uint32, uint16, uint8
///
/// Returns a human-readable reply string on success and `None` on
/// failure.
fn remote_inv_seri() -> Option<String> {
    // Same constants as the C++ / C# / Pascal / JS counterparts.
    const B: u8 = 200;
    const W: u16 = 0x10;
    const C: u32 = 0x2F;
    const U64: u64 = 0x3F;
    const S: &str = "hello world";
    const F: f32 = 3.14;

    let mut param = DataHandle::new("inv_seri").ok()?;
    param.write(B).ok()?;
    param.write(W).ok()?;
    param.write(C).ok()?;
    param.write(U64).ok()?;
    param.write_string(S).ok()?;
    param.write(F).ok()?;

    let mut response = framework::try_call(TARGET_APP, &param, CALL_TIMEOUT_MS)
        .ok()??;

    // Read the reply fields in the reverse order the node wrote them.
    let rf: f32 = response.read().ok()?;
    let rs: String = response.read_string().ok()?;
    let ru64: u64 = response.read().ok()?;
    let rc: u32 = response.read().ok()?;
    let rw: u16 = response.read().ok()?;
    let rb: u8 = response.read().ok()?;

    Some(format!(
        "reply: [{}, {}, {}, {}, \"{}\", {:?}]  original: [{}, {}, {}, {}, \"{}\", {:?}]",
        rb, rw, rc, ru64, rs, rf, B, W, C, U64, S, F
    ))
}

// ---------------------------------------------------------------------------
// Worker thread
// ---------------------------------------------------------------------------

/// Small xorshift64 PRNG. Inlined to avoid pulling in the `rand` crate
/// for what is essentially a "pick 0 or 1, then pick a random integer in
/// a small range" use case.
#[inline]
fn xorshift64(state: &mut u64) -> u64 {
    let mut x = *state;
    x ^= x << 13;
    x ^= x >> 7;
    x ^= x << 17;
    *state = x;
    x
}

#[inline]
fn random_in_range(state: &mut u64, min: i32, max: i32) -> i32 {
    let span = (max - min + 1) as u64;
    (xorshift64(state) % span) as i32 + min
}

/// Worker thread body.
///
/// Each worker keeps a private iteration counter used purely to decide
/// whether the current iteration should be logged. The aggregate
/// counters in `Stats` are updated unconditionally and are exact.
fn worker(index: usize, stop: Arc<AtomicBool>, stats: Arc<Stats>) {
    // Seed the PRNG with a value derived from the thread index and the
    // current time, so that different workers diverge immediately.
    let mut seed: u64 = (index as u64)
        .wrapping_mul(0x9E37_79B9_7F4A_7C15)
        ^ Instant::now().elapsed().as_nanos() as u64
        ^ std::process::id() as u64;

    let mut iter: u64 = 0;
    while !stop.load(Ordering::Relaxed) {
        iter += 1;
        let do_log = iter % LOG_EVERY_NTH_CALL == 0;

        if xorshift64(&mut seed) & 1 == 0 {
            // ---- add ----
            let a = random_in_range(&mut seed, NUMBER_MIN, NUMBER_MAX);
            let b = random_in_range(&mut seed, NUMBER_MIN, NUMBER_MAX);

            let result = remote_add(a, b);

            stats.total_calls.fetch_add(1, Ordering::Relaxed);
            stats.add_calls.fetch_add(1, Ordering::Relaxed);

            match result {
                Some(c) => {
                    stats.success_calls.fetch_add(1, Ordering::Relaxed);
                    if do_log {
                        println!("[Call {}] add({}, {}) = {}", index, a, b, c);
                    }
                }
                None => {
                    stats.failed_calls.fetch_add(1, Ordering::Relaxed);
                    if do_log {
                        println!(
                            "[Call {}] add({}, {}) timed out or failed.",
                            index, a, b
                        );
                    }
                }
            }
        } else {
            // ---- inv_seri ----
            let result = remote_inv_seri();

            stats.total_calls.fetch_add(1, Ordering::Relaxed);
            stats.inv_seri_calls.fetch_add(1, Ordering::Relaxed);

            match result {
                Some(text) => {
                    stats.success_calls.fetch_add(1, Ordering::Relaxed);
                    if do_log {
                        println!("[Call {}] {}", index, text);
                    }
                }
                None => {
                    stats.failed_calls.fetch_add(1, Ordering::Relaxed);
                    if do_log {
                        println!("[Call {}] inv_seri timed out or failed.", index);
                    }
                }
            }
        }

        if PAUSE_MS > 0 {
            thread::sleep(Duration::from_millis(PAUSE_MS));
        }
    }
}

// ---------------------------------------------------------------------------
// Main logic
// ---------------------------------------------------------------------------

fn run() -> Result<(), Box<dyn std::error::Error>> {
    framework::set_option("Wait_Connection_ReadyOk", "True")?;
    framework::set_option("Overlap_Connection", "True")?;
    framework::set_option("Wait_Connection_Timeout", "10000")?;

    framework::reset_prepare();

    // Pure consumer: no application is exposed.
    framework::prepare_client(ENDPOINT, None)?;

    let done = framework::prepare_done()?;
    if !done && !framework::check_main_thread()? {
        return Err(
            "prepare_done returned false and the main thread is not running".into(),
        );
    }

    println!(
        "[Call] Connected to {}. Starting {}-second load test with {} threads...",
        ENDPOINT, TEST_SECONDS, WORKER_THREADS
    );

    let stats = Arc::new(Stats::new());
    let stop = Arc::new(AtomicBool::new(false));

    let start = Instant::now();

    // Launch worker threads.
    let mut handles = Vec::with_capacity(WORKER_THREADS);
    for i in 0..WORKER_THREADS {
        let stats = Arc::clone(&stats);
        let stop = Arc::clone(&stop);
        handles.push(thread::spawn(move || worker(i, stop, stats)));
    }

    // Run for the configured duration.
    thread::sleep(Duration::from_secs(TEST_SECONDS));
    stop.store(true, Ordering::Relaxed);

    // Join all workers.
    for h in handles {
        let _ = h.join();
    }

    let elapsed = start.elapsed().as_secs_f64();

    // Snapshot the counters now that all workers have stopped.
    let total = stats.total_calls.load(Ordering::Relaxed);
    let success = stats.success_calls.load(Ordering::Relaxed);
    let failed = stats.failed_calls.load(Ordering::Relaxed);
    let add_calls = stats.add_calls.load(Ordering::Relaxed);
    let inv_seri_calls = stats.inv_seri_calls.load(Ordering::Relaxed);

    let success_rate = if total > 0 {
        100.0 * success as f64 / total as f64
    } else {
        0.0
    };
    let throughput = if elapsed > 0.0 {
        total as f64 / elapsed
    } else {
        0.0
    };
    let success_throughput = if elapsed > 0.0 {
        success as f64 / elapsed
    } else {
        0.0
    };

    // Summary. Single-threaded at this point.
    println!();
    println!("[Call] Load test summary");
    println!("         duration          : {:.3} s", elapsed);
    println!("         total calls       : {}", total);
    println!(
        "         success           : {} ({:.2} %)",
        success, success_rate
    );
    println!("         failed            : {}", failed);
    println!("         add calls         : {}", add_calls);
    println!("         inv_seri calls    : {}", inv_seri_calls);
    println!("         throughput        : {:.2} calls/s", throughput);
    println!(
        "         success throughput: {:.2} calls/s",
        success_throughput
    );

    println!("[Call] Press Enter to exit...");
    let mut line = String::new();
    std::io::stdin().read_line(&mut line)?;

    // LF-CLEAN-001 sequence.
    let _ = network_events::clear_network_event();
    framework::exit_main_thread();
    framework::shutdown();

    Ok(())
}

// ---------------------------------------------------------------------------
// Entry point
// ---------------------------------------------------------------------------

fn main() -> ExitCode {
    println!("=== Cross Call (Client) ===");

    if let Err(e) = sys::load_library() {
        eprintln!("[FATAL] Failed to load native library: {}", e);
        return ExitCode::FAILURE;
    }

    match run() {
        Ok(()) => {
            println!("[Call] Bye.");
            ExitCode::SUCCESS
        }
        Err(e) => {
            eprintln!("[FATAL] {}", e);
            ExitCode::FAILURE
        }
    }
}