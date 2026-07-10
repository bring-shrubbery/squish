#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_DIR="$ROOT_DIR/dist/Squish.app"

cd "$ROOT_DIR"
swift build -c release --product Squish

rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"
cp "$ROOT_DIR/.build/release/Squish" "$APP_DIR/Contents/MacOS/Squish"
cp "$ROOT_DIR/Support/Info.plist" "$APP_DIR/Contents/Info.plist"
codesign --force --sign - "$APP_DIR"

echo "$APP_DIR"
