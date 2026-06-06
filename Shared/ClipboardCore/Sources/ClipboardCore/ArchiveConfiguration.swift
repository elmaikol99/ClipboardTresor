import Foundation

public struct ArchiveConfiguration: Sendable {
    public let bundleIdentifier: String
    public let archiveFolderName: String
    public let appGroupIdentifier: String?
    public let parentPathDefaultsKey: String

    public init(
        bundleIdentifier: String = "local.clipboardtresor.app",
        archiveFolderName: String = "ClipboardTresor",
        appGroupIdentifier: String? = nil,
        parentPathDefaultsKey: String = "ArchiveParentPath"
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.archiveFolderName = archiveFolderName
        self.appGroupIdentifier = appGroupIdentifier
        self.parentPathDefaultsKey = parentPathDefaultsKey
    }

    public var rootURL: URL {
        archiveParentURL().appendingPathComponent(archiveFolderName, isDirectory: true)
    }

    public var displayPath: String {
        Self.abbreviatedPath(rootURL.path)
    }

    private func archiveParentURL() -> URL {
        if let configuredPath = UserDefaults.standard.string(forKey: parentPathDefaultsKey),
           !configuredPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return URL(fileURLWithPath: (configuredPath as NSString).expandingTildeInPath, isDirectory: true)
        }

        #if os(iOS)
        if let appGroupIdentifier,
           let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier) {
            return container
        }
        #endif

        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        return documents ?? FileManager.default.temporaryDirectory
    }

    private static func abbreviatedPath(_ path: String) -> String {
        #if os(macOS)
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path == home {
            return "~"
        }
        if path.hasPrefix(home + "/") {
            return "~" + path.dropFirst(home.count)
        }
        #endif
        return path
    }
}
