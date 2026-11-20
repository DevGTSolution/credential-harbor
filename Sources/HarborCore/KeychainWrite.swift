import Foundation
import Security

enum KeychainWrite {
    // A failed update must never fall back to deleting the owner's existing item.
    static func save(query: [CFString: Any], attributes: [CFString: Any],
                     update: (CFDictionary, CFDictionary) -> OSStatus = SecItemUpdate,
                     add: (CFDictionary, UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus = SecItemAdd) -> OSStatus {
        let updated = update(query as CFDictionary, attributes as CFDictionary)
        guard updated == errSecItemNotFound else { return updated }
        let item = query.merging(attributes) { _, value in value }
        let added = add(item as CFDictionary, nil)
        // Another writer may have inserted the item between update and add.
        return added == errSecDuplicateItem ? update(query as CFDictionary, attributes as CFDictionary) : added
    }
}
