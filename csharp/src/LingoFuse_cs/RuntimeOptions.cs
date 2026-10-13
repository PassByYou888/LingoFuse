// ============================================================================
// File: csharp/src/LingoFuse_cs/RuntimeOptions.cs
// ============================================================================
// RuntimeOptions — strongly typed access to every LF_SetOption /
// LF_GetOption key exposed by the C ABI.
// ============================================================================
// WHY THIS FILE EXISTS
// --------------------
// The C ABI exposes its runtime configuration through two stringly
// typed functions:
//
//     LF_SetOption(optionName, value)
//     LF_GetOption(optionName) -> string
//
// That interface is deliberately permissive. Unknown option names are
// silently ignored, boolean values are parsed from text ("True",
// "False", "1", "0", "Yes", "No"), and integer values are parsed from
// decimal strings. The design is fine for a C ABI, but it is a poor
// fit for C#:
//
//   * A typo in the option name produces no error and no diagnostic.
//     The application silently behaves as if the option had never
//     been set.
//
//   * Callers must remember the exact string for each option and its
//     aliases ("ShowThreadID" vs "ShowThread" vs "Show_Thread",
//     "LF_P2P_name" vs "P2P_name" vs "LF_P2P" vs "P2P").
//
//   * Values arrive as strings and must be parsed by hand. The
//     conversion rules (which accepted spellings map to true / false,
//     what happens on an empty string, how overflow is treated) are
//     not documented on the ABI surface.
//
//   * There is no discoverable list of supported options. Callers
//     must consult documentation or the Pascal source to learn what
//     is available.
//
// RuntimeOptions wraps that surface with one strongly typed property
// per option. Each property:
//
//   * uses the canonical option key on the wire, so callers cannot
//     get the spelling wrong,
//   * converts between the CLR type and the wire format using a
//     single, documented policy,
//   * is covered by XML documentation that explains its effect,
//     its default, and any relevant trade-offs.
//
// The two raw entry points LF_SetOption / LF_GetOption remain
// available through Framework.SetOption and RuntimeOptions.GetRaw /
// SetRaw, so the abstraction is not a wall: it is a convenience layer
// that also serves as the discoverable list of supported options.
//
// VALUE FORMAT POLICY
// -------------------
// The wire format for each CLR type is fixed:
//
//   bool    -> "True" or "False" (capitalized exactly as shown).
//              The ABI also accepts "1", "0", "Yes", "No", and
//              case-insensitive spellings of all four, but the
//              binding always writes the canonical "True" / "False"
//              form so that the wire bytes are deterministic.
//
//   int     -> decimal string, using the invariant culture. Negative
//              values are written with a leading '-'.
//
//   ulong   -> decimal string, using the invariant culture.
//
//   string  -> verbatim text, no escaping.
//
// READING POLICY
// --------------
// Getters return the option's current value as reported by
// LF_GetOption. The ABI returns an empty string for unknown options
// and for options that have never been set; this binding maps that
// empty string to a type-appropriate default:
//
//   bool    -> false
//   int     -> 0
//   ulong   -> 0
//   string  -> ""
//
// The bool parser additionally accepts the alternate spellings the
// ABI itself accepts ("1", "0", "Yes", "No", and lowercase forms), so
// that an option set through Framework.SetOption with a non-canonical
// spelling still reads back correctly.
//
// SCOPE AND LIFETIME
// ------------------
// Options are PROCESS-GLOBAL and are lost on LF_Shutdown. An
// application that restarts the framework must reapply its options.
// There is no per-App or per-Client option scope.
//
// THREAD SAFETY
// -------------
// Both underlying ABI functions are thread-safe. RuntimeOptions adds
// no locking of its own; concurrent writers and readers behave the
// same way as the ABI, which is to say that a setter is visible to a
// subsequent reader on another thread but the two may interleave.
// Applications that require a consistent multi-option snapshot must
// serialise their own updates.
//
// ============================================================================

using System;
using System.Globalization;

