import ClipboardCore
import KeyboardKit
import SwiftUI
import UIKit

private let appGroupIdentifier = "group.local.clipboardtresor"
private let keychainAccessGroup = "H9YGR79DYW.local.clipboardtresor.shared"

extension KeyboardApp {
    static var clipboardTresor: KeyboardApp {
        .init(
            name: "ClipboardTresor",
            appGroupId: appGroupIdentifier,
            deepLinks: .init(app: "clipboardtresor://")
        )
    }
}

final class KeyboardViewController: KeyboardInputViewController {
    private let repository = ClipboardArchiveRepository(
        configuration: ArchiveConfiguration(
            appGroupIdentifier: appGroupIdentifier,
            keychainAccessGroup: keychainAccessGroup
        )
    )

    override func viewWillSetupKeyboardKit() {
        setupKeyboardKit(for: .clipboardTresor) { result in
            if case .failure(let error) = result {
                print("ClipboardTresor keyboard setup failed: \(error)")
            }
        }
    }

    override func viewWillSetupKeyboardView() {
        setupKeyboardView { [weak self] controller in
            ClipboardTresorKeyboardView(
                services: controller.services,
                state: controller.state,
                repository: self?.repository,
                insertText: { [weak self] text in
                    self?.textDocumentProxy.insertText(text)
                },
                copyImage: { data in
                    guard let image = UIImage(data: data) else { return }
                    UIPasteboard.general.image = image
                }
            )
        }
    }
}

private struct ClipboardTresorKeyboardView: View {
    let services: Keyboard.Services
    let state: Keyboard.State
    let repository: ClipboardArchiveRepository?
    let insertText: (String) -> Void
    let copyImage: (Data) -> Void

    var body: some View {
        KeyboardView(
            layout: KeyboardLayout.standard(for: state.keyboardContext),
            services: services,
            buttonContent: { $0.view },
            buttonView: { $0.view },
            collapsedView: { $0.view },
            emojiKeyboard: { $0.view },
            toolbar: { _ in
                ClipboardFavoritesToolbar(
                    repository: repository,
                    insertText: insertText,
                    copyImage: copyImage
                )
            }
        )
    }
}

private struct ClipboardFavoritesToolbar: View {
    let repository: ClipboardArchiveRepository?
    let insertText: (String) -> Void
    let copyImage: (Data) -> Void

    @State private var favorites: [ClipEntry] = []

    var body: some View {
        HStack(spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    if favorites.isEmpty {
                        Text("Keine Favoriten")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 8)
                    } else {
                        ForEach(favorites) { entry in
                            Button {
                                paste(entry)
                            } label: {
                                Label(
                                    entry.kind == .image ? "Bild" : entry.preview,
                                    systemImage: entry.kind == .image ? "photo" : "text.quote"
                                )
                                .lineLimit(1)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }
                }
                .padding(.leading, 8)
            }

            Link(destination: URL(string: "clipboardtresor://")!) {
                Image(systemName: "app.badge")
                    .font(.system(size: 18))
                    .foregroundStyle(.secondary)
                    .frame(width: 36, height: 36)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.trailing, 6)
        }
        .frame(height: 44)
        .background(.thinMaterial)
        .onAppear(perform: reloadFavorites)
        .task {
            while !Task.isCancelled {
                reloadFavorites()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func reloadFavorites() {
        guard let repository else {
            favorites = []
            return
        }
        let reloaded = Array(repository.reload().filter { $0.isFavorite == true }.prefix(20))
        if reloaded != favorites {
            favorites = reloaded
        }
    }

    private func paste(_ entry: ClipEntry) {
        guard let repository else { return }

        switch entry.kind {
        case .text:
            guard let text = try? repository.string(for: entry) else { return }
            insertText(text)
        case .image:
            guard let data = try? repository.data(for: entry) else { return }
            copyImage(data)
        }
    }
}
