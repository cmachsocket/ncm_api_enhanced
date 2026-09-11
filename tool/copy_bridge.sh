#!/usr/bin/env bash
# Copy bridge/ (the node-side NCM runtime) into the platform-specific bundle
# locations where Flutter can find it at run time.
#
# Usage (called by build scripts or manually):
#   tool/copy_bridge.sh                  # copies to all enabled platforms
#   tool/copy_bridge.sh desktop          # linux/macos/windows only
#   tool/copy_bridge.sh android ios      # mobile only
#
# The resulting layout:
#
#   build/ncm_bridge/                    # shared — works for desktop dev runs
#     bridge.js
#     package.json
#     node_modules/...
#
#   android/app/src/main/assets/ncm_bridge/
#     bridge.js
#     package.json
#     node_modules/...
#
#   ios/Runner/ncm_bridge/               # referenced as a folder reference
#     ...
#
# macos/Runner/Resources/ncm_bridge/  and windows/runner/{Debug,Release}/...
# likewise. Run with `tool/copy_bridge.sh all` to populate every platform.

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BRIDGE_SRC="$PROJECT_ROOT/bridge"

if [[ ! -d "$BRIDGE_SRC/node_modules/@neteasecloudmusicapienhanced" ]]; then
  echo "error: $BRIDGE_SRC/node_modules/@neteasecloudmusicapienhanced missing." >&2
  echo "  run: (cd bridge && npm install)" >&2
  exit 1
fi

copy_into() {
  local dest="$1"
  mkdir -p "$dest"
  # `-L` follows symlinks; `bridge/node_modules` is a symlink to the
  # project's root `node_modules` so rsync sees the real files.
  rsync -aL --delete \
    --exclude='.DS_Store' \
    "$BRIDGE_SRC/" "$dest/"
  echo "  -> $dest"
}

case "${1:-all}" in
  desktop)
    mkdir -p "$PROJECT_ROOT/build/ncm_bridge"
    copy_into "$PROJECT_ROOT/build/ncm_bridge"
    mkdir -p "$PROJECT_ROOT/macos/Runner/ncm_bridge"
    copy_into "$PROJECT_ROOT/macos/Runner/ncm_bridge"
    # Windows: Flutter doesn't ship a "runner resources" folder by default;
    # flutter packs assets from the pubspec `assets:` entries. So we don't
    # need a Windows-specific copy — the asset bundle handles it.
    ;;
  android)
    copy_into "$PROJECT_ROOT/android/app/src/main/assets/ncm_bridge"
    ;;
  ios)
    copy_into "$PROJECT_ROOT/ios/Runner/ncm_bridge"
    ;;
  all)
    "$0" desktop
    "$0" android
    "$0" ios
    ;;
  *)
    echo "usage: $0 [desktop|android|ios|all]" >&2
    exit 2
    ;;
esac