import 'dart:async';

import 'package:usb_models/usb_models.dart';

import 'loader.dart';
import 'rust/api/udc.dart' as rust;

/// The USB device controllers (UDCs) of this system.
Future<List<rust.Udc>> udcs() async {
  await ensureInitialized();
  return rust.udcs();
}

/// The system's only, or first, USB device controller.
///
/// Throws a `notFound` [GadgetException] if there is none: the board has no
/// device-capable USB port, or its driver isn't loaded.
Future<rust.Udc> defaultUdc() async {
  await ensureInitialized();
  return rust.defaultUdc();
}

Speed _speed(int code) => switch (code) {
  1 => .lowSpeed,
  2 => .fullSpeed,
  3 => .highSpeed,
  4 => .superSpeed,
  5 => .superSpeedPlus,
  _ => .unknown,
};

/// Speeds as `usb_models` types, and waiting for a state.
extension UdcModels on rust.Udc {
  /// Speed of the current connection; [Speed.unknown] when not connected.
  Speed get currentSpeed => _speed(rawCurrentSpeed());

  /// The fastest speed the controller supports.
  Speed get maxSpeed => _speed(rawMaxSpeed());

  /// Completes once the controller reaches [state], such as
  /// [rust.UdcState.configured] once the host has set a configuration.
  ///
  /// sysfs has no change notification for this, so the state is polled
  /// every [interval]. Throws a [TimeoutException] after [timeout].
  Future<void> waitForState(
    rust.UdcState state, {
    Duration? timeout,
    Duration interval = const Duration(milliseconds: 50),
  }) async {
    final deadline = timeout == null ? null : DateTime.now().add(timeout);
    while (this.state() != state) {
      if (deadline != null && DateTime.now().isAfter(deadline)) {
        throw TimeoutException(
          'UDC $name did not reach ${state.name}',
          timeout,
        );
      }
      await Future<void>.delayed(interval);
    }
  }
}
