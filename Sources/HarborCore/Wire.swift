import Foundation

/// CLI ⇄ app protocol: one JSON object per line over a Unix socket.
/// The app (in the owner's login session) owns the Keychain and policy; the CLI runs the
/// command as whoever called it (the owner, a service account, …), so the app never runs
/// commands for callers.
public enum Wire {
    public static let directory = "/Users/Shared/CredentialHarbor"
    public static let socketPath = directory + "/harbor.sock"
    public static let cliPath = directory + "/bin/harbor"
    public static let keyVariable = "HARBOR_AGENT_KEY"

    public struct Request: Codable, Sendable {
        public var op: String // "list" | "fetch" | "done"
        public var key = ""
        public var aliases: [String] = []
        public var command = ""
        public var cwd = ""
        public var exit: Int32?
        public init(op: String, key: String = "", aliases: [String] = [], command: String = "", cwd: String = "", exit: Int32? = nil) {
            self.op = op; self.key = key; self.aliases = aliases; self.command = command; self.cwd = cwd; self.exit = exit
        }
    }

    public struct Credential: Codable, Sendable {
        public var alias: String
        public var username: String
        public var note: String
        public var secret: String?
        public init(alias: String, username: String, note: String, secret: String? = nil) {
            self.alias = alias; self.username = username; self.note = note; self.secret = secret
        }
    }

    public struct Response: Codable, Sendable {
        public var ok: Bool
        public var error: String?
        public var agent: String?
        public var credentials: [Credential] = []
        public init(ok: Bool, error: String? = nil, agent: String? = nil, credentials: [Credential] = []) {
            self.ok = ok; self.error = error; self.agent = agent; self.credentials = credentials
        }
        public static func deny(_ reason: String) -> Response { Response(ok: false, error: reason) }
    }

    public static func connect() -> Int32? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var address = unixAddress(socketPath)
        let result = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Foundation.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        if result != 0 { close(fd); return nil }
        return fd
    }

    public static func unixAddress(_ path: String) -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            let bytes = Array(path.utf8.prefix(buffer.count - 1))
            buffer.copyBytes(from: bytes)
        }
        return address
    }
}

/// Newline-delimited JSON over a file descriptor.
public final class LineChannel {
    private let fd: Int32
    private var buffer = Data()
    public init(_ fd: Int32) { self.fd = fd }

    public func send<T: Encodable>(_ value: T) throws {
        var data = try JSONEncoder().encode(value)
        data.append(0x0A)
        try data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let written = write(fd, raw.baseAddress! + offset, raw.count - offset)
                guard written > 0 else { throw HarborError.usage("Connection to Credential Harbor lost.") }
                offset += written
            }
        }
    }

    /// nil on EOF.
    public func receive<T: Decodable>(_ type: T.Type) throws -> T? {
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            if let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer[..<newline]
                buffer = Data(buffer[buffer.index(after: newline)...])
                return try JSONDecoder().decode(T.self, from: line)
            }
            guard buffer.count < 1_000_000 else { throw HarborError.usage("Message too large.") }
            let count = read(fd, &chunk, chunk.count)
            guard count > 0 else { return nil }
            buffer.append(contentsOf: chunk[..<count])
        }
    }
}
