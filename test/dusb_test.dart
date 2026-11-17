// Read-only checks against whatever USB hardware is attached:
// `dart test` builds the Rust crate through the build hook.
import 'package:dusb/dusb.dart';
import 'package:test/test.dart';

void main() {
  late Usb usb;
  setUpAll(() async => usb = await Usb.initialize());

  test('lists buses', () async {
    expect(await usb.listBuses(), isNotEmpty);
  });

  test('lists devices and reads descriptors', () async {
    for (final info in await usb.listDevices()) {
      final device = await info.open();
      expect(device.deviceDescriptor.vendorId, info.vendorId);
      expect(device.deviceDescriptor.productId, info.productId);
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
      throwsA(isA<UsbException>().having((e) => e.kind, 'kind', UsbErrorKind.transferInvalidArgument)),
    );
  });

  test('selector matching', () async {
    for (final info in await usb.listDevices()) {
      expect(info.matches(DeviceSelector(vendorId: info.vendorId)), isTrue);
      expect(info.matches(DeviceSelector(vendorId: info.vendorId ^ 0xffff)), isFalse);
    }
  });
}