using LingoFuse.Native;

namespace LingoFuse;

/// <summary>
/// Strongly typed access to the LingoFuse runtime options.
/// </summary>
/// <remarks>
/// <para>
/// Every property in this class maps to one <c>LF_SetOption</c> /
/// <c>LF_GetOption</c> key. Getting and setting a property is
/// equivalent to calling the corresponding ABI function, except that
/// the CLR type system enforces the correct spelling of both the
/// option name and the value.
/// </para>
/// <para>
/// Options are process-global and are lost when
/// <see cref="Framework.Shutdown"/> is called. Reapply them on every
/// framework restart.
/// </para>
/// <para>
/// For an option that is not covered here (for example, a future ABI
/// extension), use <see cref="GetRaw"/> and <see cref="SetRaw"/> to
/// access the underlying string interface directly.
/// </para>
/// </remarks>
public static class RuntimeOptions
{
    // ====================================================================
    // Raw escape hatch
    // ====================================================================

    /// <summary>
    /// Reads an option by its wire key.
    /// </summary>
    /// <param name="optionName">
    /// The exact option key (case-insensitive aliases are accepted by
    /// the ABI). Must not be null.
    /// </param>
    /// <returns>
    /// The option's current value, or an empty string when the option
    /// is unknown or has never been set.
    /// </returns>
    /// <exception cref="ArgumentNullException">
    /// Thrown when <paramref name="optionName"/> is null.
    /// </exception>
    public static string GetRaw(string optionName)
    {
        ArgumentNullException.ThrowIfNull(optionName);
        return GetOptionRaw(optionName);
    }

    /// <summary>
    /// Writes an option by its wire key.
    /// </summary>
    /// <param name="optionName">
    /// The exact option key (case-insensitive aliases are accepted by
    /// the ABI). Must not be null. Unknown keys are silently ignored
    /// by the ABI.
    /// </param>
    /// <param name="value">
    /// The value to write, in the ABI's accepted format. Must not be
    /// null.
    /// </param>
    /// <exception cref="ArgumentNullException">
    /// Thrown when either argument is null.
    /// </exception>
    public static void SetRaw(string optionName, string value)
    {
        ArgumentNullException.ThrowIfNull(optionName);
        ArgumentNullException.ThrowIfNull(value);
        SetOptionRaw(optionName, value);
    }

    // ====================================================================
    // Authentication
    // ====================================================================

    /// <summary>
    /// The C4 P2PVM authentication token.
    /// </summary>
    /// <remarks>
    /// <para>
    /// Must match on both sides of a connection or the handshake
    /// fails. The default is a well-known development token
    /// (<c>DTC40@ZSERVER</c>); a production deployment should set a
    /// private value before <see cref="Framework.PrepareService"/>
    /// or <see cref="Framework.PrepareClient"/>.
    /// </para>
    /// <para>
    /// <b>Getter behaviour:</b> the underlying ABI always returns a
    /// fixed mask (<c>********</c>) instead of the real password. The
    /// value returned by this property is that mask, not the secret.
    /// Do not rely on this property to recover a password; store the
    /// secret in your own configuration.
    /// </para>
    /// <para>
    /// Underlying option key: <c>password</c> (alias: <c>passwd</c>).
    /// </para>
    /// </remarks>
    public static string Password
    {
        get => GetOptionRaw("password");
        set
        {
            ArgumentNullException.ThrowIfNull(value);
            SetOptionRaw("password", value);
        }
    }

    // ====================================================================
    // Logging and diagnostics
    // ====================================================================

    /// <summary>
    /// Whether the framework runs in quiet mode.
    /// </summary>
    /// <remarks>
    /// <para>
    /// When quiet mode is enabled, most internal informational logging
    /// is suppressed. Debug messages emitted by the Pascal-side
    /// LF_Debug_Log are gated by this flag.
    /// </para>
    /// <para>
    /// Default: <c>false</c> (logging enabled).
    /// </para>
    /// <para>
    /// Underlying option key: <c>Quiet</c>.
    /// </para>
    /// </remarks>
    public static bool Quiet
    {
        get => ParseBool(GetOptionRaw("Quiet"));
        set => SetOptionRaw("Quiet", value ? "True" : "False");
    }

