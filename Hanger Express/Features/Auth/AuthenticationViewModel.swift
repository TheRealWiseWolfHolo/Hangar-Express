import Foundation
import Observation
import UIKit
import WebKit

@MainActor
@Observable
final class AuthenticationViewModel {
    enum Step {
        case signIn
        case twoFactor
    }

    struct BrowserChallenge: Identifiable, Hashable {
        let id = UUID()
        let message: String
        let loginIdentifier: String
        let password: String
    }

    var step: Step = .signIn
    var loginIdentifier = ""
    var password = ""
    var rememberMe = true
    var verificationCode = ""
    var deviceName = UIDevice.current.name
    var trustDuration: TrustedDeviceDuration = .year
    var noticeMessage: String?
    var errorMessage: String?
    var errorDebugDetails: String?
    var browserChallenge: BrowserChallenge?
    var isSubmitting = false

    private let appModel: AppModel
    private let authService: any AuthenticationServicing

    init(appModel: AppModel) {
        self.appModel = appModel
        authService = appModel.authService

        if let draft = appModel.consumePendingAuthenticationDraft() {
            loginIdentifier = draft.loginIdentifier
            password = draft.password
            rememberMe = draft.rememberMe
            noticeMessage = draft.notice
        }
    }

    func updateVerificationCode(_ code: String) {
        verificationCode = Self.normalizedVerificationCode(code)
    }

    func submitCredentials(forceBrowserLogin: Bool = false) async {
        guard !isSubmitting else {
            return
        }

        clearMessages()
        isSubmitting = true
        defer { isSubmitting = false }

        do {
            let result = try await authService.signIn(
                loginIdentifier: loginIdentifier,
                password: password,
                rememberMe: rememberMe,
                forceBrowserLogin: forceBrowserLogin
            )

            switch result {
            case let .authenticated(session):
                password = ""
                await appModel.completeAuthentication(session)
            case .requiresTwoFactor:
                step = .twoFactor
                verificationCode = ""
            case let .requiresBrowserChallenge(message):
                browserChallenge = BrowserChallenge(
                    message: message,
                    loginIdentifier: loginIdentifier,
                    password: password
                )
            }
        } catch {
            if case let AuthenticationError.requiresBrowserChallenge(message) = error {
                browserChallenge = BrowserChallenge(
                    message: message,
                    loginIdentifier: loginIdentifier,
                    password: password
                )
                return
            }

            showError(error)
        }
    }

    func submitVerificationCode() async {
        guard !isSubmitting else {
            return
        }

        clearMessages()
        verificationCode = Self.normalizedVerificationCode(verificationCode)
        isSubmitting = true
        defer { isSubmitting = false }

        do {
            let session = try await authService.submitTwoFactor(
                code: verificationCode,
                deviceName: deviceName,
                trustDuration: trustDuration
            )

            password = ""
            verificationCode = ""
            await appModel.completeAuthentication(session)
        } catch {
            if case let AuthenticationError.requiresBrowserChallenge(message) = error {
                browserChallenge = BrowserChallenge(
                    message: message,
                    loginIdentifier: loginIdentifier,
                    password: password
                )
                return
            }

            showError(error)
        }
    }

    func finishBrowserChallengeUsingCachedCookies(trustBrowserSession: Bool) async -> String? {
        guard !isSubmitting else {
            return "Hangar Express is already finishing the current sign-in attempt."
        }

        clearMessages()
        isSubmitting = true
        defer { isSubmitting = false }

        do {
            appModel.authDiagnostics.record(
                stage: "auth.browser-handoff",
                summary: "Finishing the in-app browser sign-in using the latest cookie export already cached by Hangar Express.",
                detail: "cookieSource=auth.browser-cache"
            )
            let session = try await authService.completeBrowserAuthentication(
                cookies: [],
                trustBrowserSession: trustBrowserSession
            )
            browserChallenge = nil
            password = ""
            verificationCode = ""
            await appModel.completeAuthentication(session)
            return nil
        } catch {
            let presentation = AuthenticationDebugFormatter.present(error)
            errorMessage = presentation.message
            errorDebugDetails = presentation.debugDetails
            if let debugDetails = presentation.debugDetails {
                return """
                \(presentation.message)

                \(debugDetails)
                """
            }
            return presentation.message
        }
    }

