import ClipboardCore
import SwiftUI
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
    private let typingStack = UIStackView()
    private var appLinkHostingController: UIHostingController<KeyboardAppLinkView>?
    private var refreshTimer: Timer?
    private var lastFavoriteSignature: String?
    private var letterButtons: [UIButton] = []
    private var isShifted = false

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
        view.backgroundColor = .systemGray5

        barView.translatesAutoresizingMaskIntoConstraints = false
        barView.layer.cornerRadius = 0
        barView.clipsToBounds = true
        view.addSubview(barView)

        let globeButton = iconButton(systemName: "globe")
        globeButton.addTarget(self, action: #selector(nextKeyboardTapped), for: .touchUpInside)
        globeButton.addTarget(self, action: #selector(nextKeyboardTouchDown(_:event:)), for: .touchDown)

        let appButton = appLinkView()

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

        typingStack.axis = .vertical
        typingStack.spacing = 7
        typingStack.distribution = .fillEqually
        typingStack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(typingStack)
        buildTypingKeyboard()

        NSLayoutConstraint.activate([
            view.heightAnchor.constraint(equalToConstant: 292),

            barView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            barView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            barView.topAnchor.constraint(equalTo: view.topAnchor),
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
            favoriteStack.heightAnchor.constraint(equalTo: favoriteScrollView.frameLayoutGuide.heightAnchor),

            typingStack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 6),
            typingStack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -6),
            typingStack.topAnchor.constraint(equalTo: barView.bottomAnchor, constant: 8),
            typingStack.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -8)
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
            DispatchQueue.main.async {
                self?.reloadFavorites()
            }
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

    private func appLinkView() -> UIView {
        let hostingController = UIHostingController(rootView: KeyboardAppLinkView())
        hostingController.view.backgroundColor = .clear
        hostingController.view.translatesAutoresizingMaskIntoConstraints = false
        addChild(hostingController)
        hostingController.didMove(toParent: self)
        appLinkHostingController = hostingController
        return hostingController.view
    }

    private func buildTypingKeyboard() {
        typingStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        letterButtons.removeAll()

        addLetterRow(["q", "w", "e", "r", "t", "z", "u", "i", "o", "p", "ü"])
        addLetterRow(["a", "s", "d", "f", "g", "h", "j", "k", "l", "ö", "ä"])

        let thirdRow = UIStackView()
        thirdRow.axis = .horizontal
        thirdRow.spacing = 5
        thirdRow.distribution = .fill
        thirdRow.addArrangedSubview(actionButton(systemName: "shift", action: #selector(toggleShift)))
        for letter in ["y", "x", "c", "v", "b", "n", "m"] {
            thirdRow.addArrangedSubview(letterButton(letter))
        }
        thirdRow.addArrangedSubview(actionButton(systemName: "delete.left", action: #selector(deleteBackward)))
        typingStack.addArrangedSubview(thirdRow)

        let bottomRow = UIStackView()
        bottomRow.axis = .horizontal
        bottomRow.spacing = 6
        bottomRow.distribution = .fill
        bottomRow.addArrangedSubview(textKey(".", width: 44))
        bottomRow.addArrangedSubview(spaceButton())
        bottomRow.addArrangedSubview(textKey(",", width: 44))
        bottomRow.addArrangedSubview(returnButton())
        typingStack.addArrangedSubview(bottomRow)
    }

    private func addLetterRow(_ letters: [String]) {
        let row = UIStackView()
        row.axis = .horizontal
        row.spacing = 5
        row.distribution = .fillEqually
        for letter in letters {
            row.addArrangedSubview(letterButton(letter))
        }
        typingStack.addArrangedSubview(row)
    }

    private func letterButton(_ letter: String) -> UIButton {
        let button = keyButton(title: isShifted ? letter.uppercased() : letter)
        button.accessibilityIdentifier = letter
        button.addAction(UIAction { [weak self] _ in
            self?.insertLetter(letter)
        }, for: .touchUpInside)
        letterButtons.append(button)
        return button
    }

    private func textKey(_ text: String, width: CGFloat) -> UIButton {
        let button = keyButton(title: text)
        button.widthAnchor.constraint(equalToConstant: width).isActive = true
        button.addAction(UIAction { [weak self] _ in
            self?.textDocumentProxy.insertText(text)
        }, for: .touchUpInside)
        return button
    }

    private func spaceButton() -> UIButton {
        let button = keyButton(title: "Leerzeichen")
        button.addAction(UIAction { [weak self] _ in
            self?.textDocumentProxy.insertText(" ")
        }, for: .touchUpInside)
        return button
    }

    private func returnButton() -> UIButton {
        let button = keyButton(title: "Return")
        button.widthAnchor.constraint(equalToConstant: 82).isActive = true
        button.addAction(UIAction { [weak self] _ in
            self?.textDocumentProxy.insertText("\n")
        }, for: .touchUpInside)
        return button
    }

    private func actionButton(systemName: String, action: Selector) -> UIButton {
        let button = UIButton(type: .system)
        var configuration = UIButton.Configuration.gray()
        configuration.image = UIImage(systemName: systemName)
        configuration.cornerStyle = .medium
        button.configuration = configuration
        button.widthAnchor.constraint(equalToConstant: 44).isActive = true
        button.addTarget(self, action: action, for: .touchUpInside)
        return button
    }

    private func keyButton(title: String) -> UIButton {
        let button = UIButton(type: .system)
        var configuration = UIButton.Configuration.filled()
        configuration.title = title
        configuration.baseBackgroundColor = .systemBackground
        configuration.baseForegroundColor = .label
        configuration.cornerStyle = .medium
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 5, leading: 4, bottom: 5, trailing: 4)
        button.configuration = configuration
        button.titleLabel?.font = .systemFont(ofSize: 18, weight: .regular)
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

    private func insertLetter(_ letter: String) {
        textDocumentProxy.insertText(isShifted ? letter.uppercased() : letter)
        if isShifted {
            isShifted = false
            updateLetterButtons()
        }
    }

    private func updateLetterButtons() {
        for button in letterButtons {
            guard let letter = button.accessibilityIdentifier else { continue }
            button.configuration?.title = isShifted ? letter.uppercased() : letter
        }
    }

    @objc private func toggleShift() {
        isShifted.toggle()
        updateLetterButtons()
    }

    @objc private func deleteBackward() {
        textDocumentProxy.deleteBackward()
    }

    @objc private func nextKeyboardTapped() {
        advanceToNextInputMode()
    }

    @objc private func nextKeyboardTouchDown(_ sender: UIButton, event: UIEvent) {
        handleInputModeList(from: sender, with: event)
    }
}

private struct KeyboardAppLinkView: View {
    private let appURL = URL(string: "clipboardtresor://")!

    var body: some View {
        Link(destination: appURL) {
            Image(systemName: "app.badge")
                .font(.system(size: 20, weight: .regular))
                .foregroundStyle(Color(uiColor: .secondaryLabel))
                .frame(width: 36, height: 36)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
