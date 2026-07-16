import SwiftUI
import UIKit

struct AuthenticationFlowView: View {
    let appModel: AppModel

    @AppStorage(AppLanguage.storageKey) private var appLanguageRawValue = AppLanguage.system.rawValue
    @AppStorage("auth.debug.showFullErrors") private var showsFullErrorDetails = false
    @AppStorage("auth.forceBrowserLogin") private var forcesBrowserLogin = false
    @State private var isShowingClearKeychainAlert = false
    @State private var didCopyAuthDebugReport = false
    @State private var signInRoute: AuthenticationSignInRoute = .checkingIP
    @State private var viewModel: AuthenticationViewModel

    init(appModel: AppModel) {
        self.appModel = appModel
        _viewModel = State(initialValue: AuthenticationViewModel(appModel: appModel))
    }

    var body: some View {
        ZStack {
            NavigationStack {
                Form {
                    Section {
                        Text("This is an unofficial Star Citizen fan app and is not affiliated with the Cloud Imperium group of companies.")
                            .font(.subheadline.weight(.semibold))
                    } header: {
                        Text("RSI Login")
                    }

                    if let noticeMessage = viewModel.noticeMessage {
                        Section {
                            Text(noticeMessage)
                                .foregroundStyle(.orange)
                        }
                    }

                    if let errorMessage = viewModel.errorMessage {
                        Section {
                            Text(errorMessage)
                                .foregroundStyle(.red)

                            if showsFullErrorDetails, let errorDebugDetails = viewModel.errorDebugDetails {
                                Text(verbatim: errorDebugDetails)
                                    .font(.system(.footnote, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                            }

                            Button("Copy Auth Debug Report") {
                                copyAuthDebugReport()
                            }
                            .disabled(authDebugReport.isEmpty)
                        }
                    }

                    switch viewModel.step {
                    case .signIn:
                        if !quickLoginSessions.isEmpty {
                            savedAccountsSection
                        }
                        signInSection
                    case .twoFactor:
                        twoFactorSection
                    }

#if DEBUG
                    Section {
                        Button("Load Demo Hangar") {
                            Task {
                                await viewModel.loadDemoHangar()
                            }
                        }
                    }
#endif

                    Section {
                        Toggle("Show Full Auth Errors", isOn: $showsFullErrorDetails)

                        Button("Remove Saved Keychain Content", role: .destructive) {
                            isShowingClearKeychainAlert = true
                        }
                        .disabled(viewModel.isSubmitting)
                    } header: {
                        Text("Advanced")
                    } footer: {
                        Text("Removes every saved RSI account, its stored cookies, and saved credentials from Keychain without touching your local image or hangar cache.")
                    }

                    Section {
                        Text("Star Citizen, Squadron 42, Roberts Space Industries, and related names, ships, artwork, and other game content shown or referenced by this app belong to the Cloud Imperium group of companies and their respective owners.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                .id(appLanguageRawValue)
                .navigationTitle("Hangar Express")
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        AppLanguageMenuButton()
                    }
                }
            }

            if let signInPreparationOverlayDetail {
                StartupWarmupOverlay(
                    title: "Preparing Sign-In",
                    detail: signInPreparationOverlayDetail
                )
            }
        }
        .background(recaptchaBridge)
        .task {
            await resolveInitialSignInRoute()
        }
        .sheet(item: browserChallengeBinding) { challenge in
            AuthenticationBrowserChallengeView(
                challenge: challenge,
                diagnostics: appModel.authDiagnostics,
                authService: appModel.authService,
                isFinishingAuthentication: viewModel.isSubmitting,
                onCancel: {
                    viewModel.cancelBrowserChallenge()
                },
                onAuthenticationAttempt: { trustBrowserSession in
                    await viewModel.finishBrowserChallengeUsingCachedCookies(
                        trustBrowserSession: trustBrowserSession
                    )
                }
            )
        }
        .alert("Remove Saved Keychain Content?", isPresented: $isShowingClearKeychainAlert) {
            Button("Cancel", role: .cancel) {}
            Button("Remove", role: .destructive) {
                Task {
                    await appModel.clearSavedKeychainContent()
                }
            }
        } message: {
            Text("This removes every saved RSI account, stored cookie, and saved credential from Keychain. You will need to sign in again for any saved account you want to use.")
        }
        .alert("Auth Debug Report Copied", isPresented: $didCopyAuthDebugReport) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("The full auth debug report was copied to the clipboard so a tester can paste it into a message.")
        }
    }

    private var signInSection: some View {
        Section {
            TextField("RSI Email or Login ID", text: $viewModel.loginIdentifier)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.asciiCapable)
                .textContentType(.username)

            SecureField("Password", text: $viewModel.password)
                .textContentType(.password)

            Toggle("Keep me signed in", isOn: $viewModel.rememberMe)

            Toggle("Force Browser Login", isOn: $forcesBrowserLogin)

            Button("Continue") {
                Task {
                    await viewModel.submitCredentials(
                        forceBrowserLogin: shouldUseBrowserAssistedLogin
                    )
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(viewModel.isSubmitting || (signInRoute.isCheckingIP && !forcesBrowserLogin))
        } header: {
            Text("Credentials")
        }
    }

    @ViewBuilder
    private var recaptchaBridge: some View {
        if shouldInitializeRecaptchaBridge {
            RecaptchaBridgeView(broker: appModel.recaptchaBroker)
                .frame(width: 1, height: 1)
                .opacity(0.01)
                .allowsHitTesting(false)
        }
    }

    private var savedAccountsSection: some View {
        Section {
            SavedQuickLoginRows(
                sessions: quickLoginSessions,
                isDisabled: viewModel.isSubmitting,
                onSelect: { session in
                    Task {
                        await appModel.openSavedAccount(id: session.id)
                    }
                },
                onRemove: { session in
                    Task {
                        await appModel.removeSavedAccount(id: session.id)
                    }
                }
            )
        } header: {
            Text("Saved Accounts")
        } footer: {
            Text("Pick a saved RSI account to reuse its stored cookies, or jump back into sign-in with its stored credentials if the session needs to be refreshed. Swipe left on an account to remove it.")
        }
    }

    private var twoFactorSection: some View {
        Section {
            TextField("Verification Code", text: verificationCodeBinding)
                .keyboardType(.asciiCapable)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
                .textContentType(.oneTimeCode)

            TextField("Device Name", text: $viewModel.deviceName)
                .textInputAutocapitalization(.words)

            Picker("Remember This Device", selection: $viewModel.trustDuration) {
                ForEach(TrustedDeviceDuration.allCases) { duration in
                    Text(duration.displayName)
                        .tag(duration)
                }
            }

            Button("Verify") {
                Task {
                    await viewModel.submitVerificationCode()
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(viewModel.isSubmitting)

            Button("Back to Sign In") {
                viewModel.returnToSignIn()
            }
            .disabled(viewModel.isSubmitting)
        } header: {
            Text("Verification")
        }
    }

    private var verificationCodeBinding: Binding<String> {
        Binding(
            get: { viewModel.verificationCode },
            set: { viewModel.updateVerificationCode($0) }
        )
    }

    private var quickLoginSessions: [UserSession] {
        appModel.quickLoginSessions
    }

    private var shouldInitializeRecaptchaBridge: Bool {
        signInRoute == .browserlessHelper && !appModel.recaptchaBroker.prefersBrowserAssistedLogin
    }

    private var shouldUseBrowserAssistedLogin: Bool {
        forcesBrowserLogin || signInRoute.usesBrowserAssistedLogin || appModel.recaptchaBroker.prefersBrowserAssistedLogin
    }

    private var signInPreparationOverlayDetail: String? {
        if signInRoute.isCheckingIP {
            return "Checking your sign-in connection."
        }

        if appModel.recaptchaBroker.isPreparing, shouldInitializeRecaptchaBridge {
            return appModel.recaptchaBroker.statusMessage
        }

        return nil
    }

    private var browserChallengeBinding: Binding<AuthenticationViewModel.BrowserChallenge?> {
        Binding(
            get: { viewModel.browserChallenge },
            set: { newValue in
                if let newValue {
                    viewModel.browserChallenge = newValue
                } else {
                    viewModel.cancelBrowserChallenge()
                }
            }
        )
    }

    private var authDebugReport: String {
        AuthenticationDebugReportBuilder.build(
            diagnostics: appModel.authDiagnostics.entries,
            step: viewModel.step,
            noticeMessage: viewModel.noticeMessage,
            errorMessage: viewModel.errorMessage,
            errorDebugDetails: viewModel.errorDebugDetails,
            loginIdentifier: viewModel.loginIdentifier,
            rememberMe: viewModel.rememberMe,
            showsFullErrors: showsFullErrorDetails,
            browserChallengeIsPresented: viewModel.browserChallenge != nil,
            helperIsPreparing: appModel.recaptchaBroker.isPreparing,
            helperStatusMessage: appModel.recaptchaBroker.statusMessage,
            forceBrowserLogin: forcesBrowserLogin,
            signInRoute: signInRoute.debugLabel,
            helperPrefersBrowserAssistedLogin: appModel.recaptchaBroker.prefersBrowserAssistedLogin
        )
    }

    private func resolveInitialSignInRoute() async {
        guard signInRoute == .checkingIP else {
            return
        }

        let result = await appModel.authIPRegionChecker.currentRegion()

        guard !Task.isCancelled else {
            return
        }

        let countryCode = result.countryCode ?? "unknown"
        if result.isMainlandChina {
            signInRoute = .browserAssisted(reason: .mainlandChinaIP)
            appModel.authDiagnostics.record(
                stage: "auth.ip-region",
                summary: "The public IP check resolved to mainland China, so Hangar Express will use browser-assisted sign-in.",
                detail: "countryCode=\(countryCode)"
            )
        } else {
            signInRoute = .browserlessHelper
            appModel.authDiagnostics.record(
                stage: "auth.ip-region",
                summary: "The public IP check did not require browser-assisted sign-in, so Hangar Express will prepare the RSI verification helper.",
                detail: ipRegionDebugDetail(for: result)
            )
        }
    }

    private func ipRegionDebugDetail(for result: AuthenticationIPRegionCheckResult) -> String {
        var parts = [
            "countryCode=\(result.countryCode ?? "unknown")"
        ]

        if let errorDescription = result.errorDescription, !errorDescription.isEmpty {
            parts.append("error=\(errorDescription)")
        }

        return parts.joined(separator: ", ")
    }

    private func copyAuthDebugReport() {
        UIPasteboard.general.string = authDebugReport
        didCopyAuthDebugReport = true
    }
}

private enum AuthenticationSignInRoute: Equatable {
    case checkingIP
    case browserlessHelper
    case browserAssisted(reason: BrowserAssistedReason)

    enum BrowserAssistedReason: Equatable {
        case mainlandChinaIP
    }

    var isCheckingIP: Bool {
        self == .checkingIP
    }

    var usesBrowserAssistedLogin: Bool {
        if case .browserAssisted = self {
            return true
        }

        return false
    }

    var debugLabel: String {
        switch self {
        case .checkingIP:
            return "checking-ip"
        case .browserlessHelper:
            return "browserless-helper"
        case let .browserAssisted(reason):
            switch reason {
            case .mainlandChinaIP:
                return "browser-assisted-mainland-china-ip"
            }
        }
    }
}

private struct SavedQuickLoginRows: View {
    let sessions: [UserSession]
    let isDisabled: Bool
    let onSelect: (UserSession) -> Void
    let onRemove: (UserSession) -> Void

    var body: some View {
        ForEach(sessions, id: \.id) { session in
            SavedQuickLoginButton(session: session, isDisabled: isDisabled) {
                onSelect(session)
            }
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                Button("Remove", role: .destructive) {
                    onRemove(session)
                }
                .disabled(isDisabled)
            }
        }
    }
}

private struct SavedQuickLoginButton: View {
    let session: UserSession
    let isDisabled: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(session.displayName)
                        .font(.headline)
                        .foregroundStyle(.primary)

                    Text(session.credentials?.loginIdentifier ?? session.email)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 12)

                Text("Use Saved")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
            }
            .padding(.vertical, 2)
        }
        .disabled(isDisabled)
    }
}

