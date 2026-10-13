package lingofuse;

import java.util.Objects;

/**
 * Typed shortcuts for the LingoFuse runtime options.
 *
 * <p>This class exposes one typed getter/setter pair for each runtime
 * option that the LingoFuse C ABI recognises. The pairs mirror, one
 * for one, the convenience functions defined by the Pascal-side
 * {@code lingofuse_import.pas} unit:
 *
 * <pre>
 * Pascal                              Java (this class)
 * ------------------------------      -------------------------------
 * LF_Set_Opt_Debug / Get              setDebug / getDebug
 * LF_Set_Opt_P2P_Name / Get           setP2pName / getP2pName
 * LF_Set_Opt_Password / Get           setPassword / getPassword
 * LF_Set_Opt_Quiet / Get              setQuiet / getQuiet
 * ... (16 pairs in total)
 * </pre>
 *
 * <p>Every method is a thin, typed wrapper around {@link Framework#setOption}
 * and {@link Framework#getOption}. Behaviour is byte-for-byte identical:
 * the underlying call path is always
 *
 * <pre>{@code
 * LF_SetOption(cstr(name), cstr(value));
 * LF_GetOption(cstr(name));
 * }</pre>
 *
 * <p>The only difference is that these methods:
 *
 * <ul>
 *   <li>accept and return native Java types ({@code boolean} /
 *       {@code int} / {@code long} / {@link String}) instead of the
 *       stringly-typed option value;</li>
 *   <li>carry the canonical option key internally, so the caller
 *       cannot misspell it;</li>
 *   <li>document the semantics, default value, and known pitfalls of
 *       each option in its own Javadoc.</li>
 * </ul>
 *
 * <h2>The generic setOption / getOption are still available</h2>
 *
 * <p>These typed shortcuts are ADDITIVE. {@link Framework#setOption}
 * and {@link Framework#getOption} remain the primary API for:
 *
 * <ul>
 *   <li>passing option names dynamically (for example, from a config
 *       file);</li>
 *   <li>using an option that has multiple accepted aliases;</li>
 *   <li>scripting the options as a data-driven key/value
 *       sequence.</li>
 * </ul>
 *
 * <p>Both paths share the same underlying C primitive, so mixing them
 * is safe.
 *
 * <h2>Unknown option names are silently ignored</h2>
 *
 * <p>The underlying {@code LF_SetOption} has no return value and does
 * not report an error when it receives an unrecognised option name
 * (see LF-OPT-001 in the Pascal-side pitfall knowledge base). These
 * typed shortcuts eliminate that failure mode by hard-coding the
 * canonical name, but they do NOT change the underlying behaviour:
 * calling {@code Framework.setOption("Typo", "x")} still silently
 * does nothing.
 *
 * <h2>Options are not persisted across LF_Shutdown</h2>
 *
 * <p>Every option is reset to its built-in default when
 * {@link Framework#shutdown()} is called. An application that
 * restarts the framework must reapply its options on every startup
 * (see LF-OPT-002). This applies equally to the typed shortcuts and
 * to the generic helpers.
 *
 * <h2>getP2pName versus DataHandle.getP2pName</h2>
 *
 * <p>These two methods sound similar but are completely unrelated,
 * and they read from two different sources:
 *
 * <ul>
 *   <li>{@link #getP2pName()} reads the P2P group name that THIS
 *       process has declared for itself, through the
 *       {@code LF_P2P_name} runtime option. It is a LOCAL
 *       CONFIGURATION read: it asks "what name did I set for
 *       myself?". It is thread-safe, does not depend on any incoming
 *       call, and returns an empty string when no name has been
 *       set.</li>
 *   <li>{@link DataHandle#getP2pName()} reads the P2P group name of
 *       the SENDER of an incoming request. This value is "SIDE DATA":
 *       it is the {@code FromP2PName} field that the SENDER'S
 *       transport layer injects automatically into every outbound
 *       request payload before transmission (Pascal side:
 *       {@code TC40_LF_Client.Send_*} -&gt;
 *       {@code TMemory_Param_Tool.Rebuild_UID_and_P2PName}). It is
 *       valid ONLY on the INPUT handle of a registered Call or Notify
 *       callback, and it returns the PEER's name, not the local
 *       one.</li>
 * </ul>
 *
 * <p>In short:
 * <pre>
 * Options.getP2pName()         -&gt; MY name (local config)
 * DataHandle.getP2pName()      -&gt; the SENDER's name (side data)
 * </pre>
 *
 * <p>The two are deliberately kept in separate classes and under
 * distinct names so that no call site can confuse them.
 *
 * <h2>Thread safety</h2>
 *
 * <p>The underlying {@code LF_SetOption} / {@code LF_GetOption} are
 * documented as thread-safe, and every method in this class is
 * therefore safe to call from any thread. However:
 *
 * <ul>
 *   <li>A setter takes effect immediately, so a concurrent reader may
 *       observe the old value, the new value, or (for multi-byte
 *       string values) a torn read. Applications that require
 *       consistent multi-field configuration should serialize their
 *       option updates behind their own lock.</li>
 *   <li>A getter for a numeric option returns 0 when the underlying
 *       string cannot be parsed. This is a defensive fallback; it
 *       should not happen in practice because the underlying library
 *       only stores values that were successfully parsed by the
 *       setter.</li>
 * </ul>
 */
