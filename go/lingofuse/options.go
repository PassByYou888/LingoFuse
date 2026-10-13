package lingofuse

import (
	"strconv"
	"strings"
)

// ---------------------------------------------------------------------------
// Typed option shortcuts
// ---------------------------------------------------------------------------
//
// This file mirrors, one for one, the Pascal-side LF_Set_Opt_* /
// LF_Get_Opt_* helpers and the Python-side set_opt_* / get_opt_*
// functions. Every runtime option the LingoFuse C ABI recognises gets
// exactly one typed setter / getter pair here.
//
// {!!!!!  WHY THESE EXIST  !!!!!}
// The generic SetOption / GetOption pair is stringly typed: a caller
// passes an option name as a string and a value as a string, and the
// native layer silently ignores any name it does not recognise (see
// LF-OPT-001 in the Pascal pitfall knowledge base). That failure mode
// is easy to hit and hard to debug.
//
// The shortcuts in this file:
//
//   - hard-code the canonical option key, so a caller cannot misspell
//     it;
//   - accept and return native Go types (bool / int / uint64 / string)
//     instead of strings;
//   - carry the semantics, default value, and known pitfalls of each
//     option in its own docstring.
//
// {!!!!!  THE GENERIC FUNCTIONS REMAIN AVAILABLE  !!!!!}
// SetOption / GetOption are the primary API for:
//
//   - passing option names dynamically (e.g. from a config file);
//   - using an option that has multiple accepted aliases;
//   - scripting the options as a data-driven key/value sequence.
//
// Both paths call the same underlying native function, so mixing them
// is safe.
//
// {!!!!!  OPTIONS ARE NOT PERSISTED ACROSS SHUTDOWN  !!!!!}
// Every option is reset to its built-in default when Shutdown is
// called. An application that restarts the framework must reapply its
// options on every startup (see LF-OPT-002).
//
// {!!!!!  THREAD SAFETY  !!!!!}
// The underlying native functions are documented as thread-safe, so
// every function in this file is safe to call from any goroutine.
// However:
//
//   - A setter takes effect immediately, so a concurrent reader may
//     observe the old value, the new value, or (for multi-byte string
//     values) a torn read. Applications that require a consistent
//     multi-option configuration should serialise their updates
//     behind their own lock.
//
//   - A numeric getter returns 0 when the underlying string cannot be
//     parsed. This is a defensive fallback that matches the tolerant
//     behaviour of the Pascal and Python bindings; it should not
//     happen in practice because the underlying library only stores
//     values that were successfully parsed by the setter.
//
// {!!!!!  LOGS AND DOCSTRINGS  !!!!!}
// All comments and docstrings are in English, matching the rest of
// the toolchain.

// ---------------------------------------------------------------------------
// Internal helpers
// ---------------------------------------------------------------------------
//
// These four pairs of helpers are the ONLY place in this file that
// touches the raw stringly-typed layer. Every public shortcut below
// delegates to one of them.
//
// The Boolean wire form ("True" / "False") matches the value produced
// by the Pascal-side umlBoolToStr and consumed by the native
// EStrToBool parser. It also matches the form used by the Python
// binding, so the two sides are interchangeable on the wire.

// setBoolOption writes a Boolean option using the canonical
// Pascal-side wire form.
func setBoolOption(key string, value bool) error {
	if value {
		return SetOption(key, "True")
	}
	return SetOption(key, "False")
}

// getBoolOption reads a Boolean option.
//
// The comparison is case-insensitive to match the native parser
// (EStrToBool accepts "True", "true", "TRUE" and similarly for
// False). An empty or unrecognised value yields false, matching the
// Pascal and Python bindings.
func getBoolOption(key string) (bool, error) {
	raw, err := GetOption(key)
	if err != nil {
		return false, err
	}
	return strings.EqualFold(strings.TrimSpace(raw), "True"), nil
}

// setIntOption writes a signed 32-bit integer option as a decimal
// string.
func setIntOption(key string, value int) error {
	return SetOption(key, strconv.Itoa(value))
}

// getIntOption reads a signed 32-bit integer option.
//
// Returns 0 when the stored value is empty or not parseable as a
// decimal integer. This matches the tolerant behaviour of the Pascal
// and Python bindings.
func getIntOption(key string) (int, error) {
	raw, err := GetOption(key)
	if err != nil {
		return 0, err
	}
	raw = strings.TrimSpace(raw)
	if raw == "" {
		return 0, nil
	}
	v, perr := strconv.Atoi(raw)
	if perr != nil {
		return 0, nil
	}
	return v, nil
}