    /// <summary>
    /// Whether thread IDs are prefixed onto status messages.
    /// </summary>
    /// <remarks>
    /// <para>
    /// When enabled, every status message emitted by the Z.Status
    /// subsystem is prefixed with the numeric ID of the thread that
    /// produced it. This is the single most useful diagnostic when
    /// debugging which worker thread runs a callback.
    /// </para>
    /// <para>
    /// Default: <c>true</c> on the CLI, <c>false</c> for a library
    /// host. The ABI's own default is <c>true</c>.
    /// </para>
    /// <para>
    /// Underlying option key: <c>ShowThreadID</c> (aliases:
    /// <c>ShowThread</c>, <c>Show_Thread</c>).
    /// </para>
    /// </remarks>
    public static bool ShowThreadId
    {
        get => ParseBool(GetOptionRaw("ShowThreadID"));
        set => SetOptionRaw("ShowThreadID", value ? "True" : "False");
    }

    /// <summary>
    /// Whether status messages are echoed to the process's standard
    /// output.
    /// </summary>
    /// <remarks>
    /// <para>
    /// When enabled, the Z.Status subsystem writes every status
    /// message to stdout. When disabled, messages are still queued
    /// and remain readable through
    /// <see cref="LingoFuseStatus.GetStatus"/>; only the console sink
    /// is muted.
    /// </para>
    /// <para>
    /// Default: <c>true</c> for a console process, <c>false</c> for
    /// a GUI or library host. The binding sets this automatically at
    /// load time based on the host type.
    /// </para>
    /// <para>
    /// Underlying option key: <c>ConsoleOutput</c> (alias:
    /// <c>Console_Output</c>).
    /// </para>
    /// </remarks>
    public static bool ConsoleOutput
    {
        get => ParseBool(GetOptionRaw("ConsoleOutput"));
        set => SetOptionRaw("ConsoleOutput", value ? "True" : "False");
    }

    /// <summary>
    /// Executes a C4 console debug command.
    /// </summary>
    /// <param name="command">
    /// The command to run. Must not be null. Recognised command names
    /// include <c>service</c>, <c>tunnel</c>, <c>ZNet_Info</c>,
    /// <c>HPC_Thread_Info</c>, and <c>Instance_Info</c>.
    /// </param>
    /// <remarks>
    /// <para>
    /// This option is <b>write-only</b>. Each call constructs a
    /// transient helper object on the Pascal side and runs the given
    /// command against the current framework state. There is no way
    /// to read the debug option back through the ABI; the getter
    /// would return a fixed placeholder string.
    /// </para>
    /// <para>
    /// Because each call allocates a helper object, this method is
    /// intended for interactive diagnostics only. Do not call it in a
    /// hot loop.
    /// </para>
    /// <para>
    /// Underlying option key: <c>debug</c> (aliases: <c>debug_cmd</c>,
    /// <c>debug_command</c>, <c>debugcommand</c>).
    /// </para>
    /// </remarks>
    /// <exception cref="ArgumentNullException">
    /// Thrown when <paramref name="command"/> is null.
    /// </exception>
    public static void SetDebugCommand(string command)
    {
        ArgumentNullException.ThrowIfNull(command);
        SetOptionRaw("debug", command);
    }

    // ====================================================================
    // Connection readiness
    // ====================================================================

