import Foundation

actor PreviewAuthenticationService: AuthenticationServicing {
    private var pendingLoginIdentifier: String?
    private var pendingPassword: String?
    private let diagnostics: AuthenticationDiagnosticsStore

    init(diagnostics: AuthenticationDiagnosticsStore) {
        self.diagnostics = diagnostics
    }

    func signIn(
        loginIdentifier: String,
        password: String,
        rememberMe: Bool,
        forceBrowserLogin: Bool
    ) async throws -> SignInOutcome {
        let trimmedLoginIdentifier = loginIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedLoginIdentifier.isEmpty, !password.isEmpty else {
            await log(
                stage: "preview.sign-in",
                summary: "Preview sign-in was blocked because credentials were incomplete.",
                level: .warning
            )
            throw AuthenticationError.invalidInput("Enter your RSI email or Login ID and password to continue.")
        }

        await log(
            stage: "preview.sign-in",
            summary: "Running the preview sign-in flow.",
            detail: "loginIdentifier=\(maskedIdentifier(trimmedLoginIdentifier)), forceBrowserLogin=\(forceBrowserLogin)"
        )
        pendingLoginIdentifier = trimmedLoginIdentifier
        pendingPassword = password

        if forceBrowserLogin {
            return .requiresBrowserChallenge(
                "Forced browser login is enabled. Continue in the in-app browser to finish signing in."
            )
        }

        return .requiresTwoFactor
    }

    func submitTwoFactor(code: String, deviceName: String, trustDuration: TrustedDeviceDuration) async throws -> UserSession {
        guard let pendingLoginIdentifier, let pendingPassword else {
            await log(
                stage: "preview.two-factor",
                summary: "Preview verification expired before a pending sign-in could be completed.",
                level: .warning
            )
            throw AuthenticationError.pendingVerificationExpired
        }

        await log(
            stage: "preview.two-factor",
            summary: "Completing the preview verification flow."
        )
        let handle = pendingLoginIdentifier.split(separator: "@").first.map(String.init) ?? pendingLoginIdentifier
        self.pendingLoginIdentifier = nil
        self.pendingPassword = nil

        return UserSession(
            handle: handle,
            displayName: handle,
            email: pendingLoginIdentifier,
            authMode: .developerPreview,
            notes: "Preview authentication completed without contacting RSI.",
            credentials: AccountCredentials(loginIdentifier: pendingLoginIdentifier, password: pendingPassword),
            cookies: [],
            createdAt: .now
        )
    }

    func completeBrowserAuthentication(cookies: [SessionCookie], trustBrowserSession: Bool) async throws -> UserSession {
        guard let pendingLoginIdentifier, let pendingPassword else {
            await log(
                stage: "preview.browser",
                summary: "Preview browser completion expired before a pending sign-in could be completed.",
                level: .warning
            )
            throw AuthenticationError.pendingVerificationExpired
        }

        await log(
            stage: "preview.browser",
            summary: "Completing preview browser authentication.",
            detail: "cookieCount=\(cookies.count)"
        )
        let handle = pendingLoginIdentifier.split(separator: "@").first.map(String.init) ?? pendingLoginIdentifier
        self.pendingLoginIdentifier = nil
        self.pendingPassword = nil

        return UserSession(
            handle: handle,
            displayName: handle,
            email: pendingLoginIdentifier,
            authMode: .developerPreview,
            notes: "Preview browser authentication completed without contacting RSI.",
            credentials: AccountCredentials(loginIdentifier: pendingLoginIdentifier, password: pendingPassword),
            cookies: cookies,
            createdAt: .now
        )
    }

    func rememberBrowserExportedCookies(_ cookies: [SessionCookie]) async {
        await log(
            stage: "preview.browser",
            summary: "Preview auth remembered cookies exported from the in-app browser.",
            detail: "cookieCount=\(cookies.count)"
        )
    }

    func canCompleteBrowserAuthentication(cookies: [SessionCookie]) async -> Bool {
        pendingLoginIdentifier != nil && pendingPassword != nil
    }

    func cancelPendingAuthentication() async {
        pendingLoginIdentifier = nil
        pendingPassword = nil
        await log(
            stage: "preview.cancel",
            summary: "Cancelled the preview sign-in flow."
        )
    }

    private func log(
        stage: String,
        summary: String,
        detail: String? = nil,
        level: AuthenticationDiagnosticsStore.Entry.Level = .info
    ) async {
        await MainActor.run {
            diagnostics.record(stage: stage, summary: summary, detail: detail, level: level)
        }
    }

    private func maskedIdentifier(_ value: String) -> String {
        guard let atIndex = value.firstIndex(of: "@") else {
            let prefix = String(value.prefix(2))
            return prefix + String(repeating: "*", count: max(0, value.count - prefix.count))
        }

        let name = String(value[..<atIndex])
        let domain = String(value[atIndex...])
        let visiblePrefix = String(name.prefix(2))
        return visiblePrefix + String(repeating: "*", count: max(0, name.count - visiblePrefix.count)) + domain
    }
}