    func cancelBrowserChallenge() {
        browserChallenge = nil
        verificationCode = ""
        step = .signIn

        Task {
            await authService.cancelPendingAuthentication()
        }
    }

    func returnToSignIn() {
        clearMessages()
        verificationCode = ""
        step = .signIn

        Task {
            await authService.cancelPendingAuthentication()
        }
    }

    func loadDemoHangar() async {
        await appModel.enablePreviewSession()
    }

    private func showError(_ error: Error) {
        let presentation = AuthenticationDebugFormatter.present(error)
        errorMessage = presentation.message
        errorDebugDetails = presentation.debugDetails
    }

    private func clearMessages() {
        noticeMessage = nil
        errorMessage = nil
        errorDebugDetails = nil
    }

    nonisolated static func normalizedVerificationCode(_ code: String) -> String {
        let filteredScalars = code.unicodeScalars.filter { scalar in
            scalar.isASCII && (CharacterSet.alphanumerics.contains(scalar))
        }

        return String(String.UnicodeScalarView(filteredScalars)).uppercased()
    }
}

struct AuthenticationErrorPresentation: Sendable {
    let message: String
    let debugDetails: String?
}

enum AuthenticationDebugFormatter {
    nonisolated private static let javaScriptExceptionKeys = [
        "WKJavaScriptExceptionMessage",
        "WKJavaScriptExceptionLineNumber",
        "WKJavaScriptExceptionColumnNumber",
        "WKJavaScriptExceptionSourceURL"
    ]

    nonisolated static func present(_ error: Error) -> AuthenticationErrorPresentation {
        let debugDetails = debugDescription(for: error)
        let message = preferredMessage(for: error, debugDetails: debugDetails)

        return AuthenticationErrorPresentation(
            message: message,
            debugDetails: debugDetails == message ? nil : debugDetails
        )
    }

    nonisolated private static func preferredMessage(for error: Error, debugDetails: String) -> String {
        if let message = (error as? AuthenticationError)?.errorDescription?.trimmedNonEmpty {
            return message
        }

        let nsError = error as NSError

        if let javaScriptMessage = javaScriptSummary(from: nsError) {
            return javaScriptMessage
        }

        if let responseBody = rsiResponseBody(from: nsError) {
            let localizedDescription = nsError.localizedDescription.trimmedNonEmpty ?? "RSI returned an unexpected response."
            return "\(localizedDescription)\n\n\(responseBody)"
        }

        if let localizedDescription = nsError.localizedDescription.trimmedNonEmpty,
           !isGenericMessage(localizedDescription) {
            return localizedDescription
        }

        return debugDetails
    }

    nonisolated static func debugDescription(for error: Error) -> String {
        var lines: [String] = []
        append(error, title: "Error", into: &lines, indent: "")
        return lines.joined(separator: "\n")
    }

    nonisolated private static func append(_ error: Error, title: String, into lines: inout [String], indent: String) {
        let nsError = error as NSError

        lines.append("\(indent)\(title)")
        lines.append("\(indent)type: \(String(reflecting: type(of: error)))")
        lines.append("\(indent)localizedDescription: \(nsError.localizedDescription)")
        lines.append("\(indent)domain: \(nsError.domain)")

        if let codeName = webKitCodeName(for: nsError) {
            lines.append("\(indent)code: \(nsError.code) (\(codeName))")
        } else {
            lines.append("\(indent)code: \(nsError.code)")
        }

        let javaScriptDetails = javaScriptDetails(from: nsError)
        if !javaScriptDetails.isEmpty {
            lines.append("\(indent)javascriptDetails:")
            javaScriptDetails.forEach { lines.append("\(indent)- \($0)") }
        }

        let renderedUserInfo = renderUserInfo(nsError.userInfo)
        if !renderedUserInfo.isEmpty {
            lines.append("\(indent)userInfo:")
            renderedUserInfo.forEach { lines.append("\(indent)- \($0)") }
        }

        if let underlyingError = nsError.userInfo[NSUnderlyingErrorKey] as? Error {
            append(underlyingError, title: "Underlying Error", into: &lines, indent: indent + "  ")
        }
    }

