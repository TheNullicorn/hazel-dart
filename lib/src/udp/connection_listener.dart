import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import '../byte_buffer.dart';
import '../connection.dart';
import '../endpoint.dart';
import '../send_option.dart';
import 'client_connection.dart';
import 'keep_alive.dart';
import 'protocol.dart';
import 'reliability.dart';
import 'udp.dart';

class BasicUdpConnectionListener extends UdpConnectionListener {
  @override
  final IPEndPoint endpoint;

  @override
  final InternetAddressType ipMode;

  final Map<IPEndPoint, BasicUdpServerConnection> _allConnections = {};
  RawDatagramSocket _socket;
  Timer _reliablePacketTimer;
  bool _acceptingConnections = false;

  BasicUdpConnectionListener(this.endpoint, [this.ipMode]) {
    if (ipMode != InternetAddressType.IPv4 &&
        ipMode != InternetAddressType.IPv6) {
      throw ArgumentError.value(
          ipMode.name, 'ipMode', 'Unsupported address type');
    }
  }

  @override
  int get connectionCount => _allConnections.length;

  @override
  void start() async {
    _socket = await RawDatagramSocket.bind(endpoint.address, endpoint.port);
    _reliablePacketTimer =
        Timer.periodic(manageReliablesInterval, _manageReliablePackets);

    _socket.listen((event) {
      if (event == RawSocketEvent.read) _handleRead(_socket.receive());
    });
    _acceptingConnections = true;
  }

  @override
  void stop() {
    _acceptingConnections = false;

    _reliablePacketTimer?.cancel();
    _socket?.close();
    _allConnections.values.forEach((connection) => connection.close());
  }

  void _manageReliablePackets(Timer timer) {
    _allConnections.values
        .forEach((element) => element.reliability.manageReliablePackets());
  }

  void _handleRead(Datagram datagram) {
    if (!_acceptingConnections || datagram.data.isEmpty) {
      return;
    }

    // 4 bytes = send option + packet ID + Hazel version
    var isHello = datagram.data[0] == UdpSendOption.hello.value &&
        datagram.data.length >= 4;
    var remoteEndpoint = IPEndPoint(datagram.address, datagram.port);

    var connection = _allConnections[remoteEndpoint];
    ByteBuffer msg;
    if (connection == null) {
      // Ignore non-hello packets until a hello is sent
      if (!isHello) return;

      // See if the connection should be rejected
      var response = (onConnectionInit == null)
          ? null
          : onConnectionInit(remoteEndpoint, datagram.data);
      if (response != null) {
        _sendData(response, remoteEndpoint);
        return;
      }

      // Add the connection
      connection = BasicUdpServerConnection(this, remoteEndpoint, ipMode);
      if (_allConnections.containsKey(remoteEndpoint)) {
        throw StateError('Connection already exists. This should not happen.');
      } else {
        _allConnections[remoteEndpoint] = connection;
      }

      // Invoke new connection handler
      var handshakeMsg = ByteBuffer.pooledFromData(datagram.data);
      handshakeMsg.skip(4); // 4 bytes = send option + packet ID + Hazel version
      invokeNewConnection(connection, handshakeMsg);
    }

    // Invoke message handler
    msg = ByteBuffer.pooledFromData(datagram.data);
    try {
      connection.handleReceive(msg);
    } finally {
      msg.release();
    }
  }

  void _sendData(Uint8List data, IPEndPoint remoteEndpoint) {
    try {
      _socket.send(data, remoteEndpoint.address, remoteEndpoint.port);
    } catch (_) {}
  }

  void _removeConnectionTo(IPEndPoint endPoint) {
    _allConnections.remove(endpoint);
  }
}

class BasicUdpServerConnection extends UdpConnection with UdpProtocol {
  final BasicUdpConnectionListener listener;

  @override
  final IPEndPoint endpoint;

  @override
  final InternetAddressType ipMode;

  BasicUdpServerConnection(this.listener, this.endpoint, this.ipMode) {
    state = ConnectionState.connected;
    keepAlive = KeepAliveManager(this);
    reliability = ReliablePacketManager(this);
    keepAlive.initKeepAliveTimer();
  }

  @override
  IPEndPoint get remoteEndpoint => endpoint;

  @override
  void connect(Uint8List bytes, [Duration timeout]) {
    throw UnsupportedError(
        'Cannot manually connect to a BasicUdpServerConnection. Did you mean to use a BasicUdpClientConnection?');
  }

  @override
  void writeBytes(Uint8List data) {
    listener._sendData(data, remoteEndpoint);
  }

  @override
  bool sendDisconnect([ByteBuffer msg]) {
    if (state != ConnectionState.connected) return false;
    state = ConnectionState.not_connected;

    var bytes;
    if (msg == null || msg.length == 0) {
      bytes = Uint8List(1);
    } else if (msg.sendOption == SendOption.reliable) {
      throw ArgumentError('Disconnect messages can only be unreliable.');
    } else {
      bytes = msg.toUint8List();
    }
    bytes[0] = UdpSendOption.disconnect.value;

    try {
      listener._sendData(bytes, remoteEndpoint);
    } catch (_) {}

    return true;
  }

  @override
  void close() {
    state = ConnectionState.not_connected;

    keepAlive?.handleClose();
    reliability?.handleClose();
    listener._removeConnectionTo(remoteEndpoint);
  }
}
