#!/bin/zsh
# zsh tools/vault-check/run.sh   run Vault.swift entitled (as a Developer ID build) against a dummy credential.
# Unit tests run unentitled and can't reach the data-protection keychain; this does. Run it before
# shipping any keychain change. Needs signing/*.provisionprofile and the Developer ID certificate.
set -eu
cd "${0:A:h}/../.."
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
[[ -f dist/entitlements.plist ]] || zsh build-app.sh >/dev/null
WORK=$(mktemp -d) && trap 'rm -rf "$WORK"' EXIT
APP="$WORK/VaultCheck.app"; mkdir -p "$APP/Contents/MacOS"
BUNDLE_ID=$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "dist/Credential Harbor.app/Contents/Info.plist")
/usr/libexec/PlistBuddy -c "Add CFBundleExecutable string VaultCheck" -c "Add CFBundleIdentifier string $BUNDLE_ID" -c "Add CFBundlePackageType string APPL" "$APP/Contents/Info.plist" >/dev/null
cp signing/*.provisionprofile(N[1]) "$APP/Contents/embedded.provisionprofile"
swiftc -O -o "$APP/Contents/MacOS/VaultCheck" Sources/HarborCore/Vault.swift tools/vault-check/main.swift
IDENTITY=$(security find-identity -v -p codesigning | /usr/bin/grep -o '"Developer ID Application: [^"]*"' | head -1 | tr -d '"')
codesign --force --sign "$IDENTITY" --options runtime --entitlements dist/entitlements.plist --identifier "$BUNDLE_ID" "$APP" 2>/dev/null
"$APP/Contents/MacOS/VaultCheck"
