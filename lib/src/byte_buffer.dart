import 'dart:convert';
import 'dart:typed_data';

import 'pool.dart';
import 'send_option.dart';

final Pool<ByteBuffer> _pool = Pool(() => ByteBuffer());

/// A buffer of binary data that can be read from and written to.
///
/// Some buffers may be pooled to conserve memory, so be sure to call
/// [release] when you're done with a buffer.
class ByteBuffer with Pooled {
  /// The underlying buffer.
  Uint8List _buf;

  /// The reader head. This is the buffer index where new data will be read
  /// from.
  int _readerIndex;

  /// The writer head. This is the buffer index where new data will be
  /// written.
  int _writerIndex;

  /// The start index of every message currently being written.
  ///
  /// If any nested messages are being written (a message inside a message),
  /// then the last index is for the most deeply nested message.
  List<int> _messageStarts;

  /// If this buffer is meant to be sent over a connection, this is the
  /// message's [SendOption]. Otherwise, this is null.
  SendOption _sendOption;

  /// The underlying buffer. Any modifications made to the array will be
  /// reflected in the buffer, so be cautious when modifying it.
  Uint8List get buf => _buf;

  /// The reader index of this buffer. Reader functions will read starting
  /// at this index and increment it for each byte read.
  int get readerIndex => _readerIndex;

  /// The writer index of this buffer. Writer function will begin writing
  /// at this index and increment it for each byte written.
  int get writerIndex {
    if (_sendOption == null) {
      return _writerIndex;
    } else if (_sendOption == SendOption.reliable) {
      return _writerIndex - 3;
    } else {
      return _writerIndex - 1;
    }
  }

  /// The number of bytes written to this buffer. This should always be the
  /// same as [writerIndex], but exists for the sake of clarity.
  int get length => writerIndex;

  /// If this buffer represents a message that will be sent over a
  /// connection, this returns the message's [SendOption]. Otherwise, null is
  /// returned;
  SendOption get sendOption => _sendOption;

  final int messageTag;

  final int _offset;

  ByteBuffer([int initialCapacity = 256])
      : _buf = Uint8List(initialCapacity),
        _readerIndex = 0,
        _writerIndex = 0,
        _offset = 0,
        _sendOption = null,
        messageTag = null;

  ByteBuffer.withOption(this._sendOption, [int initialCapacity = 256])
      : _buf = Uint8List(initialCapacity),
        _readerIndex = 0,
        _writerIndex = 0,
        _offset = 0,
        messageTag = null {
    _clear(_sendOption);
  }

  ByteBuffer.fromData(Uint8List data, [int length])
      : _buf = data,
        _readerIndex = 0,
        _offset = 0,
        _sendOption = null,
        messageTag = null {
    length ??= data.length;
    RangeError.checkNotNegative(length, 'length');
    _writerIndex = length;
  }

  ByteBuffer._withFlag(this.messageTag, this._offset) : _sendOption = null;

  factory ByteBuffer.pooled() => ByteBuffer.pooledWithOption(null);

  factory ByteBuffer.pooledWithOption(SendOption sendOption) {
    var result = _pool.getObject();
    result._sendOption = sendOption;
    result._clear(sendOption);

    return result;
  }

  factory ByteBuffer.pooledFromData(Uint8List data, [int length]) {
    var result = _pool.getObject();

    length ??= data.length;
    RangeError.checkNotNegative(length, 'length');

    if (data.length < length) {
      // If the input buffer is smaller than the desired length, expand it
      data = Uint8List(length)..setRange(0, data.length, data);
    }

    if (result._buf.length < length) {
      // If the buffer is too small, just use the array itself
      result._buf = data;
    } else {
      // If the buffer is big enough, copy the data from the array
      result._buf.setRange(0, data.length, data);
    }

    result._readerIndex = 0;
    result._writerIndex = length;
    return result;
  }

  /// Whether or not there is another byte in this buffer. If the
  /// [readerIndex] is at the buffer's end, this returns false.
  bool isReadable([int amount = 1]) => (_readerIndex + amount <= _writerIndex);

  /// Whether or not writing is enabled for this buffer. Attempting to write
  /// otherwise may throw an error.
  bool isWritable() => _offset == 0;

