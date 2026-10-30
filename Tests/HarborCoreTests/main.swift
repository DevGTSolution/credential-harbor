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

let expanded = Template.expand("-u {{AI-Pf.user}}:{{AI-Pf}} {{AI-Pf}}", secrets: ["AI-Pf": "s3cret"], usernames: ["AI-Pf": "admin"])
check(expanded == "-u admin:s3cret s3cret", "template expansion")

let redacted = Redactor.redact("token=abcd1234 inner=abcd\n", secrets: ["AI-Long": "abcd1234", "AI-Short": "abcd"])
check(redacted == "token={{AI-Long}} inner={{AI-Short}}\n", "redaction, longest first")
check(Redactor.redact("x", secrets: ["AI-Empty": ""]) == "x", "empty secret ignored")
check(Vault.isValidAlias("AI-M2_admin") && !Vault.isValidAlias("AI-") && !Vault.isValidAlias("AI-a b"), "alias validation")

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
print("PASS")
