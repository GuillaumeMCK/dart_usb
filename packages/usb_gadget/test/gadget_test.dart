// End to end: registers gadgets on a virtual controller and talks to them
// from the host side with dusb, all on one Linux machine.
//
// Needs root, configfs and the dummy_hcd module:
//
//   sudo modprobe dummy_hcd libcomposite
//   sudo dart test test/gadget_test.dart
//
// Skipped when no `dummy_udc` controller is present.
@TestOn('linux')
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dusb/dusb.dart' as host;
import 'package:test/test.dart';
import 'package:usb_gadget/usb_gadget.dart';

const _id = Id(vendor: 0x1209, product: 0x0001); // pid.codes test ID

Future<Udc?> _dummyUdc() async {
  try {
    return (await udcs())
        .where((u) => u.name.startsWith('dummy_udc'))
        .firstOrNull;
  } on GadgetException {
    return null;
  }
}

/// Registers [functions] on [udc] and opens the device from the host side.
Future<(RegisteredGadget, host.Device)> _connect(
  Udc udc,
  List<GadgetFunction> functions,
) async {
  final usb = await host.Usb.initialize();
  final gadget = Gadget(
    id: _id,
    strings: {
      .enUS: const GadgetStrings(
        manufacturer: 'usb_gadget',
        product: 'Test',
        serialNumber: 'T1',
      ),
    },
    configs: [Config(description: 'Test', functions: functions)],
  );
  final registered = await gadget.bind(udc);
  addTearDown(registered.remove);
  await udc.waitForState(.configured, timeout: const Duration(seconds: 10));
  final selector = host.DeviceSelector(
    vendorId: _id.vendor,
    productId: _id.product,
  );
  for (var attempt = 0; attempt < 50; attempt++) {
    if (await usb.findDevice([selector]) case final info?) {
      return (registered, await info.open());
    }
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  throw StateError('the host never saw the gadget');
}

/// Runs [body], skipping the test if the kernel lacks the function driver.
Future<void> _needsDriver(Future<void> Function() body) async {
  try {
    await body();
  } on GadgetException catch (e) {
    if (e.kind == .unsupported || e.kind == .notFound) {
      markTestSkipped('function driver unavailable: $e');
      return;
    }
    rethrow;
  }
}

void main() async {
  final udc = await _dummyUdc();
  final skip = udc == null
      ? 'no dummy_udc controller (sudo modprobe dummy_hcd)'
      : false;

  group('kernel functions', skip: skip, () {
    test(
      'serial: the host reads the descriptors the gadget declared',
      () async {
        await _needsDriver(() async {
          final serial = SerialFunction();
          final (_, device) = await _connect(udc!, [serial]);
          expect(device.deviceDescriptor.id, _id);
          expect(serial.state, FunctionState.bound);
          expect(File(serial.devicePath).existsSync(), isTrue);
          final classes = device.activeConfiguration().altSettings.map(
            (a) => a.class_.type,
          );
          expect(classes, contains(ClassType.comm));
        });
      },
    );

    test('hid: report descriptor and input reports', () async {
      const reportDescriptor = [
        0x06,
        0x00,
        0xFF,
        0x09,
        0x01,
        0xA1,
        0x01,
        0x15,
        0x00,
        0x26,
        0xFF,
        0x00,
        0x75,
        0x08,
        0x95,
        0x04,
        0x09,
        0x01,
        0x81,
        0x02,
        0xC0,
      ];
      await _needsDriver(() async {
        final hid = HidFunction(
          reportDescriptor: reportDescriptor,
          reportLength: 4,
          noOutEndpoint: true,
        );
        final (_, device) = await _connect(udc!, [hid]);
        final interface = await device.detachAndClaimInterface(0);
        final read = await interface.controlIn(
          ControlIn(
            type: .standard,
            recipient: .interface,
            request: 0x06,
            value: 0x2200,
            length: reportDescriptor.length,
          ),
        );
        expect(read, reportDescriptor);

        final endpoint = interface.descriptor!.endpoints.single;
        final reports = interface.endpointIn(endpoint.address.value);
        final file = await hid.open();
        await file.writeFrom([1, 2, 3, 4]);
        expect(
          await reports.transfer(
            length: 4,
            timeout: const Duration(seconds: 2),
          ),
          [1, 2, 3, 4],
        );
        await file.close();
      });
    });

    test('net: the gadget gets a network interface', () async {
      await _needsDriver(() async {
        final net = NetFunction(.ncm, deviceAddress: [0x02, 0, 0, 0, 0, 1]);
        await _connect(udc!, [net]);
        expect(net.interfaceName, isNotEmpty);
        expect(net.deviceAddress, [0x02, 0, 0, 0, 0, 1]);
      });
    });

    test('mass storage: serves a disk image', () async {
      final dir = await Directory.systemTemp.createTemp('usb_gadget');
      addTearDown(() => dir.delete(recursive: true));
      final image = File('${dir.path}/disk.img');
      await image.writeAsBytes(Uint8List(1024 * 1024));
      await _needsDriver(() async {
        final storage = MassStorageFunction([Lun(image.path)]);
        final (_, device) = await _connect(udc!, [storage]);
        final alt = device.activeConfiguration().altSettings.single;
        expect(alt.class_.type, ClassType.massStorage);
        expect(
          alt.endpoints.map((e) => e.transferType),
          everyElement(TransferType.bulk),
        );
      });
    });
  });

  group('custom function', skip: skip, () {
    late EndpointSender tx;
    late EndpointReceiver rx;
    late CustomFunction function;
    late host.Interface interface;
    late StreamSubscription<CustomEvent> events;
    var stored = <int>[];

    setUp(() async {
      tx = EndpointSender();
      rx = EndpointReceiver();
      function = CustomFunction([
        CustomInterface(
          const Class.vendorSpecific(0, 0),
          name: 'echo',
          endpoints: [CustomEndpoint.bulk(tx), CustomEndpoint.bulk(rx)],
        ),
      ]);
      final enabled = Completer<void>();
      StreamSubscription<void>? echo;
      events = function.events.listen((event) async {
        switch (event) {
          case EnableEvent():
            echo ??= rx.stream().asyncMap(tx.sendAndFlush).listen(null);
            if (!enabled.isCompleted) enabled.complete();
          case final ControlOutRequest r when r.setup.request == 1:
            stored = await r.receive();
          case final ControlInRequest r when r.setup.request == 1:
            await r.send(stored);
          case final ControlRequest r:
            await r.halt();
          default:
        }
      });
      addTearDown(() async {
        await echo?.cancel();
        await events.cancel();
      });
      final (_, device) = await _connect(udc!, [function]);
      await enabled.future.timeout(const Duration(seconds: 5));
      interface = await device.claimInterface(0);
    });

    test('bulk data comes back', () async {
      final alt = interface.descriptor!;
      final out = interface.endpointOut(
        alt.endpoints.firstWhere((e) => e.direction == .out).address.value,
      );
      final in_ = interface.endpointIn(
        alt.endpoints.firstWhere((e) => e.direction == .in_).address.value,
      );
      for (final size in [1, 100, 4000]) {
        final payload = Uint8List.fromList([
          for (var i = 0; i < size; i++) i & 0xFF,
        ]);
        await out.transfer(data: payload);
        expect(
          await in_.transfer(
            length: 16384,
            timeout: const Duration(seconds: 2),
          ),
          payload,
        );
      }
    });

    test('vendor control requests reach Dart and are answered', () async {
      await interface.controlOut(
        const ControlOut(
          type: .vendor,
          recipient: .interface,
          request: 1,
          data: [9, 8, 7],
        ),
      );
      final read = await interface.controlIn(
        const ControlIn(
          type: .vendor,
          recipient: .interface,
          request: 1,
          length: 64,
        ),
      );
      expect(read, [9, 8, 7]);
    });

    test('halted requests stall', () async {
      await expectLater(
        interface.controlIn(
          const ControlIn(
            type: .vendor,
            recipient: .interface,
            request: 2,
            length: 8,
          ),
        ),
        throwsA(
          isA<host.UsbException>().having(
            (e) => e.kind,
            'kind',
            host.UsbErrorKind.transferStall,
          ),
        ),
      );
    });
  });
}