    nonisolated private static func javaScriptDetails(from error: NSError) -> [String] {
        javaScriptExceptionKeys.compactMap { key in
            guard let value = error.userInfo[key] else {
                return nil
            }

            return "\(key): \(render(value))"
        }
    }

    nonisolated private static func renderUserInfo(_ userInfo: [String: Any]) -> [String] {
        userInfo.keys.sorted().compactMap { key in
            guard key != NSUnderlyingErrorKey else {
                return nil
            }

            guard let value = userInfo[key] else {
                return nil
            }

            return "\(key): \(render(value))"
        }
    }

    nonisolated private static func render(_ value: Any) -> String {
        if let error = value as? NSError {
            return "\(error.domain) (\(error.code)): \(error.localizedDescription)"
        }

        if let url = value as? URL {
            return url.absoluteString
        }

        if let array = value as? [Any] {
            return "[" + array.map(render).joined(separator: ", ") + "]"
        }

        if let dictionary = value as? [String: Any] {
            return "{" + dictionary.keys.sorted().map { key in
                let renderedValue = dictionary[key].map(render) ?? "nil"
                return "\(key): \(renderedValue)"
            }.joined(separator: ", ") + "}"
        }

        return String(describing: value)
    }

    nonisolated private static func webKitCodeName(for error: NSError) -> String? {
        guard error.domain == WKErrorDomain,
              let code = WKError.Code(rawValue: error.code) else {
            return nil
        }

        switch code {
        case .unknown:
            return "unknown"
        case .webContentProcessTerminated:
            return "webContentProcessTerminated"
        case .webViewInvalidated:
            return "webViewInvalidated"
        case .javaScriptExceptionOccurred:
            return "javaScriptExceptionOccurred"
        case .javaScriptResultTypeIsUnsupported:
            return "javaScriptResultTypeIsUnsupported"
        case .contentRuleListStoreCompileFailed:
            return "contentRuleListStoreCompileFailed"
        case .contentRuleListStoreLookUpFailed:
            return "contentRuleListStoreLookUpFailed"
        case .contentRuleListStoreRemoveFailed:
            return "contentRuleListStoreRemoveFailed"
        case .contentRuleListStoreVersionMismatch:
            return "contentRuleListStoreVersionMismatch"
        case .attributedStringContentFailedToLoad:
            return "attributedStringContentFailedToLoad"
        case .attributedStringContentLoadTimedOut:
            return "attributedStringContentLoadTimedOut"
        case .javaScriptInvalidFrameTarget:
            return "javaScriptInvalidFrameTarget"
        case .navigationAppBoundDomain:
            return "navigationAppBoundDomain"
        case .javaScriptAppBoundDomain:
            return "javaScriptAppBoundDomain"
        case .duplicateCredential:
            return "duplicateCredential"
        case .malformedCredential:
            return "malformedCredential"
        case .credentialNotFound:
            return "credentialNotFound"
        @unknown default:
            return "unknownFutureWKError"
        }
    }

    nonisolated private static func javaScriptSummary(from error: NSError) -> String? {
        guard let message = error.userInfo["WKJavaScriptExceptionMessage"] as? String else {
            return nil
        }

        let trimmedMessage = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedMessage.isEmpty else {
            return nil
        }

        var summary = "JavaScript error: \(trimmedMessage)"

        if let lineNumber = error.userInfo["WKJavaScriptExceptionLineNumber"] {
            summary.append(" (line \(render(lineNumber))")

            if let columnNumber = error.userInfo["WKJavaScriptExceptionColumnNumber"] {
                summary.append(", column \(render(columnNumber))")
            }

            summary.append(")")
        }

        return summary
    }

    nonisolated private static func rsiResponseBody(from error: NSError) -> String? {
        guard error.domain == "RSIAuthService",
              let rawBody = error.userInfo["RSIResponseBody"] as? String else {
            return nil
        }

        let trimmedBody = rawBody.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedBody.isEmpty else {
            return nil
        }

        return trimmedBody
    }

    nonisolated private static func isGenericMessage(_ message: String) -> Bool {
        let normalized = message.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized.isEmpty
            || normalized == "the operation couldn’t be completed."
            || normalized == "the operation could not be completed."
            || normalized == "unknown error"
    }
}

private extension String {
    nonisolated var trimmedNonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
