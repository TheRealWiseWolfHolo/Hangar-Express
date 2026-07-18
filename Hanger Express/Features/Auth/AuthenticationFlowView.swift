import SwiftUI
import UIKit

struct AuthenticationFlowView: View {
    let appModel: AppModel

    @AppStorage(AppLanguage.storageKey) private var appLanguageRawValue = AppLanguage.system.rawValue
    @AppStorage("auth.debug.showFullErrors") private var showsFullErrorDetails = false
    @FocusState private var focusedField: InputField?
    @State private var isShowingClearKeychainAlert = false
    @State private var didCopyAuthDebugReport = false
    @State private var isShowingAdvanced = false
    @State private var isShowingSavedAccounts = false
    @State private var passwordInfoTopic: PasswordInfoTopic?
    @State private var viewModel: AuthenticationViewModel

    private enum InputField: Hashable {
        case loginIdentifier
        case password
        case captcha
        case verificationCode
        case deviceName
    }

    private enum PasswordInfoTopic: String, Identifiable {
        case standard
        case readOnly

        var id: Self { self }

        var title: LocalizedStringKey {
            switch self {
            case .standard:
                return "Your Password is Secured"
            case .readOnly:
                return "Read-Only Login"
            }
        }

        var message: LocalizedStringKey {
            switch self {
            case .standard:
                return "Your password is stored securely in this device's Keychain and used only to sign in and authenticate with RSI services. It is never shared with the app developer or any third-party service."
            case .readOnly:
                return "Read-only login opens an RSI browser session. You enter your password directly on RSI's website, so it is never visible to or saved by Hangar Express. Password-confirmed features—including gifting, melting, applying upgrades, character repair, and device management—are disabled for this account."
            }
        }
    }

    init(appModel: AppModel) {
        self.appModel = appModel
        _viewModel = State(initialValue: AuthenticationViewModel(appModel: appModel))
    }

