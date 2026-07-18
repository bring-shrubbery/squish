#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_DIR="$ROOT_DIR/dist/Squish.app"

cd "$ROOT_DIR"
swift build -c release --product Squish
swift build -c release --product squish-hook

rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"
cp "$ROOT_DIR/.build/release/Squish" "$APP_DIR/Contents/MacOS/Squish"
cp "$ROOT_DIR/.build/release/squish-hook" "$APP_DIR/Contents/MacOS/squish-hook"
cp "$ROOT_DIR/Support/Info.plist" "$APP_DIR/Contents/Info.plist"
cp "$ROOT_DIR/Sources/SquishApp/Resources/AppIcon.icns" "$APP_DIR/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$APP_DIR/Contents/MacOS/squish-hook"
codesign --force --sign - "$APP_DIR"

echo "$APP_DIR"
