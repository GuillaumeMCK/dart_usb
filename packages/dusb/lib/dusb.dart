/// Cross-platform low-level access to USB devices, bridging the Rust
/// [nusb](https://github.com/kevinmehall/nusb) crate.
///
/// Start from [Usb.initialize]:
///
/// ```dart
/// import 'package:dusb/dusb.dart';
///
/// Future<void> main() async {
///   final usb = await Usb.initialize();
///   for (final device in await usb.listDevices()) {
///     print(device); // DeviceInfo(0bda:8153 "USB LAN" by "Realtek", ...)
///   }
/// }
/// ```
library;

export 'src/rust/api/device.dart';
export 'src/rust/api/endpoint.dart';
export 'src/rust/api/enumeration.dart'
    show BusInfo, DeviceId, DeviceInfo, DeviceSelector, HotplugEvent, InterfaceInfo;
export 'src/rust/api/error.dart';
export 'src/rust/api/types.dart';
export 'src/models.dart';
export 'src/usb.dart';
export 'package:usb_models/usb_models.dart';
