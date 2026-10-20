import Foundation
import Security

func packageSecret(_ account: String) -> String {
    var data: CFTypeRef?
    let query = [kSecClass: kSecClassGenericPassword, kSecAttrService: "StableBar", kSecAttrAccount: account,
                 kSecReturnData: true] as CFDictionary
    guard SecItemCopyMatching(query, &data) == errSecSuccess else { return "" }
    return String(decoding: data as! Data, as: UTF8.self)
}

func packageSecretIsSaved(_ account: String) throws -> Bool {
    let query = [kSecClass: kSecClassGenericPassword, kSecAttrService: "StableBar", kSecAttrAccount: account] as CFDictionary
    let status = SecItemCopyMatching(query, nil)
    if status == errSecItemNotFound { return false }
    guard status == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
    return true
}

func savePackageSecret(_ value: String, account: String) throws {
    let item = [kSecClass: kSecClassGenericPassword, kSecAttrService: "StableBar", kSecAttrAccount: account] as [CFString: Any]
    var status: OSStatus
    if value.isEmpty {
        status = SecItemDelete(item as CFDictionary)
        if status == errSecItemNotFound { status = errSecSuccess }
    } else {
        let data = [kSecValueData: Data(value.utf8)] as [CFString: Any]
        status = SecItemUpdate(item as CFDictionary, data as CFDictionary)
        if status == errSecItemNotFound { status = SecItemAdd(item.merging(data) { $1 } as CFDictionary, nil) }
    }
    guard status == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
}
