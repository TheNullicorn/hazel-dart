/// Specifies how a message should be sent between connections.
class SendOption {
  /// Requests unreliable delivery with no fragmentation.
  ///
  /// Sending data using unreliable delivery means that data is not
  /// guaranteed to arrive at it's destination nor is it guaranteed to arrive
  /// only once. However, unreliable delivery can be faster than other
  /// methods and it typically requires a smaller number of protocol bytes
  /// than other methods. There is also typically less processing involved
  /// and less memory needed as packets are not stored once sent.
  static const none = SendOption._internal(0);

  /// Requests data be sent reliably but with no fragmentation.
  ///
  /// Sending data reliably means that data is guaranteed to arrive and to
  /// arrive only once. Reliable delivery typically requires more processing,
  /// more memory (as packets need to be stored in case they need resending),
  /// a larger number of protocol bytes and can be slower than unreliable
  /// delivery.
  static const reliable = SendOption._internal(1);

  final int value;

  const SendOption._internal(this.value);

  /// Get a send option by its numeric value.
  static SendOption fromValue(int value) => value == 1 ? reliable : none;
}
