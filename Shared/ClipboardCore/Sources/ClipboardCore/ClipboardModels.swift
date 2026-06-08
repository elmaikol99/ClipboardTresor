import Foundation

public enum ClipKind: String, Codable, Sendable {
    case text
    case image
}

public struct ClipEntry: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public let kind: ClipKind
    public let createdAt: Date
    public let filePath: String
    public var preview: String
    public let byteCount: Int
    public let pasteboardArchivePath: String?
    public var isFavorite: Bool?
    public var isSensitive: Bool?
    public var displayKind: String?
    public var richPreviewPath: String?
    public var favoriteShortcut: String?
    public var title: String?

    public init(
        id: String,
        kind: ClipKind,
        createdAt: Date,
        filePath: String,
        preview: String,
        byteCount: Int,
        pasteboardArchivePath: String?,
        isFavorite: Bool? = false,
        isSensitive: Bool? = false,
        displayKind: String? = nil,
        richPreviewPath: String? = nil,
        favoriteShortcut: String? = nil,
        title: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.createdAt = createdAt
        self.filePath = filePath
        self.preview = preview
        self.byteCount = byteCount
        self.pasteboardArchivePath = pasteboardArchivePath
        self.isFavorite = isFavorite
        self.isSensitive = isSensitive
        self.displayKind = displayKind
        self.richPreviewPath = richPreviewPath
        self.favoriteShortcut = favoriteShortcut
        self.title = title
    }

    public var url: URL {
        URL(fileURLWithPath: filePath)
    }

    public var displayLabel: String {
        displayKind ?? (kind == .text ? "Text" : "Bild")
    }

    public var displayTitle: String {
        if let trimmedTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines),
           !trimmedTitle.isEmpty {
            return trimmedTitle
        }
        return displayLabel
    }

    public var richPreviewURL: URL? {
        guard let richPreviewPath else { return nil }
        return URL(fileURLWithPath: richPreviewPath)
    }
}

public struct PasteboardArchiveManifest: Codable, Sendable {
    public struct ArchivedType: Codable, Sendable {
        public let pasteboardType: String
        public let fileName: String

        public init(pasteboardType: String, fileName: String) {
            self.pasteboardType = pasteboardType
            self.fileName = fileName
        }
    }

    public struct ArchivedItem: Codable, Sendable {
        public let types: [ArchivedType]

        public init(types: [ArchivedType]) {
            self.types = types
        }
    }

    public let items: [ArchivedItem]

    public init(items: [ArchivedItem]) {
        self.items = items
    }
}

public extension String {
    func normalizedPreview(maxCharacters: Int) -> String {
        let collapsed = replacingOccurrences(
            of: "\\s+",
            with: " ",
            options: .regularExpression
        )
        .trimmingCharacters(in: .whitespacesAndNewlines)

        guard collapsed.count > maxCharacters else { return collapsed }
        return String(collapsed.prefix(maxCharacters)) + "..."
    }
}
