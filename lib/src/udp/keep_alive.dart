import 'dart:typed_data';

import 'package:async/async.dart';

import '../connection.dart';
import '../network_connection.dart';
import 'protocol.dart';

/// A tool for managing keep-alive messages and ensuring that a connection
/// does not close unexpectedly.
class KeepAliveManager {
  /// The connection using this instance.
  final UdpProtocol connection;

  /// Ping packets awaiting acknowledgement, mapped by their reliable IDs.
  final Map<int, PingPacket> activePingPackets = {};

  /// The number of unacknowledged ping packets before the connection is assumed
  /// to be dead.
  int missingPingsUntilDisconnect = 6;

  /// The number of ping packets sent since the last ping packet was
  /// acknowledged.
  int pingsSinceAck = 0;

  ///
  RestartableTimer _keepAliveTimer;

  KeepAliveManager(this.connection);

  /// The interval from data being received/transmitted to a KeepAlive packet
  /// being sent in milliseconds.
  ///
  /// KeepAlive packets serve to close connections when an endpoint abruptly
  /// disconnects and to ensure than any NAT devices do not close their
  /// translation for our argument. By ensuring there is regular contact the
  /// connection can detect and prevent these issues.
  ///
  /// The default value is 10 seconds, set to null to disable KeepAlive packets
  int get keepAliveInterval => _keepAliveInterval;

  set keepAliveInterval(int value) {
    _keepAliveInterval = value;
    resetKeepAliveTimer();
  }

  int _keepAliveInterval = 1500;

  /// Begins sending ping packets.
  void initKeepAliveTimer() {
    _keepAliveTimer = RestartableTimer(
        Duration(milliseconds: keepAliveInterval), _handleKeepAlive);
  }

  /// Resets the internal timer used to send ping packets periodically.
  void resetKeepAliveTimer() {
    _keepAliveTimer.reset();
  }

  /// Called periodically to evaluate the status of the connection and send
  /// another ping packet.
  void _handleKeepAlive() {
    if (connection.state != ConnectionState.connected) return;

    if (pingsSinceAck >= missingPingsUntilDisconnect) {
      connection.disconnectInternal(HazelInternalError.pingsWithoutResponse,
          'Sent $pingsSinceAck pings that remote has not responded to.');
      return;
    }

    try {
      pingsSinceAck++;
      _sendPing();
    } catch (_) {}
  }

  /// Creates a new ping packet, sends it over the connection, and waits for
  /// it to be acknowledged.
  void _sendPing() {
    var id = connection.reliability.nextReliableId;

    var bytes = Uint8List(3);
    bytes[0] = UdpSendOption.ping.value;
    bytes[1] = (id >> 8).toUnsigned(8);
    bytes[2] = id.toUnsigned(8);

    PingPacket pkt;
    if ((pkt = activePingPackets[id]) == null) {
      pkt == PingPacket();
      activePingPackets[id] = pkt;
    }

    pkt.stopwatch
      ..reset() // This doesn't matter unless the packet is old
      ..start();
    connection.writeBytes(bytes);
  }

  /// Called when the connection being managed is closed.
  ///
  /// This just runs some internal cleanup/resetting.
  void handleClose() {
    activePingPackets?.clear();
    _keepAliveTimer?.cancel();

    missingPingsUntilDisconnect = 6;
    pingsSinceAck = 0;
  }
}

/// Represents a ping packet that is awaiting acknowledgement.
class PingPacket {
  Stopwatch stopwatch = Stopwatch();
}
