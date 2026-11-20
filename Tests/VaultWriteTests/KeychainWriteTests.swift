import Foundation
import Security
import XCTest
@testable import HarborCore

final class KeychainWriteTests: XCTestCase {
    // Only synthetic in-memory data; every Security write function is injected.
    let query: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: "SyntheticHarborTest", kSecAttrAccount: "AI-Fixture"]
    let values: [CFString: Any] = [kSecValueData: Data("synthetic-new".utf8)]

    func testExistingItemUpdatesWithoutAdd() {
        var stored = Data("synthetic-old".utf8)
        var adds = 0
        let result = KeychainWrite.save(query: query, attributes: values, update: { _, incoming in
            stored = (incoming as NSDictionary)[kSecValueData] as! Data
            return errSecSuccess
        }, add: { _, _ in adds += 1; return errSecSuccess })
        XCTAssertEqual(result, errSecSuccess)
        XCTAssertEqual(stored, Data("synthetic-new".utf8))
        XCTAssertEqual(adds, 0)
    }

    func testFailedUpdateDoesNotFallThroughToAdd() {
        for failure in [errSecAuthFailed, errSecInteractionNotAllowed, errSecParam, errSecNotAvailable, errSecDuplicateItem, errSecMissingEntitlement] {
            var adds = 0
            let result = KeychainWrite.save(query: query, attributes: values, update: { _, _ in failure }, add: { _, _ in adds += 1; return errSecSuccess })
            XCTAssertEqual(result, failure)
            XCTAssertEqual(adds, 0)
        }
    }

    func testMissingItemAddsMergedIdentityAndAttributes() {
        var added: NSDictionary?
        let result = KeychainWrite.save(query: query, attributes: values, update: { _, _ in errSecItemNotFound }, add: { item, _ in added = item as NSDictionary; return errSecSuccess })
        XCTAssertEqual(result, errSecSuccess)
        XCTAssertEqual(added?[kSecAttrService] as? String, "SyntheticHarborTest")
        XCTAssertEqual(added?[kSecValueData] as? Data, Data("synthetic-new".utf8))
    }

    func testAddFailureIsReturned() {
        var updates = 0
        let result = KeychainWrite.save(query: query, attributes: values, update: { _, _ in updates += 1; return errSecItemNotFound }, add: { _, _ in errSecNotAvailable })
        XCTAssertEqual(result, errSecNotAvailable)
        XCTAssertEqual(updates, 1)
    }

    func testConcurrentInsertRetriesUpdateOnce() {
        var updates = 0
        let result = KeychainWrite.save(query: query, attributes: values, update: { _, _ in updates += 1; return updates == 1 ? errSecItemNotFound : errSecSuccess }, add: { _, _ in errSecDuplicateItem })
        XCTAssertEqual(result, errSecSuccess)
        XCTAssertEqual(updates, 2)
    }

    func testConcurrentInsertThenUpdateFailureIsReturned() {
        var updates = 0
        let result = KeychainWrite.save(query: query, attributes: values, update: { _, _ in updates += 1; return updates == 1 ? errSecItemNotFound : errSecAuthFailed }, add: { _, _ in errSecDuplicateItem })
        XCTAssertEqual(result, errSecAuthFailed)
        XCTAssertEqual(updates, 2)
    }

    func testModernAddUsesConcreteSyncValueInsteadOfAny() {
        for synced in [true, false] {
            var modern = query
            modern[kSecUseDataProtectionKeychain] = true
            modern[kSecAttrSynchronizable] = kSecAttrSynchronizableAny
            var attributes = values
            attributes[kSecAttrSynchronizable] = synced
            attributes[kSecAttrAccessible] = synced ? kSecAttrAccessibleAfterFirstUnlock : kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let result = KeychainWrite.save(query: modern, attributes: attributes, update: { _, _ in errSecItemNotFound }, add: { item, _ in
                let added = item as NSDictionary
                XCTAssertEqual(added[kSecAttrSynchronizable] as? Bool, synced)
                XCTAssertEqual(added[kSecUseDataProtectionKeychain] as? Bool, true)
                return errSecSuccess
            })
            XCTAssertEqual(result, errSecSuccess)
        }
    }

    func testRejectedSyncTransitionDoesNotDeleteOrAdd() {
        var attributes = values
        attributes[kSecAttrSynchronizable] = true
        attributes[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlock
        var adds = 0
        let result = KeychainWrite.save(query: query, attributes: attributes, update: { _, _ in errSecParam }, add: { _, _ in adds += 1; return errSecSuccess })
        XCTAssertEqual(result, errSecParam)
        XCTAssertEqual(adds, 0)
    }

    func testRealLegacyWriteStaysInFileStore() throws {
        try Vault.writeCopy(alias: "AI-Fixture", username: "fixture-user", secret: "synthetic-new", synced: false, dataProtection: false) { query, attributes in
            XCTAssertEqual(query[kSecUseDataProtectionKeychain] as? Bool, false)
            XCTAssertEqual(query[kSecAttrService] as? String, Vault.service)
            XCTAssertEqual(query[kSecAttrAccount] as? String, "AI-Fixture")
            XCTAssertNil(query[kSecAttrSynchronizable])
            XCTAssertNil(attributes[kSecAttrSynchronizable])
            XCTAssertNil(attributes[kSecUseDataProtectionKeychain])
            return KeychainWrite.save(query: query, attributes: attributes, update: { _, _ in errSecItemNotFound }, add: { item, _ in
                let item = item as NSDictionary
                XCTAssertEqual(item[kSecUseDataProtectionKeychain] as? Bool, false)
                XCTAssertEqual(item[kSecValueData] as? Data, Data("synthetic-new".utf8))
                return errSecSuccess
            })
        }
    }

    func testRealModernWritesUseDataProtectionAndConcreteSyncOnAdd() throws {
        for synced in [true, false] {
            try Vault.writeCopy(alias: "AI-Fixture", username: "fixture-user", secret: "synthetic-new", synced: synced, dataProtection: true) { query, attributes in
                XCTAssertEqual(query[kSecUseDataProtectionKeychain] as? Bool, true)
                XCTAssertEqual(query[kSecAttrSynchronizable] as? String, kSecAttrSynchronizableAny as String)
                XCTAssertEqual(attributes[kSecAttrSynchronizable] as? Bool, synced)
                XCTAssertEqual(attributes[kSecAttrAccessible] as? String,
                               (synced ? kSecAttrAccessibleAfterFirstUnlock : kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly) as String)
                return KeychainWrite.save(query: query, attributes: attributes, update: { _, _ in errSecItemNotFound }, add: { item, _ in
                    XCTAssertEqual((item as NSDictionary)[kSecAttrSynchronizable] as? Bool, synced)
                    XCTAssertEqual((item as NSDictionary)[kSecUseDataProtectionKeychain] as? Bool, true)
                    return errSecSuccess
                })
            }
        }
    }

    func testRealWriteFailurePropagatesWithoutAddingInBothStores() {
        for modern in [false, true] {
            for failure in [errSecAuthFailed, errSecInteractionNotAllowed, errSecParam, errSecNotAvailable, errSecMissingEntitlement] {
                var adds = 0
                XCTAssertThrowsError(try Vault.writeCopy(alias: "AI-Fixture", username: "fixture-user", secret: "synthetic-new", synced: false, dataProtection: modern) { query, attributes in
                    KeychainWrite.save(query: query, attributes: attributes, update: { _, _ in failure }, add: { _, _ in adds += 1; return errSecSuccess })
                }) { error in
                    guard case HarborError.keychain(let status, _) = error else { return XCTFail("Unexpected error: \(error)") }
                    XCTAssertEqual(status, failure)
                }
                XCTAssertEqual(adds, 0)
            }
        }
    }
}
