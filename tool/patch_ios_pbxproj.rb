#!/usr/bin/env ruby
# tool/patch_ios_pbxproj.rb
#
# Adds NodeMobile.framework to the iOS Xcode project so that the Flutter
# Runner can link against the vendored NodeMobile.xcframework from
# nodejs-mobile v18.20.4.
#
# Usage:
#   bundle install   # if you have a Gemfile that lists xcodeproj
#   tool/patch_ios_pbxproj.rb path/to/NodeMobile.xcframework
#
# If you don't have the `xcodeproj` gem installed:
#   gem install --user-install xcodeproj
#
# This script is idempotent: re-running it after NodeMobile.xcframework
# has already been added is a no-op.

require 'xcodeproj'

framework_path = ARGV[0] or abort("usage: #{$0} path/to/NodeMobile.xcframework")
proj_path = File.expand_path('../ios/Runner.xcodeproj', __dir__)
project = Xcodeproj::Project.open(proj_path)

target = project.targets.find { |t| t.name == 'Runner' } or abort("Runner target not found")

# Already added?
existing = project.frameworks_group.files.find { |f|
  f.path&.end_with?('NodeMobile.xcframework')
}
if existing
  puts "NodeMobile.xcframework already in project; nothing to do."
  exit 0
end

# 1. Copy the framework into ios/Runner/ so the project has a stable
#    relative reference (avoids issues with absolute paths getting
#    stale or being per-machine).
dest_dir = File.expand_path('../ios/Runner', __dir__)
dest = File.join(dest_dir, 'NodeMobile.xcframework')
unless File.directory?(dest)
  puts "Copying #{framework_path} → #{dest}"
  FileUtils.cp_r(framework_path, dest_dir)
end

# 2. Add as a file reference under Frameworks group.
ref = project.frameworks_group.new_file('../Runner/NodeMobile.xcframework')

# 3. Link it.
target.frameworks_build_phases.add_file_reference(ref, true)

# 4. Embed it (so the .xcframework ships in the .app bundle).
target.add_resources([ref])  # fallback for older Xcode; for newer use:
copy_phase = target.copy_files_build_phases.find { |p|
  p.symbol_dst_subfolder_spec == :frameworks
}
unless copy_phase
  copy_phase = target.new_copy_files_build_phase('Embed Frameworks')
  copy_phase.symbol_dst_subfolder_spec = :frameworks
end
copy_phase.add_file_reference(ref, true)

project.save
puts "Done. NodeMobile.xcframework linked + embedded into Runner."
puts "Open ios/Runner.xcodeproj in Xcode, set ENABLE_BITCODE=No (Build Settings), then build."