    /// <summary>
    /// Whether multiple client tunnels may share the same physical
    /// address.
    /// </summary>
    /// <remarks>
    /// <para>
    /// <c>false</c> (the default): only one client tunnel per
    /// physical address. A second
    /// <see cref="Framework.PrepareClient"/> call for the same
    /// address returns <c>-1</c> and the new application handle is
    /// discarded.
    /// </para>
    /// <para>
    /// <c>true</c>: every <see cref="Framework.PrepareClient"/> call
    /// creates a new independent tunnel, binding the supplied
    /// application handle.
    /// </para>
    /// <para>
    /// <b>Effective time:</b> this option must be set BEFORE the
    /// <see cref="Framework.PrepareClient"/> calls it is meant to
    /// affect. Changing it after a tunnel has been created does not
    /// rearrange existing tunnels.
    /// </para>
    /// <para>
    /// Underlying option key: <c>Overlap_Connection</c> (aliases:
    /// <c>Overlap_Client</c>, <c>OverlapConnection</c>,
    /// <c>OverlapClient</c>, <c>OverlapConnect</c>).
    /// </para>
    /// </remarks>
    public static bool OverlapConnection
    {
        get => ParseBool(GetOptionRaw("Overlap_Connection"));
        set => SetOptionRaw("Overlap_Connection", value ? "True" : "False");
    }

    /// <summary>
    /// Whether <see cref="Framework.PrepareDone"/> blocks until every
    /// prepared client is online.
    /// </summary>
    /// <remarks>
    /// <para>
    /// <c>true</c> (the default): <c>PrepareDone</c> waits for all
    /// prepared clients to reach the "online" state before returning.
    /// </para>
    /// <para>
    /// <c>false</c>: <c>PrepareDone</c> returns immediately after the
    /// simulated main thread has started. The caller is then
    /// responsible for probing readiness itself (for example with
    /// <see cref="Framework.CheckApi"/> in a retry loop).
    /// </para>
    /// <para>
    /// The total wait is bounded by
    /// <see cref="WaitConnectionTimeoutMs"/>.
    /// </para>
    /// <para>
    /// Underlying option key: <c>Wait_Connection_ReadyOk</c>
    /// (aliases: <c>Wait_API_Prepare_Done</c>,
    /// <c>API_Prepare_Done_Wait</c>, <c>WaitConnect</c>,
    /// <c>Wait_Ready</c>, <c>WaitReady</c>).
    /// </para>
    /// </remarks>
    public static bool WaitConnectionReadyOk
    {
        get => ParseBool(GetOptionRaw("Wait_Connection_ReadyOk"));
        set => SetOptionRaw("Wait_Connection_ReadyOk",
            value ? "True" : "False");
    }

    /// <summary>
    /// The timeout, in milliseconds, for the
    /// <see cref="Framework.PrepareDone"/> wait.
    /// </summary>
    /// <remarks>
    /// <para>
    /// Default: 30000 ms (30 seconds). The ABI imposes a floor of
    /// 5000 ms when the wait is actually performed; lower values are
    /// silently raised.
    /// </para>
    /// <para>
    /// If the timeout expires before every client is ready, the
    /// framework still reports success. The caller must
    /// independently verify readiness if that matters.
    /// </para>
    /// <para>
    /// Underlying option key: <c>Wait_Connection_Timeout</c>
    /// (aliases: <c>Wait_TimeOut</c>,
    /// <c>API_Prepare_Done_TimeOut</c>, <c>WaitTimeOut</c>).
    /// </para>
    /// </remarks>
    public static ulong WaitConnectionTimeoutMs
    {
        get => ParseUInt64(GetOptionRaw("Wait_Connection_Timeout"));
        set => SetOptionRaw("Wait_Connection_Timeout",
            FormatUInt64(value));
    }

    // ====================================================================
    // Inter-process communication
    // ====================================================================

    /// <summary>
    /// The size of the IPC server thread pool.
    /// </summary>
    /// <remarks>
    /// <para>
    /// Must be set BEFORE the IPC server is started. Changing it
    /// after startup has no effect on an already-running server.
    /// </para>
    /// <para>
    /// Default: platform-dependent.
    /// </para>
    /// <para>
    /// Underlying option key: <c>IPC_Serv_ThreadCount</c> (aliases:
    /// <c>IPC_ThreadCount</c>, <c>IPC_Server_ThreadCount</c>).
    /// </para>
    /// </remarks>
    public static int IpcServerThreadCount
    {
        get => ParseInt32(GetOptionRaw("IPC_Serv_ThreadCount"));
        set => SetOptionRaw("IPC_Serv_ThreadCount", FormatInt32(value));
    }

