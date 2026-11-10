import 'package:flutter_rust_bridge_hooks/flutter_rust_bridge_hooks.dart';

void main(List<String> args) async {
  await build(args, (input, output) async {
    await FlutterRustBridgeNativeAssetsBuilder(
      // Link hooks are only enabled for AOT runs, so this is Flutter's debug mode.
      buildMode: input.config.linkingEnabled
          ? FlutterRustBridgeBuildMode.release
          : FlutterRustBridgeBuildMode.debug,
    ).run(input: input, output: output);
  });
}
