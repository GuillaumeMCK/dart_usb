// End to end: registers gadgets on a virtual controller and talks to them
// from the host side with usb_host, all on one Linux machine.
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

import 'package:usb_host/usb_host.dart' as host;
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
    late InEndpoint tx;
    late OutEndpoint rx;
    late CustomFunction function;
    late _Echo echo;
    late host.Interface interface;

    setUp(() async {
      tx = InEndpoint();
      rx = OutEndpoint();
      function = _echoFunction(tx, rx);
      echo = _Echo(function, tx, rx); // listens before registration
      addTearDown(echo.stop);
      final (_, device) = await _connect(udc!, [function]);
      await echo.enabled.timeout(const Duration(seconds: 5));
      interface = await device.claimInterface(0);
    });

    test('bulk data comes back', () async {
      for (final size in [1, 100, 4000]) {
        final payload = Uint8List.fromList([
          for (var i = 0; i < size; i++) i & 0xFF,
        ]);
        expect(await _roundTrip(interface, payload), payload);
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

    test('a late answer fails promptly instead of hanging', () async {
      await expectLater(
        interface.controlIn(
          const ControlIn(
            type: .vendor,
            recipient: .interface,
            request: 3,
            length: 8,
          ),
          timeout: const Duration(seconds: 8),
        ),
        throwsA(
          isA<host.UsbException>().having(
            (e) => e.kind,
            'kind',
            host.UsbErrorKind.transferStall,
          ),
        ),
      );
      final error = await echo.lateAnswer.future.timeout(
        const Duration(seconds: 5),
      );
      expect(
        error,
        isA<GadgetException>().having(
          (e) => e.kind,
          'kind',
          GadgetErrorKind.timedOut,
        ),
      );
    }, timeout: const Timeout(Duration(seconds: 30)));

    test('handlers can look up interface numbers without blocking', () async {
      final watch = Stopwatch()..start();
      final read = await interface.controlIn(
        const ControlIn(
          type: .vendor,
          recipient: .interface,
          request: 4,
          length: 1,
        ),
      );
      expect(read, [0]);
      expect(watch.elapsed, lessThan(const Duration(seconds: 1)));
    });

    test('answers are truncated to the length the host asked for', () async {
      final read = await interface.controlIn(
        const ControlIn(
          type: .vendor,
          recipient: .interface,
          request: 5,
          length: 4,
        ),
      );
      expect(read, [0, 1, 2, 3]);
    });

    test('a request can only be answered once', () async {
      await interface.controlIn(
        const ControlIn(
          type: .vendor,
          recipient: .interface,
          request: 6,
          length: 1,
        ),
      );
      expect(
        await echo.secondAnswer.future.timeout(const Duration(seconds: 2)),
        isA<StateError>(),
      );
    });

    test('endpoint queries answer while a stream waits for data', () async {
      expect(
        await rx.maxPacketSize.timeout(const Duration(seconds: 1)),
        greaterThan(0),
      );
      expect(
        await rx.address.timeout(const Duration(seconds: 1)),
        greaterThan(0),
      );
    });

    test('one consumer at a time', () async {
      expect(() => rx.read(), throwsStateError);
      await expectLater(function.events.first, throwsStateError);
    });
  });

  group('custom function lifecycle', skip: skip, () {
    test('a paused stream holds the host off', () async {
      final rx = OutEndpoint(queueLength: 2);
      final function = CustomFunction([
        CustomInterface(
          const Class.vendorSpecific(0, 0),
          endpoints: [CustomEndpoint.bulk(rx)],
        ),
      ]);
      final enabled = function.events.firstWhere((e) => e is EnableEvent);
      final (_, device) = await _connect(udc!, [function]);
      await enabled.timeout(const Duration(seconds: 5));
      final interface = await device.claimInterface(0);
      final out = interface.endpointOut(
        interface.descriptor!.endpoints.single.address.value,
      );

      final received = <List<int>>[];
      final subscription = rx.stream(chunkSize: 512).listen(received.add)
        ..pause();
      addTearDown(subscription.cancel);
      // Paused before reading anything: no buffer is queued, so the host's
      // transfer is NAKed until it times out.
      await expectLater(
        out.transfer(
          data: [1, 2, 3],
          timeout: const Duration(milliseconds: 500),
        ),
        throwsA(isA<host.UsbException>()),
      );
      subscription.resume();
      await out.transfer(data: [4, 5, 6], timeout: const Duration(seconds: 2));
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(received, [
        [4, 5, 6],
      ]);
    });

    test('a function can be registered again after removal', () async {
      final tx = InEndpoint(), rx = OutEndpoint();
      final function = _echoFunction(tx, rx);
      for (var round = 0; round < 2; round++) {
        final echo = _Echo(function, tx, rx);
        final (registered, device) = await _connect(udc!, [function]);
        await echo.enabled.timeout(const Duration(seconds: 5));
        final interface = await device.claimInterface(0);
        expect(await _roundTrip(interface, [round, 1, 2]), [round, 1, 2]);
        await echo.stop();
        await registered.remove();
        expect(function.state, FunctionState.removed);
        await Future<void>.delayed(
          const Duration(milliseconds: 500),
        ); // let the host see it go
      }
    }, timeout: const Timeout(Duration(seconds: 40)));
  });
}

