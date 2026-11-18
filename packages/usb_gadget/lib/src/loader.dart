import 'dart:ffi';

import 'package:ffi/ffi.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';

import 'package:usb_gadget/src/rust/frb_generated.dart';

// hook/build.dart bundles the Rust crate as a code asset under this ID
// (flutter_rust_bridge_hooks' default). Binding one symbol to it lets the
// Dart runtime load the library from wherever the build put it.
@Native<Int32 Function()>(
  symbol: 'frb_get_rust_content_hash',
  assetId: 'package:usb_gadget/src/rust/frb_generated.io.dart',
)
external int _anchor();

Future<void>? _initialized;

/// Loads the native library, once.
Future<void> ensureInitialized() => _initialized ??= _load();

Future<void> _load() async {
  try {
    await RustLib.init(externalLibrary: _library());
  } catch (_) {
    _initialized = null; // Let a later call retry.
    rethrow;
  }
}

/// The Rust library, located through its code asset. flutter_rust_bridge
/// opens libraries by path, so this resolves the path of the file the
/// runtime loaded for the asset.
ExternalLibrary _library() {
  final address = Native.addressOf<NativeFunction<Int32 Function()>>(_anchor)
      .cast<Void>();
  return using((arena) {
    final dladdr = DynamicLibrary.process()
        .lookupFunction<
          Int32 Function(Pointer<Void>, Pointer<_DlInfo>),
          int Function(Pointer<Void>, Pointer<_DlInfo>)
        >('dladdr');
    final info = arena<_DlInfo>();
    if (dladdr(address, info) == 0 || info.ref.fname == nullptr) {
      throw StateError('usb_gadget: could not locate the native library');
    }
    return ExternalLibrary.open(info.ref.fname.toDartString());
  });
}

final class _DlInfo() extends Struct {
  external Pointer<Utf8> fname;
  external Pointer<Void> fbase;
  external Pointer<Utf8> sname;
  external Pointer<Void> saddr;
}
