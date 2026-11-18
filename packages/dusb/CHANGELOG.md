## 0.1.0

- Dart package bridging the Rust [nusb](https://github.com/kevinmehall/nusb)
  crate (0.2.9) with flutter_rust_bridge 2.13.0, built and bundled by a Dart
  build hook (no platform-specific build files).
- Enumeration, buses and hotplug; opening devices, claiming interfaces,
  configurations, alternate settings and reset; control, bulk and interrupt
  transfers; buffered endpoint readers and writers; parsed descriptors.
