#!/bin/bash
set -euo pipefail
SOURCE_DIR="$(cd "$(dirname "$0")" && pwd)"
OUTPUT_DIR="${1:-$(dirname "$SOURCE_DIR")/outputs/release}"
mkdir -p "$OUTPUT_DIR"
OUTPUT_DIR="$(cd "$OUTPUT_DIR" && pwd)"
STAGING_DIR="$(mktemp -d "${TMPDIR:-/tmp}/orvia-package.XXXXXX")"
trap 'rm -rf "$STAGING_DIR"' EXIT
bash "$SOURCE_DIR/build.sh" "$STAGING_DIR"
APP="$STAGING_DIR/Orvia.app"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
ARCH="$(uname -m)"
ARCHIVE="Orvia-$VERSION-macos-$ARCH.zip"
# ditto preserves bundle metadata and executable permissions for distribution.
ditto -c -k --sequesterRsrc --keepParent "$APP" "$STAGING_DIR/$ARCHIVE"
mv "$STAGING_DIR/$ARCHIVE" "$OUTPUT_DIR/$ARCHIVE"
(cd "$OUTPUT_DIR" && shasum -a 256 "$ARCHIVE" > "$ARCHIVE.sha256")
printf 'Package: %s\nChecksum: %s\n' "$OUTPUT_DIR/$ARCHIVE" "$OUTPUT_DIR/$ARCHIVE.sha256"
