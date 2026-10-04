#!/bin/zsh
# Builds dist/Squish.app: the app and squish-hook executables, Info.plist, the icon and
# the embedded Sparkle framework, signed inside out.
#
#   ./scripts/build-app.sh                       ad-hoc signed development bundle
#   SIGN_IDENTITY="Developer ID Application: …" VERSION=1.2.3 BUILD_NUMBER=42 \
#     ./scripts/build-app.sh                     what the release workflow runs
#
# SIGN_IDENTITY  codesign identity; "-" (the default) signs ad hoc without the hardened
#                runtime or a timestamp. Any other identity gets both, as notarization needs.
# VERSION        CFBundleShortVersionString; defaults to the one in Support/Info.plist.
# BUILD_NUMBER   CFBundleVersion (Sparkle compares it); defaults to the one in Info.plist.
# ARCH           arm64 (default) or x86_64.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_DIR="$ROOT_DIR/dist/Squish.app"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
ARCH="${ARCH:-arm64}"

cd "$ROOT_DIR"
swift build -c release --arch "$ARCH" --product Squish
swift build -c release --arch "$ARCH" --product squish-hook
BIN_DIR="$(swift build -c release --arch "$ARCH" --show-bin-path)"

# SwiftPM puts the binary framework next to the products, or under PackageFrameworks with
# the newer build system.
SPARKLE_FRAMEWORK=""
for candidate in "$BIN_DIR/Sparkle.framework" "$BIN_DIR/PackageFrameworks/Sparkle.framework"; do
    if [ -d "$candidate" ]; then SPARKLE_FRAMEWORK="$candidate"; break; fi
done
if [ -z "$SPARKLE_FRAMEWORK" ]; then
    SPARKLE_FRAMEWORK="$(find "$ROOT_DIR/.build" -path '*release*' -name Sparkle.framework -type d -prune | head -1)"
fi
if [ -z "$SPARKLE_FRAMEWORK" ]; then
    echo "error: Sparkle.framework not found under $BIN_DIR" >&2
    exit 1
fi

rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources" "$APP_DIR/Contents/Frameworks"
cp "$BIN_DIR/Squish" "$APP_DIR/Contents/MacOS/Squish"
cp "$BIN_DIR/squish-hook" "$APP_DIR/Contents/MacOS/squish-hook"
cp "$ROOT_DIR/Support/Info.plist" "$APP_DIR/Contents/Info.plist"
cp "$ROOT_DIR/Sources/SquishApp/Resources/AppIcon.icns" "$APP_DIR/Contents/Resources/AppIcon.icns"
# -R keeps the framework's Versions/Current symlinks, which its signature covers.
cp -R "$SPARKLE_FRAMEWORK" "$APP_DIR/Contents/Frameworks/"

PLIST="$APP_DIR/Contents/Info.plist"
[ -n "${VERSION:-}" ] && /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$PLIST"
[ -n "${BUILD_NUMBER:-}" ] && /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$PLIST"

# The build tree's rpaths are absolute; the bundle loads Sparkle from Contents/Frameworks.
EXECUTABLE="$APP_DIR/Contents/MacOS/Squish"
otool -l "$EXECUTABLE" | awk '/LC_RPATH/ { getline; getline; print $2 }' | while read -r rpath; do
    case "$rpath" in
        /usr/lib/swift) ;;
        *) install_name_tool -delete_rpath "$rpath" "$EXECUTABLE" 2>/dev/null || true ;;
    esac
done
install_name_tool -add_rpath "@executable_path/../Frameworks" "$EXECUTABLE"

if [ "$SIGN_IDENTITY" = "-" ]; then
    sign=(codesign --force --sign -)
else
    sign=(codesign --force --sign "$SIGN_IDENTITY" --options runtime --timestamp)
fi

# Sparkle ships its helpers ad-hoc signed and notarization rejects every Mach-O without a
# Developer ID. Sign inside out (never --deep: each seal must cover its re-signed children).
FW="$APP_DIR/Contents/Frameworks/Sparkle.framework/Versions/B"
"${sign[@]}" "$FW/XPCServices/Installer.xpc"
"${sign[@]}" --preserve-metadata=entitlements "$FW/XPCServices/Downloader.xpc"
"${sign[@]}" "$FW/Autoupdate"
"${sign[@]}" "$FW/Updater.app"
"${sign[@]}" "$APP_DIR/Contents/Frameworks/Sparkle.framework"
"${sign[@]}" "$APP_DIR/Contents/MacOS/squish-hook"
"${sign[@]}" "$APP_DIR"

codesign --verify --deep --strict "$APP_DIR"
echo "$APP_DIR"
