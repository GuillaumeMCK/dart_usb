// The device side of ping/pong: a custom function with two bulk endpoints
// that echoes everything the host sends. Run as root on a board with a USB
// device controller, then run ping.dart on the host.
import 'dart:async';
import 'dart:io';

import 'package:usb_gadget/usb_gadget.dart';

Future<void> main() async {
  final tx = InEndpoint(), rx = OutEndpoint();
  final function = CustomFunction([
    CustomInterface(
      const Class.vendorSpecific(0, 0),
      name: 'pong',
      endpoints: [CustomEndpoint.bulk(tx), CustomEndpoint.bulk(rx)],
    ),
  ]);
  final gadget = Gadget(
    id: const Id(vendor: 0x1209, product: 0x0001), // pid.codes test ID
    strings: {
      .enUS: const GadgetStrings(manufacturer: 'usb_gadget', product: 'Pong'),
    },
    configs: [
      Config(description: 'Pong', functions: [function]),
    ],
  );

  final registered = await gadget.bind(await defaultUdc());
  StreamSubscription<void>? echo;
  final events = function.events.listen((event) async {
    switch (event) {
      case EnableEvent():
        echo ??= rx
            .stream()
            .asyncMap(tx.writeAndFlush)
            .listen(null, onError: (Object e) => stderr.writeln(e));
      case DisableEvent():
        await echo?.cancel();
        echo = null;
      case final ControlRequest request:
        await request.halt();
      default:
    }
  });

  stdout.writeln('Pong ready. Ctrl+C to exit.');
  await ProcessSignal.sigint.watch().first;
  await echo?.cancel();
  await events.cancel();
  await registered.remove();
}
