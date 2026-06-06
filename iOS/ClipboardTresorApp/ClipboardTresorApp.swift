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
            }
        }
    }

    func importCurrentClipboard() {
        if UIPasteboard.general.hasImages, let image = UIPasteboard.general.image, let data = image.pngData() {
            do {
                try repository.addImageData(data)
                refresh(status: "Bild gespeichert")
            } catch {
                statusText = "Bild konnte nicht gespeichert werden"
            }
            return
        }

        if UIPasteboard.general.hasStrings, let text = UIPasteboard.general.string, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            do {
                try repository.addText(text)
                refresh(status: "Text gespeichert")
            } catch {
                statusText = "Text konnte nicht gespeichert werden"
            }
            return
        }

        statusText = "Keine passende Zwischenablage gefunden"
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
                        Button(action: viewModel.importCurrentClipboard) {
                            Image(systemName: "plus")
                        }
                        .accessibilityLabel("Zwischenablage speichern")
                    }
                }
            }
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
