import AppKit
import SwiftUI
import ApplicationServices
import Carbon
import CryptoKit
import LocalAuthentication
import Network
import Security

enum ArchiveLocation {
    static let bundleIdentifier = "local.clipboardarchiv.app"
    static let parentPathDefaultsKey = "ArchiveParentPath"

    static var rootURL: URL {
        archiveParentURL().appendingPathComponent("ClipboardArchiv", isDirectory: true)
    }

    static var displayPath: String {
        abbreviatedPath(rootURL.path)
    }

    private static func archiveParentURL() -> URL {
        if let configuredPath = UserDefaults.standard.string(forKey: parentPathDefaultsKey),
           !configuredPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return URL(fileURLWithPath: (configuredPath as NSString).expandingTildeInPath, isDirectory: true)
        }

        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        return documents ?? FileManager.default.homeDirectoryForCurrentUser
    }

    private static func abbreviatedPath(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path == home {
            return "~"
        }
        if path.hasPrefix(home + "/") {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }
}

enum SecureStorageError: Error {
    case keychainReadFailed(OSStatus)
    case keychainWriteFailed(OSStatus)
    case randomFailed(OSStatus)
}

final class SecureStorage {
    static let shared = SecureStorage()

    private let service = "local.clipboardarchiv.app"
    private let account = "archive-encryption-key-v1"
    private let header = Data("CLPAENC1\n".utf8)
    private let dragTempDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("ClipboardArchivDrag", isDirectory: true)
    private lazy var key: SymmetricKey = {
        do {
            return SymmetricKey(data: try loadOrCreateKeyData())
        } catch {
            DebugLog.shared.write("Encryption key unavailable: \(error)")
            fatalError("ClipboardArchiv encryption key unavailable: \(error)")
        }
    }()

    private init() {}

    func readData(from url: URL) throws -> Data {
        let data = try Data(contentsOf: url)
        return try decryptIfNeeded(data)
    }

    func readString(from url: URL) throws -> String {
        let data = try readData(from: url)
        return String(decoding: data, as: UTF8.self)
    }

    func writeEncrypted(_ data: Data, to url: URL) throws {
        let encrypted = try encryptIfNeeded(data)
        try encrypted.write(to: url, options: .atomic)
    }

    func encryptFileIfNeeded(at url: URL) {
        guard let data = try? Data(contentsOf: url), !isEncrypted(data) else { return }
        do {
            try writeEncrypted(data, to: url)
        } catch {
            DebugLog.shared.write("Encrypt existing file failed \(url.path): \(error.localizedDescription)")
        }
    }

    func decryptedTemporaryURL(for entry: ClipEntry) -> URL? {
        guard let data = try? readData(from: entry.url) else { return nil }
        return temporaryURL(data: data, fileName: "\(entry.id)_\(entry.url.lastPathComponent)", removeAfter: 300)
    }

    func temporaryURL(data: Data, fileName: String, removeAfter: TimeInterval = 300) -> URL? {
        try? FileManager.default.createDirectory(at: dragTempDirectory, withIntermediateDirectories: true)
        let tempURL = dragTempDirectory.appendingPathComponent(fileName)
        try? data.write(to: tempURL, options: .atomic)
        DispatchQueue.main.asyncAfter(deadline: .now() + removeAfter) {
            try? FileManager.default.removeItem(at: tempURL)
        }
        return tempURL
    }

    func cleanupTemporaryFiles() {
        try? FileManager.default.removeItem(at: dragTempDirectory)
    }

    private func encryptIfNeeded(_ data: Data) throws -> Data {
        guard !isEncrypted(data) else { return data }
        let sealed = try AES.GCM.seal(data, using: key)
        guard let combined = sealed.combined else { return data }
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

struct FavoriteSyncRecord: Codable, Equatable {
    let signature: String
    var isFavorite: Bool
    var favoriteShortcut: String?
    var updatedAt: Date

    init(signature: String, isFavorite: Bool, favoriteShortcut: String?, updatedAt: Date = Date()) {
        self.signature = signature
        self.isFavorite = isFavorite
        self.favoriteShortcut = favoriteShortcut
        self.updatedAt = updatedAt
    }
}

final class FavoriteSyncStore {
    private let defaults = UserDefaults.standard
    private let recordsKey = "clipboardTresor.favoriteSync.records.v1"

    func records() -> [String: FavoriteSyncRecord] {
        decode(defaults.data(forKey: recordsKey))
    }

    func upsert(signature: String, isFavorite: Bool, favoriteShortcut: String?) {
        var current = records()
        current[signature] = FavoriteSyncRecord(
            signature: signature,
            isFavorite: isFavorite,
            favoriteShortcut: isFavorite ? favoriteShortcut : nil
        )
        save(current)
    }

    func seedMissing(_ recordsToSeed: [FavoriteSyncRecord]) {
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

    func encodedRecords() -> Data? {
        encode(records())
    }

    @discardableResult
    func mergeEncodedRecords(_ data: Data) -> Bool {
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
}

enum ClipContentSignature {
    static func signature(kind: ClipKind, data: Data) -> String {
        let digest = SHA256.hash(data: data)
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return "\(kind.rawValue):\(hex)"
    }

    static func normalizedTextSignature(_ text: String) -> String? {
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

struct ArchiveSyncItem: Codable {
    let id: String
    let kind: ClipKind
    let createdAt: Date
    let preview: String
    let data: Data
    let isFavorite: Bool?
    let displayKind: String?
    let richPreviewData: Data?
    let favoriteShortcut: String?
    let title: String?
}

struct ArchiveSyncPayload: Codable {
    let generatedAt: Date
    let items: [ArchiveSyncItem]
}

final class FavoriteSyncServer {
    private let queue = DispatchQueue(label: "ClipboardTresor.FavoriteSyncServer")
    private let getPayload: () -> Data?
    private let mergePayload: (Data) -> Void
    private let getArchivePayload: () -> Data?
    private var listener: NWListener?

    init(
        getPayload: @escaping () -> Data?,
        mergePayload: @escaping (Data) -> Void,
        getArchivePayload: @escaping () -> Data?
    ) {
        self.getPayload = getPayload
        self.mergePayload = mergePayload
        self.getArchivePayload = getArchivePayload
    }

    func start() {
        do {
            let listener = try NWListener(using: .tcp)
            listener.service = NWListener.Service(name: "ClipboardTresor", type: "_clipboardtresor._tcp")
            listener.newConnectionHandler = { [weak self] connection in
                self?.handle(connection)
            }
            listener.start(queue: queue)
            self.listener = listener
        } catch {
            DebugLog.shared.write("Favorite sync server failed: \(error.localizedDescription)")
        }
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(on: connection, buffer: Data())
    }

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, _ in
            guard let self else { return }
            var request = buffer
            if let data {
                request.append(data)
            }

            if self.isCompleteRequest(request) || isComplete {
                self.respond(to: request, on: connection)
            } else {
                self.receive(on: connection, buffer: request)
            }
        }
    }

    private func isCompleteRequest(_ data: Data) -> Bool {
        guard let headerEnd = headerEndRange(in: data) else { return false }
        let headers = String(decoding: data[..<headerEnd.lowerBound], as: UTF8.self)
        let contentLength = headers
            .components(separatedBy: "\r\n")
            .first { $0.lowercased().hasPrefix("content-length:") }?
            .split(separator: ":", maxSplits: 1)
            .last
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .flatMap { Int($0) } ?? 0
        return data.count >= headerEnd.upperBound + contentLength
    }

    private func respond(to request: Data, on connection: NWConnection) {
        let path = requestPath(from: request)

        if path == "/archive" {
            sendResponse(getArchivePayload() ?? emptyArchivePayload(), on: connection)
            return
        }

        if let body = requestBody(from: request), !body.isEmpty {
            mergePayload(body)
        }

        let body = getPayload() ?? Data("{}".utf8)
        sendResponse(body, on: connection)
    }

    private func sendResponse(_ body: Data, on connection: NWConnection) {
        let header = [
            "HTTP/1.1 200 OK",
            "Content-Type: application/json",
            "Content-Length: \(body.count)",
            "Connection: close",
            "",
            ""
        ].joined(separator: "\r\n")
        var response = Data(header.utf8)
        response.append(body)
        connection.send(content: response, isComplete: true, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private func emptyArchivePayload() -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return (try? encoder.encode(ArchiveSyncPayload(generatedAt: Date(), items: []))) ?? Data(#"{"items":[]}"#.utf8)
    }

    private func requestPath(from data: Data) -> String {
        guard let headerEnd = headerEndRange(in: data) else { return "/" }
        let headers = String(decoding: data[..<headerEnd.lowerBound], as: UTF8.self)
        let firstLine = headers.components(separatedBy: "\r\n").first ?? ""
        let parts = firstLine.split(separator: " ")
        guard parts.count >= 2 else { return "/" }
        return String(parts[1]).components(separatedBy: "?").first ?? "/"
    }

    private func requestBody(from data: Data) -> Data? {
        guard let headerEnd = headerEndRange(in: data) else { return nil }
        return data.suffix(from: headerEnd.upperBound)
    }

    private func headerEndRange(in data: Data) -> Range<Data.Index>? {
        let marker = Data("\r\n\r\n".utf8)
        return data.range(of: marker)
    }
}

final class DebugLog {
    static let shared = DebugLog()

    private let logURL: URL
    private let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "de_DE")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return formatter
    }()

    private init() {
        let root = ArchiveLocation.rootURL
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        logURL = root.appendingPathComponent("diagnose.log")
    }

    func write(_ message: String) {
        let line = "[\(formatter.string(from: Date()))] \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        if FileManager.default.fileExists(atPath: logURL.path),
           let handle = try? FileHandle(forWritingTo: logURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: logURL, options: .atomic)
        }
    }

    func open() {
        NSWorkspace.shared.open(logURL)
    }
}

enum ClipKind: String, Codable {
    case text
    case image
}

struct ClipEntry: Identifiable, Codable, Equatable {
    let id: String
    let kind: ClipKind
    let createdAt: Date
    let filePath: String
    var preview: String
    let byteCount: Int
    let pasteboardArchivePath: String?
    var isFavorite: Bool?
    var isSensitive: Bool?
    var displayKind: String?
    var richPreviewPath: String?
    var favoriteShortcut: String?
    var title: String?

    var url: URL {
        URL(fileURLWithPath: filePath)
    }

    var displayLabel: String {
        displayKind ?? (kind == .text ? "Text" : "Bild")
    }

    var displayTitle: String {
        if let trimmedTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines),
           !trimmedTitle.isEmpty {
            return trimmedTitle
        }
        return displayLabel
    }

    var displaySystemImage: String {
        displayLabel == "Bild" ? "photo" : "text.alignleft"
    }

    var richPreviewURL: URL? {
        guard let richPreviewPath else { return nil }
        return URL(fileURLWithPath: richPreviewPath)
    }
}

struct PasteboardArchiveManifest: Codable {
    struct ArchivedType: Codable {
        let pasteboardType: String
        let fileName: String
    }

    struct ArchivedItem: Codable {
        let types: [ArchivedType]
    }

    let items: [ArchivedItem]
}

final class ClipboardStore: ObservableObject {
    @Published private(set) var entries: [ClipEntry] = []
    @Published var lastStatus: String = "Bereit"
    @Published var scrollToTopRequest = 0
    var onExternalReload: (() -> Void)?

    private let pasteboard = NSPasteboard.general
    private let rootURL: URL
    private let indexURL: URL
    private var lastIndexModifiedAt: Date?
    private var lastChangeCount: Int
    private var skippedChangeCount: Int?
    private var lastSignature: String?
    private var timer: Timer?
    private let favoriteSyncStore = FavoriteSyncStore()
    private var contentSignatureCache: [String: [String]] = [:]
    private var lastFavoriteSyncRefresh = Date.distantPast
    private var favoriteSyncServer: FavoriteSyncServer?
    private let archiveSyncLookback: TimeInterval = 3 * 24 * 60 * 60
    private let archiveSyncMaxItems = 250
    private let archiveSyncMaxBytes = 50 * 1024 * 1024

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

    private let statusDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "de_DE")
        formatter.dateFormat = "dd.MM.yyyy HH:mm:ss"
        return formatter
    }()

