# SPDX-License-Identifier: MIT
#
# tool/refresh_bridge.sh — refresh the package's `bridge/` runtime tree
# from upstream `@neteasecloudmusicapienhanced/api`.
#
# This is a **package-author-only** script. It runs once when you're
# cutting a new release of `ncm_api_enhanced`. It does NOT run at
# consumer build time — that's the hook's job for native assets
# (libnode.so), and consumers never need npm.
#
# Why a script and not a hook entrypoint:
#   - hook/build.dart runs on every `flutter pub get` for every
#     consumer of the package, which is unacceptable for a 65 MB
#     node_modules download.
#   - upstream `@neteasecloudmusicapienhanced/api` is a JS dep, not
#     a native code asset. Dart's CodeAsset protocol can't ship it.
#   - 65 MB would inflate the pub tarball for every consumer even
#     though the JS side is constant across all consumers.
#
# Usage (from packages/ncm_api_enhanced/ or the package root, since
# the package no longer lives under packages/):
#   tool/refresh_bridge.sh
#
# This populates bridge/bridge.js + bridge/package.json +
# bridge/node_modules/ (~65 MB). The last directory is symlinked
# locally and real-copied into the package by the script below.
#
# After running this once, commit bridge/bridge.js + bridge/package.json
# + bridge/node_modules/ into the repo. They are then shipped as
# Flutter assets in the package pubspec.

set -euo pipefail

PKG_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# Source of truth for the upstream NCM API: this monorepo's root
# node_modules, populated by the project's own `npm install`. If you
# don't have it, run `npm install` at the repo root first.
SRC_ROOT="$(cd "$PKG_ROOT/.." && pwd)"
SRC_BRIDGE="$SRC_ROOT/bridge/bridge.js"

if [[ ! -d "$SRC_ROOT/node_modules/@neteasecloudmusicapienhanced" ]]; then
  echo "error: upstream @neteasecloudmusicapienhanced not found in" >&2
  echo "  $SRC_ROOT/node_modules" >&2
  echo "  Run: (cd \"$SRC_ROOT\" && npm install)" >&2
  exit 1
fi
if [[ ! -f "$SRC_BRIDGE" ]]; then
  echo "error: source bridge.js missing at $SRC_BRIDGE" >&2
  echo "  This repo's bridge/bridge.js is the IPC entrypoint — it must" >&2
  echo "  exist on disk before refreshing the package copy." >&2
  exit 1
fi

BRIDGE_DST="$PKG_ROOT/bridge"
mkdir -p "$BRIDGE_DST"

# Copy the IPC entrypoint.
cp -f "$SRC_BRIDGE" "$BRIDGE_DST/bridge.js"

# Standalone package.json (no deps needed; the upstream module is
# already in node_modules).
cat > "$BRIDGE_DST/package.json" <<'EOF'
{
  "name": "ncm_bridge",
  "version": "1.0.0",
  "private": true
}
EOF

# Copy node_modules in real-file form so the package ships without
# dangling symlinks.
rm -rf "$BRIDGE_DST/node_modules"
cp -rL "$SRC_ROOT/node_modules" "$BRIDGE_DST/node_modules"

# Strip the unblock-music utilities package. Upstream NCM does not
# `require()` anything from `@unblockneteasemusic/server` at runtime —
# only docs reference it. But the package ships with a real EC private
# key and a Google API key in source, which trips `pub publish`'s
# `false_secrets` check and bloats the tarball by ~2 MB.
#
# This keeps the JS runtime fully functional while making the package
# safe to publish on pub.dev.
if [[ -d "$BRIDGE_DST/node_modules/@unblockneteasemusic" ]]; then
    echo "Pruning @unblockneteasemusic (runtime-unused, contains private keys)"
    rm -rf "$BRIDGE_DST/node_modules/@unblockneteasemusic"
fi
# .bin/ may contain symlinks into the pruned package; clean those too.
find "$BRIDGE_DST/node_modules/.bin" -type l \
    \( -name 'unblockneteasemusic*' -o -name 'unblockmusic*' \) \
    -delete 2>/dev/null || true

# node_modules ships plenty of dev-time .bin symlinks. We don't need
# any of them at runtime — `bridge.js` is a hand-written entrypoint,
# not an npm script — so strip the whole .bin/ to shrink the tarball.
if [[ -d "$BRIDGE_DST/node_modules/.bin" ]]; then
    rm -rf "$BRIDGE_DST/node_modules/.bin"
fi

echo "Bridge refreshed at $BRIDGE_DST"
du -sh "$BRIDGE_DST/node_modules"
echo ""
echo "Next steps:"
echo "  1. flutter pub publish --dry-run     # sanity-check the tarball"
echo "  2. git add bridge/                   # commit the ~63 MB node_modules"
echo "  3. flutter pub publish                # ship"