    /// <summary>
    /// The maximum length of the IPC server's inbound message queue.
    /// </summary>
    /// <remarks>
    /// <para>
    /// Must be set BEFORE the IPC server is started.
    /// </para>
    /// <para>
    /// Underlying option key: <c>IPC_Serv_MaxQueueLength</c>
    /// (aliases: <c>IPC_MaxQueueLength</c>,
    /// <c>IPC_Server_MaxQueueLength</c>).
    /// </para>
    /// </remarks>
    public static int IpcServerMaxQueueLength
    {
        get => ParseInt32(GetOptionRaw("IPC_Serv_MaxQueueLength"));
        set => SetOptionRaw("IPC_Serv_MaxQueueLength",
            FormatInt32(value));
    }

    /// <summary>
    /// The maximum size, in bytes, of a single IPC message.
    /// </summary>
    /// <remarks>
    /// <para>
    /// Must be set BEFORE the IPC server is started.
    /// </para>
    /// <para>
    /// Underlying option key: <c>IPC_Serv_MaxMsgSize</c> (aliases:
    /// <c>IPC_MaxMsgSize</c>, <c>IPC_Server_MaxMsgSize</c>).
    /// </para>
    /// </remarks>
    public static int IpcServerMaxMsgSize
    {
        get => ParseInt32(GetOptionRaw("IPC_Serv_MaxMsgSize"));
        set => SetOptionRaw("IPC_Serv_MaxMsgSize", FormatInt32(value));
    }

    // ====================================================================
    // Sequenced notifications
    // ====================================================================

    /// <summary>
    /// The sticky-affinity window, in milliseconds, for P2PName load
    /// balancing.
    /// </summary>
    /// <remarks>
    /// <para>
    /// When the server-side dispatcher routes a P2PName-addressed
    /// call, it normally picks the target with the smallest
    /// Cycle_Anchor value (pure round-robin). If a single target has
    /// been handling requests for longer than this value, the
    /// dispatcher switches to a different target instead, to avoid
    /// starvation.
    /// </para>
    /// <para>
    /// Default: 20000 ms (20 seconds).
    /// </para>
    /// <para>
    /// Underlying option key: <c>Fixed_Sequenced_Time</c> (alias:
    /// <c>Fixed_Sequenced_Life</c>).
    /// </para>
    /// </remarks>
    public static ulong FixedSequencedTimeMs
    {
        get => ParseUInt64(GetOptionRaw("Fixed_Sequenced_Time"));
        set => SetOptionRaw("Fixed_Sequenced_Time",
            FormatUInt64(value));
    }

    // ====================================================================
    // P2P group name
    // ====================================================================

    /// <summary>
    /// This process's P2P group name.
    /// </summary>
    /// <remarks>
    /// <para>
    /// The name is injected into every outbound request payload and
    /// is reported to the server through the Update_UID command. It
    /// defines which P2PName-addressed calls this process is willing
    /// to receive.
    /// </para>
    /// <para>
    /// May be changed at any time. The framework picks up the new
    /// name on the next outbound request; there is no need to
    /// reconnect.
    /// </para>
    /// <para>
    /// Default: empty string ("not a member of any group"). An empty
    /// P2P name disables P2PName routing for this process; UID and
    /// App-name routing are unaffected.
    /// </para>
    /// <para>
    /// Underlying option key: <c>LF_P2P_name</c> (aliases:
    /// <c>P2P_name</c>, <c>LF_P2P</c>, <c>P2P</c>).
    /// </para>
    /// <para>
    /// <b>Do not confuse this with the sender's identity.</b> This
    /// property sets the LOCAL process's group name. To read the
    /// SENDER's P2P name from an inbound request, use
    /// <c>DataHandle.GetSenderP2PName</c> inside a callback.
    /// </para>
    /// </remarks>
    public static string P2PName
    {
        get => GetOptionRaw("LF_P2P_name");
        set
        {
            ArgumentNullException.ThrowIfNull(value);
            SetOptionRaw("LF_P2P_name", value);
        }
    }

