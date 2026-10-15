// Public entry point for the LingoFuse Dart binding.
//
// The package exposes two coexisting API surfaces:
//
//   LEGACY   AppHandle / DataHandle / Framework / LingoFuseStatus / LfIo
//            Direct FFI, no bridge required. All v1.x call sites
//            continue to work unchanged.
//
//   BRIDGE   BridgeHost / BridgeFfi / CallHandler / NotifyHandler /
//            AsyncResultHandler / NetworkEventHandler / BridgeException
//            The C-bridge-mediated layer. Offers P2P identity access,
//            UID addressing, asynchronous invocation, and typed options.
//
//   ASYNC    CallPromise / AsyncBridge / Target / AppTarget / UIDTarget /
//            P2PNameTarget / NetworkEventListener
//            The modern async surface. Routes through the bridge.
//
// The three surfaces share the same underlying LingoFuse DLL; they can
// coexist in the same process.
//
// All diagnostics are in English.

library lingofuse;

// ---------------------------------------------------------------------------
// Legacy surface
// ---------------------------------------------------------------------------

export 'src/app_handle.dart' show AppHandle;
export 'src/data_handle.dart' show DataHandle;
export 'src/framework.dart' show Framework;
export 'src/io.dart' show LfIo;
export 'src/status.dart' show LingoFuseStatus;

// ---------------------------------------------------------------------------
// Bridge surface
// ---------------------------------------------------------------------------

export 'src/bridge/bridge_error.dart'
    show BridgeErrorCode, BridgeException;
export 'src/bridge/bridge_ffi.dart' show BridgeFfi;
export 'src/bridge/bridge_host.dart'
    show
        BridgeHost,
        CallHandler,
        NotifyHandler,
        AsyncResultHandler,
        NetworkEventHandler;

// ---------------------------------------------------------------------------
// Async programming surface
// ---------------------------------------------------------------------------

export 'src/async_support.dart' show CallPromise, AsyncBridge;

// ---------------------------------------------------------------------------
// Addressing abstraction
// ---------------------------------------------------------------------------

export 'src/address.dart' show Target, AppTarget, UIDTarget, P2PNameTarget;

// ---------------------------------------------------------------------------
// Network event listener abstraction
// ---------------------------------------------------------------------------

export 'src/network_events.dart'
    show NetworkEventListener, installNetworkListener, clearNetworkListener;

// ---------------------------------------------------------------------------
// Exception hierarchy (shared by all three surfaces)
// ---------------------------------------------------------------------------

export 'src/errors.dart'
    show
        LingoFuseError,
        LingoFuseLibraryLoadError,
        LingoFuseCallError,
        LingoFuseTimeoutError,
        LingoFuseIoError,
        LingoFuseObjectDisposedError,
        LingoFuseCallbackError,
        LingoFuseRegistrationError;