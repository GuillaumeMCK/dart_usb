// A HID gamepad implemented in Dart with a custom (FunctionFS) function: the
// HID class requests are answered here instead of by the kernel's HID
// driver. Run as root on a board with a USB device controller.
import 'dart:async';
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

/// The gamepad's state, sent as input reports.
final class GamepadReport {
  int leftX = 128, leftY = 128, rightX = 128, rightY = 128;
  int buttons = 0; // 12 bits
  int hat = 8; // 0-7 clockwise from north, 8 centered

  Uint8List toBytes() => Uint8List.fromList([
    leftX,
    leftY,
    rightX,
    rightY,
    buttons & 0xFF,
    buttons >> 8 & 0x0F,
    hat & 0x0F,
  ]);
}

/// A gamepad that moves its sticks in circles and steps its hat around.
final class Gamepad {
  Gamepad() {
    function = CustomFunction([
      CustomInterface(
        const Class(.hid, 0, 0),
        name: 'Gamepad',
        endpoints: [
          CustomEndpoint.interrupt(_reports, interval: 4, maxPacketSize: 8),
        ],
        descriptors: [
          CustomDescriptor(
            HidDescriptorType.hid.value,
            HidDescriptor(reportLength: _reportDescriptor.length)
                .toBytes()
                .sublist(2),
          ),
        ],
      ),
    ]);
  }

  late final CustomFunction function;
  final _reports = EndpointSender();
  final report = GamepadReport();
  var _idle = 0;
  var _protocol = 1;
  Timer? _timer;

  /// Answers the host until the gadget is removed.
  Future<void> run() async {
    await for (final event in function.events) {
      switch (event) {
        case EnableEvent():
          _start();
        case DisableEvent() || UnbindEvent():
          _timer?.cancel();
        case final ControlRequest request:
          await _answer(request);
        default:
      }
    }
  }

  Future<void> _answer(ControlRequest request) async {
    final setup = request.setup;
    switch ((request, setup.type, setup.request)) {
      // The host reads the report descriptor through the interface.
      case (final ControlInRequest r, .standard, 0x06)
          when setup.value >> 8 == HidDescriptorType.report.value:
        await r.send(_reportDescriptor.take(setup.length).toList());
      case (final ControlInRequest r, .class_, 0x01): // GET_REPORT
        await r.send(report.toBytes());
      case (final ControlInRequest r, .class_, 0x02): // GET_IDLE
        await r.send([_idle]);
      case (final ControlInRequest r, .class_, 0x03): // GET_PROTOCOL
        await r.send([_protocol]);
      case (final ControlOutRequest r, .class_, 0x0A): // SET_IDLE
        _idle = setup.value >> 8;
        await r.receive();
      case (final ControlOutRequest r, .class_, 0x0B): // SET_PROTOCOL
        _protocol = setup.value & 0xFF;
        await r.receive();
      default:
        await request.halt();
    }
  }

  void _start() {
    var frame = 0;
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(milliseconds: 10), (_) async {
      final t = frame++ / 100;
      report
        ..leftX = (128 + 110 * cos(t * pi)).round()
        ..leftY = (128 + 110 * sin(t * pi)).round()
        ..rightX = (128 + 90 * cos(t * 1.5 * pi)).round()
        ..rightY = (128 + 90 * sin(t * 3 * pi)).round()
        ..hat = (t / 0.75).floor() % 9;
      try {
        await _reports.send(
          report.toBytes(),
          timeout: const Duration(milliseconds: 100),
        );
      } on GadgetException {
        // The host isn't polling yet, or stopped; keep animating.
      }
    });
  }
}

Future<void> main() async {
  final gamepad = Gamepad();
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
        functions: [gamepad.function],
      ),
    ],
  );

  final registered = await gadget.bind(await defaultUdc());
  unawaited(gamepad.run());
  stdout.writeln('Gamepad active. Ctrl+C to exit.');
  await ProcessSignal.sigint.watch().first;
  await registered.remove();
}
