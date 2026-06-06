import ClipboardCore
import UIKit

private let appGroupIdentifier = "group.local.clipboardtresor"

final class KeyboardViewController: UIInputViewController {
    private let repository = ClipboardArchiveRepository(
        configuration: ArchiveConfiguration(appGroupIdentifier: appGroupIdentifier)
    )
    private let stackView = UIStackView()

    override func viewDidLoad() {
        super.viewDidLoad()
        configureLayout()
        reloadFavorites()
    }

    private func configureLayout() {
        view.backgroundColor = .secondarySystemBackground

        stackView.axis = .vertical
        stackView.spacing = 8
        stackView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stackView)

        NSLayoutConstraint.activate([
            stackView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            stackView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            stackView.topAnchor.constraint(equalTo: view.topAnchor, constant: 10),
            stackView.bottomAnchor.constraint(lessThanOrEqualTo: view.bottomAnchor, constant: -10)
        ])
    }

    private func reloadFavorites() {
        stackView.arrangedSubviews.forEach { $0.removeFromSuperview() }

        let header = UIStackView()
        header.axis = .horizontal
        header.spacing = 8

        let nextKeyboard = UIButton(type: .system)
        nextKeyboard.setImage(UIImage(systemName: "globe"), for: .normal)
        nextKeyboard.addTarget(self, action: #selector(nextKeyboardTapped), for: .touchUpInside)
        header.addArrangedSubview(nextKeyboard)

        let title = UILabel()
        title.text = "Favoriten"
        title.font = .preferredFont(forTextStyle: .headline)
        header.addArrangedSubview(title)
        header.addArrangedSubview(UIView())
        stackView.addArrangedSubview(header)

        let favorites = repository.reload().filter { $0.isFavorite == true }.prefix(6)
        if favorites.isEmpty {
            let label = UILabel()
            label.text = "Keine Favoriten"
            label.textColor = .secondaryLabel
            label.font = .preferredFont(forTextStyle: .footnote)
            stackView.addArrangedSubview(label)
            return
        }

        for entry in favorites {
            let button = UIButton(type: .system)
            button.contentHorizontalAlignment = .leading
            button.titleLabel?.numberOfLines = 2
            button.setTitle(entry.preview, for: .normal)
            button.addAction(UIAction { [weak self] _ in
                self?.insert(entry)
            }, for: .touchUpInside)
            stackView.addArrangedSubview(button)
        }
    }

    private func insert(_ entry: ClipEntry) {
        switch entry.kind {
        case .text:
            guard let text = try? repository.string(for: entry) else { return }
            textDocumentProxy.insertText(text)
        case .image:
            guard let data = try? repository.data(for: entry),
                  let image = UIImage(data: data) else { return }
            UIPasteboard.general.image = image
        }
    }

    @objc private func nextKeyboardTapped() {
        advanceToNextInputMode()
    }
}
