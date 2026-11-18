/// USB gadgets for Linux: make a board with a USB device controller act as a
/// USB device, with kernel functions (HID, serial, network, mass storage,
/// audio, video, MIDI, ...) or functions implemented in Dart.
///
/// Bridges the Rust [usb-gadget](https://crates.io/crates/usb-gadget) crate.
/// USB types and descriptors come from `package:usb_models`, re-exported.
library;

export 'package:usb_models/usb_models.dart';

export 'src/custom/custom.dart';
export 'src/function.dart' hide classCodes;
export 'src/gadget.dart';
export 'src/rust/api/error.dart' show GadgetErrorKind, GadgetException;
export 'src/rust/api/function.dart' show FunctionState;
export 'src/rust/api/gadget.dart' show RegisteredFunction;
export 'src/rust/api/udc.dart' show Udc, UdcState;
export 'src/udc.dart';