public final class Options {

    private Options() {
        // Utility class; no instances.
    }

    // ==================================================================
    // Internal helpers
    // ------------------------------------------------------------------
    // These eight helpers are the ONLY place in this class that touches
    // the raw C ABI. Every public method below delegates to one of them.
    //
    // The naming convention is intentionally explicit:
    //
    //     setStr / getStr   - raw string pass-through
    //     setBool / getBool - boolean <-> "True" / "False"
    //     setInt / getInt   - int <-> decimal string
    //     setLong / getLong - long <-> decimal string
    //
    // The Boolean wire form ("True" / "False") matches the value
    // produced by the Pascal-side umlBoolToStr and consumed by the
    // underlying EStrToBool. It also matches the form used by the
    // existing generic setOption / getOption wrappers, so the two APIs
    // are interchangeable on the wire.
    // ==================================================================

    private static void setStr(String name, String value) {
        Objects.requireNonNull(name, "name must not be null");
        Objects.requireNonNull(value, "value must not be null");
        Framework.setOption(name, value);
    }

    private static String getStr(String name) {
        Objects.requireNonNull(name, "name must not be null");
        return Framework.getOption(name);
    }

    private static void setBool(String name, boolean value) {
        setStr(name, value ? "True" : "False");
    }

    /**
     * Reads a Boolean value.
     *
     * <p>The comparison is case-insensitive to match the parsing rules
     * of the underlying C code (EStrToBool accepts "True", "true",
     * "TRUE" and similarly for False). An empty or unrecognised value
     * yields False, which matches the behaviour of the Pascal-side
     * {@code LF_Get_Opt_*} helpers.
     */
    private static boolean getBool(String name) {
        return "true".equalsIgnoreCase(getStr(name).trim());
    }

    private static void setInt(String name, int value) {
        setStr(name, Integer.toString(value));
    }

    /**
     * Reads an integer value.
     *
     * <p>Returns 0 when the stored value is empty or not parseable as
     * a decimal integer. This mirrors the Pascal-side helpers, which
     * leave the destination variable unchanged on a parse failure and
     * therefore also yield a zero-initialised value in the common
     * case.
     */
    private static int getInt(String name) {
        String raw = getStr(name);
        if (raw == null) {
            return 0;
        }
        try {
            return Integer.parseInt(raw.trim());
        } catch (NumberFormatException e) {
            return 0;
        }
    }

    private static void setLong(String name, long value) {
        setStr(name, Long.toString(value));
    }

    /**
     * Reads a long value. Same defensive fallback as {@link #getInt}.
     */
    private static long getLong(String name) {
        String raw = getStr(name);
        if (raw == null) {
            return 0L;
        }
        try {
            return Long.parseLong(raw.trim());
        } catch (NumberFormatException e) {
            return 0L;
        }
    }

    // ==================================================================
    // Authentication
    // ==================================================================

