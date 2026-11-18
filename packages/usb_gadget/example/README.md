# Examples

Run the device-side examples as root on a Linux board with a USB device
controller (or with the `dummy_hcd` module for a virtual one).

- [keyboard.dart](keyboard.dart): types text through the kernel HID function.
- [gamepad.dart](gamepad.dart): a HID gamepad implemented in Dart with a
  custom function, answering the HID control requests itself.
- [mass_storage.dart](mass_storage.dart): serves disk images as a USB drive.
- [ping/pong.dart](ping/pong.dart) with [ping/ping.dart](ping/ping.dart): a
  bulk echo function, and a host program using `dusb` to exercise it.
