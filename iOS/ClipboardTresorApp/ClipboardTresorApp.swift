import ClipboardCore
import LocalAuthentication
import Network
import SwiftUI
import UIKit
import UniformTypeIdentifiers

private let appGroupIdentifier = "group.local.clipboardtresor"
private let keychainAccessGroup = "H9YGR79DYW.local.clipboardtresor.shared"

@main
struct ClipboardTresorApp: App {
    var body: some Scene {
        WindowGroup {
            ArchiveListView(
                viewModel: ArchiveListViewModel(
                    repository: ClipboardArchiveRepository(
                        configuration: ArchiveConfiguration(
                            appGroupIdentifier: appGroupIdentifier,
                            keychainAccessGroup: keychainAccessGroup,
                            prefersLegacyKeychainKey: true
                        )
                    )
                )
            )
            .preferredColorScheme(.dark)
        }
    }
}

@MainActor
final class ArchiveListViewModel: ObservableObject {
    @Published private(set) var entries: [ClipEntry]
    @Published var selectedScope: HistoryScope = .all
    @Published var searchText = ""
    @Published var statusText = "Bereit"
    @Published var isUnlocked = false

    private let repository: ClipboardArchiveRepository
    private let favoriteLANSync: FavoriteLANSyncClient
    private var lastSeenPasteboardChangeCount: Int?
    private var lastImportedSignature: String?

    init(repository: ClipboardArchiveRepository) {
        self.repository = repository
        self.favoriteLANSync = FavoriteLANSyncClient(repository: repository)
        entries = repository.entries
        favoriteLANSync.onMerged = { [weak self] in
            Task { @MainActor in
                self?.refreshFromArchive()
            }
        }
        favoriteLANSync.start()
    }