    /**
     * Sets the P2PVM / C4 network authentication password.
     *
     * <p>The password must match on both sides of a connection, or
     * the handshake will fail. The default is the well-known
     * development token; a production deployment should set a private
     * one before calling {@link Framework#prepareService} /
     * {@link Framework#prepareClient}.
     *
     * <p>Alias accepted by the underlying library: {@code passwd}.
     * Corresponding Pascal helper: {@code LF_Set_Opt_Password}.
     *
     * @param value the password; must not be null
     */
    public static void setPassword(String value) {
        setStr("password", value);
    }

    /**
     * Reads the configured password.
     *
     * <p>The underlying library returns a fixed mask
     * ({@code '********'}) for this option, regardless of the actual
     * password. This is a deliberate security measure: the real value
     * is never exposed through the option-reading API. The return
     * type of this method is therefore a string, but its content is
     * always the mask.
     *
     * <p>Corresponding Pascal helper: {@code LF_Get_Opt_Password}.
     *
     * @return the password mask
     */
    public static String getPassword() {
        return getStr("password");
    }

    // ==================================================================
    // Logging and diagnostics
    // ==================================================================

    /**
     * Executes a C4 console debug command.
     *
     * <p>This option is WRITE-ONLY and has side effects: each call
     * constructs a transient console helper object on the Pascal side
     * and runs the given command. Recognised command names include
     * {@code "service"}, {@code "tunnel"}, {@code "ZNet_Info"},
     * {@code "HPC_Thread_Info"}, {@code "Instance_Info"}, and any
     * other command registered with the C4 console dispatcher.
     *
     * <p>Because each call allocates a helper object, this option is
     * intended for interactive diagnostics only. Do not call it in a
     * hot loop.
     *
     * <p>Corresponding Pascal helper: {@code LF_Set_Opt_Debug}.
     *
     * @param command the debug command; must not be null
     */
    public static void setDebug(String command) {
        setStr("debug", command);
    }

    /**
     * Reads the current value of the debug option.
     *
     * <p>Because the underlying option is write-only, the library
     * returns a fixed placeholder string
     * ({@code '(no value: debug is write-only)'}) rather than a
     * stored value. This method is provided for symmetry with the
     * other getters and for callers that iterate over the full option
     * table.
     *
     * <p>Corresponding Pascal helper: {@code LF_Get_Opt_Debug}.
     *
     * @return the placeholder string
     */
    public static String getDebug() {
        return getStr("debug");
    }

    /**
     * Enables or disables quiet mode.
     *
     * <p>When quiet mode is enabled, most internal informational
     * logging is suppressed. Debug-level logs emitted by the
     * Pascal-side {@code LF_Debug_Log} are gated by this flag through
     * {@code C40_QuietMode}.
     *
     * <p>The default is {@code false} (logging enabled).
     *
     * <p>Related pitfall IDs: LF-OPT-001 (silent unknown option),
     * LF-OPT-002 (options are not persisted across LF_Shutdown).
     *
     * <p>Corresponding Pascal helper: {@code LF_Set_Opt_Quiet}.
     *
     * @param value true to enable quiet mode
     */
    public static void setQuiet(boolean value) {
        setBool("Quiet", value);
    }

    /**
     * Returns true if quiet mode is currently enabled.
     *
     * <p>Corresponding Pascal helper: {@code LF_Get_Opt_Quiet}.
     *
     * @return true when quiet mode is enabled
     */
    public static boolean getQuiet() {
        return getBool("Quiet");
    }

    /**
     * Enables or disables thread-ID prefixes in status output.
     *
     * <p>When enabled, every status message emitted by the Z.Status
     * subsystem is prefixed with the numeric ID of the thread that
     * produced it. This is useful for multi-threaded diagnostics but
     * adds a small per-message cost.
     *
     * <p>The default is {@code true}.
     *
     * <p>Alias accepted by the underlying library: {@code ShowThread}.
     * Corresponding Pascal helper: {@code LF_Set_Opt_ShowThreadID}.
     *
     * @param value true to enable thread-ID prefixes
     */
    public static void setShowThreadId(boolean value) {
        setBool("ShowThreadID", value);
    }

    /**
     * Returns true if thread-ID prefixes are currently enabled.
     *
     * <p>Corresponding Pascal helper: {@code LF_Get_Opt_ShowThreadID}.
     *
     * @return true when thread-ID prefixes are enabled
     */
    public static boolean getShowThreadId() {
        return getBool("ShowThreadID");
    }

