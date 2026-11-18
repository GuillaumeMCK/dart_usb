import 'dart:typed_data';

import 'package:usb_models/usb_models.dart';

/// Splits concatenated descriptors into individual [RawDescriptor]s.
///
/// Stops at the first malformed descriptor (a `bLength` below 2 or past the
/// end of [bytes]) rather than throwing, as devices sometimes report
/// trailing garbage.
List<RawDescriptor> splitDescriptors(List<int> bytes) {
  final out = <RawDescriptor>[];
  var i = 0;
  while (i + 2 <= bytes.length) {
    final length = bytes[i];
    if (length < 2 || i + length > bytes.length) break;
    out.add(RawDescriptor(bytes.sublist(i, i + length)));
    i += length;
  }
  return out;
}

/// A device descriptor, as read from a device.
final class const DeviceDescriptor({
  required this.usbVersion,
  required this.class_,
  required this.maxPacketSize0,
  required this.id,
  required this.deviceVersion,
  this.manufacturer = StringIndex.none,
  this.product = StringIndex.none,
  this.serialNumber = StringIndex.none,
  required this.numConfigurations,
}) {
  /// A device descriptor with the given fields; see [DeviceDescriptor.parse].
  this;

  /// Parses an 18-byte device descriptor.
  ///
  /// Throws [FormatException] if [bytes] is not a device descriptor.
  factory DeviceDescriptor.parse(List<int> bytes) {
    if (bytes.length < length ||
        bytes[0] < length ||
        bytes[1] != DescriptorType.device.value) {
      throw FormatException('not a valid device descriptor', bytes);
    }
    int u16(int i) => bytes[i] | (bytes[i + 1] << 8);
    return DeviceDescriptor(
      usbVersion: u16(2),
      class_: Class.raw(bytes[4], bytes[5], bytes[6]),
      maxPacketSize0: bytes[7],
      id: Id(vendor: u16(8), product: u16(10)),
      deviceVersion: u16(12),
      manufacturer: StringIndex(bytes[14]),
      product: StringIndex(bytes[15]),
      serialNumber: StringIndex(bytes[16]),
      numConfigurations: bytes[17],
    );
  }

  /// Length of a device descriptor in bytes.
  static const length = 18;

  /// `bcdUSB`, such as `0x0200` for USB 2.0.
  final int usbVersion;

  /// Device class, subclass and protocol.
  final Class class_;

  /// `bMaxPacketSize0`: max packet size of endpoint 0.
  final int maxPacketSize0;

  /// Vendor and product IDs.
  final Id id;

  /// `bcdDevice`: the device release number.
  final int deviceVersion;

  /// String index of the manufacturer name.
  final StringIndex manufacturer;

  /// String index of the product name.
  final StringIndex product;

  /// String index of the serial number.
  final StringIndex serialNumber;

  /// `bNumConfigurations`.
  final int numConfigurations;

  /// Serializes to the 18-byte descriptor.
  Uint8List toBytes() {
    final b = ByteData(length)
      ..setUint8(0, length)
      ..setUint8(1, DescriptorType.device.value)
      ..setUint16(2, usbVersion, .little)
      ..setUint8(4, class_.code)
      ..setUint8(5, class_.subClass)
      ..setUint8(6, class_.protocol)
      ..setUint8(7, maxPacketSize0)
      ..setUint16(8, id.vendor, .little)
      ..setUint16(10, id.product, .little)
      ..setUint16(12, deviceVersion, .little)
      ..setUint8(14, manufacturer.value)
      ..setUint8(15, product.value)
      ..setUint8(16, serialNumber.value)
      ..setUint8(17, numConfigurations);
    return b.buffer.asUint8List();
  }

  @override
  String toString() =>
      'DeviceDescriptor($id, USB ${_bcd(usbVersion)}, $class_, '
      '$numConfigurations configuration${numConfigurations == 1 ? '' : 's'})';
}

