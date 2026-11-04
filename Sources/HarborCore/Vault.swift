import Foundation
import Security

/// A credential the owner approved for AI use. Approval == a Harbor-owned copy exists
/// (service "CredentialHarbor", account = alias). Developer ID builds keep it in the
/// data-protection keychain, readable only by apps signed with Harbor's team and access group,
/// optionally synced through iCloud Keychain. Other builds keep it in the login keychain, whose
/// ACL trusts only this signed binary. Revoke == delete the copy.
public struct VaultEntry: Identifiable, Hashable, Sendable {
    public var id: String { alias }
    public let alias: String
    public let username: String
    public var synced = false
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

    /// The data-protection keychain needs a keychain-access-groups entitlement, which only a build
    /// with its provisioning profile has (without one, writes fail -34018 and reads find nothing).
    /// Otherwise Harbor stays on the login keychain.
    public static let modern: Bool = {
        guard let task = SecTaskCreateFromSelf(nil) else { return false }
        return SecTaskCopyValueForEntitlement(task, "keychain-access-groups" as CFString, nil) != nil
    }()

    private static func dp(_ query: [CFString: Any]) -> [CFString: Any] {
        query.merging([kSecUseDataProtectionKeychain: true, kSecAttrSynchronizable: kSecAttrSynchronizableAny]) { $1 }
    }

    public static func isValidAlias(_ alias: String) -> Bool {
        alias.hasPrefix("AI-") && alias.count > 3 && alias.count <= 100
            && alias.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) && $0.isASCII || $0 == "-" || $0 == "_" }
    }

    /// Harbor's copies in both stores; a data-protection copy wins over a leftover login-keychain one.
    public static func entries(interactive: Bool = true) throws -> [VaultEntry] {
        var byAlias: [String: VaultEntry] = [:]
        for entry in try legacyEntries(interactive: interactive) { byAlias[entry.alias] = entry }
        if modern {
            for entry in try parse(attributes(dp(listQuery), "list")) { byAlias[entry.alias] = entry }
        }
        return byAlias.values.sorted { $0.alias < $1.alias }
    }

    /// Approved credentials whose only copy is still in the login keychain.
    public static func unmigrated() throws -> [VaultEntry] {
        guard modern else { return [] }
        let moved = Set(try parse(attributes(dp(listQuery), "list")).map(\.alias))
        return try legacyEntries(interactive: true).filter { !moved.contains($0.alias) }
    }

    /// Owner-only, one at a time: reading a login-keychain copy written by an older build makes
    /// macOS ask once. The old copy stays, as a backup for rolling back, until revoke or replace.
    public static func migrate(_ entry: VaultEntry) throws {
        let secret = try legacySecret(entry.alias, interactive: true)
        try add(alias: entry.alias, username: entry.username, secret: secret, synced: false)
    }

    private static let listQuery: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service,
                                                     kSecMatchLimit: kSecMatchLimitAll, kSecReturnAttributes: true]

    private static func legacyEntries(interactive: Bool) throws -> [VaultEntry] {
        if interactive { return try parse(attributes(listQuery, "list")) }
        do { return try withoutDialogs { try parse(attributes(listQuery, "list")) } }
        catch HarborError.needsOwner(_) where modern { return [] } // locked login keychain; data-protection copies still serve
    }

    private static func parse(_ items: [[String: Any]]) -> [VaultEntry] {
        items.compactMap { item in
            guard let alias = item[kSecAttrAccount as String] as? String, isValidAlias(alias) else { return nil }
            return VaultEntry(alias: alias, username: item[kSecAttrComment as String] as? String ?? "",
                              synced: "\(item[kSecAttrSynchronizable as String] ?? 0)" == "1")
        }
    }

    public static func secret(_ alias: String, interactive: Bool = true) throws -> String {
        guard isValidAlias(alias) else { throw HarborError.invalidAlias(alias) }
        if modern {
            var result: CFTypeRef?
            let status = SecItemCopyMatching(dp([kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: alias,
                                                 kSecMatchLimit: kSecMatchLimitOne, kSecReturnData: true]) as CFDictionary, &result)
            if status == errSecSuccess, let data = result as? Data { return String(decoding: data, as: UTF8.self) }
            guard status == errSecItemNotFound else { throw HarborError.keychain(status, "read of \(alias)") }
        }
        return try legacySecret(alias, interactive: interactive)
    }

    private static func legacySecret(_ alias: String, interactive: Bool) throws -> String {
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

    /// Owner-only (called from the GUI). Replaces any existing copy, in either store, with a fresh one.
    /// `synced` puts it in iCloud Keychain, so it reaches every Mac on this Apple Account that runs
    /// this team's Harbor; only those builds can read it.
    public static func save(alias: String, username: String, secret: String, synced: Bool = false) throws {
        guard isValidAlias(alias) else { throw HarborError.invalidAlias(alias) }
        guard modern || !synced else { throw HarborError.usage("iCloud Keychain sync needs a Developer ID build of Harbor.") }
        if modern {
            try add(alias: alias, username: username, secret: secret, synced: synced)
            try removeLegacy(alias)
            return
        }
        try removeLegacy(alias)
        let item: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: alias,
                                     kSecAttrLabel: "Credential Harbor: \(alias)", kSecAttrComment: username,
                                     kSecValueData: Data(secret.utf8)]
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw HarborError.keychain(status, "save of \(alias)") }
    }

    /// Data-protection copy, replacing any synced or local one. Readable after first unlock so
    /// background agents keep working while the screen is locked.
    private static func add(alias: String, username: String, secret: String, synced: Bool) throws {
        try removeModern(alias)
        let item: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: alias,
                                     kSecAttrLabel: "Credential Harbor: \(alias)", kSecAttrComment: username,
                                     kSecUseDataProtectionKeychain: true, kSecAttrSynchronizable: synced,
                                     kSecAttrAccessible: synced ? kSecAttrAccessibleAfterFirstUnlock : kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
                                     kSecValueData: Data(secret.utf8)]
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw HarborError.keychain(status, "save of \(alias)") }
    }

    /// Deletes every copy. A synced copy is deleted on every Mac on this Apple Account.
    public static func remove(_ alias: String) throws {
        if modern { try removeModern(alias) }
        try removeLegacy(alias)
    }

    private static func removeModern(_ alias: String) throws {
        let status = SecItemDelete(dp([kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: alias]) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw HarborError.keychain(status, "removal of \(alias)") }
    }

    private static func removeLegacy(_ alias: String) throws {
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