    /**
     * Enables or disables console output for status messages.
     *
     * <p>When enabled, the Z.Status subsystem writes every status
     * message to the process's standard output (or console, depending
     * on the platform). When disabled, status messages are still
     * queued and remain readable through {@link LingoFuseStatus#getStatus()}
     * / {@link LingoFuseStatus#getStatusCount()}; only the console
     * sink is muted.
     *
     * <p>The default depends on the host: {@code true} for a console
     * application, {@code false} for a library loaded into a GUI
     * process. The library entry point sets this explicitly at
     * initialisation time.
     *
     * <p>Alias accepted by the underlying library: {@code Console_Output}.
     * Corresponding Pascal helper: {@code LF_Set_Opt_ConsoleOutput}.
     *
     * @param value true to enable console output
     */
    public static void setConsoleOutput(boolean value) {
        setBool("ConsoleOutput", value);
    }

    /**
     * Returns true if console output is currently enabled.
     *
     * <p>Corresponding Pascal helper: {@code LF_Get_Opt_ConsoleOutput}.
     *
     * @return true when console output is enabled
     */
    public static boolean getConsoleOutput() {
        return getBool("ConsoleOutput");
    }

    // ==================================================================
    // Connection readiness
    // ==================================================================

    /**
     * Allows or forbids multiple client tunnels to the same physical
     * address.
     *
     * <p>{@code false} (the default) permits only one client tunnel
     * per physical address. A second {@link Framework#prepareClient}
     * call for the same address returns -1 and the new application
     * handle is discarded.
     *
     * <p>{@code true} makes every {@link Framework#prepareClient}
     * call create a new independent tunnel, binding the supplied
     * application handle.
     *
     * <p>This option MUST be set BEFORE the
     * {@link Framework#prepareClient} calls it is meant to affect.
     * Changing it after a tunnel has been created does not rearrange
     * existing tunnels.
     *
     * <p>Related pitfall IDs: LF-APP-005, LF-APP-006, LF-NET-001,
     * LF-OPT-003.
     *
     * <p>Corresponding Pascal helper:
     * {@code LF_Set_Opt_Overlap_Connection}.
     *
     * @param value true to allow overlapping connections
     */
    public static void setOverlapConnection(boolean value) {
        setBool("Overlap_Connection", value);
    }

    /**
     * Returns true if overlapping connections are currently allowed.
     *
     * <p>Corresponding Pascal helper:
     * {@code LF_Get_Opt_Overlap_Connection}.
     *
     * @return true when overlapping connections are allowed
     */
    public static boolean getOverlapConnection() {
        return getBool("Overlap_Connection");
    }

    /**
     * Controls whether {@link Framework#prepareDone()} blocks until
     * every prepared client is online.
     *
     * <p>{@code true} (the default) makes
     * {@link Framework#prepareDone()} wait for all prepared clients to
     * reach the "online" state before returning. This is the
     * convenient behaviour when the mesh is fully controlled and the
     * peers are known to be up.
     *
     * <p>{@code false} makes {@link Framework#prepareDone()} return
     * immediately after the simulated main thread has started. The
     * caller is then responsible for probing readiness itself (for
     * example with {@link LingoFuseStatus#checkApp(String)} in a
     * retry loop). This is the recommended setting for deployments
     * where the startup order of peers is not predictable.
     *
     * <p>The total wait is bounded by
     * {@link #setWaitConnectionTimeout(long)}.
     *
     * <p>Related pitfall IDs: LF-NET-002, LF-NET-004, LF-NET-007.
     *
     * <p>Corresponding Pascal helper:
     * {@code LF_Set_Opt_Wait_Connection_ReadyOk}.
     *
     * @param value true to block until all clients are online
     */
    public static void setWaitConnectionReadyOk(boolean value) {
        setBool("Wait_Connection_ReadyOk", value);
    }

    /**
     * Returns true if {@link Framework#prepareDone()} currently waits
     * for all clients.
     *
     * <p>Corresponding Pascal helper:
     * {@code LF_Get_Opt_Wait_Connection_ReadyOk}.
     *
     * @return true when prepareDone blocks for readiness
     */
    public static boolean getWaitConnectionReadyOk() {
        return getBool("Wait_Connection_ReadyOk");
    }

