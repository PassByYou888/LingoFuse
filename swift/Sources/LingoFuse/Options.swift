//
//  Options.swift
//  LingoFuse
//
//  Typed Swift API for the LingoFuse runtime options.
//
//  PURPOSE
//  -------
//  The native layer exposes a single string-keyed configuration
//  primitive:
//
//      LF_SetOption(name, value)    // write (always succeeds)
//      LF_GetOption(name) -> str    // read  (returns "" for unknown)
//
//  This module wraps that primitive in a TYPED, DISCOVERABLE surface:
//  one `setXxx(_:)` / `getXxx()` pair per documented option. The
//  pairs mirror, one for one, the convenience functions defined by
//  the Pascal-side `lingofuse_import.pas` unit and the C++ side's
//  `LingoFuse.c`:
//
//      Pascal / C++                                Swift (this file)
//      ---------------------------------------    -------------------------
//      LF_Set_Opt_Password / LF_Get_Opt_Password   setPassword / getPassword
//      LF_Set_Opt_Quiet / LF_Get_Opt_Quiet         setQuiet / getQuiet
//      ... (16 pairs in total)
//
//  BEHAVIOUR
//  ---------
//  Each Swift function is a thin wrapper around the generic
//  `LF_SetOption` / `LF_GetOption` C primitives. The call path is
//  always:
//
//      LF_SetOption(name, "True")  // bool  setter
//      LF_SetOption(name, "5000")  // numeric setter
//      LF_GetOption(name)          // getter, always reads a string
//
//  The only differences from the raw C primitives are:
//
//    * the caller supplies typed values (Bool / UInt64 / Int32 / String)
//      instead of the stringly-typed value, and
//    * the getters apply a documented safe fallback for the
//      unknown / unset / malformed case.
//
//  BOOLEAN ENCODING (IMPORTANT)
//  ----------------------------
//  The C side's boolean parser accepts multiple spellings
//  ("True" / "1" / "Yes" / ...), but the C++ `LF_Set_Opt_XXX` helpers
//  ONLY ever write the canonical "True" / "False" form, and the
//  C++ `LF_Get_Opt_XXX` helpers ONLY recognise "True"
//  (case-insensitive) as `true`. This Swift module preserves that
//  behaviour exactly:
//
//      * setter writes "True" / "False", nothing else
//      * getter treats anything other than "True" (case-insensitive)
//        as `false`
//
//  Rationale: consistent round-trip. A setter that writes "True"
//  followed by a getter that returns `true` is guaranteed by
//  construction. A caller that wants to accept "1" / "Yes" / etc. on
//  the read side must use `Framework.getOption(_:)` and parse the
//  string itself.
//
//  NUMERIC ENCODING
//  ----------------
//  Setters write the canonical decimal form of the value (no sign for
//  unsigned, optional "-" for signed). Getters extract the LEADING
//  decimal digits and ignore any trailing garbage, matching the C++
//  side's `strtoull` / `strtoll` behaviour:
//
//      "5000"        -> 5000
//      "5000abc"     -> 5000
//      "abc"         -> 0
//      ""            -> 0
//
//  UNKNOWN / UNSET / MALFORMED OPTIONS
//  -----------------------------------
//  The native `LF_GetOption` returns an empty string for an unknown
//  option name, and does NOT signal an error. Every getter in this
//  module therefore has a documented "safe fallback" for the
//  unknown / unset / malformed case:
//
//      Bool     -> false
//      UInt64   -> 0
//      Int32    -> 0
//      String   -> ""
//
//  Callers that need to distinguish "unset" from "set to zero" must
//  call `Framework.getOption(_:)` directly and inspect the raw
//  string.
//
//  WRITE-ONLY OPTIONS
//  ------------------
//  Two options are special:
//
//      "password"   the getter returns a fixed mask ("********")
//                   regardless of the actual value.
//      "debug"      the option is write-only; the getter returns a
//                   fixed placeholder string from the native layer.
//
//  These behaviours are implemented on the C side, NOT here. This
//  module simply forwards to `LF_GetOption` and returns whatever the
//  native layer produces.
//
//  PERSISTENCE
//  -----------
//  Options are process-global and take effect immediately, but they
//  are NOT persisted across `LF_Shutdown`. An application that
//  restarts the framework must reapply its options on every startup.
//  See Pascal LF-OPT-002.
//
//  THREADING
//  ---------
//  The underlying `LF_SetOption` / `LF_GetOption` are documented as
//  thread-safe. Every function in this module is therefore
//  thread-safe as well. However, a setter takes effect immediately,
//  so a concurrent reader may observe the old value, the new value,
//  or (for string options) a torn read. An application that needs a
//  consistent multi-option configuration must serialise its own
//  updates behind its own lock.
//
//  STRING PARAMETERS
//  -----------------
//  Every string argument is forwarded to the C side as UTF-8. The C
//  wrapper handles the NUL-termination internally; Swift's default
//  `String` -> `UnsafePointer<CChar>` conversion on the imported
//  function signature takes care of it.
//

