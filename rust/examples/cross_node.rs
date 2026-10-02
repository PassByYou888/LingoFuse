//! Worker node that registers the "add" and "inv_seri" Call APIs.
//!
//! Rust port of the C++ `CrossNode.cpp`, C# `CrossNode.cs`, and
//! JavaScript `cross-node.js` demos. The behaviour is identical:
//!
//!   1. Load the native LingoFuse library.
//!   2. Create the application `demo`.
//!   3. Register the `add` and `inv_seri` Call APIs.
//!   4. Connect to `ipc:cross` as a client, exposing `demo`.
//!   5. Start the framework.
//!   6. Wait for Enter.
//!   7. Shut down in the LF-CLEAN-001 order.
//!
//! # Registered APIs
//!
//! ```text
//! add       (int32 a, int32 b)                    -> int32
//! inv_seri  (uint8, uint16, uint32, uint64,
//!            string(NUL), float)                   -> same types reversed
//! ```
//!
//! # Wire format
//!
//! Byte-for-byte identical to the C++ / C# / Pascal / Python / JS
//! bindings. All integers are little-endian; the string is UTF-8,
//! NUL-terminated. A Rust `CrossNode` is directly interoperable with a
//! `CrossCall` client in any of those languages, and vice versa.
//!
//! # Registration order
//!
//! The two APIs must be registered **before** `prepare_client`, because
//! the `Init_App_Info` broadcast carries the API list as a snapshot.
//!
//! # Running
//!
//! Start the coordinator first (`cross_service`), then this node:
//!
//! ```text
//! cargo run --example cross_node
//! ```

use std::process::ExitCode;

use lingofuse::app_handle::AppHandle;
use lingofuse::data_handle::DataHandle;
use lingofuse::{framework, network_events, sys};

/// The IPC endpoint name. Must match the other language demos.
const ENDPOINT: &str = "ipc:cross";

/// The application name exposed to the mesh.
const APP_NAME: &str = "demo";

// ---------------------------------------------------------------------------
// Callbacks
// ---------------------------------------------------------------------------
//
// Callbacks execute on background worker threads. Inside them:
//
//   - Do NOT block.
//   - Do NOT call `framework::call` / `AppHandle::local_call` (deadlock).
//   - Do NOT panic. The wrapper isolates a panic at the FFI boundary,
//     but a caught panic still aborts the current callback and the
//     caller receives an empty response.
//
// Both callbacks below therefore use `match` / `if let` on the `Result`
// values returned by the handle methods; a failure produces an empty
// response rather than a panic.

/// `add(int32, int32) -> int32`
///
/// Reads two 32-bit signed integers (little-endian) and writes their
/// sum. This is the exact byte sequence the C++ / C# / Pascal / Python
/// / JavaScript counterparts read and write.
fn add_handler(input: &mut DataHandle, output: &mut DataHandle) {
    let a: i32 = match input.read() {
        Ok(v) => v,
        Err(_) => return,
    };
    let b: i32 = match input.read() {
        Ok(v) => v,
        Err(_) => return,
    };
    let c = a.wrapping_add(b);

    println!("[Node] add({}, {}) = {}", a, b, c);

    let _ = output.write(c);
}

/// `inv_seri(uint8, uint16, uint32, uint64, string, float)`
///   -> reversed typed sequence
///
/// Reads the request in one field order and replies with the same
/// fields in reverse order. Used to exercise the binary wire format.
fn inv_seri_handler(input: &mut DataHandle, output: &mut DataHandle) {
    let b: u8 = match input.read() {
        Ok(v) => v,
        Err(_) => return,
    };
    let w: u16 = match input.read() {
        Ok(v) => v,
        Err(_) => return,
    };
    let c: u32 = match input.read() {
        Ok(v) => v,
        Err(_) => return,
    };
    let u64_: u64 = match input.read() {
        Ok(v) => v,
        Err(_) => return,
    };
    let s: String = match input.read_string() {
        Ok(v) => v,
        Err(_) => return,
    };
    let f: f32 = match input.read() {
        Ok(v) => v,
        Err(_) => return,
    };

    println!(
        "[Node] inv_seri received: [{}, {}, {}, {}, \"{}\", {:?}]",
        b, w, c, u64_, s, f
    );

    // Reply in the reverse field order, matching CrossNode.cpp.
    let _ = output.write(f);
    let _ = output.write_string(&s);
    let _ = output.write(u64_);
    let _ = output.write(c);
    let _ = output.write(w);
    let _ = output.write(b);

    println!(
        "[Node] inv_seri replied:  [{:?}, \"{}\", {}, {}, {}, {}]",
        f, s, u64_, c, w, b
    );
}

