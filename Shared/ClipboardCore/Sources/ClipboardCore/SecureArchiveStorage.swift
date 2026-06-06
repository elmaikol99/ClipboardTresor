import CryptoKit
import Foundation
import Security

public enum SecureStorageError: Error, Sendable {
    case keychainReadFailed(OSStatus)
    case keychainWriteFailed(OSStatus)
    case randomFailed(OSStatus)
    case encryptionFailed
}

public final class SecureArchiveStorage: @unchecked Sendable {
    private let service: String
    private let account: String
    private let accessGroup: String?
    private let prefersLegacyKey: Bool
    private let header = Data("CLPAENC1\n".utf8)
    private lazy var key: SymmetricKey = {
        do {
            return SymmetricKey(data: try loadOrCreateKeyData())
        } catch {
            fatalError("Clipboard encryption key unavailable: \(error)")
        }
    }()

    public init(
        service: String,
        account: String = "archive-encryption-key-v1",
        accessGroup: String? = nil,
        prefersLegacyKey: Bool = false
    ) {
        self.service = service
        self.account = account
        self.accessGroup = accessGroup
        self.prefersLegacyKey = prefersLegacyKey
    }

    public func readData(from url: URL) throws -> Data {
        let data = try Data(contentsOf: url)
        return try decryptIfNeeded(data)
    }

    public func readString(from url: URL) throws -> String {
        let data = try readData(from: url)
        return String(decoding: data, as: UTF8.self)
    }

    public func writeEncrypted(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encrypted = try encryptIfNeeded(data)
        try encrypted.write(to: url, options: .atomic)
    }

    public func encryptFileIfNeeded(at url: URL) {
        guard let data = try? Data(contentsOf: url), !isEncrypted(data) else { return }
        try? writeEncrypted(data, to: url)
    }

    private func encryptIfNeeded(_ data: Data) throws -> Data {
        guard !isEncrypted(data) else { return data }
        let sealed = try AES.GCM.seal(data, using: key)
        guard let combined = sealed.combined else {
            throw SecureStorageError.encryptionFailed
        }
        return header + combined
    }

    private func decryptIfNeeded(_ data: Data) throws -> Data {
        guard isEncrypted(data) else { return data }
        let encrypted = data.dropFirst(header.count)
        let box = try AES.GCM.SealedBox(combined: encrypted)
        return try AES.GCM.open(box, using: key)
    }

    private func isEncrypted(_ data: Data) -> Bool {
        data.count > header.count && data.prefix(header.count) == header
    }

    private func loadOrCreateKeyData() throws -> Data {
        if prefersLegacyKey, let legacyData = try? readKeyData(accessGroup: nil) {
            try upsertSharedKeyData(legacyData)
            return legacyData
        }

        if let sharedData = try? readKeyData(accessGroup: accessGroup) {
            return sharedData
        }

        if let legacyData = try? readKeyData(accessGroup: nil) {
            try upsertSharedKeyData(legacyData)
            return legacyData
        }

        var keyData = Data(count: 32)
        let randomStatus = keyData.withUnsafeMutableBytes { buffer in
            SecRandomCopyBytes(kSecRandomDefault, 32, buffer.baseAddress!)
        }
        guard randomStatus == errSecSuccess else {
            throw SecureStorageError.randomFailed(randomStatus)
        }

        try upsertKeyData(keyData, accessGroup: accessGroup)
        return keyData
    }

    private func readKeyData(accessGroup: String?) throws -> Data {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        if let accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }

        var item: CFTypeRef?
        let readStatus = SecItemCopyMatching(query as CFDictionary, &item)
        if readStatus == errSecSuccess, let data = item as? Data, data.count == 32 {
            return data
        }
        if readStatus != errSecItemNotFound {
            throw SecureStorageError.keychainReadFailed(readStatus)
        }
        throw SecureStorageError.keychainReadFailed(readStatus)
    }

    private func upsertSharedKeyData(_ keyData: Data) throws {
        guard accessGroup != nil else { return }
        try upsertKeyData(keyData, accessGroup: accessGroup)
    }

    private func upsertKeyData(_ keyData: Data, accessGroup: String?) throws {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        if let accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }

        let update: [String: Any] = [
            kSecValueData as String: keyData
        ]
        let updateStatus = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if updateStatus == errSecSuccess {
            return
        }
        if updateStatus != errSecItemNotFound {
            throw SecureStorageError.keychainWriteFailed(updateStatus)
        }

        var addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData as String: keyData
        ]
        if let accessGroup {
            addQuery[kSecAttrAccessGroup as String] = accessGroup
        }

        let writeStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard writeStatus == errSecSuccess else {
            throw SecureStorageError.keychainWriteFailed(writeStatus)
        }
    }
}
