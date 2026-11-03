#!/bin/zsh
# zsh build-app.sh            build dist/Credential Harbor.app (app + bundled harbor CLI)
# zsh build-app.sh --install  also copy to ~/Applications and link ~/.local/bin/harbor
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
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/CredentialHarbor" "$BIN/harbor" "$APP/Contents/MacOS/"
cp Resources/logo.png Resources/AppIcon.icns Clients/harbor-container "$APP/Contents/Resources/"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>CredentialHarbor</string>
<key>CFBundleIdentifier</key><string>local.credentialharbor</string>
<key>CFBundleName</key><string>Credential Harbor</string>
<key>CFBundleDisplayName</key><string>Credential Harbor</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.5.0</string>
<key>CFBundleVersion</key><string>150</string>
<key>LSMinimumSystemVersion</key><string>15.0</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null | /usr/bin/grep -o '"Apple Development: [^"]*"' | head -1 | tr -d '"')
[[ -n "$IDENTITY" ]] || IDENTITY="-"
codesign --force --sign "$IDENTITY" --identifier local.credentialharbor.cli "$APP/Contents/MacOS/harbor"
codesign --force --sign "$IDENTITY" --identifier local.credentialharbor "$APP"
codesign --verify --strict "$APP"
echo "Signed with: $IDENTITY"
if [[ "${1:-}" == "--install" ]]; then
  osascript -e 'quit app id "local.credentialharbor"' 2>/dev/null || true
  rm -rf "$HOME/Applications/Credential Harbor.app"
  mkdir -p "$HOME/Applications" "$HOME/.local/bin"
  cp -R "$APP" "$HOME/Applications/"
  ln -sf /Users/Shared/CredentialHarbor/bin/harbor "$HOME/.local/bin/harbor"
  echo "Installed ~/Applications/Credential Harbor.app; it installs the CLI to /Users/Shared/CredentialHarbor/bin on launch"
else
  echo "Built $APP"
fi
