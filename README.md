# usb

USB for Dart and Flutter, both sides of the cable, built on one set of
models.

| Package | Side | What it does |
| --- | --- | --- |
| [`usb_models`](packages/usb_models) | both | USB standard (chapter 9) and HID types and descriptors: parse and build them. Pure Dart. |
| [`dusb`](packages/dusb) | host | List, open and talk to USB devices on macOS, Linux and Windows, bridging the Rust [nusb](https://github.com/kevinmehall/nusb) crate. |
| [`usb_gadget`](packages/usb_gadget) | device | Make a Linux board with a USB device controller act as a USB device (HID, mass storage, network, custom FunctionFS). |

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

`usb_gadget`'s tests need a Linux board with a USB device controller. The
Flutter example in `packages/dusb/example` resolves on its own
(`flutter pub get`).

## Licenses

`dusb` is MIT. `usb_gadget` and `usb_models` are Apache 2.0, like the
[usb-gadget](https://github.com/surban/usb-gadget) crate they derive from.
