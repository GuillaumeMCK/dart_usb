// Pure Dart: runs anywhere, without the native library.
import 'package:test/test.dart';
import 'package:usb_gadget/usb_gadget.dart';

void main() {
  test('frame rates become 100 ns intervals', () {
    final frame = VideoFrame.fps(640, 480, .mjpeg, [30, 60]);
    expect(frame.intervals, [333333, 166666]);
  });

  test('config descriptions default to US English', () {
    final config = Config(
      description: 'Main',
      descriptions: {.frFR: 'Principale'},
    );
    expect(config.descriptions, {
      LanguageId.enUS: 'Main',
      LanguageId.frFR: 'Principale',
    });
  });

  test('device interface GUIDs are braced', () {
    const property = OsExtProperty.deviceInterfaceGuid(
      '12345678-1234-1234-1234-123456789abc',
    );
    expect(property.name, 'DeviceInterfaceGUID');
    expect(property.text, '{12345678-1234-1234-1234-123456789abc}');
  });

  test('endpoints take their direction from their io', () {
    final tx = InEndpoint(queueLength: 4);
    final endpoint = CustomEndpoint.interrupt(
      tx,
      interval: 4,
      maxPacketSize: 8,
    );
    expect(endpoint.io, same(tx));
    expect(endpoint.transferType, TransferType.interrupt);
    expect(endpoint.maxPacketSizeHighSpeed, 8);
  });

  test('functions report unregistered before registration', () {
    expect(SerialFunction().state, FunctionState.unregistered);
    expect(CustomFunction([]).path, isNull);
    expect(() => SerialFunction().devicePath, throwsStateError);
    expect(() => OutEndpoint().read(), throwsStateError);
  });

  test('endpoints need a queue', () {
    expect(() => InEndpoint(queueLength: 0), throwsArgumentError);
    expect(OutEndpoint(queueLength: 1).queueLength, 1);
  });
}