    var body: some View {
        NavigationStack {
            ZStack(alignment: .top) {
                AuthenticationBackground()

                authenticationContent
            }
            .id(appLanguageRawValue)
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    AppLanguageMenuButton()
                }
            }
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
        .alert(item: $passwordInfoTopic) { topic in
            Alert(
                title: Text(topic.title),
                message: Text(topic.message),
                dismissButton: .default(Text("OK"))
            )
        }
    }

    private var authenticationContent: some View {
        VStack(alignment: .leading, spacing: 24) {
            hero

            switch viewModel.step {
            case .signIn:
                if !quickLoginSessions.isEmpty {
                    savedAccountsSection
                }
                signInSection
            case .captcha:
                captchaSection
            case .twoFactor:
                twoFactorSection
            }

            VStack(spacing: 10) {
                advancedSection
                legalNotice
            }
        }
        .frame(maxWidth: 640)
        .padding(.horizontal, 20)
        .padding(.top, -24)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity)
    }

    private var hero: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                Image("BrandMark")
                    .resizable()
                    .scaledToFill()
                    .frame(width: 64, height: 64)
                    .clipShape(RoundedRectangle(cornerRadius: 17, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 17, style: .continuous)
                            .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                    }
                    .shadow(color: Color.black.opacity(0.18), radius: 12, y: 6)

                Text("Hangar Express")
                    .font(.largeTitle.bold())
                    .foregroundStyle(.primary)
            }

            Text("Sign in to sync your hangar and manage your fleet")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "info.circle.fill")
                    .foregroundStyle(Color.accentColor)
                    .padding(.top, 1)

                Text("This is an unofficial Star Citizen fan app and is not affiliated with the Cloud Imperium group of companies")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }

    @ViewBuilder
    private var statusMessages: some View {
        if let noticeMessage = viewModel.noticeMessage {
            AuthenticationStatusBanner(
                message: noticeMessage,
                systemImage: "info.circle.fill",
                tint: .orange,
                onCopy: copyAuthDebugReport
            )
        }

        if let errorMessage = viewModel.errorMessage {
            AuthenticationCard {
                VStack(alignment: .leading, spacing: 12) {
                    Label {
                        Text(errorMessage)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                    }
                    .font(.subheadline.weight(.medium))

                    if showsFullErrorDetails, let errorDebugDetails = viewModel.errorDebugDetails {
                        Text(verbatim: errorDebugDetails)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }

                    Button("Copy Auth Debug Report") {
                        copyAuthDebugReport()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(authDebugReport.isEmpty)
                }
            }
        }
    }

    private var signInSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            statusMessages

            AuthenticationCard {
                VStack(spacing: 14) {
                    HStack(spacing: 12) {
                        Image(systemName: "person.fill")
                            .frame(width: 22)
                            .foregroundStyle(.secondary)

                        TextField("RSI Email or Login ID", text: $viewModel.loginIdentifier)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.asciiCapable)
                            .textContentType(.username)
                            .focused($focusedField, equals: .loginIdentifier)
                            .submitLabel(.next)
                            .onSubmit { focusedField = .password }
                    }
                    .authenticationInputSurface()

                    HStack(spacing: 12) {
                        Image(systemName: "lock.fill")
                            .frame(width: 22)
                            .foregroundStyle(.secondary)

                        SecureField("Password", text: $viewModel.password)
                            .textContentType(.password)
                            .focused($focusedField, equals: .password)
                            .submitLabel(.go)
                            .onSubmit {
                                Task { await viewModel.submitCredentials() }
                            }
                    }
                    .authenticationInputSurface()

                    PasswordInfoRow(
                        title: "Your password is secured",
                        systemImage: "lock.shield.fill"
                    ) {
                        passwordInfoTopic = .standard
                    }

                    Button {
                        focusedField = nil
                        Task { await viewModel.submitCredentials() }
                    } label: {
                        HStack(spacing: 10) {
                            if viewModel.isSubmitting {
                                ProgressView()
                                    .tint(.white)
                            } else {
                                Image(systemName: "arrow.right")
                            }

                            Text("Continue")
                                .fontWeight(.semibold)
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: 50)
                        .foregroundStyle(.white)
                        .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .disabled(viewModel.isSubmitting)

                    HStack(spacing: 12) {
                        Divider()

                        Text("OR")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.tertiary)
                            .tracking(0.8)

                        Divider()
                    }
                    .frame(height: 16)
                    .accessibilityElement(children: .combine)

                    Button {
                        focusedField = nil
                        Task { await viewModel.beginReadOnlySignIn() }
                    } label: {
                        Label("Login as Read Only", systemImage: "eye.fill")
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .frame(height: 46)
                            .foregroundStyle(Color.accentColor)
                            .background(Color.accentColor.opacity(0.09), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .disabled(viewModel.isSubmitting)

                    PasswordInfoRow(
                        title: "Read Only: Your password is not saved",
                        systemImage: "eye.fill"
                    ) {
                        passwordInfoTopic = .readOnly
                    }
                }
            }
        }
    }

    private var captchaSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            AuthenticationSectionHeader(title: "RSI Verification", systemImage: "character.textbox")
            statusMessages

            AuthenticationCard {
                VStack(spacing: 16) {
                    if let data = viewModel.captchaImageData, let image = UIImage(data: data) {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                            .frame(maxHeight: 180)
                            .frame(maxWidth: .infinity)
                            .padding(10)
                            .background(.white, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                            .accessibilityLabel("RSI CAPTCHA image")
                    }

                    HStack(spacing: 12) {
                        Image(systemName: "textformat.abc")
                            .frame(width: 22)
                            .foregroundStyle(.secondary)

                        TextField("CAPTCHA Code", text: $viewModel.captchaCode)
                            .textInputAutocapitalization(.characters)
                            .autocorrectionDisabled()
                            .keyboardType(.asciiCapable)
                            .focused($focusedField, equals: .captcha)
                            .submitLabel(.go)
                            .onSubmit { Task { await viewModel.submitCaptcha() } }
                    }
                    .authenticationInputSurface()

                    Button {
                        focusedField = nil
                        Task { await viewModel.submitCaptcha() }
                    } label: {
                        Text("Verify CAPTCHA")
                            .fontWeight(.semibold)
                            .frame(maxWidth: .infinity)
                            .frame(height: 50)
                            .foregroundStyle(.white)
                            .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .disabled(viewModel.isSubmitting || viewModel.captchaCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                    Button("Back to Sign In") {
                        focusedField = nil
                        viewModel.returnToSignIn()
                    }
                    .disabled(viewModel.isSubmitting)

                    Text("Enter the characters from RSI's launcher CAPTCHA. This image is served by RSI and does not require Google reCAPTCHA.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private var savedAccountsSection: some View {
        Button {
            isShowingSavedAccounts = true
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "person.crop.circle.badge.checkmark")
                    .font(.title3)
                    .foregroundStyle(Color.accentColor)

                Text("Saved Accounts")
                    .font(.headline)
                    .foregroundStyle(.primary)

                Spacer(minLength: 8)

                Text(quickLoginSessions.count, format: .number)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(Color.primary.opacity(0.06), in: Capsule())

                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity, minHeight: 56)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(Color.primary.opacity(0.07), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .disabled(viewModel.isSubmitting)
        .popover(isPresented: $isShowingSavedAccounts) {
            savedAccountsPopover
                .presentationCompactAdaptation(.popover)
        }
    }

    private var savedAccountsPopover: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                AuthenticationSectionHeader(title: "Saved Accounts", systemImage: "person.crop.circle.badge.checkmark")

                Spacer()

                Text(quickLoginSessions.count, format: .number)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }

            ScrollView(.vertical) {
                LazyVStack(spacing: 10) {
                    ForEach(quickLoginSessions, id: \.id) { session in
                        SavedQuickLoginCard(
                            session: session,
                            isDisabled: viewModel.isSubmitting,
                            onSelect: {
                                isShowingSavedAccounts = false
                                Task { await appModel.openSavedAccount(id: session.id) }
                            },
                            onRemove: {
                                Task { await appModel.removeSavedAccount(id: session.id) }
                            }
                        )
                        .frame(height: savedAccountRowHeight)
                    }
                }
            }
            .frame(height: savedAccountListHeight)
            .scrollDisabled(quickLoginSessions.count <= 3)
            .scrollIndicators(quickLoginSessions.count > 3 ? .visible : .hidden)
        }
        .padding(16)
        .frame(width: 340)
    }

    private var twoFactorSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            AuthenticationSectionHeader(title: "Verification", systemImage: "envelope.badge.shield.half.filled")
            statusMessages

            AuthenticationCard {
                VStack(spacing: 14) {
                    HStack(spacing: 12) {
                        Image(systemName: "number")
                            .frame(width: 22)
                            .foregroundStyle(.secondary)

                        TextField("Verification Code", text: verificationCodeBinding)
                            .keyboardType(.asciiCapable)
                            .textInputAutocapitalization(.characters)
                            .autocorrectionDisabled()
                            .textContentType(.oneTimeCode)
                            .focused($focusedField, equals: .verificationCode)
                    }
                    .authenticationInputSurface()

                    HStack(spacing: 12) {
                        Image(systemName: "iphone")
                            .frame(width: 22)
                            .foregroundStyle(.secondary)

                        TextField("Device Name", text: $viewModel.deviceName)
                            .textInputAutocapitalization(.words)
                            .focused($focusedField, equals: .deviceName)
                    }
                    .authenticationInputSurface()

                    Button {
                        focusedField = nil
                        Task { await viewModel.submitVerificationCode() }
                    } label: {
                        Text("Verify")
                            .fontWeight(.semibold)
                            .frame(maxWidth: .infinity)
                            .frame(height: 50)
                            .foregroundStyle(.white)
                            .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .disabled(viewModel.isSubmitting || viewModel.verificationCode.isEmpty)

                    Button("Back to Sign In") {
                        focusedField = nil
                        viewModel.returnToSignIn()
                    }
                    .disabled(viewModel.isSubmitting)
                }
            }
        }
    }

    private var advancedSection: some View {
        Button {
            isShowingAdvanced = true
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "gearshape.fill")
                    .font(.title3)
                    .foregroundStyle(Color.accentColor)

                Text("Advanced")
                    .font(.headline)
                    .foregroundStyle(.primary)

                Spacer(minLength: 8)

                Image(systemName: "chevron.up")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity, minHeight: 56)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(Color.primary.opacity(0.07), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .popover(
            isPresented: $isShowingAdvanced,
            attachmentAnchor: .rect(.bounds),
            arrowEdge: .bottom
        ) {
            advancedPopover
                .presentationCompactAdaptation(.popover)
        }
    }

    private var advancedPopover: some View {
        VStack(alignment: .leading, spacing: 16) {
            AuthenticationSectionHeader(title: "Advanced", systemImage: "gearshape.fill")

            Divider()

            Toggle("Show Full Auth Errors", isOn: $showsFullErrorDetails)
                .tint(Color.accentColor)

#if DEBUG
            Button {
                isShowingAdvanced = false
                Task { await viewModel.loadDemoHangar() }
            } label: {
                Label("Load Demo Hangar", systemImage: "sparkles")
            }
            .disabled(viewModel.isSubmitting)
#endif

            Button(role: .destructive) {
                isShowingAdvanced = false
                isShowingClearKeychainAlert = true
            } label: {
                Label("Remove Saved Keychain Content", systemImage: "key.slash.fill")
            }
            .disabled(viewModel.isSubmitting)

            Text("Removes every saved RSI account, its stored cookies, and saved credentials from Keychain without touching your local image or hangar cache.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(width: 340)
    }

    private var legalNotice: some View {
        Text("Star Citizen, Squadron 42, Roberts Space Industries, and related names, ships, artwork, and other game content shown or referenced by this app belong to the Cloud Imperium group of companies and their respective owners.")
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 8)
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

    private var savedAccountRowHeight: CGFloat { 66 }

    private var savedAccountListHeight: CGFloat {
        let visibleRowCount = min(quickLoginSessions.count, 3)
        let rowSpacing = max(visibleRowCount - 1, 0) * 10
        return (CGFloat(visibleRowCount) * savedAccountRowHeight) + CGFloat(rowSpacing)
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
            rememberMe: true,
            showsFullErrors: showsFullErrorDetails,
            browserChallengeIsPresented: viewModel.browserChallenge != nil,
            helperIsPreparing: appModel.recaptchaBroker.isPreparing,
            helperStatusMessage: appModel.recaptchaBroker.statusMessage,
            helperPrefersBrowserAssistedLogin: appModel.recaptchaBroker.prefersBrowserAssistedLogin
        )
    }

    private func copyAuthDebugReport() {
        UIPasteboard.general.string = authDebugReport
        didCopyAuthDebugReport = true
    }
}

private struct SavedQuickLoginCard: View {
    let session: UserSession
    let isDisabled: Bool
    let onSelect: () -> Void
    let onRemove: () -> Void

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Button(action: onSelect) {
                HStack(spacing: 10) {
                    SavedAccountAvatar(session: session)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(session.displayName)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)

                        Text(session.credentials?.loginIdentifier ?? session.email)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }

                    Spacer(minLength: 24)
                }
                .padding(11)
                .frame(maxWidth: .infinity, minHeight: 66, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(isDisabled)
            .accessibilityHint("Use Saved")

            Menu {
                Button("Remove", role: .destructive, action: onRemove)
            } label: {
                Image(systemName: "ellipsis")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 30, height: 30)
                    .contentShape(Rectangle())
            }
            .padding(.top, 4)
            .padding(.trailing, 4)
            .accessibilityLabel("Account options")
            .disabled(isDisabled)
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.primary.opacity(0.07), lineWidth: 1)
        }
    }
}

