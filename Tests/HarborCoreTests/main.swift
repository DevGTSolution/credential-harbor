import Foundation
import HarborCore

// Pure-logic checks; Keychain and process paths are covered by the end-to-end run in README.
func check(_ condition: Bool, _ name: String) { if !condition { print("FAIL \(name)"); exit(1) }; print("ok   \(name)") }

let spec = try RunSpec.parse(["--env", "TF_VAR_x={{AI-Cloud}}", "--askpass", "AI-Server", "--", "curl", "-u", "{{AI-Pf.user}}:{{AI-Pf}}", "url"])
check(spec.command == ["curl", "-u", "{{AI-Pf.user}}:{{AI-Pf}}", "url"], "command after --")
check(spec.aliases == ["AI-Cloud", "AI-Pf", "AI-Server"], "aliases from env, askpass and args")
check(try RunSpec.parse(["ssh", "host", "--env"]).command == ["ssh", "host", "--env"], "options stop at first command word")
check((try? RunSpec.parse(["--env", "x"])) == nil, "malformed --env rejected")
check((try? RunSpec.parse(["--askpass", "Bad"])) == nil, "non AI- alias rejected")
check((try? RunSpec.parse([])) == nil, "missing command rejected")
let quiet = try RunSpec.parse(["--noninteractive", "--stdin", "AI-Key", "--", "receiver"])
check(quiet.noninteractive && quiet.stdin == "AI-Key" && quiet.command == ["receiver"], "--noninteractive parsed")
check(!(try RunSpec.parse(["ssh", "--noninteractive"])).noninteractive, "--noninteractive after the command is the command's")
let oldRequest = try JSONDecoder().decode(Wire.Request.self, from: Data(#"{"op":"fetch","key":"","aliases":[],"command":"","cwd":""}"#.utf8))
check(oldRequest.noninteractive == nil, "requests without the field stay interactive")

let expanded = Template.expand("-u {{AI-Pf.user}}:{{AI-Pf}} {{AI-Pf}}", secrets: ["AI-Pf": "s3cret"], usernames: ["AI-Pf": "admin"])
check(expanded == "-u admin:s3cret s3cret", "template expansion")

let redacted = Redactor.redact("token=abcd1234 inner=abcd\n", secrets: ["AI-Long": "abcd1234", "AI-Short": "abcd"])
check(redacted == "token={{AI-Long}} inner={{AI-Short}}\n", "redaction, longest first")
check(Redactor.redact("x", secrets: ["AI-Empty": ""]) == "x", "empty secret ignored")
check(Vault.isValidAlias("AI-Host_admin") && !Vault.isValidAlias("AI-") && !Vault.isValidAlias("AI-a b"), "alias validation")

// Config patching: the user's real Codex layout already has [shell_environment_policy.set].
let codex = "approval_policy = \"never\"\n\n[shell_environment_policy.set]\nOTHER = \"x\"\n\n[mcp_servers.a]\ncommand = \"b\""
let withKey = try ConfigPatch.toml(codex, table: "shell_environment_policy.set", key: "HARBOR_AGENT_KEY", value: "\"k1\"")
check(withKey.contains("[shell_environment_policy.set]\nHARBOR_AGENT_KEY = \"k1\"\nOTHER = \"x\""), "toml: key added under existing table")
let rekeyed = try ConfigPatch.toml(withKey, table: "shell_environment_policy.set", key: "HARBOR_AGENT_KEY", value: "\"k2\"")
check(rekeyed.contains("HARBOR_AGENT_KEY = \"k2\"") && !rekeyed.contains("k1"), "toml: key replaced, not duplicated")
let net = try ConfigPatch.toml(rekeyed, table: "sandbox_workspace_write", key: "network_access", value: "true")
check(net.hasSuffix("\n[sandbox_workspace_write]\nnetwork_access = true\n") && net.hasPrefix(codex.prefix(30)), "toml: missing table appended, rest kept")
check((try? ConfigPatch.toml("[shell_environment_policy]\nset = { A = \"1\" }\n", table: "shell_environment_policy.set", key: "K", value: "\"v\"")) == nil, "toml: inline parent table refused")
let json = try ConfigPatch.jsonEnv(Data(#"{"model":"opus","env":{"A":"1"}}"#.utf8), key: "HARBOR_AGENT_KEY", value: "k")
let parsed = try JSONSerialization.jsonObject(with: json) as! [String: Any]
check((parsed["env"] as! [String: String]) == ["A": "1", "HARBOR_AGENT_KEY": "k"] && parsed["model"] as? String == "opus", "json: env key merged, rest kept")
check((try? ConfigPatch.jsonEnv(Data("{oops".utf8), key: "K", value: "v")) == nil, "json: invalid file refused")
// Service key files: 0600 from creation, 0700 folder, replace keeps 0600, slug is stable.
let keyDir = NSTemporaryDirectory() + "harbor-keyfile-\(getpid())"
KeyFile.directory = keyDir
check(KeyFile.path(for: "Backup Service") == keyDir + "/backup-service.key", "keyfile: slug from agent name")
let keyPath = KeyFile.path(for: "Backup Service")
umask(0)  // a permissive umask must not widen the file
try KeyFile.write("hbk_test1", to: keyPath)
var st = stat(); lstat(keyPath, &st); var dt = stat(); lstat(keyDir, &dt)
check(st.st_mode & 0o777 == 0o600 && dt.st_mode & 0o777 == 0o700, "keyfile: file 0600, folder 0700")
try KeyFile.write("hbk_test2", to: keyPath); lstat(keyPath, &st)
check((try? String(contentsOfFile: keyPath, encoding: .utf8)) == "hbk_test2\n" && st.st_mode & 0o777 == 0o600, "keyfile: replace keeps 0600")
check(!FileManager.default.fileExists(atPath: keyPath + ".new"), "keyfile: no temp left")
// Ownership: a name can't take Hermes's file, another agent's file, or a file Harbor didn't write for it.
func refused(_ body: () throws -> Void) -> Bool { (try? body()) == nil }
check(KeyFile.path(for: "Hermes") == keyDir + "/hermes.key", "keyfile: an Other agent named Hermes maps to hermes.key")
check(refused { try KeyFile.claim(KeyFile.path(for: "Hermes"), for: "A", owned: [:]) }, "keyfile: hermes.key reserved")
check(refused { try KeyFile.claim(keyPath, for: "B", owned: ["A": keyPath]) }, "keyfile: another agent's file refused")
check(refused { try KeyFile.claim(keyPath, for: "B", owned: [:]) }, "keyfile: existing unrecorded file refused")
check(!refused { try KeyFile.claim(keyPath, for: "A", owned: ["A": keyPath]) }, "keyfile: owner may rewrite its own file")
check(!refused { try KeyFile.claim(keyDir + "/fresh.key", for: "C", owned: ["A": keyPath]) }, "keyfile: fresh path allowed")
// Shared folders: a symlink (or anything not a real folder you own) is refused.
let realDir = keyDir + "/real", linkDir = keyDir + "/link"
try KeyFile.ownedFolder(realDir, mode: 0o755); var rt = stat(); lstat(realDir, &rt)
check(rt.st_mode & 0o777 == 0o755, "owned folder: created with its mode")
symlink(realDir, linkDir)
check(refused { try KeyFile.ownedFolder(linkDir, mode: 0o755) }, "owned folder: symlink refused")
check(refused { try KeyFile.ownedFolder(keyPath, mode: 0o700) }, "owned folder: a file refused")
umask(0o022); try? FileManager.default.removeItem(atPath: keyDir)
check(versionLabel(["CFBundleShortVersionString": "1.4.0", "CFBundleVersion": "140"]) == "Credential Harbor 1.4.0 (140)", "version label: short + build")
check(versionLabel(["CFBundleShortVersionString": "1.4.0"]) == "Credential Harbor 1.4.0", "version label: no build")
check(versionLabel(nil) == "Credential Harbor" && versionLabel(["CFBundleShortVersionString": ""]) == "Credential Harbor", "version label: unbundled falls back")
// Settings files: no keys travel, bad files are refused, and every access change is listed.
let opts = SettingsFile.Options(pauseAll: false, notify: "Never", retentionDays: 30, theme: "Harbor", containers: false)
let here = SettingsFile(agents: [.init(name: "Claude", kind: "Claude", allowed: ["AI-A"], paused: true, links: []),
                                 .init(name: "Local", kind: "Other", allowed: [], paused: false, links: [])], notes: ["AI-A": "old"], options: opts)
var moreOpts = opts; moreOpts.containers = true
let there = SettingsFile(agents: [.init(name: "Claude", kind: "Claude", allowed: ["AI-A", "AI-B"], paused: false, links: ["/Applications/X.app"]),
                                  .init(name: "Bot", kind: "Other", allowed: ["AI-C"], paused: false, links: [])], notes: ["AI-A": "new"], options: moreOpts)
let roundTrip = try SettingsFile.read(JSONEncoder().encode(there))
check(roundTrip == there, "settings file: round trip")
check(!String(decoding: try JSONEncoder().encode(there), as: UTF8.self).contains("key"), "settings file: no key fields")
check(refused { _ = try SettingsFile.read(Data(#"{"agents":[]}"#.utf8)) }, "settings file: other JSON refused")
var badAlias = there; badAlias.agents[0].allowed = ["password"]
check(refused { _ = try SettingsFile.read(JSONEncoder().encode(badAlias)) }, "settings file: bad credential name refused")
var badLink = there; badLink.agents[0].links = ["X.app"]
check(refused { _ = try SettingsFile.read(JSONEncoder().encode(badLink)) }, "settings file: relative link refused")
var badDays = there; badDays.options.retentionDays = -1
check(refused { _ = try SettingsFile.read(JSONEncoder().encode(badDays)) }, "settings file: bad retention refused")
let merged = here.merging(there)
check(merged.agents.map(\.name) == ["Claude", "Local", "Bot"] && merged.agents[0].allowed == ["AI-A", "AI-B"] && merged.notes["AI-A"] == "new", "settings file: merge by name, local agents kept")
let lines = here.changes(importing: there)
check(lines.contains("Claude may now use AI-B") && lines.contains("Claude gets linked apps, no key needed: /Applications/X.app")
      && lines.contains("Claude is unpaused") && lines.contains { $0.hasPrefix("New agent Bot") }
      && lines.contains { $0.hasPrefix("Containers (Docker) turns on") }, "settings file: access changes listed")
check(here.changes(importing: here).isEmpty, "settings file: same settings, no changes")
// Unentitled (no provisioning profile): login keychain only, and sync is refused before any keychain write.
check(!Vault.modern, "vault: unentitled build stays on the login keychain")
check(refused { try Vault.save(alias: "AI-SyncProbe", username: "", secret: "x", synced: true) }, "vault: sync refused without Developer ID")
print("PASS")
