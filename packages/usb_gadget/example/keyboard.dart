// Types "hello world" on the host as a USB keyboard, using the kernel's HID
// function. Run as root on a board with a USB device controller.
import 'dart:io';
import 'dart:typed_data';

import 'package:usb_gadget/usb_gadget.dart';

/// Boot keyboard report descriptor: a modifier byte, a reserved byte and six
/// key codes.
const _reportDescriptor = [
  0x05, 0x01, // Usage Page (Generic Desktop)
  0x09, 0x06, // Usage (Keyboard)
  0xA1, 0x01, // Collection (Application)
  0x05, 0x07, //   Usage Page (Key Codes)
  0x19, 0xE0, //   Usage Minimum (224)
  0x29, 0xE7, //   Usage Maximum (231)
  0x15, 0x00, //   Logical Minimum (0)
  0x25, 0x01, //   Logical Maximum (1)
  0x75, 0x01, //   Report Size (1)
  0x95, 0x08, //   Report Count (8)
  0x81, 0x02, //   Input (Data, Variable, Absolute): modifiers
  0x95, 0x01, //   Report Count (1)
  0x75, 0x08, //   Report Size (8)
  0x81, 0x01, //   Input (Constant): reserved
  0x95, 0x06, //   Report Count (6)
  0x75, 0x08, //   Report Size (8)
  0x15, 0x00, //   Logical Minimum (0)
  0x25, 0x65, //   Logical Maximum (101)
  0x05, 0x07, //   Usage Page (Key Codes)
  0x19, 0x00, //   Usage Minimum (0)
  0x29, 0x65, //   Usage Maximum (101)
  0x81, 0x00, //   Input (Data, Array): keys
  0xC0, // End Collection
];

/// "hello world" and Enter, as HID usage IDs.
const _helloWorld = [
  0x0B,
  0x08,
  0x0F,
  0x0F,
  0x12,
  0x2C,
  0x1A,
  0x12,
  0x15,
  0x0F,
  0x07,
  0x28,
];

Future<void> main() async {
  final keyboard = HidFunction(
    reportDescriptor: _reportDescriptor,
    reportLength: 8,
    subClass: 1,
    protocol: 1,
  );
  final gadget = Gadget(
    id: const Id(vendor: 0x1209, product: 0x0001), // pid.codes test ID
    strings: {
      .enUS: const GadgetStrings(
        manufacturer: 'usb_gadget',
        product: 'Keyboard',
        serialNumber: 'KB001',
      ),
    },
    configs: [
      Config(description: 'Keyboard', functions: [keyboard]),
    ],
  );

  final udc = await defaultUdc();
  final registered = await gadget.bind(udc);
  try {
    await udc.waitForState(.configured);
    // Some hosts miss the first reports right after configuration.
    await Future<void>.delayed(const Duration(milliseconds: 500));

    final device = await keyboard.open();
    for (final key in _helloWorld) {
      await device.writeFrom(Uint8List(8)..[2] = key); // press
      await device.writeFrom(Uint8List(8)); // release
    }
    await device.close();

    stdout.writeln('Typed "hello world". Ctrl+C to exit.');
    await ProcessSignal.sigint.watch().first;
  } finally {
    await registered.remove();
  }
}
