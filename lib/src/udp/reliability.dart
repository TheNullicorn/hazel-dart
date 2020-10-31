import 'dart:collection';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import '../byte_buffer.dart';
import '../network_connection.dart';
import '../send_option.dart';
import 'keep_alive.dart';
import 'protocol.dart';

const defaultResendTimeout = 0;
const defaultResendLimit = 0;
const defaultResendPingMultiplier = 2.0;

/// A tool for managing reliable messages and ensuring that a connection and
/// ensuring that they are received by the remote.
class ReliablePacketManager {
  final UdpProtocol connection;

  /// The starting timeout, in milliseconds, at which data will be resent.
  ///
  /// For reliable delivery data is resent at specified intervals unless an
  /// acknowledgement is received from the receiving device. The
  /// [resendTimeout] specifies the interval between the packets being resent,
  /// each time a packet is resent the interval is increased for that packet
  /// until the duration exceeds the [disconnectTimeout] value.
  int resendTimeout = defaultResendTimeout;

  /// Max number of times to resend packets.
  ///
  /// 0 == no limit
  int resendLimit = defaultResendLimit;

  /// A compounding multiplier to back off resend timeout.
  ///
  /// Applied to ping before first timeout when [resendTimeout] == 0
  double resendPingMultiplier = defaultResendPingMultiplier;

  /// Holds the last reliable ID allocated.
  int _lastIdAllocated = 0;

  /// The packets of data that have been transmitted reliably and not
  /// acknowledged.
  final Map<int, _Packet> _unacknowledgedPackets = {};

  /// Packet IDs that have not been received, but are expected.
  final HashSet<int> _missingPacketIds = HashSet();

  /// The ID of the last new reliable packet received.
  int _lastReceivedId = 65535;

  /// Returns the average ping to this endpoint.
  ///
  /// This returns the average ping for a one-way trip as calculated from the
  /// reliable packets that have been sent and acknowledged by the endpoint.
  double avgPingMs = 500.0;

  /// The maximum times a message should be resent before marking the
  /// endpoint as disconnected.
  ///
  /// Reliable packets will be resent at an interval defined in
  /// [resendTimeout] for the number of times specified here. Once a packet
  /// has been retransmitted this number of times and has not been
  /// acknowledged the connection will be marked as disconnected and the
  /// [Connection.onDisconnected] event will be invoked.
  int disconnectTimeout = 5000;

  ReliablePacketManager(this.connection);

  /// Get the next available reliable ID.
  ///
  /// Calling this getter automatically increments the value.
  int get nextReliableId =>
      _lastIdAllocated = (_lastIdAllocated + 1).toUnsigned(16);

  /// Resends any packets that have not been acknowledged.
  ///
  /// The return value is the number of packets that were resent.
  int manageReliablePackets() {
    var output = 0;
    _unacknowledgedPackets.forEach((id, packet) {
      try {
        if (packet.resend()) output++;
      } catch (_) {}
    });
    return output;
  }

  /// Adds a 2 byte ID to the packet at offset and stores the packet
  /// reference for retransmission.
  ///
  /// [ackCallback] is an optional callback to execute once the packet has
  /// been acknowledged.
  void attachReliableId(Uint8List buffer, int offset,
      [Function() ackCallback]) {
    var id = _lastIdAllocated++;

    if (_unacknowledgedPackets.containsKey(id)) {
      throw StateError('Duplicate reliable ID. This should not happen.');
    }

    // Set reliable ID
    buffer[offset] = (id >> 8).toUnsigned(8);
    buffer[offset + 1] = id;

    // Create packet obj
    var packet = _Packet();
    packet.id = id;
    packet.connection = connection;
    packet.data = buffer;
    packet.nextTimeout = resendTimeout > 0
        ? resendTimeout
        : min(avgPingMs * resendPingMultiplier, 300).toInt();
    packet.ackCallback = ackCallback;

    // Store packet for resending
    _unacknowledgedPackets[id] = packet;
  }

  /// Sends the bytes reliably and stores the send.
  ///
  /// [ackCallback] is an optional callback to execute once the packet has
  /// been acknowledged.
  void reliablySend(int sendOption, Uint8List data, [Function() ackCallback]) {
    connection.keepAlive.resetKeepAliveTimer();

    var fullMsg = Uint8List(data.length + 3);
    fullMsg[0] = sendOption;

    attachReliableId(fullMsg, 1, ackCallback);
    fullMsg.setRange(3, fullMsg.length, data);

    connection.writeBytes(fullMsg);
  }

  /// Handles a reliable message being received and invokes the data event.
  void onReliableMessageReceived(final ByteBuffer buf) {
    var id = buf.readInt16(endian: Endian.big);
    if (processReliableReceived(id)) {
      connection.invokeDataReceived(buf, SendOption.reliable);
    }
  }

