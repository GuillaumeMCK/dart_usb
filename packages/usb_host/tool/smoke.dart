// Prints what usb_host finds on this machine, using read-only requests.
// Run with `dart run tool/smoke.dart`; the build hook compiles the Rust crate.
import 'dart:io';

import 'package:usb_host/usb_host.dart';

Future<void> main() async {
  final usb = await Usb.initialize();

  (await usb.listBuses()).forEach(stdout.writeln);

  for (final info in await usb.listDevices()) {
    stdout
      ..writeln(info)
      ..writeln('  ${info.interfaces}');

    final device = await info.open();
    stdout.writeln('  ${device.deviceDescriptor}, ${device.speed?.name}');
    try {
      stdout.writeln(
        '  active configuration ${device.activeConfiguration().configurationValue}',
      );
    } on UsbException catch (e) {
      stdout.writeln('  $e');
    }

    final languages = await device.getStringDescriptorSupportedLanguages();
    stdout.writeln(
      '  languages: ${languages.map((l) => '0x${l.toRadixString(16)}').join(', ')}',
    );
    final product = device.deviceDescriptor.product;
    if (product.hasString) {
      stdout.writeln(
        '  product string: ${await device.getStringDescriptor(index: product.value)}',
      );
    }

    // Errors print their kind, message and OS code.
    try {
      await device.claimInterface(0);
    } on UsbException catch (e) {
      stdout.writeln('  claiming interface 0: $e');
    }
    device.dispose();
  }

  final events = usb.watchDevices().listen(stdout.writeln);
  await Future<void>.delayed(const Duration(milliseconds: 300));
  await events.cancel();
}
