import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage(SyncPreferences.workerCountKey) private var syncWorkerCount = Double(SyncPreferences.defaultWorkerCount)
    @AppStorage(DisplayPreferences.compositeUpgradeThumbnailModeKey) private var usesCompositeUpgradeThumbnails = DisplayPreferences.compositeUpgradeThumbnailsEnabledByDefault
    @AppStorage(DisplayPreferences.hangarUpgradedShipDisplayModeKey) private var showsUpgradedShipInHangar = DisplayPreferences.hangarUpgradedShipDisplayEnabledByDefault
    @AppStorage(DisplayPreferences.hangarGiftedHighlightKey) private var highlightsGiftedHangarRows = DisplayPreferences.hangarGiftedHighlightEnabledByDefault
    @AppStorage(DisplayPreferences.hangarUpgradedHighlightKey) private var highlightsUpgradedHangarRows = DisplayPreferences.hangarUpgradedHighlightEnabledByDefault
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
                                Button("Remove", role: .destructive) {
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
                    Text("Each saved account keeps its own RSI cookies and stored credentials in Keychain so you can switch accounts without logging in again. Swipe left on an account to remove it.")
                }

                Section {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("Refresh Workers")
                            Spacer()
                            Text("\(resolvedWorkerCount)")
                                .foregroundStyle(.secondary)
                        }

                        Slider(
                            value: $syncWorkerCount,
                            in: Double(SyncPreferences.minWorkerCount) ... Double(SyncPreferences.maxWorkerCount),
                            step: 1
                        )
                    }
                } header: {
                    Text("Sync")
                } footer: {
                    Text("Controls how many hangar and buy-back pages Hangar Express refreshes in parallel. Higher values can finish faster on large inventories, but they also send more requests at once.")
                }

                Section {
                    Toggle("Composite Upgrade Thumbnails", isOn: $usesCompositeUpgradeThumbnails)
                    Toggle("Show Final Upgraded Ship in Hangar", isOn: $showsUpgradedShipInHangar)
                    Toggle("Highlight Gifted Hangar Rows", isOn: $highlightsGiftedHangarRows)
                    Toggle("Highlight Upgraded Hangar Rows", isOn: $highlightsUpgradedHangarRows)
                } header: {
                    Text("Display")
                } footer: {
                    Text("When RSI does not provide upgrade artwork, Hangar Express can show a split thumbnail using the source ship on one side and the target ship on the other. Turn this off to keep the original default placeholder instead. You can also choose whether upgraded ship pledges use the original pledge card or the final upgraded ship in the hangar list, and whether gifted or upgraded rows are tinted in the hangar.")
                }

                Section {
                    Label("Browser-backed sign-in and multi-account session restore", systemImage: "checkmark.circle")
                    Label("Live hangar, fleet, buy-back, and account sync", systemImage: "checkmark.circle")
                    Label("Hosted ship specs and fleet-to-pledge drill-down", systemImage: "checkmark.circle")
                    Label("Persistent ship image cache and upgrade composite thumbnails", systemImage: "checkmark.circle")
                    Label("Melt, gift, and apply-upgrade actions", systemImage: "checkmark.circle")
                    Label("Item-linked hangar log shortcuts from detail screens", systemImage: "hourglass")
                    Label("Final pre-release QA, copy polish, and edge-case cleanup", systemImage: "hourglass")
                } header: {
                    Text("Roadmap")
                } footer: {
                    Text("Checked items are already in the app. Hourglass items are the remaining pre-release polish work.")
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

    private var resolvedWorkerCount: Int {
        min(
            max(Int(syncWorkerCount.rounded()), SyncPreferences.minWorkerCount),
            SyncPreferences.maxWorkerCount
        )
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
