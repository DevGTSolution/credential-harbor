import Foundation
import Security

/// A credential the owner approved for AI use. Approval == a Harbor-owned copy
/// exists in the login keychain (service "CredentialHarbor", account = alias).
/// Harbor creates that item, so its ACL trusts only this signed binary; any
/// other tool reading it gets a macOS prompt. Revoke == delete the copy.
public struct VaultEntry: Identifiable, Hashable, Sendable {
    public var id: String { alias }
    public let alias: String
    public let username: String
}

/// An `AI-` item found in the keychain that is not approved yet.
public struct Candidate: Identifiable, Hashable, Sendable {
    public let id: Data // persistent ref
    public let alias: String
    public let username: String
    public let itemClass: String
    public let source: String
}

public enum HarborError: Error, CustomStringConvertible {
    case keychain(OSStatus, String)
    case notApproved(String)
    case invalidAlias(String)
    case usage(String)
    case needsOwner(String)

    public var description: String {
        switch self {
        case let .keychain(status, action):
            let reason = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
            return "Keychain \(action) failed: \(reason)"
        case let .notApproved(alias): return "\(alias) is not approved in Credential Harbor. Ask the owner to approve it in the app (harbor list shows what is)."
        case let .invalidAlias(alias): return "Invalid credential name \(alias). Names start with AI- and use letters, digits, - or _."
        case let .usage(text): return text
        case let .needsOwner(text): return "\(text) Background mode never shows a dialog, so it stopped instead."
        }
    }
}

public enum Vault {
    static let service = "CredentialHarbor"
    /// macOS's no-dialog switch is per process, so every read that could prompt takes this lock:
    /// an owner-facing read never runs while a background read has dialogs turned off.
    private static let interaction = NSLock()