/// A configuration descriptor with its interfaces, alternate settings and
/// endpoints, as read from a device.
final class ConfigurationDescriptor._(this.bytes, this.interfaces) {
  /// Parses a configuration descriptor and the descriptors that follow it,
  /// up to `wTotalLength`.
  ///
  /// Throws [FormatException] if the header is invalid.
  factory ConfigurationDescriptor.parse(List<int> bytes) {
    if (bytes.length < 9 ||
        bytes[0] < 9 ||
        bytes[1] != DescriptorType.config.value) {
      throw FormatException('not a valid configuration descriptor', bytes);
    }
    final totalLength = bytes[2] | (bytes[3] << 8);
    if (totalLength < bytes[0] || totalLength > bytes.length) {
      throw FormatException(
        'invalid wTotalLength $totalLength (${bytes.length} bytes available)',
        bytes,
      );
    }
    final own = Uint8List.fromList(bytes.sublist(0, totalLength));
    return ConfigurationDescriptor._(
      own,
      _groupInterfaces(splitDescriptors(own.sublist(own[0]))),
    );
  }

  /// Parses configuration descriptors stored back to back (as Linux usbfs
  /// returns them), stopping at the first invalid one.
  static List<ConfigurationDescriptor> parseAll(List<int> bytes) {
    final out = <ConfigurationDescriptor>[];
    var rest = bytes;
    while (true) {
      final ConfigurationDescriptor config;
      try {
        config = ConfigurationDescriptor.parse(rest);
      } on FormatException {
        return out;
      }
      out.add(config);
      rest = rest.sublist(config.bytes.length);
    }
  }

  /// The raw descriptors, `wTotalLength` bytes.
  final Uint8List bytes;

  /// Interfaces in ascending order, each with its alternate settings.
  final List<InterfaceDescriptors> interfaces;

  /// `bNumInterfaces`.
  int get numInterfaces => bytes[4];

  /// `bConfigurationValue`, used to select this configuration.
  int get configurationValue => bytes[5];

  /// String index describing this configuration.
  StringIndex get stringIndex => StringIndex(bytes[6]);

  /// `bmAttributes`.
  int get attributes => bytes[7];

  /// Whether the device is self-powered in this configuration.
  bool get selfPowered => attributes & 0x40 != 0;

  /// Whether the device supports remote wakeup in this configuration.
  bool get remoteWakeup => attributes & 0x20 != 0;

  /// `bMaxPower`, in units of 2 mA (USB 2) or 8 mA (SuperSpeed).
  int get maxPower => bytes[8];

  /// Every alternate setting of every interface, in descriptor order.
  Iterable<InterfaceAltSetting> get altSettings =>
      interfaces.expand((i) => i.altSettings);

  @override
  String toString() =>
      'ConfigurationDescriptor($configurationValue, interfaces: $interfaces)';
}

/// All the alternate settings of one interface.
final class const InterfaceDescriptors(this.interfaceNumber, this.altSettings) {
  /// Interface [interfaceNumber] with its [altSettings].
  this;

  /// `bInterfaceNumber`.
  final InterfaceNumber interfaceNumber;

  /// Alternate settings in descriptor order; the first is usually setting 0.
  final List<InterfaceAltSetting> altSettings;

  @override
  String toString() =>
      'Interface(${interfaceNumber.value}, altSettings: $altSettings)';
}

/// One alternate setting of an interface: its descriptor, endpoints and
/// any class-specific descriptors.
final class const InterfaceAltSetting(
  this.descriptor,
  this.endpoints,
  this.descriptors,
) {
  /// An alternate setting described by [descriptor].
  this;

  /// Parses an interface descriptor followed by its endpoint and
  /// class-specific descriptors, up to the next interface descriptor.
  ///
  /// Throws [FormatException] if [bytes] doesn't start with an interface
  /// descriptor.
  factory InterfaceAltSetting.parse(List<int> bytes) {
    final descriptors = splitDescriptors(bytes);
    if (descriptors.isEmpty) {
      throw FormatException('empty interface descriptor', bytes);
    }
    return _groupInterfaces(descriptors).firstOrNull?.altSettings.first ??
        (throw FormatException('not a valid interface descriptor', bytes));
  }

  /// The interface descriptor itself.
  final InterfaceDescriptor descriptor;

  /// The endpoint descriptors.
  final List<EndpointDescriptor> endpoints;

  /// Every descriptor after the interface descriptor, up to the next
  /// interface: endpoints and class-specific descriptors.
  final List<RawDescriptor> descriptors;

  /// `bInterfaceNumber`.
  InterfaceNumber get interfaceNumber => descriptor.interfaceNumber;

  /// `bAlternateSetting`.
  AlternateSetting get alternateSetting => descriptor.alternateSetting;

  /// Interface class, subclass and protocol.
  Class get class_ => descriptor.class_;

  /// String index of the interface name.
  StringIndex get stringIndex => descriptor.stringIndex;

  @override
  String toString() =>
      'InterfaceAltSetting(${interfaceNumber.value}/${alternateSetting.value}, $class_, endpoints: $endpoints)';
}