  /// Whether or not there is enough space after [readerIndex] to use
  /// [readMessage].
  bool isMessageReadable() => isReadable(3);

  /// Copies the data in this buffer into the provided array.
  void copyInto(Uint8List array) {
    var bytesToCopy = array.length;
    if (bytesToCopy > length) bytesToCopy = length;
    array.setRange(0, bytesToCopy, _buf, _offset);
  }

  /// Copies the data in this buffer into a new byte array and returns the
  /// array.
  Uint8List toUint8List([int length]) {
    var result = Uint8List(length ?? this.length);
    copyInto(result);
    return result;
  }

  /// Increase the reader index by a certain amount without reading any of
  /// the data in between
  ///
  /// [amount] is the number of bytes to be skipped, and must be greater than or
  /// equal to 0.
  void skip([int amount = 1]) {
    if (amount < 0) {
      throw RangeError.value(
          amount, 'length', 'Cannot skip a negative number of bytes');
    }

    _readerIndex += amount;
  }

  /// Starts a message.
  ///
  /// Messages are chunks of data prefixed with the data's length (2 bytes)
  /// and the [tag] of the data (1 byte). Any bytes written before the
  /// next call to [endMessage] will be inside of this message.
  void startMessage(int tag) {
    _messageStarts ??= [];

    _messageStarts.add(_writerIndex);
    writeInt16(0x0000); // Leave 2 bytes blank for message length
    writeInt8(tag);
  }

  /// Ends the most recently started message.
  ///
  /// See [startMessage] for more info on messages.
  void endMessage() {
    if (_messageStarts == null || _messageStarts.isEmpty) {
      throw StateError('No messages to end');
    }
    var lastMessageStart = _messageStarts.removeLast();
    var msgLength = _writerIndex - lastMessageStart - 3; // Minus length & type

    // Move the writer index backwards for a sec to update the message's
    // length field
    var tempWriterIndex = _writerIndex;
    _writerIndex = lastMessageStart;
    writeInt16(msgLength);

    // Fix the writer index
    _writerIndex = tempWriterIndex;
  }

  /// Clears the most recently started message and sets the buffer's
  /// [writerIndex] to wherever it was before [startMessage] was called.
  ///
  /// See [startMessage] for more info on messages.
  void cancelMessage() {
    _writerIndex = _messageStarts.removeLast();
    _buf = Uint8List.sublistView(_buf, 0, _writerIndex);
  }

  /// Read the next message from the buffer.
  ///
  /// If the message header cannot be read, or the message length is past the
  /// end of the buffer, null is returned. See [startMessage] for more info
  /// on messages.
  ByteBuffer readMessage() {
    var messageLength = readInt16();
    var messageTag = readInt8();

    var msgBuf = ByteBuffer._withFlag(messageTag, _offset + _readerIndex);
    msgBuf._buf = _buf;
    msgBuf._readerIndex = 0;
    msgBuf._writerIndex = messageLength;

    _readerIndex += messageLength;
    return msgBuf;
  }

  /// Read a string from the buffer with the provided encoding.
  ///
  /// If the string's [length] is not provided, it will be determined by
  /// reading a packed-integer from the buffer first.
  ///
  /// If no [codec] is provided, UTF-8 is used by default.
  String readString({int length = -1, Encoding codec = utf8}) {
    length = length >= 0 ? length : readPackedInt32();
    return codec.decode(readBytes(length));
  }

  /// Read a certain number of bytes from the buffer.
  ///
  /// If a [length] is not provided, it will be determined by reading a
  /// packed-integer from the buffer first.
  Uint8List readBytes([int length]) {
    length ??= readPackedInt32();

    var output = Uint8List(length);
    output.setRange(0, output.length, _buf, _offset + _readerIndex);
    _readerIndex += length;

    return output;
  }

  /// Read a boolean (1 byte) from the buffer.
  ///
  /// If the byte's value is 0x00, false is returned; any other value results
  /// in true.
  bool readBool() {
    return readInt8() != 0x00;
  }

  /// Read a single-precision, floating-point number (4 bytes) from the buffer.
  double readFloat32([Endian endian = Endian.little]) {
    return readBytes(4).buffer.asByteData().getFloat32(0, endian);
  }