    var filteredEntries: [ClipEntry] {
        let scoped = selectedScope == .favorites ? entries.filter { $0.isFavorite == true } : entries
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return scoped }
        return scoped.filter {
            $0.preview.lowercased().contains(query) ||
            $0.displayLabel.lowercased().contains(query)
        }
    }

    func authenticate() {
        let context = LAContext()
        let reason = "ClipboardTresor entsperren"
        context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { [weak self] success, error in
            DispatchQueue.main.async {
                self?.isUnlocked = success
                self?.statusText = success ? "Archiv entsperrt" : (error?.localizedDescription ?? "Archiv gesperrt")
                if success {
                    self?.refreshFromArchive()
                    self?.importCurrentClipboardIfChanged()
                }
            }
        }
    }

    func refreshFromArchive() {
        guard isUnlocked else { return }
        favoriteLANSync.syncOnce()
        let reloaded = repository.reload()
        if reloaded != entries {
            entries = reloaded
        }
    }

    func importCurrentClipboardIfChanged() {
        guard isUnlocked else { return }
        let pasteboard = UIPasteboard.general
        let changeCount = pasteboard.changeCount
        guard lastSeenPasteboardChangeCount != changeCount else { return }
        lastSeenPasteboardChangeCount = changeCount
        importCurrentClipboard(manual: false)
    }

    func importCurrentClipboard(manual: Bool = true) {
        if UIPasteboard.general.hasImages, let image = UIPasteboard.general.image, let data = image.pngData() {
            let signature = "image:\(fnv1a(data))"
            guard shouldImport(signature: signature, data: data, kind: .image) else {
                if manual {
                    statusText = "Bild ist bereits gespeichert"
                }
                return
            }
            do {
                try repository.addImageData(data)
                lastImportedSignature = signature
                refresh(status: "Bild gespeichert")
            } catch {
                statusText = "Bild konnte nicht gespeichert werden"
            }
            return
        }

        if UIPasteboard.general.hasStrings, let text = UIPasteboard.general.string, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let data = Data(text.utf8)
            let signature = "text:\(fnv1a(data))"
            guard shouldImport(signature: signature, data: data, kind: .text) else {
                if manual {
                    statusText = "Text ist bereits gespeichert"
                }
                return
            }
            do {
                try repository.addText(text)
                lastImportedSignature = signature
                refresh(status: "Text gespeichert")
            } catch {
                statusText = "Text konnte nicht gespeichert werden"
            }
            return
        }

        if manual {
            statusText = "Keine passende Zwischenablage gefunden"
        }
    }

    func copy(_ entry: ClipEntry) {
        do {
            switch entry.kind {
            case .text:
                UIPasteboard.general.string = try repository.string(for: entry)
            case .image:
                if let image = UIImage(data: try repository.data(for: entry)) {
                    UIPasteboard.general.image = image
                }
            }
            statusText = "\(entry.displayLabel) kopiert"
        } catch {
            statusText = "Eintrag konnte nicht kopiert werden"
        }
    }

    func toggleFavorite(_ entry: ClipEntry) {
        try? repository.toggleFavorite(entry)
        favoriteLANSync.syncOnce()
        refresh(status: entry.isFavorite == true ? "Aus Favoriten entfernt" : "Zu Favoriten hinzugefügt")
    }

    func delete(_ entry: ClipEntry) {
        repository.delete(entry)
        refresh(status: "Eintrag gelöscht")
    }

    private func refresh(status: String) {
        entries = repository.reload()
        statusText = status
    }

    private func shouldImport(signature: String, data: Data, kind: ClipKind) -> Bool {
        guard signature != lastImportedSignature else { return false }
        for entry in entries.prefix(12) where entry.kind == kind {
            guard entry.byteCount == data.count,
                  let existingData = try? repository.data(for: entry),
                  existingData == data else { continue }
            lastImportedSignature = signature
            return false
        }
        return true
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

final class FavoriteLANSyncClient: @unchecked Sendable {
    var onMerged: (() -> Void)?

    private let repository: ClipboardArchiveRepository
    private let queue = DispatchQueue(label: "ClipboardTresor.FavoriteLANSyncClient")
    private var browser: NWBrowser?
    private var endpoint: NWEndpoint?
    private var isSyncing = false

    init(repository: ClipboardArchiveRepository) {
        self.repository = repository
    }

    func start() {
        let browser = NWBrowser(for: .bonjour(type: "_clipboardtresor._tcp", domain: nil), using: .tcp)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            guard let client = self else { return }
            client.queue.async {
                client.endpoint = results.first?.endpoint
            }
        }
        browser.start(queue: queue)
        self.browser = browser
    }

    func syncOnce() {
        guard let payload = repository.favoriteSyncPayload() else { return }

        queue.async { [weak self] in
            guard let self, !self.isSyncing, let endpoint = self.endpoint else { return }
            self.isSyncing = true
            self.sync(payload: payload, endpoint: endpoint)
        }
    }

    private func sync(payload: Data, endpoint: NWEndpoint) {
        let connection = NWConnection(to: endpoint, using: .tcp)
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self, let connection else { return }
            if case .ready = state {
                self.send(payload: payload, on: connection)
            } else if case .failed = state {
                self.finish(connection)
            }
        }
        connection.start(queue: queue)
    }

    private func send(payload: Data, on connection: NWConnection) {
        let header = [
            "POST /favorites HTTP/1.1",
            "Host: ClipboardTresor.local",
            "Content-Type: application/json",
            "Content-Length: \(payload.count)",
            "Connection: close",
            "",
            ""
        ].joined(separator: "\r\n")
        var request = Data(header.utf8)
        request.append(payload)
        connection.send(content: request, completion: .contentProcessed { [weak self, weak connection] error in
            guard let self, let connection else { return }
            if error != nil {
                self.finish(connection)
                return
            }
            self.receive(on: connection, buffer: Data())
        })
    }

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, _ in
            guard let self else { return }
            var response = buffer
            if let data {
                response.append(data)
            }

            if self.isCompleteResponse(response) || isComplete {
                if let body = self.responseBody(from: response), !body.isEmpty {
                    DispatchQueue.main.async { [weak self] in
                        if self?.repository.mergeFavoriteSyncPayload(body) == true {
                            self?.onMerged?()
                        }
                    }
                }
                self.finish(connection)
            } else {
                self.receive(on: connection, buffer: response)
            }
        }
    }

    private func finish(_ connection: NWConnection) {
        connection.cancel()
        isSyncing = false
    }

    private func isCompleteResponse(_ data: Data) -> Bool {
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

    private func responseBody(from data: Data) -> Data? {
        guard let headerEnd = headerEndRange(in: data) else { return nil }
        return data.suffix(from: headerEnd.upperBound)
    }

    private func headerEndRange(in data: Data) -> Range<Data.Index>? {
        let marker = Data("\r\n\r\n".utf8)
        return data.range(of: marker)
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

struct ArchiveListView: View {
    @ObservedObject var viewModel: ArchiveListViewModel
    @Environment(\.scenePhase) private var scenePhase
    private let archiveRefreshTimer = Timer.publish(every: 1.0, on: .main, in: .common).autoconnect()

    var body: some View {
        NavigationStack {
            ZStack {
                AppTheme.background.ignoresSafeArea()

                if viewModel.isUnlocked {
                    archiveContent
                } else {
                    lockedContent
                }
            }
            .toolbar(.hidden, for: .navigationBar)
        }
        .onAppear {
            viewModel.refreshFromArchive()
            viewModel.importCurrentClipboardIfChanged()
        }
        .onChange(of: scenePhase) { _, newValue in
            if newValue == .active {
                viewModel.refreshFromArchive()
                viewModel.importCurrentClipboardIfChanged()
            }
        }
        .onReceive(archiveRefreshTimer) { _ in
            viewModel.refreshFromArchive()
        }
    }

    private var archiveContent: some View {
        VStack(spacing: 0) {
            topBar

            scopeTabs

            List {
                ForEach(viewModel.filteredEntries) { entry in
                    ArchiveRow(entry: entry) {
                        viewModel.copy(entry)
                    } onFavorite: {
                        viewModel.toggleFavorite(entry)
                    } onDelete: {
                        viewModel.delete(entry)
                    }
                    .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .searchable(text: $viewModel.searchText)

            statusBar
        }
        .background(AppTheme.background)
    }

    private var topBar: some View {
        HStack {
            AppLogo(size: 34)

            Spacer()

            GlassIconButton(systemName: "plus", accessibilityLabel: "Zwischenablage speichern") {
                viewModel.importCurrentClipboard()
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .background(.ultraThinMaterial)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(AppTheme.stroke)
                .frame(height: 1)
        }
    }

    private var scopeTabs: some View {
        HStack(spacing: 8) {
            ForEach(HistoryScope.allCases) { scope in
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        viewModel.selectedScope = scope
                    }
                } label: {
                    Text(scope.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(viewModel.selectedScope == scope ? .white : .secondary)
                        .frame(maxWidth: .infinity)
                        .frame(height: 34)
                        .background {
                            if viewModel.selectedScope == scope {
                                Capsule()
                                    .fill(.ultraThinMaterial)
                                    .overlay {
                                        Capsule().stroke(AppTheme.stroke)
                                    }
                            }
                        }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .background(Color.clear)
    }

    private var statusBar: some View {
        Text(viewModel.statusText)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(.ultraThinMaterial)
            .overlay(alignment: .top) {
                Rectangle()
                    .fill(AppTheme.stroke)
                    .frame(height: 1)
            }
    }

    private var lockedContent: some View {
        VStack(spacing: 18) {
            AppLogo(size: 44)
            Image(systemName: "lock.fill")
                .font(.system(size: 36, weight: .medium))
                .foregroundStyle(.secondary)
            Text("Archiv gesperrt")
                .font(.title3.weight(.semibold))
            Text(viewModel.statusText)
                .font(.footnote)
                .foregroundStyle(.secondary)
            Button("Entsperren", action: viewModel.authenticate)
                .buttonStyle(.borderedProminent)
        }
        .padding(24)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(AppTheme.stroke)
        }
        .padding(24)
    }
}

struct ArchiveRow: View {
    let entry: ClipEntry
    let onCopy: () -> Void
    let onFavorite: () -> Void
    let onDelete: () -> Void

    var body: some View {
        Button(action: onCopy) {
            HStack(spacing: 12) {
                Image(systemName: entry.displayLabel == "Bild" ? "photo" : "text.alignleft")
                    .font(.system(size: 17, weight: .medium))
                    .frame(width: 38, height: 38)
                    .foregroundStyle(.secondary)
                    .background(.regularMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(entry.displayLabel)
                            .font(.subheadline.weight(.semibold))
                        Text(entry.createdAt, format: .dateTime.day().month().year().hour().minute())
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Text(entry.preview)
                        .font(.subheadline)
                        .lineLimit(2)
                        .foregroundStyle(.primary)
                }

                Spacer()

                Button(action: onFavorite) {
                    Image(systemName: entry.isFavorite == true ? "star.fill" : "star")
                        .foregroundStyle(entry.isFavorite == true ? .yellow : .secondary)
                        .frame(width: 34, height: 34)
                }
                .buttonStyle(.plain)
            }
            .padding(12)
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(AppTheme.stroke)
            }
        }
        .buttonStyle(.plain)
        .swipeActions(edge: .trailing) {
            Button(role: .destructive, action: onDelete) {
                Label("Löschen", systemImage: "trash")
            }
        }
    }
}

private enum AppTheme {
    static let background = LinearGradient(
        colors: [
            Color(red: 0.07, green: 0.075, blue: 0.08),
            Color(red: 0.12, green: 0.125, blue: 0.13)
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
    static let stroke = Color.white.opacity(0.08)
}

private struct AppLogo: View {
    let size: CGFloat

    var body: some View {
        Image(systemName: "doc.on.clipboard")
            .font(.system(size: size * 0.56, weight: .regular))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(.regularMaterial)
            .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
                    .stroke(AppTheme.stroke)
            }
    }
}

private struct GlassIconButton: View {
    let systemName: String
    let accessibilityLabel: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 36, height: 36)
                .background(.regularMaterial)
                .clipShape(Circle())
                .overlay {
                    Circle().stroke(AppTheme.stroke)
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
    }
}
