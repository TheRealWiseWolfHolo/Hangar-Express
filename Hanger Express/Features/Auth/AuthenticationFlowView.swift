import SwiftUI

struct AuthenticationFlowView: View {
    let appModel: AppModel

    @AppStorage("auth.debug.showFullErrors") private var showsFullErrorDetails = false
    @State private var viewModel: AuthenticationViewModel

    private let unofficialAppNotice = "This is an unofficial Star Citizen fan app and is not affiliated with the Cloud Imperium group of companies."
    private let ownershipNotice = "Star Citizen, Squadron 42, Roberts Space Industries, and related names, ships, artwork, and other game content shown or referenced by this app belong to the Cloud Imperium group of companies and their respective owners."

    init(appModel: AppModel) {
        self.appModel = appModel
        _viewModel = State(initialValue: AuthenticationViewModel(appModel: appModel))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(unofficialAppNotice)
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
                } header: {
                    Text("Advanced")
                }

                Section {
                    Text(ownershipNotice)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Hangar Express")
        }
        .background(
            RecaptchaBridgeView(broker: appModel.recaptchaBroker)
                .frame(width: 1, height: 1)
                .opacity(0.01)
                .allowsHitTesting(false)
        )
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

            Button("Continue") {
                Task {
                    await viewModel.submitCredentials()
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(viewModel.isSubmitting)
        } header: {
            Text("Credentials")
        }
    }

    private var savedAccountsSection: some View {
                Section {
                    SavedQuickLoginRows(sessions: quickLoginSessions, isDisabled: viewModel.isSubmitting) { session in
                        Task {
                            await appModel.openSavedAccount(id: session.id)
                        }
                    }
                } header: {
                    Text("Saved Accounts")
                } footer: {
                    Text("Pick a saved RSI account to reuse its stored cookies, or jump back into sign-in with its stored credentials if the session needs to be refreshed.")
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
}

private struct SavedQuickLoginRows: View {
    let sessions: [UserSession]
    let isDisabled: Bool
    let onSelect: (UserSession) -> Void

    var body: some View {
        SwiftUI.ForEach<[UserSession], UserSession.ID, SavedQuickLoginButton>(sessions, id: \.id) { session in
            SavedQuickLoginButton(session: session, isDisabled: isDisabled) {
                onSelect(session)
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
