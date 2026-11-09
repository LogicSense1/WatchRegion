#!/bin/bash
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/watchregion-build.XXXXXX")
trap 'rm -rf "$work"' EXIT

xcodebuild -project "$root/WatchRegion.xcodeproj" -scheme WatchRegion \
    -configuration Release -destination 'generic/platform=watchOS' \
    -derivedDataPath "$work/DerivedData" CODE_SIGNING_ALLOWED=NO \
    CODE_SIGNING_REQUIRED=NO build

app="$work/DerivedData/Build/Products/Release-watchos/WatchRegion.app"
if codesign --display "$app/WatchRegion" >/dev/null 2>&1; then
    codesign --remove-signature "$app/WatchRegion"
fi
if codesign --display "$app/WatchRegion" >/dev/null 2>&1 ||
    [[ -e "$app/_CodeSignature" || -e "$app/embedded.mobileprovision" ]]; then
    printf '%s\n' 'Expected an unsigned watchOS app without a provisioning profile.' >&2
    exit 1
fi

version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Info.plist")
name="WatchRegion-$version-unsigned-watchOS.ipa"
mkdir -p "$root/dist" "$work/Payload"
cp "$root/LICENSE" "$app/LICENSE"
mv "$app" "$work/Payload/"
ditto -c -k --norsrc --keepParent "$work/Payload" "$work/$name"
mv "$work/$name" "$root/dist/$name"
(cd "$root/dist" && shasum -a 256 "$name" > "$name.sha256")
printf '\n%s\n' "$root/dist/$name"
