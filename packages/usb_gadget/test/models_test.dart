// Pure Dart: runs anywhere, without the native library.
import 'package:test/test.dart';
import 'package:usb_gadget/usb_gadget.dart';

void main() {
  test('frame rates become 100 ns intervals', () {
    final frame = VideoFrame.fps(640, 480, .mjpeg, [30, 60]);
    expect(frame.intervals, [333_333, 166_666]);
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

  test('endpoints are declared with templates and looked up by number', () {
    final function = CustomFunction(
      queueLength: 4,
      interfaces: const [
        CustomInterface(
          class_: .vendorSpecific(0, 0),
          endpoints: [
            EndpointTemplate(
              address: .in_(.ep1),
              config: .interrupt(interval: Duration(milliseconds: 4)),
            ),
            EndpointTemplate(address: .out(.ep1), config: .bulk()),
          ],
        ),
      ],
    );
    expect(
      function.endpointIn(.ep1).template.config.transferType,
      TransferType.interrupt,
    );
    expect(function.endpointOut(.ep1).queueLength, 4);
    expect(() => function.endpointIn(.ep2), throwsArgumentError);
  });

  test('duplicate endpoints and empty queues are rejected', () {
    const ep = EndpointTemplate(address: .in_(.ep1), config: .bulk());
    expect(
      () => CustomFunction(
        interfaces: const [
          CustomInterface(class_: .vendorSpecific(0, 0), endpoints: [ep, ep]),
        ],
      ),
      throwsArgumentError,
    );
    expect(
      () => CustomFunction(interfaces: const [], queueLength: 0),
      throwsArgumentError,
    );
  });

  test('functions report unregistered before registration', () {
    expect(SerialFunction().state, FunctionState.unregistered);
    final function = CustomFunction(
      interfaces: const [
        CustomInterface(
          class_: .vendorSpecific(0, 0),
          endpoints: [EndpointTemplate(address: .out(.ep1), config: .bulk())],
        ),
      ],
    );
    expect(function.state, CustomFunctionState.unregistered);
    expect(function.path, isNull);
    expect(() => SerialFunction().devicePath, throwsStateError);
    expect(() => function.endpointOut(.ep1).read(), throwsStateError);
  });

  test('HidFunctionFs declares its endpoints and HID descriptor', () {
    final hid = HidFunctionFs(
      config: const .bidirectional(),
      reportDescriptor: const [0x05, 0x01, 0xC0],
    );
    expect(hid.interfaces.single.class_.type, ClassType.hid);
    expect(hid.interfaces.single.endpoints, hasLength(2));
    expect(hid.interfaces.single.descriptors.single, isA<HidDescriptor>());
    expect(hid.epIn.number, EndpointNumber.ep1);
    expect(hid.bootProtocol, isFalse);
  });

  test('HidFunctionFs keeps the interface protocol apart', () {
    final mouse = HidFunctionFs(
      config: const .inputOnly(),
      reportDescriptor: const [0x05, 0x01, 0xC0],
      subClass: 1,
      interfaceProtocol: 2,
    );
    expect(mouse.interfaces.single.class_.protocol, 2);
    expect(mouse.bootProtocol, isFalse);
    expect(mouse.hidDescriptor.reportLength, 3);
  });
}
