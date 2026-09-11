# ncm_api_enhanced.podspec
#
# Flutter plugins are distributed to iOS apps via CocoaPods. The pod's
# `Classes/` is the source we build, and `vendored_frameworks` brings
# in NodeMobile.xcframework (which the user adds manually — see
# docs/mobile_setup.md — or via tool/patch_ios_pbxproj.rb).
#
# We intentionally do NOT vendor NodeMobile.xcframework from a URL
# here, because:
#   1. The user's nodejs-mobile tarball is downloaded by hook/build.dart
#      and copied next to the package source. Hooks run on the host
#      during `flutter build`, before CocoaPods sees the project.
#   2. podspec `http` downloads happen later, after `flutter build`
#      has already wired up the plugin; by then Flutter has committed
#      to specific .so paths.

Pod::Spec.new do |s|
  s.name             = 'ncm_api_enhanced'
  s.version          = '0.1.0'
  s.summary          = 'NCM API Enhanced — embedded nodejs-mobile runtime for Flutter.'
  s.description      = <<-DESC
                         Unofficial Netease Cloud Music API for Flutter, backed by
                         nodejs-mobile v18.20.4. Provides 439 NCM module functions
                         as a Dart facade.
                       DESC
  s.homepage         = 'https://github.com/your/ncm_api_enhanced'
  s.license          = { :type => 'MIT', :file => '../LICENSE' }
  s.author           = { 'ncm_api_enhanced' => 'noreply@example.com' }
  s.source           = { :path => '.' }

  s.swift_version    = '5.0'
  s.platform         = :ios, '13.0'

  s.source_files     = 'Classes/**/*'
  s.public_header_files = 'Classes/**/*.h'
  s.dependency 'Flutter'

  # NodeMobile.xcframework must be added by the user (via tool/patch_ios_pbxproj.rb
  # or manually in Xcode). We embed it here too in case the user has already
  # vendored it at ios/NodeMobile.framework (kept relative so the path is stable).
  s.frameworks       = 'Foundation'
  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'SWIFT_INCLUDE_PATHS' => '$(PODS_TARGET_SRCROOT)/Classes',
    # libnode is not bitcode-built.
    'ENABLE_BITCODE' => 'NO',
  }

  # Bundle the bridge/ tree as a resource. The Swift plugin extracts it
  # at runtime to Documents/ncm_bridge/.
  s.resources = 'bridge'
end