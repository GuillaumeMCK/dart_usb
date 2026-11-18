# usb_gadget

[![Apache 2.0 license](https://img.shields.io/badge/License-Apache%202.0-blue.svg)](https://opensource.org/licenses/Apache-2.0)

Turn a Linux device with a USB device controller (UDC) into a USB
peripheral: keyboard, storage, network adapter, serial port, sound card,
camera, or your own protocol implemented in Dart.

It bridges the Rust [usb-gadget](https://github.com/surban/usb-gadget) crate
with [flutter_rust_bridge](https://cjycode.com/flutter_rust_bridge/) and Dart
build hooks: configfs setup and FunctionFS I/O (with the kernel's
asynchronous I/O, several transfers in flight) run in Rust, while gadgets,
functions and control requests are plain Dart. USB types and descriptors
come from [`usb_models`](../usb_models) (re-exported), shared with the
host-side [`dusb`](../dusb).

Boards with a UDC include the Raspberry Pi 4/5 and Zero 2 W; most PCs have
none. Linux's `dummy_hcd` module adds a virtual one for testing.

## Requirements

- Linux with configfs gadget support (`CONFIG_USB_CONFIGFS`), run as root.
- A Rust toolchain ([rustup](https://rustup.rs)): the build hook compiles the
  bridge on first build. No C libraries are needed.

```sh
sudo modprobe libcomposite
sudo mount -t configfs none /sys/kernel/config  # if not already mounted
```

## Kernel functions

The kernel implements the function; you configure it and use the device it
creates.

```dart
import 'package:usb_gadget/usb_gadget.dart';

Future<void> main() async {
  final serial = SerialFunction(); // CDC ACM
  final gadget = Gadget(
    id: const Id(vendor: 0x1209, product: 0x0001),
    strings: {.enUS: const GadgetStrings(manufacturer: 'ACME', product: 'Widget', serialNumber: '0001')},
    configs: [Config(description: 'Serial', functions: [serial])],
  );

  final registered = await gadget.bind(await defaultUdc());
  print('host-facing serial port: ${serial.devicePath}'); // /dev/ttyGS0
  // ...
  await registered.remove();
}
```

| Function | Class | Kernel option |
| --- | --- | --- |
| HID | `HidFunction` | `CONFIG_USB_CONFIGFS_F_HID` |
| Mass storage | `MassStorageFunction` | `CONFIG_USB_CONFIGFS_MASS_STORAGE` |
| Network (ECM, EEM, NCM, RNDIS) | `NetFunction` | `CONFIG_USB_CONFIGFS_{ECM,ECM_SUBSET,EEM,NCM,RNDIS}` |
| Serial (ACM, generic) | `SerialFunction` | `CONFIG_USB_CONFIGFS_{ACM,SERIAL}` |
| MIDI | `MidiFunction` | `CONFIG_USB_CONFIGFS_F_MIDI` |
| Printer | `PrinterFunction` | `CONFIG_USB_CONFIGFS_F_PRINTER` |
| Audio (UAC1, UAC2) | `AudioFunction.uac1` / `.uac2` | `CONFIG_USB_CONFIGFS_F_UAC{1,2}` |
| Video (UVC) | `VideoFunction` | `CONFIG_USB_CONFIGFS_F_UVC` |
| Loopback, source/sink | `LoopbackFunction`, `SourceSinkFunction` | `CONFIG_USB_ZERO` |
| Any other driver | `OtherFunction` | |

## Custom functions

A `CustomFunction` is implemented in Dart through FunctionFS
(`CONFIG_USB_CONFIGFS_F_FS`). Endpoints are declared with an
`EndpointSender` (IN, to the host) or `EndpointReceiver` (OUT, from the
host); control requests arrive as events to answer.

```dart
final tx = EndpointSender(), rx = EndpointReceiver();
final echo = CustomFunction([
  CustomInterface(
    const Class.vendorSpecific(0, 0),
    name: 'echo',
    endpoints: [CustomEndpoint.bulk(tx), CustomEndpoint.bulk(rx)],
  ),
]);

final registered = await Gadget(
  id: const Id(vendor: 0x1209, product: 0x0001),
  configs: [Config(functions: [echo])],
).bind(await defaultUdc());

await for (final event in echo.events) {
  switch (event) {
    case EnableEvent():
      // Keeps 16 receive buffers queued; sends each chunk back.
      rx.stream().asyncMap(tx.sendAndFlush).listen(null);
    case ControlInRequest(:final setup) when setup.type == .vendor:
      await event.send([1, 2, 3]);
    case final ControlRequest request:
      await request.halt(); // stall what we don't handle
    default:
  }
}
```

Each control request must be answered once: `send` (IN), `receive` (OUT) or
`halt`. Unanswered requests are stalled after 4.5 seconds.

## Examples

See [example/](example): a keyboard, a gamepad implemented as a custom
function, a USB drive, and a bulk echo gadget with a `dusb` host program.

## Testing

`test/models_test.dart` runs anywhere. `test/native_test.dart` loads the
native library on any Linux machine. `test/gadget_test.dart` registers
gadgets on the virtual `dummy_hcd` controller and talks to them with `dusb`
on the same machine:

```sh
sudo modprobe dummy_hcd libcomposite
sudo dart test test/gadget_test.dart
```

## Regenerating the bindings

The Rust API lives in `rust/src/api`. Regenerate the Dart side with
`flutter_rust_bridge_codegen generate`. The crate only builds for Linux, so
on another OS point cargo at a Linux target, with a C cross-compiler for
that target (used by a dependency's build script):

```sh
CARGO_BUILD_TARGET=aarch64-unknown-linux-gnu \
CC_aarch64_unknown_linux_gnu=<linux cross C compiler> \
  flutter_rust_bridge_codegen generate
```

## Android

The crate supports Android and the bridge is built for Android targets, but
running a Dart program on a rooted phone with this 2.0 release is untested.

## Credits

- [usb-gadget](https://github.com/surban/usb-gadget) by Sebastian Urban, which
  does the work underneath.
- [python-functionfs](https://github.com/vpelletier/python-functionfs)
- [Linux USB gadget API](https://www.kernel.org/doc/html/latest/driver-api/usb/gadget.html)