    /**
     * Sets the timeout, in milliseconds, for the
     * {@link Framework#prepareDone()} wait described by
     * {@link #setWaitConnectionReadyOk(boolean)}.
     *
     * <p>The default is 30,000 ms (30 seconds). If the timeout expires
     * before all clients are ready, {@link Framework#prepareDone()}
     * still returns 1; the caller must independently verify readiness
     * if that matters (see LF-NET-007).
     *
     * <p>The library imposes a floor of 5,000 ms on this value when
     * the wait is actually performed. Values below that floor are
     * silently raised.
     *
     * <p>Related pitfall IDs: LF-NET-002, LF-NET-007.
     *
     * <p>Corresponding Pascal helper:
     * {@code LF_Set_Opt_Wait_Connection_Timeout}.
     *
     * @param valueMs the timeout in milliseconds
     */
    public static void setWaitConnectionTimeout(long valueMs) {
        setLong("Wait_Connection_Timeout", valueMs);
    }

    /**
     * Returns the current {@link Framework#prepareDone()} wait
     * timeout, in ms.
     *
     * <p>Corresponding Pascal helper:
     * {@code LF_Get_Opt_Wait_Connection_Timeout}.
     *
     * @return the timeout in milliseconds
     */
    public static long getWaitConnectionTimeout() {
        return getLong("Wait_Connection_Timeout");
    }

    // ==================================================================
    // IPC (Inter-Process Communication)
    // ==================================================================

    /**
     * Sets the size of the IPC server thread pool.
     *
     * <p>This option MUST be set before the IPC server is started.
     * Changing it after startup has no effect on an already-running
     * server.
     *
     * <p>The default is platform-dependent.
     *
     * <p>Corresponding Pascal helper:
     * {@code LF_Set_Opt_IPC_Serv_ThreadCount}.
     *
     * @param value the number of threads
     */
    public static void setIpcServThreadCount(int value) {
        setInt("IPC_Serv_ThreadCount", value);
    }

    /**
     * Returns the configured IPC server thread count.
     *
     * <p>Corresponding Pascal helper:
     * {@code LF_Get_Opt_IPC_Serv_ThreadCount}.
     *
     * @return the configured thread count
     */
    public static int getIpcServThreadCount() {
        return getInt("IPC_Serv_ThreadCount");
    }

    /**
     * Sets the maximum length of the IPC server's inbound message
     * queue.
     *
     * <p>This option MUST be set before the IPC server is started.
     *
     * <p>Corresponding Pascal helper:
     * {@code LF_Set_Opt_IPC_Serv_MaxQueueLength}.
     *
     * @param value the maximum queue length
     */
    public static void setIpcServMaxQueueLength(int value) {
        setInt("IPC_Serv_MaxQueueLength", value);
    }

    /**
     * Returns the configured IPC server max queue length.
     *
     * <p>Corresponding Pascal helper:
     * {@code LF_Get_Opt_IPC_Serv_MaxQueueLength}.
     *
     * @return the configured max queue length
     */
    public static int getIpcServMaxQueueLength() {
        return getInt("IPC_Serv_MaxQueueLength");
    }

    /**
     * Sets the maximum size, in bytes, of a single IPC message.
     *
     * <p>This option MUST be set before the IPC server is started.
     *
     * <p>Corresponding Pascal helper:
     * {@code LF_Set_Opt_IPC_Serv_MaxMsgSize}.
     *
     * @param value the maximum message size in bytes
     */
    public static void setIpcServMaxMsgSize(int value) {
        setInt("IPC_Serv_MaxMsgSize", value);
    }

    /**
     * Returns the configured IPC server max message size.
     *
     * <p>Corresponding Pascal helper:
     * {@code LF_Get_Opt_IPC_Serv_MaxMsgSize}.
     *
     * @return the configured max message size in bytes
     */
    public static int getIpcServMaxMsgSize() {
        return getInt("IPC_Serv_MaxMsgSize");
    }

    // ==================================================================
    // Sequenced notifications
    // ==================================================================