    // ====================================================================
    // Data handle pool
    // ====================================================================

    /// <summary>
    /// The idle-reclaim threshold, in milliseconds, for auto-recycled
    /// data handles.
    /// </summary>
    /// <remarks>
    /// <para>
    /// A value greater than zero enables idle reclamation: a handle
    /// that has not been accessed for at least this long becomes a
    /// candidate for release on the next pool scan. The default is
    /// 600000 ms (10 minutes).
    /// </para>
    /// <para>
    /// A value of zero disables idle reclamation entirely. In that
    /// mode, only an explicit <see cref="DataHandle.Dispose"/> (which
    /// calls LF_FreeData) releases a handle.
    /// </para>
    /// <para>
    /// This option does NOT affect permanent handles created with
    /// <see cref="DataHandle.CreatePermanent"/>: those are released
    /// synchronously by <c>Dispose</c> and never enter the
    /// idle-reclaim path.
    /// </para>
    /// <para>
    /// Underlying option key: <c>DataHandle_Idle_Timeout</c>
    /// (aliases: <c>Data_Idle_Timeout</c>, <c>Idle_Timeout</c>).
    /// </para>
    /// </remarks>
    public static ulong DataHandleIdleTimeoutMs
    {
        get => ParseUInt64(GetOptionRaw("DataHandle_Idle_Timeout"));
        set => SetOptionRaw("DataHandle_Idle_Timeout",
            FormatUInt64(value));
    }

    /// <summary>
    /// The minimum interval, in milliseconds, between two consecutive
    /// scans of the data-handle pool.
    /// </summary>
    /// <remarks>
    /// <para>
    /// A value greater than zero enables rate-limiting: the scanner
    /// returns immediately if fewer than this many milliseconds have
    /// elapsed since the last scan. Default: 5000 ms (5 seconds).
    /// </para>
    /// <para>
    /// A value of zero disables the rate limiter. The scanner then
    /// runs on every progress tick of the simulated main thread,
    /// which can be a significant CPU cost under a busy main loop.
    /// </para>
    /// <para>
    /// Underlying option key: <c>DataHandle_Pool_Scan_Interval</c>
    /// (aliases: <c>Data_Scan_Interval</c>,
    /// <c>DataHandle_Scan_Interval</c>).
    /// </para>
    /// </remarks>
    public static ulong DataHandlePoolScanIntervalMs
    {
        get => ParseUInt64(
            GetOptionRaw("DataHandle_Pool_Scan_Interval"));
        set => SetOptionRaw("DataHandle_Pool_Scan_Interval",
            FormatUInt64(value));
    }

    // ====================================================================
    // Command flushing
    // ====================================================================

    /// <summary>
    /// The null-flush threshold for no-response commands.
    /// </summary>
    /// <remarks>
    /// <para>
    /// The LingoFuse protocol periodically sends a NULL command to
    /// force the server to acknowledge pending one-way Notify
    /// messages. After every N no-response commands, one NULL
    /// command is emitted as a flush point.
    /// </para>
    /// <para>
    /// A lower value gives more timely acknowledgement at a slight
    /// cost in bandwidth; a higher value is more efficient but
    /// delays the server-side visibility of Notify deliveries.
    /// </para>
    /// <para>
    /// Default: 5000.
    /// </para>
    /// <para>
    /// The option key retains the historical spelling
    /// <c>No_Reponse_Cmd_NULL_Flush_Threshold</c> (missing the second
    /// 's' in "Response"). This is intentional and matches the Pascal
    /// helper name; the property name uses the correct spelling for
    /// readability.
    /// </para>
    /// </remarks>
    public static int NoReponseCmdNullFlushThreshold
    {
        get => ParseInt32(
            GetOptionRaw("No_Reponse_Cmd_NULL_Flush_Threshold"));
        set => SetOptionRaw("No_Reponse_Cmd_NULL_Flush_Threshold",
            FormatInt32(value));
    }