import Foundation
import CLingoFuse

public enum Options {

    // ==================================================================
    // Authentication
    // ==================================================================

    /// Sets the P2PVM / C4 network authentication password.
    ///
    /// Must match on both sides of a connection or the handshake
    /// fails. The default is the well-known development token; a
    /// production deployment should set a private value before
    /// `Framework.prepareService` / `Framework.prepareClient`.
    ///
    /// Option key: `"password"`.
    public static func setPassword(_ value: String) {
        setString("password", value)
    }

    /// Reads the configured password.
    ///
    /// The native layer returns a fixed mask (`"********"`) rather
    /// than the real value. This is a deliberate security measure:
    /// the actual password is never exposed through the option-reading
    /// API.
    ///
    /// Option key: `"password"`.
    public static func getPassword() -> String {
        return getString("password")
    }

    // ==================================================================
    // Logging and diagnostics
    // ==================================================================

    /// Executes a C4 console debug command.
    ///
    /// This option is WRITE-ONLY and has side effects: each call
    /// constructs a transient console helper object on the native side
    /// and runs the given command. Recognised command names include
    /// `"service"`, `"tunnel"`, `"ZNet_Info"`, `"HPC_Thread_Info"`,
    /// and `"Instance_Info"`.
    ///
    /// Because each call allocates a helper object, this option is
    /// intended for interactive diagnostics only. Do not call it in a
    /// hot loop.
    ///
    /// Option key: `"debug"`.
    public static func setDebug(_ value: String) {
        setString("debug", value)
    }

    /// Reads the current value of the `debug` option.
    ///
    /// Because the underlying option is write-only, the native layer
    /// returns a fixed placeholder string rather than a stored value.
    /// Provided for symmetry with the other getters.
    ///
    /// Option key: `"debug"`.
    public static func getDebug() -> String {
        return getString("debug")
    }

    /// Enables or disables quiet mode.
    ///
    /// When quiet mode is enabled, most internal informational logging
    /// is suppressed.
    ///
    /// Default: `false`.
    ///
    /// Option key: `"Quiet"`.
    public static func setQuiet(_ value: Bool) {
        setBool("Quiet", value)
    }

    /// Returns `true` when quiet mode is currently enabled.
    ///
    /// Option key: `"Quiet"`.
    public static func getQuiet() -> Bool {
        return getBool("Quiet")
    }

    /// Enables or disables thread-ID prefixes in status output.
    ///
    /// When enabled, every status message emitted by the Z.Status
    /// subsystem is prefixed with the numeric ID of the thread that
    /// produced it.
    ///
    /// Default: `true`.
    ///
    /// Option key: `"ShowThreadID"`.
    public static func setShowThreadID(_ value: Bool) {
        setBool("ShowThreadID", value)
    }

    /// Returns `true` when thread-ID prefixes are currently enabled.
    ///
    /// Option key: `"ShowThreadID"`.
    public static func getShowThreadID() -> Bool {
        return getBool("ShowThreadID")
    }