    init() {
        rootURL = ArchiveLocation.rootURL
        indexURL = rootURL.appendingPathComponent("clipboard_history.json")
        lastChangeCount = pasteboard.changeCount
        load()
        createFolders()
        migrateExistingEntriesForSecurity()
        publishCurrentFavoritesIfNeeded()
        applyFavoriteSyncRecords()
        startFavoriteSyncServer()
        lastIndexModifiedAt = indexModificationDate()
    }

    func startMonitoring() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.45, repeats: true) { [weak self] _ in
            self?.pollPasteboard()
        }
    }

    func stopMonitoring() {
        timer?.invalidate()
        timer = nil
    }

    func requestScrollToTop() {
        scrollToTopRequest += 1
    }

    func copyToPasteboard(_ entry: ClipEntry) {
        if entry.kind == .image {
            copyImageEntryToPasteboard(entry)
            return
        }

        if restorePasteboardArchive(for: entry) {
            updateSignatureAfterCopying(entry)
            skippedChangeCount = pasteboard.changeCount
            setCopiedStatus(for: entry)
            return
        }

        pasteboard.clearContents()

        switch entry.kind {
        case .text:
            guard let text = try? SecureStorage.shared.readString(from: entry.url) else { return }
            pasteboard.setString(text, forType: .string)
        case .image:
            guard let data = try? SecureStorage.shared.readData(from: entry.url),
                  let image = NSImage(data: data) else { return }
            pasteboard.writeObjects([image])
        }

        updateSignatureAfterCopying(entry)
        skippedChangeCount = pasteboard.changeCount
        setCopiedStatus(for: entry)
    }

    private func copyImageEntryToPasteboard(_ entry: ClipEntry) {
        guard let data = try? SecureStorage.shared.readData(from: entry.url),
              let image = NSImage(data: data) else {
            lastStatus = "Bild konnte nicht kopiert werden"
            return
        }

        pasteboard.clearContents()

        let item = NSPasteboardItem()
        item.setData(data, forType: NSPasteboard.PasteboardType("public.png"))
        if let tiff = image.tiffRepresentation {
            item.setData(tiff, forType: .tiff)
        }

        let didWrite = pasteboard.writeObjects([item])
        if !didWrite {
            pasteboard.clearContents()
            pasteboard.writeObjects([image])
        }

        updateSignatureAfterCopying(entry)
        skippedChangeCount = pasteboard.changeCount
        setCopiedStatus(for: entry)
    }

    func reveal(_ entry: ClipEntry) {
        NSWorkspace.shared.activateFileViewerSelecting([entry.url])
    }

    func openArchiveFolder() {
        NSWorkspace.shared.open(rootURL)
    }

    func delete(_ entry: ClipEntry) {
        try? FileManager.default.removeItem(at: entry.url)
        if let archivePath = entry.pasteboardArchivePath {
            try? FileManager.default.removeItem(atPath: archivePath)
        }
        if let richPreviewPath = entry.richPreviewPath {
            try? FileManager.default.removeItem(atPath: richPreviewPath)
        }
        entries.removeAll { $0.id == entry.id }
        saveIndex()
        lastStatus = "Eintrag gelöscht"
    }

    func toggleFavorite(_ entry: ClipEntry) {
        load()
        applyFavoriteSyncRecords(saveIfChanged: false)
        guard let index = entries.firstIndex(where: { $0.id == entry.id }) else { return }
        let newValue = !(entries[index].isFavorite == true)
        entries[index].isFavorite = newValue
        if !newValue {
            entries[index].favoriteShortcut = nil
        }
        saveIndex()
        pushFavoriteState(for: entries[index])
        lastStatus = newValue ? "Zu Favoriten hinzugefügt" : "Aus Favoriten entfernt"
    }

    func setFavoriteShortcut(_ shortcut: String?, for entry: ClipEntry) {
        load()
        applyFavoriteSyncRecords(saveIfChanged: false)
        guard let index = entries.firstIndex(where: { $0.id == entry.id }) else { return }

        var changedEntries: [ClipEntry] = []
        if let shortcut {
            for otherIndex in entries.indices where entries[otherIndex].favoriteShortcut == shortcut {
                entries[otherIndex].favoriteShortcut = nil
                changedEntries.append(entries[otherIndex])
            }
            entries[index].isFavorite = true
            entries[index].favoriteShortcut = shortcut
            lastStatus = "Shortcut \(shortcut) zugewiesen"
        } else {
            entries[index].favoriteShortcut = nil
            lastStatus = "Shortcut entfernt"
        }
        changedEntries.append(entries[index])

        saveIndex()
        changedEntries.forEach { pushFavoriteState(for: $0) }
    }

    func setTitle(_ title: String?, for entry: ClipEntry) {
        load()
        guard let index = entries.firstIndex(where: { $0.id == entry.id }) else { return }
        entries[index].title = Self.normalizedTitle(title)
        saveIndex()
        onExternalReload?()
        lastStatus = entries[index].title == nil ? "Name entfernt" : "Name geändert"
    }

    func entry(withID id: String) -> ClipEntry? {
        entries.first { $0.id == id }
    }

    private func pollPasteboard() {
        refreshFromExternalIndexIfNeeded()
        refreshFavoritesFromSyncIfNeeded()

        let changeCount = pasteboard.changeCount
        guard changeCount != lastChangeCount else { return }
        lastChangeCount = changeCount

        if skippedChangeCount == changeCount {
            skippedChangeCount = nil
            return
        }

        if let imageData = pasteboardImageData() {
            storeImage(data: imageData)
            return
        }

        if let text = pasteboard.string(forType: .string), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if pasteboardContainsImageReference() {
                storeText(
                    text,
                    previewOverride: "Bild aus Rich-Clipboard",
                    displayKind: "Bild",
                    signaturePrefix: "rich-image"
                )
            } else {
                storeText(text)
            }
            return
        }

        if let image = NSImage(pasteboard: pasteboard), let png = image.pngData() {
            storeImage(data: png)
        }
    }

    private func storeText(
        _ text: String,
        previewOverride: String? = nil,
        displayKind: String? = nil,
        signaturePrefix: String = "text"
    ) {
        let data = Data(text.utf8)
        let signature = pasteboardSignature(prefix: signaturePrefix, fallbackData: data)
        guard signature != lastSignature else { return }
        lastSignature = signature

        let now = Date()
        let id = UUID().uuidString
        let dayURL = dayFolder(for: now)
        let fileURL = dayURL.appendingPathComponent("\(fileFormatter.string(from: now))_text_\(id.prefix(8)).txt")
        let richPreviewPath = displayKind == "Bild" ? storeRichImagePreview(id: id, date: now, dayURL: dayURL) : nil

        do {
            try FileManager.default.createDirectory(at: dayURL, withIntermediateDirectories: true)
            try SecureStorage.shared.writeEncrypted(data, to: fileURL)
            let entry = ClipEntry(
                id: id,
                kind: .text,
                createdAt: now,
                filePath: fileURL.path,
                preview: previewOverride ?? text.normalizedPreview(maxCharacters: 220),
                byteCount: data.count,
                pasteboardArchivePath: archivePasteboardItems(id: id, date: now, dayURL: dayURL),
                isFavorite: false,
                isSensitive: false,
                displayKind: displayKind,
                richPreviewPath: richPreviewPath,
                favoriteShortcut: nil,
                title: nil
            )
            add(entry)
        } catch {
            lastStatus = "Text konnte nicht gespeichert werden: \(error.localizedDescription)"
        }
    }

    private func storeImage(data: Data) {
        let signature = pasteboardSignature(prefix: "image", fallbackData: data)
        guard signature != lastSignature else { return }
        lastSignature = signature

        let now = Date()
        let id = UUID().uuidString
        let dayURL = dayFolder(for: now)
        let fileURL = dayURL.appendingPathComponent("\(fileFormatter.string(from: now))_bild_\(id.prefix(8)).png")

        do {
            try FileManager.default.createDirectory(at: dayURL, withIntermediateDirectories: true)
            try SecureStorage.shared.writeEncrypted(data, to: fileURL)
            let entry = ClipEntry(
                id: id,
                kind: .image,
                createdAt: now,
                filePath: fileURL.path,
                preview: "Bild",
                byteCount: data.count,
                pasteboardArchivePath: archivePasteboardItems(id: id, date: now, dayURL: dayURL),
                isFavorite: false,
                isSensitive: false,
                displayKind: nil,
                richPreviewPath: nil,
                favoriteShortcut: nil,
                title: nil
            )
            add(entry)
        } catch {
            lastStatus = "Bild konnte nicht gespeichert werden: \(error.localizedDescription)"
        }
    }

    private func pasteboardImageData() -> Data? {
        let imageTypes = [
            NSPasteboard.PasteboardType("public.png"),
            NSPasteboard.PasteboardType("public.tiff"),
            NSPasteboard.PasteboardType("public.jpeg"),
            NSPasteboard.PasteboardType("public.heic"),
            NSPasteboard.PasteboardType("com.compuserve.gif"),
            NSPasteboard.PasteboardType.tiff
        ]

        for item in pasteboard.pasteboardItems ?? [] {
            for type in imageTypes where item.types.contains(type) {
                guard let data = item.data(forType: type), !data.isEmpty else { continue }
                if let normalized = normalizedImageData(data, type: type.rawValue) {
                    return normalized
                }
            }
        }

        if let image = NSImage(pasteboard: pasteboard), let png = image.pngData() {
            return png
        }

        return nil
    }

    private func normalizedImageData(_ data: Data, type: String) -> Data? {
        if type == "public.png",
           let image = NSImage(data: data),
           image.size.width > 8,
           image.size.height > 8 {
            return data
        }

        guard let image = NSImage(data: data),
              image.size.width > 8,
              image.size.height > 8 else { return nil }
        return image.pngData()
    }

    private func pasteboardContainsImageReference() -> Bool {
        guard let html = pasteboardHTML()?.lowercased() else { return false }
        return html.contains("<img") ||
            html.contains("data:image/") ||
            html.contains("ac:image") ||
            html.contains("ri:attachment") ||
            html.contains("image/")
    }

    private func pasteboardHTML() -> String? {
        for item in pasteboard.pasteboardItems ?? [] {
            for type in item.types where type.rawValue.lowercased().contains("html") {
                guard let data = item.data(forType: type), !data.isEmpty else { continue }
                if let html = String(data: data, encoding: .utf8) {
                    return html
                }
                if let html = String(data: data, encoding: .utf16) {
                    return html
                }
            }
        }
        return nil
    }

    private func storeRichImagePreview(id: String, date: Date, dayURL: URL) -> String? {
        guard let html = pasteboardHTML() else { return nil }

        let previewData: Data?
        if let extracted = extractEmbeddedImageData(from: html) {
            previewData = extracted
        } else {
            previewData = renderRichImagePlaceholder(from: html)?.pngData()
        }

        guard let data = previewData else { return nil }
        let fileURL = dayURL.appendingPathComponent("\(fileFormatter.string(from: date))_rich_preview_\(id.prefix(8)).png")

        do {
            try FileManager.default.createDirectory(at: dayURL, withIntermediateDirectories: true)
            try SecureStorage.shared.writeEncrypted(data, to: fileURL)
            return fileURL.path
        } catch {
            DebugLog.shared.write("Rich image preview failed: \(error.localizedDescription)")
            return nil
        }
    }

    private func writeRichImagePreview(_ data: Data, for entry: ClipEntry) -> String? {
        let directory = entry.url.deletingLastPathComponent()
        let fileURL = directory.appendingPathComponent("\(fileFormatter.string(from: entry.createdAt))_rich_preview_\(entry.id.prefix(8)).png")

        do {
            try SecureStorage.shared.writeEncrypted(data, to: fileURL)
            return fileURL.path
        } catch {
            DebugLog.shared.write("Write rich preview failed: \(error.localizedDescription)")
            return nil
        }
    }

    private func archivedRichPreviewData(for entry: ClipEntry) -> Data? {
        guard let archivePath = entry.pasteboardArchivePath else { return nil }
        let archiveURL = URL(fileURLWithPath: archivePath, isDirectory: true)
        let manifestURL = archiveURL.appendingPathComponent("manifest.json")
        guard let manifestData = try? SecureStorage.shared.readData(from: manifestURL),
              let manifest = try? JSONDecoder().decode(PasteboardArchiveManifest.self, from: manifestData) else {
            return nil
        }

        let preferredImageTypes = [
            "public.png",
            "public.tiff",
            "public.jpeg",
            "public.heic",
            "com.compuserve.gif"
        ]

        for preferredType in preferredImageTypes {
            for item in manifest.items {
                for archivedType in item.types where archivedType.pasteboardType == preferredType {
                    let fileURL = archiveURL.appendingPathComponent(archivedType.fileName)
                    guard let data = try? SecureStorage.shared.readData(from: fileURL),
                          let normalized = normalizedImageData(data, type: archivedType.pasteboardType) else { continue }
                    return normalized
                }
            }
        }

        if let html = archivedString(from: manifest, archiveURL: archiveURL, containingType: "html") {
            if let embedded = extractEmbeddedImageData(from: html) {
                return embedded
            }
            return renderRichImagePlaceholder(from: html)?.pngData()
        }

        return nil
    }

    private func archivedString(
        from manifest: PasteboardArchiveManifest,
        archiveURL: URL,
        containingType typeFragment: String
    ) -> String? {
        for item in manifest.items {
            for archivedType in item.types where archivedType.pasteboardType.lowercased().contains(typeFragment) {
                let fileURL = archiveURL.appendingPathComponent(archivedType.fileName)
                guard let data = try? SecureStorage.shared.readData(from: fileURL) else { continue }
                if let string = String(data: data, encoding: .utf8) {
                    return string
                }
                if let string = String(data: data, encoding: .utf16) {
                    return string
                }
            }
        }

        return nil
    }

    private func extractEmbeddedImageData(from html: String) -> Data? {
        let pattern = #"data:image/(png|jpeg|jpg|gif|webp);base64,([A-Za-z0-9+/=]+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let nsRange = NSRange(html.startIndex..<html.endIndex, in: html)
        let matches = regex.matches(in: html, range: nsRange)

        for match in matches where match.numberOfRanges >= 3 {
            guard let base64Range = Range(match.range(at: 2), in: html),
                  let data = Data(base64Encoded: String(html[base64Range])),
                  let image = NSImage(data: data),
                  image.size.width > 8,
                  image.size.height > 8 else { continue }
            return image.pngData()
        }

        return nil
    }

    private func renderRichImagePlaceholder(from html: String) -> NSImage? {
        let width = 180
        let height = 180
        let size = NSSize(width: width, height: height)
        let image = NSImage(size: size)
        let dimensions = richImageDimensions(from: html)

        image.lockFocus()
        NSColor.controlBackgroundColor.setFill()
        NSRect(origin: .zero, size: size).fill()

        let rect = NSRect(x: 16, y: 16, width: width - 32, height: height - 32)
        NSColor.windowBackgroundColor.withAlphaComponent(0.92).setFill()
        let path = NSBezierPath(roundedRect: rect, xRadius: 14, yRadius: 14)
        path.fill()

        NSColor.separatorColor.setStroke()
        path.lineWidth = 1
        path.stroke()

        let symbol = NSImage(systemSymbolName: "photo", accessibilityDescription: nil)
        symbol?.draw(in: NSRect(x: 62, y: 82, width: 56, height: 56))

        let subtitleAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .medium),
            .foregroundColor: NSColor.secondaryLabelColor
        ]

        let subtitle = dimensions ?? "Rich"
        subtitle.draw(
            in: NSRect(x: 24, y: 44, width: width - 48, height: 20),
            withAttributes: subtitleAttributes
        )

        image.unlockFocus()
        return image
    }

    private func richImageDimensions(from html: String) -> String? {
        func value(for name: String) -> String? {
            let pattern = #"data-\#(name)="([^"]+)""#
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..<html.endIndex, in: html)),
                  let range = Range(match.range(at: 1), in: html) else { return nil }
            return String(html[range])
        }

        if let width = value(for: "width"), let height = value(for: "height") {
            return "\(width) x \(height)"
        }
        return nil
    }

    private func add(_ entry: ClipEntry) {
        entries.insert(entry, at: 0)
        applyFavoriteSyncRecords(saveIfChanged: false)
        saveIndex()
        lastStatus = "Gespeichert: \(entry.displayTitle)"
    }

    private func setCopiedStatus(for entry: ClipEntry) {
        lastStatus = "\(entry.displayTitle) \(statusDateFormatter.string(from: entry.createdAt)) - in Zwischenablage kopiert"
    }

    private func updateSignatureAfterCopying(_ entry: ClipEntry) {
        switch entry.kind {
        case .text:
            if let text = try? SecureStorage.shared.readString(from: entry.url) {
                lastSignature = pasteboardSignature(prefix: "text", fallbackData: Data(text.utf8))
            }
        case .image:
            if let data = try? SecureStorage.shared.readData(from: entry.url) {
                lastSignature = pasteboardSignature(prefix: "image", fallbackData: data)
            }
        }
    }

    private func archivePasteboardItems(id: String, date: Date, dayURL: URL) -> String? {
        guard let pasteboardItems = pasteboard.pasteboardItems, !pasteboardItems.isEmpty else {
            return nil
        }

        let archiveURL = dayURL.appendingPathComponent("\(fileFormatter.string(from: date))_pasteboard_\(id.prefix(8)).pasteboard", isDirectory: true)
        var archivedItems: [PasteboardArchiveManifest.ArchivedItem] = []

        do {
            try FileManager.default.createDirectory(at: archiveURL, withIntermediateDirectories: true)

            for (itemIndex, item) in pasteboardItems.enumerated() {
                var archivedTypes: [PasteboardArchiveManifest.ArchivedType] = []

                for (typeIndex, type) in item.types.enumerated() {
                    guard let data = item.data(forType: type), !data.isEmpty else { continue }
                    let fileName = safePasteboardFileName(itemIndex: itemIndex, typeIndex: typeIndex, type: type)
                    try SecureStorage.shared.writeEncrypted(data, to: archiveURL.appendingPathComponent(fileName))
                    archivedTypes.append(
                        PasteboardArchiveManifest.ArchivedType(
                            pasteboardType: type.rawValue,
                            fileName: fileName
                        )
                    )
                }

                if !archivedTypes.isEmpty {
                    archivedItems.append(PasteboardArchiveManifest.ArchivedItem(types: archivedTypes))
                }
            }

            guard !archivedItems.isEmpty else {
                try? FileManager.default.removeItem(at: archiveURL)
                return nil
            }

            let manifest = PasteboardArchiveManifest(items: archivedItems)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let manifestData = try encoder.encode(manifest)
            try SecureStorage.shared.writeEncrypted(manifestData, to: archiveURL.appendingPathComponent("manifest.json"))
            return archiveURL.path
        } catch {
            DebugLog.shared.write("Pasteboard archive failed: \(error.localizedDescription)")
            try? FileManager.default.removeItem(at: archiveURL)
            return nil
        }
    }

    private func restorePasteboardArchive(for entry: ClipEntry) -> Bool {
        guard let archivePath = entry.pasteboardArchivePath else { return false }

        let archiveURL = URL(fileURLWithPath: archivePath, isDirectory: true)
        let manifestURL = archiveURL.appendingPathComponent("manifest.json")
        guard let manifestData = try? SecureStorage.shared.readData(from: manifestURL),
              let manifest = try? JSONDecoder().decode(PasteboardArchiveManifest.self, from: manifestData) else {
            return false
        }

        var restoredItems: [NSPasteboardItem] = []

        for archivedItem in manifest.items {
            let item = NSPasteboardItem()
            var restoredTypeCount = 0

            for archivedType in archivedItem.types {
                let fileURL = archiveURL.appendingPathComponent(archivedType.fileName)
                guard let data = try? SecureStorage.shared.readData(from: fileURL) else { continue }
                let type = NSPasteboard.PasteboardType(archivedType.pasteboardType)
                if item.setData(data, forType: type) {
                    restoredTypeCount += 1
                }
            }

            if restoredTypeCount > 0 {
                restoredItems.append(item)
            }
        }

        guard !restoredItems.isEmpty else { return false }
        pasteboard.clearContents()
        let didWrite = pasteboard.writeObjects(restoredItems)
        DebugLog.shared.write("Restored pasteboard archive for \(entry.id): \(didWrite)")
        return didWrite
    }

    private func safePasteboardFileName(itemIndex: Int, typeIndex: Int, type: NSPasteboard.PasteboardType) -> String {
        let cleanedType = type.rawValue.replacingOccurrences(
            of: "[^A-Za-z0-9._-]+",
            with: "_",
            options: .regularExpression
        )
        let limitedType = String(cleanedType.prefix(80))
        return "item_\(itemIndex)_type_\(typeIndex)_\(limitedType).data"
    }

    private func pasteboardSignature(prefix: String, fallbackData: Data) -> String {
        guard let pasteboardItems = pasteboard.pasteboardItems, !pasteboardItems.isEmpty else {
            return "\(prefix):\(fnv1a(fallbackData))"
        }

        var parts: [String] = []
        for (itemIndex, item) in pasteboardItems.enumerated() {
            for type in item.types.sorted(by: { $0.rawValue < $1.rawValue }) {
                guard let data = item.data(forType: type), !data.isEmpty else { continue }
                parts.append("\(itemIndex):\(type.rawValue):\(fnv1a(data))")
            }
        }

        guard !parts.isEmpty else {
            return "\(prefix):\(fnv1a(fallbackData))"
        }
        return "\(prefix):\(parts.joined(separator: "|"))"
    }

    private func migrateExistingEntriesForSecurity() {
        var changedIndex = false

        for index in entries.indices {
            SecureStorage.shared.encryptFileIfNeeded(at: entries[index].url)

            if entries[index].kind == .text,
               let text = try? SecureStorage.shared.readString(from: entries[index].url) {
                if entries[index].preview == "Sensibler Eintrag" {
                    entries[index].preview = text.normalizedPreview(maxCharacters: 220)
                    entries[index].isSensitive = false
                    changedIndex = true
                } else if entries[index].isSensitive == nil {
                    entries[index].isSensitive = false
                    changedIndex = true
                } else if entries[index].isSensitive == true {
                    entries[index].isSensitive = false
                    changedIndex = true
                }
            } else if entries[index].isSensitive == nil {
                entries[index].isSensitive = false
                changedIndex = true
            }

            if let archivePath = entries[index].pasteboardArchivePath {
                encryptArchiveDirectory(at: URL(fileURLWithPath: archivePath, isDirectory: true))
            }
            if let richPreviewPath = entries[index].richPreviewPath {
                SecureStorage.shared.encryptFileIfNeeded(at: URL(fileURLWithPath: richPreviewPath))
            }

            if entries[index].displayLabel == "Bild",
               entries[index].kind == .text,
               let previewData = archivedRichPreviewData(for: entries[index]),
               let previewPath = writeRichImagePreview(previewData, for: entries[index]),
               entries[index].richPreviewPath != previewPath {
                entries[index].richPreviewPath = previewPath
                changedIndex = true
            }
        }

        if FileManager.default.fileExists(atPath: indexURL.path) {
            SecureStorage.shared.encryptFileIfNeeded(at: indexURL)
        }
        if changedIndex {
            saveIndex()
        }
    }

    private func encryptArchiveDirectory(at archiveURL: URL) {
        guard let enumerator = FileManager.default.enumerator(
            at: archiveURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        for case let fileURL as URL in enumerator {
            let isRegularFile = (try? fileURL.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
            guard isRegularFile else { continue }
            SecureStorage.shared.encryptFileIfNeeded(at: fileURL)
        }
    }

    private func dayFolder(for date: Date) -> URL {
        rootURL.appendingPathComponent(folderFormatter.string(from: date), isDirectory: true)
    }

    private func createFolders() {
        try? FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    }

    private func load() {
        guard let data = try? SecureStorage.shared.readData(from: indexURL) else { return }
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
        do {
            let data = try encoder.encode(entries)
            try SecureStorage.shared.writeEncrypted(data, to: indexURL)
            lastIndexModifiedAt = indexModificationDate()
        } catch {
            lastStatus = "Index konnte nicht gespeichert werden: \(error.localizedDescription)"
        }
    }

    private func refreshFromExternalIndexIfNeeded() {
        guard let modifiedAt = indexModificationDate() else { return }
        guard lastIndexModifiedAt != modifiedAt else { return }

        let oldEntries = entries
        load()
        publishCurrentFavoritesIfNeeded()
        applyFavoriteSyncRecords(saveIfChanged: false)
        lastIndexModifiedAt = modifiedAt

        if oldEntries != entries {
            onExternalReload?()
        }
    }

    private func refreshFavoritesFromSyncIfNeeded() {
        guard Date().timeIntervalSince(lastFavoriteSyncRefresh) >= 2 else { return }
        lastFavoriteSyncRefresh = Date()

        if applyFavoriteSyncRecords() {
            onExternalReload?()
        }
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

    private func favoriteSyncPayload() -> Data? {
        publishCurrentFavoritesIfNeeded()
        return favoriteSyncStore.encodedRecords()
    }

    private func archiveSyncPayload() -> Data? {
        load()
        let cutoff = Date().addingTimeInterval(-archiveSyncLookback)
        var totalBytes = 0
        var items: [ArchiveSyncItem] = []

        for entry in entries where entry.createdAt >= cutoff {
            guard items.count < archiveSyncMaxItems,
                  let data = try? SecureStorage.shared.readData(from: entry.url),
                  !data.isEmpty else { continue }

            let richPreviewData = entry.richPreviewURL.flatMap { try? SecureStorage.shared.readData(from: $0) }
            let itemBytes = data.count + (richPreviewData?.count ?? 0)
            guard totalBytes + itemBytes <= archiveSyncMaxBytes else { break }

            items.append(
                ArchiveSyncItem(
                    id: entry.id,
                    kind: entry.kind,
                    createdAt: entry.createdAt,
                    preview: entry.preview,
                    data: data,
                    isFavorite: entry.isFavorite,
                    displayKind: entry.displayKind,
                    richPreviewData: richPreviewData,
                    favoriteShortcut: entry.favoriteShortcut,
                    title: entry.title
                )
            )
            totalBytes += itemBytes
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try? encoder.encode(ArchiveSyncPayload(generatedAt: Date(), items: items))
    }

    private func mergeFavoriteSyncPayload(_ data: Data) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if self.favoriteSyncStore.mergeEncodedRecords(data), self.applyFavoriteSyncRecords() {
                self.onExternalReload?()
            }
        }
    }

    private func startFavoriteSyncServer() {
        favoriteSyncServer = FavoriteSyncServer(
            getPayload: { [weak self] in self?.favoriteSyncPayload() },
            mergePayload: { [weak self] data in self?.mergeFavoriteSyncPayload(data) },
            getArchivePayload: { [weak self] in self?.archiveSyncPayload() }
        )
        favoriteSyncServer?.start()
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
        guard let data = try? SecureStorage.shared.readData(from: entry.url) else { return [] }
        var signatures = [ClipContentSignature.signature(kind: entry.kind, data: data)]
        if entry.kind == .text,
           let text = String(data: data, encoding: .utf8),
           let normalizedSignature = ClipContentSignature.normalizedTextSignature(text) {
            signatures.append(normalizedSignature)
        }
        contentSignatureCache[entry.id] = signatures
        return signatures
    }

    private static func normalizedTitle(_ title: String?) -> String? {
        guard let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        return trimmed
    }

    private func indexModificationDate() -> Date? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: indexURL.path) else { return nil }
        return attributes[.modificationDate] as? Date
    }

    private func fnv1a(_ data: Data) -> UInt64 {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in data {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return hash
    }
}

