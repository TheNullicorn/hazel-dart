import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:quiver/core.dart';

import '../endpoint.dart';

final _broadcastAddress = InternetAddress('255.255.255.255');

/// A simple tool for broadcasting messages to the local network using UDP.
///
/// To use the broadcaster, you'll first need to set the message that you
/// want to broadcast (using [setMessage]). After that, the message you set
/// will be broadcast every time you call the [broadcast] function.
///
/// Notes:
/// - [setMessage] may be called at any time to change the message that will be
///   broadcast.
/// - The first time that [broadcast] is called, it may take slightly longer
///   because the broadcaster must bind to a port.
class UdpBroadcaster {
  /// The UDP port that messages will be broadcast to.
  final int port;

  /// The UDP socket used to send broadcast messages.
  RawDatagramSocket _socket;

  /// The last message set using [setMessage].
  Uint8List _currentMsg;

  UdpBroadcaster(this.port);

  /// Sets the message to be sent in subsequent calls to [broadcast].
  void setMessage(String contents) {
    if (contents == null || contents.isEmpty) {
      throw ArgumentError('\'contents\' cannot be empty or null');
    }
    var payloadBytes = utf8.encode(contents);

    // 2 extra bytes for the broadcast header, 0x0402
    _currentMsg = Uint8List(2 + payloadBytes.length);
    _currentMsg[0] = 4;
    _currentMsg[1] = 2;
    _currentMsg.setAll(2, payloadBytes);
  }

  /// Broadcasts the current message to the local network.
  ///
  /// Be sure that [setMessage] is called at least once before this.
  void broadcast() async {
    if (_socket == null) {
      _socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      _socket.broadcastEnabled = true; // Required so we can broadcast
    }

    if (_currentMsg == null || _currentMsg.isEmpty) {
      throw StateError('Nothing to broadcast. Try using setMessage first.');
    }
    _socket.send(_currentMsg, _broadcastAddress, port);
  }

  /// Closes the socket used by this broadcaster.
  ///
  /// Calling [broadcast] again will automatically reopen it.
  void stop() {
    _socket?.close();
    _currentMsg = null;
    _socket = null;
  }
}

/// A broadcast packet sent by a [UdpBroadcaster].
class BroadcastPacket {
  /// The message sent in the packet.
  final String data;

  /// The address of the device that broadcast the packet.
  final IPEndPoint sender;

  /// The time when the packet was received.
  ///
  /// If the packet's [data] and [sender] were received multiple times, this is
  /// most recent time when it was received (since [packets], [start] or
  /// [clearPendingPackets] were called).
  final DateTime receiveTime;

  BroadcastPacket(this.data, this.receiveTime, this.sender);

  @override
  bool operator ==(Object other) {
    return other is BroadcastPacket &&
        other.sender == sender &&
        other.data == data;
  }

  @override
  int get hashCode => hash2(data, sender);

  @override
  String toString() => 'BroadcastPacket from $sender: "$data"';
}

/// Listens for UDP messages sent on the local network by a [UdpBroadcaster].
///
/// Because this class acts as a [Stream], packets can be listened for using
/// any of the standard stream methods ([listen], [forEach], etc).
class UdpBroadcastListener extends Stream<BroadcastPacket> {
  /// The UDP port that this listener will listen for messages on.
  final int port;

  /// All subscribers to events for this listener.
  final List<_BroadcastSubscriber> _subscribers = [];

  /// The UDP socket used to listen for message.
  RawDatagramSocket _socket;

  UdpBroadcastListener(this.port);