    /// Enables or disables console output for status messages.
    ///
    /// When disabled, status messages are still queued and remain
    /// readable through `Status.getStatus()`; only the console sink
    /// is muted.
    ///
    /// Default: depends on the host; set explicitly by the native
    /// entry point based on whether the host is a console or a GUI
    /// process.
    ///
    /// Option key: `"ConsoleOutput"`.
    public static func setConsoleOutput(_ value: Bool) {
        setBool("ConsoleOutput", value)
    }

    /// Returns `true` when console output is currently enabled.
    ///
    /// Option key: `"ConsoleOutput"`.
    public static func getConsoleOutput() -> Bool {
        return getBool("ConsoleOutput")
    }

    // ==================================================================
    // Connection readiness
    // ==================================================================

    /// Allows or forbids multiple client tunnels to the same physical
    /// address.
    ///
    /// `false` (the default): only one client tunnel per physical
    /// address. A second `Framework.prepareClient` call for the same
    /// address returns an error and the new application handle is
    /// discarded.
    ///
    /// `true`: every `Framework.prepareClient` call creates a new
    /// independent tunnel, binding the supplied application handle.
    ///
    /// This option MUST be set BEFORE the `prepareClient` calls it is
    /// meant to affect. Changing it after a tunnel has been created
    /// does not rearrange existing tunnels.
    ///
    /// Option key: `"Overlap_Connection"`.
    public static func setOverlapConnection(_ value: Bool) {
        setBool("Overlap_Connection", value)
    }

    /// Returns `true` when overlapping connections are allowed.
    ///
    /// Option key: `"Overlap_Connection"`.
    public static func getOverlapConnection() -> Bool {
        return getBool("Overlap_Connection")
    }

    /// Controls whether `Framework.prepareDone` blocks until every
    /// prepared client is online.
    ///
    /// `true` (the default): `prepareDone` waits for all prepared
    /// clients to reach the "online" state before returning.
    ///
    /// `false`: `prepareDone` returns immediately after the simulated
    /// main thread has started. The caller is then responsible for
    /// probing readiness itself (for example with `Framework.checkApi`
    /// in a retry loop). This is the recommended setting for
    /// deployments where the startup order of peers is not
    /// predictable.
    ///
    /// The total wait is bounded by `setWaitConnectionTimeout(_:)`.
    ///
    /// Option key: `"Wait_Connection_ReadyOk"`.
    public static func setWaitConnectionReadyOk(_ value: Bool) {
        setBool("Wait_Connection_ReadyOk", value)
    }

    /// Returns `true` when `prepareDone` currently waits for all
    /// clients.
    ///
    /// Option key: `"Wait_Connection_ReadyOk"`.
    public static func getWaitConnectionReadyOk() -> Bool {
        return getBool("Wait_Connection_ReadyOk")
    }

    /// Sets the timeout, in milliseconds, for the `prepareDone` wait
    /// described by `setWaitConnectionReadyOk(_:)`.
    ///
    /// Default: 30,000 ms (30 seconds). If the timeout expires before
    /// all clients are ready, `prepareDone` still returns `true`; the
    /// caller must independently verify readiness if that matters.
    ///
    /// The native library imposes a floor of 5,000 ms on this value
    /// when the wait is actually performed. Values below that floor
    /// are silently raised.
    ///
    /// Option key: `"Wait_Connection_Timeout"`.
    public static func setWaitConnectionTimeout(_ ms: UInt64) {
        setUInt64("Wait_Connection_Timeout", ms)
    }

    /// Returns the current `prepareDone` wait timeout, in milliseconds.
    ///
    /// Option key: `"Wait_Connection_Timeout"`.
    public static func getWaitConnectionTimeout() -> UInt64 {
        return getUInt64("Wait_Connection_Timeout")
    }

    // ==================================================================
    // IPC
    // ==================================================================

