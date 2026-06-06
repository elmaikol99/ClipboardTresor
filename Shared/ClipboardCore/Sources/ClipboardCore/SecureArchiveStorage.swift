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
    private let header = Data("CLPAENC1\n".utf8)
    private lazy var key: SymmetricKey = {
        do {
            return SymmetricKey(data: try loadOrCreateKeyData())
        } catch {
            fatalError("Clipboard encryption key unavailable: \(error)")
        }
    }()

    public init(service: String, account: String = "archive-encryption-key-v1") {
        self.service = service
        self.account = account
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
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var item: CFTypeRef?
        let readStatus = SecItemCopyMatching(query as CFDictionary, &item)
        if readStatus == errSecSuccess, let data = item as? Data, data.count == 32 {
            return data
        }
        if readStatus != errSecItemNotFound {
            throw SecureStorageError.keychainReadFailed(readStatus)
        }

        var keyData = Data(count: 32)
        let randomStatus = keyData.withUnsafeMutableBytes { buffer in
            SecRandomCopyBytes(kSecRandomDefault, 32, buffer.baseAddress!)
        }
        guard randomStatus == errSecSuccess else {
            throw SecureStorageError.randomFailed(randomStatus)
        }

        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData as String: keyData
        ]
        let writeStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard writeStatus == errSecSuccess else {
            throw SecureStorageError.keychainWriteFailed(writeStatus)
        }
        return keyData
    }
}
