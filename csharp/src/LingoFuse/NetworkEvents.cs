using System;

using LingoFuse.Native;

namespace LingoFuse;

// ============================================================================
// NetworkEvents — process-global connect / disconnect notifications.
// ============================================================================
//
// SEMANTICS
// ---------
// "Connect"    fires the FIRST time a client receives a service API-info
//              broadcast. It is NOT the TCP handshake; it is the
//              earliest point at which remote calls can be routed.
//              Fires once per connection lifecycle, and again after an
//              auto-reconnect.
//
// "Disconnect" fires once per physical link loss. An automatic
//              reconnect does NOT emit a Disconnect for the reconnect
//              attempt itself; it emits a new Connect once the client
//              is back online.
//
// THREADING CONTRACT
// ------------------
// Callbacks run on a background worker thread owned by the native
// library. They must:
//
//   - copy the endpoint string immediately (this wrapper does that
//     for the user, so the delegate receives a managed string);
//   - never touch UI controls directly;
//   - never call any blocking LingoFuse function (LF_Call,
//     LF_LocalCall, LF_PrepareDone, LF_Shutdown) — this would deadlock;
//   - never let an exception escape into the native stack.
//
// The wrapper enforces the last rule: any exception raised by a user
// delegate is caught and reported through Framework.ReportCallbackError.
// The native layer sees a callback that returned normally.
//
// ENDPOINT STRING LIFETIME
// ------------------------
// The native side passes a UTF-8 pointer that is freed as soon as the
// callback returns. This wrapper copies the string to a managed string
// before invoking the user delegate, so user code never sees a
// dangling pointer.
//
// GLOBAL SCOPE
// ------------
// LF_Set_Network_Event is a process-wide slot. There is no per-client
// registration. Installing new handlers replaces the previous ones
// entirely; passing null for a handler disables that event.
//
// LF_Shutdown automatically clears both handlers during teardown. It
// is nevertheless recommended to call Clear explicitly before
// unloading the binding to release the managed delegate references.
//
// ============================================================================

/// <summary>
/// Process-global network connect / disconnect event handlers.
/// </summary>
public static class NetworkEvents
{
    // --------------------------------------------------------------------
    // GC keep-alive
    // --------------------------------------------------------------------
    //
    // The native library stores raw function pointers to the delegates
    // below. If the GC collects the delegates, the native side would
    // jump into freed memory on the next invocation. These static
    // fields hold the delegates for as long as the handlers are
    // installed, which is exactly the required lifetime.
    //
    // The user-supplied delegates are held by the trampolines via
    // closure capture, so they cannot be collected while the
    // trampolines are alive either.
    // --------------------------------------------------------------------

    private static LfNetworkEventFunc? _nativeConnect;
    private static LfNetworkEventFunc? _nativeDisconnect;

    /// <summary>
    /// Guards mutations of the delegate fields. Reads happen inside the
    /// native trampolines and are lock-free, which is safe because the
    /// fields are only assigned under this lock during Set / Clear.
    /// </summary>
    private static readonly object SyncRoot = new();

    /// <summary>
    /// True when at least one handler is currently installed.
    /// </summary>
    public static bool IsInstalled
    {
        get
        {
            lock (SyncRoot)
            {
                return _nativeConnect is not null
                    || _nativeDisconnect is not null;
            }
        }
    }

    /// <summary>
    /// Installs the process-global connect and disconnect handlers.
    /// Passing <c>null</c> for either argument disables that event.
    /// </summary>
    /// <remarks>
    /// This is a REPLACE operation, not a patch. Calling it a second
    /// time discards any previously installed handlers, even those
    /// whose corresponding argument is <c>null</c> in the new call.
    /// </remarks>
    /// <param name="onConnect">
    /// Handler invoked when a client becomes online. May be null.
    /// </param>
    /// <param name="onDisconnect">
    /// Handler invoked when a client goes offline. May be null.
    /// </param>
    public static void Set(
        Action<string>? onConnect,
        Action<string>? onDisconnect)
    {
        lock (SyncRoot)
        {
            _nativeConnect = onConnect is null
                ? null
                : MakeConnectTrampoline(onConnect);
            _nativeDisconnect = onDisconnect is null
                ? null
                : MakeDisconnectTrampoline(onDisconnect);

            NativeMethods.LF_Set_Network_Event(
                _nativeConnect, _nativeDisconnect);
        }
    }

    /// <summary>
    /// Removes both handlers. Safe to call multiple times.
    /// </summary>
    public static void Clear()
    {
        lock (SyncRoot)
        {
            _nativeConnect = null;
            _nativeDisconnect = null;

            NativeMethods.LF_Set_Network_Event(null, null);
        }
    }

    // ====================================================================
    // Trampoline factories
    // ====================================================================
    //
    // Each factory returns a fresh delegate. Caching trampolines would
    // require a stable identity for the user callback, which an
    // anonymous lambda does not provide. Building fresh delegates per
    // Set call is cheap (Set is a once-per-process operation) and
    // eliminates a class of stale-callback bugs.
    // ====================================================================

    private static LfNetworkEventFunc MakeConnectTrampoline(
        Action<string> userCallback)
    {
        return addr =>
        {
            // Copy the string immediately; the native buffer is freed
            // as soon as this trampoline returns.
            string endpoint = Utf8Marshal.PtrToString(addr);
            try
            {
                userCallback(endpoint);
            }
            catch (Exception ex)
            {
                Framework.ReportCallbackError(
                    "NetworkEvents.Connect", ex);
            }
        };
    }

    private static LfNetworkEventFunc MakeDisconnectTrampoline(
        Action<string> userCallback)
    {
        return addr =>
        {
            string endpoint = Utf8Marshal.PtrToString(addr);
            try
            {
                userCallback(endpoint);
            }
            catch (Exception ex)
            {
                Framework.ReportCallbackError(
                    "NetworkEvents.Disconnect", ex);
            }
        };
    }
}