    /**
     * Sets the sticky-affinity window, in milliseconds, for P2PName
     * load balancing.
     *
     * <p>When the server-side dispatcher routes a P2PName-addressed
     * call, it normally picks the target with the smallest
     * Cycle_Anchor value (pure round-robin). If, however, a single
     * target has been handling requests for longer than
     * {@code Fixed_Sequenced_Time}, the dispatcher switches to a
     * different target instead, to avoid starvation.
     *
     * <p>The default is 20,000 ms (20 seconds).
     *
     * <p>Related pitfall IDs: LF-SEQ-001, LF-ROUTE-006.
     *
     * <p>Corresponding Pascal helper:
     * {@code LF_Set_Opt_Fixed_Sequenced_Time}.
     *
     * @param valueMs the sticky-affinity window in milliseconds
     */
    public static void setFixedSequencedTime(long valueMs) {
        setLong("Fixed_Sequenced_Time", valueMs);
    }

    /**
     * Returns the current sticky-affinity window, in ms.
     *
     * <p>Corresponding Pascal helper:
     * {@code LF_Get_Opt_Fixed_Sequenced_Time}.
     *
     * @return the sticky-affinity window in milliseconds
     */
    public static long getFixedSequencedTime() {
        return getLong("Fixed_Sequenced_Time");
    }

    // ==================================================================
    // P2P group name
    // ==================================================================

    /**
     * Sets this process's P2P group name.
     *
     * <p>The name is injected into every outbound request payload and
     * is reported to the server through the {@code Update_UID}
     * command. It defines which P2PName-addressed calls this process
     * is willing to receive: a server dispatching to P2PName
     * {@code "workers"} will pick a client whose P2P name is
     * {@code "workers"}.
     *
     * <h2>This is the local declaration</h2>
     *
     * <p>The value set here is the name THIS process declares for
     * itself. It is distinct from the P2P name that OTHER processes
     * will see when they receive a request from us, and it is distinct
     * from the name this process will read from an incoming request's
     * INPUT handle via {@link DataHandle#getP2pName()}. The sender's
     * P2P name that a receiver reads is "SIDE DATA": it is the
     * {@code FromP2PName} field that OUR transport layer wrote into
     * the outbound payload before transmission. The two values
     * coincide only because we are the sender.
     *
     * <p>The value may be changed at any time. The framework picks up
     * the new name on the next outbound request; there is no need to
     * reconnect.
     *
     * <p>The default is an empty string, which means "not a member of
     * any group". An empty P2P name disables P2PName routing for this
     * process (UID and App-name routing are unaffected).
     *
     * <p>Related pitfall IDs: LF-MECH-010, LF-ROUTE-003.
     *
     * <p>Corresponding Pascal helper: {@code LF_Set_Opt_P2P_Name}.
     *
     * @param value the P2P group name; must not be null
     */
    public static void setP2pName(String value) {
        setStr("LF_P2P_name", value);
    }

    /**
     * Returns this process's configured P2P group name.
     *
     * <h2>Not to be confused with DataHandle.getP2pName</h2>
     *
     * <p>This method reads the LOCAL configuration: the value this
     * process set for itself through {@link #setP2pName(String)}. It
     * answers the question "what P2P name have I declared for
     * myself?".
     *
     * <p>It is completely unrelated to
     * {@link DataHandle#getP2pName()}, which reads the SENDER's P2P
     * name from the INPUT handle of a registered callback. That value
     * is "SIDE DATA": it is the {@code FromP2PName} field that the
     * peer's transport layer injected into the payload before
     * transmission. In other words:
     *
     * <pre>
     * Options.getP2pName()         -&gt; MY name (local config)
     * DataHandle.getP2pName()      -&gt; the SENDER's name (side data)
     * </pre>
     *
     * <p>Both names happen to be of the same underlying wire type (a
     * UTF-8 string), but they come from two different sources and must
     * not be confused at any call site.
     *
     * <p>Returns an empty string when no name has been set.
     *
     * <p>Corresponding Pascal helper: {@code LF_Get_Opt_P2P_Name}.
     *
     * @return the local P2P group name
     */
    public static String getP2pName() {
        return getStr("LF_P2P_name");
    }

    // ==================================================================
    // Data handle pool
    // ==================================================================

