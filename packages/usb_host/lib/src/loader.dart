import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';

// hook/build.dart bundles the Rust crate as a code asset under this ID
// (flutter_rust_bridge_hooks' default). Binding one symbol to it lets the
// Dart runtime load the library from wherever the build put it, under both
// `dart` and Flutter.
@Native<Int32 Function()>(
  symbol: 'frb_get_rust_content_hash',
  assetId: 'package:usb_host/src/rust/frb_generated.io.dart',
)
external int _anchor();

/// The Rust library, located through its code asset.
///
/// flutter_rust_bridge opens libraries by path, so this resolves the path of
/// the file the runtime loaded for the asset.
ExternalLibrary usbHostExternalLibrary() {
  final address = Native.addressOf<NativeFunction<Int32 Function()>>(_anchor).cast<Void>();
  return ExternalLibrary.open(Platform.isWindows ? _windowsPath(address) : _posixPath(address));
}

final class _DlInfo extends Struct {
  external Pointer<Utf8> fname;
  external Pointer<Void> fbase;
  external Pointer<Utf8> sname;
  external Pointer<Void> saddr;
}

String _posixPath(Pointer<Void> address) => using((arena) {
  final dladdr = DynamicLibrary.process()
      .lookupFunction<Int32 Function(Pointer<Void>, Pointer<_DlInfo>), int Function(Pointer<Void>, Pointer<_DlInfo>)>(
        'dladdr',
      );
  final info = arena<_DlInfo>();
  if (dladdr(address, info) == 0 || info.ref.fname == nullptr) {
    throw StateError('usb_host: could not locate the native library');
  }
  return info.ref.fname.toDartString();
});

String _windowsPath(Pointer<Void> address) => using((arena) {
  final kernel32 = DynamicLibrary.open('kernel32.dll');
  final getModuleHandleEx = kernel32
      .lookupFunction<
        Int32 Function(Uint32, Pointer<Void>, Pointer<Pointer<Void>>),
        int Function(int, Pointer<Void>, Pointer<Pointer<Void>>)
      >('GetModuleHandleExW');
  final getModuleFileName = kernel32
      .lookupFunction<Uint32 Function(Pointer<Void>, Pointer<Utf16>, Uint32), int Function(Pointer<Void>, Pointer<Utf16>, int)>(
        'GetModuleFileNameW',
      );
  const fromAddress = 0x4, unchangedRefcount = 0x2;
  final module = arena<Pointer<Void>>();
  if (getModuleHandleEx(fromAddress | unchangedRefcount, address, module) == 0) {
    throw StateError('usb_host: could not locate the native library');
  }
  const capacity = 32768;
  final path = arena<Uint16>(capacity).cast<Utf16>();
  final length = getModuleFileName(module.value, path, capacity);
  if (length == 0) throw StateError('usb_host: could not locate the native library');
  return path.toDartString(length: length);
});
