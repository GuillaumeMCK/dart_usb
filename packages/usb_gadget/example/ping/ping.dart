// The host side of ping/pong, with usb_host: finds the pong gadget, sends
// payloads and checks they come back. Runs on macOS, Linux or Windows.
import 'dart:io';
import 'dart:typed_data';

import 'package:usb_host/usb_host.dart';

Future<void> main() async {
  final usb = await Usb.initialize();
  final info = await usb.findDevice([
    const DeviceSelector(vendorId: 0x1209, productId: 0x0001),
  ]);
  if (info == null) {
    stderr.writeln('No pong gadget connected.');
    exit(1);
  }
  final device = await info.open();
  final interface = await device.claimInterface(0);
  final alt = interface.descriptor!;
  final inAddress = alt.endpoints
      .firstWhere((e) => e.direction == .in_)
      .address
      .value;
  final outAddress = alt.endpoints
      .firstWhere((e) => e.direction == .out)
      .address
      .value;
  final out = interface.endpointOut(outAddress);
  final in_ = interface.endpointIn(inAddress);

  // The gadget echoes each transfer it receives into a 16 KiB buffer, so a
  // payload must fill it or end with a short packet: sizes that are a
  // multiple of the max packet size, but below 16 KiB, would wait for more.
  for (final size in [1, 63, 511, 4000, 16384]) {
    final payload = Uint8List.fromList([
      for (var i = 0; i < size; i++) i & 0xFF,
    ]);
    final watch = Stopwatch()..start();
    await out.transfer(data: payload);
    final echo = await in_.transfer(length: 16384);
    stdout.writeln(
      '$size bytes: ${_equal(echo, payload) ? 'ok' : 'MISMATCH'} in ${watch.elapsedMicroseconds} µs',
    );
  }
}

bool _equal(List<int> a, List<int> b) =>
    a.length == b.length &&
    Iterable.generate(a.length).every((i) => a[i] == b[i]);
