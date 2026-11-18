import 'package:code_assets/code_assets.dart';
import 'package:flutter_rust_bridge_hooks/flutter_rust_bridge_hooks.dart';

void main(List<String> args) async {
  await build(args, (input, output) async {
    // USB gadgets exist only on Linux (and Android, which is Linux). On other
    // systems the package still resolves and analyzes, without a library.
    if (!input.config.buildCodeAssets) return;
    final os = input.config.code.targetOS;
    if (os != OS.linux && os != OS.android) return;
    await const FlutterRustBridgeNativeAssetsBuilder().run(
      input: input,
      output: output,
    );
  });
}
