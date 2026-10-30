import CryptoKit
import Foundation
import HarborCore
import UserNotifications

enum AgentKind: String, Codable, CaseIterable, Identifiable {
    case claude = "Claude", codex = "Codex", cursor = "Cursor", hermes = "Hermes", other = "Other"
    var id: String { rawValue }

    func setup(key: String) -> String {
        switch self {
        case .claude: return "Add to ~/.claude/settings.json:\n  \"env\": { \"HARBOR_AGENT_KEY\": \"\(key)\" }"
        case .codex: return "Add to ~/.codex/config.toml (under an existing [shell_environment_policy.set] if you have one):\n  [shell_environment_policy.set]\n  HARBOR_AGENT_KEY = \"\(key)\"\n\n  [sandbox_workspace_write]\n  network_access = true   # lets sandboxed commands reach Harbor"
        case .cursor: return "Add to the shell profile Cursor's agent uses (e.g. ~/.zshrc):\n  export HARBOR_AGENT_KEY=\(key)"
        case .hermes: return "Add to the Hermes .env (as the hermes user):\n  HARBOR_AGENT_KEY=\(key)\nand put /Users/Shared/CredentialHarbor/bin on its PATH."
        case .other: return "Set in that agent's environment or .env:\n  HARBOR_AGENT_KEY=\(key)"
        }
    }

    /// The config file Harbor can write the key into for you, if this kind has one.
    var configFile: URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        switch self {
        case .claude: return home.appendingPathComponent(".claude/settings.json")
        case .codex: return home.appendingPathComponent(".codex/config.toml")
        default: return nil
        }
    }

    /// Writes the key (and, for Codex, socket access for its sandbox) into the agent's config.
    /// Keeps a one-time backup next to the file. Returns a sentence describing the change.
    func install(key: String) throws -> String {
        guard let file = configFile else { throw HarborError.usage("\(rawValue) has no config Harbor can edit; use Copy setup.") }
        let original = try? Data(contentsOf: file)
        let updated: Data
        switch self {
        case .codex:
            var text = original.map { String(decoding: $0, as: UTF8.self) } ?? ""
            text = try ConfigPatch.toml(text, table: "shell_environment_policy.set", key: "HARBOR_AGENT_KEY", value: "\"\(key)\"")
            text = try ConfigPatch.toml(text, table: "sandbox_workspace_write", key: "network_access", value: "true")
            updated = Data(text.utf8)
        default:
            updated = try ConfigPatch.jsonEnv(original, key: "HARBOR_AGENT_KEY", value: key)
        }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let backup = file.appendingPathExtension("before-harbor")
        if let original, !FileManager.default.fileExists(atPath: backup.path) { try original.write(to: backup) }
        try updated.write(to: file) // in place, not atomic rename: keeps the file's inode for anything watching it
        let path = file.path.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~")
        return self == .codex
            ? "Added the key to \(path) and let Codex's sandbox reach Harbor (network_access). Quit and reopen Codex."
            : "Added the key to \(path). Restart \(rawValue) sessions."
    }

}

struct Agent: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var kind: AgentKind
    var keyHash: String?
    var keyCreated: Date?
    var allowed: Set<String> = []
    var paused = false
    var lastUsed: Date?
}

struct Health: Codable, Hashable {
    var ok: Bool
    var date: Date
    var output: String
}

struct CredentialMeta: Codable, Hashable {
    var note = ""
    var test = ""
    var health: Health?
    var lastUsed: Date?
}

enum NotifyLevel: String, Codable, CaseIterable, Identifiable {
    case all = "Every use", denied = "Denied and unknown only", never = "Never"
    var id: String { rawValue }
}

struct Settings: Codable, Hashable {
    var pauseAll = false
    var notify = NotifyLevel.denied
    var retentionDays = 30
    var theme = ThemeName.harbor

    init() {}
    /// Tolerates configs written by older versions (missing keys keep their defaults).
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        pauseAll = try c.decodeIfPresent(Bool.self, forKey: .pauseAll) ?? false
        notify = try c.decodeIfPresent(NotifyLevel.self, forKey: .notify) ?? .denied
        retentionDays = try c.decodeIfPresent(Int.self, forKey: .retentionDays) ?? 30
        theme = (try? c.decodeIfPresent(ThemeName.self, forKey: .theme)) ?? .harbor
    }
}

struct Config: Codable {
    var agents: [Agent] = ["Claude", "Codex", "Cursor"].map {
        Agent(name: $0, kind: AgentKind(rawValue: $0) ?? .other)
    }
    var credentials: [String: CredentialMeta] = [:]
    var settings = Settings()
}

