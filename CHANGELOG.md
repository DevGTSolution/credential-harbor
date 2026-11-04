# Changelog

## 1.6.1
* **Search** on the Credentials page: filters by name, username and note (and Keychain items found by Scan).
* **Remove old copies:** after moving to the 1.6 keychain, removes the login-keychain copies kept for rollback
  (only ones whose credential already has its new copy).
* When a Mac holds both a synced and a local copy of a credential, Harbor uses the synced one everywhere.

## 1.6.0
* **iCloud Keychain sync, per credential** (Developer ID builds): a **Sync with iCloud Keychain** switch on each
  credential. Only builds signed by your team can read synced copies.
* Developer ID builds keep Harbor's copies in the data-protection keychain: no more Keychain prompts, even after
  rebuilds or certificate renewals. **Move now** moves existing credentials once (old copies kept for rollback).
* `build-app.sh` signs Developer ID with the hardened runtime when `signing/` has a profile; `--notarize` notarizes.
  Free-account builds work as before.
* `deploy-mac.sh [user@]host …` installs the signed build on other Macs over ssh, refusing builds not signed by your team.

## 1.5.0
* **Move to another Mac:** Settings → Export settings… / Import settings…, through iCloud Drive by default.
  Import lists every change first. No secrets, usernames, agent keys or health-check commands travel.
  See the [guide](docs/guide.md#8-move-to-another-mac).
* **Security:** Harbor refuses its shared folders (`/Users/Shared/CredentialHarbor`, `bin`, `keys`) when
  another account created them first, since whoever owns them controls the CLI and socket agents use.

## 1.4.2
* **Copy name:** a copy button next to a credential's name, and **Copy name** when you right-click it in
  the list, for telling an AI which credential to use. Copies the name only, never the secret.

## 1.4.1
* Menu bar mode: starts in the background with a menu bar icon.
* `harbor run --noninteractive` for scheduled jobs: never shows a dialog, exits 77 instead.
* Service key files: **Write key file** for Other agents.
* **Replace secret** and **Replace key** for rotation.
