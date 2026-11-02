# Credential Harbor how-to guide

Step-by-step recipes. The [README](../README.md) explains what Harbor is and its security model; read
that section before granting anything you care about.

* [1. Install](#1-install)
* [2. Add your first credential](#2-add-your-first-credential)
* [3. Connect an agent](#3-connect-an-agent)
* [4. Run commands with credentials](#4-run-commands-with-credentials)
* [5. Scheduled jobs and services](#5-scheduled-jobs-and-services)
* [6. Agents in Docker](#6-agents-in-docker)
* [7. Day-to-day: rotate, pause, revoke](#7-day-to-day-rotate-pause-revoke)
* [8. Troubleshooting](#8-troubleshooting)

## 1. Install

You need macOS 15 or later and Xcode 16 or later.

```sh
git clone https://github.com/DevGTSolution/credential-harbor.git
cd credential-harbor
zsh build-app.sh --install
```

1. Open **~/Applications/Credential Harbor.app**. It starts in the menu bar (shield icon), not the Dock.
2. Click the icon → **Open Credential Harbor**.
3. **Settings → Launch at login**: turn on **Start Credential Harbor in the menu bar at login**.
   `harbor` only works while the app is running.
4. Check the CLI: `harbor help`. It lives at `/Users/Shared/CredentialHarbor/bin/harbor`, linked from
   `~/.local/bin/harbor`.

Sign with an Apple Development certificate if you can (see the README's **Signing matters**).
Otherwise macOS asks for Keychain access again after every rebuild.

## 2. Add your first credential

Credential names start with `AI-`, for example `AI-Server` or `AI-CloudAPI`.

**Either** add it in the app: **Credentials → Add**, then enter the name, username (optional),
secret and a note for agents ("admin on server.local; sudo works").

**Or** keep it in your login keychain: create a password item named `AI-Server` in Keychain Access,
then click **Scan** (↻) in Harbor and approve it.

The note is what agents see in `harbor list`, so say what the credential is for. Never put a secret in it.

To tell an AI which credential to use, copy its name: the copy button next to the name on its page,
or right-click it in the list → **Copy name**. This copies the name only, never the secret.

## 3. Connect an agent

1. **Agents → Add**, pick the type (Claude, Codex, Cursor, Hermes, Other), then **Generate key**.
2. Give it the key:
   * **Claude Code / Codex:** **Add key to … config**. Harbor edits the config and keeps a
     `.before-harbor` backup.
   * **Anything else:** copy the setup line into the agent's environment.
3. **Copy AI instructions** and paste them into the agent's system prompt, `CLAUDE.md` or `AGENTS.md`.
   They contain no secrets.
4. Tick the credentials this agent may use. A new agent can use nothing.
5. Restart the agent, then ask it to run `harbor doctor` and `harbor list`.

Can't give a tool a key? Use **Linked apps** instead (see the README).

## 4. Run commands with credentials

Pick the injection that fits the tool:

| Need | Use |
|---|---|
| sudo on a remote host | `harbor run --stdin AI-Server -- ssh server.local 'sudo -S -p "" uptime'` |
| ssh password login, `sudo -A` | `harbor run --askpass AI-Server -- ssh admin@server.local uptime` |
| password or user in an argument | `harbor run -- curl -u '{{AI-Router.user}}:{{AI-Router}}' https://router.lan/api` |
| API key in an environment variable | `harbor run --env API_TOKEN='{{AI-CloudAPI}}' -- ./deploy.sh` |

* `{{AI-X}}` is the secret and `{{AI-X.user}}` the username.
* Any secret that shows up in the output is replaced with `{{AI-X}}`.
* Prefer `--stdin`, `--askpass` or `--env` over `{{…}}` in arguments: arguments are visible in `ps`.

## 5. Scheduled jobs and services

Background jobs must never hang on a dialog. Add `--noninteractive`, and branch on the exit code:

```sh
harbor run --noninteractive --env API_TOKEN='{{AI-CloudAPI}}' -- ./nightly-sync.sh
case $? in
  77) echo "denied, keychain locked, or macOS would prompt" ;;
  69) echo "Credential Harbor isn't running" ;;
  64) echo "app too old for --noninteractive; update it" ;;
esac
```

**Give a service its own key file** instead of putting the key in its config:

1. **Agents → Add → Other**, name it (for example "Backup Service"), tick its credentials.
2. **Generate key → Write key file**. Harbor writes
   `/Users/Shared/CredentialHarbor/keys/backup-service.key` (0600, in a 0700 folder). It won't
   overwrite a file that belongs to another agent.
3. Have the job read the file at start:

```sh
HARBOR_AGENT_KEY="$(cat /Users/Shared/CredentialHarbor/keys/backup-service.key)" \
  harbor run --noninteractive --stdin AI-Server -- ssh server.local 'sudo -S -p "" ./backup.sh'
```

Run the job as the same user that owns the key folder. A job that runs before you log in fails with
69, because the app isn't running yet.

## 6. Agents in Docker

1. **Settings → Containers**: turn it on. Harbor also listens on `127.0.0.1:47821`.
2. Give the agent the **Hermes** (container) type, then **Generate key → Write key file**.
3. Mount the CLI folder and the key read-only (create the key file first):

```yaml
services:
  agent:
    volumes:
      - /Users/Shared/CredentialHarbor/bin:/opt/harbor:ro
      - /Users/Shared/CredentialHarbor/keys/hermes.key:/run/secrets/harbor_agent_key:ro
```

4. Inside the container: `python3 /opt/harbor/harbor-container doctor`.

## 7. Day-to-day: rotate, pause, revoke

* **Rotate a secret:** open the credential → **Replace secret**. Names, notes and agent access stay the same.
* **Replace an agent's key:** **Replace key** on the agent. Key files are rewritten in place, so a running
  container picks up the new one; config-based agents need the new key and a restart.
* **Stop one agent:** turn on its **Paused** switch (temporary), or untick its credentials (revoke).
* **Stop everything:** **Settings → Pause all**. Every call is denied; nothing is revoked.
* **See what happened:** **Activity** shows who asked for what, and the exit code. The menu bar
  menu shows the last few requests. Secret values are never logged.
* **Quitting Harbor** cuts every agent off until it's running again.

## 8. Troubleshooting

Start with `harbor doctor`: it says which of these it is.

| Symptom | Cause | Fix |
|---|---|---|
| exit 69 | app not running | open it from the menu bar or Spotlight; turn on launch at login |
| exit 69 inside an agent only | the agent's sandbox blocks local sockets | allow `/Users/Shared/CredentialHarbor/harbor.sock` (Codex: see the README's allow rules) |
| exit 77 | agent paused, credential not ticked, Pause all on, or keychain locked | check the agent in Harbor; with `--noninteractive`, also any case that would need a dialog |
| exit 64 | the app is older than the CLI | rebuild and reinstall the app |
| macOS asks for Keychain access after every rebuild | app signed ad hoc | sign with an Apple Development certificate |
| container: connection refused | Settings → Containers is off | turn it on |
| container: key path is a directory | Docker created it before the key file existed | delete it, **Write key file**, recreate the container |
