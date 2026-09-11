# iOS: adding `ncm_bridge` to the Xcode project

The `ncm_bridge` folder under `ios/Runner/` contains the entire node-side
runtime — `bridge.js` plus a 65 MB `node_modules/` tree. We ship it as a
**folder reference** (blue folder in Xcode), not a group, so Xcode copies
the entire tree verbatim into the app bundle rather than indexing it
source-by-source.

Steps to wire it into the project:

1. Open `ios/Runner.xcodeproj` in Xcode.
2. In the Project Navigator, right-click the **Runner** group → **Add
   Files to "Runner"...**.
3. Select `ios/Runner/ncm_bridge/` (do not tick *Copy items if needed* —
   the folder already lives inside the project root).
4. In the "Add to targets" sheet, ensure **Runner** is checked.
5. In the dialog that appears, click **Add as Folder Reference** (NOT
   "Create groups"). The folder should appear with a blue icon in the
   navigator.

That's it for the assets side. The next step is to add
`NodeMobile.framework`:

1. Download `nodejs-mobile-v18.20.4-ios.tar.gz` from
   <https://github.com/nodejs-mobile/nodejs-mobile/releases/tag/v18.20.4>.
2. Extract `Release-universal/NodeMobile.framework`.
3. Drag it into `ios/Runner/` in Finder.
4. Drag it from Finder into the Xcode project's **Frameworks** group.
5. In the project settings, set **Build Settings → Enable Bitcode → No**.
   (libnode is not built with bitcode.)
6. (Optional, scripted) Run `tool/patch_ios_pbxproj.rb
   path/to/NodeMobile.xcframework` — idempotently adds the framework to
   Runner and embeds it in the .app bundle.

After both steps:

- `ios/Runner/ncm_bridge/` is in the app bundle at `ncm_bridge/`.
- `NodeMobile.framework` is linked and embedded.
- `pod install` (in `ios/`) sets `ENABLE_BITCODE = NO` across all
  Pods.

Finally, run `flutter run` — `NcmNodePlugin` will be registered in
`AppDelegate.swift`, the `MobileNcmBridge` factory will pick it, and the
Dart side will start the bridge transparently.