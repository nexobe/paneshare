#if os(macOS)
import Foundation
import PaneshareCore
import Security

public struct KeychainError: Error, CustomStringConvertible {
    public let what: String
    public let status: OSStatus
    public var description: String {
        let message = SecCopyErrorMessageString(status, nil).map { $0 as String } ?? "error \(status)"
        return "\(what): \(message)"
    }
}

/// The device key (raw P-256 scalar) and the trust list, as generic passwords.
///
/// It prefers the data-protection keychain, where only this app's signing team can create or read
/// items, so another process can't plant a key before the first launch. That keychain needs a
/// provisioning profile. An ad hoc signed development build gets `errSecMissingEntitlement`, and
/// then the store falls back to the login keychain, which can't tell who created an item.
/// `isDataProtection` says which one is in use, and the UI shows it.
public final class KeychainStore {
    public static let service = "dev.paneshare.identity"
    static let keyAccount = "device-key"
    static let trustAccount = "trusted-peers"

    public private(set) var isDataProtection: Bool

    public init() {
        isDataProtection = Self.hasKeychainEntitlement
    }

    /// Without this entitlement a data-protection read says "not found", not "missing entitlement",
    /// even when the item is in the login keychain. So the store must choose before its first read.
    private static var hasKeychainEntitlement: Bool {
        guard let task = SecTaskCreateFromSelf(nil) else { return false }
        return SecTaskCopyValueForEntitlement(task, "keychain-access-groups" as CFString, nil) != nil
    }

    public func loadOrCreateIdentity() throws -> DeviceIdentity {
        if let raw = try read(Self.keyAccount) {
            return try DeviceIdentity(rawPrivateKey: raw)
        }
        let identity = try DeviceIdentity.generate()
        try add(identity.privateKey.rawRepresentation, account: Self.keyAccount)
        return identity
    }

    public func loadTrust() throws -> TrustStore {
        guard let data = try read(Self.trustAccount) else { return TrustStore() }
        return try TrustStore.decode(data)
    }

    public func saveTrust(_ trust: TrustStore) throws {
        try write(try trust.encoded(), account: Self.trustAccount)
    }

    /// Forgets this Mac's identity and every pairing. The next launch makes a new identity.
    public func reset() {
        for account in [Self.keyAccount, Self.trustAccount] {
            for dp in [true, false] {
                var q = base(account)
                if dp { q[kSecUseDataProtectionKeychain as String] = true }
                SecItemDelete(q as CFDictionary)
            }
        }
    }

    private func base(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: Self.service,
         kSecAttrAccount as String: account]
    }

    private func scoped(_ account: String) -> [String: Any] {
        var q = base(account)
        if isDataProtection { q[kSecUseDataProtectionKeychain as String] = true }
        return q
    }

    /// The item's bytes, nil when it doesn't exist. Any other failure throws: silently making a new key
    /// would change this Mac's identity and break every pin.
    private func read(_ account: String) throws -> Data? {
        var q = scoped(account)
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        q[kSecReturnData as String] = true
        var item: CFTypeRef?
        var status = SecItemCopyMatching(q as CFDictionary, &item)
        if status == errSecMissingEntitlement, isDataProtection {
            isDataProtection = false
            return try read(account)
        }
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else {
            if status == errSecSuccess { status = errSecDecode }
            throw KeychainError(what: "\(account) couldn't be read", status: status)
        }
        return data
    }

    private func write(_ data: Data, account: String) throws {
        let q = scoped(account)
        let updated = SecItemUpdate(q as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if updated == errSecSuccess { return }
        if updated == errSecMissingEntitlement, isDataProtection {
            isDataProtection = false
            return try write(data, account: account)
        }
        guard updated == errSecItemNotFound else { throw KeychainError(what: "\(account) couldn't be saved", status: updated) }
        try add(data, account: account)
    }

    /// Only ever creates. An existing item makes this throw, so a new key can't replace this Mac's
    /// identity even if a read wrongly found nothing.
    private func add(_ data: Data, account: String) throws {
        var add = scoped(account)
        add[kSecValueData as String] = data
        add[kSecAttrLabel as String] = "paneshare (\(account))"
        if isDataProtection { add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly }
        let added = SecItemAdd(add as CFDictionary, nil)
        if added == errSecMissingEntitlement, isDataProtection {
            isDataProtection = false
            return try self.add(data, account: account)
        }
        guard added == errSecSuccess else { throw KeychainError(what: "\(account) couldn't be saved", status: added) }
    }
}
#endif