List<InterfaceDescriptors> _groupInterfaces(List<RawDescriptor> descriptors) {
  final groups = <int, List<InterfaceAltSetting>>{};
  for (var i = 0; i < descriptors.length; i++) {
    final d = descriptors[i];
    if (d.bDescriptorType != DescriptorType.interface.value || d.bLength < 9) {
      continue;
    }
    var end = i + 1;
    while (end < descriptors.length &&
        descriptors[end].bDescriptorType != DescriptorType.interface.value) {
      end++;
    }
    final following = descriptors.sublist(i + 1, end);
    final interface = InterfaceDescriptor.parse(d.toBytes());
    final endpoints = [
      for (final e in following)
        if (e.bDescriptorType == DescriptorType.endpoint.value &&
            e.bLength >= 7)
          EndpointDescriptor.parse(e.toBytes()),
    ];
    (groups[interface.interfaceNumber.value] ??= []).add(
      InterfaceAltSetting(interface, endpoints, following),
    );
  }
  final numbers = groups.keys.toList()..sort();
  return [
    for (final n in numbers)
      InterfaceDescriptors(InterfaceNumber(n), groups[n]!),
  ];
}

/// String descriptors: UTF-16LE text, or the list of supported languages
/// at index 0.
abstract final class StringDescriptor() {
  /// Decodes a string descriptor, or returns `null` if [bytes] isn't one.
  /// Unpaired surrogates become U+FFFD.
  static String? decode(List<int> bytes) {
    if (bytes.length < 2 ||
        bytes[0] != bytes.length ||
        bytes[1] != DescriptorType.string.value) {
      return null;
    }
    final units = [
      for (var i = 2; i + 1 < bytes.length; i += 2)
        bytes[i] | (bytes[i + 1] << 8),
    ];
    final out = StringBuffer();
    for (var i = 0; i < units.length; i++) {
      final u = units[i];
      if (u >= 0xD800 && u <= 0xDBFF && i + 1 < units.length) {
        final lo = units[i + 1];
        if (lo >= 0xDC00 && lo <= 0xDFFF) {
          out.writeCharCode(0x10000 + ((u - 0xD800) << 10) + (lo - 0xDC00));
          i++;
          continue;
        }
      }
      out.writeCharCode(u >= 0xD800 && u <= 0xDFFF ? 0xFFFD : u);
    }
    return out.toString();
  }

  /// Encodes [text] as a string descriptor.
  static Uint8List encode(String text) {
    final units = text.codeUnits;
    final b = ByteData(2 + units.length * 2)
      ..setUint8(0, 2 + units.length * 2)
      ..setUint8(1, DescriptorType.string.value);
    for (var i = 0; i < units.length; i++) {
      b.setUint16(2 + i * 2, units[i], .little);
    }
    return b.buffer.asUint8List();
  }

  /// Decodes string descriptor 0, the language IDs a device supports, or
  /// returns `null` if [bytes] isn't one. IDs are raw values; see
  /// [LanguageId] for common ones.
  static List<int>? decodeLanguages(List<int> bytes) {
    if (bytes.length < 2 ||
        bytes[0] != bytes.length ||
        bytes[1] != DescriptorType.string.value) {
      return null;
    }
    return [
      for (var i = 2; i + 1 < bytes.length; i += 2)
        bytes[i] | (bytes[i + 1] << 8),
    ];
  }
}

String _bcd(int v) =>
    '${(v >> 8).toRadixString(16)}.${(v & 0xff).toRadixString(16).padLeft(2, '0')}';
