import MessageUI
import SwiftUI
import UniformTypeIdentifiers

struct FeedbackMailComposer: UIViewControllerRepresentable {
    let draft: FeedbackEmailDraft
    let onFinish: (MFMailComposeResult, Error?) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onFinish: onFinish) }

    func makeUIViewController(context: Context) -> MFMailComposeViewController {
        let controller = MFMailComposeViewController()
        controller.mailComposeDelegate = context.coordinator
        controller.setToRecipients([draft.recipient])
        controller.setSubject(draft.emailSubject)
        controller.setMessageBody(draft.emailBody, isHTML: false)
        for attachment in draft.attachments {
            controller.addAttachmentData(attachment.data, mimeType: attachment.mimeType, fileName: attachment.filename)
        }
        return controller
    }

    func updateUIViewController(_ controller: MFMailComposeViewController, context: Context) {}

    final class Coordinator: NSObject, MFMailComposeViewControllerDelegate {
        let onFinish: (MFMailComposeResult, Error?) -> Void
        init(onFinish: @escaping (MFMailComposeResult, Error?) -> Void) { self.onFinish = onFinish }
        func mailComposeController(_ controller: MFMailComposeViewController,
                                   didFinishWith result: MFMailComposeResult, error: Error?) {
            onFinish(result, error)
        }
    }
}

/// Used only when Apple Mail is unavailable. Every chosen attachment is handed
/// to the system share sheet; the UI explains that the recipient must be entered.
struct FeedbackSharePayload: Identifiable {
    enum PreparationError: Error { case invalidRecipient }
    let id = UUID()
    let directory: URL
    let draft: FeedbackEmailDraft
    let urls: [URL]

    static func make(draft: FeedbackEmailDraft) throws -> Self {
        guard FeedbackConfiguration.validatedRecipient(draft.recipient) != nil else {
            throw PreparationError.invalidRecipient
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("HangarFeedback-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.complete])
        do {
            let messageURL = directory.appendingPathComponent("feedback-message.txt")
            let message = "To: \(draft.recipient)\nSubject: \(draft.emailSubject)\n\n\(draft.emailBody)"
            try Data(message.utf8).write(to: messageURL, options: [.atomic, .completeFileProtection])
            var urls = [messageURL]
            for attachment in draft.attachments {
                let url = directory.appendingPathComponent(attachment.filename)
                try attachment.data.write(to: url, options: [.atomic, .completeFileProtection])
                urls.append(url)
            }
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var protectedDirectory = directory
            try protectedDirectory.setResourceValues(values)
            return Self(directory: directory, draft: draft, urls: urls)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }
}

struct FeedbackShareSheet: UIViewControllerRepresentable {
    let payload: FeedbackSharePayload
    let onFinish: () -> Void

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let source = MessageSource(draft: payload.draft)
        let controller = UIActivityViewController(activityItems: [source] + payload.urls, applicationActivities: nil)
        controller.completionWithItemsHandler = { _, _, _, _ in
            Task { @MainActor in onFinish() }
        }
        return controller
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}

    final class MessageSource: NSObject, UIActivityItemSource {
        let draft: FeedbackEmailDraft
        init(draft: FeedbackEmailDraft) { self.draft = draft }
        func activityViewControllerPlaceholderItem(_ controller: UIActivityViewController) -> Any { draft.emailBody }
        func activityViewController(_ controller: UIActivityViewController, itemForActivityType activityType: UIActivity.ActivityType?) -> Any? {
            "To: \(draft.recipient)\n\n" + draft.emailBody
        }
        func activityViewController(_ controller: UIActivityViewController, subjectForActivityType activityType: UIActivity.ActivityType?) -> String {
            draft.emailSubject
        }
    }
}