    /// Sets the size of the IPC server thread pool.
    ///
    /// MUST be set before the IPC server is started. Changing it after
    /// startup has no effect on an already-running server.
    ///
    /// Default: platform-dependent.
    ///
    /// Option key: `"IPC_Serv_ThreadCount"`.
    public static func setIPCServThreadCount(_ value: Int32) {
        setInt32("IPC_Serv_ThreadCount", value)
    }

    /// Returns the configured IPC server thread count.
    ///
    /// Option key: `"IPC_Serv_ThreadCount"`.
    public static func getIPCServThreadCount() -> Int32 {
        return getInt32("IPC_Serv_ThreadCount")
    }

    /// Sets the maximum length of the IPC server's inbound message
    /// queue.
    ///
    /// MUST be set before the IPC server is started.
    ///
    /// Option key: `"IPC_Serv_MaxQueueLength"`.
    public static func setIPCServMaxQueueLength(_ value: Int32) {
        setInt32("IPC_Serv_MaxQueueLength", value)
    }

    /// Returns the configured IPC server max queue length.
    ///
    /// Option key: `"IPC_Serv_MaxQueueLength"`.
    public static func getIPCServMaxQueueLength() -> Int32 {
        return getInt32("IPC_Serv_MaxQueueLength")
    }

    /// Sets the maximum size, in bytes, of a single IPC message.
    ///
    /// MUST be set before the IPC server is started.
    ///
    /// Option key: `"IPC_Serv_MaxMsgSize"`.
    public static func setIPCServMaxMsgSize(_ value: Int32) {
        setInt32("IPC_Serv_MaxMsgSize", value)
    }

    /// Returns the configured IPC server max message size.
    ///
    /// Option key: `"IPC_Serv_MaxMsgSize"`.
    public static func getIPCServMaxMsgSize() -> Int32 {
        return getInt32("IPC_Serv_MaxMsgSize")
    }

    // ==================================================================
    // Sequenced notifications
    // ==================================================================

    /// Sets the sticky-affinity window, in milliseconds, for P2PName
    /// load balancing.
    ///
    /// When the server-side dispatcher routes a P2PName-addressed call,
    /// it normally picks the target with the smallest Cycle_Anchor
    /// value (pure round-robin). If, however, a single target has been
    /// handling requests for longer than this value, the dispatcher
    /// switches to a different target instead, to avoid starvation.
    ///
    /// Default: 20,000 ms (20 seconds).
    ///
    /// Option key: `"Fixed_Sequenced_Time"`.
    public static func setFixedSequencedTime(_ ms: UInt64) {
        setUInt64("Fixed_Sequenced_Time", ms)
    }

    /// Returns the current sticky-affinity window, in milliseconds.
    ///
    /// Option key: `"Fixed_Sequenced_Time"`.
    public static func getFixedSequencedTime() -> UInt64 {
        return getUInt64("Fixed_Sequenced_Time")
    }

    // ==================================================================
    // P2P group name
    // ==================================================================

    /// Sets this process's P2P group name.
    ///
    /// The name is injected into every outbound request payload and is
    /// reported to the server through the `Update_UID` command. It
    /// defines which P2PName-addressed calls this process is willing
    /// to receive.
    ///
    /// May be changed at any time. The framework picks up the new name
    /// on the next outbound request; there is no need to reconnect.
    ///
    /// Default: empty string ("not a member of any group"). An empty
    /// P2P name disables P2PName routing for this process; UID and
    /// App-name routing are unaffected.
    ///
    /// {!!!!!  NOT TO BE CONFUSED WITH DataHandle.p2pName()  !!!!!}
    /// This function controls the LOCAL configuration: the P2P name
    /// that THIS process declares for itself. It is unrelated to
    /// `DataHandle.p2pName()`, which reads the SENDER's P2P name from
    /// the INPUT handle of a registered callback (side data injected
    /// by the sender's transport layer).
    ///
    /// Option key: `"LF_P2P_name"`.
    public static func setP2PName(_ value: String) {
        setString("LF_P2P_name", value)
    }