// setU64Option writes an unsigned 64-bit integer option as a decimal
// string.
func setU64Option(key string, value uint64) error {
	return SetOption(key, strconv.FormatUint(value, 10))
}

// getU64Option reads an unsigned 64-bit integer option.
//
// Returns 0 when the stored value is empty or not parseable as a
// decimal unsigned integer.
func getU64Option(key string) (uint64, error) {
	raw, err := GetOption(key)
	if err != nil {
		return 0, err
	}
	raw = strings.TrimSpace(raw)
	if raw == "" {
		return 0, nil
	}
	v, perr := strconv.ParseUint(raw, 10, 64)
	if perr != nil {
		return 0, nil
	}
	return v, nil
}

// ===========================================================================
// Authentication
// ===========================================================================

// SetOptPassword sets the P2PVM / C4 network authentication password.
//
// Must match on both sides of a connection, or the handshake fails.
// The default is the well-known development token; a production
// deployment should set a private value before PrepareService /
// PrepareClient.
//
// Underlying option key : "password"  (alias "passwd")
// Type                  : string
func SetOptPassword(value string) error {
	return SetOption("password", value)
}

// GetOptPassword reads the configured password.
//
// The native library deliberately returns a fixed mask ("********")
// rather than the real value. The mask is produced by the underlying
// option reader, not by this wrapper; do not rely on the returned
// string ever containing the actual password.
//
// Underlying option key : "password"
// Type                  : string (always masked)
func GetOptPassword() (string, error) {
	return GetOption("password")
}

// ===========================================================================
// Logging and diagnostics
// ===========================================================================

// SetOptDebug executes a C4 console debug command.
//
// This option is WRITE-ONLY and has side effects: each call
// constructs a transient console helper object on the Pascal side and
// runs the given command. Recognised command names include "service",
// "tunnel", "ZNet_Info", "HPC_Thread_Info", and "Instance_Info".
//
// Because each call allocates a helper object, this option is
// intended for interactive diagnostics only. Do NOT call it in a hot
// loop.
//
// Underlying option key : "debug"
// Type                  : string (write-only)
func SetOptDebug(value string) error {
	return SetOption("debug", value)
}

// GetOptDebug reads the current value of the debug option.
//
// Because the underlying option is write-only, the native library
// returns a fixed placeholder string rather than a stored value. This
// getter is provided for symmetry with the other getters and for
// callers that iterate over the full option table.
//
// Underlying option key : "debug"
// Type                  : string (placeholder only)
func GetOptDebug() (string, error) {
	return GetOption("debug")
}

// SetOptQuiet enables or disables quiet mode.
//
// When quiet mode is enabled, most internal informational logging is
// suppressed. Debug logs emitted by the native debug logger are gated
// by this flag through C40_QuietMode.
//
// Default: false (logging enabled).
//
// Underlying option key : "Quiet"
// Type                  : boolean
func SetOptQuiet(value bool) error {
	return setBoolOption("Quiet", value)
}

// GetOptQuiet returns true if quiet mode is currently enabled.
//
// Underlying option key : "Quiet"
// Type                  : boolean
func GetOptQuiet() (bool, error) {
	return getBoolOption("Quiet")
}

// SetOptShowThreadID enables or disables thread-ID prefixes in status
// output.
//
// When enabled, every status message emitted by the Z.Status
// subsystem is prefixed with the numeric ID of the thread that
// produced it.
//
// Default: true.
//
// Underlying option key : "ShowThreadID"  (alias "ShowThread")
// Type                  : boolean
func SetOptShowThreadID(value bool) error {
	return setBoolOption("ShowThreadID", value)
}

// GetOptShowThreadID returns true if thread-ID prefixes are enabled.
//
// Underlying option key : "ShowThreadID"
// Type                  : boolean
func GetOptShowThreadID() (bool, error) {
	return getBoolOption("ShowThreadID")
}

// SetOptConsoleOutput enables or disables console output for status
// messages.
//
// When enabled, the Z.Status subsystem writes every status message to
// the process's standard output. When disabled, status messages are
// still queued and remain readable through GetStatus; only the
// console sink is muted.
//
// Default: depends on the host; set explicitly by the native entry
// point based on whether the host is a console or a GUI process.
//
// Underlying option key : "ConsoleOutput"  (alias "Console_Output")
// Type                  : boolean
func SetOptConsoleOutput(value bool) error {
	return setBoolOption("ConsoleOutput", value)
}

