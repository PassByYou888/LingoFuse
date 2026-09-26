using System;
using System.Diagnostics;

using LingoFuse.Native;

namespace LingoFuse.Events;

// ============================================================================
// NetworkEvents — process-global connect / disconnect notifications.
// ============================================================================
//
// Semantics
// ---------
// "Connect"    fires the FIRST time a client receives a service API-info
//              broadcast. It is NOT the TCP handshake; it is the earliest
//              point at which remote calls can be routed. Fires once per
//              connection lifecycle, and again after an auto-reconnect.
//
// "Disconnect" fires once per physical link loss. An automatic reconnect
//              does NOT emit a Disconnect for the reconnect attempt
//              itself; it emits a new Connect once the client is back
//              online.
//
// ----------------------------------------------------------------------------
// THREADING CONTRACT
// ----------------------------------------------------------------------------
// Callbacks run on a background worker thread owned by the native
// library. They must:
//
//   - copy the endpoint string immediately (the wrapper does this for
//     the user, so the delegate receives a managed string);
//   - never touch UI controls directly;
//   - never call any blocking LingoFuse function (LF_Call, LF_LocalCall,
//     LF_PrepareDone, LF_Shutdown) — this would deadlock;
//   - never let an exception escape into the native stack.
//
// The wrapper enforces the last rule: any exception raised by a user
// delegate is caught and logged via Debug.WriteLine. The native layer
// sees a callback that returned normally.
//
// ----------------------------------------------------------------------------
// ENDPOINT STRING LIFETIME
// ----------------------------------------------------------------------------
// The native side passes a UTF-8 pointer that is freed as soon as the
// callback returns. This wrapper copies the string to a managed string
// before invoking the user delegate, so the user code never sees a
// dangling pointer.
//
// ----------------------------------------------------------------------------
// GLOBAL SCOPE
// ----------------------------------------------------------------------------
// LF_Set_Network_Event is a process-wide slot. There is no per-client
// registration. Installing new handlers replaces the previous ones
// entirely; passing null for a handler disables that particular event.
//
// LF_Shutdown automatically clears both handlers during teardown. It is
// nevertheless recommended to call Clear() explicitly before unloading
// the binding to release the managed delegate references.
//
// ----------------------------------------------------------------------------
// EXCEPTION POLICY
// ----------------------------------------------------------------------------
//     ArgumentNullException   a reference argument that is required to
//                             be non-null is null
//
// The class itself has no disposal semantics; Set / Clear can be called
// at any time. Set replaces the previous handlers atomically under an
// internal lock.
// ============================================================================

/// <summary>
/// Process-global network connect / disconnect event handlers.
/// </summary>
public static class NetworkEvents
{
    /// <summary>
    /// Static fields hold the native-facing delegates so that the GC
    /// cannot collect them while the native library still refers to
    /// their function pointers.
    /// </summary>
    private static LfNetworkEventFunc? _nativeConnect;
    private static LfNetworkEventFunc? _nativeDisconnect;

    /// <summary>User-supplied handlers, kept alive for the same reason.</summary>
    private static Action<string>? _userConnect;
    private static Action<string>? _userDisconnect;

    /// <summary>
    /// Guards mutations of the delegate fields. Reads happen inside the
    /// native trampolines and are lock-free, which is safe because the
    /// fields are only assigned under this lock during Set / Clear.
    /// </summary>
    private static readonly object SyncRoot = new();

    /// <summary>True when at least one handler is currently installed.</summary>
    public static bool IsInstalled
    {
        get
        {
            lock (SyncRoot)
            {
                return _nativeConnect is not null || _nativeDisconnect is not null;
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
            _userConnect = onConnect;
            _userDisconnect = onDisconnect;

            _nativeConnect = onConnect is null ? null : OnConnectTrampoline;
            _nativeDisconnect = onDisconnect is null ? null : OnDisconnectTrampoline;

            NativeMethods.LF_Set_Network_Event(_nativeConnect, _nativeDisconnect);
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
            _userConnect = null;
            _userDisconnect = null;

            NativeMethods.LF_Set_Network_Event(null, null);
        }
    }

    // ====================================================================
    // Native trampolines
    // ====================================================================

    /// <summary>
    /// Native-facing trampoline for the connect event. Copies the
    /// endpoint string to managed memory and invokes the user delegate.
    /// Any exception is swallowed.
    /// </summary>
    private static void OnConnectTrampoline(IntPtr addr)
    {
        // Copy the string immediately; the native buffer is freed as
        // soon as this method returns.
        string endpoint = Utf8Marshal.PtrToString(addr);

        try
        {
            _userConnect?.Invoke(endpoint);
        }
        catch (Exception ex)
        {
            // Never let a managed exception cross into the native
            // stack. The user handler is responsible for its own error
            // reporting; this fallback only guarantees the process
            // stays alive.
            Debug.WriteLine(
                "[LingoFuse] NetworkEvents connect handler threw: " + ex);
        }
    }

    /// <summary>
    /// Native-facing trampoline for the disconnect event. Same contract
    /// as <see cref="OnConnectTrampoline"/>.
    /// </summary>
    private static void OnDisconnectTrampoline(IntPtr addr)
    {
        string endpoint = Utf8Marshal.PtrToString(addr);

        try
        {
            _userDisconnect?.Invoke(endpoint);
        }
        catch (Exception ex)
        {
            Debug.WriteLine(
                "[LingoFuse] NetworkEvents disconnect handler threw: " + ex);
        }
    }
}