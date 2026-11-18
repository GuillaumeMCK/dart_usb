import 'dart:async';

import 'package:usb_host/src/loader.dart';
import 'package:usb_host/src/rust/api/enumeration.dart' as rust;
import 'package:usb_host/src/rust/frb_generated.dart';

/// A device was connected; see [rust.HotplugEvent].
typedef HotplugConnected = rust.HotplugEvent_Connected;

/// A device was disconnected; see [rust.HotplugEvent].
typedef HotplugDisconnected = rust.HotplugEvent_Disconnected;

/// Access to the USB devices of this system: the entry point to usb_host.
///
/// ```dart
/// final usb = await Usb.initialize();
/// for (final device in await usb.listDevices()) {
///   print(device);
/// }
/// ```
final class Usb._() {
  static Future<Usb>? _instance;

  /// Loads the native library and returns the shared [Usb] instance.
  ///
  /// Safe to call any number of times; the library is loaded once.
  static Future<Usb> initialize() => _instance ??= _load();

  static Future<Usb> _load() async {
    try {
      await RustLib.init(externalLibrary: usbHostExternalLibrary());
      return Usb._();
    } catch (_) {
      _instance = null; // Let a later call retry.
      rethrow;
    }
  }

  /// The connected USB devices.
  Future<List<rust.DeviceInfo>> listDevices() => rust.listDevices();

  /// The system's USB buses (host controllers).
  Future<List<rust.BusInfo>> listBuses() => rust.listBuses();

  /// The first device matching any of [selectors] (any device by default),
  /// or `null` if none is connected.
  Future<rust.DeviceInfo?> findDevice([
    List<rust.DeviceSelector> selectors = const [rust.DeviceSelector()],
  ]) => rust.requestDevice(selectors);

  /// Devices connecting and disconnecting, from the moment this stream is
  /// listened to. Cancel the subscription to stop watching.
  ///
  /// To keep a list of connected devices, listen first and then call
  /// [listDevices], so a device connected in between isn't missed:
  ///
  /// ```dart
  /// usb.watchDevices().listen((event) {
  ///   switch (event) {
  ///     case HotplugConnected(:final device): devices[device.id] = device;
  ///     case HotplugDisconnected(:final id): devices.remove(id);
  ///   }
  /// });
  /// ```
  ///
  /// On Windows, the interfaces of a composite device might not be ready
  /// when it is reported connected; retry opening after a short delay.
  Stream<rust.HotplugEvent> watchDevices() {
    // Polls with a short timeout so cancelling takes effect promptly; the
    // native watch is released as soon as the subscription ends.
    const poll = Duration(milliseconds: 250);
    var active = true;
    late final StreamController<rust.HotplugEvent> controller;
    controller = StreamController(
      onListen: () async {
        try {
          final watch = await rust.openHotplugWatch();
          try {
            while (active) {
              final event = await watch.nextEvent(timeout: poll);
              if (event != null && active) controller.add(event);
            }
          } finally {
            watch.dispose();
          }
        } catch (e, st) {
          if (active) controller.addError(e, st);
        } finally {
          await controller.close();
        }
      },
      onCancel: () => active = false,
    );
    return controller.stream;
  }
}