  /// Read a variable-length integer (up to 5 bytes) from the buffer.
  ///
  /// If the integer is encoded using more than 5 bytes, only the first 5 are
  /// read.
  int readPackedInt32([bool signed = false]) {
    var result = 0;
    var totalBytesRead = 0;
    int lastRead;

    do {
      lastRead = readInt8();
      var value = lastRead & 0x7F;
      result |= (value << (7 * totalBytesRead));

      totalBytesRead++;
    } while ((lastRead & 0x80) != 0 && totalBytesRead < 5);

    // Convert to signed if necessary
    return signed ? result.toSigned(7 * totalBytesRead + 1) : result;
  }

  /// Read a 64-bit integer (8 bytes) from the buffer.
  int readInt64({bool signed = false, Endian endian = Endian.little}) {
    return _readInt(8, signed, endian);
  }

  /// Read a 32-bit integer (4 bytes) from the buffer.
  int readInt32({bool signed = false, Endian endian = Endian.little}) {
    return _readInt(4, signed, endian);
  }

  /// Read a 16-bit integer (2 bytes) from the buffer.
  int readInt16({bool signed = false, Endian endian = Endian.little}) {
    return _readInt(2, signed, endian);
  }

  /// Read a signed, 8-bit integer (1 byte) from the buffer.
  int readInt8({bool signed = false}) {
    if (signed) {
      return _readInt(1, true, Endian.little);
    } else {
      return _readByte();
    }
  }

  /// Read an integer from the buffer.
  ///
  /// [byteWidth] is the length of the integer in bytes (e.g. 4 bytes for a
  /// 32-bit integer). [signed] indicates whether or not the most significant
  /// bit should be treated as a sign bit. [endian] indicates the integer's
  /// byte order.
  int _readInt(int byteWidth, bool signed, Endian endian) {
    var output = 0;
    if (endian == Endian.little) {
      for (var i = 0; i < byteWidth; i++) {
        output |= _readByte() << (8 * i);
      }
    } else {
      for (var i = byteWidth - 1; i >= 0; i--) {
        output |= _readByte() << (8 * i);
      }
    }
    return signed ? output = output.toSigned(byteWidth * 8) : output;
  }

  /// Read a single byte of data from the buffer.
  ///
  /// If the [readerIndex] is out of bounds, zero is returned.
  int _readByte() {
    if (!isReadable()) return 0;
    return _buf[_offset + _readerIndex++].toUnsigned(8);
  }

  /// Write a string to the buffer with the provided encoding.
  ///
  /// If no [codec] is provided, UTF-8 is used by default.
  void writeString(String value, [Encoding codec = utf8]) {
    writePackedInt32(value.length);
    writeBytes(codec.encode(value));
  }

  /// Write an array of bytes directly to the buffer.
  void writeBytes(Uint8List data, [int offset = 0, int length]) {
    length ??= data.length;
    _resizeIfNecessary(length);
    for (var i = offset; i < length; i++) {
      _writeByte(data[i]);
    }
  }

  /// Write an array of bytes to the buffer, prefixed by their length as a
  /// packed-integer.
  void writeBytesAndSize(Uint8List data, [int offset = 0, int length]) {
    length ??= data.length;
    writePackedInt32(length);
    writeBytes(data, offset, length);
  }

  /// Write the data from another buffer into this one.
  ///
  /// To include the [data]'s [sendOption] header, set [includeHeader] to
  /// true. Otherwise, it will not be copied over.
  void writeData(ByteBuffer data, [bool includeHeader = false]) {
    var headerOffset = 0;
    if (!includeHeader) {
      if (data._sendOption == SendOption.reliable) {
        headerOffset = 3;
      } else if (data._sendOption == SendOption.none) {
        headerOffset = 1;
      }
    }
    writeBytes(
        data._buf, data._offset + headerOffset, data.length - headerOffset);
  }

  /// Write a boolean (1 byte) to the buffer.
  ///
  /// false is encoded as 0x00; true is encoded as 0x01.
  void writeBool(bool value) {
    writeInt8(value == false ? 0x00 : 0x01);
  }

