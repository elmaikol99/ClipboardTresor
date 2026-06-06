import ClipboardCore
import KeyboardKit
import Network
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
            keychainAccessGroup: keychainAccessGroup,
            prefersLegacyKeychainKey: true
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
        state.keyboardContext.autocapitalizationTypeOverride = Keyboard.AutocapitalizationType.none
        state.keyboardContext.keyboardCase = .lowercased

        setupKeyboardView { [weak self] controller in
            ClipboardTresorKeyboardView(
                services: controller.services,
                state: controller.state,
                keyboardContext: controller.state.keyboardContext,
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
    @ObservedObject var keyboardContext: KeyboardContext
    let repository: ClipboardArchiveRepository?
    let insertText: (String) -> Void
    let copyImage: (Data) -> Void

    var body: some View {
        KeyboardView(
            layout: KeyboardLayout.standard(for: keyboardContext),
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
        .keyboardState(state)
    }
}

private struct ClipboardFavoritesToolbar: View {
    let repository: ClipboardArchiveRepository?
    let insertText: (String) -> Void
    let copyImage: (Data) -> Void

    @State private var favorites: [ClipEntry] = []
    @State private var syncClient: KeyboardFavoriteSyncClient?

    var body: some View {
        HStack(spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    if favorites.isEmpty {
                        Text("Favoriten")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 8)
                    } else {
                        ForEach(favorites) { entry in
                            Button {
                                paste(entry)
                            } label: {
                                HStack(spacing: 5) {
                                    Image(systemName: entry.kind == .image ? "photo" : "text.quote")
                                        .font(.caption2.weight(.semibold))
                                    Text(entry.kind == .image ? "Bild" : entry.preview)
                                        .font(.caption.weight(.medium))
                                }
                                .lineLimit(1)
                                .foregroundStyle(.primary)
                                .padding(.horizontal, 10)
                                .frame(height: 28)
                                .background(.ultraThinMaterial)
                                .clipShape(Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(.leading, 8)
            }

            Link(destination: URL(string: "clipboardtresor://")!) {
                Image(systemName: "app.badge")
                    .font(.system(size: 16))
                    .foregroundStyle(.secondary)
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.trailing, 8)
        }
        .frame(height: 36)
        .background(Color.clear)
        .onAppear {
            reloadFavorites()
            startSyncIfNeeded()
        }
        .task {
            while !Task.isCancelled {
                syncClient?.syncOnce()
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

    private func startSyncIfNeeded() {
        guard syncClient == nil, let repository else { return }
        let client = KeyboardFavoriteSyncClient(repository: repository) {
            reloadFavorites()
        }
        syncClient = client
        client.start()
        client.syncOnce()
    }
}

private final class KeyboardFavoriteSyncClient: @unchecked Sendable {
    private let repository: ClipboardArchiveRepository
    private let onMerged: @MainActor () -> Void
    private let queue = DispatchQueue(label: "ClipboardTresor.KeyboardFavoriteSync")
    private var browser: NWBrowser?
    private var endpoint: NWEndpoint?
    private var isSyncing = false

    init(repository: ClipboardArchiveRepository, onMerged: @escaping @MainActor () -> Void) {
        self.repository = repository
        self.onMerged = onMerged
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
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        if self.repository.mergeFavoriteSyncPayload(body) {
                            self.onMerged()
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
