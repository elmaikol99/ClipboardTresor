import Foundation

public enum ClipboardArchiveError: Error, Sendable {
    case entryNotFound
}

public final class ClipboardArchiveRepository: @unchecked Sendable {
    public private(set) var entries: [ClipEntry] = []

    public let configuration: ArchiveConfiguration
    public let storage: SecureArchiveStorage

    private let rootURL: URL
    private let indexURL: URL

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
        self.storage = SecureArchiveStorage(service: configuration.bundleIdentifier)
        rootURL = configuration.rootURL
        indexURL = rootURL.appendingPathComponent("clipboard_history.json")
        createFolders()
        load()
        migrateIndexIfNeeded()
    }

    @discardableResult
    public func reload() -> [ClipEntry] {
        load()
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

    public func toggleFavorite(_ entry: ClipEntry) throws {
        guard let index = entries.firstIndex(where: { $0.id == entry.id }) else {
            throw ClipboardArchiveError.entryNotFound
        }
        let newValue = !(entries[index].isFavorite == true)
        entries[index].isFavorite = newValue
        if !newValue {
            entries[index].favoriteShortcut = nil
        }
        saveIndex()
    }

    public func setFavoriteShortcut(_ shortcut: String?, for entry: ClipEntry) throws {
        guard let index = entries.firstIndex(where: { $0.id == entry.id }) else {
            throw ClipboardArchiveError.entryNotFound
        }

        if let shortcut {
            for otherIndex in entries.indices where entries[otherIndex].favoriteShortcut == shortcut {
                entries[otherIndex].favoriteShortcut = nil
            }
            entries[index].isFavorite = true
            entries[index].favoriteShortcut = shortcut
        } else {
            entries[index].favoriteShortcut = nil
        }

        saveIndex()
    }

    private func insertAndSave(_ entry: ClipEntry) {
        entries.insert(entry, at: 0)
        saveIndex()
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

    private func migrateIndexIfNeeded() {
        if FileManager.default.fileExists(atPath: indexURL.path) {
            storage.encryptFileIfNeeded(at: indexURL)
        }
    }
}
