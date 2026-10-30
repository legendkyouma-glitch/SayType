#!/bin/zsh
# Build the Apple Silicon app. Ad-hoc signing is the default; no personal certificate is selected automatically.
set -euo pipefail
cd "$(dirname "$0")/.."
project_dir="$PWD"
work_dir="$project_dir/.work"
mkdir -p "$work_dir/tmp" "$work_dir/modcache" "$project_dir/outputs"
export TMPDIR="$work_dir/tmp/"
export CLANG_MODULE_CACHE_PATH="$work_dir/modcache"

# A public release must opt in and name its Developer ID identity explicitly.
if [[ "${RELEASE_SIGNING:-0}" == "1" ]]; then
  if [[ -z "${SIGN_IDENTITY:-}" || "$SIGN_IDENTITY" == "-" ]]; then
    echo "RELEASE_SIGNING=1 requires a Developer ID Application SIGN_IDENTITY." >&2
    exit 1
  fi
fi

# Keep the signing stage outside synced folders, which can re-add Finder metadata.
build_dir="$(mktemp -d "$(getconf DARWIN_USER_TEMP_DIR)saytype-build.XXXXXX")"
trap 'rm -rf "$build_dir"' EXIT
app_dir="$build_dir/SayType.app"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
cp -X app/Info.plist "$app_dir/Contents/Info.plist"
cp -X LICENSE "$app_dir/Contents/Resources/LICENSE"

echo "Compiling SayType for macOS 26+ (Apple Silicon)…"
xcrun --sdk macosx swiftc -O \
  -module-name SayType \
  -target arm64-apple-macos26.0 \
  -module-cache-path "$CLANG_MODULE_CACHE_PATH" \
  -o "$app_dir/Contents/MacOS/SayType" \
  app/Sources/*.swift

# Finder metadata on generated files is not part of the app and can prevent signing.
xattr -cr "$app_dir"
if [[ "${RELEASE_SIGNING:-0}" == "1" ]]; then
  codesign --force --sign "$SIGN_IDENTITY" --options runtime --timestamp \
    --entitlements app/SayType.entitlements "$app_dir"
  signing_details="$(codesign --display --verbose=4 "$app_dir" 2>&1)"
  if [[ "$signing_details" != *"Authority=Developer ID Application:"* ]]; then
    echo "Release signing requires a Developer ID Application certificate." >&2
    exit 1
  fi
else
  codesign --force --sign "${SIGN_IDENTITY:--}" "$app_dir"
fi
codesign --verify --strict "$app_dir"
# Replace only this script's generated app after compilation and signing succeed.
rm -rf "$project_dir/outputs/SayType.app"
mv "$app_dir" "$project_dir/outputs/SayType.app"
echo "Built: outputs/SayType.app"
echo "Launch: open outputs/SayType.app"
