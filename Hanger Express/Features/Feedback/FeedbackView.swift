import MessageUI
import PhotosUI
import SwiftUI

struct FeedbackView: View {
    let appModel: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var subject = ""
    @State private var message = ""
    @State private var includesDeviceDetails = false
    @State private var includesDiagnostics = false
    @State private var diagnosticReport: String?
    @State private var selectedPhotos: [PhotosPickerItem] = []
    @State private var screenshots: [FeedbackAttachment] = []
    @State private var isLoadingScreenshots = false
    @State private var screenshotError = false
    @State private var previewScreenshot: FeedbackAttachment?
    @State private var composerDraft: FeedbackEmailDraft?
    @State private var sharePayload: FeedbackSharePayload?
    @State private var shareDirectory: URL?
    @State private var isShowingShareExplanation = false
    @State private var isShowingError = false
    private let canSendMail = MFMailComposeViewController.canSendMail()

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("To") {
                        Text(FeedbackConfiguration.recipient ?? AppLocalizer.string("Not configured")).textSelection(.enabled)
                            .accessibilityIdentifier("feedback.recipient")
                    }
                    Button("Copy email address") { UIPasteboard.general.string = FeedbackConfiguration.recipient }
                        .disabled(FeedbackConfiguration.recipient == nil)
                    if FeedbackConfiguration.recipient == nil {
                        Text("Feedback email is not configured in this build.").foregroundStyle(.secondary)
                    }
                    Text("Replies will go to the email address you send from. Your email provider also shares your sender address and display name.")
                        .font(.footnote).foregroundStyle(.secondary)
                } header: { Text("Email feedback") }

                Section {
                    TextField("Subject", text: $subject)
                        .accessibilityIdentifier("feedback.subject")
                        .onChange(of: subject) { _, value in subject = String(value.prefix(120)) }
                    TextEditor(text: $message)
                        .frame(minHeight: 140)
                        .accessibilityLabel("Your message")
                        .accessibilityIdentifier("feedback.message")
                        .onChange(of: message) { _, value in message = String(value.prefix(8_000)) }
                } header: { Text("Your message") }

                Section {
                    FeedbackInclusionOption(title: "Include app and device details", identifier: "feedback.includeDetails",
                                            isIncluded: $includesDeviceDetails)
                    if includesDeviceDetails {
                        Text(deviceDetails).font(.footnote).textSelection(.enabled)
                    }
                    FeedbackInclusionOption(title: "Include diagnostic log", identifier: "feedback.includeLogs",
                                            isIncluded: $includesDiagnostics)
                        .onChange(of: includesDiagnostics) { _, enabled in
                            diagnosticReport = enabled ? makeDiagnosticReport() : nil
                        }
                    if let diagnosticReport {
                        NavigationLink {
                            FeedbackTextPreview(title: "Diagnostic log", text: diagnosticReport)
                        } label: { Label("Preview diagnostic log", systemImage: "doc.text.magnifyingglass") }
                        .accessibilityIdentifier("feedback.previewLogs")
                    }
                } header: { Text("Optional details") }
                footer: {
                    Text("Logs are off by default. They contain sanitized sign-in and refresh events, timestamps, errors and network details, and may still include activity or inventory details. Review the full log before sharing. No additional account request is made.")
                }

                Section {
                    PhotosPicker(selection: $selectedPhotos, maxSelectionCount: FeedbackScreenshotProcessor.maximumCount,
                                 matching: .images, photoLibrary: .shared()) {
                        Label("Choose screenshots", systemImage: "photo.badge.plus")
                    }
                    .accessibilityIdentifier("feedback.chooseScreenshots")
                    if isLoadingScreenshots { ProgressView("Preparing screenshots…") }
                    if screenshotError {
                        Text("A selected picture could not be prepared. Choose up to 3 images under 20 MB each, or remove the selection.")
                            .foregroundStyle(.red)
                    }
                    ForEach(screenshots) { attachment in
                        HStack {
                            Button { previewScreenshot = attachment } label: {
                                HStack {
                                    if let image = UIImage(data: attachment.data) {
                                        Image(uiImage: image).resizable().scaledToFit().frame(width: 56, height: 56)
                                    }
                                    Text(attachment.filename)
                                }
                            }.buttonStyle(.plain)
                            Spacer()
                            Button(role: .destructive) { removeScreenshot(attachment) } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel(AppLocalizer.format("Remove %@", attachment.filename))
                        }
                    }
                    if !selectedPhotos.isEmpty {
                        Button("Remove all screenshots", role: .destructive) { selectedPhotos = []; screenshots = [] }
                    }
                } header: { Text("Screenshots — optional") }
                footer: {
                    Text("Only pictures you select are included. Images are resized and saved without original filenames or location metadata. Check the preview for personal information visible in the picture.")
                }

                Section {
                    LabeledContent("App and device details", value: AppLocalizer.string(includesDeviceDetails ? "Included" : "Not included"))
                    LabeledContent("Diagnostic log", value: AppLocalizer.string(includesDiagnostics ? "Included" : "Not included"))
                        .accessibilityIdentifier("feedback.logSummary")
                    LabeledContent("Screenshots", value: String(screenshots.count))
                    NavigationLink {
                        FeedbackTextPreview(title: "Email content", text: draft.emailBody)
                    } label: { Label("Preview email content", systemImage: "envelope.open") }
                    .accessibilityIdentifier("feedback.previewEmail")
                    Button(AppLocalizer.string(canSendMail ? "Continue to Mail" : "Share email draft")) { continueToEmail() }
                        .disabled(message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                                  FeedbackConfiguration.recipient == nil ||
                                  isLoadingScreenshots || screenshots.count != selectedPhotos.count ||
                                  screenshotError || (includesDiagnostics && diagnosticReport == nil))
                        .accessibilityIdentifier("feedback.continue")
                } header: { Text("Review before sending") }
                footer: {
                    Text("Nothing is sent until you send in your email app. Only your message, the details enabled above, and the listed attachments are prepared. Hangar Express does not upload this draft to a feedback server.")
                }
            }
            .navigationTitle("Feedback")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .keyboardDismissToolbar()
            .task(id: selectedPhotos) { await loadScreenshots() }
            .sheet(item: $previewScreenshot) { attachment in
                NavigationStack {
                    ScrollView {
                        if let image = UIImage(data: attachment.data) {
                            Image(uiImage: image).resizable().scaledToFit().padding()
                        }
                    }
                    .navigationTitle(attachment.filename).navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { previewScreenshot = nil } } }
                }
            }
            .sheet(item: $composerDraft) { preparedDraft in
                FeedbackMailComposer(draft: preparedDraft) { result, error in
                    composerDraft = nil
                    if result == .sent || result == .saved { dismiss() }
                    else if result == .failed || error != nil { isShowingError = true }
                }.ignoresSafeArea()
            }
            .sheet(item: $sharePayload, onDismiss: cleanUpSharedFiles) { payload in
                FeedbackShareSheet(payload: payload) { sharePayload = nil }
            }
            .alert("Use another email app", isPresented: $isShowingShareExplanation) {
                Button("Cancel", role: .cancel) {}
                Button("Continue") { shareDraft() }
            } message: {
                Text("Apple Mail is not configured. Choose an email app from the share sheet, then use the recipient shown on the Feedback form. Your message is also included as feedback-message.txt, alongside every selected attachment. Check the recipient, message and attachments in your email app before sending.")
            }
            .alert("Email draft unavailable", isPresented: $isShowingError) {
                Button("OK", role: .cancel) {}
            } message: { Text("Your feedback has not been sent. Please try again. Your message and selections are still here.") }
            .onChange(of: appModel.authenticationFlowID) { _, _ in dismiss() }
            .onChange(of: appModel.session?.id) { _, _ in dismiss() }
            .onDisappear { cleanUpSharedFiles() }
        }
    }

    private var deviceDetails: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Unknown"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "Unknown"
        return "App: Hangar Express \(version) (\(build))\nDevice: \(UIDevice.current.model)\niOS: \(UIDevice.current.systemVersion)"
    }

    private var draft: FeedbackEmailDraft {
        FeedbackEmailDraft(recipient: FeedbackConfiguration.recipient ?? "",
            subject: subject.isEmpty ? AppLocalizer.string("Feedback") : subject, message: message,
            deviceDetails: includesDeviceDetails ? deviceDetails : nil,
            diagnosticReport: includesDiagnostics ? diagnosticReport : nil, screenshots: screenshots)
    }

    private func makeDiagnosticReport() -> String {
        let sessions = appModel.savedSessions + (appModel.session.map { [$0] } ?? [])
        return FeedbackDiagnosticsBuilder.build(auth: appModel.authDiagnostics, refresh: appModel.refreshDiagnostics,
            secrets: sessions.flatMap(DiagnosticPrivacy.sensitiveValues))
    }

    private func continueToEmail() {
        guard FeedbackConfiguration.recipient != nil else { isShowingError = true; return }
        if MFMailComposeViewController.canSendMail() { composerDraft = draft }
        else { isShowingShareExplanation = true }
    }

    private func shareDraft() {
        do {
            let payload = try FeedbackSharePayload.make(draft: draft)
            shareDirectory = payload.directory
            sharePayload = payload
        } catch { isShowingError = true }
    }

    private func cleanUpSharedFiles() {
        if let shareDirectory { try? FileManager.default.removeItem(at: shareDirectory) }
        shareDirectory = nil
    }

    private func removeScreenshot(_ attachment: FeedbackAttachment) {
        guard let index = screenshots.firstIndex(where: { $0.id == attachment.id }), selectedPhotos.indices.contains(index) else { return }
        selectedPhotos.remove(at: index)
        screenshots.remove(at: index)
    }

    private func loadScreenshots() async {
        let selection = selectedPhotos
        isLoadingScreenshots = !selection.isEmpty
        screenshotError = false
        screenshots = []
        do {
            var prepared: [FeedbackAttachment] = []
            for (index, photo) in selection.enumerated() {
                guard let data = try await photo.loadTransferable(type: Data.self) else {
                    throw FeedbackScreenshotProcessor.ProcessingError.invalidImage
                }
                try Task.checkCancellation()
                let attachment = try await Task.detached(priority: .userInitiated) {
                    try FeedbackScreenshotProcessor.attachment(from: data, number: index + 1)
                }.value
                try Task.checkCancellation()
                prepared.append(attachment)
            }
            guard !Task.isCancelled else { return }
            screenshots = prepared
            isLoadingScreenshots = false
        } catch {
            guard !Task.isCancelled else { return }
            screenshotError = true
            isLoadingScreenshots = false
        }
    }
}

private struct FeedbackTextPreview: View {
    let title: String
    let text: String
    var body: some View {
        ScrollView { Text(text).font(.system(.footnote, design: .monospaced)).textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading).padding() }
            .navigationTitle(AppLocalizer.string(title)).navigationBarTitleDisplayMode(.inline)
    }
}

private struct FeedbackInclusionOption: View {
    let title: String
    let identifier: String
    @Binding var isIncluded: Bool

    var body: some View {
        Button { isIncluded.toggle() } label: {
            HStack {
                Text(AppLocalizer.string(title)).foregroundStyle(.primary)
                Spacer()
                Image(systemName: isIncluded ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isIncluded ? Color.accentColor : Color.secondary)
            }
            .frame(minHeight: 32)
            .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(AppLocalizer.string(title))
        .accessibilityValue(AppLocalizer.string(isIncluded ? "Included" : "Not included"))
        .accessibilityIdentifier(identifier)
        .accessibilityAddTraits(isIncluded ? .isSelected : [])
    }
}