private enum AuthenticationDebugReportBuilder {
    static func build(
        diagnostics: [AuthenticationDiagnosticsStore.Entry],
        step: AuthenticationViewModel.Step,
        noticeMessage: String?,
        errorMessage: String?,
        errorDebugDetails: String?,
        loginIdentifier: String,
        rememberMe: Bool,
        showsFullErrors: Bool,
        browserChallengeIsPresented: Bool,
        helperIsPreparing: Bool,
        helperStatusMessage: String,
        forceBrowserLogin: Bool,
        signInRoute: String,
        helperPrefersBrowserAssistedLogin: Bool
    ) -> String {
        var lines: [String] = []

        lines.append("Hangar Express Auth Debug Report")
        lines.append("Generated: \(timestampFormatter.string(from: .now))")
        lines.append("App: \(appVersionLabel)")
        lines.append("Device: \(deviceLabel)")
        lines.append("iOS: \(UIDevice.current.systemVersion)")
        lines.append("Login Step: \(stepLabel(for: step))")
        lines.append("Login Identifier: \(maskedIdentifier(loginIdentifier))")
        lines.append("Remember Me: \(rememberMe)")
        lines.append("Show Full Auth Errors: \(showsFullErrors)")
        lines.append("Force Browser Login: \(forceBrowserLogin)")
        lines.append("Browser Challenge Visible: \(browserChallengeIsPresented)")
        lines.append("Sign-In Route: \(signInRoute)")
        lines.append("Recaptcha Helper Preparing: \(helperIsPreparing)")
        lines.append("Recaptcha Helper Status: \(helperStatusMessage)")
        lines.append("Recaptcha Helper Browser-Assisted Fallback: \(helperPrefersBrowserAssistedLogin)")

        if let noticeMessage, !noticeMessage.isEmpty {
            lines.append("")
            lines.append("Notice")
            lines.append(noticeMessage)
        }

        if let errorMessage, !errorMessage.isEmpty {
            lines.append("")
            lines.append("Visible Error")
            lines.append(errorMessage)
        }

        if let errorDebugDetails, !errorDebugDetails.isEmpty {
            lines.append("")
            lines.append("Expanded Error Details")
            lines.append(errorDebugDetails)
        }

        lines.append("")
        lines.append("Diagnostics")

        if diagnostics.isEmpty {
            lines.append("No auth diagnostics were recorded in this session.")
        } else {
            for entry in diagnostics {
                lines.append("[\(entry.timestampLabel)] \(entry.level.rawValue) \(entry.stage)")
                lines.append(entry.summary)

                if let detail = entry.detail, !detail.isEmpty {
                    lines.append(detail)
                }

                lines.append("")
            }

            if lines.last?.isEmpty == true {
                lines.removeLast()
            }
        }

        return lines.joined(separator: "\n")
    }

