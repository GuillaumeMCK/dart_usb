import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:meta/meta.dart';
import 'package:usb_models/usb_models.dart';

import 'function.dart';
import 'rust/api.dart' show LocalizedString;
import 'rust/api/custom.dart' as rust;
import 'rust/api/endpoint.dart' as rust;
import 'rust/api/error.dart';
import 'rust/api/function.dart' show FunctionState;
import 'rust/api/gadget.dart' show FunctionHandle;

List<LocalizedString> _localized(String name, Map<LanguageId, String> names) =>
    [
      for (final MapEntry(key: language, value: text) in {
        LanguageId.enUS: name,
        ...names,
      }.entries)
        LocalizedString(language: language.value, text: text),
    ];

/// A function implemented in Dart through FunctionFS: its interfaces and
/// endpoints are declared here, its control requests arrive as [events],
/// and its data moves through [EndpointSender]s and [EndpointReceiver]s.
///
/// ```dart
/// final tx = EndpointSender(), rx = EndpointReceiver();
/// final function = CustomFunction([
///   CustomInterface(
///     const Class.vendorSpecific(0, 0),
///     name: 'echo',
///     endpoints: [CustomEndpoint.bulk(tx), CustomEndpoint.bulk(rx)],
///   ),
/// ]);
/// ```
///
/// Requires `CONFIG_USB_CONFIGFS_F_FS`.
final class CustomFunction extends GadgetFunction {
  CustomFunction(
    this.interfaces, {
    this.allControlRecipients = false,
    this.config0Setup = false,
    this.ffsDirectory,
    this.ffsRootMode,
    this.ffsFileMode,
    this.ffsUid,
    this.ffsGid,
    this.ffsNoDisconnect = false,
    this.ffsNoInit = false,
    this.ffsNoMount = false,
  });

  final List<CustomInterface> interfaces;

  /// Receives control requests for any recipient, not only this function's
  /// interfaces and endpoints.
  final bool allControlRecipients;

  /// Receives control requests while the device is unconfigured.
  final bool config0Setup;

  /// Mounts FunctionFS here instead of a temporary directory.
  final String? ffsDirectory;
  final int? ffsRootMode;
  final int? ffsFileMode;
  final int? ffsUid;
  final int? ffsGid;
  final bool ffsNoDisconnect;
  final bool ffsNoInit;
  final bool ffsNoMount;

  rust.CustomFunction? _native;

  rust.CustomFunction get _function =>
      _native ??
      (throw StateError('CustomFunction is not part of a registered gadget'));

  @override
  @internal
  FunctionHandle createHandle() {
    if (_native == null) {
      final native = rust.CustomFunction(spec: _spec());
      var index = 0;
      for (final interface in interfaces) {
        for (final endpoint in interface.endpoints) {
          switch (endpoint.io) {
            case final EndpointSender sender:
              sender._native = native.takeSender(index);
            case final EndpointReceiver receiver:
              receiver._native = native.takeReceiver(index);
          }
          index++;
        }
      }
      _native = native;
    }
    return _native!.handle();
  }

  @override
  FunctionState get state => _native?.state ?? .unregistered;

  @override
  String? get path => _native?.path;

  /// Where FunctionFS is mounted. Available once registered.
  Future<String> get mountPath => _function.ffsDir();

  /// The interface number the host sees for this function's interface
  /// [index]. Available once bound.
  Future<int> interfaceNumber(int index) =>
      _function.realInterfaceNumber(index);

  /// Lifecycle events and control requests, from the moment this is
  /// listened to. Answer every [ControlRequest] promptly: unanswered ones
  /// are stalled after 4.5 seconds, before the host gives up.
  ///
  /// Listen once at a time; cancelling stalls pending requests.
  Stream<CustomEvent> get events {
    final function = _function;
    var listening = false;
    late final StreamController<CustomEvent> controller;
    Future<void> pump() async {
      while (listening) {
        try {
          final event = await function.nextEvent(
            const Duration(milliseconds: 200),
          );
          if (event != null && listening) {
            controller.add(_event(function, event));
          }
        } on GadgetException catch (e, stack) {
          if (listening) controller.addError(e, stack);
          break;
        }
      }
      if (listening) await controller.close();
    }

    controller = StreamController(
      onListen: () {
        listening = true;
        unawaited(pump());
      },
      onCancel: () {
        listening = false;
        function.stopEvents();
      },
    );
    return controller.stream;
  }

