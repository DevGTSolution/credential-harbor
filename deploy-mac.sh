#!/bin/zsh
# zsh deploy-mac.sh [user@]host ...   install dist/Credential Harbor.app on other Macs over ssh
# Builds first if dist/ is missing. Files copied over ssh carry no quarantine flag, so macOS opens
# the signed build without a Gatekeeper prompt, and the same signature keeps Keychain approvals.
# Each Mac keeps its own config; move settings with Settings → Export/Import. The app (not this
# script) creates /Users/Shared/CredentialHarbor on first launch, so that user owns it.
set -eu
cd "${0:A:h}"
(( $# )) || { print -u2 "usage: zsh deploy-mac.sh [user@]host ..."; exit 64; }
APP="dist/Credential Harbor.app"
[[ -d "$APP" ]] || zsh build-app.sh
# dist/ may sit on a shared or noowners drive where anyone could swap it: require this Mac's own signing team, not just any signature.
TEAM=${HARBOR_TEAM:-$(security find-certificate -c "Apple Development" -p 2>/dev/null | openssl x509 -noout -subject 2>/dev/null | sed -n 's/.*OU=\([A-Z0-9]*\).*/\1/p')}
[[ -n "$TEAM" ]] || { print -u2 "No Apple Development certificate here; set HARBOR_TEAM to your Team ID."; exit 1; }
REQ="anchor apple generic and certificate leaf[subject.OU] = \"$TEAM\" and identifier \"local.credentialharbor\""
codesign --verify --strict -R="$REQ" "$APP"
VERSION=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist")

for HOST in "$@"; do
  print "== $HOST: Credential Harbor $VERSION"
  ssh "$HOST" 'mkdir -p ~/Applications/"Credential Harbor.app.new" && [[ $(sw_vers -productVersion | cut -d. -f1) -ge 15 ]] || { echo "needs macOS 15 or later"; exit 1; }'
  rsync -a --delete "$APP/" "${HOST}:Applications/Credential\\ Harbor.app.new/"
  ssh "$HOST" "REQ=${(q)REQ} zsh -s" <<'REMOTE'
set -eu
NEW=~/Applications/"Credential Harbor.app.new" CUR=~/Applications/"Credential Harbor.app"
codesign --verify --strict -R="$REQ" "$NEW"
osascript -e 'quit app id "local.credentialharbor"' 2>/dev/null || pkill -x CredentialHarbor || true
for _ in {1..20}; do pgrep -x CredentialHarbor >/dev/null || break; sleep 0.5; done
if [[ -d "$CUR" ]]; then
  BACK=~/Library/"Application Support/CredentialHarbor-rollback/$(date -u +%Y%m%dT%H%M%SZ)"
  mkdir -p "$BACK" && mv "$CUR" "$BACK/" && echo "previous app kept in $BACK"
fi
mv "$NEW" "$CUR"
mkdir -p ~/.local/bin && ln -sf /Users/Shared/CredentialHarbor/bin/harbor ~/.local/bin/harbor
if open "$CUR" 2>/dev/null; then
  # The old app's socket file lingers until the new one rebinds it, so wait for a real connection.
  for _ in {1..20}; do /Users/Shared/CredentialHarbor/bin/harbor doctor 2>&1 | grep -q '^connect *ok' && break; sleep 0.5; done
  /Users/Shared/CredentialHarbor/bin/harbor doctor || true
else
  echo "Installed. Nobody is logged in to this Mac's desktop, so open Credential Harbor there."
fi
REMOTE
done
