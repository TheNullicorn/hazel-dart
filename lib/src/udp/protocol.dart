import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import '../byte_buffer.dart';
import '../connection.dart';
import '../endpoint.dart';
import '../network_connection.dart';
import '../send_option.dart';
import 'keep_alive.dart';
import 'reliability.dart';
import 'udp.dart';

/// Extra internal states for SendOption enumeration when using UDP.
class UdpSendOption {
  /// Hello message for initiating communication.
  static const hello = UdpSendOption._internal(8);

  /// Message for discontinuing communication.
  static const disconnect = UdpSendOption._internal(9);

  /// Message acknowledging the receipt of a message.
  static const acknowledgement = UdpSendOption._internal(10);

  /// Message that is part of a larger, fragmented message.
  static const fragment = UdpSendOption._internal(11);

  /// A single byte of continued existence.
  static const ping = UdpSendOption._internal(12);

  final int value;

  const UdpSendOption._internal(this.value);

  /// Get a send option by its numeric value.
  static UdpSendOption fromValue(int value) {
    switch (value) {
      case 8:
        return hello;

      case 9:
        return disconnect;

      case 10:
        return acknowledgement;

      case 11:
        return fragment;

      case 12:
        return ping;
    }
    return null;
  }
}

mixin UdpProtocol on UdpConnection {
  static Future<RawDatagramSocket> createSocket(IPEndpoint address) {
    return RawDatagramSocket.bind(address.address, address.port);
  }

  KeepAliveManager keepAlive;
  ReliablePacketManager reliability;

  void writeBytes(Uint8List data);

  bool sendDisconnect([ByteBuffer msg]);

  @override
  void send(ByteBuffer msg, [Function() ackCallback]) {
    if (state != ConnectionState.connected) {
      throw StateError('Cannot send data while the connection is not open');
    }

    var buffer = msg.toUint8List();

    if (msg.sendOption == SendOption.reliable) {
      keepAlive.resetKeepAliveTimer();
      reliability.attachReliableId(buffer, 1, ackCallback);
    }
    writeBytes(buffer);
  }

  @override
  void sendBytes(Uint8List data, [SendOption option = SendOption.none]) {
    _handleSend(data, option?.value ?? 0);
  }

  void _handleSend(Uint8List data, int sendOption, [Function() ackCallback]) {
    switch (sendOption) {
      case 1:
      case 8:
      case 12:
        reliability.reliablySend(sendOption, data, ackCallback);
        break;

      // Treat any other packets as non-reliable
      default:
        unreliablySend(sendOption, data);
    }
  }

  /// Sends bytes using the unreliable UDP protocol.
  void unreliablySend(int sendOption, Uint8List data) {
    var bytes = Uint8List(data.length + 1);
    bytes[0] = sendOption;
    bytes.setAll(1, data);
    writeBytes(bytes);
  }

  /// Sends a hello packet to the remote endpoint.
  ///
  /// [data] contains any optional data to send in the hello, but may be null.
  /// Once the packet is acknowledged, [ackCallback] is executed.
  void sendHello(Uint8List data, [Function() ackCallback]) {
    // Always starts with 1 byte of empty data (a Hazel version, indicator,
    // which is currently 0)

    Uint8List bytes;
    if (data == null) {
      bytes = Uint8List(1);
    } else {
      bytes = Uint8List(data.length + 1);
      bytes.setAll(1, data);
    }

    _handleSend(bytes, UdpSendOption.hello.value, ackCallback);
  }

  /// Called to handle new messages received over the connection.
  ///
  /// [msg] is a buffer containing the full message received.
  void handleReceive(ByteBuffer msg) {
    var option = msg.readInt8();
    switch (option) {
      // Handle reliable packets
      case 1:
        reliability.onReliableMessageReceived(msg);
        break;

      // Handle hello / ping packets
      // Unlike reliable packets, these do not trigger onDataReceived
      case 8:
      case 12:
        var id = msg.readInt16(endian: Endian.big);
        reliability.processReliableReceived(id);
        break;

      // Handle disconnect packets
      case 9:
        disconnectRemote('The remote sent a disconnect request', msg);
        break;

      // Handle acknowledgement packets
      case 10:
        reliability.handleAcknowledgementReceived(msg.buf);
        break;

      // Treat any other options as unreliable
      default:
        invokeDataReceived(msg, SendOption.none);
    }
  }

  /// Called when the socket has been disconnected at the remote host.
  void disconnectRemote(String reason, [ByteBuffer msg]) {
    if (state == ConnectionState.not_connected) return;
    state = ConnectionState.not_connected;

    try {
      if (sendDisconnect(null)) invokeDisconnected(reason, msg);
    } finally {
      close();
    }
  }

  /// Called when socket is disconnected internally.
  void disconnectInternal(HazelInternalError error, [String reason]) {
    if (state == ConnectionState.not_connected) return;
    state = ConnectionState.not_connected;

    var handler = onInternalDisconnect;
    if (handler != null) {
      var messageToRemote = handler(error);
      if (messageToRemote != null) {
        disconnect(reason, messageToRemote);
        return;
      }
    }
    disconnect(reason, null);
  }

  @override
  void disconnect(String reason, [ByteBuffer msg]) async {
    if (state == ConnectionState.not_connected) return;
    state = ConnectionState.not_connected;

    var disconnectSent = false;
    try {
      disconnectSent = sendDisconnect(msg);
      close();
    } finally {
      if (disconnectSent) invokeDisconnected(reason, msg);
    }
  }
}
