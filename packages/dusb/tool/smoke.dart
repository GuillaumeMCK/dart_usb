// Prints what dusb finds on this machine, using read-only requests.
// Run with `dart run tool/smoke.dart`; the build hook compiles the Rust crate.
import 'package:dusb/dusb.dart';

Future<void> main() async {
  final usb = await Usb.initialize();

  for (final bus in await usb.listBuses()) {
    print(bus);
  }

  for (final info in await usb.listDevices()) {
    print(info);
    print('  ${info.interfaces}');

    final device = await info.open();
    print('  ${device.deviceDescriptor}, ${device.speed?.name}');
    try {
      print('  active configuration ${device.activeConfiguration().configurationValue}');
    } on UsbException catch (e) {
      print('  $e');
    }

    final languages = await device.getStringDescriptorSupportedLanguages();
    print('  languages: ${languages.map((l) => '0x${l.toRadixString(16)}').join(', ')}');
    final product = device.deviceDescriptor.product;
    if (product.hasString) {
      print('  product string: ${await device.getStringDescriptor(index: product.value)}');
    }

    // Errors print their kind, message and OS code.
    try {
      await device.claimInterface(0);
    } on UsbException catch (e) {
      print('  claiming interface 0: $e');
    }
    device.dispose();
  }

  final events = usb.watchDevices().listen((event) => print(event));
  await Future<void>.delayed(const Duration(milliseconds: 300));
  await events.cancel();
}
