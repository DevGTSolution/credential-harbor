import Foundation

/// Minimal, line-based edits to an agent's own config file so the owner never pastes a key.
/// Only touches the keys it sets; everything else is kept byte for byte.
public enum ConfigPatch {
    /// Sets `key = value` inside `[table]`, adding the table at the end if missing.
    /// Throws if the table is already defined inline in its parent (`set = { … }`), where a
    /// `[parent.child]` header would make the file invalid TOML.
    public static func toml(_ text: String, table: String, key: String, value: String) throws -> String {
        var lines = text.components(separatedBy: "\n")
        let header = "[\(table)]"
        let assignment = "\(key) = \(value)"

        if let start = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == header }) {
            var end = start + 1
            while end < lines.count, !lines[end].trimmingCharacters(in: .whitespaces).hasPrefix("[") { end += 1 }
            if let existing = (start + 1 ..< end).first(where: { assigns(lines[$0], key) }) {
                lines[existing] = assignment
            } else {
                lines.insert(assignment, at: start + 1)
            }
            return lines.joined(separator: "\n")
        }

        if let dot = table.lastIndex(of: ".") {
            let parent = "[\(table[..<dot])]", child = String(table[table.index(after: dot)...])
            if let start = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == parent }) {
                var end = start + 1
                while end < lines.count, !lines[end].trimmingCharacters(in: .whitespaces).hasPrefix("[") { end += 1 }
                if (start + 1 ..< end).contains(where: { assigns(lines[$0], child) }) {
                    throw HarborError.usage("\(parent) already sets \(child) inline; add \(key) there by hand.")
                }
            }
        }
        var result = text
        if !result.isEmpty, !result.hasSuffix("\n") { result += "\n" }
        return result + "\n\(header)\n\(assignment)\n"
    }

    /// Sets `env.<key>` in a JSON settings file (Claude Code's settings.json).
    public static func jsonEnv(_ data: Data?, key: String, value: String) throws -> Data {
        var root = (data.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]) ?? [:]
        if data != nil, !(data!.isEmpty), (try? JSONSerialization.jsonObject(with: data!)) == nil {
            throw HarborError.usage("settings.json isn't valid JSON; not touching it.")
        }
        var env = root["env"] as? [String: Any] ?? [:]
        env[key] = value
        root["env"] = env
        return try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }

    private static func assigns(_ line: String, _ key: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix(key) else { return false }
        return trimmed.dropFirst(key.count).trimmingCharacters(in: .whitespaces).hasPrefix("=")
    }
}