// GetOptConsoleOutput returns true if console output is enabled.
//
// Underlying option key : "ConsoleOutput"
// Type                  : boolean
func GetOptConsoleOutput() (bool, error) {
	return getBoolOption("ConsoleOutput")
}

// ===========================================================================
// Connection readiness
// ===========================================================================

// SetOptOverlapConnection allows or forbids multiple client tunnels to
// the same physical address.
//
// false (the default): only one client tunnel per physical address. A
// second PrepareClient call for the same address returns an error and
// the new application handle is discarded.
//
// true: every PrepareClient call creates a new independent tunnel,
// binding the supplied application handle.
//
// This option MUST be set BEFORE the PrepareClient calls it is meant
// to affect. Changing it after a tunnel has been created does not
// rearrange existing tunnels.
//
// Related pitfall IDs: LF-APP-005, LF-APP-006, LF-NET-001,
// LF-OPT-003.
//
// Underlying option key : "Overlap_Connection"
// Type                  : boolean
func SetOptOverlapConnection(value bool) error {
	return setBoolOption("Overlap_Connection", value)
}

// GetOptOverlapConnection returns true if overlapping connections are
// allowed.
//
// Underlying option key : "Overlap_Connection"
// Type                  : boolean
func GetOptOverlapConnection() (bool, error) {
	return getBoolOption("Overlap_Connection")
}

// SetOptWaitConnectionReadyOk controls whether PrepareDone blocks
// until every prepared client is online.
//
// true (the default): PrepareDone waits for all prepared clients to
// reach the "online" state before returning.
//
// false: PrepareDone returns immediately after the simulated main
// thread has started. The caller is then responsible for probing
// readiness itself (for example with CheckApp in a retry loop). This
// is the recommended setting for deployments where the startup order
// of peers is not predictable.
//
// The total wait is bounded by SetOptWaitConnectionTimeout.
//
// Related pitfall IDs: LF-NET-002, LF-NET-004, LF-NET-007.
//
// Underlying option key : "Wait_Connection_ReadyOk"
// Type                  : boolean
func SetOptWaitConnectionReadyOk(value bool) error {
	return setBoolOption("Wait_Connection_ReadyOk", value)
}

// GetOptWaitConnectionReadyOk returns true if PrepareDone currently
// waits for all clients.
//
// Underlying option key : "Wait_Connection_ReadyOk"
// Type                  : boolean
func GetOptWaitConnectionReadyOk() (bool, error) {
	return getBoolOption("Wait_Connection_ReadyOk")
}

// SetOptWaitConnectionTimeout sets the timeout, in milliseconds, for
// the PrepareDone wait described by SetOptWaitConnectionReadyOk.
//
// Default: 30000 ms (30 seconds). If the timeout expires before all
// clients are ready, PrepareDone still returns success; the caller
// must independently verify readiness if that matters.
//
// The native library imposes a floor of 5000 ms on this value when
// the wait is actually performed. Values below that floor are
// silently raised.
//
// Related pitfall IDs: LF-NET-002, LF-NET-007.
//
// Underlying option key : "Wait_Connection_Timeout"
// Type                  : unsigned integer (milliseconds)
func SetOptWaitConnectionTimeout(valueMs uint64) error {
	return setU64Option("Wait_Connection_Timeout", valueMs)
}

// GetOptWaitConnectionTimeout returns the current PrepareDone wait
// timeout, in ms.
//
// Underlying option key : "Wait_Connection_Timeout"
// Type                  : unsigned integer
func GetOptWaitConnectionTimeout() (uint64, error) {
	return getU64Option("Wait_Connection_Timeout")
}

// ===========================================================================
// IPC (Inter-Process Communication)
// ===========================================================================

// SetOptIPCServThreadCount sets the size of the IPC server thread
// pool.
//
// MUST be set before the IPC server is started. Changing it after
// startup has no effect on an already-running server.
//
// Default: platform-dependent.
//
// Underlying option key : "IPC_Serv_ThreadCount"
// Type                  : integer
func SetOptIPCServThreadCount(value int) error {
	return setIntOption("IPC_Serv_ThreadCount", value)
}

// GetOptIPCServThreadCount returns the configured IPC server thread
// count.
//
// Underlying option key : "IPC_Serv_ThreadCount"
// Type                  : integer
func GetOptIPCServThreadCount() (int, error) {
	return getIntOption("IPC_Serv_ThreadCount")
}