private struct SavedAccountAvatar: View {
    let session: UserSession

    private let size: CGFloat = 42

    var body: some View {
        Group {
            if let avatarURL = session.avatarURL {
                CachedRemoteImage(
                    url: avatarURL,
                    targetSize: CGSize(width: size, height: size)
                ) { phase in
                    switch phase {
                    case let .success(image):
                        image
                            .resizable()
                            .scaledToFill()
                    case .empty, .failure:
                        placeholder
                    }
                }
            } else {
                placeholder
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.primary.opacity(0.1), lineWidth: 1)
        }
        .overlay(alignment: .bottomTrailing) {
            if session.isReadOnly {
                Image(systemName: "eye.fill")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 16, height: 16)
                    .background(Color.accentColor, in: Circle())
                    .overlay {
                        Circle()
                            .stroke(Color(uiColor: .systemGroupedBackground), lineWidth: 1.5)
                    }
                    .offset(x: 3, y: 3)
            }
        }
    }

    private var placeholder: some View {
        LinearGradient(
            colors: [Color.accentColor, Color.cyan],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .overlay {
            Text(initials)
                .font(.caption.weight(.bold))
                .foregroundStyle(.white)
        }
    }

    private var initials: String {
        let words = session.displayName
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
            .filter { !$0.isEmpty }

        guard !words.isEmpty else {
            return "HE"
        }

        return words
            .prefix(2)
            .compactMap { $0.first.map(String.init) }
            .joined()
            .uppercased()
    }
}