  static CustomEvent _event(rust.CustomFunction function, rust.CustomEvent e) =>
      switch (e.kind) {
        .bind => const BindEvent(),
        .unbind => const UnbindEvent(),
        .enable => const EnableEvent(),
        .disable => const DisableEvent(),
        .suspend => const SuspendEvent(),
        .resume => const ResumeEvent(),
        .setupDeviceToHost => ControlInRequest._(
          function,
          e.id,
          SetupPacket.parse(e.setup),
        ),
        .setupHostToDevice => ControlOutRequest._(
          function,
          e.id,
          SetupPacket.parse(e.setup),
        ),
        .unknown => UnknownEvent(e.code),
      };

  rust.CustomSpec _spec() {
    final associations = <InterfaceAssociation, int>{};
    return rust.CustomSpec(
      interfaces: [
        for (final i in interfaces)
          rust.InterfaceSpec(
            class_: classCodes(i.class_),
            name: _localized(i.name, i.names),
            endpoints: [for (final e in i.endpoints) e._spec()],
            association: switch (i.association) {
              final a? => rust.AssociationSpec(
                id: associations.putIfAbsent(a, () => associations.length),
                class_: classCodes(a.class_),
                name: _localized(a.name, a.names),
              ),
              null => null,
            },
            osExtCompat: [
              for (final c in i.osExtCompat)
                rust.OsExtCompatSpec(
                  compatibleId: ascii.encode(c.compatibleId),
                  subCompatibleId: ascii.encode(c.subCompatibleId),
                ),
            ],
            osExtProps: [for (final p in i.osExtProperties) p._spec()],
            customDescriptors: [
              for (final d in i.descriptors)
                rust.CustomDescriptorSpec(
                  descriptorType: d.descriptorType,
                  data: Uint8List.fromList(d.data),
                ),
            ],
          ),
      ],
      allCtrlRecipient: allControlRecipients,
      config0Setup: config0Setup,
      ffsDir: ffsDirectory,
      ffsRootMode: ffsRootMode,
      ffsFileMode: ffsFileMode,
      ffsUid: ffsUid,
      ffsGid: ffsGid,
      ffsNoDisconnect: ffsNoDisconnect,
      ffsNoInit: ffsNoInit,
      ffsNoMount: ffsNoMount,
    );
  }
}

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
/// [EndpointSender] makes an IN endpoint, an [EndpointReceiver] an OUT one.
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
    deviceToHost: io is EndpointSender,
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

/// The data side of a [CustomEndpoint]. Usable once the function's gadget
/// is registered and the host has enabled the function.
sealed class EndpointIo {
  EndpointIo({this.queueLength = 16});

  /// Transfers queued in the kernel at once. Deeper queues keep the
  /// endpoint busy while Dart catches up.
  final int queueLength;

  /// Maximum packet size negotiated with the host.
  Future<int> get maxPacketSize;

  /// The endpoint address the host sees.
  Future<int> get address;

  /// Stalls the endpoint.
  Future<void> halt();

  /// Clears a stall.
  Future<void> clearHalt();

  /// Cancels pending operations and queued transfers; they throw a
  /// `cancelled` [GadgetException].
  void cancel();
}

/// Sends data to the host on an IN endpoint.
///
/// For throughput, send chunks much larger than the max packet size, such
/// as 16 KiB; [send] queues them and returns, [flush] waits for them.
final class EndpointSender extends EndpointIo {
  EndpointSender({super.queueLength});

  rust.EndpointSender? _native;

  rust.EndpointSender get _io =>
      _native ??
      (throw StateError(
        "the endpoint's function is not part of a registered gadget",
      ));

  /// Queues [data], waiting up to [timeout] for queue space.
  Future<void> send(List<int> data, {Duration? timeout}) =>
      _io.send(data, timeout);

  /// Waits up to [timeout] for queued data to be sent. On timeout, queued
  /// transfers are cancelled.
  Future<void> flush({Duration? timeout}) => _io.flush(timeout);

  /// Sends [data] and waits until it is sent.
  Future<void> sendAndFlush(List<int> data, {Duration? timeout}) async {
    await send(data, timeout: timeout);
    await flush(timeout: timeout);
  }

