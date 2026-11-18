// Descriptor parsing tests; the device data is from nusb's test suite.
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:usb_models/usb_models.dart';

void main() {
  group('ConfigurationDescriptor.parseAll', () {
    List<List<int>> parse(List<int> bytes) =>
        ConfigurationDescriptor.parseAll(bytes)
            .map((c) => c.bytes.toList())
            .toList();

    test('empty', () => expect(parse([]), isEmpty));
    test('short', () => expect(parse([0]), isEmpty));
    test(
      'invalid total length',
      () => expect(parse([9, 2, 0, 0, 0, 0, 0, 0, 0]), isEmpty),
    );
    test('one config', () {
      expect(parse([9, 2, 9, 0, 0, 0, 0, 0, 0]), [
        [9, 2, 9, 0, 0, 0, 0, 0, 0],
      ]);
    });
    test('two configs', () {
      expect(
        parse([
          9,
          2,
          13,
          0,
          0,
          0,
          0,
          0,
          0,
          4,
          0,
          0,
          0,
          9,
          2,
          9,
          0,
          0,
          0,
          0,
          0,
          0,
        ]),
        [
          [9, 2, 13, 0, 0, 0, 0, 0, 0, 4, 0, 0, 0],
          [9, 2, 9, 0, 0, 0, 0, 0, 0],
        ],
      );
    });
  });

  test('empty config', () {
    final c = ConfigurationDescriptor.parse([9, 2, 9, 0, 0, 1, 0, 0, 250]);
    expect(c.numInterfaces, 0);
    expect(c.configurationValue, 1);
    expect(c.stringIndex.hasString, isFalse);
    expect(c.interfaces, isEmpty);
  });

  test('stops at a malformed descriptor', () {
    final c = ConfigurationDescriptor.parse([
      9,
      2,
      14,
      0,
      0,
      1,
      0,
      0,
      2,
      5,
      250,
      0,
      0,
      0,
    ]);
    expect(c.interfaces, isEmpty);
  });

  test('extra descriptors', () {
    final c = ConfigurationDescriptor.parse([
      0x09, 0x02, 0x2a, 0x00, 0x01, 0x01, 0x00, 0x80, 0xfa, // config
      0x09, 0x04, 0x00, 0x00, 0x02, 0xff, 0x00, 0x00, 0x04, // interface
      0x02, 0x30, // empty vendor descriptor
      0x03, 0x30, 0xaa, // vendor descriptor
      0x07, 0x05, 0x82, 0x02, 0x40, 0x00, 0x00, // endpoint
      0x02, 0x31, // empty vendor descriptor
      0x07, 0x05, 0x83, 0x02, 0x40, 0x00, 0x00, // endpoint
      0x03, 0x31, 0x55, // vendor descriptor
    ]);
    final alt = c.altSettings.single;
    expect(alt.interfaceNumber.value, 0);
    expect(alt.descriptors.take(2).map((d) => d.toBytes().toList()), [
      [0x02, 0x30],
      [0x03, 0x30, 0xaa],
    ]);
    expect(alt.endpoints.map((e) => e.address.value), [0x82, 0x83]);
    expect(alt.descriptors, hasLength(6));
  });

  test('linux root hub', () {
    final dev = DeviceDescriptor.parse([
      0x12, 0x01, 0x00, 0x02, 0x09, 0x00, 0x01, 0x40, 0x6b, //
      0x1d, 0x02, 0x00, 0x10, 0x05, 0x03, 0x02, 0x01, 0x01,
    ]);
    expect(dev.usbVersion, 0x0200);
    expect(dev.class_, const Class(.hub, 0x00, 0x01));
    expect(dev.maxPacketSize0, 64);
    expect(dev.id, const Id(vendor: 0x1d6b, product: 0x0002));
    expect(dev.deviceVersion, 0x0510);
    expect(dev.manufacturer.value, 3);
    expect(dev.product.value, 2);
    expect(dev.serialNumber.value, 1);
    expect(dev.numConfigurations, 1);

    final c = ConfigurationDescriptor.parse([
      0x09, 0x02, 0x19, 0x00, 0x01, 0x01, 0x00, 0xe0, 0x00, //
      0x09, 0x04, 0x00, 0x00, 0x01, 0x09, 0x00, 0x00, 0x00, //
      0x07, 0x05, 0x81, 0x03, 0x04, 0x00, 0x0c,
    ]);
    expect(c.numInterfaces, 1);
    expect(c.configurationValue, 1);
    expect(c.selfPowered, isTrue);
    expect(c.remoteWakeup, isTrue);
    expect(c.maxPower, 0);

    final alt = c.interfaces.single.altSettings.single;
    expect(alt.interfaceNumber, InterfaceNumber.interface0);
    expect(alt.alternateSetting, AlternateSetting.default_);
    expect(alt.class_.type, ClassType.hub);

    final endpoint = alt.endpoints.single;
    expect(endpoint.address, const EndpointAddress.in_(.ep1));
    expect(endpoint.transferType, TransferType.interrupt);
    expect(endpoint.maxPacketSize.size, 4);
    expect(endpoint.interval.value, 12);
  });

  test('dell webcam: alternate settings and high-bandwidth endpoints', () {
    final c = ConfigurationDescriptor.parse([
      0x09, 0x02, 0x9c, 0x00, 0x02, 0x01, 0x00, 0x80, 0xfa,
      // interface association
      0x08, 0x0b, 0x00, 0x02, 0x0e, 0x03, 0x00, 0x05,
      // VideoControl interface, a class-specific descriptor and an endpoint
      0x09, 0x04, 0x00, 0x00, 0x01, 0x0e, 0x01, 0x00, 0x05,
      0x0d,
      0x24,
      0x01,
      0x00,
      0x01,
      0x67,
      0x00,
      0xc0,
      0xe1,
      0xe4,
      0x00,
      0x01,
      0x01,
      0x07, 0x05, 0x83, 0x03, 0x10, 0x00, 0x06,
      0x05, 0x25, 0x03, 0x80, 0x00,
      // VideoStreaming alternate settings 0-6
      0x09, 0x04, 0x01, 0x00, 0x00, 0x0e, 0x02, 0x00, 0x00,
      0x09,
      0x04,
      0x01,
      0x01,
      0x01,
      0x0e,
      0x02,
      0x00,
      0x00,
      0x07,
      0x05,
      0x81,
      0x05,
      0x80,
      0x00,
      0x01,
      0x09,
      0x04,
      0x01,
      0x02,
      0x01,
      0x0e,
      0x02,
      0x00,
      0x00,
      0x07,
      0x05,
      0x81,
      0x05,
      0x00,
      0x01,
      0x01,
      0x09,
      0x04,
      0x01,
      0x03,
      0x01,
      0x0e,
      0x02,
      0x00,
      0x00,
      0x07,
      0x05,
      0x81,
      0x05,
      0x20,
      0x03,
      0x01,
      0x09,
      0x04,
      0x01,
      0x04,
      0x01,
      0x0e,
      0x02,
      0x00,
      0x00,
      0x07,
      0x05,
      0x81,
      0x05,
      0x20,
      0x0b,
      0x01,
      0x09,
      0x04,
      0x01,
      0x05,
      0x01,
      0x0e,
      0x02,
      0x00,
      0x00,
      0x07,
      0x05,
      0x81,
      0x05,
      0x20,
      0x13,
      0x01,
      0x09,
      0x04,
      0x01,
      0x06,
      0x01,
      0x0e,
      0x02,
      0x00,
      0x00,
      0x07,
      0x05,
      0x81,
      0x05,
      0x00,
      0x14,
      0x01,
    ]);

    expect(c.interfaces.map((i) => i.interfaceNumber.value), [0, 1]);

    final control = c.interfaces[0].altSettings.single;
    expect(control.class_.code, 0x0e);
    expect(control.descriptors.map((d) => d.bDescriptorType), [
      0x24,
      0x05,
      0x25,
    ]);
    expect(control.endpoints.single.address.value, 0x83);

    final streaming = c.interfaces[1].altSettings;
    expect(streaming.map((a) => a.alternateSetting.value), [
      0,
      1,
      2,
      3,
      4,
      5,
      6,
    ]);
    expect(streaming[0].endpoints, isEmpty);
    final expected = [
      (128, null),
      (256, null),
      (800, null),
      (800, 2),
      (800, 3),
      (1024, 3),
    ];
    for (final (i, (size, transactions)) in expected.indexed) {
      final e = streaming[i + 1].endpoints.single;
      expect(e.transferType, TransferType.isochronous);
      expect(e.maxPacketSize.size, size, reason: 'alt ${i + 1}');
      expect(
        e.maxPacketSize.transactionsPerMicroframe,
        transactions,
        reason: 'alt ${i + 1}',
      );
    }
  });

  group('round trips with the gadget-side builders', () {
    test('interface descriptor', () {
      const built = InterfaceDescriptor(
        interfaceNumber: InterfaceNumber.interface1,
        alternateSetting: AlternateSetting.alt2,
        numEndpoints: EndpointCount.two,
        class_: Class.vendorSpecific(0x12, 0x34),
        stringIndex: StringIndex(5),
      );
      final parsed = InterfaceDescriptor.parse(built.toBytes());
      expect(parsed.toBytes(), built.toBytes());
      expect(parsed.class_, built.class_);
    });

    test('endpoint descriptor', () {
      final built = EndpointDescriptor(
        address: const EndpointAddress.out(.ep2),
        attributes: .isochronous(syncType: .adaptive, usageType: .data),
        maxPacketSize: const MaxPacketSize.fromValue(0x1400),
        interval: const PollingInterval.raw(1),
      );
      final parsed = EndpointDescriptor.parse(built.toBytes());
      expect(parsed.toBytes(), built.toBytes());
      expect(parsed.attributes.syncType, IsoSyncType.adaptive);
      expect(parsed.maxPacketSize.transactionsPerMicroframe, 3);
    });

    test('device descriptor', () {
      final built = DeviceDescriptor(
        usbVersion: 0x0210,
        class_: const Class.raw(0xef, 0x02, 0x01),
        maxPacketSize0: 64,
        id: const Id(vendor: 0x1234, product: 0x5678),
        deviceVersion: 0x0100,
        manufacturer: StringIndex.manufacturer,
        numConfigurations: 1,
      );
      expect(
        DeviceDescriptor.parse(built.toBytes()).toBytes(),
        built.toBytes(),
      );
    });

    test('setup packet', () {
      const request = ControlIn(
        type: .vendor,
        recipient: .interface,
        request: 0x30,
        value: 0x1234,
        index: 2,
        length: 64,
      );
      expect(request.setup.toBytes(), [
        0xC1,
        0x30,
        0x34,
        0x12,
        0x02,
        0x00,
        0x40,
        0x00,
      ]);
      expect(SetupPacket.parse(request.setup.toBytes()), request.setup);
      const out = ControlOut(
        type: .class_,
        recipient: .endpoint,
        request: 1,
        data: [1, 2, 3],
      );
      expect(out.setup.toBytes(), [0x22, 0x01, 0, 0, 0, 0, 3, 0]);
      expect(
        SetupPacket.parse([0x80, 0x06, 0x00, 0x01, 0, 0, 18, 0])
            .standardRequest,
        StandardRequest.getDescriptor,
      );
      expect(
        SetupPacket.parse([0x80, 0x42, 0, 0, 0, 0, 0, 0]).standardRequest,
        isNull,
      );
    });
  });

  test('InterfaceAltSetting.parse stops at the next interface', () {
    final alt = InterfaceAltSetting.parse([
      0x09, 0x04, 0x02, 0x01, 0x01, 0xff, 0x00, 0x00, 0x00, //
      0x07, 0x05, 0x81, 0x02, 0x00, 0x02, 0x00, //
      0x09, 0x04, 0x03, 0x00, 0x00, 0xff, 0x00, 0x00, 0x00,
    ]);
    expect(alt.interfaceNumber.value, 2);
    expect(alt.alternateSetting.value, 1);
    expect(alt.endpoints.single.maxPacketSize.size, 512);
    expect(
      () =>
          InterfaceAltSetting.parse([0x07, 0x05, 0x81, 0x02, 0x00, 0x02, 0x00]),
      throwsFormatException,
    );
  });

  group('string descriptors', () {
    test('round trip', () {
      expect(StringDescriptor.decode(StringDescriptor.encode('ABé')), 'ABé');
    });
    test('surrogate pair', () {
      expect(StringDescriptor.decode([6, 3, 0x3d, 0xd8, 0x00, 0xde]), '😀');
    });
    test('unpaired surrogate becomes U+FFFD', () {
      expect(StringDescriptor.decode([4, 3, 0x3d, 0xd8]), '�');
    });
    test('rejects bad length', () {
      expect(StringDescriptor.decode([6, 3, 0x41, 0]), isNull);
    });
    test('languages', () {
      expect(StringDescriptor.decodeLanguages([4, 3, 0x09, 0x04]), [
        LanguageId.enUS.value,
      ]);
    });
  });

  test('unknown class codes are preserved', () {
    const c = Class.raw(0x42, 1, 2);
    expect(c.code, 0x42);
    expect(c.type, isNull);
    expect(Uint8List.fromList([c.code]), [0x42]);
  });
}
