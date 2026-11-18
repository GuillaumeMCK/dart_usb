// Read-only checks against whatever USB hardware is attached:
// `dart test` builds the Rust crate through the build hook.
import 'package:test/test.dart';
import 'package:usb_host/usb_host.dart';

void main() {
  late Usb usb;
  setUpAll(() async => usb = await Usb.initialize());

  test('lists buses', () async {
    expect(await usb.listBuses(), isNotEmpty);
  });

  test('lists devices and reads descriptors', () async {
    for (final info in await usb.listDevices()) {
      final device = await info.open();
      expect(
        device.deviceDescriptor.id,
        Id(vendor: info.vendorId, product: info.productId),
      );
      expect(device.configurations, isNotEmpty);
    }
  });

  test('hotplug stream starts and cancels', () async {
    final sub = usb.watchDevices().listen((_) {});
    await Future<void>.delayed(const Duration(milliseconds: 300));
    await sub.cancel();
  });

  test('errors carry a kind', () async {
    final devices = await usb.listDevices();
    if (devices.isEmpty) return;
    final device = await devices.first.open();
    await expectLater(
      device.getStringDescriptor(index: 0),
      throwsA(
        isA<UsbException>().having(
          (e) => e.kind,
          'kind',
          UsbErrorKind.transferInvalidArgument,
        ),
      ),
    );
  });

  test('selector matching', () async {
    for (final info in await usb.listDevices()) {
      expect(info.matches(DeviceSelector(vendorId: info.vendorId)), isTrue);
      expect(
        info.matches(DeviceSelector(vendorId: info.vendorId ^ 0xffff)),
        isFalse,
      );
    }
  });

  test('descriptors parse into usb_models types', () async {
    for (final info in await usb.listDevices()) {
      final device = await info.open();
      expect(device.speed, info.speed);
      expect(device.deviceDescriptor.class_, info.class_);
      expect(
        device.deviceDescriptor.numConfigurations,
        device.configurations.length,
      );
      final active = device.activeConfiguration();
      expect(
        device.configurations.map((c) => c.configurationValue),
        contains(active.configurationValue),
      );
      for (final alt in active.altSettings) {
        for (final endpoint in alt.endpoints) {
          expect(endpoint.address.number.value, inInclusiveRange(1, 15));
        }
      }
    }
  });

  test('control requests from usb_models', () async {
    final devices = await usb.listDevices();
    if (devices.isEmpty) return;
    final device = await devices.first.open();
    // GET_DESCRIPTOR(device): a read-only standard request.
    final bytes = await device.controlIn(
      const ControlIn(
        type: .standard,
        recipient: .device,
        request: 0x06,
        value: 0x0100,
        length: 18,
      ),
    );
    expect(DeviceDescriptor.parse(bytes).id, device.deviceDescriptor.id);
  });
}
