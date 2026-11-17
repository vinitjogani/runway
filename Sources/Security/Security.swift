// The Keychain's generic-password API (SecItemAdd/CopyMatching/Update/
// Delete) for Linux and Windows. Items live in a per-user store readable
// only by the user (0600): $XDG_DATA_HOME/runway/keychain.json on Linux,
// %APPDATA%\runway\keychain.json on Windows.
// The Secret Service (libsecret) and Windows Credential Manager are the
// stronger native homes; this keeps the API working where they're absent.

import Foundation
import RunwayFoundation

public let errSecSuccess: OSStatus = 0
public let errSecItemNotFound: OSStatus = -25300
public let errSecDuplicateItem: OSStatus = -25299
public let errSecParam: OSStatus = -50
public let errSecIO: OSStatus = -36

public let kSecClass: CFString = "class"
public let kSecClassGenericPassword: CFString = "genp"
public let kSecClassInternetPassword: CFString = "inet"
public let kSecAttrService: CFString = "svce"
public let kSecAttrAccount: CFString = "acct"
public let kSecAttrLabel: CFString = "labl"
public let kSecAttrServer: CFString = "srvr"
public let kSecAttrSynchronizable: CFString = "sync"
public let kSecAttrAccessible: CFString = "pdmn"
public let kSecAttrAccessibleAfterFirstUnlock: CFString = "ck"
public let kSecAttrAccessibleWhenUnlocked: CFString = "ak"
public let kSecUseDataProtectionKeychain: CFString = "nleg"
public let kSecValueData: CFString = "v_Data"
public let kSecReturnData: CFString = "r_Data"
public let kSecReturnAttributes: CFString = "r_Attributes"
public let kSecMatchLimit: CFString = "m_Limit"
public let kSecMatchLimitOne: CFString = "m_LimitOne"
public let kSecMatchLimitAll: CFString = "m_LimitAll"

public func SecCopyErrorMessageString(_ status: OSStatus, _ reserved: UnsafeMutableRawPointer?) -> CFString? {
    "Keychain error \(status)" as NSString
}

enum Keychain {
    struct Item: Codable { var service: String; var account: String; var label: String?; var data: Data }
    static let lock = NSLock()

    static var url: URL {
        #if os(Windows)
        let base = ProcessInfo.processInfo.environment["APPDATA"].map { URL(fileURLWithPath: $0) } ?? FileManager.default.homeDirectoryForCurrentUser
        #else
        let base = ProcessInfo.processInfo.environment["XDG_DATA_HOME"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/share")
        #endif
        return base.appendingPathComponent("runway/keychain.json")
    }

    static func load() -> [Item] {
        guard let d = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([Item].self, from: d)) ?? []
    }

    static func save(_ items: [Item]) -> OSStatus {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(items).write(to: url, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            return errSecSuccess
        } catch { return errSecIO }
    }

    static func value(_ q: NSDictionary, _ key: CFString) -> Any? { q.object(forKey: key) ?? q.object(forKey: key as String) }
    static func string(_ q: NSDictionary, _ key: CFString) -> String? {
        (value(q, key) as? String) ?? (value(q, key) as? NSString).map { $0 as String }
    }
    static func matches(_ item: Item, _ q: NSDictionary) -> Bool {
        if let s = string(q, kSecAttrService), s != item.service { return false }
        if let a = string(q, kSecAttrAccount), a != item.account { return false }
        return true
    }
}

public func SecItemCopyMatching(_ query: CFDictionary, _ result: UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus {
    Keychain.lock.lock(); defer { Keychain.lock.unlock() }
    let found = Keychain.load().filter { Keychain.matches($0, query) }
    guard let first = found.first else { return errSecItemNotFound }
    if let result {
        let wantsData = (Keychain.value(query, kSecReturnData) as? Bool) ?? false
        result.pointee = wantsData ? NSData(data: first.data) : ([kSecAttrService: first.service, kSecAttrAccount: first.account] as NSDictionary)
    }
    return errSecSuccess
}

public func SecItemAdd(_ attributes: CFDictionary, _ result: UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus {
    Keychain.lock.lock(); defer { Keychain.lock.unlock() }
    var items = Keychain.load()
    guard let service = Keychain.string(attributes, kSecAttrService), let account = Keychain.string(attributes, kSecAttrAccount) else { return errSecParam }
    if items.contains(where: { $0.service == service && $0.account == account }) { return errSecDuplicateItem }
    let data = (Keychain.value(attributes, kSecValueData) as? Data) ?? (Keychain.value(attributes, kSecValueData) as? NSData).map { Data(referencing: $0) } ?? Data()
    items.append(Keychain.Item(service: service, account: account, label: Keychain.string(attributes, kSecAttrLabel), data: data))
    return Keychain.save(items)
}

public func SecItemUpdate(_ query: CFDictionary, _ attributesToUpdate: CFDictionary) -> OSStatus {
    Keychain.lock.lock(); defer { Keychain.lock.unlock() }
    var items = Keychain.load()
    var hit = false
    for i in items.indices where Keychain.matches(items[i], query) {
        hit = true
        if let d = (Keychain.value(attributesToUpdate, kSecValueData) as? Data) ?? (Keychain.value(attributesToUpdate, kSecValueData) as? NSData).map({ Data(referencing: $0) }) {
            items[i].data = d
        }
    }
    return hit ? Keychain.save(items) : errSecItemNotFound
}

public func SecItemDelete(_ query: CFDictionary) -> OSStatus {
    Keychain.lock.lock(); defer { Keychain.lock.unlock() }
    let items = Keychain.load()
    let kept = items.filter { !Keychain.matches($0, query) }
    guard kept.count != items.count else { return errSecItemNotFound }
    return Keychain.save(kept)
}
