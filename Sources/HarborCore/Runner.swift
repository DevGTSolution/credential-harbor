import Foundation

/// `harbor run [--env NAME=VALUE]... [--askpass AI-X] [--stdin AI-X] [--] command args...`
/// `{{AI-X}}` in VALUE or args becomes the password, `{{AI-X.user}}` the username.
public struct RunSpec: Equatable, Sendable {
    public var env: [String: String] = [:]
    public var askpass: String?
    public var stdin: String?
    public var command: [String] = []

    public init(env: [String: String] = [:], askpass: String? = nil, stdin: String? = nil, command: [String] = []) {
        self.env = env; self.askpass = askpass; self.stdin = stdin; self.command = command
    }

    /// Every alias the command needs, so they can be fetched (and audited) up front.
    public var aliases: Set<String> {
        var names = Set([askpass, stdin].compactMap { $0 })
        for text in command + env.values { names.formUnion(Template.references(in: text).map(\.alias)) }
        return names
    }

    public static func parse(_ args: [String]) throws -> RunSpec {
        var spec = RunSpec()
        var index = 0
        func value(_ flag: String) throws -> String {
            index += 1
            guard index < args.count else { throw HarborError.usage("\(flag) needs a value") }
            return args[index]
        }
        while index < args.count {
            let arg = args[index]
            switch arg {
            case "--env":
                let pair = try value(arg)
                guard let eq = pair.firstIndex(of: "="), eq != pair.startIndex else { throw HarborError.usage("--env expects NAME=VALUE, got \(pair)") }
                spec.env[String(pair[..<eq])] = String(pair[pair.index(after: eq)...])
            case "--askpass": spec.askpass = try value(arg)
            case "--stdin": spec.stdin = try value(arg)
            case "--": spec.command = Array(args[(index + 1)...]); index = args.count
            default:
                guard !arg.hasPrefix("--") else { throw HarborError.usage("Unknown option \(arg)") }
                spec.command = Array(args[index...]); index = args.count
            }
            index += 1
        }
        guard !spec.command.isEmpty else { throw HarborError.usage("No command given. Example: harbor run --askpass AI-Server -- ssh admin@server.local uptime") }
        for alias in spec.aliases where !Vault.isValidAlias(alias) { throw HarborError.invalidAlias(alias) }
        return spec
    }
}

public enum Template {
    public struct Reference: Hashable { public let token: String; public let alias: String; public let user: Bool }
    private static let pattern = try! NSRegularExpression(pattern: #"\{\{(AI-[A-Za-z0-9_-]+)(\.user)?\}\}"#)

    public static func references(in text: String) -> [Reference] {
        pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)).map { match in
            Reference(token: String(text[Range(match.range, in: text)!]),
                      alias: String(text[Range(match.range(at: 1), in: text)!]),
                      user: match.range(at: 2).location != NSNotFound)
        }
    }

    public static func expand(_ text: String, secrets: [String: String], usernames: [String: String]) -> String {
        references(in: text).reduce(text) { result, ref in
            result.replacingOccurrences(of: ref.token, with: (ref.user ? usernames : secrets)[ref.alias] ?? "")
        }
    }
}

public enum Redactor {
    /// Longest first so a secret containing another secret is masked whole.
    public static func redact(_ text: String, secrets: [String: String]) -> String {
        secrets.filter { !$0.value.isEmpty }.sorted { $0.value.count > $1.value.count }
            .reduce(text) { $0.replacingOccurrences(of: $1.value, with: "{{\($1.key)}}") }
    }
}

public enum Runner {
    public static let askpassVariable = "HARBOR_ASKPASS_SECRET"

    /// Runs the command with secrets injected; every output chunk is redacted before `output` sees it.
    public static func execute(_ spec: RunSpec, secrets: [String: String], usernames: [String: String],
                               askpassExecutable: String, timeout: TimeInterval? = nil,
                               output: @escaping @Sendable (Data, _ isError: Bool) -> Void) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = spec.command.map { Template.expand($0, secrets: secrets, usernames: usernames) }
        var environment = ProcessInfo.processInfo.environment
        environment.removeValue(forKey: Wire.keyVariable) // the child doesn't need the agent key
        for (name, value) in spec.env { environment[name] = Template.expand(value, secrets: secrets, usernames: usernames) }
        if let alias = spec.askpass {
            // ponytail: secret rides in the child's env (same exposure as --env); a one-shot socket would avoid that.
            environment[askpassVariable] = secrets[alias]
            environment["SSH_ASKPASS"] = askpassExecutable
            environment["SSH_ASKPASS_REQUIRE"] = "force"
            environment["SUDO_ASKPASS"] = askpassExecutable
        }
        process.environment = environment

        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        let input = spec.stdin.map { _ in Pipe() }
        if let input { process.standardInput = input }
        try process.run()
        if let input, let alias = spec.stdin {
            input.fileHandleForWriting.write(Data(((secrets[alias] ?? "") + "\n").utf8))
            try? input.fileHandleForWriting.close()
        }
        if let timeout { DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { if process.isRunning { process.terminate() } } }
        let group = DispatchGroup()
        pump(out, secrets: secrets, group: group) { output($0, false) }
        pump(err, secrets: secrets, group: group) { output($0, true) }
        process.waitUntilExit()
        group.wait()
        return process.terminationStatus
    }

    // ponytail: line-buffered, so output without newlines (progress bars) shows at the end.
    private static func pump(_ pipe: Pipe, secrets: [String: String], group: DispatchGroup, emit: @escaping @Sendable (Data) -> Void) {
        DispatchQueue.global().async(group: group) {
            let reader = pipe.fileHandleForReading
            var buffer = Data()
            func flush(_ chunk: Data) { emit(Data(Redactor.redact(String(decoding: chunk, as: UTF8.self), secrets: secrets).utf8)) }
            while case let chunk = reader.availableData, !chunk.isEmpty {
                buffer.append(chunk)
                while let newline = buffer.firstIndex(of: 0x0A) {
                    flush(buffer[...newline])
                    buffer = Data(buffer[buffer.index(after: newline)...])
                }
            }
            if !buffer.isEmpty { flush(buffer) }
        }
    }
}
