import Foundation
import HarborCore

// The `harbor` CLI. Lives at /Users/Shared/CredentialHarbor/bin/harbor so every local user
// (the owner, service accounts) can run it. It asks Credential Harbor.app for secrets over a socket and runs
// the command as the caller. It never reads the Keychain itself.

let args = CommandLine.arguments
signal(SIGPIPE, SIG_IGN)

let help = """
Credential Harbor: use approved credentials without seeing them.

  harbor list                         credentials this agent may use (no secrets)
  harbor run [options] [--] cmd ...   run cmd with credentials injected; output is redacted

Options (repeatable --env):
  --env NAME=VALUE    set env var; {{AI-X}} = password, {{AI-X.user}} = username
  --askpass AI-X      answer ssh password prompts and `sudo -A` with AI-X
  --stdin AI-X        write AI-X's password to the command's stdin (`sudo -S`)
  {{AI-X}} / {{AI-X.user}} may also appear directly in cmd arguments.

Examples:
  harbor run --stdin AI-Server -- ssh server.local 'sudo -S -p "" launchctl list'
  harbor run --askpass AI-Server -- ssh admin@server.local uptime
  harbor run -- curl -sk -u '{{AI-Router.user}}:{{AI-Router}}' https://router.lan/api/status
  harbor run --env TF_VAR_client_secret='{{AI-CloudAPI}}' -- terraform plan

Needs HARBOR_AGENT_KEY in the environment (set by the owner in your agent's config).
Exit 77 = not allowed (tell the owner which AI- name you need), 69 = Harbor app not running.
Do not try to print or decode secrets.
"""

func fail(_ message: String, _ code: Int32) -> Never {
    FileHandle.standardError.write(Data("harbor: \(message)\n".utf8))
    exit(code)
}

// ssh/sudo call us back as their askpass helper with a prompt argument.
if let secret = ProcessInfo.processInfo.environment[Runner.askpassVariable], !["list", "run", "help"].contains(args.dropFirst().first ?? "") {
    print(secret)
    exit(0)
}

func session() -> LineChannel {
    if let fd = Wire.connect() { return LineChannel(fd) }
    if getuid() == directoryOwner() {
        // The owner's own call can start the app; other users must wait for the owner's session.
        _ = try? Process.run(URL(fileURLWithPath: "/usr/bin/open"), arguments: ["-gj", "-b", "local.credentialharbor"])
        for _ in 0..<20 { usleep(500_000); if let fd = Wire.connect() { return LineChannel(fd) } }
    }
    fail("Credential Harbor isn't running on this Mac. The owner needs to be logged in with the app open (Settings → Launch at login).", 69)
}

func directoryOwner() -> uid_t? {
    var info = stat()
    return lstat(Wire.directory, &info) == 0 ? info.st_uid : nil
}

let key = ProcessInfo.processInfo.environment[Wire.keyVariable] ?? ""

switch args.dropFirst().first {
case "list":
    let channel = session()
    do {
        try channel.send(Wire.Request(op: "list", key: key, cwd: FileManager.default.currentDirectoryPath))
        guard let response = try channel.receive(Wire.Response.self) else { fail("Credential Harbor closed the connection.", 69) }
        guard response.ok else { fail(response.error ?? "denied", 77) }
        if response.credentials.isEmpty { print("\(response.agent ?? "This agent") has no credentials yet. Ask the owner to tick some in Credential Harbor → Agents.") }
        for credential in response.credentials {
            var line = credential.alias
            if !credential.username.isEmpty { line += "\tuser=\(credential.username)" }
            if !credential.note.isEmpty { line += "\t\(credential.note)" }
            print(line)
        }
    } catch { fail("\(error)", 69) }
case "run":
    let spec: RunSpec
    do { spec = try RunSpec.parse(Array(args.dropFirst(2))) } catch { fail("\(error)\n\n\(help)", 64) }
    let channel = session()
    var status: Int32 = 1
    do {
        try channel.send(Wire.Request(op: "fetch", key: key, aliases: spec.aliases.sorted(),
                                      command: spec.command.joined(separator: " "), cwd: FileManager.default.currentDirectoryPath))
        guard let response = try channel.receive(Wire.Response.self) else { fail("Credential Harbor closed the connection.", 69) }
        guard response.ok else { fail(response.error ?? "denied", 77) }
        var secrets: [String: String] = [:], usernames: [String: String] = [:]
        for credential in response.credentials { secrets[credential.alias] = credential.secret; usernames[credential.alias] = credential.username }
        let askpass = URL(fileURLWithPath: args[0]).resolvingSymlinksInPath().path
        do {
            status = try Runner.execute(spec, secrets: secrets, usernames: usernames, askpassExecutable: askpass) { data, isError in
                (isError ? FileHandle.standardError : FileHandle.standardOutput).write(data)
            }
        } catch { FileHandle.standardError.write(Data("harbor: could not start \(spec.command[0]): \(error.localizedDescription)\n".utf8)); status = 127 }
        try? channel.send(Wire.Request(op: "done", exit: status))
    } catch { fail("\(error)", 69) }
    exit(status)
case "help", "-h", "--help", nil:
    print(help)
default:
    fail("unknown command \(args[1])\n\n\(help)", 64)
}
