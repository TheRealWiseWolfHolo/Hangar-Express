import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var isShowingClearCacheAlert = false

    let appModel: AppModel
    let snapshot: HangarSnapshot

    private let officialRSIURL = URL(string: "https://robertsspaceindustries.com/en/")!
    private let repositoryURL = URL(string: "https://github.com/TheRealWiseWolfHolo/Hanger-Express")!
    private let fanProjectDisclaimer = "Hangar Express is an unofficial Star Citizen fan project and is not affiliated with the Cloud Imperium group of companies. Star Citizen, Squadron 42, Roberts Space Industries, and related game content shown by this app belong to the Cloud Imperium group of companies and their respective owners."

    var body: some View {
        NavigationStack {
            List {
                Section {
                    LabeledContent("Account", value: appModel.session?.displayName ?? snapshot.accountHandle)
                    LabeledContent("Account Email", value: appModel.session?.email ?? "Unknown")
                    LabeledContent("Saved Login", value: appModel.session?.credentials?.loginIdentifier ?? "None")
                    LabeledContent("Session Mode", value: appModel.session?.authMode.rawValue ?? "None")
                    LabeledContent("Saved Accounts", value: "\(appModel.savedSessions.count)")
                    LabeledContent("Stored Cookies", value: "\(appModel.session?.cookies.count ?? 0)")
                    LabeledContent("Stored Credentials", value: appModel.session?.hasStoredCredentials == true ? "Keychain" : "None")
                    LabeledContent("Last Refresh", value: refreshLabel)
                } header: {
                    Text("Session")
                }

                Section {
                    if appModel.savedSessions.isEmpty {
                        Text("No saved accounts yet.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(appModel.savedSessions) { savedSession in
                            SavedAccountRow(
                                session: savedSession,
                                isActive: savedSession.id == appModel.session?.id,
                                onSwitch: {
                                    dismiss()
                                    Task {
                                        await appModel.openSavedAccount(id: savedSession.id)
                                    }
                                }
                            )
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button("Forget", role: .destructive) {
                                    if savedSession.id == appModel.session?.id {
                                        dismiss()
                                    }

                                    Task {
                                        await appModel.removeSavedAccount(id: savedSession.id)
                                    }
                                }
                            }
                        }
                    }

                    Button {
                        dismiss()
                        Task {
                            await appModel.beginAddingAccount()
                        }
                    } label: {
                        Label("Add Another Account", systemImage: "plus.circle")
                    }
                } header: {
                    Text("Accounts")
                } footer: {
                    Text("Each saved account keeps its own RSI cookies and stored credentials in Keychain so you can switch accounts without logging in again.")
                }

                Section {
                    Label("Read-only pledge sync", systemImage: "checkmark.circle")
                    Label("Buy-back visibility", systemImage: "checkmark.circle")
                    Label("Ship grouping and local notes", systemImage: "checkmark.circle")
                    Label("Melt, gift, and upgrade actions", systemImage: "hourglass")
                    Label("Item-linked hangar log shortcuts from pledge details", systemImage: "hourglass")
                } header: {
                    Text("Roadmap")
                }

                Section {
                    Button {
                        isShowingClearCacheAlert = true
                    } label: {
                        Label("Clear Local Cache", systemImage: "trash")
                    }
                    .disabled(appModel.isRefreshing)
                } header: {
                    Text("Storage")
                } footer: {
                    Text("Clears downloaded images and saved local hangar snapshots without removing saved accounts, cookies, or credentials. Confirming this will immediately perform a full account reload with the currently saved RSI session.")
                }

                Section {
                    ForEach(SponsorDirectory.displayedSponsors) { sponsor in
                        HStack(spacing: 10) {
                            Image(systemName: "heart.fill")
                                .foregroundStyle(.pink)

                            Text(sponsor.name)
                        }
                    }
                } header: {
                    Text("Sponsors")
                } footer: {
                    Text("Thank you for supporting Hangar Express. Names are shown in supporter order based on contribution ranking.")
                }

                Section {
                    Text(fanProjectDisclaimer)
                        .font(.footnote)

                    Link(destination: officialRSIURL) {
                        Label("Official RSI Website", systemImage: "link")
                    }

                    Link(destination: repositoryURL) {
                        Label("GitHub Repository", systemImage: "link")
                    }
                } header: {
                    Text("Legal")
                }

                Section {
                    Button("Sign Out and Remove Saved Credentials", role: .destructive) {
                        dismiss()
                        Task {
                            await appModel.clearSession()
                        }
                    }
                } footer: {
                    Text("This removes every saved account, its credentials, and its RSI cookies from Keychain.")
                }
            }
            .navigationTitle("Settings")
            .alert("Clear Local Cache?", isPresented: $isShowingClearCacheAlert) {
                Button("Cancel", role: .cancel) {}
                Button("Clear and Reload", role: .destructive) {
                    dismiss()
                    Task {
                        await appModel.clearLocalCache()
                    }
                }
            } message: {
                Text("Clearing local cache removes downloaded images and saved local snapshots. Hangar Express will then run a full reload to rebuild everything from RSI.")
            }
        }
    }

    private var refreshLabel: String {
        guard let lastRefreshAt = appModel.lastRefreshAt else {
            return "Not yet synced"
        }

        return lastRefreshAt.formatted(date: .abbreviated, time: .shortened)
    }
}

private struct SavedAccountRow: View {
    let session: UserSession
    let isActive: Bool
    let onSwitch: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(session.displayName)
                        .font(.headline)

                    Text(session.credentials?.loginIdentifier ?? session.email)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 12)

                if isActive {
                    Text("Active")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.green)
                } else {
                    Button("Switch", action: onSwitch)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                }
            }

            Text(summaryLine)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }

    private var summaryLine: String {
        let cookieSummary = "\(session.cookies.count) cookies"

        if session.hasStoredCredentials {
            return "\(cookieSummary) saved, credentials in Keychain"
        }

        return cookieSummary
    }
}
