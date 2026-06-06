import ClipboardCore
import UIKit

private let appGroupIdentifier = "group.local.clipboardtresor"
private let keychainAccessGroup = "H9YGR79DYW.local.clipboardtresor.shared"

final class KeyboardViewController: UIInputViewController {
    private let repository = ClipboardArchiveRepository(
        configuration: ArchiveConfiguration(
            appGroupIdentifier: appGroupIdentifier,
            keychainAccessGroup: keychainAccessGroup
        )
    )

    private let barView = UIVisualEffectView(effect: UIBlurEffect(style: .systemMaterial))
    private let favoriteScrollView = UIScrollView()
    private let favoriteStack = UIStackView()
    private var refreshTimer: Timer?
    private var lastFavoriteSignature: String?

    override func viewDidLoad() {
        super.viewDidLoad()
        configureLayout()
        reloadFavorites()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        reloadFavorites()
        startRefreshingFavorites()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        stopRefreshingFavorites()
    }

    private func configureLayout() {
        view.backgroundColor = .clear

        barView.translatesAutoresizingMaskIntoConstraints = false
        barView.layer.cornerRadius = 0
        barView.clipsToBounds = true
        view.addSubview(barView)

        let globeButton = iconButton(systemName: "globe")
        globeButton.addTarget(self, action: #selector(nextKeyboardTapped), for: .touchUpInside)
        globeButton.addTarget(self, action: #selector(nextKeyboardTouchDown(_:event:)), for: .touchDown)

        let appButton = iconButton(systemName: "app.badge")
        appButton.addTarget(self, action: #selector(openApp), for: .touchUpInside)

        favoriteScrollView.showsHorizontalScrollIndicator = false
        favoriteScrollView.alwaysBounceHorizontal = true

        favoriteStack.axis = .horizontal
        favoriteStack.alignment = .center
        favoriteStack.spacing = 8
        favoriteStack.translatesAutoresizingMaskIntoConstraints = false
        favoriteScrollView.addSubview(favoriteStack)

        let contentStack = UIStackView(arrangedSubviews: [globeButton, favoriteScrollView, appButton])
        contentStack.axis = .horizontal
        contentStack.alignment = .center
        contentStack.spacing = 8
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        barView.contentView.addSubview(contentStack)

        NSLayoutConstraint.activate([
            barView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            barView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            barView.topAnchor.constraint(equalTo: view.topAnchor),
            barView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            barView.heightAnchor.constraint(equalToConstant: 54),

            contentStack.leadingAnchor.constraint(equalTo: barView.contentView.leadingAnchor, constant: 8),
            contentStack.trailingAnchor.constraint(equalTo: barView.contentView.trailingAnchor, constant: -8),
            contentStack.topAnchor.constraint(equalTo: barView.contentView.topAnchor, constant: 7),
            contentStack.bottomAnchor.constraint(equalTo: barView.contentView.bottomAnchor, constant: -7),

            globeButton.widthAnchor.constraint(equalToConstant: 36),
            globeButton.heightAnchor.constraint(equalToConstant: 36),
            appButton.widthAnchor.constraint(equalToConstant: 36),
            appButton.heightAnchor.constraint(equalToConstant: 36),

            favoriteStack.leadingAnchor.constraint(equalTo: favoriteScrollView.contentLayoutGuide.leadingAnchor),
            favoriteStack.trailingAnchor.constraint(equalTo: favoriteScrollView.contentLayoutGuide.trailingAnchor),
            favoriteStack.topAnchor.constraint(equalTo: favoriteScrollView.contentLayoutGuide.topAnchor),
            favoriteStack.bottomAnchor.constraint(equalTo: favoriteScrollView.contentLayoutGuide.bottomAnchor),
            favoriteStack.heightAnchor.constraint(equalTo: favoriteScrollView.frameLayoutGuide.heightAnchor)
        ])
    }

    private func reloadFavorites() {
        let favorites = Array(repository.reload().filter { $0.isFavorite == true }.prefix(20))
        let signature = favorites.map { "\($0.id):\($0.preview):\($0.isFavorite == true)" }.joined(separator: "|")
        guard signature != lastFavoriteSignature else { return }
        lastFavoriteSignature = signature

        favoriteStack.arrangedSubviews.forEach { $0.removeFromSuperview() }

        guard !favorites.isEmpty else {
            favoriteStack.addArrangedSubview(placeholderLabel("Keine Favoriten"))
            return
        }

        for entry in favorites {
            favoriteStack.addArrangedSubview(favoriteButton(for: entry))
        }
    }

    private func favoriteButton(for entry: ClipEntry) -> UIButton {
        let title = entry.kind == .image ? "Bild" : entry.preview
        let button = UIButton(type: .system)
        var configuration = UIButton.Configuration.gray()
        configuration.title = title
        configuration.image = UIImage(systemName: entry.kind == .image ? "photo" : "text.quote")
        configuration.imagePadding = 5
        configuration.cornerStyle = .capsule
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 10, bottom: 6, trailing: 12)
        button.configuration = configuration
        button.titleLabel?.lineBreakMode = .byTruncatingTail
        button.widthAnchor.constraint(lessThanOrEqualToConstant: 220).isActive = true
        button.addAction(UIAction { [weak self] _ in
            self?.insert(entry)
        }, for: .touchUpInside)
        return button
    }

    private func startRefreshingFavorites() {
        refreshTimer?.invalidate()
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.reloadFavorites()
        }
        refreshTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func stopRefreshingFavorites() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    private func iconButton(systemName: String) -> UIButton {
        let button = UIButton(type: .system)
        var configuration = UIButton.Configuration.plain()
        configuration.image = UIImage(systemName: systemName)
        configuration.baseForegroundColor = .secondaryLabel
        configuration.cornerStyle = .capsule
        button.configuration = configuration
        return button
    }

    private func placeholderLabel(_ text: String) -> UILabel {
        let label = UILabel()
        label.text = text
        label.textColor = .secondaryLabel
        label.font = .preferredFont(forTextStyle: .footnote)
        return label
    }

    private func insert(_ entry: ClipEntry) {
        switch entry.kind {
        case .text:
            guard let text = try? repository.string(for: entry) else {
                return
            }
            textDocumentProxy.insertText(text)
        case .image:
            guard let data = try? repository.data(for: entry),
                  let image = UIImage(data: data) else {
                return
            }
            UIPasteboard.general.image = image
        }
    }

    @objc private func openApp() {
        guard let url = URL(string: "clipboardtresor://") else { return }
        extensionContext?.open(url)
    }

    @objc private func nextKeyboardTapped() {
        advanceToNextInputMode()
    }

    @objc private func nextKeyboardTouchDown(_ sender: UIButton, event: UIEvent) {
        handleInputModeList(from: sender, with: event)
    }
}
