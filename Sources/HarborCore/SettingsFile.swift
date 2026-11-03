import Foundation

/// Harbor settings in a file the owner can carry to another Mac (e.g. through iCloud Drive).
/// Holds no secrets and no agent keys: each Mac approves its own credentials and makes its own
/// keys. Credential health-check commands are left out because Harbor runs them with the secret.
public struct SettingsFile: Codable, Equatable {
    public struct Agent: Codable, Equatable {
        public var name: String
        public var kind: String
        public var allowed: [String]
        public var paused: Bool
        public var links: [String]
        public init(name: String, kind: String, allowed: [String], paused: Bool, links: [String]) {
            self.name = name; self.kind = kind; self.allowed = allowed; self.paused = paused; self.links = links
        }
    }

    public struct Options: Codable, Equatable {
        public var pauseAll: Bool
        public var notify: String
        public var retentionDays: Int
        public var theme: String
        public var containers: Bool
        public init(pauseAll: Bool, notify: String, retentionDays: Int, theme: String, containers: Bool) {
            self.pauseAll = pauseAll; self.notify = notify; self.retentionDays = retentionDays; self.theme = theme; self.containers = containers
        }
    }

    public static let format = "credential-harbor-settings"
    public var format = SettingsFile.format
    public var version = 1
    public var agents: [Agent]
    public var notes: [String: String]
    public var options: Options

    public init(agents: [Agent], notes: [String: String], options: Options) {
        self.agents = agents; self.notes = notes; self.options = options
    }

    /// iCloud Drive's Credential Harbor folder, when iCloud Drive is on.
    public static var iCloudFolder: URL? {
        let drive = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs")
        return FileManager.default.fileExists(atPath: drive.path) ? drive.appendingPathComponent("Credential Harbor") : nil
    }

    /// Reads a file and refuses anything that isn't a well-formed Harbor settings file.
    public static func read(_ data: Data) throws -> SettingsFile {
        guard let file = try? JSONDecoder().decode(SettingsFile.self, from: data), file.format == format else {
            throw HarborError.usage("That isn't a Credential Harbor settings file.")
        }
        guard file.version == 1 else { throw HarborError.usage("This settings file is from a newer Credential Harbor. Update this Mac first.") }
        for agent in file.agents {
            guard !agent.name.trimmingCharacters(in: .whitespaces).isEmpty else { throw HarborError.usage("The file has an agent with no name.") }
            if let bad = agent.allowed.first(where: { !Vault.isValidAlias($0) }) { throw HarborError.invalidAlias(bad) }
            if let bad = agent.links.first(where: { !$0.hasPrefix("/") }) { throw HarborError.usage("Linked app \(bad) isn't a full path.") }
        }
        guard (1...3650).contains(file.options.retentionDays) else { throw HarborError.usage("The file's activity retention (\(file.options.retentionDays) days) is out of range.") }
        if let bad = file.notes.keys.first(where: { !Vault.isValidAlias($0) }) { throw HarborError.invalidAlias(bad) }
        return file
    }

    /// `incoming` merged into `self`: agents matched by name take the file's type, credentials,
    /// pause and linked apps; agents only on this Mac stay; the file's notes and options win.
    public func merging(_ incoming: SettingsFile) -> SettingsFile {
        var result = self
        for agent in incoming.agents {
            if let i = result.agents.firstIndex(where: { $0.name == agent.name }) { result.agents[i] = agent } else { result.agents.append(agent) }
        }
        result.notes.merge(incoming.notes.filter { !$0.value.isEmpty }) { _, new in new }
        result.options = incoming.options
        return result
    }

    /// What importing `incoming` would change, one line each, for the owner to review first.
    /// Access changes come first: they take effect as soon as the import is applied.
    public func changes(importing incoming: SettingsFile) -> [String] {
        let after = merging(incoming)
        var lines: [String] = []
        for agent in after.agents {
            guard let old = agents.first(where: { $0.name == agent.name }) else {
                lines.append("New agent \(agent.name) (\(agent.kind)), no key yet\(agent.allowed.isEmpty ? "" : ": may use \(agent.allowed.joined(separator: ", "))")")
                if !agent.links.isEmpty { lines.append("  linked apps, no key needed: \(agent.links.joined(separator: ", "))") }
                continue
            }
            let granted = agent.allowed.filter { !old.allowed.contains($0) }, revoked = old.allowed.filter { !agent.allowed.contains($0) }
            let linked = agent.links.filter { !old.links.contains($0) }, unlinked = old.links.filter { !agent.links.contains($0) }
            if !granted.isEmpty { lines.append("\(agent.name) may now use \(granted.joined(separator: ", "))") }
            if !linked.isEmpty { lines.append("\(agent.name) gets linked apps, no key needed: \(linked.joined(separator: ", "))") }
            if old.paused && !agent.paused { lines.append("\(agent.name) is unpaused") }
            if !revoked.isEmpty { lines.append("\(agent.name) loses \(revoked.joined(separator: ", "))") }
            if !unlinked.isEmpty { lines.append("\(agent.name) unlinks \(unlinked.joined(separator: ", "))") }
            if !old.paused && agent.paused { lines.append("\(agent.name) is paused") }
            if old.kind != agent.kind { lines.append("\(agent.name) becomes type \(agent.kind)") }
        }
        if !options.containers && after.options.containers { lines.append("Containers (Docker) turns on: Harbor listens on 127.0.0.1:\(Wire.tcpPort)") }
        if options.containers && !after.options.containers { lines.append("Containers (Docker) turns off") }
        if options.pauseAll != after.options.pauseAll { lines.append(after.options.pauseAll ? "Pause all turns on" : "Pause all turns off") }
        let notes = after.notes.filter { notes[$0.key] != $0.value }.count
        if notes > 0 { lines.append("\(notes) credential note\(notes == 1 ? "" : "s") updated") }
        let o = options, n = after.options
        if (o.notify, o.retentionDays, o.theme) != (n.notify, n.retentionDays, n.theme) { lines.append("Notifications, activity retention or theme change") }
        return lines
    }
}
