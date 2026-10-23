import PDFKit
import SwiftUI
import UIKit
import UniformTypeIdentifiers
import UserNotifications
import Vision

/// The "Agenda" button in the Share menu. It reads what's shared (text, a link, screenshots or a
/// PDF), keeps it for the app to sort, and taps Ian on the shoulder to finish adding it.
final class ShareViewController: UIViewController {
    private let model = ShareModel()

    override func viewDidLoad() {
        super.viewDidLoad()
        model.finish = { [weak self] in self?.extensionContext?.completeRequest(returningItems: nil) }
        model.cancel = { [weak self] in
            self?.extensionContext?.cancelRequest(withError: NSError(domain: "Agenda", code: 0))
        }
        let host = UIHostingController(rootView: ShareView(model: model))
        addChild(host)
        host.view.frame = view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(host.view)
        host.didMove(toParent: self)

        let items = (extensionContext?.inputItems as? [NSExtensionItem]) ?? []
        Task { await model.load(items) }
    }
}

@MainActor
@Observable
final class ShareModel {
    var text = ""
    var link = ""
    var comment = ""
    var loading = true
    var finish: () -> Void = {}
    var cancel: () -> Void = {}

    var preview: String {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if body.isEmpty { return link }
        return String(body.prefix(400))
    }

    func load(_ items: [NSExtensionItem]) async {
        var texts: [String] = []
        for item in items {
            if let content = item.attributedContentText?.string, !content.isEmpty { texts.append(content) }
            for provider in item.attachments ?? [] {
                if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier),
                   let url = try? await provider.loadItem(forTypeIdentifier: UTType.url.identifier) as? URL {
                    if url.isFileURL {
                        if let found = read(fileURL: url) { texts.append(found) }
                    } else if link.isEmpty {
                        link = url.absoluteString
                    }
                } else if provider.hasItemConformingToTypeIdentifier(UTType.pdf.identifier),
                          let found = await loadPDF(provider) {
                    texts.append(found)
                } else if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier),
                          let image = await loadImage(provider), let found = await recognise(image) {
                    texts.append(found)
                } else if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier),
                          let found = try? await provider.loadItem(forTypeIdentifier: UTType.plainText.identifier) as? String {
                    texts.append(found)
                }
            }
        }
        // Avoid repeating the same text twice (some apps send it both ways).
        var seen = Set<String>()
        text = texts.filter { seen.insert($0).inserted }.joined(separator: "\n\n")
        loading = false
    }

    func save() {
        let drop = SharedDrop(text: String(text.prefix(20000)), link: link, comment: comment.trimmingCharacters(in: .whitespacesAndNewlines))
        ShareInbox.add(drop)
        let content = UNMutableNotificationContent()
        content.title = "Ready to add"
        content.body = "Tap to check what Agenda found and add it."
        content.sound = nil
        let request = UNNotificationRequest(identifier: "share-\(drop.id.uuidString)", content: content,
                                            trigger: UNTimeIntervalNotificationTrigger(timeInterval: 2, repeats: false))
        UNUserNotificationCenter.current().add(request) { _ in }
        finish()
    }

    // MARK: - Reading attachments

    private func read(fileURL: URL) -> String? {
        if fileURL.pathExtension.lowercased() == "pdf", let document = PDFDocument(url: fileURL) {
            return pdfText(document)
        }
        return try? String(contentsOf: fileURL, encoding: .utf8)
    }

    private func loadPDF(_ provider: NSItemProvider) async -> String? {
        guard let value = try? await provider.loadItem(forTypeIdentifier: UTType.pdf.identifier) else { return nil }
        if let url = value as? URL, let document = PDFDocument(url: url) { return pdfText(document) }
        if let data = value as? Data, let document = PDFDocument(data: data) { return pdfText(document) }
        return nil
    }

    private func pdfText(_ document: PDFDocument) -> String? {
        var pages: [String] = []
        for index in 0..<min(document.pageCount, 6) {
            if let page = document.page(at: index)?.string { pages.append(page) }
        }
        let joined = pages.joined(separator: "\n")
        return joined.isEmpty ? nil : joined
    }

    private func loadImage(_ provider: NSItemProvider) async -> CGImage? {
        guard let value = try? await provider.loadItem(forTypeIdentifier: UTType.image.identifier) else { return nil }
        var image: UIImage?
        if let url = value as? URL { image = UIImage(contentsOfFile: url.path) }
        else if let data = value as? Data { image = UIImage(data: data) }
        else if let ui = value as? UIImage { image = ui }
        return image?.cgImage
    }

    /// Reads the words in a screenshot, on the phone.
    private func recognise(_ image: CGImage) async -> String? {
        await Task.detached(priority: .userInitiated) {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            try? VNImageRequestHandler(cgImage: image).perform([request])
            let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
            return lines.isEmpty ? nil : lines.joined(separator: "\n")
        }.value
    }
}

struct ShareView: View {
    @Bindable var model: ShareModel

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if model.loading {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text("Reading…").foregroundStyle(.secondary)
                        }
                    } else if model.preview.isEmpty {
                        Text("Nothing to read here, but you can still say what it's about below.")
                            .foregroundStyle(.secondary)
                    } else {
                        Text(model.preview)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .lineLimit(8)
                    }
                } header: {
                    Text("Shared")
                }
                Section {
                    TextField("Anything to add? e.g. dinner with Sam", text: $model.comment, axis: .vertical)
                } footer: {
                    Text("Agenda will pick out the booking or to-dos, with dates, places and confirmation numbers, for you to check.")
                }
            }
            .navigationTitle("Add to Agenda")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { model.cancel() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") { model.save() }
                        .fontWeight(.semibold)
                        .disabled(model.loading || (model.preview.isEmpty && model.comment.isEmpty))
                }
            }
        }
    }
}
