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
  harbor doctor                       why harbor can't reach the app or your key fails
  harbor run [options] [--] cmd ...   run cmd with credentials injected; output is redacted

Options (repeatable --env):
  --env NAME=VALUE    set env var; {{AI-X}} = password, {{AI-X.user}} = username
  --askpass AI-X      answer ssh password prompts and `sudo -A` with AI-X
  --stdin AI-X        write AI-X's password to the command's stdin (`sudo -S`)
  --noninteractive    for background jobs: never start the app or show a dialog;
                      exit 64 if the app lacks this mode, 77 if denied or the
                      keychain is locked or would prompt, 69 if the app isn't running
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
if let secret = ProcessInfo.processInfo.environment[Runner.askpassVariable], !["list", "run", "help", "doctor"].contains(args.dropFirst().first ?? "") {
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
    fail(Wire.explain(errno) + " Run `harbor doctor` for details.", 69)
}

/// Background mode: doesn't start the app, and asks the broker whether it supports the mode
/// before sending any fetch, so an older app never gets a request it would answer with a dialog.
func quietSession() -> LineChannel {
    func open() -> LineChannel {
        guard let fd = Wire.connect() else { fail(Wire.explain(errno), 69) }
        return LineChannel(fd)
    }
    let probe = open()
    let features: [String]
    do {
        try probe.send(Wire.Request(op: "hello"))
        features = try probe.receive(Wire.Response.self)?.features ?? []
    } catch { fail("\(error)", 69) }
    guard features.contains("noninteractive") else { fail("This Credential Harbor app doesn't support --noninteractive. Update and relaunch it.", 64) }
    return open()
}

/// Prints what this process can see, so an agent can tell its owner why harbor fails. No secrets.
func doctor() -> Never {
    let user = getpwuid(getuid()).map { String(cString: $0.pointee.pw_name) } ?? "?"
    print("user        \(user) (uid \(getuid()))")
    print("cwd         \(FileManager.default.currentDirectoryPath)")
    print("agent key   \(key.isEmpty ? "not set (fine if the owner linked this agent's app)" : "set (\(key.count) chars)")")
    print("socket      \(FileManager.default.fileExists(atPath: Wire.socketPath) ? "present" : "not visible") at \(Wire.socketPath)")
    guard let fd = Wire.connect() else { print("connect     FAILED: \(Wire.explain(errno))"); exit(69) }
    print("connect     ok")
    let channel = LineChannel(fd)
    do {
        try channel.send(Wire.Request(op: "list", key: key, cwd: FileManager.default.currentDirectoryPath))
        guard let response = try channel.receive(Wire.Response.self) else { print("broker      closed the connection"); exit(69) }
        if response.ok {
            print("agent       \(response.agent ?? "?")")
            print("may use     \(response.credentials.map(\.alias).joined(separator: ", ").nilIfEmpty ?? "nothing yet")")
            exit(0)
        }
        print("broker      DENIED: \(response.error ?? "?")"); exit(77)
    } catch { print("broker      error: \(error)"); exit(69) }
}

extension String { var nilIfEmpty: String? { isEmpty ? nil : self } }

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
    let channel = spec.noninteractive ? quietSession() : session()
    var status: Int32 = 1
    do {
        try channel.send(Wire.Request(op: "fetch", key: key, aliases: spec.aliases.sorted(),
                                      command: spec.command.joined(separator: " "), cwd: FileManager.default.currentDirectoryPath,
                                      noninteractive: spec.noninteractive ? true : nil))
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
case "doctor":
    doctor()
case "help", "-h", "--help", nil:
    print(help)
default:
    fail("unknown command \(args[1])\n\n\(help)", 64)
}
