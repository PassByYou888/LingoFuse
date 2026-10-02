//! Coordinator process for the IPC endpoint "ipc:cross".
//!
//! Rust port of the C++ `CrossService.cpp`, C# `CrossService.cs`, and
//! JavaScript `cross-service.js` demos. The behaviour is identical:
//!
//!   1. Load the native LingoFuse library.
//!   2. Configure the same deployment options as the other languages.
//!   3. Create the IPC service endpoint `ipc:cross`.
//!   4. Prepare a self-connected client so that the C4 mesh has at least
//!      one physical tunnel to anchor the broadcast loop.
//!   5. Start the framework (`prepare_done`).
//!   6. Wait for Enter.
//!   7. Shut down in the LF-CLEAN-001 order.
//!
//! # Cleanup order
//!
//! The required cleanup sequence is:
//!
//! ```text
//! NetworkEvents.Clear -> ExitMainThread -> Shutdown
//! ```
//!
//! Every operation is idempotent, so this script runs the sequence on
//! every exit path (normal return, early return, or error).
//!
//! # Running
//!
//! ```text
//! cargo run --example cross_service
//! ```

use std::process::ExitCode;

use lingofuse::{framework, network_events, sys};

/// The IPC endpoint name. Must match the other language demos.
const ENDPOINT: &str = "ipc:cross";

// ---------------------------------------------------------------------------
// Cleanup guard
// ---------------------------------------------------------------------------

/// RAII guard that performs the LF-CLEAN-001 shutdown sequence on drop.
///
/// The guard is declared at the top of `run()`, and `mark_started()` is
/// called only after the framework has successfully started. If startup
/// fails partway through, the guard does nothing, which is the correct
/// behaviour — the framework was never fully initialised.
struct CleanupGuard {
    started: bool,
}

impl CleanupGuard {
    fn new() -> Self {
        Self { started: false }
    }

    fn mark_started(&mut self) {
        self.started = true;
    }
}

impl Drop for CleanupGuard {
    fn drop(&mut self) {
        if !self.started {
            return;
        }

        // LF-CLEAN-001 sequence. Every step is best-effort; a failure
        // in one step does not prevent the others from running.
        let _ = network_events::clear_network_event();
        framework::exit_main_thread();
        framework::shutdown();
    }
}

// ---------------------------------------------------------------------------
// Main logic
// ---------------------------------------------------------------------------

fn run(guard: &mut CleanupGuard) -> Result<(), Box<dyn std::error::Error>> {
    // Deployment options, identical to the C++ / C# / JS demos.
    framework::set_option("Wait_Connection_ReadyOk", "True")?;
    framework::set_option("Overlap_Connection", "True")?;
    framework::set_option("Wait_Connection_Timeout", "10000")?;

    framework::reset_prepare();

    // 1. Create the IPC service endpoint.
    let service_tag = framework::prepare_service(ENDPOINT, ENDPOINT)?;
    println!(
        "[Service] Prepared service endpoint {} (tag={}).",
        ENDPOINT, service_tag
    );

    // 2. Prepare a client with no application. This gives the mesh at
    //    least one physical tunnel at the coordinator itself, which the
    //    C4 broadcast loop needs in order to make the endpoint
    //    reachable by other processes.
    let client_tag = framework::prepare_client(ENDPOINT, None)?;
    println!("[Service] Prepared client tunnel (tag={}).", client_tag);

    // 3. Start the framework.
    //
    // `prepare_done` returns Ok(true) on the first successful call.
    // A subsequent call in the same process without an intervening
    // shutdown returns Ok(false), which is not a failure.
    let done = framework::prepare_done()?;
    if !done && !framework::check_main_thread()? {
        return Err(
            "prepare_done returned false and the main thread is not running".into(),
        );
    }

    guard.mark_started();

    println!(
        "[Service] IPC service '{}' is running. Press Enter to exit...",
        ENDPOINT
    );

    // 4. Idle until the user presses Enter.
    let mut line = String::new();
    std::io::stdin().read_line(&mut line)?;

    println!("[Service] Shutting down...");
    Ok(())
}

// ---------------------------------------------------------------------------
// Entry point
// ---------------------------------------------------------------------------

fn main() -> ExitCode {
    println!("=== Cross Service (Coordinator) ===");

    // Eagerly load the native library so that a missing-library error
    // surfaces here, at a well-defined point, instead of at the first
    // unrelated native call.
    if let Err(e) = sys::load_library() {
        eprintln!("[FATAL] Failed to load native library: {}", e);
        return ExitCode::FAILURE;
    }

    let mut guard = CleanupGuard::new();

    let outcome = run(&mut guard);

    // `guard` drops here, running the LF-CLEAN-001 sequence when the
    // framework was successfully started.
    drop(guard);

    match outcome {
        Ok(()) => {
            println!("[Service] Bye.");
            ExitCode::SUCCESS
        }
        Err(e) => {
            eprintln!("[FATAL] {}", e);
            ExitCode::FAILURE
        }
    }
}