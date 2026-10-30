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
print("PASS")
