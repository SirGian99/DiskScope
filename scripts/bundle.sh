#!/bin/bash
#
# Assembles a runnable DiskScope.app bundle from the SwiftPM build product.
# Works with the Command Line Tools toolchain — no Xcode project required.
#
set -euo pipefail

CONFIG="${1:-release}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

echo "› Building ($CONFIG)…"
swift build -c "$CONFIG"

BIN_PATH="$(swift build -c "$CONFIG" --show-bin-path)/DiskScope"
APP="$ROOT/.build/DiskScope.app"

echo "› Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_PATH" "$APP/Contents/MacOS/DiskScope"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

if [ -f "$ROOT/Resources/AppIcon.icns" ]; then
    cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
fi

# Ad-hoc code signature. This is optional, but it gives the bundle a stable
# identity so a Full Disk Access grant in System Settings sticks across rebuilds.
echo "› Ad-hoc signing"
codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || \
    echo "  (codesign skipped — app still runs unsigned)"

echo "✓ Built $APP"
