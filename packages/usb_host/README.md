# usb_host

Low-level access to USB devices for Dart and Flutter, powered by the Rust
crate [nusb](https://github.com/kevinmehall/nusb) through
[flutter_rust_bridge](https://cjycode.com/flutter_rust_bridge/) and Dart
[build hooks](https://dart.dev/tools/hooks).

nusb talks to the OS directly (IOKit on macOS, usbfs on Linux and Android,
WinUSB on Windows), with no libusb. usb_host exposes its functions and types to
Dart: Rust handles become Dart objects, descriptors and settings become
plain Dart classes and enums, and every blocking call runs on a Rust worker
thread and returns a `Future`.

## Example

```dart
import 'package:usb_host/usb_host.dart';

Future<void> main() async {
  final usb = await Usb.initialize();

  final info = await usb.findDevice([const DeviceSelector(vendorId: 0x1234, productId: 0x5678)]);
  if (info == null) return print('device not connected');
  print(info); // DeviceInfo(1234:5678 "Widget" by "ACME", bus 00, address 3)

  final device = await info.open();
  final interface = await device.claimInterface(0);

  // Control requests come from package:usb_models (re-exported); value and
  // index default to 0, the timeout to 1 second.
  await interface.controlOut(
    const ControlOut(type: .vendor, recipient: .device, request: 0x10, data: [1, 2, 3, 4]),
  );

  // Buffered bulk IO.
  final writer = interface.endpointOut(0x01).writer(transferSize: 4096);
  await writer.writeAll([0x00, 0xff]);
  await writer.flush();

  final reader = interface.endpointIn(0x81).reader(
    transferSize: 4096,
    numTransfers: 4,
    readTimeout: const Duration(seconds: 1),
  );
  final response = await reader.readExact(64);
  print(response);
}
```

`example/` is a Flutter app that lists devices and keeps the list current
with hotplug events; `tool/smoke.dart` prints everything usb_host can read
about the attached devices.

## Guide

**Errors.** Every failure throws a `UsbException` with a `kind`, a message
and the OS error code:

```dart
try {
  await device.claimInterface(0);
} on UsbException catch (e) {
  if (e.kind == UsbErrorKind.busy) print('another driver owns it: $e');
}
```

**Hotplug.** `watchDevices()` is a normal Dart stream of the sealed class
`HotplugEvent`, so a `switch` over it is exhaustive. Cancel the
subscription to stop watching. Listen before listing so no device is missed:

```dart
final devices = <DeviceId, DeviceInfo>{};
final subscription = usb.watchDevices().listen((event) {
  switch (event) {
    case HotplugConnected(:final device):
      devices[device.id] = device;
    case HotplugDisconnected(:final id):
      devices.remove(id);
  }
});
for (final device in await usb.listDevices()) {
  devices[device.id] = device;
}
```

**Descriptors and strings.** Descriptors are cached when the device is
opened; string requests go to the device:

```dart
for (final config in device.configurations) {
  for (final interface in config.interfaces) {
    print(interface.altSettings.first.endpoints);
  }
}
final product = device.deviceDescriptor.product;
if (product.hasString) print(await device.getStringDescriptor(index: product.value));
```

**Low-level transfers.** For full throughput, keep several transfers in
flight and collect them in order:

```dart
final endpoint = interface.endpointIn(0x81);
while (endpoint.pending < 8) {
  endpoint.submit(16 * endpoint.maxPacketSize);
}
while (true) {
  final completion = await endpoint.nextComplete();
  if (completion!.error case final error?) throw error;
  handle(completion.data);
  endpoint.submit(16 * endpoint.maxPacketSize);
}
```

**Lifetimes.** Devices, interfaces and endpoints are released when garbage
collected; call `dispose()` to release one immediately. A device stays open
while an interface claimed from it is alive. Methods that wait (reads,
writes, `nextComplete`) lock their endpoint, so a long wait blocks other
calls on it, including `cancelAll`; pass timeouts to bound waits.

## API

The API mirrors nusb's:

| nusb | usb_host |
| --- | --- |
| (no context object) | `Usb`, from `await Usb.initialize()` |
| `list_devices()`, `list_buses()`, `request_device()` | `usb.listDevices()`, `usb.listBuses()`, `usb.findDevice()` |
| `watch_devices()`, `HotplugEvent` | `usb.watchDevices()`: a `Stream` of the sealed `HotplugEvent` (`HotplugConnected`, `HotplugDisconnected`) |
| `DeviceInfo` | `DeviceInfo`: getters for the cached fields, `matches()`, `open()` |
| `Device` | `Device`: descriptors, `claimInterface`, `setConfiguration`, `reset`, `getStringDescriptor`, control transfers |
| `Interface` | `Interface`: alternate settings, control transfers, `endpointIn` / `endpointOut` |
| `Endpoint<Bulk \| Interrupt, In \| Out>` | `InEndpoint` / `OutEndpoint`, with `submit`, `nextComplete`, `transfer`, `cancelAll`, `clearHalt` |
| `io::EndpointRead` / `EndpointWrite` | `EndpointReader` (`read`, `readExact`, `readPacket`) / `EndpointWriter` (`writeAll`, `flush`, `flushEnd`) |
| `Error`, `TransferError`, ... | `UsbException`, with a `UsbErrorKind` and the OS error code |

## How it's built

usb_host is a plain Dart package with a [build hook](https://dart.dev/tools/hooks)
(`hook/build.dart`). When you run, test or build a program that uses usb_host,
with `dart` or `flutter`, the hook compiles the Rust crate in `rust/` and
the SDK bundles the library: as a framework in macOS apps, next to the
executable elsewhere. This is the mechanism Flutter
[recommends for native code](https://docs.flutter.dev/interop/bind-native-code)
since Flutter 3.38, so there is no CocoaPods podspec, Swift package, CMake or
Gradle file, and apps work whether they use Swift Package Manager or
CocoaPods.

Building needs [rustup](https://rustup.rs). The first build installs the
Rust version pinned in `rust/rust-toolchain.toml` and compiles nusb, which
takes a minute; later builds are incremental.

`Usb.initialize()` finds the library through its code asset, so it works
under `dart run`, `dart test` and Flutter alike.

## Platform setup

* **macOS:** sandboxed apps need the `com.apple.security.device.usb`
  entitlement (see `example/macos/Runner/*.entitlements`). Devices with a
  kernel driver can't be claimed. Vendor-class devices may need
  `setConfiguration(1)` after opening.
* **Linux:** your user needs write access to `/dev/bus/usb/*`; add a
  [udev rule](https://www.reactivated.net/writing_udev_rules.html) such as
  `SUBSYSTEM=="usb", ATTRS{idVendor}=="1234", MODE="0660", GROUP="plugdev"`.
* **Windows:** the device or interface must use the WinUSB driver (a WCID
  descriptor, or [Zadig](https://zadig.akeo.ie/)). WinUSB can't set
  configurations or reset devices, and control transfers go through a
  claimed `Interface`.
* **Android:** nusb only supports devices opened from a file descriptor,
  which usb_host doesn't bridge yet.

## Development

The Rust API lives in `rust/src/api/`. After changing it, regenerate the
Dart bindings in `lib/src/rust/` (this also runs `build_runner` for the
freezed classes, such as `HotplugEvent`); `lib/src/usb.dart` is the
hand-written entry point on top of them:

```sh
flutter_rust_bridge_codegen generate
```

Tests are read-only and run against the attached hardware:

```sh
dart test                                          # plain Dart
cd example && flutter test integration_test -d macos   # Flutter app
dart run tool/smoke.dart                           # prints what it finds
```

## License

usb_host is licensed under the [MIT license](LICENSE).

The native library it builds includes [nusb](https://github.com/kevinmehall/nusb)
(MIT or Apache-2.0) and [flutter_rust_bridge](https://github.com/fzyzcjy/flutter_rust_bridge)
(MIT), among other Rust crates; apps distributing it should include their
license notices.