    private static var timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss ZZZZ"
        return formatter
    }()

    private static var appVersionLabel: String {
        let shortVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let buildVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String

        switch (shortVersion?.trimmedNonEmpty, buildVersion?.trimmedNonEmpty) {
        case let (.some(shortVersion), .some(buildVersion)):
            return "\(shortVersion) (\(buildVersion))"
        case let (.some(shortVersion), nil):
            return shortVersion
        case let (nil, .some(buildVersion)):
            return buildVersion
        default:
            return "Unknown"
        }
    }

    private static var deviceLabel: String {
        let current = UIDevice.current
        return "\(current.model) [\(current.userInterfaceIdiom.debugName)]"
    }

    private static func stepLabel(for step: AuthenticationViewModel.Step) -> String {
        switch step {
        case .signIn:
            return "Sign In"
        case .twoFactor:
            return "Verification"
        }
    }

    private static func maskedIdentifier(_ value: String) -> String {
        let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedValue.isEmpty else {
            return "Empty"
        }

        guard let atIndex = trimmedValue.firstIndex(of: "@") else {
            let prefix = String(trimmedValue.prefix(2))
            return prefix + String(repeating: "*", count: max(0, trimmedValue.count - prefix.count))
        }

        let name = String(trimmedValue[..<atIndex])
        let domain = String(trimmedValue[atIndex...])
        let visiblePrefix = String(name.prefix(2))
        return visiblePrefix + String(repeating: "*", count: max(0, name.count - visiblePrefix.count)) + domain
    }
}

private extension String {
    var trimmedNonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

private extension UIUserInterfaceIdiom {
    var debugName: String {
        switch self {
        case .phone:
            return "phone"
        case .pad:
            return "pad"
        case .tv:
            return "tv"
        case .carPlay:
            return "carPlay"
        case .vision:
            return "vision"
        case .mac:
            return "mac"
        default:
            return "unspecified"
        }
    }
}
