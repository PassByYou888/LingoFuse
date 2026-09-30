/** Number of pending log messages in the status queue. */
export declare function getStatusCount(): number;
/** Retrieve the next log message. Returns "" when the queue is empty. */
export declare function getStatus(): string;
/**
 * Drain up to maxMessages pending status messages in FIFO order.
 * Stops early when the queue reports an empty message.
 */
export declare function drainStatus(maxMessages?: number): string[];
/** Inject a custom log message into the status queue. */
export declare function postStatus(message: string): void;
/** True when the simulated main thread is currently running. */
export declare function checkMainThread(): boolean;
/**
 * Probe whether an application with the given name is available.
 *
 * Uses a local cache updated by network broadcasts (~3 s delay).
 * False negatives immediately after registration and false positives
 * shortly after unregistration are both normal.
 */
export declare function checkApp(appName: string): boolean;
/** Probe whether the named API is available for the given application. */
export declare function checkApi(appName: string, apiName: string): boolean;
//# sourceMappingURL=status.d.ts.map