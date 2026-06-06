import ClipboardCore
import UIKit
import UniformTypeIdentifiers

private let appGroupIdentifier = "group.local.clipboardtresor"

final class ShareViewController: UIViewController {
    private let repository = ClipboardArchiveRepository(
        configuration: ArchiveConfiguration(appGroupIdentifier: appGroupIdentifier)
    )

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        importSharedItems()
    }

    private func importSharedItems() {
        guard let item = extensionContext?.inputItems.first as? NSExtensionItem,
              let attachments = item.attachments else {
            complete()
            return
        }

        let group = DispatchGroup()
        var didStore = false

        for provider in attachments {
            if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                group.enter()
                provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { [weak self] data, _ in
                    if let data, (try? self?.repository.addImageData(data)) != nil {
                        didStore = true
                    }
                    group.leave()
                }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
                group.enter()
                provider.loadItem(forTypeIdentifier: UTType.plainText.identifier) { [weak self] item, _ in
                    if let text = item as? String, (try? self?.repository.addText(text)) != nil {
                        didStore = true
                    }
                    group.leave()
                }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                group.enter()
                provider.loadItem(forTypeIdentifier: UTType.url.identifier) { [weak self] item, _ in
                    if let url = item as? URL, (try? self?.repository.addText(url.absoluteString)) != nil {
                        didStore = true
                    }
                    group.leave()
                }
            }
        }

        group.notify(queue: .main) { [weak self] in
            self?.complete(didStore: didStore)
        }
    }

    private func complete(didStore: Bool = false) {
        let result = didStore ? "Gespeichert" : "Nichts gespeichert"
        let item = NSExtensionItem()
        item.attributedContentText = NSAttributedString(string: result)
        extensionContext?.completeRequest(returningItems: [item])
    }
}