  /// Write a single-precision, floating-point number (4 bytes) to the buffer.
  void writeFloat32(double value, [Endian endian = Endian.little]) {
    var bytes = Uint8List(4)..buffer.asByteData().setFloat32(0, value, endian);
    writeBytes(bytes);
  }

  /// Write a variable-length integer to the buffer.
  ///
  /// If the [value] takes up more than 32 bits, it will be truncated to fit
  /// that limit.
  void writePackedInt32(int value) {
    value = value.toUnsigned(32);
    do {
      var temp = value.toUnsigned(7);
      if (value >= 0x80) temp |= 0x80;

      writeInt8(temp);
      value = value.logicalShiftRight(7);
    } while (value != 0);
  }

  /// Write a 64-bit integer (8 bytes) to the buffer.
  void writeInt64(int value, [Endian endian = Endian.little]) {
    _writeInt(value, 8, endian);
  }

  /// Write a 32-bit integer (4 bytes) to the buffer.
  void writeInt32(int value, [Endian endian = Endian.little]) {
    _writeInt(value, 4, endian);
  }

  /// Write a 16-bit integer (2 bytes) to the buffer.
  void writeInt16(int value, [Endian endian = Endian.little]) {
    _writeInt(value, 2, endian);
  }

  /// Write an 8-bit integer (1 byte) to the buffer.
  void writeInt8(int value) {
    _resizeIfNecessary();
    _writeByte(value);
  }

  /// Write an integer ([value]) to the buffer at the current writer index.
  ///
  /// [byteLength] is the number of bytes that should be used to encode the
  /// value (e.g. 4 for a 32-bit integer). [endian] determines the byte order
  /// that the integer is encoded
  /// in.
  void _writeInt(int value, int byteLength, Endian endian) {
    _resizeIfNecessary(byteLength);

    value = value.toUnsigned(byteLength * 8);
    if (endian == Endian.little) {
      for (var i = 0; i < byteLength; i++) {
        _writeByte((value >> (8 * i)) & 0xFF);
      }
    } else {
      for (var i = byteLength - 1; i >= 0; i--) {
        _writeByte((value >> (8 * i)) & 0xFF);
      }
    }
  }

  /// Write a single byte of data to the buffer without. This method is
  /// unsafe and will not check if the buffer needs resized.
  void _writeByte(int value) {
    if (!isWritable()) {
      throw UnsupportedError('Writing is not allowed in message buffers');
    }
    _buf[_offset + _writerIndex++] = value.toUnsigned(8);
  }

  /// Increases the size of the underlying buffer if [writerIndex] is greater
  /// than or equal to [_buf.length].
  void _resizeIfNecessary([int amount = 1]) {
    if (!isWritable()) {
      throw UnsupportedError('Resizing is not possible in message buffers');
    }

    var requiredSize = _offset + _writerIndex + amount;
    if (requiredSize >= _buf.length) {
      var newBufSize = _buf.length;
      while (newBufSize < requiredSize) {
        // Add half to the buffer's size until it can fit the new index
        newBufSize += newBufSize ~/ 2 + 1;
      }

      var newBuf = Uint8List(newBufSize);
      newBuf.setAll(0, _buf);
      _buf = newBuf;
    }
  }

  @override
  String toString() {
    var output = '[';
    if (messageTag != null) output += '$messageTag; ';
    for (var i = _offset; i < _offset + _writerIndex; i++) {
      output += _buf[i].toRadixString(16).padLeft(2, '0');
      if (i < _offset + _writerIndex - 1) output += ', ';
    }
    return output + ']';
  }

  void _clear(SendOption sendOption) {
    if (_offset != 0) {
      throw UnsupportedError('Message buffers cannot be cleared');
    }
    _readerIndex = 0;
    _writerIndex = 0;
    if (sendOption == null) return;

    writeInt8(sendOption.value);
    if (sendOption == SendOption.reliable) {
      writeInt16(0); // Leave blank for reliable ID
    }
  }

  @override
  void release() {
    _clear(null);
    _pool.putObject(this);
  }
}

/// Utility extension for performing logical shifts on integers.
extension _LogicalShiftInt on int {
  int logicalShiftRight(int bits) {
    return (this >> bits) & ~(-1 << (64 - bits));
  }
}
