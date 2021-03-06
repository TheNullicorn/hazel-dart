import 'dart:io';

import 'package:quiver/core.dart';

/// The address and port of an internet endpoint.
class IPEndpoint {
  final InternetAddress address;
  final int port;

  IPEndpoint(this.address, this.port);

  @override
  bool operator ==(Object other) {
    return other is IPEndpoint &&
        other.address == address &&
        other.port == port;
  }

  @override
  int get hashCode => hash2(address, port);

  @override
  String toString() {
    return '${address.address}:$port';
  }
}