// SetOptIPCServMaxQueueLength sets the maximum length of the IPC
// server's inbound message queue.
//
// MUST be set before the IPC server is started.
//
// Underlying option key : "IPC_Serv_MaxQueueLength"
// Type                  : integer
func SetOptIPCServMaxQueueLength(value int) error {
	return setIntOption("IPC_Serv_MaxQueueLength", value)
}

// GetOptIPCServMaxQueueLength returns the configured IPC server max
// queue length.
//
// Underlying option key : "IPC_Serv_MaxQueueLength"
// Type                  : integer
func GetOptIPCServMaxQueueLength() (int, error) {
	return getIntOption("IPC_Serv_MaxQueueLength")
}

// SetOptIPCServMaxMsgSize sets the maximum size, in bytes, of a
// single IPC message.
//
// MUST be set before the IPC server is started.
//
// Underlying option key : "IPC_Serv_MaxMsgSize"
// Type                  : integer
func SetOptIPCServMaxMsgSize(value int) error {
	return setIntOption("IPC_Serv_MaxMsgSize", value)
}

// GetOptIPCServMaxMsgSize returns the configured IPC server max
// message size.
//
// Underlying option key : "IPC_Serv_MaxMsgSize"
// Type                  : integer
func GetOptIPCServMaxMsgSize() (int, error) {
	return getIntOption("IPC_Serv_MaxMsgSize")
}

// ===========================================================================
// Sequenced notifications
// ===========================================================================

// SetOptFixedSequencedTime sets the sticky-affinity window, in
// milliseconds, for P2PName load balancing.
//
// When the server-side dispatcher routes a P2PName-addressed call, it
// normally picks the target with the smallest Cycle_Anchor value
// (pure round-robin). If, however, a single target has been handling
// requests for longer than this value, the dispatcher switches to a
// different target instead, to avoid starvation.
//
// Default: 20000 ms (20 seconds).
//
// Related pitfall IDs: LF-SEQ-001, LF-ROUTE-006.
//
// Underlying option key : "Fixed_Sequenced_Time"
// Type                  : unsigned integer (milliseconds)
func SetOptFixedSequencedTime(valueMs uint64) error {
	return setU64Option("Fixed_Sequenced_Time", valueMs)
}

// GetOptFixedSequencedTime returns the current sticky-affinity window,
// in ms.
//
// Underlying option key : "Fixed_Sequenced_Time"
// Type                  : unsigned integer
func GetOptFixedSequencedTime() (uint64, error) {
	return getU64Option("Fixed_Sequenced_Time")
}

// ===========================================================================
// P2P group name
// ===========================================================================

// SetOptP2PName sets this process's P2P group name.
//
// The name is injected into every outbound request payload and is
// reported to the server through the Update_UID command. It defines
// which P2PName-addressed calls this process is willing to receive.
//
// {!!!!!  THIS IS THE LOCAL DECLARATION  !!!!!}
// The value set here is the name THIS process declares for itself. It
// is distinct from the P2P name that OTHER processes will see when
// they receive a request from us, and it is distinct from the name
// this process reads from an incoming request's INPUT handle via
// DataHandle.GetP2PName(). The latter is "side data": it is the
// FromP2PName field that the sender's transport layer wrote into the
// outbound payload. The two values coincide only because we are the
// sender.
//
// The value may be changed at any time. The framework picks up the
// new name on the next outbound request; there is no need to
// reconnect.
//
// Default: empty string ("not a member of any group"). An empty P2P
// name disables P2PName routing for this process; UID and App-name
// routing are unaffected.
//
// Related pitfall IDs: LF-MECH-010, LF-ROUTE-003.
//
// Underlying option key : "LF_P2P_name"
// Type                  : string
func SetOptP2PName(value string) error {
	return SetOption("LF_P2P_name", value)
}

// GetOptP2PName returns this process's configured P2P group name.
//
// {!!!!!  NOT TO BE CONFUSED WITH DataHandle.GetP2PName  !!!!!}
// This function reads the LOCAL configuration: the value this process
// set for itself through SetOptP2PName. It answers the question "what
// P2P name have I declared for myself?".
//
// It is completely unrelated to DataHandle.GetP2PName, which reads
// the SENDER's P2P name from the INPUT handle of a registered
// callback. In other words:
//
//	GetOptP2PName()         -> MY name (local config)
//	DataHandle.GetP2PName() -> the SENDER's name (side data)
//
// Both names happen to be of the same underlying wire type (a UTF-8
// string), but they come from two different sources and must not be
// confused at any call site.
//
// Returns an empty string when no name has been set.
//
// Underlying option key : "LF_P2P_name"
// Type                  : string
func GetOptP2PName() (string, error) {
	return GetOption("LF_P2P_name")
}

