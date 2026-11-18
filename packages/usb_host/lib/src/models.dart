/// @docImport 'package:usb_host/src/rust/api/error.dart';
library;

import 'dart:typed_data';

import 'package:usb_host/src/rust/api/device.dart';
import 'package:usb_host/src/rust/api/enumeration.dart';
import 'package:usb_models/usb_models.dart';

/// Reads the speed codes the Rust side reports (see `speed_code`).
Speed? _speed(int? code) => switch (code) {
  1 => .lowSpeed,
  2 => .fullSpeed,
  3 => .highSpeed,
  4 => .superSpeed,
  5 => .superSpeedPlus,
  _ => null,
};

/// Typed views of a [DeviceInfo], using the shared `usb_models` types.
extension DeviceInfoModels on DeviceInfo {
  /// Connection speed, if the OS reports it.
  Speed? get speed => _speed(rawSpeed);

  /// Device class, subclass and protocol.
  Class get class_ => Class.raw(deviceClass, subclass, protocol);
}

/// Typed views of an [InterfaceInfo].
extension InterfaceInfoModels on InterfaceInfo {
  /// Interface class, subclass and protocol of the first alternate setting.
  Class get class_ => Class.raw(interfaceClass, subclass, protocol);
}

/// Descriptors and control transfers of an open [Device], using the shared
/// `usb_models` types.
extension DeviceModels on Device {
  /// The device descriptor. Cached; doesn't perform IO.
  DeviceDescriptor get deviceDescriptor =>
      DeviceDescriptor.parse(rawDeviceDescriptor);

  /// Every configuration of the device. Cached; doesn't perform IO.
  List<ConfigurationDescriptor> get configurations => [
    for (final bytes in rawConfigurations) ConfigurationDescriptor.parse(bytes),
  ];

  /// The active configuration. Throws a `notConfigured` [UsbException] if
  /// the device is unconfigured.
  ConfigurationDescriptor activeConfiguration() =>
      ConfigurationDescriptor.parse(rawActiveConfiguration());

  /// Connection speed, if known.
  Speed? get speed => _speed(rawSpeed);

  /// Reads [request]'s data stage from the default control endpoint;
  /// [timeout] defaults to 1 second.
  ///
  /// Not supported on Windows: claim an interface and use
  /// [InterfaceModels.controlIn].
  Future<Uint8List> controlIn(ControlIn request, {Duration? timeout}) =>
      controlInRaw(
        requestType: request.setup.requestType,
        request: request.request,
        value: request.value,
        index: request.index,
        length: request.length,
        timeout: timeout,
      );

  /// Sends [request] on the default control endpoint; [timeout] defaults to
  /// 1 second.
  ///
  /// Not supported on Windows: claim an interface and use
  /// [InterfaceModels.controlOut].
  Future<void> controlOut(ControlOut request, {Duration? timeout}) =>
      controlOutRaw(
        requestType: request.setup.requestType,
        request: request.request,
        value: request.value,
        index: request.index,
        data: request.data,
        timeout: timeout,
      );
}

/// Descriptors and control transfers of a claimed [Interface], using the
/// shared `usb_models` types.
extension InterfaceModels on Interface {
  /// Every alternate setting of this interface in the active configuration.
  List<InterfaceAltSetting> get descriptors => [
    for (final bytes in rawDescriptors) InterfaceAltSetting.parse(bytes),
  ];

  /// The current alternate setting, with its endpoints.
  InterfaceAltSetting? get descriptor => switch (rawDescriptor) {
    final bytes? => InterfaceAltSetting.parse(bytes),
    null => null,
  };

  /// Reads [request]'s data stage; [timeout] defaults to 1 second.
  ///
  /// On Windows, for [Recipient.interface], the low byte of `index` must be
  /// this interface's number.
  Future<Uint8List> controlIn(ControlIn request, {Duration? timeout}) =>
      controlInRaw(
        requestType: request.setup.requestType,
        request: request.request,
        value: request.value,
        index: request.index,
        length: request.length,
        timeout: timeout,
      );

  /// Sends [request]; [timeout] defaults to 1 second. Same Windows
  /// restriction as [controlIn].
  Future<void> controlOut(ControlOut request, {Duration? timeout}) =>
      controlOutRaw(
        requestType: request.setup.requestType,
        request: request.request,
        value: request.value,
        index: request.index,
        data: request.data,
        timeout: timeout,
      );
}