    public static func isValidAlias(_ alias: String) -> Bool {
        alias.hasPrefix("AI-") && alias.count > 3 && alias.count <= 100
            && alias.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) && $0.isASCII || $0 == "-" || $0 == "_" }
    }

    public static func entries(interactive: Bool = true) throws -> [VaultEntry] {
        let query: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service,
                                      kSecMatchLimit: kSecMatchLimitAll, kSecReturnAttributes: true]
        let items = interactive ? try attributes(query, "list") : try withoutDialogs { try attributes(query, "list") }
        return items.compactMap { item in
            guard let alias = item[kSecAttrAccount as String] as? String, isValidAlias(alias) else { return nil }
            return VaultEntry(alias: alias, username: item[kSecAttrComment as String] as? String ?? "")
        }.sorted { $0.alias < $1.alias }
    }

    public static func secret(_ alias: String, interactive: Bool = true) throws -> String {
        guard isValidAlias(alias) else { throw HarborError.invalidAlias(alias) }
        let query: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service,
                                      kSecAttrAccount: alias, kSecMatchLimit: kSecMatchLimitOne, kSecReturnData: true]
        var result: CFTypeRef?
        let read = { SecItemCopyMatching(query as CFDictionary, &result) }
        let status = interactive ? interaction.withLock(read) : try withoutDialogs(read)
        if status == errSecItemNotFound { throw HarborError.notApproved(alias) }
        if !interactive, status == errSecAuthFailed || status == errSecInteractionNotAllowed {
            throw HarborError.needsOwner("macOS wants to ask before Harbor reads \(alias) (this Harbor build isn't on its access list). Use it once from a normal harbor command and choose Always Allow, or save it again in Harbor.")
        }
        guard status == errSecSuccess, let data = result as? Data else { throw HarborError.keychain(status, "read of \(alias)") }
        return String(decoding: data, as: UTF8.self)
    }

    public static func username(_ alias: String) throws -> String {
        guard let entry = try entries().first(where: { $0.alias == alias }) else { throw HarborError.notApproved(alias) }
        return entry.username
    }

    /// Owner-only (called from the GUI). Replaces any existing item so the ACL is ours.
    public static func save(alias: String, username: String, secret: String) throws {
        guard isValidAlias(alias) else { throw HarborError.invalidAlias(alias) }
        try remove(alias)
        let item: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: alias,
                                     kSecAttrLabel: "Credential Harbor: \(alias)", kSecAttrComment: username,
                                     kSecValueData: Data(secret.utf8)]
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw HarborError.keychain(status, "save of \(alias)") }
    }

    public static func remove(_ alias: String) throws {
        let query: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: alias]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw HarborError.keychain(status, "removal of \(alias)") }
    }

    /// Attribute-only scan for items whose label/service/server starts with AI-. No secrets read, no prompt.
    public static func candidates() throws -> [Candidate] {
        var found: [Candidate] = []
        for itemClass in [kSecClassGenericPassword, kSecClassInternetPassword] {
            let query: [CFString: Any] = [kSecClass: itemClass, kSecMatchLimit: kSecMatchLimitAll,
                                          kSecReturnAttributes: true, kSecReturnPersistentRef: true]
            for item in try attributes(query, "scan") {
                let place = (item[kSecAttrService as String] ?? item[kSecAttrServer as String]) as? String ?? ""
                guard place != service, let ref = item[kSecValuePersistentRef as String] as? Data else { continue }
                let label = item[kSecAttrLabel as String] as? String ?? ""
                guard let name = [label, place].first(where: { $0.hasPrefix("AI-") }) else { continue }
                let alias = String(name.map { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") ? $0 : "-" }.prefix(100))
                found.append(Candidate(id: ref, alias: alias, username: item[kSecAttrAccount as String] as? String ?? "",
                                       itemClass: itemClass as String, source: label == place || place.isEmpty ? label : "\(label) (\(place))"))
            }
        }
        return found.sorted { $0.alias < $1.alias }
    }

    /// Owner-only. Reading the original item makes macOS ask the owner once; then Harbor keeps its own copy.
    public static func approve(_ candidate: Candidate) throws {
        let query: [CFString: Any] = [kSecClass: candidate.itemClass, kSecValuePersistentRef: candidate.id, kSecReturnData: true]
        var result: CFTypeRef?
        let status = interaction.withLock { SecItemCopyMatching(query as CFDictionary, &result) }
        guard status == errSecSuccess, let data = result as? Data else { throw HarborError.keychain(status, "read of \(candidate.source)") }
        try save(alias: candidate.alias, username: candidate.username, secret: String(decoding: data, as: UTF8.self))
    }

    /// Runs a read with macOS dialogs off, after checking the login keychain is unlocked.
    /// kSecUseAuthenticationUIFail is ignored by the login (file-based) keychain, which still
    /// prompts, so this uses the legacy per-process switch (checked 2026-10-31 on test keychains:
    /// locked and not-on-access-list both return errSecAuthFailed at once, approved reads work).
    static func withoutDialogs<T>(_ body: () throws -> T) throws -> T {
        try interaction.withLock {
            var keychain: SecKeychain?
            var state: SecKeychainStatus = 0
            let status = SecKeychainCopyDefault(&keychain)
            guard status == errSecSuccess, let keychain else { throw HarborError.keychain(status, "lookup of the login keychain") }
            let checked = SecKeychainGetStatus(keychain, &state)
            guard checked == errSecSuccess else { throw HarborError.keychain(checked, "status check") }
            guard state & UInt32(kSecUnlockStateStatus) != 0 else { throw HarborError.needsOwner("The login keychain is locked; the owner must log in or unlock it.") }
            SecKeychainSetUserInteractionAllowed(false)
            defer { SecKeychainSetUserInteractionAllowed(true) }
            return try body()
        }
    }

    private static func attributes(_ query: [CFString: Any], _ action: String) throws -> [[String: Any]] {
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess else { throw HarborError.keychain(status, action) }
        return result as? [[String: Any]] ?? []
    }
}