// ---------------------------------------------------------------------------
// Cleanup guard
// ---------------------------------------------------------------------------

/// RAII guard that performs the LF-CLEAN-001 shutdown sequence.
///
/// The application handle is held as an `Option` so that the guard can
/// explicitly drop it at the correct point in the sequence:
///
/// ```text
/// NetworkEvents.Clear -> ExitMainThread -> App.Dispose -> Shutdown
/// ```
struct CleanupGuard {
    started: bool,
    app: Option<AppHandle>,
}

impl CleanupGuard {
    fn new(app: AppHandle) -> Self {
        Self {
            started: false,
            app: Some(app),
        }
    }

    fn app(&self) -> &AppHandle {
        // Invariant: `app` is only `None` after `drop` has run, which
        // cannot happen while `run` holds a reference.
        self.app.as_ref().expect("app already taken")
    }

    fn mark_started(&mut self) {
        self.started = true;
    }
}

impl Drop for CleanupGuard {
    fn drop(&mut self) {
        if !self.started {
            // Startup failed partway through. Release the app, but do
            // not touch the process-wide framework, which was never
            // fully initialised.
            self.app.take();
            return;
        }

        // LF-CLEAN-001 sequence.
        let _ = network_events::clear_network_event();
        framework::exit_main_thread();
        self.app.take();
        framework::shutdown();
    }
}

// ---------------------------------------------------------------------------
// Main logic
// ---------------------------------------------------------------------------

fn run(guard: &mut CleanupGuard) -> Result<(), Box<dyn std::error::Error>> {
    // 1. Register the two Call APIs. Both registrations must complete
    //    before `prepare_client`, because the `Init_App_Info` broadcast
    //    carries the API list as a snapshot.
    //
    // `AppHandle::register_call` returns `Result<(), Error>`: success is
    // `Ok(())`, failure is `Err(Error)` with `ErrorCode::RegistrationFailed`.
    // The `?` operator propagates the failure; no boolean check is needed.
    let app = guard.app();
    app.register_call("add", "add(int a, int b) -> int", add_handler)?;
    app.register_call(
        "inv_seri",
        "inv_seri() -> reversed typed sequence",
        inv_seri_handler,
    )?;

    // 2. Deployment mode: do not block `prepare_done` waiting for the
    //    service endpoint. The node can start before the coordinator;
    //    it will connect automatically once the endpoint is reachable.
    framework::set_option("Wait_Ready", "False")?;
    framework::set_option("Overlap_Connection", "True")?;

    framework::reset_prepare();

    // 3. Connect to the coordinator as a client and expose `demo`.
    framework::prepare_client(ENDPOINT, Some(guard.app()))?;

    // 4. Start the framework.
    let done = framework::prepare_done()?;
    if !done && !framework::check_main_thread()? {
        return Err(
            "prepare_done returned false and the main thread is not running".into(),
        );
    }

    guard.mark_started();

    println!(
        "[Node] Registered APIs 'add' and 'inv_seri' under application '{}'.",
        APP_NAME
    );
    println!("[Node] Online. Press Enter to exit...");

    // 5. Idle until the user presses Enter.
    let mut line = String::new();
    std::io::stdin().read_line(&mut line)?;

    println!("[Node] Shutting down...");
    Ok(())
}

// ---------------------------------------------------------------------------
// Entry point
// ---------------------------------------------------------------------------

fn main() -> ExitCode {
    println!("=== Cross Node (Worker) ===");

    if let Err(e) = sys::load_library() {
        eprintln!("[FATAL] Failed to load native library: {}", e);
        return ExitCode::FAILURE;
    }

    // Create the application up front so that the cleanup guard owns it
    // from the start. This lets the guard release the app even when the
    // registration or network preparation steps fail.
    let app = match AppHandle::new(APP_NAME, "Rust worker node") {
        Ok(a) => a,
        Err(e) => {
            eprintln!("[FATAL] Failed to create application: {}", e);
            return ExitCode::FAILURE;
        }
    };

    let mut guard = CleanupGuard::new(app);

    let outcome = run(&mut guard);

    drop(guard);

    match outcome {
        Ok(()) => {
            println!("[Node] Bye.");
            ExitCode::SUCCESS
        }
        Err(e) => {
            eprintln!("[FATAL] {}", e);
            ExitCode::FAILURE
        }
    }
}