  /// Sends every chunk of [stream], then flushes.
  Future<void> addStream(Stream<List<int>> stream) async {
    await for (final chunk in stream) {
      await send(chunk);
    }
    await flush();
  }

  @override
  Future<int> get maxPacketSize => _io.maxPacketSize();

  @override
  Future<int> get address => _io.realAddress();

  @override
  Future<void> halt() => _io.halt();

  @override
  Future<void> clearHalt() => _io.clearHalt();

  @override
  void cancel() => _native?.cancel();
}

/// Receives data from the host on an OUT endpoint.
final class EndpointReceiver extends EndpointIo {
  EndpointReceiver({super.queueLength});

  rust.EndpointReceiver? _native;

  rust.EndpointReceiver get _io =>
      _native ??
      (throw StateError(
        "the endpoint's function is not part of a registered gadget",
      ));

  /// Receives one transfer of up to [maxLength] bytes (a multiple of the
  /// max packet size), waiting up to [timeout]. A short packet ends the
  /// transfer early.
  Future<Uint8List> receive({int maxLength = 16384, Duration? timeout}) =>
      _io.receive(maxLength, false, timeout);

  /// Every transfer received, keeping [queueLength] buffers of [chunkSize]
  /// bytes queued so the host never waits on Dart. Cancel the subscription
  /// to stop; queued buffers are cancelled.
  Stream<Uint8List> stream({int chunkSize = 16384}) {
    final io = _io;
    var listening = false;
    late final StreamController<Uint8List> controller;
    Future<void> pump() async {
      while (listening) {
        try {
          final data = await io.receive(chunkSize, true, null);
          if (listening) controller.add(data);
        } on GadgetException catch (e, stack) {
          if (listening) controller.addError(e, stack);
          break;
        }
      }
      if (listening) await controller.close();
    }

    controller = StreamController(
      onListen: () {
        listening = true;
        unawaited(pump());
      },
      onCancel: () {
        listening = false;
        io.cancel();
      },
    );
    return controller.stream;
  }

  @override
  Future<int> get maxPacketSize => _io.maxPacketSize();

  @override
  Future<int> get address => _io.realAddress();

  @override
  Future<void> halt() => _io.halt();

  @override
  Future<void> clearHalt() => _io.clearHalt();

  @override
  void cancel() => _native?.cancel();
}

/// Something that happened to a [CustomFunction].
sealed class CustomEvent {
  const CustomEvent();
}

/// The function was bound to a controller.
final class BindEvent extends CustomEvent {
  const BindEvent();
}

/// The function was unbound from its controller.
final class UnbindEvent extends CustomEvent {
  const UnbindEvent();
}

/// The host selected a configuration with this function: endpoints are
/// usable.
final class EnableEvent extends CustomEvent {
  const EnableEvent();
}

/// The host deselected the configuration, or the device was reset.
final class DisableEvent extends CustomEvent {
  const DisableEvent();
}

/// The bus was suspended.
final class SuspendEvent extends CustomEvent {
  const SuspendEvent();
}

/// The bus resumed.
final class ResumeEvent extends CustomEvent {
  const ResumeEvent();
}

/// A FunctionFS event this version doesn't know.
final class UnknownEvent extends CustomEvent {
  const UnknownEvent(this.code);

  final int code;
}

/// A control request for this function; answer it exactly once.
sealed class ControlRequest extends CustomEvent {
  ControlRequest._(this._function, this._id, this.setup);

  final rust.CustomFunction _function;
  final int _id;

  /// The request.
  final SetupPacket setup;

  /// Rejects the request: the host sees a stall.
  Future<void> halt() => _function.replyHalt(_id);
}

/// A control request whose data goes to the host: answer with [send].
final class ControlInRequest extends ControlRequest {
  ControlInRequest._(super.function, super.id, super.setup) : super._();

  /// Sends the data stage; at most `setup.length` bytes. Returns the number
  /// of bytes sent.
  Future<int> send(List<int> data) => _function.replySend(_id, data);
}

/// A control request whose data comes from the host: accept it with
/// [receive].
final class ControlOutRequest extends ControlRequest {
  ControlOutRequest._(super.function, super.id, super.setup) : super._();

  /// Accepts the request and returns its data stage (`setup.length` bytes).
  Future<Uint8List> receive() => _function.replyReceive(_id);
}