final class HoldCommandCMonitor {
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var globalKeyDownMonitor: Any?
    private var globalKeyUpMonitor: Any?
    private var globalFlagsMonitor: Any?
    private var retryTimer: Timer?
    private var pollingTimer: Timer?
    private var cKeyDownAt: Date?
    private var holdTimer: Timer?
    private var didOpenForCurrentHold = false
    private let onHold: () -> Void
    private let onStatus: (String) -> Void
    private let onPermissionMissing: () -> Void

    init(onHold: @escaping () -> Void, onStatus: @escaping (String) -> Void, onPermissionMissing: @escaping () -> Void) {
        self.onHold = onHold
        self.onStatus = onStatus
        self.onPermissionMissing = onPermissionMissing
    }

    func start() {
        DebugLog.shared.write("HoldCommandCMonitor.start AXTrusted=\(AXIsProcessTrusted())")
        startPollingFallback()
        guard eventTap == nil else { return }

        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        guard AXIsProcessTrustedWithOptions(options) else {
            DebugLog.shared.write("AX permission missing")
            onPermissionMissing()
            schedulePermissionRetry()
            return
        }

        let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue) | (1 << CGEventType.flagsChanged.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let monitor = Unmanaged<HoldCommandCMonitor>.fromOpaque(refcon).takeUnretainedValue()
            monitor.handle(type: type, event: event)
            return Unmanaged.passUnretained(event)
        }

        eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        )

        guard let eventTap else {
            DebugLog.shared.write("CGEvent.tapCreate failed; installing NSEvent fallback")
            onPermissionMissing()
            installNSEventFallback()
            onStatus("Fallback-Tastaturmonitor aktiv")
            return
        }

        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
        if let runLoopSource {
            CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        CGEvent.tapEnable(tap: eventTap, enable: true)
        installNSEventFallback()
        retryTimer?.invalidate()
        retryTimer = nil
        DebugLog.shared.write("CGEvent tap active")
        onStatus("Tastaturmonitor aktiv, Hold-Polling läuft")
    }

    func stop() {
        holdTimer?.invalidate()
        holdTimer = nil
        retryTimer?.invalidate()
        retryTimer = nil
        pollingTimer?.invalidate()
        pollingTimer = nil
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        if let eventTap {
            CFMachPortInvalidate(eventTap)
        }
        if let globalKeyDownMonitor {
            NSEvent.removeMonitor(globalKeyDownMonitor)
        }
        if let globalKeyUpMonitor {
            NSEvent.removeMonitor(globalKeyUpMonitor)
        }
        if let globalFlagsMonitor {
            NSEvent.removeMonitor(globalFlagsMonitor)
        }
        eventTap = nil
        runLoopSource = nil
        globalKeyDownMonitor = nil
        globalKeyUpMonitor = nil
        globalFlagsMonitor = nil
    }

    private func handle(type: CGEventType, event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let eventTap {
                CGEvent.tapEnable(tap: eventTap, enable: true)
            }
            onStatus("Tastaturmonitor reaktiviert")
            return
        }

        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let isC = keyCode == 8
        let commandIsPressed = event.flags.contains(.maskCommand)

        if type == .keyDown, isC, commandIsPressed {
            DebugLog.shared.write("CGEvent Cmd+C keyDown")
            scheduleHoldOpen()
        }

        if type == .keyUp, isC {
            cancelHoldOpen()
        }

        if type == .flagsChanged, !commandIsPressed {
            cancelHoldOpen()
        }
    }

    private func installNSEventFallback() {
        guard globalKeyDownMonitor == nil else { return }

        globalKeyDownMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleNSEvent(type: .keyDown, event: event)
        }
        globalKeyUpMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyUp) { [weak self] event in
            self?.handleNSEvent(type: .keyUp, event: event)
        }
        globalFlagsMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handleNSEvent(type: .flagsChanged, event: event)
        }
    }

    private func handleNSEvent(type: NSEvent.EventType, event: NSEvent) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let isC = event.keyCode == 8
            let commandIsPressed = event.modifierFlags.contains(.command)

            if type == .keyDown, isC, commandIsPressed {
                DebugLog.shared.write("NSEvent Cmd+C keyDown")
                self.scheduleHoldOpen()
            }

            if type == .keyUp, isC {
                self.cancelHoldOpen()
            }

            if type == .flagsChanged, !commandIsPressed {
                self.cancelHoldOpen()
            }
        }
    }

    private func scheduleHoldOpen() {
        if cKeyDownAt == nil {
            cKeyDownAt = Date()
            holdTimer?.invalidate()
            holdTimer = Timer.scheduledTimer(withTimeInterval: 0.38, repeats: false) { [weak self] _ in
                guard let self, self.cKeyDownAt != nil else { return }
                self.openOnceForCurrentHold()
            }
        }
    }

    private func cancelHoldOpen() {
        cKeyDownAt = nil
        holdTimer?.invalidate()
        holdTimer = nil
        didOpenForCurrentHold = false
    }

    private func schedulePermissionRetry() {
        guard retryTimer == nil else { return }
        retryTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            if AXIsProcessTrusted() {
                self.start()
            }
        }
    }

    private func startPollingFallback() {
        guard pollingTimer == nil else { return }
        pollingTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            self?.pollKeyboardState()
        }
        RunLoop.main.add(pollingTimer!, forMode: .common)
    }

    private func pollKeyboardState() {
        let flags = CGEventSource.flagsState(.combinedSessionState)
        let commandIsPressed = flags.contains(.maskCommand)
        let cIsPressed = CGEventSource.keyState(.combinedSessionState, key: 8)

        if commandIsPressed && cIsPressed {
            if cKeyDownAt == nil {
                DebugLog.shared.write("Polling sees Cmd+C down")
            }
            scheduleHoldOpen()
        } else {
            cancelHoldOpen()
        }
    }

    private func openOnceForCurrentHold() {
        guard !didOpenForCurrentHold else { return }
        didOpenForCurrentHold = true
        DebugLog.shared.write("Opening history from Cmd+C hold")
        onStatus("Cmd+C gehalten erkannt")
        onHold()
    }
}

