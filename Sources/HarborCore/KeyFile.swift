import Foundation

/// Key files for background-service agents, in Harbor's 0700 keys folder.
public enum KeyFile {
    public static var directory = Wire.directory + "/keys"

    /// "Backup Service" -> <keys>/backup-service.key
    public static func path(for agentName: String) -> String {
        let slug = agentName.lowercased().map { $0.isLetter || $0.isNumber ? String($0) : "-" }.joined()
            .split(separator: "-").joined(separator: "-")
        return "\(directory)/\(slug.isEmpty ? "service" : slug).key"
    }

    /// Paths no service agent may take, whatever its name: Hermes's bind-mounted key.
    public static var reserved: Set<String> { [directory + "/hermes.key"] }

    /// May `owner` write `path`? `owned` maps each agent ID to the key file it already owns.
    /// Refuses reserved paths, another agent's file, and any existing file this agent didn't write.
    public static func claim(_ path: String, for owner: String, owned: [String: String]) throws {
        if reserved.contains(path) { throw HarborError.usage("\(path) is reserved. Rename this agent.") }
        if owned.contains(where: { $0.key != owner && $0.value == path }) { throw HarborError.usage("\(path) belongs to another agent. Rename this agent.") }
        var info = stat()
        if lstat(path, &info) == 0, owned[owner] != path { throw HarborError.usage("\(path) already exists and wasn't written for this agent. Rename this agent or remove that file yourself.") }
    }

    /// Creates `path` if missing and refuses one another account made first. /Users/Shared is
    /// writable by every local user, so whoever creates Harbor's folders there controls the CLI
    /// every agent runs and the socket it talks to.
    public static func ownedFolder(_ path: String, mode: mode_t) throws {
        if mkdir(path, mode) != 0 && errno != EEXIST { throw HarborError.usage("Could not create \(path) (errno \(errno)).") }
        var info = stat()
        guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid() else {
            throw HarborError.usage("\(path) is not a folder you own, so Harbor won't use it. Another account may have created it first: have an admin remove it, then reopen Harbor.")
        }
        guard chmod(path, mode) == 0 else { throw HarborError.usage("Could not set permissions on \(path) (errno \(errno)).") }
    }

    /// Creates the file 0600 from the first byte (O_EXCL temp, then rename). Not for a file that
    /// is bind-mounted into a container (Hermes's): a rename would orphan the mount.
    public static func write(_ key: String, to path: String) throws {
        try ownedFolder((path as NSString).deletingLastPathComponent, mode: 0o700)
        let temp = path + ".new"
        unlink(temp)
        let fd = open(temp, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw HarborError.usage("Could not create \(temp) (errno \(errno)).") }
        let bytes = Array((key + "\n").utf8)
        let written = bytes.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
        fsync(fd); close(fd)
        guard written == bytes.count, rename(temp, path) == 0 else { unlink(temp); throw HarborError.usage("Could not write \(path).") }
    }
}
