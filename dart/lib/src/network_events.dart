// Network event listener abstraction for the LingoFuse Dart binding.
//
// This file provides a small object-oriented facade over the
// function-based network event registration exposed by BridgeHost.
//
// The underlying mechanism (BridgeHost.setNetworkEvent) installs two
// process-global callbacks that fire when a LingoFuse client
// transitions between the "online" and "offline" states. Both
// callbacks run on the Dart event loop (they are delivered through
// Protocol B), so implementations of NetworkEventListener may safely
// touch Dart-side state without additional synchronisation.
//
// All comments and diagnostic strings are in English.

import 'bridge/bridge_host.dart';

/// Base class for object-oriented network event listeners.
///
/// Subclass and override [onConnect] / [onDisconnect] as needed. Both
/// methods are optional.
///
/// Example:
///
///     class MyListener extends NetworkEventListener {
///       @override
///       void onConnect(String addr) {
///         print('Connected: $addr');
///       }
///
///       @override
///       void onDisconnect(String addr) {
///         print('Disconnected: $addr');
///       }
///     }
///
///     installNetworkListener(MyListener());
class NetworkEventListener {
  /// Called when a LingoFuse client becomes online.
  ///
  /// "Online" means the client has received its first service
  /// API-info broadcast. This is NOT the TCP handshake; it is the
  /// earliest point at which the client can actually route remote
  /// calls.
  void onConnect(String addr) {}

  /// Called when a LingoFuse client goes offline.
  ///
  /// Fires once per physical link loss. Automatic reconnects do NOT
  /// emit a Disconnect for the reconnect attempt itself.
  void onDisconnect(String addr) {}
}

/// Installs a [NetworkEventListener] as the process-global network
/// event handler.
///
/// This is a convenience wrapper around
/// `BridgeHost.instance.setNetworkEvent`. It is a REPLACE operation:
/// calling it again discards any previously installed listener.
///
/// Requires [BridgeHost.start] to have been called first; otherwise
/// throws [StateError].
///
/// The listener is captured by the installed closures. Because Dart
/// closures hold strong references to their captured environment, the
/// listener remains reachable for as long as the network event
/// callbacks are installed. Call [clearNetworkListener] to release it.
void installNetworkListener(NetworkEventListener listener) {
  BridgeHost.instance.setNetworkEvent(
    onConnect: listener.onConnect,
    onDisconnect: listener.onDisconnect,
  );
}

/// Removes the current network event handlers (if any).
///
/// Safe to call multiple times. Does not require [BridgeHost] to be
/// started - if it is not, this is a no-op.
void clearNetworkListener() {
  final host = BridgeHost.instanceOrNull;
  if (host != null && !host.isStopped) {
    host.clearNetworkEvent();
  }
}