enum HistoryScope: String, CaseIterable, Identifiable {
    case all
    case favorites

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return "Alle"
        case .favorites: return "Favoriten"
        }
    }
}

final class AppLockController: ObservableObject {
    @Published private(set) var isUnlocked = false
    @Published private(set) var statusText = "Archiv gesperrt"

    private let timeout: TimeInterval = 10 * 60
    private var lastUnlockDate: Date?
    private var timer: Timer?
    private var isAuthenticating = false

    init() {
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            DispatchQueue.main.async {
                self?.lockIfExpired()
            }
        }
    }

    func authenticate(completion: ((Bool) -> Void)? = nil) {
        if isUnlocked, !hasExpired {
            completion?(true)
            return
        }
        guard !isAuthenticating else {
            completion?(false)
            return
        }

        isAuthenticating = true
        statusText = "Authentifizierung läuft..."

        let context = LAContext()
        context.localizedCancelTitle = "Abbrechen"
        let reason = "ClipboardArchiv entsperren"

        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            isAuthenticating = false
            statusText = "macOS-Authentifizierung ist nicht verfügbar"
            completion?(false)
            return
        }

        context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { [weak self] success, authError in
            DispatchQueue.main.async {
                guard let self else { return }
                self.isAuthenticating = false
                if success {
                    self.isUnlocked = true
                    self.lastUnlockDate = Date()
                    self.statusText = "Archiv entsperrt"
                    completion?(true)
                } else {
                    self.isUnlocked = false
                    self.statusText = authError?.localizedDescription ?? "Archiv gesperrt"
                    completion?(false)
                }
            }
        }
    }

    func markActivity() {
        if isUnlocked {
            lastUnlockDate = Date()
        }
    }

    func lock() {
        isUnlocked = false
        lastUnlockDate = nil
        statusText = "Archiv gesperrt"
    }

    func lockIfExpired() {
        if isUnlocked, hasExpired {
            lock()
        }
    }

    private var hasExpired: Bool {
        guard let lastUnlockDate else { return true }
        return Date().timeIntervalSince(lastUnlockDate) > timeout
    }
}

