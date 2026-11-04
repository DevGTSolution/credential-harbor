import Foundation
// Exercises the real Vault code, entitled, on a dummy alias only. Never touches other credentials.
let a = "AI-Harbor-Probe"
func ok(_ c: Bool, _ n: String) { print(c ? "ok  " : "FAIL", n); if !c { exit(1) } }
func names() -> [String: Bool] { Dictionary(uniqueKeysWithValues: ((try? Vault.entries()) ?? []).map { ($0.alias, $0.synced) }) }
let before = names().filter { $0.key != a }
ok(Vault.modern, "entitled build uses the data-protection keychain")
try? Vault.remove(a)
try Vault.save(alias: a, username: "u", secret: "dummy-1")
ok((try? Vault.secret(a)) == "dummy-1", "add (local) keeps its copy")
try Vault.save(alias: a, username: "u", secret: "dummy-2")
ok((try? Vault.secret(a)) == "dummy-2", "replace (local) keeps its copy")
ok(((try? Vault.leftovers()) ?? []).isEmpty, "no leftovers reported for data-protection copies")
_ = try Vault.removeLeftovers()
ok((try? Vault.secret(a)) == "dummy-2", "remove leftovers leaves data-protection copies alone")
try Vault.save(alias: a, username: "u", secret: "dummy-3", synced: true)
ok(names()[a] == true && (try? Vault.secret(a)) == "dummy-3", "sync on")
try Vault.save(alias: a, username: "u", secret: "dummy-4", synced: false)
ok(names()[a] == false && (try? Vault.secret(a)) == "dummy-4", "sync off")
try Vault.remove(a)
ok(names()[a] == nil, "revoke removes it")
ok(names().filter { $0.key != a } == before, "every other credential untouched (\(before.count))")
