#!/bin/zsh
# Package only a freshly built app, never local configuration or user data.
set -euo pipefail
cd "$(dirname "$0")/.."
./scripts/build.sh
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' app/Info.plist)"
release_dir="$PWD/outputs/releases"
mkdir -p "$release_dir"
archive="SayType-$version-macOS-arm64.zip"
rm -f "$release_dir/$archive"
# build.sh archives and verifies outside synced folders, before a file provider
# can attach Finder metadata to the .app. Keep those verified bytes unchanged.
cp -X outputs/SayType.zip "$release_dir/$archive"
cd "$release_dir"
shasum -a 256 "$archive" > SHA256SUMS
echo "Packaged: $release_dir/$archive"
