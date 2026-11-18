// Loads the native library through the build hook. Needs Linux, but no
// USB hardware or root.
@TestOn('linux')
library;

import 'package:test/test.dart';
import 'package:usb_gadget/usb_gadget.dart';

void main() {
  test('the native library loads and lists controllers', () async {
    try {
      final controllers = await udcs();
      for (final udc in controllers) {
        expect(udc.name, isNotEmpty);
      }
    } on GadgetException catch (e) {
      // No /sys/class/udc (a container, or no controller driver) is fine:
      // the call still went through the bridge.
      expect(e.kind, isIn([GadgetErrorKind.notFound, GadgetErrorKind.other]));
    }
  });

  test('bridge errors arrive as GadgetException', () async {
    final gadget = Gadget(id: const Id(vendor: 0x1209, product: 0x0001));
    // No configuration: the crate rejects it, or configfs is missing.
    await expectLater(gadget.register(), throwsA(isA<GadgetException>()));
  });
}