final class FavoriteShortcutManager {
    private struct Registration {
        let shortcut: String
        let entryID: String
        var hotKeyRef: EventHotKeyRef?
    }

    private var registrations: [UInt32: Registration] = [:]
    private var eventHandler: EventHandlerRef?
    private var nextID: UInt32 = 1
    private let onShortcut: (String) -> Void

    init(onShortcut: @escaping (String) -> Void) {
        self.onShortcut = onShortcut
        installHandler()
    }

    func refresh(entries: [ClipEntry]) {
        unregisterAll()

        let assignedEntries = entries.filter { $0.isFavorite == true && $0.favoriteShortcut != nil }
        for entry in assignedEntries {
            guard let shortcut = entry.favoriteShortcut,
                  let keyCode = Self.keyCode(for: shortcut) else { continue }
            register(shortcut: shortcut, entryID: entry.id, keyCode: keyCode)
        }
    }

    func stop() {
        unregisterAll()
        if let eventHandler {
            RemoveEventHandler(eventHandler)
        }
        eventHandler = nil
    }

    deinit {
        stop()
    }

    private func installHandler() {
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let selfPointer = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData in
                guard let userData, let event else { return noErr }
                let manager = Unmanaged<FavoriteShortcutManager>.fromOpaque(userData).takeUnretainedValue()
                var hotKeyID = EventHotKeyID()
                GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )
                manager.handle(hotKeyID.id)
                return noErr
            },
            1,
            &eventType,
            selfPointer,
            &eventHandler
        )
    }

    private func register(shortcut: String, entryID: String, keyCode: UInt32) {
        let id = nextID
        nextID += 1
        let hotKeyID = EventHotKeyID(signature: fourCharCode("CLPF"), id: id)
        var hotKeyRef: EventHotKeyRef?
        let status = RegisterEventHotKey(
            keyCode,
            UInt32(cmdKey),
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )

        guard status == noErr, let hotKeyRef else {
            DebugLog.shared.write("Favorite shortcut registration failed \(shortcut): \(status)")
            return
        }

        registrations[id] = Registration(shortcut: shortcut, entryID: entryID, hotKeyRef: hotKeyRef)
    }

    private func handle(_ id: UInt32) {
        guard let registration = registrations[id] else { return }
        onShortcut(registration.entryID)
    }

    private func unregisterAll() {
        for registration in registrations.values {
            if let hotKeyRef = registration.hotKeyRef {
                UnregisterEventHotKey(hotKeyRef)
            }
        }
        registrations.removeAll()
    }

    private func fourCharCode(_ string: String) -> OSType {
        var result: UInt32 = 0
        for scalar in string.unicodeScalars.prefix(4) {
            result = (result << 8) + scalar.value
        }
        return OSType(result)
    }

    static let availableShortcuts = (1...9).map { "⌘\($0)" }

    private static func keyCode(for shortcut: String) -> UInt32? {
        switch shortcut {
        case "⌘1": return UInt32(kVK_ANSI_1)
        case "⌘2": return UInt32(kVK_ANSI_2)
        case "⌘3": return UInt32(kVK_ANSI_3)
        case "⌘4": return UInt32(kVK_ANSI_4)
        case "⌘5": return UInt32(kVK_ANSI_5)
        case "⌘6": return UInt32(kVK_ANSI_6)
        case "⌘7": return UInt32(kVK_ANSI_7)
        case "⌘8": return UInt32(kVK_ANSI_8)
        case "⌘9": return UInt32(kVK_ANSI_9)
        default: return nil
        }
    }
}

struct HistoryView: View {
    @ObservedObject var store: ClipboardStore
    @ObservedObject var lock: AppLockController
    let onCopy: (ClipEntry) -> Void
    let onReveal: (ClipEntry) -> Void
    let onDelete: (ClipEntry) -> Void
    let onToggleFavorite: (ClipEntry) -> Void
    let onSetShortcut: (ClipEntry, String?) -> Void
    let onRename: (ClipEntry, String?) -> Void
    let onOpenFolder: () -> Void
    let onUnlock: () -> Void

    @State private var searchText = ""
    @State private var selectedScope: HistoryScope = .all
    @State private var renameTarget: ClipEntry?
    @State private var renameText = ""

