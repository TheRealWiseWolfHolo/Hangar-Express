import Foundation
import Observation
import WebKit

@MainActor
@Observable
final class AuthenticationViewModel {
    enum Step {
        case signIn
        case captcha
        case twoFactor
    }

    struct BrowserChallenge: Identifiable, Hashable {
        let id = UUID()
        let flowID: UUID
        let message: String
        let loginIdentifier: String
        let password: String
    }

    var step: Step = .signIn
    var loginIdentifier = ""
    var password = ""
    var verificationCode = ""
    var captchaCode = ""
    var captchaImageData: Data?
    var deviceName = AuthorizedDevice.hangarExpressDeviceName
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
            noticeMessage = draft.notice
        }
    }

    private var requestID = UUID()
    private func isCurrentRequest(_ id: UUID, flowID: UUID) -> Bool {
        requestID == id && appModel.authenticationFlowID == flowID && !Task.isCancelled
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
        let id = UUID()
        requestID = id
        let flowID = appModel.authenticationFlowID
        defer { if requestID == id { isSubmitting = false } }

        do {
            let result = try await authService.signIn(
                loginIdentifier: loginIdentifier,
                password: password,
                rememberMe: true,
                forceBrowserLogin: forceBrowserLogin
            )

            guard isCurrentRequest(id, flowID: flowID) else { return }
            await handle(result, browserLoginIdentifier: loginIdentifier, browserPassword: password, flowID: flowID)
        } catch {
            guard isCurrentRequest(id, flowID: flowID) else { return }
            if case let AuthenticationError.requiresBrowserChallenge(message) = error {
                browserChallenge = BrowserChallenge(
                    flowID: flowID,
                    message: message,
                    loginIdentifier: loginIdentifier,
                    password: password
                )
                return
            }

            showError(error)
        }
    }

    func submitCaptcha() async {
        guard !isSubmitting else { return }
        clearMessages()
        isSubmitting = true
        let id = UUID()
        requestID = id
        let flowID = appModel.authenticationFlowID
        defer { if requestID == id { isSubmitting = false } }

        do {
            let result = try await authService.submitCaptcha(captchaCode)
            guard isCurrentRequest(id, flowID: flowID) else { return }
            await handle(result, browserLoginIdentifier: loginIdentifier, browserPassword: password, flowID: flowID)
        } catch {
            guard isCurrentRequest(id, flowID: flowID) else { return }
            showError(error)
        }
    }

    func beginReadOnlySignIn() async {
        guard !isSubmitting else { return }
        clearMessages()
        isSubmitting = true
        let id = UUID()
        requestID = id
        let flowID = appModel.authenticationFlowID
        defer { if requestID == id { isSubmitting = false } }

        do {
            let result = try await authService.beginReadOnlySignIn()
            guard isCurrentRequest(id, flowID: flowID) else { return }
            await handle(result, browserLoginIdentifier: "", browserPassword: "", flowID: flowID)
        } catch {
            guard isCurrentRequest(id, flowID: flowID) else { return }
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
        let id = UUID()
        requestID = id
        let flowID = appModel.authenticationFlowID
        defer { if requestID == id { isSubmitting = false } }

        do {
            let session = try await authService.submitTwoFactor(
                code: verificationCode,
                deviceName: deviceName,
                trustDuration: .year
            )

            guard isCurrentRequest(id, flowID: flowID) else { return }
            password = ""
            verificationCode = ""
            await appModel.completeAuthentication(session, expectedFlowID: flowID)
        } catch {
            guard isCurrentRequest(id, flowID: flowID) else { return }
            if case let AuthenticationError.requiresBrowserChallenge(message) = error {
                browserChallenge = BrowserChallenge(
                    flowID: flowID,
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
            return AppLocalizer.string("Hangar Express is already finishing the current sign-in attempt.")
        }

        clearMessages()
        isSubmitting = true
        let id = UUID()
        requestID = id
        let flowID = appModel.authenticationFlowID
        defer { if requestID == id { isSubmitting = false } }

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
            guard isCurrentRequest(id, flowID: flowID) else { return AppLocalizer.string("Sign-in was cancelled.") }
            browserChallenge = nil
            password = ""
            verificationCode = ""
            await appModel.completeAuthentication(session, expectedFlowID: flowID)
            return nil
        } catch {
            guard isCurrentRequest(id, flowID: flowID) else { return AppLocalizer.string("Sign-in was cancelled.") }
            let presentation = AuthenticationDebugFormatter.present(error)
            errorMessage = appModel.authDiagnostics.redacted(presentation.message)
            errorDebugDetails = presentation.debugDetails.map(appModel.authDiagnostics.redacted)
            if let debugDetails = presentation.debugDetails {
                return appModel.authDiagnostics.redacted(presentation.message + "\n\n" + debugDetails)
            }
            return appModel.authDiagnostics.redacted(presentation.message)
        }
    }

    func cancelBrowserChallenge() {
        password = ""
        requestID = UUID()
        browserChallenge = nil
        verificationCode = ""
        captchaCode = ""
        captchaImageData = nil
        step = .signIn

        let cancellationID = requestID
        isSubmitting = true
        Task {
            await authService.cancelPendingAuthentication()
            if requestID == cancellationID { isSubmitting = false }
        }
    }

    func returnToSignIn() {
        password = ""
        requestID = UUID()
        clearMessages()
        verificationCode = ""
        captchaCode = ""
        captchaImageData = nil
        step = .signIn

        let cancellationID = requestID
        isSubmitting = true
        Task {
            await authService.cancelPendingAuthentication()
            if requestID == cancellationID { isSubmitting = false }
        }
    }

    private func handle(
        _ result: SignInOutcome,
        browserLoginIdentifier: String,
        browserPassword: String,
        flowID: UUID
    ) async {
        guard flowID == appModel.authenticationFlowID else { return }
        switch result {
        case let .authenticated(session):
            password = ""
            captchaCode = ""
            captchaImageData = nil
            await appModel.completeAuthentication(session, expectedFlowID: flowID)
        case let .requiresCaptcha(imageData):
            captchaImageData = imageData
            captchaCode = ""
            step = .captcha
        case .requiresTwoFactor:
            step = .twoFactor
            verificationCode = ""
        case let .requiresBrowserChallenge(message):
            browserChallenge = BrowserChallenge(
                flowID: flowID,
                message: message,
                loginIdentifier: browserLoginIdentifier,
                password: browserPassword
            )
        }
    }

    func loadDemoHangar() async {
        await appModel.enablePreviewSession()
    }

    private func showError(_ error: Error) {
        let presentation = AuthenticationDebugFormatter.present(error)
        errorMessage = appModel.authDiagnostics.redacted(presentation.message)
        errorDebugDetails = presentation.debugDetails.map(appModel.authDiagnostics.redacted)
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
    nonisolated static func present(_ error: Error) -> AuthenticationErrorPresentation {
        let debugDetails = debugDescription(for: error)
        let message = preferredMessage(for: error, debugDetails: debugDetails)

        return AuthenticationErrorPresentation(
            message: DiagnosticPrivacy.text(message),
            debugDetails: debugDetails == message ? nil : DiagnosticPrivacy.text(debugDetails)
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

        if let localizedDescription = nsError.localizedDescription.trimmedNonEmpty,
           !isGenericMessage(localizedDescription) {
            return localizedDescription
        }

        return debugDetails
    }

    nonisolated static func debugDescription(for error: Error) -> String {
        let nsError = error as NSError
        var lines = ["Error", "type: \(String(reflecting: type(of: error)))"]
        if let name = webKitCodeName(for: nsError) { lines.append("webKitCode=\(name)") }
        lines += RSINetworkDiagnostics.errorLines(error)
        if let message = nsError.userInfo["WKJavaScriptExceptionMessage"] as? String {
            lines.append("javascriptMessage: \(DiagnosticPrivacy.text(message, limit: 2_048))")
        }
        for key in ["WKJavaScriptExceptionLineNumber", "WKJavaScriptExceptionColumnNumber"] {
            if let value = nsError.userInfo[key] as? NSNumber { lines.append("\(key): \(value)") }
        }
        return DiagnosticPrivacy.report(lines)
    }

    nonisolated private static func render(_ value: Any) -> String {
        (value as? NSNumber)?.stringValue ?? "unavailable"
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