private struct AuthenticationSectionHeader: View {
    let title: LocalizedStringKey
    let systemImage: String

    var body: some View {
        Label(title, systemImage: systemImage)
            .font(.headline)
            .foregroundStyle(.primary)
    }
}

private struct PasswordInfoRow: View {
    let title: LocalizedStringKey
    let systemImage: String
    let onInfo: () -> Void

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: systemImage)
                .font(.caption)
                .foregroundStyle(Color.accentColor)

            Text(title)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)

            Button(action: onInfo) {
                Image(systemName: "info.circle")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("More information")

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct AuthenticationCard<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(Color.primary.opacity(0.07), lineWidth: 1)
            }
            .shadow(color: Color.black.opacity(0.05), radius: 16, y: 8)
    }
}

private struct AuthenticationStatusBanner: View {
    let message: String
    let systemImage: String
    let tint: Color
    let onCopy: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label {
                Text(message)
            } icon: {
                Image(systemName: systemImage)
                    .foregroundStyle(tint)
            }
            .font(.subheadline)

            Button(action: onCopy) {
                Label("Copy Logs", systemImage: "doc.on.doc")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .tint(tint)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.09), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

private struct AuthenticationBackground: View {
    var body: some View {
        ZStack {
            Color(uiColor: .systemGroupedBackground)

            RadialGradient(
                colors: [Color.accentColor.opacity(0.11), .clear],
                center: .topLeading,
                startRadius: 0,
                endRadius: 360
            )
        }
        .ignoresSafeArea()
    }
}

private extension View {
    func authenticationInputSurface() -> some View {
        padding(.horizontal, 14)
            .frame(minHeight: 52)
            .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color.primary.opacity(0.07), lineWidth: 1)
            }
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
        lines.append("Browser Challenge Visible: \(browserChallengeIsPresented)")
        lines.append("Sign-In Route: launcher-api")
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
        case .captcha:
            return "CAPTCHA"
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