CustomFunction _echoFunction(InEndpoint tx, OutEndpoint rx) => CustomFunction([
  CustomInterface(
    const Class.vendorSpecific(0, 0),
    name: 'echo',
    endpoints: [CustomEndpoint.bulk(tx), CustomEndpoint.bulk(rx)],
  ),
]);

/// Sends [payload] out and reads the echo back.
Future<List<int>> _roundTrip(
  host.Interface interface,
  List<int> payload,
) async {
  final alt = interface.descriptor!;
  final out = interface.endpointOut(
    alt.endpoints.firstWhere((e) => e.direction == .out).address.value,
  );
  final in_ = interface.endpointIn(
    alt.endpoints.firstWhere((e) => e.direction == .in_).address.value,
  );
  await out.transfer(data: payload);
  return in_.transfer(length: 16384, timeout: const Duration(seconds: 2));
}

/// The test gadget's behaviour: echoes bulk data, and answers vendor
/// requests by number (1 store/load, 2 stall, 3 answer too late, 4 own
/// interface number, 5 oversized answer, 6 answer twice).
final class _Echo {
  _Echo(this.function, this.tx, this.rx) {
    _events = function.events.listen(_onEvent);
  }

  final CustomFunction function;
  final InEndpoint tx;
  final OutEndpoint rx;
  late final StreamSubscription<CustomEvent> _events;
  StreamSubscription<void>? _echo;
  final _enabled = Completer<void>();
  final lateAnswer = Completer<Object>();
  final secondAnswer = Completer<Object>();
  var _stored = <int>[];

  Future<void> get enabled => _enabled.future;

  Future<void> _onEvent(CustomEvent event) async {
    switch (event) {
      case EnableEvent():
        _echo ??= rx.stream().asyncMap(tx.writeAndFlush).listen(null);
        if (!_enabled.isCompleted) _enabled.complete();
      case DisableEvent():
        await _echo?.cancel();
        _echo = null;
      case final ControlOutRequest r when r.setup.request == 1:
        _stored = await r.receive();
      case final ControlInRequest r when r.setup.request == 1:
        await r.send(_stored);
      case final ControlInRequest r when r.setup.request == 3:
        await Future<void>.delayed(const Duration(seconds: 5));
        try {
          await r.send([1]);
        } on Object catch (e) {
          lateAnswer.complete(e);
        }
      case final ControlInRequest r when r.setup.request == 4:
        await r.send([function.interfaceNumber(0)]);
      case final ControlInRequest r when r.setup.request == 5:
        await r.send(List.generate(10, (i) => i));
      case final ControlInRequest r when r.setup.request == 6:
        await r.send([1]);
        try {
          await r.send([2]);
        } on Object catch (e) {
          secondAnswer.complete(e);
        }
      case final ControlRequest r:
        await r.halt();
      default:
    }
  }

  Future<void> stop() async {
    await _echo?.cancel();
    await _events.cancel();
  }
}
