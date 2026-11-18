part of 'custom.dart';

/// An interface of a [CustomFunction].
///
/// ```dart
/// CustomInterface(
///   class_: const .vendorSpecific(0, 0),
///   name: 'echo',
///   endpoints: const [
///     EndpointTemplate(address: .in_(.ep1), config: .bulk()),
///     EndpointTemplate(address: .out(.ep2), config: .bulk()),
///   ],
/// )
/// ```
final class const CustomInterface({
  required this.class_,
  this.name = '',
  this.names = const {},
  this.endpoints = const [],
  this.descriptors = const [],
  this.association,
  this.osExtCompat = const [],
  this.osExtProperties = const [],
}) {
  /// An interface of class [class_] with [endpoints].
  this;

  /// Interface class, subclass and protocol.
  final Class class_;

  /// Interface string in US English; see [names] for other languages.
  final String name;

  /// Interface string per language, overriding [name].
  final Map<LanguageId, String> names;

  /// The endpoints. Their packet sizes and intervals come from each
  /// template's [EndpointConfig]; their numbers identify them in
  /// [CustomFunction.endpointIn] and [CustomFunction.endpointOut] (the host
  /// may see other numbers).
  final List<EndpointTemplate> endpoints;

  /// Class-specific descriptors placed right after the interface
  /// descriptor, such as a [HidDescriptor].
  final List<Descriptor> descriptors;

  /// Groups adjacent interfaces into one function for the host.
  final InterfaceAssociation? association;

  /// Microsoft extended compatibility IDs, such as [OsExtCompat.winUsb].
  final List<OsExtCompat> osExtCompat;

  /// Microsoft extended properties (registry values).
  final List<OsExtProperty> osExtProperties;
}

/// Groups the interfaces that share it into one function. Associated
/// interfaces must be adjacent.
final class InterfaceAssociation({
  required this.class_,
  this.name = '',
  this.names = const {},
}) {
  /// An association of class [class_].
  this;

  /// Function class, subclass and protocol.
  final Class class_;

  /// Function string in US English.
  final String name;

  /// Function string per language, overriding [name].
  final Map<LanguageId, String> names;
}

/// Microsoft extended compatibility ID.
final class const OsExtCompat(this.compatibleId, [this.subCompatibleId = '']) {
  /// A compatibility ID such as `WINUSB`.
  this;

  /// Binds Windows' WinUSB driver.
  static const winUsb = OsExtCompat('WINUSB');

  /// Up to 8 ASCII characters.
  final String compatibleId;

  /// Sub-compatibility ID, up to 8 ASCII characters.
  final String subCompatibleId;
}

/// A Microsoft extended property: a registry value Windows stores for the
/// interface.
final class const OsExtProperty._(
  this.name,
  this._kind, {
  this.text = '',
  this.binary = const [],
  this.dword = 0,
  this.strings = const [],
}) {
  /// A `REG_SZ` string value.
  const OsExtProperty.string(String name, String value)
    : this._(name, rust.OsRegValueKind.sz, text: value);

  /// A `REG_EXPAND_SZ` string value.
  const OsExtProperty.expandString(String name, String value)
    : this._(name, rust.OsRegValueKind.expandSz, text: value);

  /// A `REG_BINARY` value.
  const OsExtProperty.binary(String name, List<int> value)
    : this._(name, rust.OsRegValueKind.binary, binary: value);

  /// A little-endian `REG_DWORD` value.
  const OsExtProperty.dword(String name, int value)
    : this._(name, rust.OsRegValueKind.dwordLe, dword: value);

  /// A `REG_DWORD_BIG_ENDIAN` value.
  const OsExtProperty.dwordBigEndian(String name, int value)
    : this._(name, rust.OsRegValueKind.dwordBe, dword: value);

  /// A `REG_LINK` value.
  const OsExtProperty.link(String name, String value)
    : this._(name, rust.OsRegValueKind.link, text: value);

  /// A `REG_MULTI_SZ` value.
  const OsExtProperty.multiString(String name, List<String> value)
    : this._(name, rust.OsRegValueKind.multiSz, strings: value);

  /// The interface GUID applications open the device by, such as
  /// `12345678-1234-1234-1234-123456789abc`.
  const OsExtProperty.deviceInterfaceGuid(String guid)
    : this._('DeviceInterfaceGUID', rust.OsRegValueKind.sz, text: '{$guid}');

  /// Registry value name.
  final String name;
  final rust.OsRegValueKind _kind;

  /// The value of string and link properties.
  final String text;

  /// The value of binary properties.
  final List<int> binary;

  /// The value of DWORD properties.
  final int dword;

  /// The value of multi-string properties.
  final List<String> strings;

  rust.OsExtPropSpec _spec() => rust.OsExtPropSpec(
    name: name,
    kind: _kind,
    text: text,
    binary: Uint8List.fromList(binary),
    dword: dword,
    strings: strings,
  );
}

rust.EndpointSpec _endpointSpec(EndpointTemplate t, int queueLength) {
  final config = t.config;
  final periodic =
      config.transferType == .interrupt || config.transferType == .isochronous;
  final (sync, usage) = switch (config) {
    IsochronousEndpointConfig(:final syncType, :final usageType) => (
      syncType,
      usageType,
    ),
    _ => (IsoSyncType.noSync, IsoUsageType.data),
  };
  final superSpeed = config.getMaxPacketSize(.superSpeed).size;
  return rust.EndpointSpec(
    deviceToHost: t.address.direction == .in_,
    queueLength: queueLength,
    transferType: config.transferType.value,
    syncType: (sync.value >> 2) & 0x03,
    usageType: (usage.value >> 4) & 0x03,
    maxPacketSizeHs: config.getMaxPacketSize(.highSpeed).size,
    maxPacketSizeSs: superSpeed,
    maxBurstSs: 0,
    bytesPerIntervalSs: periodic ? superSpeed : 0,
    // FunctionFS takes one bInterval for every speed; use the high-speed
    // one, as most controllers are.
    interval: periodic ? config.getPollingInterval(.highSpeed).value : null,
  );
}