    /**
     * Sets the idle-reclaim threshold, in milliseconds, for
     * auto-recycled data handles.
     *
     * <p>A value greater than zero enables idle reclamation: a handle
     * that has not been accessed for at least this long becomes a
     * candidate for release on the next pool scan. The default is
     * 600,000 ms (10 minutes).
     *
     * <p>A value of zero or less disables idle reclamation entirely.
     * In that mode, only an explicit {@link DataHandle#close()}
     * releases a handle.
     *
     * <p>This option does NOT affect handles created through
     * {@link DataHandle#createPermanent(String)}: those are released
     * synchronously by the wrapper's destructor and never enter the
     * idle-reclaim path.
     *
     * <p>Related pitfall IDs: LF-DATA-001, LF-MECH-001.
     *
     * <p>Corresponding Pascal helper:
     * {@code LF_Set_Opt_DataHandle_Idle_Timeout}.
     *
     * @param valueMs the idle-reclaim threshold in milliseconds
     */
    public static void setDataHandleIdleTimeout(long valueMs) {
        setLong("DataHandle_Idle_Timeout", valueMs);
    }

    /**
     * Returns the current idle-reclaim threshold, in ms.
     *
     * <p>Corresponding Pascal helper:
     * {@code LF_Get_Opt_DataHandle_Idle_Timeout}.
     *
     * @return the idle-reclaim threshold in milliseconds
     */
    public static long getDataHandleIdleTimeout() {
        return getLong("DataHandle_Idle_Timeout");
    }

    /**
     * Sets the minimum interval, in milliseconds, between two
     * consecutive scans of the data-handle pool.
     *
     * <p>A value greater than zero enables rate-limiting: the scanner
     * returns immediately if fewer than this many milliseconds have
     * elapsed since the last scan. The default is 5,000 ms (5
     * seconds).
     *
     * <p>A value of zero or less disables the rate limiter. The
     * scanner then runs on every progress tick of the simulated main
     * thread, which can be a significant CPU cost under a busy main
     * loop.
     *
     * <p>The scanner is driven by the simulated main thread, so its
     * effective call frequency is bounded below by the main thread's
     * tick granularity, not by this value alone.
     *
     * <p>Corresponding Pascal helper:
     * {@code LF_Set_Opt_DataHandle_Pool_Scan_Interval}.
     *
     * @param valueMs the pool scan interval in milliseconds
     */
    public static void setDataHandlePoolScanInterval(long valueMs) {
        setLong("DataHandle_Pool_Scan_Interval", valueMs);
    }

    /**
     * Returns the current data-handle pool scan interval, in ms.
     *
     * <p>Corresponding Pascal helper:
     * {@code LF_Get_Opt_DataHandle_Pool_Scan_Interval}.
     *
     * @return the pool scan interval in milliseconds
     */
    public static long getDataHandlePoolScanInterval() {
        return getLong("DataHandle_Pool_Scan_Interval");
    }

    // ==================================================================
    // Command flushing
    // ==================================================================

    /**
     * Sets the null-flush threshold for no-response commands.
     *
     * <p>The LingoFuse protocol periodically sends a NULL command to
     * force the server to acknowledge pending one-way Notify
     * messages. After every {@code value} no-response commands, one
     * NULL command is emitted as a flush point.
     *
     * <p>A lower value gives more timely acknowledgement at a slight
     * cost in bandwidth; a higher value is more efficient but delays
     * the server-side visibility of Notify deliveries.
     *
     * <p>The default is 5,000.
     *
     * <h2>Spelling note</h2>
     *
     * <p>The option key uses the historical spelling {@code Reponse}
     * (without the second 's'). The Java method preserves that
     * spelling in its own name so that the two are trivially
     * cross-referenced. The method name and the option key are both
     * intentional.
     *
     * <p>Corresponding Pascal helper:
     * {@code LF_Set_Opt_No_Reponse_Cmd_NULL_Flush_Threshold}.
     *
     * @param value the null-flush threshold
     */
    public static void setNoReponseCmdNullFlushThreshold(int value) {
        setInt("No_Reponse_Cmd_NULL_Flush_Threshold", value);
    }

    /**
     * Returns the current null-flush threshold.
     *
     * <p>Corresponding Pascal helper:
     * {@code LF_Get_Opt_No_Reponse_Cmd_NULL_Flush_Threshold}.
     *
     * @return the current null-flush threshold
     */
    public static int getNoReponseCmdNullFlushThreshold() {
        return getInt("No_Reponse_Cmd_NULL_Flush_Threshold");
    }
}