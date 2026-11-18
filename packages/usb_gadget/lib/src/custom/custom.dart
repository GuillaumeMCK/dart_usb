/// @docImport 'package:usb_gadget/src/rust/api/error.dart';
library;

// Hooks return FutureOr<void> so overrides can be plain `void` methods or
// `async` ones; the event loop awaits either.
// ignore_for_file: avoid_futureor_void

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart'
    show RustOpaqueInterface;
import 'package:meta/meta.dart';
import 'package:usb_gadget/src/function.dart';
import 'package:usb_gadget/src/poll_stream.dart';
import 'package:usb_gadget/src/rust/api.dart' show LocalizedString;
import 'package:usb_gadget/src/rust/api/custom.dart' as rust;
import 'package:usb_gadget/src/rust/api/endpoint.dart' as rust;
import 'package:usb_gadget/src/rust/api/error.dart';
import 'package:usb_gadget/src/rust/api/gadget.dart' show FunctionHandle;
import 'package:usb_models/usb_models.dart';

part 'endpoint.dart';
part 'events.dart';
part 'interface.dart';

/// A function implemented in Dart through FunctionFS.
///
/// Declare its interfaces and endpoints, then subclass it and override the
/// hooks you need:
///
/// ```dart
/// class Echo extends CustomFunction {
///   Echo()
///     : super(
///         interfaces: const [
///           CustomInterface(
///             class_: .vendorSpecific(0, 0),
///             endpoints: [
///               EndpointTemplate(address: .in_(.ep1), config: .bulk()),
///               EndpointTemplate(address: .out(.ep2), config: .bulk()),
///             ],
///           ),
///         ],
///       );
///
///   late final epIn = endpointIn(.ep1);
///   late final epOut = endpointOut(.ep2);
///
///   @override
///   void onEnable() => epOut.stream().listen(epIn.write);
/// }
/// ```
///
/// Control requests reach [onSetup]. The function can be registered again
/// after its gadget is removed; it then starts afresh.
///
/// Requires `CONFIG_USB_CONFIGFS_F_FS`.
class CustomFunction({
  required this.interfaces,
  this.queueLength = 16,
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
}) extends GadgetFunction {
  /// A function with [interfaces]. Each endpoint keeps [queueLength]
  /// transfers queued in the kernel. The FunctionFS settings are rarely
  /// needed.
  this {
    if (queueLength < 1) {
      throw ArgumentError.value(
        queueLength,
        'queueLength',
        'must be at least 1',
      );
    }
    for (final interface in interfaces) {
      for (final template in interface.endpoints) {
        final key = (template.address.direction, template.address.number.value);
        if (_endpoints.containsKey(key)) {
          throw ArgumentError('endpoint ${template.address} is declared twice');
        }
        _endpoints[key] = switch (template.address.direction) {
          .in_ => InEndpoint._(template, queueLength),
          .out => OutEndpoint._(template, queueLength),
        };
      }
    }
  }

  /// The interfaces, in order.
  final List<CustomInterface> interfaces;

  /// Transfers each endpoint keeps queued in the kernel.
  final int queueLength;

  /// Receives control requests for any recipient, not only this function's
  /// interfaces and endpoints.
  final bool allControlRecipients;

  /// Receives control requests while the device is unconfigured.
  final bool config0Setup;

  /// Mounts FunctionFS here instead of a temporary directory.
  final String? ffsDirectory;

  /// Mode of the FunctionFS root directory.
  final int? ffsRootMode;

  /// Mode of the FunctionFS files.
  final int? ffsFileMode;

  /// Owner of the FunctionFS files.
  final int? ffsUid;

  /// Group of the FunctionFS files.
  final int? ffsGid;

  /// Keeps the gadget connected while FunctionFS is closed.
  final bool ffsNoDisconnect;

  /// Doesn't initialize FunctionFS (for an instance set up elsewhere).
  final bool ffsNoInit;

  /// Doesn't mount FunctionFS (for an instance mounted elsewhere).
  final bool ffsNoMount;

  final _endpoints = <(Direction, int), EndpointIo>{};
  rust.CustomFunction? _native;
  CustomFunctionState? _ffsState;
  final _stateChanges = StreamController<void>.broadcast(sync: true);

  rust.CustomFunction get _function =>
      _native ??
      (throw StateError('$runtimeType is not part of a registered gadget'));

  /// The IN endpoint declared with [number].
  InEndpoint endpointIn(EndpointNumber number) =>
      switch (_endpoints[(Direction.in_, number.value)]) {
        final InEndpoint e => e,
        _ => throw ArgumentError('no IN endpoint ${number.value} declared'),
      };

  /// The OUT endpoint declared with [number].
  OutEndpoint endpointOut(EndpointNumber number) =>
      switch (_endpoints[(Direction.out, number.value)]) {
        final OutEndpoint e => e,
        _ => throw ArgumentError('no OUT endpoint ${number.value} declared'),
      };

  /// Where the function is in its life.
  CustomFunctionState get state => switch (_native) {
    null => .unregistered,
    final n when n.state == .removed => .removed,
    _ => _ffsState ?? .registered,
  };

  /// Completes once the function reaches [state], such as
  /// [CustomFunctionState.enabled].
  Future<void> awaitState(
    CustomFunctionState state, {
    Duration? timeout,
  }) async {
    Future<void> wait() async {
      while (this.state != state) {
        await _stateChanges.stream.first;
      }
    }

    await (timeout == null ? wait() : wait().timeout(timeout));
  }

  void _setState(CustomFunctionState? state) {
    _ffsState = state;
    _stateChanges.add(null);
  }

  @override
  String? get path => _native?.path;

  /// Where FunctionFS is mounted. Throws a `notReady` [GadgetException]
  /// until registered.
  String get mountPath => _function.ffsDir;

  /// The number the host sees for this function's interface [index]
  /// (FunctionFS renumbers interfaces in composite gadgets). Throws a
  /// `notReady` [GadgetException] until bound. Doesn't block, so it can be
  /// used in [onSetup] to check `setup.index`.
  int interfaceNumber(int index) => _function.interfaceNumber(index);

  // --- Hooks -----------------------------------------------------------------

  /// The gadget was bound to a controller.
  @protected
  FutureOr<void> onBind() {}

  /// The gadget was unbound from its controller.
  @protected
  FutureOr<void> onUnbind() {}

  /// The host enabled the function: endpoints are usable. Start reading
  /// and writing here.
  @protected
  FutureOr<void> onEnable() {}

  /// The host disabled the function or reset the device; endpoint streams
  /// end.
  @protected
  FutureOr<void> onDisable() {}

  /// The bus was suspended.
  @protected
  FutureOr<void> onSuspend() {}

  /// The bus resumed.
  @protected
  FutureOr<void> onResume() {}

  /// A control request arrived. Answer it with
  /// [ControlInRequest.send], [ControlOutRequest.receive],
  /// [ControlOutRequest.ack] or [ControlRequest.halt] within 4.5 seconds;
  /// a request still unanswered when this completes is stalled. The default
  /// stalls everything.
  @protected
  FutureOr<void> onSetup(ControlRequest request) {}

  // --- Registration --------------------------------------------------------

  @override
  @internal
  FunctionHandle createHandle() {
    if (_native case final native? when native.state != .removed) {
      return native.handle();
    }
    // First registration, or a new one after removal: FunctionFS files are
    // single-use, so build everything again.
    _native?.dispose();
    final native = rust.CustomFunction(spec: _spec());
    var index = 0;
    for (final interface in interfaces) {
      for (final template in interface.endpoints) {
        switch (_endpoints[(
          template.address.direction,
          template.address.number.value,
        )]!) {
          case final InEndpoint e:
            e._attach(native.takeSender(index));
          case final OutEndpoint e:
            e._attach(native.takeReceiver(index));
        }
        index++;
      }
    }
    _native = native;
    _setState(null);
    unawaited(_run(native));
    return native.handle();
  }

  /// Delivers the native function's events to the hooks until it closes.
  Future<void> _run(rust.CustomFunction native) async {
    native.setListening(true);
    while (identical(native, _native)) {
      final rust.CustomEvent? event;
      try {
        event = await native.nextEvent(const Duration(milliseconds: 200));
      } on GadgetException {
        break; // The gadget was removed.
      }
      if (event == null) continue;
      await _dispatch(native, event);
    }
    if (identical(native, _native)) _setState(.removed);
  }

  Future<void> _dispatch(rust.CustomFunction native, rust.CustomEvent e) async {
    try {
      switch (e.kind) {
        case .bind:
          _setState(.bound);
          await onBind();
        case .unbind:
          _setState(.registered);
          await onUnbind();
        case .enable:
          _setState(.enabled);
          await onEnable();
        case .disable:
          _setState(.disabled);
          await onDisable();
        case .suspend:
          _setState(.suspended);
          await onSuspend();
        case .resume:
          _setState(.enabled);
          await onResume();
        case .setupDeviceToHost || .setupHostToDevice:
          final setup = SetupPacket.parse(e.setup);
          final request = e.kind == .setupDeviceToHost
              ? ControlInRequest._(native, e.id, setup)
              : ControlOutRequest._(native, e.id, setup);
          try {
            await onSetup(request);
          } finally {
            if (!request.isAnswered) await request.halt();
          }
        case .unknown:
      }
    } on Object catch (error, stack) {
      // A failing hook mustn't stop event delivery.
      Zone.current.handleUncaughtError(error, stack);
    }
  }

  rust.CustomSpec _spec() {
    final associations = <InterfaceAssociation, int>{};
    return rust.CustomSpec(
      interfaces: [
        for (final i in interfaces)
          rust.InterfaceSpec(
            class_: classCodes(i.class_),
            name: _localized(i.name, i.names),
            endpoints: [
              for (final e in i.endpoints) _endpointSpec(e, queueLength),
            ],
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
                  descriptorType: d.bDescriptorType,
                  data: d.toBytes().sublist(2),
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

List<LocalizedString> _localized(String name, Map<LanguageId, String> names) =>
    [
      for (final MapEntry(key: language, value: text) in {
        LanguageId.enUS: name,
        ...names,
      }.entries)
        LocalizedString(language: language.value, text: text),
    ];
