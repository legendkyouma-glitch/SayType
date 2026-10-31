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
cp -X THIRD_PARTY_NOTICES.md "$app_dir/Contents/Resources/THIRD_PARTY_NOTICES.md"

echo "Compiling SayType for macOS 26+ (Apple Silicon)…"
# Swift Build compiles MLX's Metal shaders as well as the Swift/C++ runtime.
# Package.resolved pins the complete native dependency graph. No Python runtime
# or model weights are included in the application.
if ! xcrun metal --version >/dev/null 2>&1; then
  echo "Xcode's Metal Toolchain is required to build. Install it in Xcode > Settings > Components." >&2
  exit 1
fi
swift build --build-system swiftbuild -c release --product SayType --arch arm64
product_dir="$(swift build --build-system swiftbuild -c release --show-bin-path --arch arm64)"
cp -X "$product_dir/SayType" "$app_dir/Contents/MacOS/SayType"

# Bundle.module resolves package resources from the installed app's Resources.
for resource in "$product_dir"/*.bundle(N); do
  ditto --noextattr --noqtn "$resource" "$app_dir/Contents/Resources/$(basename "$resource")"
done
metal_library="$product_dir/mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib"
if [[ ! -s "$metal_library" ]]; then
  echo "MLX Metal library was not generated; refusing to package an incomplete app." >&2
  exit 1
fi
# MLX resolves its SwiftPM resource bundle from this app's Resources folder.

while IFS= read -r license; do
  relative_license="${license#.build/checkouts/}"
  destination="$app_dir/Contents/Resources/ThirdPartyLicenses/$relative_license"
  mkdir -p "$(dirname "$destination")"
  cp -X "$license" "$destination"
done < <(find .build/checkouts -type f \( -name 'LICENSE*' -o -name 'NOTICE*' -o -name 'COPYING*' \))
ditto --noextattr --noqtn licenses "$app_dir/Contents/Resources/ModelLicenses"

# Finder metadata on generated files is not part of the app and can prevent signing.
# SwiftPM checkouts include read-only license files; make the copied artifacts
# writable before clearing metadata (the source checkouts stay untouched).
chmod -R u+w "$app_dir"
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
codesign --verify --deep --strict "$app_dir"
# A synced Documents folder may immediately add FinderInfo to .app directories.
# Archive the clean signed app before moving it there, so the distributable
# retains its signature independently of the surrounding file provider.
ditto -c -k --keepParent --norsrc --noextattr --noqtn "$app_dir" "$build_dir/SayType.zip"
mkdir -p "$build_dir/verify"
ditto -x -k --noextattr --noqtn "$build_dir/SayType.zip" "$build_dir/verify"
codesign --verify --deep --strict "$build_dir/verify/SayType.app"
# Replace only this script's generated app after compilation and signing succeed.
rm -rf "$project_dir/outputs/SayType.app"
mv "$app_dir" "$project_dir/outputs/SayType.app"
mv -f "$build_dir/SayType.zip" "$project_dir/outputs/SayType.zip"
echo "Built: outputs/SayType.app"
echo "Verified archive: outputs/SayType.zip"
echo "Launch: open outputs/SayType.app"
