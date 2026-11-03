# Changelog

## Unreleased
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
