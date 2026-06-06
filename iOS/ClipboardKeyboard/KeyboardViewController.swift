import ClipboardCore
import LocalAuthentication
import UIKit

private let appGroupIdentifier = "group.local.clipboardtresor"

final class KeyboardViewController: UIInputViewController {
    private let repository = ClipboardArchiveRepository(
        configuration: ArchiveConfiguration(appGroupIdentifier: appGroupIdentifier)
    )

    private let rootStack = UIStackView()
    private let favoriteScrollView = UIScrollView()
    private let favoriteStack = UIStackView()
    private let statusLabel = UILabel()
    private var isUnlocked = false

    override func viewDidLoad() {
        super.viewDidLoad()
        configureLayout()
        renderFavorites()
        renderKeyboard()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        if isUnlocked {
            renderFavorites()
        }
    }

    private func configureLayout() {
        view.backgroundColor = .systemBackground

        rootStack.axis = .vertical
        rootStack.spacing = 7
        rootStack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(rootStack)

        NSLayoutConstraint.activate([
            rootStack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
            rootStack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
            rootStack.topAnchor.constraint(equalTo: view.topAnchor, constant: 8),
            rootStack.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -8)
        ])
    }

    private func renderFavorites() {
        if rootStack.arrangedSubviews.contains(favoriteScrollView) {
            favoriteStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        } else {
            let bar = UIStackView()
            bar.axis = .horizontal
            bar.alignment = .center
            bar.spacing = 8

            let globeButton = keyboardButton(title: nil, imageName: "globe")
            globeButton.addTarget(self, action: #selector(nextKeyboardTapped), for: .touchUpInside)
            globeButton.addTarget(self, action: #selector(nextKeyboardTouchDown(_:event:)), for: .touchDown)
            globeButton.widthAnchor.constraint(equalToConstant: 42).isActive = true
            bar.addArrangedSubview(globeButton)

            favoriteScrollView.showsHorizontalScrollIndicator = false
            favoriteStack.axis = .horizontal
            favoriteStack.spacing = 7
            favoriteStack.translatesAutoresizingMaskIntoConstraints = false
            favoriteScrollView.addSubview(favoriteStack)

            NSLayoutConstraint.activate([
                favoriteStack.leadingAnchor.constraint(equalTo: favoriteScrollView.contentLayoutGuide.leadingAnchor),
                favoriteStack.trailingAnchor.constraint(equalTo: favoriteScrollView.contentLayoutGuide.trailingAnchor),
                favoriteStack.topAnchor.constraint(equalTo: favoriteScrollView.contentLayoutGuide.topAnchor),
                favoriteStack.bottomAnchor.constraint(equalTo: favoriteScrollView.contentLayoutGuide.bottomAnchor),
                favoriteStack.heightAnchor.constraint(equalTo: favoriteScrollView.frameLayoutGuide.heightAnchor),
                favoriteScrollView.heightAnchor.constraint(equalToConstant: 42)
            ])

            bar.addArrangedSubview(favoriteScrollView)

            let lockButton = keyboardButton(title: nil, imageName: isUnlocked ? "lock.open" : "lock")
            lockButton.addTarget(self, action: #selector(unlockTapped), for: .touchUpInside)
            lockButton.widthAnchor.constraint(equalToConstant: 42).isActive = true
            bar.addArrangedSubview(lockButton)

            rootStack.insertArrangedSubview(bar, at: 0)
        }

        if isUnlocked {
            let favorites = repository.reload().filter { $0.isFavorite == true }.prefix(12)
            if favorites.isEmpty {
                addFavoritePlaceholder("Keine Favoriten")
            } else {
                for entry in favorites {
                    let button = favoriteButton(for: entry)
                    favoriteStack.addArrangedSubview(button)
                }
            }
        } else {
            let unlockButton = favoriteChip(title: "Favoriten entsperren")
            unlockButton.addTarget(self, action: #selector(unlockTapped), for: .touchUpInside)
            favoriteStack.addArrangedSubview(unlockButton)
        }
    }

    private func renderKeyboard() {
        statusLabel.text = "ClipboardTresor"
        statusLabel.textColor = .secondaryLabel
        statusLabel.font = .preferredFont(forTextStyle: .caption1)
        statusLabel.textAlignment = .center
        rootStack.addArrangedSubview(statusLabel)

        let rows: [[String]] = [
            Array("qwertzuiop").map(String.init),
            Array("asdfghjkl").map(String.init),
            Array("yxcvbnm").map(String.init)
        ]

        for row in rows {
            rootStack.addArrangedSubview(keyRow(row.map { key in
                let button = keyboardButton(title: key.uppercased())
                button.addAction(UIAction { [weak self] _ in
                    self?.textDocumentProxy.insertText(key)
                }, for: .touchUpInside)
                return button
            }))
        }

        let deleteButton = keyboardButton(title: nil, imageName: "delete.left")
        deleteButton.addAction(UIAction { [weak self] _ in
            self?.textDocumentProxy.deleteBackward()
        }, for: .touchUpInside)

        let spaceButton = keyboardButton(title: "Leerzeichen")
        spaceButton.addAction(UIAction { [weak self] _ in
            self?.textDocumentProxy.insertText(" ")
        }, for: .touchUpInside)

        let returnButton = keyboardButton(title: "Return")
        returnButton.addAction(UIAction { [weak self] _ in
            self?.textDocumentProxy.insertText("\n")
        }, for: .touchUpInside)

        let bottomRow = keyRow([deleteButton, spaceButton, returnButton])
        spaceButton.widthAnchor.constraint(equalTo: deleteButton.widthAnchor, multiplier: 2.6).isActive = true
        rootStack.addArrangedSubview(bottomRow)
    }

    private func keyRow(_ buttons: [UIButton]) -> UIStackView {
        let row = UIStackView(arrangedSubviews: buttons)
        row.axis = .horizontal
        row.spacing = 6
        row.distribution = .fillEqually
        row.heightAnchor.constraint(equalToConstant: 42).isActive = true
        return row
    }

    private func favoriteButton(for entry: ClipEntry) -> UIButton {
        let title = entry.kind == .image ? "Bild" : entry.preview
        let button = favoriteChip(title: title)
        button.addAction(UIAction { [weak self] _ in
            self?.insert(entry)
        }, for: .touchUpInside)
        return button
    }

    private func favoriteChip(title: String) -> UIButton {
        let button = UIButton(type: .system)
        var configuration = UIButton.Configuration.filled()
        configuration.title = title
        configuration.baseBackgroundColor = .secondarySystemFill
        configuration.baseForegroundColor = .label
        configuration.cornerStyle = .capsule
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12)
        button.configuration = configuration
        button.titleLabel?.lineBreakMode = .byTruncatingTail
        button.widthAnchor.constraint(lessThanOrEqualToConstant: 180).isActive = true
        return button
    }

    private func keyboardButton(title: String?, imageName: String? = nil) -> UIButton {
        let button = UIButton(type: .system)
        var configuration = UIButton.Configuration.filled()
        configuration.title = title
        if let imageName {
            configuration.image = UIImage(systemName: imageName)
        }
        configuration.baseBackgroundColor = .secondarySystemBackground
        configuration.baseForegroundColor = .label
        configuration.cornerStyle = .medium
        button.configuration = configuration
        button.titleLabel?.font = .preferredFont(forTextStyle: .body)
        return button
    }

    private func addFavoritePlaceholder(_ text: String) {
        let label = UILabel()
        label.text = text
        label.textColor = .secondaryLabel
        label.font = .preferredFont(forTextStyle: .footnote)
        favoriteStack.addArrangedSubview(label)
    }

    private func insert(_ entry: ClipEntry) {
        guard isUnlocked else {
            authenticate()
            return
        }

        switch entry.kind {
        case .text:
            guard let text = try? repository.string(for: entry) else {
                statusLabel.text = "Text nicht lesbar"
                return
            }
            textDocumentProxy.insertText(text)
            statusLabel.text = "Favorit eingefügt"
        case .image:
            guard let data = try? repository.data(for: entry),
                  let image = UIImage(data: data) else {
                statusLabel.text = "Bild nicht lesbar"
                return
            }
            UIPasteboard.general.image = image
            statusLabel.text = "Bild kopiert"
        }
    }

    private func authenticate() {
        let context = LAContext()
        context.localizedCancelTitle = "Abbrechen"

        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            statusLabel.text = "Entsperren nicht verfügbar"
            return
        }

        statusLabel.text = "Entsperren..."
        context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "ClipboardTresor Favoriten entsperren") { [weak self] success, authError in
            DispatchQueue.main.async {
                guard let self else { return }
                self.isUnlocked = success
                self.statusLabel.text = success ? "Favoriten entsperrt" : (authError?.localizedDescription ?? "Gesperrt")
                self.renderFavorites()
            }
        }
    }

    @objc private func unlockTapped() {
        if isUnlocked {
            isUnlocked = false
            statusLabel.text = "Favoriten gesperrt"
            renderFavorites()
        } else {
            authenticate()
        }
    }

    @objc private func nextKeyboardTapped() {
        advanceToNextInputMode()
    }

    @objc private func nextKeyboardTouchDown(_ sender: UIButton, event: UIEvent) {
        handleInputModeList(from: sender, with: event)
    }
}
