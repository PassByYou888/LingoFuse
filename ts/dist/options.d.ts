/** Canonical runtime option names. */
export declare const Option: {
    /** C4 P2PVM authentication token. Alias: "passwd". */
    readonly PASSWORD: "password";
    /** Quiet mode: suppress most log output. */
    readonly QUIET: "Quiet";
    /** Show thread IDs in log output. Aliases: "ShowThread", "Show_Thread". */
    readonly SHOW_THREAD_ID: "ShowThreadID";
    /** Enable or disable console output. Alias: "Console_Output". */
    readonly CONSOLE_OUTPUT: "ConsoleOutput";
    /**
     * Allow multiple client tunnels to the same remote address.
     * Aliases: "Overlap_Client", "OverlapConnection", "OverlapClient",
     * "OverlapConnect".
     */
    readonly OVERLAP_CONNECTION: "Overlap_Connection";
    /**
     * Block PrepareDone until all prepared clients are ready.
     * Aliases: "Wait_API_Prepare_Done", "API_Prepare_Done_Wait",
     * "WaitConnect", "Wait_Ready", "WaitReady".
     */
    readonly WAIT_CONNECTION_READY_OK: "Wait_Connection_ReadyOk";
    /**
     * Timeout (milliseconds) for the above wait.
     * Aliases: "Wait_TimeOut", "API_Prepare_Done_TimeOut", "WaitTimeOut".
     */
    readonly WAIT_CONNECTION_TIMEOUT: "Wait_Connection_Timeout";
    /**
     * Number of threads in the IPC server thread pool.
     * Aliases: "IPC_ThreadCount", "IPC_Server_ThreadCount".
     */
    readonly IPC_SERV_THREAD_COUNT: "IPC_Serv_ThreadCount";
    /**
     * Maximum IPC message queue length.
     * Aliases: "IPC_MaxQueueLength", "IPC_Server_MaxQueueLength".
     */
    readonly IPC_SERV_MAX_QUEUE_LENGTH: "IPC_Serv_MaxQueueLength";
    /**
     * Maximum size of a single IPC message, in bytes.
     * Aliases: "IPC_MaxMsgSize", "IPC_Server_MaxMsgSize".
     */
    readonly IPC_SERV_MAX_MSG_SIZE: "IPC_Serv_MaxMsgSize";
    /**
     * Sequenced Notify fallback threshold (milliseconds).
     * Alias: "Fixed_Sequenced_Life".
     */
    readonly FIXED_SEQUENCED_TIME: "Fixed_Sequenced_Time";
};
/** Union of all canonical option names. */
export type OptionName = (typeof Option)[keyof typeof Option];
/** Canonical string form of a boolean option value. */
export type BooleanOptionValue = "True" | "False";
/**
 * Convert a boolean to the canonical option value string.
 *
 * The native parser is case-insensitive on option names but accepts
 * "True" / "False" as the canonical spellings. Using this helper
 * removes the risk of writing "true" and silently leaving the option
 * unchanged in a build where value matching is case-sensitive.
 */
export declare function bool(value: boolean): BooleanOptionValue;
//# sourceMappingURL=options.d.ts.map