import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage(AppLanguage.storageKey) private var appLanguageRawValue = AppLanguage.system.rawValue
    @AppStorage(AppAppearance.storageKey) private var appAppearanceRawValue = AppAppearance.system.rawValue
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
    private let spviewerURL = URL(string: "https://www.spviewer.eu/")!
    private let starCitizenWikiURL = URL(string: "https://starcitizen.tools/")!
    private let anywhereExpURL = URL(string: "https://robertsspaceindustries.com/en/orgs/ANYWHEREXP")!

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("Language", selection: $appLanguageRawValue) {
                        ForEach(AppLanguage.allCases) { language in
                            language.label
                                .tag(language.rawValue)
                        }
                    }
                    .pickerStyle(.menu)

                    Picker("Appearance", selection: $appAppearanceRawValue) {
                        ForEach(AppAppearance.allCases) { appearance in
                            appearance.label
                                .tag(appearance.rawValue)
                        }
                    }
                    .pickerStyle(.menu)
                } header: {
                    Text("Display")
                } footer: {
                    Text("Choose the app language and appearance.")
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
                    Text("Controls how many pages refresh in parallel.")
                }

                Section {
                    Toggle("Composite Upgrade Thumbnails", isOn: $usesCompositeUpgradeThumbnails)
                    Toggle("Show Final Upgraded Ship in Hangar", isOn: $showsUpgradedShipInHangar)
                    Toggle("Highlight Gifted Hangar Rows", isOn: $highlightsGiftedHangarRows)
                    Toggle("Highlight Upgraded Hangar Rows", isOn: $highlightsUpgradedHangarRows)
                } header: {
                    Text("Advanced")
                } footer: {
                    Text("When RSI does not provide upgrade artwork, Hangar Express can show a split thumbnail using the source ship on one side and the target ship on the other. Turn this off to keep the original default placeholder instead. You can also choose whether upgraded ship pledges use the original pledge card or the final upgraded ship in the hangar list, and whether gifted or upgraded rows are tinted in the hangar.")
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
                    Link(destination: spviewerURL) {
                        Label("SPViewer", systemImage: "link")
                    }

                    Link(destination: starCitizenWikiURL) {
                        Label("Starcitizen Wiki", systemImage: "link")
                    }

                    Link(destination: anywhereExpURL) {
                        Label("AnywhereExp", systemImage: "link")
                    }
                } header: {
                    Text("Special Thanks")
                }

                Section {
                    Text("Hangar Express is an unofficial Star Citizen fan project and is not affiliated with the Cloud Imperium group of companies. Star Citizen, Squadron 42, Roberts Space Industries, and related game content shown by this app belong to the Cloud Imperium group of companies and their respective owners.")
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
        let cookieSummary = AppLocalizer.format("%lld cookies", session.cookies.count)

        if session.hasStoredCredentials {
            return AppLocalizer.format("%@ saved, credentials in Keychain", cookieSummary)
        }

        return cookieSummary
    }
}