    private var filteredEntries: [ClipEntry] {
        let scopedEntries: [ClipEntry]
        switch selectedScope {
        case .all:
            scopedEntries = store.entries
        case .favorites:
            scopedEntries = store.entries.filter { $0.isFavorite == true }
        }

        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return scopedEntries }
        return scopedEntries.filter { entry in
            entry.preview.lowercased().contains(query) ||
            entry.displayTitle.lowercased().contains(query) ||
            entry.displayLabel.lowercased().contains(query) ||
            entry.kind.rawValue.contains(query) ||
            Self.dateFormatter.string(from: entry.createdAt).lowercased().contains(query)
        }
    }

    var body: some View {
        Group {
            if lock.isUnlocked {
                unlockedBody
            } else {
                lockedBody
            }
        }
        .frame(minWidth: 660, minHeight: 500)
    }

    private var unlockedBody: some View {
        VStack(spacing: 0) {
                header
                Divider()
                ScrollViewReader { proxy in
                    if filteredEntries.isEmpty {
                        emptyState
                    } else {
                        List(filteredEntries) { entry in
                            ClipRow(
                                entry: entry,
                                onCopy: { onCopy(entry) },
                                onReveal: { onReveal(entry) },
                                onDelete: { onDelete(entry) },
                                onToggleFavorite: { onToggleFavorite(entry) },
                                onSetShortcut: { shortcut in onSetShortcut(entry, shortcut) },
                                onRename: { beginRename(entry) }
                            )
                            .id(entry.id)
                            .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
                        }
                        .listStyle(.inset)
                        .onChange(of: store.scrollToTopRequest) { _, _ in
                            scrollToTop(proxy)
                        }
                    }
                }
                Divider()
            footer
        }
        .sheet(item: $renameTarget) { entry in
            RenameEntrySheet(
                title: $renameText,
                entry: entry,
                onCancel: { renameTarget = nil },
                onSave: {
                    onRename(entry, renameText)
                    renameTarget = nil
                }
            )
        }
    }

    private var lockedBody: some View {
        VStack(spacing: 16) {
            Image(systemName: "lock.fill")
                .font(.system(size: 44, weight: .medium))
                .foregroundStyle(.secondary)
            Text("ClipboardArchiv ist gesperrt")
                .font(.system(size: 18, weight: .semibold))
            Text(lock.statusText)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            Button(action: onUnlock) {
                Label("Entsperren", systemImage: "lock.open")
            }
            .controlSize(.large)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Picker("", selection: $selectedScope) {
                ForEach(HistoryScope.allCases) { scope in
                    Text(scope.title).tag(scope)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 180)
            Spacer()
            TextField("Suchen", text: $searchText)
                .textFieldStyle(.roundedBorder)
                .frame(width: 220)
            Button(action: onOpenFolder) {
                Label("Ordner", systemImage: "folder")
            }
        }
        .padding(16)
    }

    private func scrollToTop(_ proxy: ScrollViewProxy) {
        guard let firstEntry = filteredEntries.first else { return }
        DispatchQueue.main.async {
            withAnimation(.easeOut(duration: 0.12)) {
                proxy.scrollTo(firstEntry.id, anchor: .top)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "doc.on.clipboard")
                .font(.system(size: 42))
                .foregroundStyle(.secondary)
            Text(emptyStateText)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyStateText: String {
        if !searchText.isEmpty {
            return "Keine Treffer"
        }
        return selectedScope == .favorites ? "Noch keine Favoriten" : "Noch keine Zwischenablagen gespeichert"
    }

    private var footer: some View {
        HStack {
            Text(store.lastStatus)
                .lineLimit(1)
                .foregroundStyle(.secondary)
            Spacer()
            Text(ArchiveLocation.displayPath)
                .foregroundStyle(.secondary)
        }
        .font(.system(size: 12))
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "de_DE")
        formatter.dateFormat = "dd.MM.yyyy HH:mm:ss"
        return formatter
    }()

    private func beginRename(_ entry: ClipEntry) {
        renameText = entry.title ?? ""
        renameTarget = entry
    }
}

struct RenameEntrySheet: View {
    @Binding var title: String
    let entry: ClipEntry
    let onCancel: () -> Void
    let onSave: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Name bearbeiten")
                .font(.headline)
            Text(entry.preview)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            TextField(entry.displayLabel, text: $title)
                .textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("Abbrechen", action: onCancel)
                Button("Speichern", action: onSave)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 360)
    }
}

struct ClipRow: View {
    let entry: ClipEntry
    let onCopy: () -> Void
    let onReveal: () -> Void
    let onDelete: () -> Void
    let onToggleFavorite: () -> Void
    let onSetShortcut: (String?) -> Void
    let onRename: () -> Void

    private var richDragProvider: NSItemProvider {
        let provider = NSItemProvider()
        if let html = archivedString(containingType: "html") {
            provider.registerDataRepresentation(
                forTypeIdentifier: "public.html",
                visibility: .all
            ) { completion in
                completion(Data(html.utf8), nil)
                return nil
            }
        }
        if let plainText = archivedString(containingType: "plain-text") ?? archivedString(containingType: "utf8") {
            provider.registerDataRepresentation(
                forTypeIdentifier: "public.utf8-plain-text",
                visibility: .all
            ) { completion in
                completion(Data(plainText.utf8), nil)
                return nil
            }
        }
        return provider
    }

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 12) {
                thumbnail
                    .frame(width: 54, height: 54)
                    .background(Color(nsColor: .controlBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 8))

                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 8) {
                        Label(entry.displayTitle, systemImage: entry.displaySystemImage)
                            .font(.system(size: 12, weight: .semibold))
                        Text(HistoryView.dateFormatter.string(from: entry.createdAt))
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }

                    Text(entry.preview)
                        .font(.system(size: 13))
                        .lineLimit(2)
                        .foregroundStyle(.primary)
                }

                Spacer(minLength: 8)
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: onCopy)

            HStack(spacing: 6) {
                Button(action: onToggleFavorite) {
                    Image(systemName: entry.isFavorite == true ? "star.fill" : "star")
                        .foregroundStyle(entry.isFavorite == true ? Color.yellow : Color(nsColor: .secondaryLabelColor))
                }
                .help(entry.isFavorite == true ? "Aus Favoriten entfernen" : "Zu Favoriten hinzufügen")

                if entry.isFavorite == true {
                    Menu {
                        ForEach(FavoriteShortcutManager.availableShortcuts, id: \.self) { shortcut in
                            Button(shortcut) {
                                onSetShortcut(shortcut)
                            }
                        }
                        if entry.favoriteShortcut != nil {
                            Divider()
                            Button("Shortcut entfernen") {
                                onSetShortcut(nil)
                            }
                        }
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "keyboard")
                            if let shortcut = entry.favoriteShortcut {
                                Text(shortcut)
                                    .font(.system(size: 10, weight: .semibold))
                            }
                        }
                    }
                    .menuStyle(.borderlessButton)
                    .help(entry.favoriteShortcut.map { "Shortcut \($0) ändern" } ?? "Shortcut zuweisen")
                }

                Button(action: onCopy) {
                    Image(systemName: "doc.on.doc")
                }
                .help("Kopieren")

                Button(action: onRename) {
                    Image(systemName: "pencil")
                }
                .help("Name bearbeiten")

                Button(action: onReveal) {
                    Image(systemName: "magnifyingglass")
                }
                .help("Im Finder zeigen")

                Button(role: .destructive, action: onDelete) {
                    Image(systemName: "trash")
                }
                .help("Löschen")
            }
            .buttonStyle(.borderless)
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var thumbnail: some View {
        if let richPreviewURL = entry.richPreviewURL,
           let data = try? SecureStorage.shared.readData(from: richPreviewURL),
           let image = NSImage(data: data) {
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
                .onDrag {
                    let provider = richDragProvider
                    if let tempURL = SecureStorage.shared.temporaryURL(
                        data: data,
                        fileName: "\(entry.id)_rich_preview.png"
                    ) {
                        provider.registerFileRepresentation(
                            forTypeIdentifier: "public.png",
                            fileOptions: [],
                            visibility: .all,
                            loadHandler: { completion in
                                completion(tempURL, true, nil)
                                return nil
                            }
                        )
                    }
                    return provider
                }
        } else if entry.kind == .image,
           let data = try? SecureStorage.shared.readData(from: entry.url),
           let image = NSImage(data: data) {
            Image(nsImage: image)
                .resizable()
                .scaledToFill()
                .onDrag {
                    if let tempURL = SecureStorage.shared.decryptedTemporaryURL(for: entry) {
                        return NSItemProvider(contentsOf: tempURL) ?? NSItemProvider()
                    }
                    return NSItemProvider()
                }
        } else {
            Image(systemName: entry.displaySystemImage)
                .font(.system(size: 24))
                .foregroundStyle(.secondary)
        }
    }

    private func archivedString(containingType typeFragment: String) -> String? {
        guard let archivePath = entry.pasteboardArchivePath else { return nil }
        let archiveURL = URL(fileURLWithPath: archivePath, isDirectory: true)
        let manifestURL = archiveURL.appendingPathComponent("manifest.json")
        guard let manifestData = try? SecureStorage.shared.readData(from: manifestURL),
              let manifest = try? JSONDecoder().decode(PasteboardArchiveManifest.self, from: manifestData) else {
            return nil
        }

        for item in manifest.items {
            for archivedType in item.types where archivedType.pasteboardType.lowercased().contains(typeFragment) {
                let fileURL = archiveURL.appendingPathComponent(archivedType.fileName)
                guard let data = try? SecureStorage.shared.readData(from: fileURL) else { continue }
                if let string = String(data: data, encoding: .utf8) {
                    return string
                }
                if let string = String(data: data, encoding: .utf16) {
                    return string
                }
            }
        }

        return nil
    }
}

