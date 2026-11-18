import 'dart:typed_data';

import '../../usb_models.dart';

/// The 8-byte SETUP packet that starts every control transfer.
///
/// A host sends it ([ControlIn], [ControlOut]); a gadget receives it.
final class SetupPacket {
  const SetupPacket({
    required this.direction,
    required this.type,
    required this.recipient,
    required this.request,
    this.value = 0,
    this.index = 0,
    this.length = 0,
  });

  /// Parses the first 8 bytes of [bytes].
  factory SetupPacket.parse(List<int> bytes) {
    if (bytes.length < 8) {
      throw FormatException('a SETUP packet is 8 bytes', bytes);
    }
    int u16(int i) => bytes[i] | (bytes[i + 1] << 8);
    return SetupPacket(
      direction: Direction.fromByte(bytes[0]),
      type: RequestType.fromByte(bytes[0]),
      recipient: Recipient.fromByte(bytes[0]),
      request: bytes[1],
      value: u16(2),
      index: u16(4),
      length: u16(6),
    );
  }

  /// Direction of the data stage.
  final Direction direction;

  /// Standard, class or vendor request.
  final RequestType type;

  /// Device, interface, endpoint or other.
  final Recipient recipient;

  /// `bRequest`.
  final int request;

  /// `wValue`.
  final int value;

  /// `wIndex`: the interface or endpoint number for those recipients.
  final int index;

  /// `wLength`: number of bytes in the data stage.
  final int length;

  /// `bmRequestType`.
  int get requestType => direction.value | type.value | recipient.value;

  /// The standard request, if [type] is [RequestType.standard] and
  /// [request] is one the USB specification defines.
  StandardRequest? get standardRequest {
    if (type != RequestType.standard) return null;
    for (final r in StandardRequest.values) {
      if (r.value == request) return r;
    }
    return null;
  }

  Uint8List toBytes() =>
      (ByteData(8)
            ..setUint8(0, requestType)
            ..setUint8(1, request)
            ..setUint16(2, value, .little)
            ..setUint16(4, index, .little)
            ..setUint16(6, length, .little))
          .buffer
          .asUint8List();

  @override
  bool operator ==(Object other) =>
      other is SetupPacket &&
      other.requestType == requestType &&
      other.request == request &&
      other.value == value &&
      other.index == index &&
      other.length == length;

  @override
  int get hashCode => Object.hash(requestType, request, value, index, length);

  @override
  String toString() {
    String h(int v, int w) => '0x${v.toRadixString(16).padLeft(w, '0')}';
    return 'SetupPacket(${direction.name} ${type.name} ${recipient.name}, request: ${h(request, 2)}, '
        'value: ${h(value, 4)}, index: ${h(index, 4)}, length: $length)';
  }
}

/// A control transfer reading [length] bytes from the device.
final class ControlIn {
  const ControlIn({
    required this.type,
    required this.recipient,
    required this.request,
    this.value = 0,
    this.index = 0,
    required this.length,
  });

  final RequestType type;
  final Recipient recipient;
  final int request;
  final int value;
  final int index;

  /// Number of bytes to read.
  final int length;

  SetupPacket get setup => SetupPacket(
    direction: .in_,
    type: type,
    recipient: recipient,
    request: request,
    value: value,
    index: index,
    length: length,
  );

  @override
  String toString() => 'ControlIn($setup)';
}

/// A control transfer sending [data] to the device.
final class ControlOut {
  const ControlOut({
    required this.type,
    required this.recipient,
    required this.request,
    this.value = 0,
    this.index = 0,
    this.data = const [],
  });

  final RequestType type;
  final Recipient recipient;
  final int request;
  final int value;
  final int index;

  /// Bytes sent in the data stage.
  final List<int> data;

  SetupPacket get setup => SetupPacket(
    direction: .out,
    type: type,
    recipient: recipient,
    request: request,
    value: value,
    index: index,
    length: data.length,
  );

  @override
  String toString() => 'ControlOut($setup, ${data.length} bytes)';
}
