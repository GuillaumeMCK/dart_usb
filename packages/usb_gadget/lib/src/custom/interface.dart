part of 'custom.dart';

/// An interface of a [CustomFunction].
final class CustomInterface {
  CustomInterface(
    this.class_, {
    this.name = '',
    this.names = const {},
    this.endpoints = const [],
    this.association,
    this.osExtCompat = const [],
    this.osExtProperties = const [],
    this.descriptors = const [],
  });

  final Class class_;

  /// Interface string in US English; see [names] for other languages.
  final String name;
  final Map<LanguageId, String> names;
  final List<CustomEndpoint> endpoints;

  /// Groups adjacent interfaces into one function for the host.
  final InterfaceAssociation? association;

  /// Microsoft extended compatibility IDs, such as [OsExtCompat.winUsb].
  final List<OsExtCompat> osExtCompat;

  /// Microsoft extended properties (registry values).
  final List<OsExtProperty> osExtProperties;

  /// Class-specific descriptors, placed right after the interface
  /// descriptor.
  final List<CustomDescriptor> descriptors;
}

/// Groups interfaces that share it into one function. Associated interfaces
/// must be adjacent.
final class InterfaceAssociation {
  InterfaceAssociation(this.class_, {this.name = '', this.names = const {}});

  final Class class_;
  final String name;
  final Map<LanguageId, String> names;
}

/// Microsoft extended compatibility ID.
final class OsExtCompat {
  const OsExtCompat(this.compatibleId, [this.subCompatibleId = '']);

  /// Binds Windows' WinUSB driver.
  static const winUsb = OsExtCompat('WINUSB');

  /// Up to 8 ASCII characters.
  final String compatibleId;
  final String subCompatibleId;
}

/// A Microsoft extended property: a registry value Windows stores for the
/// interface.
final class OsExtProperty {
  const OsExtProperty._(
    this.name,
    this._kind, {
    this.text = '',
    this.binary = const [],
    this.dword = 0,
    this.strings = const [],
  });

  const OsExtProperty.string(String name, String value)
    : this._(name, rust.OsRegValueKind.sz, text: value);
  const OsExtProperty.expandString(String name, String value)
    : this._(name, rust.OsRegValueKind.expandSz, text: value);
  const OsExtProperty.binary(String name, List<int> value)
    : this._(name, rust.OsRegValueKind.binary, binary: value);
  const OsExtProperty.dword(String name, int value)
    : this._(name, rust.OsRegValueKind.dwordLe, dword: value);
  const OsExtProperty.dwordBigEndian(String name, int value)
    : this._(name, rust.OsRegValueKind.dwordBe, dword: value);
  const OsExtProperty.link(String name, String value)
    : this._(name, rust.OsRegValueKind.link, text: value);
  const OsExtProperty.multiString(String name, List<String> value)
    : this._(name, rust.OsRegValueKind.multiSz, strings: value);

  /// The interface GUID applications open the device by, such as
  /// `12345678-1234-1234-1234-123456789abc`.
  const OsExtProperty.deviceInterfaceGuid(String guid)
    : this._('DeviceInterfaceGUID', rust.OsRegValueKind.sz, text: '{$guid}');

  final String name;
  final rust.OsRegValueKind _kind;
  final String text;
  final List<int> binary;
  final int dword;
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

/// A class-specific descriptor of a [CustomInterface].
final class CustomDescriptor {
  const CustomDescriptor(this.descriptorType, this.data);

  /// `bDescriptorType`.
  final int descriptorType;

  /// The bytes after `bLength` and `bDescriptorType`.
  final List<int> data;
}

/// An endpoint of a [CustomInterface]. Its direction comes from [io]: an
/// [InEndpoint] makes an IN endpoint, an [OutEndpoint] an OUT one.
final class CustomEndpoint {
  const CustomEndpoint(
    this.io, {
    this.transferType = .bulk,
    this.syncType = .noSync,
    this.usageType = .data,
    this.maxPacketSizeHighSpeed = 512,
    this.maxPacketSizeSuperSpeed = 1024,
    this.maxBurstSuperSpeed = 0,
    this.bytesPerIntervalSuperSpeed = 0,
    this.interval,
    this.audioRefresh,
    this.audioSynchAddress,
  });

  /// A bulk endpoint.
  const CustomEndpoint.bulk(
    EndpointIo io, {
    int maxPacketSizeHighSpeed = 512,
    int maxPacketSizeSuperSpeed = 1024,
    int maxBurstSuperSpeed = 0,
  }) : this(
         io,
         maxPacketSizeHighSpeed: maxPacketSizeHighSpeed,
         maxPacketSizeSuperSpeed: maxPacketSizeSuperSpeed,
         maxBurstSuperSpeed: maxBurstSuperSpeed,
       );

  /// An interrupt endpoint polled every [interval] (frames, or
  /// 2^(interval-1) microframes at high speed).
  const CustomEndpoint.interrupt(
    EndpointIo io, {
    required int interval,
    int maxPacketSize = 64,
  }) : this(
         io,
         transferType: .interrupt,
         interval: interval,
         maxPacketSizeHighSpeed: maxPacketSize,
         maxPacketSizeSuperSpeed: maxPacketSize,
         bytesPerIntervalSuperSpeed: maxPacketSize,
       );

  /// An isochronous endpoint.
  const CustomEndpoint.isochronous(
    EndpointIo io, {
    IsoSyncType syncType = .noSync,
    IsoUsageType usageType = .data,
    int interval = 1,
    int maxPacketSize = 1024,
    int? audioRefresh,
    int? audioSynchAddress,
  }) : this(
         io,
         transferType: .isochronous,
         syncType: syncType,
         usageType: usageType,
         interval: interval,
         maxPacketSizeHighSpeed: maxPacketSize,
         maxPacketSizeSuperSpeed: maxPacketSize,
         bytesPerIntervalSuperSpeed: maxPacketSize,
         audioRefresh: audioRefresh,
         audioSynchAddress: audioSynchAddress,
       );

  final EndpointIo io;
  final TransferType transferType;

  /// Isochronous only.
  final IsoSyncType syncType;

  /// Isochronous only.
  final IsoUsageType usageType;
  final int maxPacketSizeHighSpeed;
  final int maxPacketSizeSuperSpeed;
  final int maxBurstSuperSpeed;
  final int bytesPerIntervalSuperSpeed;

  /// `bInterval`; `null` for 0 on IN and 1 on OUT bulk endpoints.
  final int? interval;

  /// Audio endpoints: `bRefresh`.
  final int? audioRefresh;

  /// Audio endpoints: `bSynchAddress`.
  final int? audioSynchAddress;

  rust.EndpointSpec _spec() => rust.EndpointSpec(
    deviceToHost: io is InEndpoint,
    queueLength: io.queueLength,
    transferType: transferType.value,
    syncType: (syncType.value >> 2) & 0x03,
    usageType: (usageType.value >> 4) & 0x03,
    maxPacketSizeHs: maxPacketSizeHighSpeed,
    maxPacketSizeSs: maxPacketSizeSuperSpeed,
    maxBurstSs: maxBurstSuperSpeed,
    bytesPerIntervalSs: bytesPerIntervalSuperSpeed,
    interval: interval,
    audioRefresh: audioRefresh,
    audioSynchAddress: audioSynchAddress,
  );
}
