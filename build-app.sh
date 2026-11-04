#!/bin/zsh
# zsh build-app.sh            build dist/Credential Harbor.app (app + bundled harbor CLI)
# zsh build-app.sh --install  also copy to ~/Applications and link ~/.local/bin/harbor
# zsh build-app.sh --notarize also notarize and staple (needs: xcrun notarytool store-credentials harbor-notary)
# With a Developer ID profile in signing/*.provisionprofile (paid Apple Developer Program), the app
# takes the profile's bundle ID, is signed Developer ID with the hardened runtime, and keeps
# credentials in the data-protection keychain (iCloud Keychain sync available). Without one:
# Keychain ties "Always Allow" to a Team ID when the app has one, otherwise to the exact build.
# So: sign with an "Apple Development" identity (free Apple ID in Xcode → Settings → Accounts)
# when present and rebuilds never re-prompt; otherwise ad-hoc, and macOS asks once per
# credential after each rebuild. (A self-signed cert has no Team ID, so it doesn't help.)
set -eu
cd "${0:A:h}"
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
swift build -c release --product CredentialHarbor
swift build -c release --product harbor
BIN=$(swift build -c release --show-bin-path)
APP="dist/Credential Harbor.app"
mkdir -p dist
PROFILE=(signing/*.provisionprofile(N))
BUNDLE_ID=local.credentialharbor SIGN_FLAGS=() ENTITLEMENTS=""
if (( $#PROFILE )); then
  security cms -D -i "$PROFILE[1]" > dist/profile.plist
  APP_ID=$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:com.apple.application-identifier' dist/profile.plist)
  TEAM_ID=${APP_ID%%.*} BUNDLE_ID=${APP_ID#*.}
  ENTITLEMENTS=dist/entitlements.plist
  cat > "$ENTITLEMENTS" <<ENT
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>com.apple.application-identifier</key><string>$APP_ID</string>
<key>com.apple.developer.team-identifier</key><string>$TEAM_ID</string>
<key>keychain-access-groups</key><array><string>$APP_ID</string></array>
</dict></plist>
ENT
  SIGN_FLAGS=(--options runtime --timestamp)
fi
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/CredentialHarbor" "$BIN/harbor" "$APP/Contents/MacOS/"
cp Resources/logo.png Resources/AppIcon.icns Clients/harbor-container "$APP/Contents/Resources/"
(( $#PROFILE )) && cp "$PROFILE[1]" "$APP/Contents/embedded.provisionprofile"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>CredentialHarbor</string>
<key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
<key>CFBundleName</key><string>Credential Harbor</string>
<key>CFBundleDisplayName</key><string>Credential Harbor</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.6.2</string>
<key>CFBundleVersion</key><string>162</string>
<key>LSMinimumSystemVersion</key><string>15.0</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
KIND="Apple Development"
(( $#PROFILE )) && KIND="Developer ID Application"
IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null | /usr/bin/grep -o "\"$KIND: [^\"]*\"" | head -1 | tr -d '"')
if [[ -z "$IDENTITY" ]]; then
  (( $#PROFILE )) && { echo "signing/ has a profile but no $KIND certificate is in the keychain"; exit 1; }
  IDENTITY="-"
fi
codesign --force --sign "$IDENTITY" "${SIGN_FLAGS[@]}" --identifier "$BUNDLE_ID.cli" "$APP/Contents/MacOS/harbor"
codesign --force --sign "$IDENTITY" "${SIGN_FLAGS[@]}" ${ENTITLEMENTS:+--entitlements} ${ENTITLEMENTS:+"$ENTITLEMENTS"} --identifier "$BUNDLE_ID" "$APP"
codesign --verify --strict "$APP"
echo "Signed $BUNDLE_ID with: $IDENTITY"
if [[ " $* " == *" --notarize "* ]]; then
  ditto -c -k --keepParent "$APP" dist/notarize.zip
  xcrun notarytool submit dist/notarize.zip --keychain-profile harbor-notary --wait
  xcrun stapler staple "$APP"
  rm -f dist/notarize.zip
fi
if [[ " $* " == *" --install "* ]]; then
  osascript -e 'quit app "Credential Harbor"' 2>/dev/null || true
  rm -rf "$HOME/Applications/Credential Harbor.app"
  mkdir -p "$HOME/Applications" "$HOME/.local/bin"
  cp -R "$APP" "$HOME/Applications/"
  ln -sf /Users/Shared/CredentialHarbor/bin/harbor "$HOME/.local/bin/harbor"
  echo "Installed ~/Applications/Credential Harbor.app; it installs the CLI to /Users/Shared/CredentialHarbor/bin on launch"
else
  echo "Built $APP"
fi
