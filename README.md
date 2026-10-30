<p align="center"><img src="Resources/logo.png" width="128" alt="Credential Harbor logo"></p>

# Credential Harbor

**Let AI agents use your Mac's Keychain credentials without seeing them.**

AI coding agents (Claude Code, Codex, Cursor, your own bots) keep stopping to ask for a
password, an API key or a sudo prompt. Pasting secrets into a chat puts them in transcripts
and logs. Credential Harbor is a small macOS app plus a `harbor` CLI. You approve credentials
once, you decide which agent may use which one, and agents run commands with those
credentials injected. The values never enter the model's context.

```sh
harbor run --stdin AI-Server -- ssh server.local 'sudo -S -p "" launchctl list'
harbor run -- curl -sk -u '{{AI-Router.user}}:{{AI-Router}}' https://router.lan/api/status
harbor run --env TF_VAR_client_secret='{{AI-CloudAPI}}' -- terraform plan
```

<p align="center"><img src="docs/settings.jpg" width="720" alt="Credential Harbor settings screen"></p>

## How it works

* **You approve credentials.** Add one in the app, or approve any login-keychain item whose name
  starts with `AI-`. Harbor keeps its own copy, which macOS lets only Harbor read.
* **You register agents.** Each agent gets a key (`HARBOR_AGENT_KEY`) that goes in its
  environment or config, never in a prompt. A new agent can use nothing until you tick credentials for it.
* **Agents call `harbor`.** The CLI sends the agent key and the credential names to the app over a
  local socket, gets the values back, and runs the command **as the caller**. Secrets are injected
  through `{{AI-X}}` / `{{AI-X.user}}` placeholders, `--env`, `--stdin`, or `--askpass` (answers ssh
  and `sudo -A` prompts). Every occurrence in the output is replaced with `{{AI-X}}`.
* **You stay in control.** Activity log (who, what, exit code), per-agent pause, revoke, Pause all,
  notifications for denied or unknown callers, a per-credential health check, and four themes.

Permissions last until you revoke them: no timers, and no prompt per command.

## Install (build from source)

Requires macOS 14+ and Xcode 16+.

```sh
git clone https://github.com/DevGTSolution/credential-harbor.git
cd credential-harbor
zsh build-app.sh --install    # → ~/Applications/Credential Harbor.app
```

On first launch the app installs the CLI to `/Users/Shared/CredentialHarbor/bin/harbor`, and the
build links it to `~/.local/bin/harbor`. Turn on **Settings → Launch at login**, because `harbor`
only works while the app is running.

**Signing matters.** macOS remembers "Always Allow" for Keychain access per Team ID. If you have
an *Apple Development* certificate (free with any Apple ID: Xcode → Settings → Accounts → Manage
Certificates → +), `build-app.sh` signs with it, and rebuilds keep access. Otherwise the app is signed
ad hoc, and macOS asks again for each credential after every rebuild. If the certificate shows as
invalid, install Apple's [WWDR G3 intermediate](https://www.apple.com/certificateauthority/).

## Set up an agent

1. **Agents → Add** (or pick Claude / Codex / Cursor), then **Generate key**. The Connect screen has two steps:
   * **Give it its key.** For Claude Code and Codex, **Add key to … config** writes `HARBOR_AGENT_KEY`
     into `~/.claude/settings.json` or `~/.codex/config.toml`, keeping a `.before-harbor` backup. For Codex it
     also sets `[sandbox_workspace_write] network_access = true`, because Codex's sandbox otherwise blocks the
     Harbor socket. For other agents, copy the setup line into their environment. The key belongs in config,
     never in a prompt.
   * **Tell it to use Harbor.** Use **Copy AI instructions** and paste them into its system prompt, `AGENTS.md`
     or `CLAUDE.md`. They contain no secrets.
2. Tick the credentials it may use.
3. Restart the agent so it picks up the new environment, then have it run `harbor doctor`.

If an agent can't edit its own config, the Connect screen also offers a one-message self-setup prompt.
It contains the key, so it stays in that chat's history.

`harbor list` shows an agent what it may use, along with your notes. Exit code 77 means "not allowed";
69 means the CLI can't reach the app. `harbor doctor` says why: the app isn't running, the agent can't see
`/Users/Shared` (container/VM), or **the agent's sandbox blocks local sockets**. Many agent sandboxes do this
by default, so allow that agent to reach `/Users/Shared/CredentialHarbor/harbor.sock`.

## Security model: read this

Credential Harbor keeps secrets out of model context and out of logs. It is **not** a sandbox.

* Agent keys give attribution and per-agent limits, not proof of identity. Any process running as
  your user can read another agent's config, and Harbor policy lives in your home folder.
* Redaction prevents accidents. An agent that deliberately wants a value it is allowed to use can get
  it (`--env P='{{AI-X}}' -- sh -c 'echo $P | rev'`). Only grant credentials you would trust that agent
  with, and prefer least-privilege accounts and tokens.
* `--env` and `--askpass` put the value in the child process's environment, which is visible to
  same-user processes. `{{…}}` in arguments is visible in `ps`.
* The socket (`/Users/Shared/CredentialHarbor/harbor.sock`) accepts any local user. A valid agent key
  is what grants anything. That lets a service account run agents while the owner's session holds the
  Keychain.

## Development

```sh
swift run HarborChecks                       # logic checks
swift tools/make-icon.swift Resources/source-icon.png Resources \
  && iconutil -c icns Resources/AppIcon.iconset -o Resources/AppIcon.icns
```

`Sources/HarborCore` holds the Keychain vault, command runner, redaction and the socket protocol.
`Sources/CredentialHarbor` is the SwiftUI app and broker. `Sources/harbor` is the CLI.

## License

[MIT](LICENSE)
