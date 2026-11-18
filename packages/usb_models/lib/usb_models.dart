/// USB standard types and descriptors shared by `dusb` (host side) and
/// `usb_gadget` (device side).
///
/// Covers the USB 2.0/3.x chapter 9 definitions (directions, request types,
/// endpoint addresses and attributes, speeds, descriptors) and the HID class.
library;

export 'src/ch9/ch9.dart';
export 'src/hid/hid.dart';
