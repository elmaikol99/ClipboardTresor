import Foundation

public enum ClipboardArchiveError: Error, Sendable {
    case entryNotFound
    case unsupportedSyncItem
}

public struct ArchiveDiagnostics: Equatable, Sendable {
    public let rootExists: Bool
    public let indexExists: Bool
    public let canReadIndex: Bool
    public let canDecodeIndex: Bool
    public let decodedEntryCount: Int
    public let errorDescription: String?

    public var summary: String {
        if !rootExists { return "Ordner fehlt" }
        if !indexExists { return "Index fehlt" }
        if !canReadIndex { return "Index nicht lesbar" }
        if !canDecodeIndex { return "Index nicht dekodierbar" }
        return "\(decodedEntryCount) Einträge"
    }
}

public final class ClipboardArchiveRepository: @unchecked Sendable {
    public private(set) var entries: [ClipEntry] = []

    public let configuration: ArchiveConfiguration
    public let storage: SecureArchiveStorage

    private let rootURL: URL
    private let indexURL: URL
    private let favoriteSyncStore: FavoriteSyncStore
    private var contentSignatureCache: [String: [String]] = [:]

    private let folderFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "de_DE")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private let fileFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "de_DE")
        formatter.dateFormat = "HH-mm-ss"
        return formatter
    }()

    public init(configuration: ArchiveConfiguration = ArchiveConfiguration()) {
        self.configuration = configuration
        self.storage = SecureArchiveStorage(
            service: configuration.bundleIdentifier,
            accessGroup: configuration.keychainAccessGroup,
            prefersLegacyKey: configuration.prefersLegacyKeychainKey
        )
        self.favoriteSyncStore = FavoriteSyncStore(appGroupIdentifier: configuration.appGroupIdentifier)
        rootURL = configuration.rootURL
        indexURL = rootURL.appendingPathComponent("clipboard_history.json")
        createFolders()
        storage.repairSharedKeyIfNeeded(usingEncryptedFile: indexURL)
        load()
        migrateIndexIfNeeded()
        publishCurrentFavoritesIfNeeded()
        applyFavoriteSyncRecords()
    }

    @discardableResult
    public func reload() -> [ClipEntry] {
        load()
        publishCurrentFavoritesIfNeeded()
        applyFavoriteSyncRecords()
        return entries
    }

    @discardableResult
    public func addText(_ text: String, date: Date = Date()) throws -> ClipEntry {
        let data = Data(text.utf8)
        let id = UUID().uuidString
        let dayURL = dayFolder(for: date)
        let fileURL = dayURL.appendingPathComponent("\(fileFormatter.string(from: date))_text_\(id.prefix(8)).txt")

        try storage.writeEncrypted(data, to: fileURL)

        let entry = ClipEntry(
            id: id,
            kind: .text,
            createdAt: date,
            filePath: fileURL.path,
            preview: text.normalizedPreview(maxCharacters: 220),
            byteCount: data.count,
            pasteboardArchivePath: nil
        )
        insertAndSave(entry)
        return entry
    }

    @discardableResult
    public func addImageData(_ data: Data, fileExtension: String = "png", date: Date = Date()) throws -> ClipEntry {
        let id = UUID().uuidString
        let dayURL = dayFolder(for: date)
        let fileURL = dayURL.appendingPathComponent("\(fileFormatter.string(from: date))_bild_\(id.prefix(8)).\(fileExtension)")

        try storage.writeEncrypted(data, to: fileURL)

        let entry = ClipEntry(
            id: id,
            kind: .image,
            createdAt: date,
            filePath: fileURL.path,
            preview: "Bild",
            byteCount: data.count,
            pasteboardArchivePath: nil
        )
        insertAndSave(entry)
        return entry
    }

    public func data(for entry: ClipEntry) throws -> Data {
        try storage.readData(from: entry.url)
    }

    public func string(for entry: ClipEntry) throws -> String {
        try storage.readString(from: entry.url)
    }

    public func delete(_ entry: ClipEntry) {
        try? FileManager.default.removeItem(at: entry.url)
        if let archivePath = entry.pasteboardArchivePath {
            try? FileManager.default.removeItem(atPath: archivePath)
        }
        if let richPreviewPath = entry.richPreviewPath {
            try? FileManager.default.removeItem(atPath: richPreviewPath)
        }
        entries.removeAll { $0.id == entry.id }
        saveIndex()
    }

    public func diagnostics() -> ArchiveDiagnostics {
        let rootExists = FileManager.default.fileExists(atPath: rootURL.path)
        let indexExists = FileManager.default.fileExists(atPath: indexURL.path)
        guard indexExists else {
            return ArchiveDiagnostics(
                rootExists: rootExists,
                indexExists: false,
                canReadIndex: false,
                canDecodeIndex: false,
                decodedEntryCount: 0,
                errorDescription: nil
            )
        }

        let data: Data
        do {
            data = try storage.readData(from: indexURL)
        } catch {
            return ArchiveDiagnostics(
                rootExists: rootExists,
                indexExists: true,
                canReadIndex: false,
                canDecodeIndex: false,
                decodedEntryCount: 0,
                errorDescription: String(describing: error)
            )
        }

        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let decoded = try decoder.decode([ClipEntry].self, from: data)
            return ArchiveDiagnostics(
                rootExists: rootExists,
                indexExists: true,
                canReadIndex: true,
                canDecodeIndex: true,
                decodedEntryCount: decoded.count,
                errorDescription: nil
            )
        } catch {
            return ArchiveDiagnostics(
                rootExists: rootExists,
                indexExists: true,
                canReadIndex: true,
                canDecodeIndex: false,
                decodedEntryCount: 0,
                errorDescription: String(describing: error)
            )
        }
    }

    public func favoriteSyncPayload() -> Data? {
        publishCurrentFavoritesIfNeeded()
        return favoriteSyncStore.encodedRecords()
    }

    @discardableResult
    public func mergeFavoriteSyncPayload(_ data: Data) -> Bool {
        if favoriteSyncStore.mergeEncodedRecords(data) {
            load()
            return applyFavoriteSyncRecords()
        }
        return false
    }

    @discardableResult
    public func importArchiveSyncPayload(_ data: Data) -> Int {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let payload = try? decoder.decode(ArchiveSyncPayload.self, from: data) else { return 0 }
        return importArchiveSyncItems(payload.items)
    }

    @discardableResult
    public func importArchiveSyncItems(_ items: [ArchiveSyncItem]) -> Int {
        load()
        var existingIDs = Set(entries.map(\.id))
        var existingSignatures = Set(entries.flatMap { contentSignatures(for: $0) })
        var importedCount = 0

        var metadataChanged = false

        for item in items.sorted(by: { $0.createdAt < $1.createdAt }) {
            if let existingIndex = entries.firstIndex(where: { $0.id == item.id }) {
                if updateMetadata(for: existingIndex, from: item) {
                    metadataChanged = true
                }
                continue
            }

            guard !item.data.isEmpty else { continue }

            let incomingSignatures = contentSignatures(kind: item.kind, data: item.data)
            if !existingSignatures.isDisjoint(with: incomingSignatures) {
                if let duplicateIndex = entries.firstIndex(where: { !Set(contentSignatures(for: $0)).isDisjoint(with: incomingSignatures) }),
                   updateMetadata(for: duplicateIndex, from: item) {
                    metadataChanged = true
                }
                continue
            }

            do {
                let entry = try writeSyncedItem(item)
                entries.append(entry)
                existingIDs.insert(entry.id)
                incomingSignatures.forEach { existingSignatures.insert($0) }
                if entry.isFavorite == true {
                    pushFavoriteState(for: entry)
                }
                importedCount += 1
            } catch {
                continue
            }
        }

        entries.sort { $0.createdAt > $1.createdAt }
        if importedCount > 0 || metadataChanged {
            saveIndex()
        }
        publishCurrentFavoritesIfNeeded()
        applyFavoriteSyncRecords()
        return importedCount
    }

    public func toggleFavorite(_ entry: ClipEntry) throws {
        load()
        applyFavoriteSyncRecords(saveIfChanged: false)
        guard let index = entries.firstIndex(where: { $0.id == entry.id }) else {
            throw ClipboardArchiveError.entryNotFound
        }
        let newValue = !(entries[index].isFavorite == true)
        entries[index].isFavorite = newValue
        if !newValue {
            entries[index].favoriteShortcut = nil
        }
        saveIndex()
        pushFavoriteState(for: entries[index])
    }

    public func setFavoriteShortcut(_ shortcut: String?, for entry: ClipEntry) throws {
        load()
        applyFavoriteSyncRecords(saveIfChanged: false)
        guard let index = entries.firstIndex(where: { $0.id == entry.id }) else {
            throw ClipboardArchiveError.entryNotFound
        }

        var changedEntries: [ClipEntry] = []
        if let shortcut {
            for otherIndex in entries.indices where entries[otherIndex].favoriteShortcut == shortcut {
                entries[otherIndex].favoriteShortcut = nil
                changedEntries.append(entries[otherIndex])
            }
            entries[index].isFavorite = true
            entries[index].favoriteShortcut = shortcut
        } else {
            entries[index].favoriteShortcut = nil
        }
        changedEntries.append(entries[index])

        saveIndex()
        changedEntries.forEach { pushFavoriteState(for: $0) }
    }

    public func setTitle(_ title: String?, for entry: ClipEntry) throws {
        load()
        guard let index = entries.firstIndex(where: { $0.id == entry.id }) else {
            throw ClipboardArchiveError.entryNotFound
        }
        entries[index].title = Self.normalizedTitle(title)
        saveIndex()
    }

    private func insertAndSave(_ entry: ClipEntry) {
        entries.insert(entry, at: 0)
        applyFavoriteSyncRecords(saveIfChanged: false)
        saveIndex()
    }

    private func writeSyncedItem(_ item: ArchiveSyncItem) throws -> ClipEntry {
        switch item.kind {
        case .text:
            guard String(data: item.data, encoding: .utf8) != nil else {
                throw ClipboardArchiveError.unsupportedSyncItem
            }
        case .image:
            break
        }

        let dayURL = dayFolder(for: item.createdAt)
        let fileKind = item.kind == .image ? "bild" : "text"
        let fileExtension = item.kind == .image ? "png" : "txt"
        let fileURL = dayURL.appendingPathComponent(
            "\(fileFormatter.string(from: item.createdAt))_\(fileKind)_\(item.id.prefix(8)).\(fileExtension)"
        )
        try storage.writeEncrypted(item.data, to: fileURL)

        let richPreviewPath: String?
        if let richPreviewData = item.richPreviewData, !richPreviewData.isEmpty {
            let previewURL = dayURL.appendingPathComponent(
                "\(fileFormatter.string(from: item.createdAt))_rich_preview_\(item.id.prefix(8)).png"
            )
            try storage.writeEncrypted(richPreviewData, to: previewURL)
            richPreviewPath = previewURL.path
        } else {
            richPreviewPath = nil
        }

        return ClipEntry(
            id: item.id,
            kind: item.kind,
            createdAt: item.createdAt,
            filePath: fileURL.path,
            preview: item.preview,
            byteCount: item.data.count,
            pasteboardArchivePath: nil,
            isFavorite: item.isFavorite ?? false,
            isSensitive: false,
            displayKind: item.displayKind,
            richPreviewPath: richPreviewPath,
            favoriteShortcut: item.favoriteShortcut,
            title: Self.normalizedTitle(item.title)
        )
    }

    private func updateMetadata(for index: Int, from item: ArchiveSyncItem) -> Bool {
        var changed = false
        let normalizedTitle = Self.normalizedTitle(item.title)
        if normalizedTitle != nil, entries[index].title != normalizedTitle {
            entries[index].title = normalizedTitle
            changed = true
        }
        if entries[index].displayKind != item.displayKind {
            entries[index].displayKind = item.displayKind
            changed = true
        }
        return changed
    }

    private static func normalizedTitle(_ title: String?) -> String? {
        guard let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        return trimmed
    }

    private func dayFolder(for date: Date) -> URL {
        rootURL.appendingPathComponent(folderFormatter.string(from: date), isDirectory: true)
    }

    private func createFolders() {
        try? FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    }

    private func load() {
        guard let data = try? storage.readData(from: indexURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let decoded = try? decoder.decode([ClipEntry].self, from: data) {
            entries = decoded.sorted { $0.createdAt > $1.createdAt }
        }
    }

    private func saveIndex() {
        createFolders()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(entries) else { return }
        try? storage.writeEncrypted(data, to: indexURL)
    }

    private func publishCurrentFavoritesIfNeeded() {
        let records = entries.flatMap { entry -> [FavoriteSyncRecord] in
            guard entry.isFavorite == true else { return [] }
            return contentSignatures(for: entry).map {
                FavoriteSyncRecord(
                    signature: $0,
                    isFavorite: true,
                    favoriteShortcut: entry.favoriteShortcut
                )
            }
        }
        favoriteSyncStore.seedMissing(records)
    }

    @discardableResult
    private func applyFavoriteSyncRecords(saveIfChanged: Bool = true) -> Bool {
        let records = favoriteSyncStore.records()
        guard !records.isEmpty else { return false }

        var changed = false
        for index in entries.indices {
            guard let record = syncedRecord(for: entries[index], records: records) else { continue }
            let syncedShortcut = record.isFavorite ? record.favoriteShortcut : nil

            if entries[index].isFavorite != record.isFavorite {
                entries[index].isFavorite = record.isFavorite
                changed = true
            }
            if entries[index].favoriteShortcut != syncedShortcut {
                entries[index].favoriteShortcut = syncedShortcut
                changed = true
            }
        }

        if changed && saveIfChanged {
            saveIndex()
        }
        return changed
    }

    private func pushFavoriteState(for entry: ClipEntry) {
        contentSignatures(for: entry).forEach { signature in
            favoriteSyncStore.upsert(
                signature: signature,
                isFavorite: entry.isFavorite == true,
                favoriteShortcut: entry.favoriteShortcut
            )
        }
    }

    private func syncedRecord(for entry: ClipEntry, records: [String: FavoriteSyncRecord]) -> FavoriteSyncRecord? {
        contentSignatures(for: entry)
            .compactMap { records[$0] }
            .max { $0.updatedAt < $1.updatedAt }
    }

    private func contentSignatures(for entry: ClipEntry) -> [String] {
        if let cached = contentSignatureCache[entry.id] {
            return cached
        }
        guard let data = try? storage.readData(from: entry.url) else { return [] }
        let signatures = contentSignatures(kind: entry.kind, data: data)
        contentSignatureCache[entry.id] = signatures
        return signatures
    }

    private func contentSignatures(kind: ClipKind, data: Data) -> [String] {
        var signatures = [ClipContentSignature.signature(kind: kind, data: data)]
        if kind == .text,
           let text = String(data: data, encoding: .utf8),
           let normalizedSignature = ClipContentSignature.normalizedTextSignature(text) {
            signatures.append(normalizedSignature)
        }
        return signatures
    }

    private func migrateIndexIfNeeded() {
        if FileManager.default.fileExists(atPath: indexURL.path) {
            storage.encryptFileIfNeeded(at: indexURL)
        }
    }
}