struct Event: Codable, Identifiable, Hashable {
    var id = UUID()
    var date = Date()
    var agent: String
    var agentID: UUID?   // nil for unknown callers and for events from before 1.2
    var user: String
    var aliases: [String]
    var command: String
    var cwd: String
    var result: String
    var ok: Bool?   // nil while running
}

/// Policy + activity, shared by the socket threads and the UI. Persisted (0600) in
/// ~/Library/Application Support/Credential Harbor. The keychain is the secret store;
/// this file only holds names, key hashes and settings.
// ponytail: a same-user process could edit config.json while the app is closed; agent keys are
// attribution and limits, not a hard boundary (see SPEC-1.1.md).
final class Store: @unchecked Sendable {
    static let shared = Store()

    private let lock = NSLock()
    private var config: Config
    private var events: [Event]
    var onChange: (@Sendable () -> Void)?

    private static let folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Credential Harbor")
    private static let configFile = folder.appendingPathComponent("config.json")
    private static let eventsFile = folder.appendingPathComponent("activity.json")

    private init() {
        config = (try? JSONDecoder.iso.decode(Config.self, from: Data(contentsOf: Self.configFile))) ?? Config()
        events = (try? JSONDecoder.iso.decode([Event].self, from: Data(contentsOf: Self.eventsFile))) ?? []
        prune()
        save()
    }

    // MARK: Reads for the UI

    func snapshot() -> (Config, [Event]) { lock.withLock { (config, events) } }

    // MARK: Owner edits (UI only)

    func update(_ change: (inout Config) -> Void) {
        lock.withLock { change(&config); persist() }
        onChange?()
    }

    /// Returns the new key. Only its hash is kept, so the owner must copy it now.
    func newKey(for agentID: UUID) -> String {
        var bytes = [UInt8](repeating: 0, count: 24)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let key = "hbk_" + bytes.map { String(format: "%02x", $0) }.joined()
        update { config in
            guard let index = config.agents.firstIndex(where: { $0.id == agentID }) else { return }
            config.agents[index].keyHash = Self.hash(key)
            config.agents[index].keyCreated = Date()
        }
        return key
    }

    func record(_ event: Event) {
        lock.withLock { events.append(event); persist() }
        onChange?()
    }

    func prune() {
        lock.withLock {
            let cutoff = Date().addingTimeInterval(-Double(config.settings.retentionDays) * 86400)
            events.removeAll { $0.date < cutoff }
            if events.count > 10_000 { events.removeFirst(events.count - 10_000) }
        }
    }

    // MARK: Socket requests (background threads)

    /// Handles one CLI connection: fetch/list, then an optional "done" with the exit code.
    func serve(_ fd: Int32) {
        let channel = LineChannel(fd)
        let user = Self.peerUser(fd)
        guard let request = try? channel.receive(Wire.Request.self) else { return }
        var event = Event(agent: "Unknown", user: user, aliases: request.aliases, command: request.command, cwd: request.cwd, result: "")
        let response = decide(request, event: &event)
        try? channel.send(response)

        guard request.op == "fetch" else { return }
        if response.ok {
            let done = (try? channel.receive(Wire.Request.self)) ?? nil
            let code = done?.exit
            event.result = code.map { "exit \($0)" } ?? "ended without exit code"
            event.ok = code == 0
        }
        record(event)
        notify(event, denied: !response.ok)
    }

