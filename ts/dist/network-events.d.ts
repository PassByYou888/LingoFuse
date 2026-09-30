/** User-supplied connect handler. */
export type ConnectHandler = (addr: string) => void;
/** User-supplied disconnect handler. */
export type DisconnectHandler = (addr: string) => void;
/**
 * Install the process-global connect and disconnect handlers. Passing
 * null for either argument disables that event. This is a REPLACE
 * operation.
 */
export declare function setNetworkEvent(onConnect: ConnectHandler | null, onDisconnect: DisconnectHandler | null): void;
/** Remove both handlers. Safe to call multiple times. */
export declare function clearNetworkEvent(): void;
/** True when at least one handler is installed. */
export declare function isNetworkEventInstalled(): boolean;
/** Base class for object-oriented network event listeners. */
export declare abstract class NetworkEventListener {
    /** Called when a client becomes online. */
    onConnect(_addr: string): void;
    /** Called when a client goes offline. */
    onDisconnect(_addr: string): void;
}
/** Install a NetworkEventListener. */
export declare function setNetworkEventListener(listener: NetworkEventListener | null): void;
//# sourceMappingURL=network-events.d.ts.map