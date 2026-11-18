# usb_models

USB standard types and descriptors for Dart, shared by
[`usb_host`](../usb_host) (host side: talk to devices) and
[`usb_gadget`](../usb_gadget) (device side: be a device).

- Chapter 9 types: `Direction`, `TransferType`, `RequestType`, `Recipient`,
  `StandardRequest`, `Speed`, `EndpointAddress`, `EndpointAttributes`,
  `MaxPacketSize`, `Class`, `Id`, `LanguageId`, ...
- Descriptors you can **build and serialize** (gadgets) and **parse** (hosts):
  `DeviceDescriptor`, `ConfigurationDescriptor` with its interface /
  alternate setting / endpoint tree, `InterfaceDescriptor`,
  `EndpointDescriptor`, string descriptors, HID descriptors.
- Control requests: `SetupPacket`, `ControlIn`, `ControlOut`.

```dart
import 'package:usb_models/usb_models.dart';

final config = ConfigurationDescriptor.parse(bytes);
for (final alt in config.altSettings) {
  print('${alt.interfaceNumber} ${alt.class_} ${alt.endpoints}');
}

const request = ControlIn(type: .vendor, recipient: .device, request: 0x30, length: 64);
print(request.setup.toBytes()); // the 8-byte SETUP packet
```

Pure Dart, no platform dependencies.

## License

Apache 2.0: these types come from `usb_gadget`, a port of the Apache-2.0
[usb-gadget](https://github.com/surban/usb-gadget) crate.
