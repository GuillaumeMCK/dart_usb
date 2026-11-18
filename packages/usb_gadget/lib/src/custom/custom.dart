/// @docImport 'package:usb_gadget/src/rust/api/error.dart';
library;

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
import 'package:usb_gadget/src/rust/api/function.dart' show FunctionState;
import 'package:usb_gadget/src/rust/api/gadget.dart' show FunctionHandle;
import 'package:usb_models/usb_models.dart';

part 'endpoint.dart';
part 'events.dart';
part 'interface.dart';

/// A function implemented in Dart through FunctionFS: its interfaces and
/// endpoints are declared here, its control requests arrive as [events],
/// and its data moves through [InEndpoint]s and [OutEndpoint]s.
///
/// ```dart
/// final ep1 = InEndpoint(), ep2 = OutEndpoint();
/// final function = CustomFunction([
///   CustomInterface(
///     const Class.vendorSpecific(0, 0),
///     name: 'echo',
///     endpoints: [CustomEndpoint.bulk(ep1), CustomEndpoint.bulk(ep2)],
///   ),
/// ]);
/// ```
///
/// A function can be registered again after its gadget is removed; it then
/// starts afresh, and streams from the previous registration end.
///
/// Requires `CONFIG_USB_CONFIGFS_F_FS`.
final class CustomFunction(
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
}) extends GadgetFunction {
  /// A custom function with [interfaces]; the FunctionFS settings are
  /// rarely needed.
  this;

  /// The interfaces, in order.
  final List<CustomInterface> interfaces;

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

  rust.CustomFunction? _native;
  Completer<rust.CustomFunction>? _nextNative;
  var _listening = false;

  /// The current native function, or the next one if there is none yet or
  /// the current one's gadget was removed.
  Future<rust.CustomFunction> get _live async {
    if (_native case final native? when native.state != .removed) return native;
    return (_nextNative ??= Completer()).future;
  }

  rust.CustomFunction get _function =>
      _native ??
      (throw StateError('CustomFunction is not part of a registered gadget'));

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
      for (final endpoint in interface.endpoints) {
        switch (endpoint.io) {
          case final InEndpoint e:
            e._attach(native.takeSender(index));
          case final OutEndpoint e:
            e._attach(native.takeReceiver(index));
        }
        index++;
      }
    }
    _native = native;
    _nextNative?.complete(native);
    _nextNative = null;
    return native.handle();
  }

  @override
  FunctionState get state => _native?.state ?? .unregistered;

  @override
  String? get path => _native?.path;

  /// Where FunctionFS is mounted. Throws a `notReady` [GadgetException]
  /// until registered.
  String get mountPath => _function.ffsDir;

  /// The interface number the host sees for this function's interface
  /// [index]. Throws a `notReady` [GadgetException] until bound.
  ///
  /// Doesn't block, so it can be used while answering a control request,
  /// for instance to check `setup.index`.
  int interfaceNumber(int index) => _function.interfaceNumber(index);

  /// Lifecycle events and control requests. Can be listened to before the
  /// gadget is registered (or registered again after removal); lifecycle
  /// events that happened before listening are delivered first.
  ///
  /// Answer every [ControlRequest] promptly: unanswered ones are stalled
  /// after 4.5 seconds, before the host gives up. While nobody listens,
  /// control requests are stalled at once.
  ///
  /// One listener at a time. The stream ends when the gadget is removed.
  Stream<CustomEvent> get events =>
      pollStream<rust.CustomFunction, CustomEvent>(
        native: _live,
        start: (native) {
          if (_listening) {
            throw StateError('CustomFunction.events already has a listener');
          }
          _listening = true;
          native.setListening(true);
        },
        stop: (native) {
          _listening = false;
          native.setListening(false);
        },
        next: (native) async =>
            switch (await native.nextEvent(const Duration(milliseconds: 200))) {
              final e? => _event(native, e),
              null => null,
            },
      );

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

List<LocalizedString> _localized(String name, Map<LanguageId, String> names) =>
    [
      for (final MapEntry(key: language, value: text) in {
        LanguageId.enUS: name,
        ...names,
      }.entries)
        LocalizedString(language: language.value, text: text),
    ];