// ===========================================================================
// Data handle pool
// ===========================================================================

// SetOptDataHandleIdleTimeout sets the idle-reclaim threshold, in
// milliseconds, for auto-recycled data handles.
//
// A value greater than zero enables idle reclamation: a handle that
// has not been accessed for at least this long becomes a candidate
// for release on the next pool scan. The default is 600000 ms
// (10 minutes).
//
// A value of zero disables idle reclamation entirely. In that mode,
// only an explicit Close releases a handle.
//
// This option does NOT affect handles created by CreatePermanent:
// those are released synchronously by Close and never enter the
// idle-reclaim path.
//
// Related pitfall IDs: LF-DATA-001, LF-MECH-001.
//
// Underlying option key : "DataHandle_Idle_Timeout"
// Type                  : unsigned integer (milliseconds)
func SetOptDataHandleIdleTimeout(valueMs uint64) error {
	return setU64Option("DataHandle_Idle_Timeout", valueMs)
}

// GetOptDataHandleIdleTimeout returns the current idle-reclaim
// threshold, in ms.
//
// Underlying option key : "DataHandle_Idle_Timeout"
// Type                  : unsigned integer
func GetOptDataHandleIdleTimeout() (uint64, error) {
	return getU64Option("DataHandle_Idle_Timeout")
}

// SetOptDataHandlePoolScanInterval sets the minimum interval, in
// milliseconds, between two consecutive scans of the data-handle
// pool.
//
// A value greater than zero enables rate-limiting: the scanner
// returns immediately if fewer than this many milliseconds have
// elapsed since the last scan. Default: 5000 ms (5 seconds).
//
// A value of zero disables the rate limiter. The scanner then runs on
// every progress tick of the simulated main thread, which can be a
// significant CPU cost under a busy main loop.
//
// The scanner is driven by the simulated main thread, so its
// effective call frequency is bounded below by the main thread's tick
// granularity, not by this value alone.
//
// Underlying option key : "DataHandle_Pool_Scan_Interval"
// Type                  : unsigned integer (milliseconds)
func SetOptDataHandlePoolScanInterval(valueMs uint64) error {
	return setU64Option("DataHandle_Pool_Scan_Interval", valueMs)
}

// GetOptDataHandlePoolScanInterval returns the current data-handle
// pool scan interval, in ms.
//
// Underlying option key : "DataHandle_Pool_Scan_Interval"
// Type                  : unsigned integer
func GetOptDataHandlePoolScanInterval() (uint64, error) {
	return getU64Option("DataHandle_Pool_Scan_Interval")
}

// ===========================================================================
// Command flushing
// ===========================================================================

// SetOptNoReponseCmdNullFlushThreshold sets the null-flush threshold
// for no-response commands.
//
// The LingoFuse protocol periodically sends a NULL command to force
// the server to acknowledge pending one-way Notify messages. After
// every N no-response commands, one NULL command is emitted as a
// flush point.
//
// A lower value gives more timely acknowledgement at a slight cost in
// bandwidth; a higher value is more efficient but delays the
// server-side visibility of Notify deliveries.
//
// Default: 5000.
//
// {!!!!!  SPELLING NOTE  !!!!!}
// The option key uses the historical spelling "Reponse" (without the
// second 's'). The Go helper preserves that spelling in its own name
// so that the two are trivially cross-referenced. The function name
// and the option key are both intentional.
//
// Underlying option key : "No_Reponse_Cmd_NULL_Flush_Threshold"
// Type                  : integer
func SetOptNoReponseCmdNullFlushThreshold(value int) error {
	return setIntOption("No_Reponse_Cmd_NULL_Flush_Threshold", value)
}

// GetOptNoReponseCmdNullFlushThreshold returns the current null-flush
// threshold.
//
// Underlying option key : "No_Reponse_Cmd_NULL_Flush_Threshold"
// Type                  : integer
func GetOptNoReponseCmdNullFlushThreshold() (int, error) {
	return getIntOption("No_Reponse_Cmd_NULL_Flush_Threshold")
}
