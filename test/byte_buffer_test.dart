import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:hazel_dart/hazel.dart';
import 'package:test/test.dart';

void main() {
  group('Writer tests', () {
    test('Write message', () {
      final tag = 1;
      final value1 = 65534;

      var msg = ByteBuffer(128);
      msg.startMessage(tag);
      msg.writeInt32(value1);
      msg.endMessage();

      expect(msg.length, 2 + 1 + 4);

      var data = msg.buf.buffer.asByteData();
      expect(data.getUint16(0, Endian.little), 4);
      expect(data.getUint8(2), tag);
      expect(data.getUint32(3, Endian.little), value1);
    });

    test('Cancel message', () {
      var msg = ByteBuffer(128);
      msg.startMessage(1);
      msg.writeInt32(32);

      msg.startMessage(2);
      msg.writeInt32(2);
      msg.cancelMessage();

      expect(msg.length, 7);

      msg.cancelMessage();

      expect(msg.length, 0);
    });

    test('Write int', () {
      final value1 = pow(2, 31) - 1;
      final value2 = -pow(2, 31);

      var msg = ByteBuffer(128);
      msg.writeInt32(value1);
      msg.writeInt32(value2);

      expect(msg.length, 8);

      var data = msg.buf.buffer.asByteData();
      expect(data.getInt32(0, Endian.little), value1);
      expect(data.getInt32(4, Endian.little), value2);
    });
  });

  test('Write bool', () {
    final value1 = true;
    final value2 = false;

    var msg = ByteBuffer(128);
    msg.writeBool(value1);
    msg.writeBool(value2);

    expect(msg.length, 2);

    var data = msg.buf.buffer.asByteData();
    expect(data.getInt8(0), 1);
    expect(data.getInt8(1), 0);
  });

  test('Write string', () {
    final value1 = 'Hello world';
    final value2 = ' ' * 1000;
    final value3 = '';

    var msg = ByteBuffer(2048);
    msg.writeString(value1);
    msg.writeString(value2);
    msg.writeString(value3);

    expect(msg.length, 1015);

    var data = msg.buf;
    expect(utf8.decode(data.sublist(1, 12)), value1);
    expect(utf8.decode(data.sublist(14, 1014)), value2);
    expect(data[1014], 0); // value3 is empty and should have a length of 0
  });

  test('Write float', () {
    final value1 = 12.34;

    var msg = ByteBuffer(128);
    msg.writeFloat32(value1);

    expect(msg.length, 4);

    var data = msg.buf.buffer.asByteData();
    expect(round(data.getFloat32(0, Endian.little), 2), value1);
  });

  test('Write packed int', () {
    final values = [0, 8, 250, 68000, 60168000, -68000, -250, -8];
    final encodedValues = [
      0,
      8,
      506,
      299936,
      483962560,
      68719209696,
      68719476358,
      68719476728
    ];
    final encodedLengths = [1, 1, 2, 3, 4, 5, 5, 5];

    for (var i = 0; i < values.length; i++) {
      var msg = ByteBuffer(8);
      msg.writePackedInt32(values[i]);
      expect(msg.length, encodedLengths[i]);

      var data = msg.buf.buffer.asByteData();
      expect(getIntFromData(data, encodedLengths[i]), encodedValues[i]);
    }
  });
}

/// Utility method for rounding floats (for comparison).
double round(double value, int decimalPlaces) {
  var precision = pow(10, decimalPlaces);
  return (value * precision).round() / precision;
}

/// Read an unsigned integer from a ByteData view.
///
/// [width] is the number of bytes that the integer is encoded in.
int getIntFromData(ByteData data, int width) {
  var output = 0;
  for (var i = 0; i < width; i++) {
    output |= data.getUint8(i) << (8 * i);
  }
  return output;
}
