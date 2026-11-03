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
        case .hermes: return "Container agent. \"Write key file\" saves the key to \(Self.containerKeyPath(for: "hermes")), then in compose:\n  volumes:\n    - /Users/Shared/CredentialHarbor/bin:/opt/harbor:ro\n    - \(Self.containerKeyPath(for: "hermes")):/run/secrets/harbor_agent_key:ro\nand run: python3 /opt/harbor/harbor-container doctor"
        case .other: return "Set in that agent's environment or .env:\n  HARBOR_AGENT_KEY=\(key)\nor, for a background service, \"Write key file\" saves it to \(Self.containerKeyPath(for: "<agent-name>")) (0600) for the service to read."
        }
    }

    /// The config file Harbor can write the key into for you, if this kind has one.
    var configFile: URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        switch self {
        case .claude: return home.appendingPathComponent(".claude/settings.json")
        case .codex: return home.appendingPathComponent(".codex/config.toml")
        case .hermes: return URL(fileURLWithPath: Self.containerKeyPath(for: "hermes"))
        default: return nil
        }
    }

    /// Key files for container agents: a 0700 folder only the owner (and Docker Desktop, running as
    /// the owner) can read. Mount the file read-only at /run/secrets/harbor_agent_key.
    static func containerKeyPath(for name: String) -> String { "\(Wire.directory)/keys/\(name).key" }

    static func serviceKeyPath(for agentName: String) -> String { KeyFile.path(for: agentName) }
    static func writeServiceKey(_ key: String, to path: String) throws { try KeyFile.write(key, to: path) }

    /// Writes the key (and, for Codex, socket access for its sandbox) into the agent's config.
    /// Keeps a one-time backup next to the file. Returns a sentence describing the change.
    func install(key: String) throws -> String {
        guard let file = configFile else { throw HarborError.usage("\(rawValue) has no config Harbor can edit; use Copy setup.") }
        let original = try? Data(contentsOf: file)
        let updated: Data
        if self == .hermes {
            try KeyFile.ownedFolder(file.deletingLastPathComponent().path, mode: 0o700)
            // Write in place: a single-file bind mount keeps pointing at the same inode.
            if !FileManager.default.fileExists(atPath: file.path) { FileManager.default.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600]) }
            let handle = try FileHandle(forWritingTo: file)
            try handle.truncate(atOffset: 0); try handle.write(contentsOf: Data((key + "\n").utf8)); try handle.close()
            chmod(file.path, 0o600)
            return "Wrote the key to \(file.path). Mount it at /run/secrets/harbor_agent_key (read-only); a running container sees a replaced key immediately."
        }
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
    /// The key file Harbor wrote for this agent (Other agents only). Optional: older builds ignore it.
    var keyFile: String?
    /// Apps or folders (e.g. /Applications/Some Agent.app, ~/.local/share/cursor-agent): harbor calls from
    /// anything launched from inside them count as this agent, no key needed. For tools whose
    /// environment Harbor can't set. `linkedApp` is the single link from 1.2 configs.
    var linkedApp: String?
    var linkedApps: [String]?
    var links: [String] { (linkedApps ?? []) + [linkedApp].compactMap { $0 } }
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
    var replaced: Date?  // optional, so older Harbor builds still read this config
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
    var allowTCP = false

    init() {}
    /// Tolerates configs written by older versions (missing keys keep their defaults).
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        pauseAll = try c.decodeIfPresent(Bool.self, forKey: .pauseAll) ?? false
        notify = try c.decodeIfPresent(NotifyLevel.self, forKey: .notify) ?? .denied
        retentionDays = try c.decodeIfPresent(Int.self, forKey: .retentionDays) ?? 30
        theme = (try? c.decodeIfPresent(ThemeName.self, forKey: .theme)) ?? .harbor
        allowTCP = try c.decodeIfPresent(Bool.self, forKey: .allowTCP) ?? false
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
        let chain = Self.ancestry(Self.peerPID(fd))
        guard let request = try? channel.receive(Wire.Request.self) else { return }
        if request.op == "hello" { try? channel.send(Wire.Response(ok: true, features: Wire.features)); return }
        var event = Event(agent: "Unknown", user: user, aliases: request.aliases, command: request.command, cwd: request.cwd, result: "")
        let response = decide(request, chain: chain, event: &event)
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

    private func decide(_ request: Wire.Request, chain: [String], event: inout Event) -> Wire.Response {
        let snapshot = lock.withLock { config }
        let agent: Agent
        if !request.key.isEmpty {
            // An explicit key wins; a wrong one is refused rather than falling back to the app.
            guard let keyed = snapshot.agents.first(where: { $0.keyHash == Self.hash(request.key) }) else {
                event.result = "denied: unknown agent key"; event.ok = false
                return .deny("Unknown agent key. Ask the owner to add or re-key this agent in Credential Harbor → Agents.")
            }
            agent = keyed
        } else if let linked = snapshot.agents.first(where: { agent in
            agent.links.contains { link in chain.contains { $0.hasPrefix(link + "/") } }
        }) {
            agent = linked
        } else {
            event.result = "denied: no agent key or linked app"; event.ok = false
            let app = chain.compactMap(Self.appBundle).first
            return .deny("No HARBOR_AGENT_KEY in this environment\(app.map { " and \($0) isn't linked to an agent" } ?? ""). The owner adds this agent in Credential Harbor → Agents and either puts its key in the agent's config or links its app.")
        }
        event.agent = agent.name; event.agentID = agent.id
        if snapshot.settings.pauseAll { event.result = "denied: Harbor paused"; event.ok = false; return .deny("Credential Harbor is paused by the owner.") }
        if agent.paused { event.result = "denied: agent paused"; event.ok = false; return .deny("\(agent.name) is paused in Credential Harbor.") }

        let quiet = request.noninteractive == true
        let approved: [VaultEntry]
        do { approved = try Vault.entries(interactive: !quiet) } catch where !quiet { approved = [] } catch {
            event.result = "denied: \(error)"; event.ok = false
            return .deny("\(error)")
        }
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
                Wire.Credential(alias: alias, username: approved.first { $0.alias == alias }?.username ?? "", note: "", secret: try Vault.secret(alias, interactive: !quiet))
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

    /// Process ID on the other end of the socket.
    private static func peerPID(_ fd: Int32) -> pid_t {
        var pid: pid_t = 0
        var size = socklen_t(MemoryLayout<pid_t>.size)
        return getsockopt(fd, 0 /* SOL_LOCAL */, 0x002 /* LOCAL_PEERPID */, &pid, &size) == 0 ? pid : 0
    }

    /// Executable paths from the caller up through its parents, as the kernel reports them.
    static func ancestry(_ start: pid_t) -> [String] {
        var paths: [String] = []
        var pid = start
        for _ in 0..<32 where pid > 1 {
            var buffer = [CChar](repeating: 0, count: 4096)
            if proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 { paths.append(String(cString: buffer)) }
            var info = proc_bsdinfo()
            let size = Int32(MemoryLayout<proc_bsdinfo>.size)
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { break }
            pid = pid_t(info.pbi_ppid)
        }
        return paths
    }

    /// Outermost .app bundle containing an executable path, if any.
    static func appBundle(_ path: String) -> String? {
        guard let range = path.range(of: ".app/") else { return nil }
        return String(path[..<range.lowerBound]) + ".app"
    }

    private static func peerUser(_ fd: Int32) -> String {
        var local = sockaddr()
        var size = socklen_t(MemoryLayout<sockaddr>.size)
        if getsockname(fd, &local, &size) == 0, local.sa_family == sa_family_t(AF_INET) {
            return "container" // via Docker's proxy; the OS user on the Mac side is meaningless
        }
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
        try KeyFile.ownedFolder(Wire.directory, mode: 0o755)
        try KeyFile.ownedFolder(Wire.directory + "/bin", mode: 0o755)
        installCLI()
        unlink(Wire.socketPath)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = Wire.unixAddress(Wire.socketPath)
        let bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        guard fd >= 0, bound == 0, listen(fd, 32) == 0 else { throw HarborError.usage("Could not open \(Wire.socketPath): \(String(cString: strerror(errno)))") }
        chmod(Wire.socketPath, 0o666)
        acceptForever(fd)
    }

    private static func acceptForever(_ fd: Int32) {
        Thread {
            while true {
                let client = accept(fd, nil, nil)
                if client < 0 { if errno == EBADF || errno == EINVAL { return }; continue } // listener closed
                DispatchQueue.global().async { Store.shared.serve(client); close(client) }
            }
        }.start()
    }

    private static var tcpListener: Int32 = -1

    /// 127.0.0.1 only. Docker Desktop forwards host.docker.internal to the Mac's loopback, so
    /// containers reach it while the LAN can't. TCP callers have no process ancestry: key required.
    @MainActor static func setTCP(_ on: Bool) {
        if !on { if tcpListener >= 0 { close(tcpListener); tcpListener = -1 }; return }
        guard tcpListener < 0 else { return }
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = Wire.tcpPort.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard fd >= 0, bound == 0, listen(fd, 32) == 0 else { if fd >= 0 { close(fd) }; return }
        tcpListener = fd
        acceptForever(fd)
    }

    /// Keeps the shared CLIs in step with the app version: the macOS `harbor` and the
    /// Python `harbor-container` for Linux containers.
    static func installCLI() {
        let bin = URL(fileURLWithPath: Wire.cliPath).deletingLastPathComponent()
        for (bundled, name) in [(Bundle.main.url(forAuxiliaryExecutable: "harbor"), "harbor"),
                                (Bundle.main.url(forResource: "harbor-container", withExtension: nil), "harbor-container")] {
            guard let bundled else { continue }
            let target = bin.appendingPathComponent(name)
            if FileManager.default.contentsEqual(atPath: bundled.path, andPath: target.path) { continue }
            try? FileManager.default.removeItem(at: target)
            try? FileManager.default.copyItem(at: bundled, to: target)
            chmod(target.path, 0o755)
        }
    }
}
