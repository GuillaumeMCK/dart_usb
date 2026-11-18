# usb

USB for Dart and Flutter, both sides of the cable, built on one set of
models.

| Package | Side | What it does |
| --- | --- | --- |
| [`usb_models`](packages/usb_models) | both | USB standard (chapter 9) and HID types and descriptors: parse and build them. Pure Dart. |
| [`dusb`](packages/dusb) | host | List, open and talk to USB devices on macOS, Linux and Windows, bridging the Rust [nusb](https://github.com/kevinmehall/nusb) crate. |
| [`usb_gadget`](packages/usb_gadget) | device | Make a Linux board with a USB device controller act as a USB device (HID, mass storage, network, custom functions in Dart), bridging the Rust [usb-gadget](https://github.com/surban/usb-gadget) crate. |

Both `dusb` and `usb_gadget` re-export `usb_models`, so a descriptor built
for a gadget and one read from a device are the same Dart type:

```dart
// usb_gadget: describe an endpoint.
final built = EndpointDescriptor(
  address: const EndpointAddress.in_(.ep1),
  attributes: const .bulk(),
  maxPacketSize: const .highSpeedBulk(),
);

// dusb: read it back from the device.
final parsed = device.activeConfiguration().altSettings.first.endpoints.first;
assert(parsed.address == built.address);
```

## Development

This is a [pub workspace](https://dart.dev/tools/pub/workspaces):

```sh
dart pub get                          # resolves every package
dart analyze
(cd packages/usb_models && dart test) # pure Dart
(cd packages/dusb && dart test)       # read-only, against attached hardware
```

`dusb` and `usb_gadget` compile their Rust crates through build hooks, so
a Rust toolchain ([rustup](https://rustup.rs)) is needed. `usb_gadget`'s
end-to-end tests run on Linux with the virtual `dummy_hcd` controller, and
use `dusb` as the host:

```sh
sudo modprobe dummy_hcd libcomposite
(cd packages/usb_gadget && sudo dart test test/gadget_test.dart)
```

The Flutter example in `packages/dusb/example` resolves on its own
(`flutter pub get`).

## Licenses

`dusb` is MIT. `usb_gadget` and `usb_models` are Apache 2.0, like the
[usb-gadget](https://github.com/surban/usb-gadget) crate `usb_gadget`
bridges and `usb_models` derives from.
