import 'dart:io';

import 'byte_buffer.dart';
import 'connection.dart';
import 'endpoint.dart';

/// Internal library errors that may turn up in
/// [NetworkConnection.onInternalDisconnect]
enum HazelInternalError {
  socketExceptionSend,
  socketExceptionReceive,
  receivedZeroBytes,
  pingsWithoutResponse,
  reliablePacketWithoutResponse,
  connectionDisconnected
}

/// Abstract base class for a [Connection] to a remote end point via a
/// network protocol like TCP or UDP.
abstract class NetworkConnection extends Connection {
  /// An event that gives us a chance to send well-formed disconnect messages
  /// to clients when an internal disconnect happens.
  ///
  /// If this callback does not return null, the data in the returned buffer
  /// will be sent to the remote in a disconnect packet.
  ByteBuffer Function(HazelInternalError error) onInternalDisconnect;

  /// The remote end point of this connection.
  ///
  /// This is the end point of the other device given as an [IPEndpoint].
  IPEndpoint get remoteEndpoint;

  /// Returns the address of the [remoteEndpoint] as a 32-bit IPv4 address.
  int get ipv4Address {
    if (ipMode == InternetAddressType.IPv4) {
      return remoteEndpoint.address.rawAddress.buffer.asByteData().getInt32(0);
    } else {
      return remoteEndpoint.address.rawAddress.buffer.asByteData().getInt64(0);
    }
  }
}

/// Abstract base class for a [ConnectionListener] for network based
/// connections.
abstract class NetworkConnectionListener extends ConnectionListener {

  /// The local end point the listener is listening for new clients on.
  IPEndpoint get endpoint;

  /// The IP mode used to listen for and send data over connections.
  InternetAddressType get ipMode;
}