import StoreKit
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
                ProSubscriptionSection(subscriptionStore: appModel.subscriptionStore)

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
                                canSwitch: appModel.allowsMultiAccountSwitching,
                                onSwitch: {
                                    dismiss()
                                    Task {
                                        await appModel.openSavedAccount(id: savedSession.id)
                                    }
                                },
                                onUpgrade: {
                                    Task {
                                        await appModel.subscriptionStore.purchasePro()
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
                        Task {
                            if appModel.allowsMultiAccountSwitching {
                                dismiss()
                                await appModel.beginAddingAccount()
                            } else {
                                await appModel.subscriptionStore.purchasePro()
                            }
                        }
                    } label: {
                        Label(
                            appModel.allowsMultiAccountSwitching ? "Add Another Account" : "Upgrade to Add Another Account",
                            systemImage: appModel.allowsMultiAccountSwitching ? "plus.circle" : "lock"
                        )
                    }
                } header: {
                    Text("Accounts")
                } footer: {
                    if !appModel.allowsMultiAccountSwitching {
                        Text("Standard keeps your current saved account. Pro unlocks switching between multiple saved accounts.")
                    }
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
                            value: syncWorkerCountBinding,
                            in: Double(SyncPreferences.minWorkerCount) ... Double(appModel.refreshWorkerLimit),
                            step: 1
                        )
                    }
                } header: {
                    Text("Sync")
                } footer: {
                    Text(appModel.isPro ? "Pro can refresh up to 10 pages in parallel." : "Standard refreshes up to 2 pages in parallel. Pro unlocks up to 10.")
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
            .onAppear {
                clampStoredWorkerCount()
            }
            .onChange(of: appModel.isPro) { _, _ in
                clampStoredWorkerCount()
            }
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
        SyncPreferences.constrainedWorkerCount(
            Int(syncWorkerCount.rounded()),
            isPro: appModel.isPro
        )
    }

    private var syncWorkerCountBinding: Binding<Double> {
        Binding(
            get: {
                Double(resolvedWorkerCount)
            },
            set: { newValue in
                syncWorkerCount = Double(
                    SyncPreferences.constrainedWorkerCount(
                        Int(newValue.rounded()),
                        isPro: appModel.isPro
                    )
                )
            }
        )
    }

    private func clampStoredWorkerCount() {
        syncWorkerCount = Double(resolvedWorkerCount)
    }
}

private struct ProSubscriptionSection: View {
    let subscriptionStore: SubscriptionStore

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: subscriptionStore.isPro ? "checkmark.seal.fill" : "sparkles")
                        .font(.title2)
                        .foregroundStyle(subscriptionStore.isPro ? .green : Color.accentColor)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(subscriptionStore.isPro ? "Hangar Express Pro Active" : "Hangar Express Pro")
                            .font(.headline)

                        Text("10 refresh workers, 500 hangar log entries, and multi account switching.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }

                if let message = statusMessage {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(statusIsError ? .red : .secondary)
                } else if let productLoadErrorMessage = subscriptionStore.productLoadErrorMessage {
                    Text(productLoadErrorMessage)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }

                VStack(alignment: .leading, spacing: 10) {
                    if subscriptionStore.isPro {
                        Button("Restore Purchases") {
                            Task {
                                await subscriptionStore.restorePurchases()
                            }
                        }
                        .buttonStyle(.bordered)
                    } else {
                        if subscriptionStore.proProducts.isEmpty {
                            Button(primaryButtonTitle) {
                                Task {
                                    await subscriptionStore.purchasePro()
                                }
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(statusIsBusy || subscriptionStore.isLoadingProducts)
                        } else {
                            ForEach(subscriptionStore.proProducts, id: \.id) { product in
                                Button {
                                    Task {
                                        await subscriptionStore.purchasePro(productID: product.id)
                                    }
                                } label: {
                                    HStack {
                                        Text(planTitle(for: product))

                                        Spacer(minLength: 12)

                                        Text(product.displayPrice)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                .buttonStyle(.borderedProminent)
                                .disabled(statusIsBusy)
                            }
                        }

                        Button("Restore") {
                            Task {
                                await subscriptionStore.restorePurchases()
                            }
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }
            .padding(.vertical, 6)
        } header: {
            Text("Pro")
        } footer: {
            Text("Purchases are handled by the App Store. Manage or cancel the subscription from your Apple Account settings.")
        }
    }

    private var primaryButtonTitle: String {
        if subscriptionStore.isLoadingProducts {
            return AppLocalizer.string("Loading...")
        }

        return AppLocalizer.format("Subscribe %@", subscriptionStore.proPriceLabel)
    }

    private func planTitle(for product: Product) -> String {
        switch product.id {
        case ProSubscriptionConfiguration.monthlyProductID:
            return AppLocalizer.string("Subscribe Monthly")
        case ProSubscriptionConfiguration.yearlyProductID:
            return AppLocalizer.string("Subscribe Yearly")
        default:
            return AppLocalizer.string("Subscribe")
        }
    }

    private var statusMessage: String? {
        switch subscriptionStore.purchaseStatus {
        case .idle:
            return nil
        case .purchasing:
            return AppLocalizer.string("Opening App Store purchase sheet.")
        case .restoring:
            return AppLocalizer.string("Restoring purchases.")
        case let .success(message), let .failed(message):
            return message
        }
    }

    private var statusIsError: Bool {
        if case .failed = subscriptionStore.purchaseStatus {
            return true
        }

        return false
    }

    private var statusIsBusy: Bool {
        switch subscriptionStore.purchaseStatus {
        case .purchasing, .restoring:
            return true
        case .idle, .success, .failed:
            return false
        }
    }
}

private struct SavedAccountRow: View {
    let session: UserSession
    let isActive: Bool
    let canSwitch: Bool
    let onSwitch: () -> Void
    let onUpgrade: () -> Void

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
                } else if canSwitch {
                    Button("Switch", action: onSwitch)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                } else {
                    Button("Pro", action: onUpgrade)
                        .buttonStyle(.bordered)
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
