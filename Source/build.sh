#!/bin/bash
set -euo pipefail
SOURCE_DIR="$(cd "$(dirname "$0")" && pwd)"
OUTPUT_DIR="${1:-$(dirname "$SOURCE_DIR")/outputs}"

if [[ "$(uname -s)" != Darwin ]]; then
    echo "Orvia must be built on macOS." >&2
    exit 1
fi
SDK_VERSION="$(xcrun --sdk macosx --show-sdk-version)"
if [[ "${SDK_VERSION%%.*}" -lt 26 ]]; then
    echo "Orvia requires the macOS 26 SDK or newer (Xcode 26+ or matching Command Line Tools)." >&2
    exit 1
fi
MINIMUM_OS="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$SOURCE_DIR/Info.plist")"
TARGET="$(uname -m)-apple-macosx$MINIMUM_OS"
BUILD_DIR="$(mktemp -d "${TMPDIR:-/tmp}/orvia-build.XXXXXX")"
trap 'rm -rf "$BUILD_DIR"' EXIT
APP="$BUILD_DIR/Orvia.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

xcrun clang -target "$TARGET" -O2 -c "$SOURCE_DIR/Multitouch.c" -o "$BUILD_DIR/Multitouch.o"
SOURCES=(
    GestureCore Shortcuts Localization Model SettingsTransfer InputActions
    KeyRecording QuickTextEditor SettingsPickers SettingsTransferUI
    RuntimeKeyboard SystemSymbols WheelRendering WheelCursor main
)
SWIFT_FILES=()
for source in "${SOURCES[@]}"; do SWIFT_FILES+=("$SOURCE_DIR/$source.swift"); done
xcrun swiftc -swift-version 5 -target "$TARGET" -O \
    -import-objc-header "$SOURCE_DIR/Multitouch.h" \
    "${SWIFT_FILES[@]}" "$BUILD_DIR/Multitouch.o" \
    -framework AppKit -framework SwiftUI -framework ApplicationServices \
    -o "$APP/Contents/MacOS/Orvia"
cp "$SOURCE_DIR/Resources/"*.plist "$SOURCE_DIR/Resources/"*.png "$SOURCE_DIR/Resources/"*.svg "$APP/Contents/Resources/"
cp "$SOURCE_DIR/Info.plist" "$APP/Contents/Info.plist"
cp "$SOURCE_DIR/../LICENSE" "$APP/Contents/Resources/LICENSE"
xcrun swift "$SOURCE_DIR/Icon.swift" "$BUILD_DIR/Orvia.iconset" "$SOURCE_DIR/Resources/OrviaLogo.png"
iconutil -c icns "$BUILD_DIR/Orvia.iconset" -o "$APP/Contents/Resources/Orvia.icns"
codesign --force --sign - "$APP"
codesign --verify --strict "$APP"

# Only copy a completed, verified bundle to the requested destination.
mkdir -p "$OUTPUT_DIR"
ditto "$APP" "$OUTPUT_DIR/Orvia.app"
printf '%s\n' "$OUTPUT_DIR/Orvia.app"
