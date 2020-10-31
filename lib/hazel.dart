/// A Dart port of willardf's
/// [Hazel Networking Library](https://github.com/willardf/Hazel-Networking),
/// originally written in C#.
///
/// Although this port does its best to stay true to the original, the names
/// and usages of some things have admittedly been altered to better suit the
/// Dart language conventions, as well as the language's limitations.
///
/// Much of the documentation for this port was taken directly (and often
/// altered) from the original.
library hazel_dart;

export 'src/byte_buffer.dart';
export 'src/connection.dart';
export 'src/endpoint.dart';
export 'src/network_connection.dart';
export 'src/send_option.dart';
export 'src/udp/udp.dart';
