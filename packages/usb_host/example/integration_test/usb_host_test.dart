// Read-only checks against whatever USB hardware is attached: nothing here
// claims an interface, changes a configuration or transfers data.
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:usb_host/usb_host.dart';
import 'package:usb_host_example/main.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  late Usb usb;
  setUpAll(() async => usb = await Usb.initialize());

  test('lists buses', () async {
    expect(await usb.listBuses(), isNotEmpty);
  });

  test('lists devices and reads descriptors', () async {
    for (final info in await usb.listDevices()) {
      final device = await info.open();
      try {
        expect(
          device.deviceDescriptor.id,
          Id(vendor: info.vendorId, product: info.productId),
        );
        expect(device.configurations, isNotEmpty);
      } finally {
        device.dispose();
      }
    }
  });

  test('hotplug stream starts and cancels', () async {
    final sub = usb.watchDevices().listen((_) {});
    await Future<void>.delayed(const Duration(milliseconds: 300));
    await sub.cancel();
  });

  test('includeConnected reports the connected devices first', () async {
    final expected = {for (final d in await usb.listDevices()) d.id};
    final reported = await usb
        .watchDevices(includeConnected: true)
        .take(expected.length)
        .map((e) => (e as HotplugConnected).device.id)
        .toSet();
    expect(reported, expected);
  });

  test('errors carry a kind', () async {
    final devices = await usb.listDevices();
    if (devices.isEmpty) return;
    final device = await devices.first.open();
    try {
      // Index 0 is the language table, not a string: usb_host rejects it
      // before any transfer reaches the device.
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
    } finally {
      device.dispose();
    }
  });

  testWidgets('the app lists the connected devices', (tester) async {
    final count = (await tester.runAsync(usb.listDevices))!.length;
    await tester.pumpWidget(const UsbHostExampleApp());
    expect(find.text('USB devices'), findsOneWidget);
    for (var i = 0; i < 50; i++) {
      if (find.byType(ListTile).evaluate().length >= count) break;
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await tester.pump();
    }
    expect(find.byType(ListTile), findsNWidgets(count));
  });
}