    // ====================================================================
    // Private helpers
    // ====================================================================

    /// <summary>
    /// Reads an option through the ABI and copies the returned string.
    /// The native side owns the returned buffer and releases it
    /// approximately 5 seconds after the call; the copy is what makes
    /// this safe.
    /// </summary>
    private static string GetOptionRaw(string name)
    {
        IntPtr namePtr = Utf8Marshal.Alloc(name);
        try
        {
            IntPtr result = NativeMethods.LF_GetOption(namePtr);
            return Utf8Marshal.PtrToString(result);
        }
        finally
        {
            Utf8Marshal.Free(namePtr);
        }
    }

    /// <summary>
    /// Writes an option through the ABI.
    /// </summary>
    private static void SetOptionRaw(string name, string value)
    {
        IntPtr namePtr = Utf8Marshal.Alloc(name);
        IntPtr valuePtr = Utf8Marshal.Alloc(value);
        try
        {
            NativeMethods.LF_SetOption(namePtr, valuePtr);
        }
        finally
        {
            Utf8Marshal.Free(namePtr);
            Utf8Marshal.Free(valuePtr);
        }
    }

    /// <summary>
    /// Parses a boolean option value.
    /// </summary>
    /// <remarks>
    /// The ABI writes the canonical "True" / "False" spelling for
    /// every boolean option, but a caller who used
    /// <see cref="Framework.SetOption"/> directly may have written
    /// "1", "0", "Yes", "No", or any case variation of those forms.
    /// The parser accepts all of them, so that a value round-trips
    /// regardless of how it was originally set.
    /// </remarks>
    private static bool ParseBool(string value)
    {
        if (string.IsNullOrEmpty(value))
        {
            return false;
        }

        if (bool.TryParse(value, out bool result))
        {
            return result;
        }

        if (value == "1" ||
            value.Equals("yes", StringComparison.OrdinalIgnoreCase))
        {
            return true;
        }

        // "0", "no", and any other string are treated as false. This
        // matches the ABI's own permissive parser, which falls back
        // to false for anything it does not recognize.
        return false;
    }

    /// <summary>
    /// Parses an integer option value using the invariant culture.
    /// Returns 0 for an unset, empty, or non-numeric value.
    /// </summary>
    private static int ParseInt32(string value)
    {
        if (string.IsNullOrEmpty(value))
        {
            return 0;
        }

        return int.TryParse(
            value,
            NumberStyles.Integer,
            CultureInfo.InvariantCulture,
            out int result)
            ? result
            : 0;
    }

    /// <summary>
    /// Parses an unsigned integer option value using the invariant
    /// culture. Returns 0 for an unset, empty, or non-numeric value.
    /// </summary>
    private static ulong ParseUInt64(string value)
    {
        if (string.IsNullOrEmpty(value))
        {
            return 0UL;
        }

        return ulong.TryParse(
            value,
            NumberStyles.Integer,
            CultureInfo.InvariantCulture,
            out ulong result)
            ? result
            : 0UL;
    }

    /// <summary>
    /// Formats a signed integer for the wire using the invariant
    /// culture. This guarantees a deterministic byte sequence
    /// regardless of the host's locale.
    /// </summary>
    private static string FormatInt32(int value) =>
        value.ToString(CultureInfo.InvariantCulture);

    /// <summary>
    /// Formats an unsigned integer for the wire using the invariant
    /// culture.
    /// </summary>
    private static string FormatUInt64(ulong value) =>
        value.ToString(CultureInfo.InvariantCulture);
}