  /// Begins listening for incoming broadcast packets.
  void start() async {
    if (_socket != null) return;
    _socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, port);
    _socket.broadcastEnabled = true;
    _socket.listen((event) {
      if (event == RawSocketEvent.read) {
        _handleReceive(_socket.receive());
      }
    });
  }

  /// Stops listening for incoming packets.
  void stop() async {
    if (_socket != null) {
      try {
        await _socket.close();
      } catch (e, st) {
        _subscribers.forEach((sub) => sub.invokeErrorHandler(e, st));
        rethrow;
      } finally {
        _socket = null;
      }
    }

    // Remove all subscribers
    while (_subscribers.isNotEmpty) {
      var sub = _subscribers.removeLast();
      try {
        sub.invokeDoneHandler();
      } catch (e, st) {
        sub.invokeErrorHandler(e, st);
      }
    }
  }

  /// Internal handler for incoming packets.
  void _handleReceive(Datagram datagram) {
    var receiveTime = DateTime.now();

    var data = datagram.data;
    if (data.length < 3 || data[0] != 4 || data[1] != 2) return;

    var sender = IPEndPoint(datagram.address, datagram.port);
    var msg = utf8.decode(data.sublist(2), allowMalformed: true);

    var packet = BroadcastPacket(msg, receiveTime, sender);
    for (var sub in _subscribers) {
      try {
        sub.invokeDataHandler(packet);
      } catch (e, st) {
        sub.invokeErrorHandler(e, st);
      }
    }
  }

  @override
  StreamSubscription<BroadcastPacket> listen(
      void Function(BroadcastPacket event) onData,
      {Function onError,
      void Function() onDone,
      bool cancelOnError}) {
    var subscription = _BroadcastSubscriber(this)
      ..onData(onData)
      ..onDone(onDone)
      ..onError(onError);
    _subscribers.add(subscription);
    return subscription;
  }

  void _removeSubscriber(_BroadcastSubscriber subscription) {
    _subscribers.remove(subscription);
  }
}

/// A stream subscription to a [UdpBroadcastListener].
class _BroadcastSubscriber implements StreamSubscription<BroadcastPacket> {
  /// The listener that this subscription is for.
  final UdpBroadcastListener listener;

  /// Stores any messages received while [isPaused] is true.
  final List<BroadcastPacket> _pauseBuffer = [];

  /// Whether or not the subscriber has paused [onData] events.
  ///
  /// If so, any messages received during that time will be buffeed in
  /// [_pauseBuffer].
  bool _paused = false;

  /// Handler function for incoming packets.
  void Function(BroadcastPacket data) _dataHandler;

  /// Handler function for the [listener] stopping.
  void Function() _doneHandler;

  /// Function for any errors occurring in the [listener].
  Function _errorHandler;

  _BroadcastSubscriber(this.listener);

  @override
  bool get isPaused => _paused;

  @override
  void onData(void Function(BroadcastPacket data) handleData) {
    _dataHandler = handleData;
  }

  @override
  void onDone(void Function() handleDone) {
    _doneHandler = handleDone;
  }

  @override
  void onError(Function handleError) {
    _errorHandler = handleError;
  }

  @override
  void pause([Future<void> resumeSignal]) {
    _paused = true;
    resumeSignal?.then((_) => resume());
  }

  @override
  void resume() {
    if (!_paused) return;
    _paused = false;
    while (_pauseBuffer.isNotEmpty) {
      invokeDataHandler(_pauseBuffer.removeLast());
    }
  }

  @override
  Future<void> cancel() {
    listener._removeSubscriber(this);
    return Future.value();
  }

  @override
  Future<E> asFuture<E>([E futureValue]) {
    var completer = Completer<E>();

    if (futureValue == null) {
      onDone(completer.complete);
    } else {
      onDone(() => completer.complete(futureValue));
    }
    onError(completer.completeError);

    return completer.future;
  }

  /// Invokes the data handler for this subscriber (if available).
  void invokeDataHandler(BroadcastPacket msg) {
    if (isPaused) return _pauseBuffer.add(msg);
    _dataHandler?.call(msg);
  }

  /// Invokes the completion handler for this subscriber (if available).
  void invokeDoneHandler() {
    cancel();
    _doneHandler.call();
  }

  /// Invokes the error handler for this subscriber (if available; otherwise,
  /// the error is forwarded to [Zone.handleUncaughtError]).
  void invokeErrorHandler(dynamic error, [StackTrace stackTrace]) {
    if (_errorHandler != null) {
      _errorHandler(error, stackTrace);
    } else {
      Zone.current.handleUncaughtError(error, stackTrace);
    }
  }
}