final class FloatingHistoryPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.titled, .closable, .resizable, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isFloatingPanel = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        level = .normal
        collectionBehavior = []
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store = ClipboardStore()
    private let lockController = AppLockController()
    private var window: FloatingHistoryPanel?
    private var statusItem: NSStatusItem?
    private var hotKeyMonitor: HoldCommandCMonitor?
    private var favoriteShortcutManager: FavoriteShortcutManager?
    private var outsideClickMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        DebugLog.shared.write("App launched")
        SecureStorage.shared.cleanupTemporaryFiles()
        NSApp.setActivationPolicy(.accessory)
        configureMenu()
        configureWindow()
        store.onExternalReload = { [weak self] in
            self?.refreshFavoriteShortcuts()
        }
        store.startMonitoring()

        hotKeyMonitor = HoldCommandCMonitor(
            onHold: { [weak self] in
                DispatchQueue.main.async {
                    self?.showHistory()
                }
            },
            onStatus: { [weak self] message in
                DispatchQueue.main.async {
                    self?.store.lastStatus = message
                }
            },
            onPermissionMissing: { [weak self] in
                DispatchQueue.main.async {
                    self?.store.lastStatus = "Bedienungshilfen erlauben, damit Cmd+C halten funktioniert"
                }
            }
        )
        hotKeyMonitor?.start()

        favoriteShortcutManager = FavoriteShortcutManager { [weak self] entryID in
            DispatchQueue.main.async {
                self?.pasteFavoriteShortcut(entryID: entryID)
            }
        }
        refreshFavoriteShortcuts()
    }

    func applicationWillTerminate(_ notification: Notification) {
        DebugLog.shared.write("App terminating")
        removeOutsideClickMonitor()
        favoriteShortcutManager?.stop()
        hotKeyMonitor?.stop()
        store.stopMonitoring()
    }

    private func configureWindow() {
        let view = HistoryView(
            store: store,
            lock: lockController,
            onCopy: { [weak self] entry in
                self?.lockController.markActivity()
                self?.store.copyToPasteboard(entry)
            },
            onReveal: { [weak self] entry in
                self?.lockController.markActivity()
                self?.store.reveal(entry)
            },
            onDelete: { [weak self] entry in
                self?.lockController.markActivity()
                self?.store.delete(entry)
            },
            onToggleFavorite: { [weak self] entry in
                self?.lockController.markActivity()
                self?.store.toggleFavorite(entry)
                self?.refreshFavoriteShortcuts()
            },
            onSetShortcut: { [weak self] entry, shortcut in
                self?.lockController.markActivity()
                self?.store.setFavoriteShortcut(shortcut, for: entry)
                self?.refreshFavoriteShortcuts()
            },
            onRename: { [weak self] entry, title in
                self?.lockController.markActivity()
                self?.store.setTitle(title, for: entry)
            },
            onOpenFolder: { [weak self] in
                self?.lockController.markActivity()
                self?.store.openArchiveFolder()
            },
            onUnlock: { [weak self] in
                self?.lockController.authenticate()
            }
        )

        let window = FloatingHistoryPanel(contentRect: NSRect(x: 0, y: 0, width: 720, height: 560))
        centerWindowOnCurrentScreen(window)
        window.title = "ClipboardArchiv"
        window.contentView = NSHostingView(rootView: view)
        self.window = window
    }

    private func configureMenu() {
        let mainMenu = NSMenu()
        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(NSMenuItem(title: "Historie anzeigen", action: #selector(showHistoryFromMenu), keyEquivalent: "h"))
        appMenu.addItem(NSMenuItem(title: "Archivordner öffnen", action: #selector(openFolderFromMenu), keyEquivalent: "o"))
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(NSMenuItem(title: "Archiv sperren", action: #selector(lockArchiveFromMenu), keyEquivalent: "l"))
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(NSMenuItem(title: "Bedienungshilfen öffnen", action: #selector(openAccessibilitySettings), keyEquivalent: ""))
        appMenu.addItem(NSMenuItem(title: "Eingabeüberwachung öffnen", action: #selector(openInputMonitoringSettings), keyEquivalent: ""))
        appMenu.addItem(NSMenuItem(title: "Diagnose-Log öffnen", action: #selector(openLogFromMenu), keyEquivalent: ""))
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(NSMenuItem(title: "ClipboardArchiv beenden", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)
        NSApp.mainMenu = mainMenu

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem?.button?.image = NSImage(systemSymbolName: "doc.on.clipboard", accessibilityDescription: "ClipboardArchiv")

        let statusMenu = NSMenu()
        statusMenu.addItem(NSMenuItem(title: "Historie anzeigen", action: #selector(showHistoryFromMenu), keyEquivalent: ""))
        statusMenu.addItem(NSMenuItem(title: "Archivordner öffnen", action: #selector(openFolderFromMenu), keyEquivalent: ""))
        statusMenu.addItem(NSMenuItem.separator())
        statusMenu.addItem(NSMenuItem(title: "Archiv sperren", action: #selector(lockArchiveFromMenu), keyEquivalent: ""))
        statusMenu.addItem(NSMenuItem.separator())
        statusMenu.addItem(NSMenuItem(title: "Bedienungshilfen öffnen", action: #selector(openAccessibilitySettings), keyEquivalent: ""))
        statusMenu.addItem(NSMenuItem(title: "Eingabeüberwachung öffnen", action: #selector(openInputMonitoringSettings), keyEquivalent: ""))
        statusMenu.addItem(NSMenuItem(title: "Diagnose-Log öffnen", action: #selector(openLogFromMenu), keyEquivalent: ""))
        statusMenu.addItem(NSMenuItem.separator())
        statusMenu.addItem(NSMenuItem(title: "Beenden", action: #selector(NSApplication.terminate(_:)), keyEquivalent: ""))
        statusItem?.menu = statusMenu
    }

    private func showHistory() {
        DebugLog.shared.write("showHistory called")
        lockController.lockIfExpired()
        guard let window else { return }
        if !window.isVisible {
            centerWindowOnCurrentScreen(window)
        }
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary, .transient, .ignoresCycle]
        window.level = .statusBar
        window.orderFrontRegardless()
        window.makeKeyAndOrderFront(nil)
        DispatchQueue.main.async { [store] in
            store.requestScrollToTop()
        }
        if !lockController.isUnlocked {
            lockController.authenticate()
        } else {
            lockController.markActivity()
        }
        installOutsideClickMonitor()
    }

    private func refreshFavoriteShortcuts() {
        favoriteShortcutManager?.refresh(entries: store.entries)
    }

    private func pasteFavoriteShortcut(entryID: String) {
        lockController.lockIfExpired()
        guard lockController.isUnlocked else {
            showHistory()
            store.lastStatus = "Archiv entsperren, um Shortcut zu nutzen"
            return
        }

        guard let entry = store.entry(withID: entryID), entry.isFavorite == true else {
            refreshFavoriteShortcuts()
            return
        }

        lockController.markActivity()
        store.copyToPasteboard(entry)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            self.sendPasteCommand()
        }
    }

    private func sendPasteCommand() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let vKey: CGKeyCode = 9

        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: true)
        keyDown?.flags = .maskCommand
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: false)
        keyUp?.flags = .maskCommand

        keyDown?.post(tap: .cgAnnotatedSessionEventTap)
        keyUp?.post(tap: .cgAnnotatedSessionEventTap)
    }

    private func sendHistoryBehind() {
        guard let window, window.isVisible else { return }
        window.level = .normal
        window.collectionBehavior = []
        window.orderBack(nil)
        removeOutsideClickMonitor()
    }

    private func installOutsideClickMonitor() {
        guard outsideClickMonitor == nil else { return }
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
            DispatchQueue.main.async {
                self?.handleGlobalMouseDown(at: event.locationInWindow)
            }
        }
    }

    private func removeOutsideClickMonitor() {
        if let outsideClickMonitor {
            NSEvent.removeMonitor(outsideClickMonitor)
        }
        outsideClickMonitor = nil
    }

    private func handleGlobalMouseDown(at _: NSPoint) {
        guard let window, window.isVisible else {
            removeOutsideClickMonitor()
            return
        }

        let mouseLocation = NSEvent.mouseLocation
        if !window.frame.contains(mouseLocation) {
            sendHistoryBehind()
        }
    }

    private func centerWindowOnCurrentScreen(_ window: NSWindow) {
        let mouseLocation = NSEvent.mouseLocation
        let targetScreen = NSScreen.screens.first { screen in
            screen.frame.contains(mouseLocation)
        } ?? NSScreen.main

        guard let visibleFrame = targetScreen?.visibleFrame else {
            window.center()
            return
        }

        let size = window.frame.size
        let origin = NSPoint(
            x: visibleFrame.midX - size.width / 2,
            y: visibleFrame.midY - size.height / 2
        )
        window.setFrameOrigin(origin)
    }

    @objc private func showHistoryFromMenu() {
        showHistory()
    }

    @objc private func openFolderFromMenu() {
        store.openArchiveFolder()
    }

    @objc private func lockArchiveFromMenu() {
        lockController.lock()
    }

    @objc private func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func openInputMonitoringSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func openLogFromMenu() {
        DebugLog.shared.open()
    }
}

extension NSImage {
    func pngData() -> Data? {
        guard let tiff = tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff) else {
            return nil
        }
        return bitmap.representation(using: .png, properties: [:])
    }
}

extension String {
    func normalizedPreview(maxCharacters: Int) -> String {
        let collapsed = replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if collapsed.count <= maxCharacters {
            return collapsed
        }
        let end = collapsed.index(collapsed.startIndex, offsetBy: maxCharacters)
        return String(collapsed[..<end]) + "..."
    }
}

@main
struct ClipboardArchivMain {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}
