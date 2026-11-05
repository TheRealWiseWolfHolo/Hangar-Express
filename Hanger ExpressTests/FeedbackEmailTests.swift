import Foundation
import ImageIO
import Testing
import UIKit
import UniformTypeIdentifiers
@testable import Hanger_Express

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct FeedbackEmailTests {
    @Test func supportRecipientRequiresExplicitValidConfiguration() {
        #expect(FeedbackConfiguration.validatedRecipient("support@example.invalid") == "support@example.invalid")
        let invalidValues: [String?] = [nil, "", "$(SUPPORT_EMAIL_ADDRESS)", "not-an-email", "support@example.invalid\nBcc: other@example.invalid",
                                        " support@example.invalid", "support@example.invalid\r\n"]
        for value in invalidValues {
            #expect(FeedbackConfiguration.validatedRecipient(value) == nil)
        }
    }

    @Test func basicFeedbackContainsNoOptionalInformationOrAttachments() {
        let draft = FeedbackEmailDraft(recipient: "support@example.invalid", subject: "Question", message: "Please help with the app.")
        #expect(draft.recipient == "support@example.invalid")
        #expect(draft.attachments.isEmpty)
        #expect(draft.emailBody.contains("Diagnostic log: Not included"))
        #expect(draft.emailBody.contains("App and device details: Not included"))
        #expect(draft.emailBody.contains("Screenshots: 0"))
        #expect(!FleetTool.feedback.requiresEarlyAccess)
        #expect(FleetTool.feedback.isAvailable)
    }

    @Test func selectedAttachmentsMatchTheReviewedDataAndCanBeRemoved() {
        let picture = FeedbackAttachment(filename: "screenshot-1.jpg", mimeType: "image/jpeg", data: Data([1, 2, 3]))
        var draft = FeedbackEmailDraft(recipient: "support@example.invalid", subject: "Bug\nreport", message: "Steps to reproduce", deviceDetails: "App: fixture",
            diagnosticReport: "Reviewed diagnostic text", screenshots: [picture])
        #expect(!draft.emailSubject.contains("\n"))
        #expect(draft.attachments.count == 2)
        #expect(draft.attachments.first?.data == picture.data)
        #expect(draft.attachments.last?.data == Data("Reviewed diagnostic text".utf8))
        #expect(draft.emailBody.contains("Screenshots: 1"))
        #expect(draft.emailBody.contains("hangar-express-diagnostics.txt"))
        draft.deviceDetails = nil
        draft.diagnosticReport = nil
        draft.screenshots = []
        #expect(draft.attachments.isEmpty)
        #expect(!draft.emailBody.contains("App: fixture"))
        #expect(!draft.emailBody.contains("Reviewed diagnostic text"))
    }

    @Test func feedbackDiagnosticsAreBoundedAndRedactKnownAccountValues() {
        let auth = AuthenticationDiagnosticsStore(), refresh = RefreshDiagnosticsStore()
        auth.record(stage: "auth.fixture", summary: "password=private-password")
        refresh.record(stage: "refresh.fixture", summary: "fixture-account-name elapsed=2s", detail: "Cookie: private-cookie")
        let report = FeedbackDiagnosticsBuilder.build(auth: auth, refresh: refresh, secrets: ["fixture-account-name"])
        #expect(report.contains("elapsed=2s"))
        for secret in ["private-password", "private-cookie", "fixture-account-name"] { #expect(!report.contains(secret)) }
        for _ in 0..<120 { refresh.record(stage: "bounded", summary: String(repeating: "a", count: 1_000)) }
        #expect(FeedbackDiagnosticsBuilder.build(auth: auth, refresh: refresh, secrets: []).utf8.count <= DiagnosticPrivacy.maximumReportBytes)
    }

    @Test func screenshotsAreDownsampledAndReencodedWithoutOriginalMetadata() throws {
        let original = try imageFixture()
        let attachment = try FeedbackScreenshotProcessor.attachment(from: original, number: 1)
        #expect(attachment.filename == "screenshot-1.jpg")
        #expect(attachment.mimeType == "image/jpeg")
        let source = try #require(CGImageSourceCreateWithData(attachment.data as CFData, nil))
        let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any])
        #expect(properties[kCGImagePropertyGPSDictionary as String] == nil)
        #expect(properties[kCGImagePropertyIPTCDictionary as String] == nil)
        #expect(!String(decoding: attachment.data, as: UTF8.self).contains("private-caption"))
        let width = try #require(properties[kCGImagePropertyPixelWidth as String] as? Int)
        let height = try #require(properties[kCGImagePropertyPixelHeight as String] as? Int)
        #expect(max(width, height) <= FeedbackScreenshotProcessor.maximumPixelSize)
        #expect(width == 2_048 && height == 512)
    }

    @Test func invalidAndOversizedPicturesAreRejected() {
        #expect(throws: (any Error).self) { try FeedbackScreenshotProcessor.attachment(from: Data("not an image".utf8), number: 1) }
        #expect(throws: (any Error).self) {
            try FeedbackScreenshotProcessor.attachment(from: Data(repeating: 0, count: FeedbackScreenshotProcessor.maximumInputBytes + 1), number: 1)
        }
    }

    @Test func fallbackSharesEverySelectedAttachmentAndTheAddressedMessage() throws {
        let image = FeedbackAttachment(filename: "screenshot-1.jpg", mimeType: "image/jpeg", data: Data([1, 2, 3]))
        let draft = FeedbackEmailDraft(recipient: "support@example.invalid", subject: "Question", message: "Reviewed message",
            diagnosticReport: "Reviewed log", screenshots: [image])
        let payload = try FeedbackSharePayload.make(draft: draft)
        defer { try? FileManager.default.removeItem(at: payload.directory) }
        #expect(payload.urls.count == 3)
        let message = try String(contentsOf: payload.urls[0], encoding: .utf8)
        #expect(message.contains("To: support@example.invalid"))
        #expect(message.contains(draft.emailBody))
        #expect(try Data(contentsOf: payload.urls[1]) == image.data)
        #expect(try Data(contentsOf: payload.urls[2]) == Data("Reviewed log".utf8))
        #expect(try payload.directory.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
    }

    @Test func fallbackRejectsUnconfiguredRecipients() {
        let draft = FeedbackEmailDraft(recipient: "", subject: "Question", message: "Private message")
        #expect(throws: (any Error).self) { try FeedbackSharePayload.make(draft: draft) }
    }

    private func imageFixture() throws -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: 4_096, height: 1_024), format: format).image { context in
            UIColor.blue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 4_096, height: 1_024))
        }
        let output = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try #require(image.cgImage), [
            kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 12.5, kCGImagePropertyGPSLatitudeRef: "N"],
            kCGImagePropertyIPTCDictionary: [kCGImagePropertyIPTCCaptionAbstract: "private-caption"]
        ] as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
        return output as Data
    }
}
