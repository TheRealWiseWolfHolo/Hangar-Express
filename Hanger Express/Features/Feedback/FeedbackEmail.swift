import Foundation
import ImageIO
import UniformTypeIdentifiers

nonisolated enum FeedbackConfiguration {
    static var recipient: String? {
        validatedRecipient(Bundle.main.object(forInfoDictionaryKey: "SupportEmailAddress") as? String)
    }

    static func validatedRecipient(_ value: String?) -> String? {
        guard let value, value.utf8.count <= 254,
              value.range(of: #"\A[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}\z"#,
                          options: .regularExpression) != nil else { return nil }
        return value
    }
}

nonisolated struct FeedbackAttachment: Identifiable, Sendable {
    let id = UUID()
    let filename: String
    let mimeType: String
    let data: Data
}

nonisolated struct FeedbackEmailDraft: Identifiable, Sendable {
    let id = UUID()
    let recipient: String
    let subject: String
    let message: String
    var deviceDetails: String? = nil
    var diagnosticReport: String? = nil
    var screenshots: [FeedbackAttachment] = []

    var emailSubject: String {
        "[Hangar Express] " + subject.components(separatedBy: .newlines)
            .joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines).prefix(120)
    }

    var attachments: [FeedbackAttachment] {
        var result = screenshots
        if let diagnosticReport {
            result.append(FeedbackAttachment(filename: "hangar-express-diagnostics.txt", mimeType: "text/plain",
                data: Data(diagnosticReport.utf8)))
        }
        return result
    }

    var emailBody: String {
        var lines = [message.trimmingCharacters(in: .whitespacesAndNewlines), "", "---", "Included with this feedback:"]
        if let deviceDetails { lines += [deviceDetails] }
        else { lines += ["App and device details: Not included"] }
        lines += ["Diagnostic log: " + (diagnosticReport == nil ? "Not included" : "Attached"),
                  "Screenshots: \(screenshots.count)"]
        if !attachments.isEmpty { lines += attachments.map { "Attachment: \($0.filename)" } }
        return lines.joined(separator: "\n")
    }
}

enum FeedbackDiagnosticsBuilder {
    static func build(auth: AuthenticationDiagnosticsStore, refresh: RefreshDiagnosticsStore,
                      secrets: [String], now: Date = .now) -> String {
        var lines = ["Hangar Express diagnostic log", "Generated UTC: \(ISO8601DateFormatter().string(from: now))",
                     "Sanitized authentication and refresh events. Review before sharing.", "", "Authentication events"]
        if auth.entries.isEmpty { lines.append("No authentication events recorded.") }
        for entry in auth.entries {
            lines.append(auth.redacted("[\(entry.timestampLabel)] \(entry.level.rawValue) \(entry.stage)\n\(entry.summary)"))
            if let detail = entry.detail { lines.append(auth.redacted(detail)) }
        }
        lines += ["", "Refresh events"]
        if refresh.entries.isEmpty { lines.append("No refresh events recorded.") }
        for entry in refresh.entries {
            lines.append(refresh.redacted("[\(entry.timestampLabel)] \(entry.level.rawValue) \(entry.stage)\n\(entry.summary)"))
            if let detail = entry.detail { lines.append(refresh.redacted(detail)) }
        }
        return DiagnosticPrivacy.report(lines, secrets: secrets)
    }
}

nonisolated enum FeedbackScreenshotProcessor {
    static let maximumCount = 3
    static let maximumInputBytes = 20 * 1_024 * 1_024
    static let maximumOutputBytes = 3 * 1_024 * 1_024
    static let maximumPixelSize = 2_048

    enum ProcessingError: Error { case invalidImage, tooLarge }

    /// Decode a bounded thumbnail and create a new JPEG from pixels only. Original
    /// filenames, GPS, EXIF, device metadata and additional frames are not copied.
    static func attachment(from data: Data, number: Int) throws -> FeedbackAttachment {
        guard data.count <= maximumInputBytes else { throw ProcessingError.tooLarge }
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else { throw ProcessingError.invalidImage }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw ProcessingError.invalidImage
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw ProcessingError.invalidImage }
        guard output.length <= maximumOutputBytes else { throw ProcessingError.tooLarge }
        return FeedbackAttachment(filename: "screenshot-\(number).jpg", mimeType: "image/jpeg", data: output as Data)
    }
}
