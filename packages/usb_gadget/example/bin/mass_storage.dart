// Exposes disk images as a USB drive. Run as root on a board with a USB
// device controller:
//
//   dart build cli -t bin/mass_storage.dart -o build/mass_storage
//   sudo build/mass_storage/bundle/bin/mass_storage [--udc NAME] IMAGE...
import 'dart:io';

import 'package:usb_gadget/usb_gadget.dart';

Future<void> main(List<String> args) async {
  final (udcName, images) = switch (args) {
    ['--udc', final name, ...final images] => (name, images),
    _ => (null, args),
  };
  if (images.isEmpty || images.any((i) => i.startsWith('-'))) {
    stderr.writeln(
      'Usage: mass_storage [--udc NAME] IMAGE [IMAGE ...]',
    );
    exit(64);
  }

  final storage = MassStorageFunction([
    for (final image in images) Lun(image, removable: true),
  ]);
  final gadget = Gadget(
    id: const Id(vendor: 0x1209, product: 0x0001), // pid.codes test ID
    strings: {
      .enUS: const GadgetStrings(
        manufacturer: 'usb_gadget',
        product: 'Mass Storage',
        serialNumber: '000000000001',
      ),
    },
    configs: [
      Config(description: 'Mass Storage', functions: [storage]),
    ],
  );

  final udc = switch (udcName) {
    final name? => (await udcs()).firstWhere((u) => u.name == name),
    null => await defaultUdc(),
  };
  try {
    await gadget.bind(udc);
    stdout.writeln(
      'Serving ${images.join(', ')} on ${udc.name}. Ctrl+C to exit.',
    );
    await ProcessSignal.sigint.watch().first;
  } finally {
    await gadget.remove();
  }
}
