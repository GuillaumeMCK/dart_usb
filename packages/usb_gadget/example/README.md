# Examples

A package of its own, so each example builds with `dart build cli`. Build as
yourself on a Linux board with a USB device controller, then run the result
as root:

```sh
dart build cli -t bin/pong.dart -o build/pong
sudo build/pong/bundle/bin/pong
```

(`sudo dart run` doesn't work: sudo resets `PATH` and `HOME`, so the build
hooks can't find your Rust toolchain.)

- [keyboard.dart](bin/keyboard.dart): types text through the kernel HID
  function.
- [gamepad.dart](bin/gamepad.dart): a HID gamepad implemented in Dart with a
  custom function, answering the HID control requests itself.
- [mass_storage.dart](bin/mass_storage.dart): serves disk images as a USB
  drive: `sudo build/mass_storage/bundle/bin/mass_storage disk.img`.
- [pong.dart](bin/pong.dart) with [ping.dart](bin/ping.dart): a bulk echo
  function, and a host program using `usb_host` to exercise it. Run ping on
  the computer the board is plugged into: `dart run bin/ping.dart`.
