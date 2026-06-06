import CryptoKit
import Foundation

public struct FavoriteSyncRecord: Codable, Equatable, Sendable {
    public let signature: String
    public var isFavorite: Bool
    public var favoriteShortcut: String?
    public var updatedAt: Date

    public init(signature: String, isFavorite: Bool, favoriteShortcut: String?, updatedAt: Date = Date()) {
        self.signature = signature
        self.isFavorite = isFavorite
        self.favoriteShortcut = favoriteShortcut
        self.updatedAt = updatedAt
    }
}

public final class FavoriteSyncStore: @unchecked Sendable {
    private let defaults: UserDefaults
    private let standardDefaults = UserDefaults.standard
    private let recordsKey = "clipboardTresor.favoriteSync.records.v1"

    public init(appGroupIdentifier: String? = nil) {
        if let appGroupIdentifier,
           let appGroupDefaults = UserDefaults(suiteName: appGroupIdentifier) {
            defaults = appGroupDefaults
        } else {
            defaults = .standard
        }
        migrateStandardRecordsIfNeeded()
    }

    public func records() -> [String: FavoriteSyncRecord] {
        decode(defaults.data(forKey: recordsKey))
    }

    public func upsert(signature: String, isFavorite: Bool, favoriteShortcut: String?) {
        var current = records()
        current[signature] = FavoriteSyncRecord(
            signature: signature,
            isFavorite: isFavorite,
            favoriteShortcut: isFavorite ? favoriteShortcut : nil
        )
        save(current)
    }

    public func seedMissing(_ recordsToSeed: [FavoriteSyncRecord]) {
        var current = records()
        var changed = false

        for record in recordsToSeed where current[record.signature] == nil {
            current[record.signature] = record
            changed = true
        }

        if changed {
            save(current)
        }
    }

    public func encodedRecords() -> Data? {
        encode(records())
    }

    @discardableResult
    public func mergeEncodedRecords(_ data: Data) -> Bool {
        let incoming = decode(data)
        guard !incoming.isEmpty else { return false }
        var current = records()
        var changed = false

        for (signature, record) in incoming {
            if let existing = current[signature], existing.updatedAt >= record.updatedAt {
                continue
            }
            current[signature] = record
            changed = true
        }

        if changed {
            save(current)
        }
        return changed
    }

    private func save(_ records: [String: FavoriteSyncRecord]) {
        guard let data = encode(records) else { return }
        defaults.set(data, forKey: recordsKey)
    }

    private func encode(_ records: [String: FavoriteSyncRecord]) -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try? encoder.encode(records)
    }

    private func decode(_ data: Data?) -> [String: FavoriteSyncRecord] {
        guard let data else { return [:] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([String: FavoriteSyncRecord].self, from: data)) ?? [:]
    }

    private func migrateStandardRecordsIfNeeded() {
        guard defaults !== standardDefaults,
              let standardData = standardDefaults.data(forKey: recordsKey) else { return }
        let standardRecords = decode(standardData)
        guard !standardRecords.isEmpty else { return }

        var current = records()
        var changed = false
        for (signature, record) in standardRecords {
            if let existing = current[signature], existing.updatedAt >= record.updatedAt {
                continue
            }
            current[signature] = record
            changed = true
        }

        if changed {
            save(current)
        }
    }
}

public enum ClipContentSignature {
    public static func signature(kind: ClipKind, data: Data) -> String {
        let digest = SHA256.hash(data: data)
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return "\(kind.rawValue):\(hex)"
    }

    public static func normalizedTextSignature(_ text: String) -> String? {
        let normalized = text
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }
        let data = Data(normalized.utf8)
        let digest = SHA256.hash(data: data)
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return "text-normalized:\(hex)"
    }
}
