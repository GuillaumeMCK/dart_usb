// The device side of ping/pong: a custom function with two bulk endpoints
// that echoes everything the host sends. Run as root on a board with a USB
// device controller, then run ping.dart on the host.
import 'dart:io';

import 'package:usb_gadget/usb_gadget.dart';

/// Echoes OUT data back on IN.
class PongFunction() extends CustomFunction {
  /// The function.
  this
    : super(
        interfaces: const [
          CustomInterface(
            class_: .vendorSpecific(0, 0),
            name: 'Pong',
            endpoints: [
              EndpointTemplate(address: .in_(.ep1), config: .bulk()),
              EndpointTemplate(address: .out(.ep2), config: .bulk()),
            ],
          ),
        ],
      );

  /// Where echoes go.
  late final epIn = endpointIn(.ep1);

  /// Where pings arrive.
  late final epOut = endpointOut(.ep2);

  // The stream ends by itself when the host disables the function.
  @override
  void onEnable() => epOut.stream().listen(epIn.write);
}

Future<void> main() async {
  final gadget = Gadget(
    id: const Id(vendor: 0x1209, product: 0x0001), // pid.codes test ID
    strings: {
      .enUS: const GadgetStrings(manufacturer: 'usb_gadget', product: 'Pong'),
    },
    configs: [
      Config(description: 'Pong', functions: [PongFunction()]),
    ],
  );

  try {
    await gadget.bind();
    stdout.writeln('Pong ready. Ctrl+C to exit.');
    await ProcessSignal.sigint.watch().first;
  } finally {
    await gadget.remove();
  }
}
