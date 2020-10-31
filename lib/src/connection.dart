import 'dart:io';
import 'dart:typed_data';

import 'package:meta/meta.dart';

import 'byte_buffer.dart';
import 'endpoint.dart';
import 'send_option.dart';

/// Represents the state a [Connection] is currently in.
enum ConnectionState {
  /// The [Connection] has either not been established yet or has been disconnected.
  not_connected,

  /// The [Connection] is currently in the process of connecting to an endpoint.
  connecting,

  /// The [Connection] is connected and data can be transferred.
  connected
}

/// Base class for all connections.
///
/// Connection is the base class for all connections that Hazel can make. It
/// provides common functionality and a standard interface to allow
/// connections to be swapped easily.
abstract class Connection {
  /// The remote end point of this Connection.  This is the end point that
  /// this connection is connected to (i.e. the other device).
  IPEndpoint get endpoint;

  /// The layer 3 protocol used to send messages over the connection.
  InternetAddressType get ipMode;

  /// The state of this connection.
  ConnectionState state = ConnectionState.not_connected;

  /// Called when a message has been received from the end point of this
  /// connection.
  ///
  /// This should be assigned before [connect] is called. Otherwise, some
  /// packets may be missed.
  ///
  /// After this function completes, the [msg] will be reallocated using
  /// [ByteBuffer.release], so be sure to extract what you need from it
  /// during the execution of this function.
  void Function(Connection sender, ByteBuffer msg, SendOption sendOption)
      onDataReceived;

  /// Called when the end point disconnects or an error occurs.
  ///
  /// Disconnected is invoked when the connection is closed due to an
  /// exception occurring or because the remote end point disconnected.
  ///
  /// This should be assigned before [connect] is called. Otherwise, it may
  /// not be executed.
  void Function(ByteBuffer msg, [String reason]) onDisconnected;

  /// Sends a number of bytes to the end point of the connection using the
  /// [SendOption] specified by the [msg]'s [sendOption][ByteBuffer.sendOption].
  ///
  /// The sendOptions parameter is only a request to use those options. The
  /// actual method used to send the data is up to the implementation. There
  /// are circumstances where this parameter may be ignored but in general
  /// any implementer should aim to always follow the user's request.
  void send(ByteBuffer msg);

  /// Sends a number of bytes to the end point of the connection using the
  /// specified [SendOption], [sendOption].
  ///
  /// The sendOptions parameter is only a request to use those options. The
  /// actual method used to send the data is up to the implementation. There
  /// are circumstances where this parameter may be ignored but in general
  /// any implementer should aim to always follow the user's request.
  void sendBytes(Uint8List bytes, [SendOption sendOption = SendOption.none]);

  /// Connects the connection to a server and begins listening. This method
  /// is asynchronous and may throw if something goes wrong while connecting.
  ///
  /// [bytes] is the data to send in the initial handshake. If the receiver
  /// does not complete the handshake after [timeout], an error is thrown.
  void connect(Uint8List bytes, [Duration timeout]);

  /// For times when you want to force [onDisconnected] to fire as well
  /// as close the connection.
  ///
  /// To close the connection without firing [onDisconnected], see [close].
  void disconnect(String reason, [ByteBuffer msg]);

  /// Closes the connection immediately and ungracefully.
  ///
  /// Calling this method does not invoke [onDisconnected].
  void close();

  /// Internal method for invoking the [onDataReceived] event.
  ///
  /// [msg] is the data that was received in the message and [sendOption] is
  /// the option used to send the message.
  ///
  /// Invokes the [onDataReceived] event on this connection to alert
  /// subscribers a new message has been received. The bytes and the send
  /// option that the message was sent with should be passed in to give to
  /// the subscribers.
  @protected
  void invokeDataReceived(ByteBuffer msg, SendOption sendOption) {
    try {
      if (onDataReceived == null) return;
      onDataReceived(this, msg, sendOption);
    } catch (_) {} finally {
      msg.release();
    }
  }

  /// Internal method for invoking the [onDisconnected] event.
  ///
  /// [reason] is the internal reason (or error message) for the disconnect.
  /// [msg] is any extra data received in the disconnect packet.
  ///
  /// Invokes the [onDisconnected] event to alert subscribers that this
  /// connection has been disconnected either by the end point or because an
  /// error occurred. If an error occurred the error should be passed into
  /// [reason]. Otherwise, null can be passed in.
  @protected
  void invokeDisconnected(String reason, [ByteBuffer msg]) {
    if (onDisconnected == null) return;
    try {
      onDisconnected(msg, reason);
    } catch (_) {}
  }
}

/// Base class for all connection listeners.
///
/// [ConnectionListener]s are server side objects that listen for clients and
/// create matching server side connections for each client in a similar way
/// to TCP. These connections should be ready for communication immediately.
///
/// Each time a client connects, the [onNewConnection] event will be invoked
/// to alert all subscribers to the new connection. A disconnected event is
/// then present on the [Connection] that is passed to the subscribers.
abstract class ConnectionListener {
  /// Invoked when a new client connects.
  ///
  /// [connection] is the connection that was just created, and
  /// [handshakeData] is any data sent by the client when they connected.
  void Function(Connection connection, ByteBuffer handshakeData)
      onNewConnection;

  /// Makes this connection listener begin listening for connections.
  ///
  /// This instructs the listener to begin listening for new clients
  /// connecting to the server. When a new client connects the
  /// [onNewConnection] event will be invoked containing the connection to
  /// the new client. To stop listening, you should call [stop].
  void start();

  /// Makes this connection listener stop listening for connections.
  ///
  /// This method is not graceful on its own, and you should try to properly
  /// disconnect each client first before calling this method.
  void stop();

  /// Invokes the [onNewConnection] event with the supplied [connection].
  ///
  /// [handshakeData] is any user-sent bytes that were received as part of the
  /// handshake. Implementers should call this to invoke the
  /// [onNewConnection] event before data is received so that subscribers do
  /// not miss any data that may have been sent immediately after connecting.
  @protected
  void invokeNewConnection(Connection connection, ByteBuffer handshakeData) {
    try {
      if (onNewConnection == null) return;
      onNewConnection(connection, handshakeData);
    } catch (_) {} finally {
      handshakeData.release();
    }
  }
}