    /// Returns this process's configured P2P group name.
    ///
    /// {!!!!!  NOT TO BE CONFUSED WITH DataHandle.p2pName()  !!!!!}
    /// This function reads the LOCAL configuration: the value this
    /// process set for itself. It is unrelated to the SENDER's P2P
    /// name that `DataHandle.p2pName()` reads from an INPUT handle.
    ///
    /// Returns an empty string when no name has been set.
    ///
    /// Option key: `"LF_P2P_name"`.
    public static func getP2PName() -> String {
        return getString("LF_P2P_name")
    }

    // ==================================================================
    // Data handle pool
    // ==================================================================

    /// Sets the idle-reclaim threshold, in milliseconds, for
    /// auto-recycled data handles.
    ///
    /// A value greater than zero enables idle reclamation: a handle
    /// that has not been accessed for at least this long becomes a
    /// candidate for release on the next pool scan. The default is
    /// 600,000 ms (10 minutes).
    ///
    /// A value of zero disables idle reclamation entirely. In that
    /// mode, only an explicit `DataHandle.dispose()` releases a handle.
    ///
    /// This option does NOT affect handles created with
    /// `DataHandle.createPermanent(apiName:)`: those are released
    /// synchronously by `dispose()` and never enter the idle-reclaim
    /// path.
    ///
    /// Option key: `"DataHandle_Idle_Timeout"`.
    public static func setDataHandleIdleTimeout(_ ms: UInt64) {
        setUInt64("DataHandle_Idle_Timeout", ms)
    }

    /// Returns the current idle-reclaim threshold, in milliseconds.
    ///
    /// Option key: `"DataHandle_Idle_Timeout"`.
    public static func getDataHandleIdleTimeout() -> UInt64 {
        return getUInt64("DataHandle_Idle_Timeout")
    }

    /// Sets the minimum interval, in milliseconds, between two
    /// consecutive scans of the data-handle pool.
    ///
    /// A value greater than zero enables rate-limiting: the scanner
    /// returns immediately if fewer than this many milliseconds have
    /// elapsed since the last scan. Default: 5,000 ms (5 seconds).
    ///
    /// A value of zero disables the rate limiter. The scanner then runs
    /// on every progress tick of the simulated main thread, which can
    /// be a significant CPU cost under a busy main loop.
    ///
    /// Option key: `"DataHandle_Pool_Scan_Interval"`.
    public static func setDataHandlePoolScanInterval(_ ms: UInt64) {
        setUInt64("DataHandle_Pool_Scan_Interval", ms)
    }

    /// Returns the current data-handle pool scan interval, in
    /// milliseconds.
    ///
    /// Option key: `"DataHandle_Pool_Scan_Interval"`.
    public static func getDataHandlePoolScanInterval() -> UInt64 {
        return getUInt64("DataHandle_Pool_Scan_Interval")
    }

    // ==================================================================
    // Command flushing
    // ==================================================================

    /// Sets the null-flush threshold for no-response commands.
    ///
    /// The protocol periodically sends a NULL command to force the
    /// server to acknowledge pending one-way Notify messages. After
    /// every N no-response commands, one NULL command is emitted as a
    /// flush point.
    ///
    /// A lower value gives more timely acknowledgement at a slight
    /// cost in bandwidth; a higher value is more efficient but delays
    /// the server-side visibility of Notify deliveries.
    ///
    /// Default: 5,000.
    ///
    /// {!!!!!  SPELLING NOTE  !!!!!}
    /// The option key uses the historical spelling `"Reponse"` (without
    /// the second 's'). This is intentional and matches the native
    /// layer and the C++ / C# / Python / Rust bindings.
    ///
    /// Option key: `"No_Reponse_Cmd_NULL_Flush_Threshold"`.
    public static func setNoReponseCmdNullFlushThreshold(_ value: Int32) {
        setInt32("No_Reponse_Cmd_NULL_Flush_Threshold", value)
    }

