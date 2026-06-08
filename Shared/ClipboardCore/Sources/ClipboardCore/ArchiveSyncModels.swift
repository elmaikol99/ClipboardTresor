import Foundation

public struct ArchiveSyncItem: Codable, Equatable, Sendable {
    public let id: String
    public let kind: ClipKind
    public let createdAt: Date
    public let preview: String
    public let data: Data
    public let isFavorite: Bool?
    public let displayKind: String?
    public let richPreviewData: Data?
    public let favoriteShortcut: String?
    public let title: String?

    public init(
        id: String,
        kind: ClipKind,
        createdAt: Date,
        preview: String,
        data: Data,
        isFavorite: Bool?,
        displayKind: String?,
        richPreviewData: Data?,
        favoriteShortcut: String?,
        title: String?
    ) {
        self.id = id
        self.kind = kind
        self.createdAt = createdAt
        self.preview = preview
        self.data = data
        self.isFavorite = isFavorite
        self.displayKind = displayKind
        self.richPreviewData = richPreviewData
        self.favoriteShortcut = favoriteShortcut
        self.title = title
    }
}

public struct ArchiveSyncPayload: Codable, Equatable, Sendable {
    public let generatedAt: Date
    public let items: [ArchiveSyncItem]

    public init(generatedAt: Date = Date(), items: [ArchiveSyncItem]) {
        self.generatedAt = generatedAt
        self.items = items
    }
}
