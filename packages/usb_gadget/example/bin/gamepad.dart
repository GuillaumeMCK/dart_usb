// A HID gamepad implemented in Dart: HidFunctionFs answers the HID class
// requests, and the gamepad only produces reports. Run as root on a board
// with a USB device controller.
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:usb_gadget/usb_gadget.dart';

/// Two sticks, twelve buttons and a hat switch, in 7 bytes.
const _reportDescriptor = [
  0x05, 0x01, // Usage Page (Generic Desktop)
  0x09, 0x04, // Usage (Joystick)
  0xA1, 0x01, // Collection (Application)
  0x09, 0x01, //   Usage (Pointer)
  0xA1, 0x00, //   Collection (Physical)
  0x09, 0x30, //     Usage (X)
  0x09, 0x31, //     Usage (Y)
  0x09, 0x32, //     Usage (Z)
  0x09, 0x35, //     Usage (Rz)
  0x15, 0x00, //     Logical Minimum (0)
  0x26, 0xFF, 0x00, //     Logical Maximum (255)
  0x75, 0x08, //     Report Size (8)
  0x95, 0x04, //     Report Count (4)
  0x81, 0x02, //     Input (Data, Variable, Absolute)
  0xC0, //   End Collection
  0x05, 0x09, //   Usage Page (Button)
  0x19, 0x01, //   Usage Minimum (1)
  0x29, 0x0C, //   Usage Maximum (12)
  0x15, 0x00, //   Logical Minimum (0)
  0x25, 0x01, //   Logical Maximum (1)
  0x75, 0x01, //   Report Size (1)
  0x95, 0x0C, //   Report Count (12)
  0x81, 0x02, //   Input (Data, Variable, Absolute)
  0x95, 0x04, //   Report Count (4)
  0x81, 0x01, //   Input (Constant): padding
  0x05, 0x01, //   Usage Page (Generic Desktop)
  0x09, 0x39, //   Usage (Hat Switch)
  0x15, 0x00, //   Logical Minimum (0)
  0x25, 0x07, //   Logical Maximum (7)
  0x35, 0x00, //   Physical Minimum (0)
  0x46, 0x3B, 0x01, //   Physical Maximum (315)
  0x65, 0x14, //   Unit (degrees)
  0x75, 0x04, //   Report Size (4)
  0x95, 0x01, //   Report Count (1)
  0x81, 0x42, //   Input (Data, Variable, Absolute, Null State)
  0x75, 0x04, //   Report Size (4)
  0x81, 0x01, //   Input (Constant): padding
  0xC0, // End Collection
];

/// A gamepad whose sticks circle and whose hat steps around.
class Gamepad() extends HidFunctionFs {
  /// The gamepad.
  this
    : super(
        name: 'Gamepad',
        config: const .inputOnly(maxPacketSize: 7),
        reportDescriptor: _reportDescriptor,
      );

  var _frame = 0;

  /// The current input report.
  Uint8List report() {
    final t = _frame++ * config.reportInterval.inMilliseconds / 1000;
    return Uint8List.fromList([
      (128 + 110 * cos(t * pi)).round(), // left X
      (128 + 110 * sin(t * pi)).round(), // left Y
      (128 + 90 * cos(t * 1.5 * pi)).round(), // right X
      (128 + 90 * sin(t * 3 * pi)).round(), // right Y
      0, 0, // buttons
      (t / 0.75).floor() % 9, // hat: 0-7 clockwise from north, 8 centered
    ]);
  }

  @override
  void onEnable() => epIn.writeWhile(
    condition: () => state == .enabled,
    data: report,
    interval: config.reportInterval,
  );

  @override
  List<int> onGetReport(HidReportType type, int reportId) => report();
}

Future<void> main() async {
  final gadget = Gadget(
    id: const Id(vendor: 0x1209, product: 0x0001), // pid.codes test ID
    strings: {
      .enUS: const GadgetStrings(
        manufacturer: 'usb_gadget',
        product: 'Gamepad',
        serialNumber: 'GP001',
      ),
    },
    configs: [
      Config(
        description: 'Gamepad',
        maxPower: const MaxPower(100),
        functions: [Gamepad()],
      ),
    ],
  );

  try {
    await gadget.bind();
    stdout.writeln('Gamepad active. Ctrl+C to exit.');
    await ProcessSignal.sigint.watch().first;
  } finally {
    await gadget.remove();
  }
}