    /// Returns the current null-flush threshold.
    ///
    /// Option key: `"No_Reponse_Cmd_NULL_Flush_Threshold"`.
    public static func getNoReponseCmdNullFlushThreshold() -> Int32 {
        return getInt32("No_Reponse_Cmd_NULL_Flush_Threshold")
    }

    // ==================================================================
    // Private primitives
    // ------------------------------------------------------------------
    // These four helpers are the ONLY places in this file that touch
    // the raw C ABI. Every public function above delegates to one of
    // them.
    //
    // The naming convention is intentionally explicit:
    //
    //     setString / getString    raw string pass-through
    //     setBool   / getBool      Bool <-> "True" / "False"
    //     setUInt64 / getUInt64    UInt64 <-> decimal string
    //     setInt32  / getInt32     Int32  <-> decimal string
    //
    // The Boolean wire form ("True" / "False") matches the value
    // produced by the C++ side's `lf_set_bool_opt` and consumed by
    // `lf_get_bool_opt`. It also matches the form used by the other
    // language bindings.
    // ==================================================================

    /// Writes `value` into the named runtime option, verbatim.
    private static func setString(_ key: String, _ value: String) {
        LF_SetOption(key, value)
    }

    /// Reads the named runtime option as a UTF-8 string.
    ///
    /// Returns an empty string when the option is unknown, when it has
    /// no value, or when the underlying C string is NULL.
    ///
    /// The native pointer is a transient buffer released ~5 seconds
    /// after the call; `String(cString:)` copies it immediately, so
    /// the returned string is fully detached and safe to retain.
    private static func getString(_ key: String) -> String {
        guard let ptr = LF_GetOption(key) else { return "" }
        return String(cString: ptr)
    }

    /// Writes a Boolean value as the canonical "True" / "False" string.
    private static func setBool(_ key: String, _ value: Bool) {
        setString(key, value ? "True" : "False")
    }

    /// Reads a Boolean value.
    ///
    /// Comparison is case-insensitive and matches only `"True"`,
    /// mirroring the C++ side's `lf_str_eq_ci(v, "True")` helper. An
    /// empty or unrecognised value yields `false`.
    private static func getBool(_ key: String) -> Bool {
        return getString(key).caseInsensitiveCompare("True") == .orderedSame
    }

    /// Writes an unsigned integer as a decimal string.
    private static func setUInt64(_ key: String, _ value: UInt64) {
        setString(key, String(value))
    }

    /// Reads an unsigned integer.
    ///
    /// Returns 0 when the stored value is empty or cannot be parsed as
    /// a decimal integer. A leading sign and trailing non-digit
    /// characters are ignored, matching the C++ side's
    /// `strtoull`-based parsing.
    private static func getUInt64(_ key: String) -> UInt64 {
        let s = getString(key)
        if s.isEmpty { return 0 }
        var digits = String()
        for c in s {
            if c.isNumber {
                digits.append(c)
            } else {
                break
            }
        }
        if digits.isEmpty { return 0 }
        return UInt64(digits) ?? 0
    }

    /// Writes a signed integer as a decimal string.
    private static func setInt32(_ key: String, _ value: Int32) {
        setString(key, String(value))
    }

    /// Reads a signed integer.
    ///
    /// Returns 0 when the stored value is empty or cannot be parsed as
    /// a decimal integer. A leading "-" or "+" is accepted; trailing
    /// non-digit characters are ignored, matching the C++ side's
    /// `strtoll`-based parsing.
    private static func getInt32(_ key: String) -> Int32 {
        let s = getString(key)
        if s.isEmpty { return 0 }

        var digits = String()
        var first = true
        for c in s {
            if first && (c == "-" || c == "+") {
                digits.append(c)
                first = false
            } else if c.isNumber {
                digits.append(c)
                first = false
            } else {
                break
            }
        }
        if digits.isEmpty || digits == "-" || digits == "+" {
            return 0
        }
        return Int32(digits) ?? 0
    }
}