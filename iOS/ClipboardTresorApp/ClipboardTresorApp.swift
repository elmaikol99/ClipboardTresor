import ClipboardCore
import LocalAuthentication
import SwiftUI
import UIKit
import UniformTypeIdentifiers

private let appGroupIdentifier = "group.local.clipboardtresor"

@main
struct ClipboardTresorApp: App {
    var body: some Scene {
        WindowGroup {
            ArchiveListView(
                viewModel: ArchiveListViewModel(
                    repository: ClipboardArchiveRepository(
                        configuration: ArchiveConfiguration(appGroupIdentifier: appGroupIdentifier)
                    )
                )
            )
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
    private var lastSeenPasteboardChangeCount: Int?
    private var lastImportedSignature: String?

    init(repository: ClipboardArchiveRepository) {
        self.repository = repository
        entries = repository.entries
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
            Group {
                if viewModel.isUnlocked {
                    archiveContent
                } else {
                    lockedContent
                }
            }
            .navigationTitle("ClipboardTresor")
            .toolbar {
                if viewModel.isUnlocked {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button(action: { viewModel.importCurrentClipboard() }) {
                            Image(systemName: "plus")
                        }
                        .accessibilityLabel("Zwischenablage speichern")
                    }
                }
            }
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
            Picker("", selection: $viewModel.selectedScope) {
                ForEach(HistoryScope.allCases) { scope in
                    Text(scope.title).tag(scope)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.top, 8)

            List {
                ForEach(viewModel.filteredEntries) { entry in
                    ArchiveRow(entry: entry) {
                        viewModel.copy(entry)
                    } onFavorite: {
                        viewModel.toggleFavorite(entry)
                    } onDelete: {
                        viewModel.delete(entry)
                    }
                }
            }
            .searchable(text: $viewModel.searchText)

            Text(viewModel.statusText)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
        }
    }

    private var lockedContent: some View {
        VStack(spacing: 16) {
            Image(systemName: "lock.fill")
                .font(.system(size: 44, weight: .medium))
                .foregroundStyle(.secondary)
            Text("Archiv gesperrt")
                .font(.title3.weight(.semibold))
            Text(viewModel.statusText)
                .font(.footnote)
                .foregroundStyle(.secondary)
            Button("Entsperren", action: viewModel.authenticate)
                .buttonStyle(.borderedProminent)
        }
        .padding()
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
                    .frame(width: 34, height: 34)
                    .foregroundStyle(.secondary)

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
                }
                .buttonStyle(.plain)
            }
        }
        .swipeActions(edge: .trailing) {
            Button(role: .destructive, action: onDelete) {
                Label("Löschen", systemImage: "trash")
            }
        }
    }
}
