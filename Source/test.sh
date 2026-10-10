#!/bin/bash
set -euo pipefail
SOURCE_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$(mktemp -d /tmp/magicwheel-test.XXXXXX)"
trap 'rm -rf "$BUILD_DIR"' EXIT
MINIMUM_OS="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$SOURCE_DIR/Info.plist")"
xcrun swiftc -swift-version 5 -target "$(uname -m)-apple-macosx$MINIMUM_OS" "$SOURCE_DIR/GestureCore.swift" "$SOURCE_DIR/Shortcuts.swift" "$SOURCE_DIR/Localization.swift" "$SOURCE_DIR/Model.swift" "$SOURCE_DIR/SettingsTransfer.swift" "$SOURCE_DIR/InputActions.swift" "$SOURCE_DIR/KeyRecording.swift" "$SOURCE_DIR/SystemSymbols.swift" "$SOURCE_DIR/WheelCursor.swift" "$SOURCE_DIR/Tests/main.swift" -o "$BUILD_DIR/GestureTests"
"$BUILD_DIR/GestureTests" "$SOURCE_DIR/Resources/SymbolCatalog.plist"
