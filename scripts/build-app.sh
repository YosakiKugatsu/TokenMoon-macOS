#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-only
set -euo pipefail
cd "$(dirname "$0")/.."
configuration="${1:-release}"
case "$configuration" in debug|release) ;; *) echo "usage: $0 [debug|release]" >&2; exit 2;; esac
swift build -c "$configuration" --product TokenMoon
swift build -c "$configuration" --product TokenMoonLoginItem
bin="$(swift build -c "$configuration" --show-bin-path)"
output="${TOKENMOON_BUILD_OUTPUT:-$PWD/dist}"
mkdir -p "$output"
app="$output/TokenMoon.app"
bundle="$app/Contents"
mkdir -p "$bundle/MacOS" "$bundle/Resources"
install -m 755 "$bin/TokenMoon" "$bundle/MacOS/TokenMoon"
cp scripts/Info.plist "$bundle/Info.plist"
login_item="$bundle/Library/LoginItems/TokenMoonLoginItem.app"
mkdir -p "$login_item/Contents/MacOS"
install -m 755 "$bin/TokenMoonLoginItem" "$login_item/Contents/MacOS/TokenMoonLoginItem"
cp scripts/LoginItem-Info.plist "$login_item/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$bundle/Info.plist")" "$login_item/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$bundle/Info.plist")" "$login_item/Contents/Info.plist"
# Also install the data in the standard resource location for relocatable bundles.
cp Sources/TokenMoonCore/Resources/public-prices.json "$bundle/Resources/public-prices.json"
cp Sources/TokenMoonCore/Resources/model-names.json "$bundle/Resources/model-names.json"
cp Sources/TokenMoonCore/Resources/models.dev-LICENSE.txt "$bundle/Resources/models.dev-LICENSE.txt"
cp THIRD_PARTY_NOTICES.md "$bundle/Resources/THIRD_PARTY_NOTICES.md"
cp LICENSE "$bundle/Resources/LICENSE.txt"
swift scripts/make-icon.swift "$output/TokenMoon.png"
mkdir -p "$output/TokenMoon.iconset"
for side in 16 32 128 256 512; do
  sips -z "$side" "$side" "$output/TokenMoon.png" --out "$output/TokenMoon.iconset/icon_${side}x${side}.png" >/dev/null
  sips -z "$((side * 2))" "$((side * 2))" "$output/TokenMoon.png" --out "$output/TokenMoon.iconset/icon_${side}x${side}@2x.png" >/dev/null
done
iconutil -c icns "$output/TokenMoon.iconset" -o "$bundle/Resources/TokenMoon.icns"
identity="${TOKENMOON_CODESIGN_IDENTITY:--}"
codesign --force --timestamp=none --sign "$identity" "$login_item"
codesign --verify --strict "$login_item"
codesign --force --timestamp=none --sign "$identity" "$app"
if [[ "$identity" != "-" ]]; then
  team="$(codesign -dv "$app" 2>&1 | awk -F= '$1=="TeamIdentifier" {print $2}')"
  [[ "$team" =~ ^[A-Z0-9]{10}$ ]] || { echo "Expected an Apple Development team identifier." >&2; exit 1; }
  helper_team="$(codesign -dv "$login_item" 2>&1 | awk -F= '$1=="TeamIdentifier" {print $2}')"
  [[ "$helper_team" == "$team" ]] || { echo "Login item signing team differs from TokenMoon." >&2; exit 1; }
  requirement="identifier \"org.tokenmoon.desktop\" and anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.1] exists and certificate leaf[field.1.2.840.113635.100.6.1.12] exists and certificate leaf[subject.OU] = \"$team\""
  codesign --verify -R "=$requirement" "$app"
  # Match the app and developer team across rebuilds and certificate renewal.
  codesign --force --timestamp=none --sign "$identity" -r="designated => $requirement" "$app"
fi
codesign --verify --strict --deep "$app"
printf '%s\n' "$app"
