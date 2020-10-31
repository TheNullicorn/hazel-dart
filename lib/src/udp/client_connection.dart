import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import '../byte_buffer.dart';
import '../connection.dart';
import '../endpoint.dart';
import '../network_connection.dart';
import '../send_option.dart';
import 'keep_alive.dart';
import 'protocol.dart';
import 'reliability.dart';
import 'udp.dart';

/// Default connection timeout
const connectTimeout = Duration(seconds: 5);

/// How often to resend unacknowledged packets
const manageReliablesInterval = Duration(milliseconds: 100);

class BasicUdpClientConnection extends UdpConnection with UdpProtocol {
  @override
  final IPEndPoint remoteEndpoint;

  @override
  final InternetAddressType ipMode;

  /// The actual socket on the remote end of this connection.
  RawDatagramSocket _socket;

  /// A timer task used to resend any reliable packets that have not been
  /// acknowledged.
  Timer _reliablePacketTimer;

  /// A completer that listens for disconnects during the handshake process.
  ///
  /// This completes whenever [close] is called while the connection is in
  /// the [ConnectionState.connecting] state.
  ///
  /// The reason for this is that [connect] is async and completes when
  /// either the server responds to the hello packet, or a timeout is
  /// detected. However, it's possible for the server to send a disconnect
  /// packet without responding to the hello. In that case, [onDisconnected]
  /// would be called, but [connect] would also throw a timeout exception
  /// because the hello was technically never responded to. Because the
  /// timeout exception doesn't accurately describe what happened (that the
  /// hello was responded to with a disconnect), we use this completer to
  /// throw a more descriptive error.
  Completer _disconnectCompleter;

  BasicUdpClientConnection(this.remoteEndpoint, [this.ipMode]) {
    if (ipMode != InternetAddressType.IPv4 &&
        ipMode != InternetAddressType.IPv6) {
      throw ArgumentError.value(
          ipMode.name, 'ipMode', 'Unsupported address type');
    }
    _reliablePacketTimer =
        Timer.periodic(manageReliablesInterval, _manageReliablePackets);
  }

  @override
  IPEndPoint get endpoint => remoteEndpoint;

  /// Resends any reliable packets that have not been acknowledged.
  void _manageReliablePackets(Timer timer) =>
      reliability.manageReliablePackets();

  @override
  void connect(Uint8List bytes, [Duration timeout = connectTimeout]) async {
    state = ConnectionState.connecting;

    keepAlive = KeepAliveManager(this);
    reliability = ReliablePacketManager(this);
    keepAlive.initKeepAliveTimer();

    // Try to bind to wildcard port
    try {
      if (ipMode == InternetAddressType.IPv6) {
        _socket = await RawDatagramSocket.bind(InternetAddress.anyIPv6, 0);
      } else {
        _socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      }
    } on SocketException {
      state = ConnectionState.not_connected;
      rethrow;
    }

    // Listen for read events
    _socket.listen((event) {
      if (event == RawSocketEvent.read) _handleRead(_socket.receive());
    });

    var helloCompleter = Completer(); // Completes when the hello is ack'd
    var timeoutCompleter = Completer(); // Completes if the timer finishes
    _disconnectCompleter = Completer(); // Completes if _destruct() is called

    // Say hello to the server. Once they acknowledge it, we know the
    // connection is ready
    sendHello(bytes, () {
      state = ConnectionState.connected;
      helloCompleter.complete(); // Stops TimeoutException from throwing
    });

    // Throw an exception if the connection is not opened before the timeout
    var timeoutTimer = Timer(timeout, () {
      if (state == ConnectionState.connected) {
        timeoutCompleter.complete();
        return;
      }
      timeoutCompleter.completeError(
          TimeoutException('Could not connect to remote: timed out'));
    });

    await Future.any([
      helloCompleter.future,
      _disconnectCompleter.future,
      timeoutCompleter.future
    ]);
    timeoutTimer.cancel();
    _disconnectCompleter.complete();
    _disconnectCompleter = null;
  }

  @override
  bool sendDisconnect([ByteBuffer msg]) {
    var bytes;
    if (msg == null || msg.length == 0) {
      bytes = Uint8List(1);
      bytes[0] == UdpSendOption.disconnect.value;
    } else if (msg.sendOption == SendOption.reliable) {
      throw ArgumentError('Disconnect messages can only be unreliable.');
    } else {
      bytes = msg.toUint8List();
      bytes[0] = UdpSendOption.disconnect.value;
    }

    try {
      _socket.send(bytes, remoteEndpoint.address, remoteEndpoint.port);
    } catch (_) {}

    return true;
  }

  @override
  void writeBytes(Uint8List bytes) {
    try {
      _socket.send(bytes, remoteEndpoint.address, remoteEndpoint.port);
    } on SocketException catch (e) {
      disconnectInternal(HazelInternalError.socketExceptionSend,
          'Could not send data as a SocketException occurred: $e');
    }
  }

  /// Called when the [_socket] emits a [RawSocketEvent.read] event.
  void _handleRead(Datagram datagram) {
    var msg = ByteBuffer.pooledFromData(datagram.data);

    try {
      // Exit. If no bytes read, we've failed.
      if (msg.length <= 0) {
        disconnectInternal(
            HazelInternalError.receivedZeroBytes, 'Received 0 bytes');
        return;
      }

      handleReceive(msg);
    } finally {
      msg.release();
    }
  }

  @override
  void close() {
    if (_disconnectCompleter != null && state == ConnectionState.connecting) {
      _disconnectCompleter.completeError(SocketException(
          'Remote disconnected during the handshake. See onDisconnected for more info.'));
      _disconnectCompleter = null;
    }
    state = ConnectionState.not_connected;

    keepAlive?.handleClose();
    reliability?.handleClose();
    _reliablePacketTimer?.cancel();
    _socket?.close();
  }
}