    private func decide(_ request: Wire.Request, event: inout Event) -> Wire.Response {
        let snapshot = lock.withLock { config }
        guard !request.key.isEmpty else {
            event.result = "denied: no agent key"; event.ok = false
            return .deny("No HARBOR_AGENT_KEY in this environment. The owner adds this agent in Credential Harbor → Agents and puts its key in the agent's config.")
        }
        guard let agent = snapshot.agents.first(where: { $0.keyHash == Self.hash(request.key) }) else {
            event.result = "denied: unknown agent key"; event.ok = false
            return .deny("Unknown agent key. Ask the owner to add or re-key this agent in Credential Harbor → Agents.")
        }
        event.agent = agent.name; event.agentID = agent.id
        if snapshot.settings.pauseAll { event.result = "denied: Harbor paused"; event.ok = false; return .deny("Credential Harbor is paused by the owner.") }
        if agent.paused { event.result = "denied: agent paused"; event.ok = false; return .deny("\(agent.name) is paused in Credential Harbor.") }

        let approved = (try? Vault.entries()) ?? []
        if request.op == "list" {
            let mine = approved.filter { agent.allowed.contains($0.alias) }
            return Wire.Response(ok: true, agent: agent.name, credentials: mine.map {
                Wire.Credential(alias: $0.alias, username: $0.username, note: snapshot.credentials[$0.alias]?.note ?? "")
            })
        }
        guard request.op == "fetch" else { return .deny("Unknown request.") }

        if let missing = request.aliases.first(where: { alias in !agent.allowed.contains(alias) || !approved.contains { $0.alias == alias } }) {
            event.result = "denied: \(missing) not allowed"; event.ok = false
            return .deny("\(agent.name) isn't allowed to use \(missing). Ask the owner to tick it for \(agent.name) in Credential Harbor (harbor list shows what you can use).")
        }
        do {
            let credentials = try request.aliases.map { alias in
                Wire.Credential(alias: alias, username: approved.first { $0.alias == alias }?.username ?? "", note: "", secret: try Vault.secret(alias))
            }
            event.result = "running"
            update { config in
                let now = Date()
                if let index = config.agents.firstIndex(where: { $0.id == agent.id }) { config.agents[index].lastUsed = now }
                for alias in request.aliases { config.credentials[alias, default: CredentialMeta()].lastUsed = now }
            }
            return Wire.Response(ok: true, agent: agent.name, credentials: credentials)
        } catch {
            event.result = "denied: \(error)"; event.ok = false
            return .deny("\(error)")
        }
    }

    private func notify(_ event: Event, denied: Bool) {
        let level = lock.withLock { config.settings.notify }
        guard level == .all || (level == .denied && denied) else { return }
        let content = UNMutableNotificationContent()
        content.title = denied ? "Harbor denied \(event.agent)" : "\(event.agent) used \(event.aliases.joined(separator: ", "))"
        content.body = denied ? "\(event.result.replacingOccurrences(of: "denied: ", with: "")) • \(event.command)" : event.command
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: event.id.uuidString, content: content, trigger: nil))
    }

    // MARK: Helpers

    static func hash(_ key: String) -> String { SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined() }

    private static func peerUser(_ fd: Int32) -> String {
        var uid = uid_t(), gid = gid_t()
        guard getpeereid(fd, &uid, &gid) == 0, let pw = getpwuid(uid) else { return "?" }
        return String(cString: pw.pointee.pw_name)
    }

    private func save() { lock.withLock { persist() } }

    /// Caller holds the lock.
    private func persist() {
        try? FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
        for (url, data) in [(Self.configFile, try? JSONEncoder.iso.encode(config)), (Self.eventsFile, try? JSONEncoder.iso.encode(events))] {
            guard let data else { continue }
            try? data.write(to: url, options: .atomic)
            chmod(url.path, 0o600)
        }
    }
}

extension JSONEncoder { static let iso: JSONEncoder = { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = .prettyPrinted; return e }() }
extension JSONDecoder { static let iso: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }() }

/// Accepts CLI connections on /Users/Shared/CredentialHarbor/harbor.sock (0666: any local user may
/// connect; a valid agent key is what grants anything).
enum Broker {
    static func start() throws {
        try FileManager.default.createDirectory(atPath: Wire.directory + "/bin", withIntermediateDirectories: true)
        chmod(Wire.directory, 0o755); chmod(Wire.directory + "/bin", 0o755)
        installCLI()
        unlink(Wire.socketPath)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = Wire.unixAddress(Wire.socketPath)
        let bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        guard fd >= 0, bound == 0, listen(fd, 32) == 0 else { throw HarborError.usage("Could not open \(Wire.socketPath): \(String(cString: strerror(errno)))") }
        chmod(Wire.socketPath, 0o666)
        Thread {
            while true {
                let client = accept(fd, nil, nil)
                guard client >= 0 else { continue }
                DispatchQueue.global().async { Store.shared.serve(client); close(client) }
            }
        }.start()
    }

    /// Keeps the shared CLI in step with the app version.
    static func installCLI() {
        guard let bundled = Bundle.main.url(forAuxiliaryExecutable: "harbor") else { return }
        let target = URL(fileURLWithPath: Wire.cliPath)
        if FileManager.default.contentsEqual(atPath: bundled.path, andPath: target.path) { return }
        try? FileManager.default.removeItem(at: target)
        try? FileManager.default.copyItem(at: bundled, to: target)
        chmod(target.path, 0o755)
    }
}
