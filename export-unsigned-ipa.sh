#!/bin/bash
# Run on macOS with Xcode. ESign must sign the resulting IPA before installation.
set -euo pipefail

if [[ "$(uname -s)" != "Darwin" ]] || ! xcrun --find xcodebuild >/dev/null 2>&1; then
    echo "Requires macOS with full Xcode selected via xcode-select." >&2
    exit 1
fi

project_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
derived_dir="$project_dir/build/Device"
output_dir="$project_dir/build/IPA"

xcodebuild \
    -project "$project_dir/ArabicLivePhoto.xcodeproj" \
    -scheme ArabicLivePhoto \
    -configuration Release \
    -sdk iphoneos \
    -destination 'generic/platform=iOS' \
    -derivedDataPath "$derived_dir" \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGNING_REQUIRED=NO \
    build

app_bundle="$derived_dir/Build/Products/Release-iphoneos/ArabicLivePhoto.app"
if [[ ! -f "$app_bundle/ArabicLivePhoto" ]]; then
    echo "Device app bundle was not produced." >&2
    exit 1
fi

staging_dir="$(mktemp -d "${TMPDIR:-/tmp}/ArabicLivePhotoIPA.XXXXXX")"
trap 'rm -rf -- "$staging_dir"' EXIT
mkdir -p "$staging_dir/Payload" "$output_dir"
/usr/bin/ditto "$app_bundle" "$staging_dir/Payload/ArabicLivePhoto.app"
(
    cd "$staging_dir"
    /usr/bin/zip -q -r ArabicLivePhoto-unsigned.ipa Payload
)
/usr/bin/ditto "$staging_dir/ArabicLivePhoto-unsigned.ipa" "$output_dir/ArabicLivePhoto-unsigned.ipa"
echo "Unsigned IPA: $output_dir/ArabicLivePhoto-unsigned.ipa"
echo "Import into ESign and sign with a matching certificate and provisioning profile."

