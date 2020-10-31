import 'dart:io';
import 'dart:typed_data';

import '../endpoint.dart';
import '../network_connection.dart';
import 'client_connection.dart';
import 'connection_listener.dart';

// LAN broadcaster/listener
export 'broadcast.dart';

/// Represents a connection that uses the UDP protocol.
abstract class UdpConnection extends NetworkConnection {
  UdpConnection();

  /// Create a new connection to a server (at [toAddress]) that uses the UDP
  /// protocol.
  ///
  /// This will not connect the client, and [UdpConnection.connect] will need
  /// to be called manually.
  factory UdpConnection.client(IPEndpoint toAddress,
      [InternetAddressType ipMode]) {
    if (toAddress == null) throw ArgumentError.notNull('toAddress');

    ipMode ??= toAddress.address.type;
    return BasicUdpClientConnection(toAddress, ipMode);
  }
}

/// Listens for new UDP connections and creates [UdpConnection]s for them.
abstract class UdpConnectionListener extends NetworkConnectionListener {
  UdpConnectionListener();

  /// An event that can be used for early connection rejection.
  ///
  /// This event is called when a handshake packet, [input], is received
  /// from an [IPEndpoint] that doesn't already have a [UdpConnection]
  /// (meaning its a new connection).
  ///
  /// If this function returns null, a new [UdpConnection] is
  /// created for the [remoteEndpoint]. If the return value is non-null, the
  /// client will be immediately disconnected with the provided data (could
  /// be a reason code, message, etc).
  ///
  /// If this function is undefined, then all connections will be accepted.
  Uint8List Function(IPEndpoint remoteEndpoint, Uint8List input)
      onConnectionInit;

  /// The current number of connections that this listener recognizes (CCU).
  int get connectionCount;

  /// Creates a new connection listener that will listen and handle new
  /// connections on [bindAddress].
  ///
  /// This factory does not actually bind the server to [bindAddress], and you
  /// will need to do that yourself using [ConnectionListener.start].
  factory UdpConnectionListener.server(IPEndpoint bindAddress,
      [InternetAddressType ipMode]) {
    if (bindAddress == null) throw ArgumentError.notNull('bindAddress');

    ipMode ??= bindAddress.address.type;
    return BasicUdpConnectionListener(bindAddress, ipMode);
  }
}