  /// Handles receives from reliable packets.
  ///
  /// Returns whether or not the packet is new.
  bool processReliableReceived(int id) {
    id = id.toUnsigned(16);

    // Acknowledge the packet
    _sendAck(id);

    var overwritePointer = (_lastReceivedId - 32768).toUnsigned(16);

    // Check if the packet is new. Since reliable IDs are limited to 2 bytes
    // (and will loop back around to zero), we need to compare the new ID to
    // the last received ID as well as that value minus 32768.
    bool isNew;
    if (overwritePointer < _lastReceivedId) {
      isNew = id > _lastReceivedId || id <= overwritePointer;
    } else {
      isNew = id > _lastReceivedId && id <= overwritePointer;
    }

    if (isNew) {
      // Mark any packets between the last ID and the current ID as missing
      if (id > _lastReceivedId) {
        for (var i = (_lastReceivedId + 1).toUnsigned(16); i < id; i++) {
          _missingPacketIds.add(i);
        }
      } else {
        var cnt = (65535 - _lastReceivedId) + id;
        for (var i = 1; i < cnt; i++) {
          _missingPacketIds.add(i + _lastReceivedId);
        }
      }

      // Update last received ID
      _lastReceivedId = id;
    }

    // Might be a missing packet
    else {
      // Check if this packet is missing. If not, it is a duplicate and
      // should be ignored
      if (_missingPacketIds.remove(id) == null) {
        return false;
      }
    }

    return true;
  }

  /// Handle inbound acknowledgement packets.
  void handleAcknowledgementReceived(Uint8List data) {
    connection.keepAlive.pingsSinceAck = 0;

    var id = ((data[1] << 8) + data[2]).toUnsigned(16);
    _onMessageAcknowledged(id);

    if (data.length == 4) {
      // Send acknowledgements for lost packets
      var recentPackets = data[3];
      for (var i = 1; i < 8; i++) {
        if ((recentPackets & 1) != 0) {
          _onMessageAcknowledged((id - i).toUnsigned(16));
        }
        recentPackets >>= 1;
      }
    }
  }

  /// Internal method for handling the receipt of an acknowledgement packet.
  void _onMessageAcknowledged(int id) {
    var packet;

    packet = _unacknowledgedPackets.remove(id);
    if (packet is _Packet) {
      // Stop the packet's ping timer
      packet.stopwatch.stop();

      // If the packet had an ack callback, execute it
      packet.ackCallback?.call();

      // Calculate ping based on response time
      var rt = packet.stopwatch.elapsedMilliseconds;
      avgPingMs = max(50, avgPingMs * 0.7 + rt * 0.3);
      return;
    }

    packet = connection.keepAlive.activePingPackets;
    if (packet is PingPacket) {
      // Stop the packet's ping timer
      packet.stopwatch.stop();

      // Calculate ping based on response time
      var rt = packet.stopwatch.elapsedMilliseconds;
      avgPingMs = max(50, avgPingMs * 0.7 + rt * 0.3);
    }
  }

  /// Sends an acknowledgement for a packet given its identification bytes.
  void _sendAck(int id) {
    var recentPackets = 0;
    for (var i = 1; i <= 8; i++) {
      if (!_missingPacketIds.contains(id - i)) recentPackets |= (1 << (i - 1));
    }

    var bytes = Uint8List.fromList([
      UdpSendOption.acknowledgement.value,
      (id >> 8).toUnsigned(8),
      id,
      recentPackets
    ]);

    try {
      connection.writeBytes(bytes);
    } catch (_) {}
  }

  /// Called when the connection being managed is closed.
  ///
  /// This just runs some internal cleanup/resetting.
  void handleClose() {
    resendTimeout = defaultResendTimeout;
    resendLimit = defaultResendLimit;
    resendPingMultiplier = defaultResendPingMultiplier;
    _lastIdAllocated = 0;
    _unacknowledgedPackets?.clear();
    _missingPacketIds?.clear();
    _lastReceivedId = 65535;
    avgPingMs = 500.0;
    disconnectTimeout = 5000;
  }
}

class _Packet {
  int id;
  Uint8List data;
  UdpProtocol connection;

  int nextTimeout;
  bool acknowledged;

  void Function() ackCallback;

  int retransmissions = 0;
  Stopwatch stopwatch = Stopwatch();

  ReliablePacketManager get manager => connection?.reliability;

  bool resend() {
    if (acknowledged || connection == null) return false;

    // Check if the packet hasn't been acknowledged after a while
    var lifetime = stopwatch.elapsedMilliseconds;
    if (lifetime >= manager.disconnectTimeout) {
      if (manager._unacknowledgedPackets.remove(id) != null) {
        // Too long without ack; disconnect
        connection.disconnectInternal(
            HazelInternalError.reliablePacketWithoutResponse,
            'Reliable packet $id (size=${data.length}) was not ack\'d '
            'after ${lifetime}ms ($retransmissions resends)');
      }
      return false;
    }

    if (lifetime >= nextTimeout) {
      retransmissions++;

      // Check if the packet has been resent too many times
      if (manager.resendLimit != 0 && retransmissions > manager.resendLimit) {
        if (manager._unacknowledgedPackets.remove(id) != null) {
          // Too many resends; disconnect
          connection.disconnectInternal(
              HazelInternalError.reliablePacketWithoutResponse,
              'Reliable packet $id (size=${data.length}) was not ack\'d '
              'after $retransmissions resends (${lifetime}ms)');
        }
        return false;
      }

      nextTimeout =
          min(nextTimeout * manager.resendPingMultiplier, 1000).toInt();
      try {
        connection.writeBytes(data);
        return true;
      } on SocketException catch (_) {
        connection.disconnectInternal(HazelInternalError.connectionDisconnected,
            'Could not resend data as connection is no longer connected');
      }
    }
    return false;
  }
}
