// android/src/main/java/to/holepunch/ncm_enhanced/AddonLinker.java
//
// Empty plugin class. This module exists to give the Flutter Android
// toolchain a plugin module whose Gradle build bundles the 100+
// `libbare-*.so` files that the bridge bundle links against at
// runtime (`linked:libbare-type.1.1.1.so` etc.).
//
// The actual jniLibs wiring lives in android/build.gradle — see the
// `downloadAndPackageAddons` task. We keep this class as the
// `pluginClass` so Flutter pub get registers the module and merges
// its aar into the host app. No Dart-side channel is used.

package to.holepunch.ncm_enhanced;

import io.flutter.embedding.engine.plugins.FlutterPlugin;

public class AddonLinker implements FlutterPlugin {

    @Override
    public void onAttachedToEngine(FlutterPlugin.FlutterPluginBinding binding) {
        // No-op. See android/build.gradle for the actual addons wiring.
    }

    @Override
    public void onDetachedFromEngine(FlutterPlugin.FlutterPluginBinding binding) {
        // No-op.
    }
}
