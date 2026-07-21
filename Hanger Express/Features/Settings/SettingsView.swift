import StoreKit
import SwiftUI
import UIKit

private enum LegalLinkDestinations {
    static let privacyPolicyURL = URL(string: "https://github.com/TheRealWiseWolfHolo/Hangar-Express/blob/main/PRIVACY_POLICY.md")!
    static let termsOfUseURL = URL(string: "https://github.com/TheRealWiseWolfHolo/Hangar-Express/blob/main/TERMS_OF_USE.md")!
}

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage(AppLanguage.storageKey) private var appLanguageRawValue = AppLanguage.system.rawValue
    @AppStorage(HangarItemLanguage.storageKey) private var hangarItemLanguageRawValue = HangarItemLanguage.original.rawValue
    @AppStorage(AppAppearance.storageKey) private var appAppearanceRawValue = AppAppearance.system.rawValue
    @AppStorage(SyncPreferences.workerCountKey) private var syncWorkerCount = Double(SyncPreferences.defaultWorkerCount)
    @AppStorage(SyncPreferences.inventoryAutoRefreshIntervalKey) private var inventoryAutoRefreshIntervalRawValue = SyncPreferences.defaultInventoryAutoRefreshInterval.rawValue
    @AppStorage(DisplayPreferences.compositeUpgradeThumbnailModeKey) private var usesCompositeUpgradeThumbnails = DisplayPreferences.compositeUpgradeThumbnailsEnabledByDefault
    @AppStorage(DisplayPreferences.hangarUpgradedShipDisplayModeKey) private var showsUpgradedShipInHangar = DisplayPreferences.hangarUpgradedShipDisplayEnabledByDefault
    @AppStorage(DisplayPreferences.hangarGiftedHighlightKey) private var highlightsGiftedHangarRows = DisplayPreferences.hangarGiftedHighlightEnabledByDefault
    @AppStorage(DisplayPreferences.hangarUpgradedHighlightKey) private var highlightsUpgradedHangarRows = DisplayPreferences.hangarUpgradedHighlightEnabledByDefault
    @AppStorage(DisplayPreferences.earlyAccessBadgeKey) private var showsEarlyAccessBadge = DisplayPreferences.earlyAccessBadgeEnabledByDefault
    @AppStorage(DisplayPreferences.sharePictureAutoCopiesDebugLogKey) private var autoCopiesSharePictureDebugLog = DisplayPreferences.sharePictureAutoCopiesDebugLogEnabledByDefault
    @AppStorage(DisplayPreferences.hangarBulkSelectionKey) private var enablesHangarBulkSelection = DisplayPreferences.hangarBulkSelectionEnabledByDefault
    @State private var isShowingClearCacheAlert = false
    @State private var isShowingClearTranslationCacheAlert = false
    @State private var isShowingProPlans = false

    let appModel: AppModel
    let snapshot: HangarSnapshot

    private let officialRSIURL = URL(string: "https://robertsspaceindustries.com/en/")!
    private let repositoryURL = URL(string: "https://github.com/TheRealWiseWolfHolo/Hangar-Express")!
    private let spviewerURL = URL(string: "https://www.spviewer.eu/")!
    private let starCitizenWikiURL = URL(string: "https://starcitizen.tools/")!
    private let anywhereExpURL = URL(string: "https://robertsspaceindustries.com/en/orgs/ANYWHEREXP")!

    var body: some View {
        NavigationStack {
            List {
                ProSubscriptionSection(
                    subscriptionStore: appModel.subscriptionStore,
                    showsEarlyAccessBadge: $showsEarlyAccessBadge,
                    onShowPlans: {
                        isShowingProPlans = true
                    }
                )

                Section {
                    Picker("App Language", selection: $appLanguageRawValue) {
                        ForEach(AppLanguage.allCases) { language in
                            language.label
                                .tag(language.rawValue)
                        }
                    }
                    .pickerStyle(.menu)

                    Picker("Item Language", selection: $hangarItemLanguageRawValue) {
                        ForEach(HangarItemLanguage.allCases) { language in
                            language.label
                                .tag(language.rawValue)
                        }
                    }
                    .pickerStyle(.menu)
                    .onChange(of: hangarItemLanguageRawValue) { _, _ in
                        appModel.requestItemTranslationPreprocessingForCurrentSnapshot()
                    }

                    Picker("Appearance", selection: $appAppearanceRawValue) {
                        ForEach(AppAppearance.allCases) { appearance in
                            appearance.label
                                .tag(appearance.rawValue)
                        }
                    }
                    .pickerStyle(.menu)
                } header: {
                    Text("Display")
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
                            appModel.allowsMultiAccountSwitching
                                ? AppLocalizer.string("Add Another Account")
                                : AppLocalizer.string("Upgrade to Add Another Account"),
                            systemImage: appModel.allowsMultiAccountSwitching ? "plus.circle" : "lock"
                        )
                    }
                } header: {
                    Text("Accounts")
                } footer: {
                    if appModel.allowsMultiAccountSwitching {
                        Text("Early Access stores up to 10 saved accounts while multiple account switching is in Labs. Adding an 11th account replaces the oldest saved account.")
                    } else {
                        Text("Standard keeps your current saved account. Early Access unlocks multiple account switching while the feature is in Labs.")
                    }
                }

                Section {
                    Picker("Auto Inventory Refresh Interval", selection: $inventoryAutoRefreshIntervalRawValue) {
                        ForEach(SyncPreferences.InventoryAutoRefreshInterval.allCases) { interval in
                            Text(interval.title)
                                .tag(interval.rawValue)
                        }
                    }
                    .pickerStyle(.menu)

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
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Auto inventory refresh controls when Hangar Express runs a full inventory refresh after opening the app. Manual refresh buttons are unaffected.")
                        Text(
                            appModel.isPro
                                ? AppLocalizer.string("Early Access Labs can refresh up to 10 pages in parallel.")
                                : AppLocalizer.string("Standard refreshes up to 2 pages in parallel. Early Access unlocks up to 10 while the feature is in Labs.")
                        )
                    }
                }

                Section {
                    Toggle("Composite Upgrade Thumbnails", isOn: $usesCompositeUpgradeThumbnails)
                    Toggle("Show Final Upgraded Ship in Hangar", isOn: $showsUpgradedShipInHangar)
                    Toggle("Highlight Gifted Hangar Rows", isOn: $highlightsGiftedHangarRows)
                    Toggle("Highlight Upgraded Hangar Rows", isOn: $highlightsUpgradedHangarRows)
                    Toggle("Hangar Multi-Select Actions", isOn: $enablesHangarBulkSelection)
                    Toggle("Auto Copy Share Picture Log", isOn: $autoCopiesSharePictureDebugLog)
                } header: {
                    Text("Advanced")
                } footer: {
                    Text("Control hangar artwork, row highlights, optional multi-select actions, and share-picture diagnostics.")
                }

                Section {
                    Toggle("Preview Translation Loading Bar", isOn: translationLoadingBarPreviewBinding)
                } header: {
                    Text("Developer")
                } footer: {
                    Text("Closes Settings and shows sample progress on the Dynamic Island loading bar.")
                }

                Section {
                    Button {
                        isShowingClearCacheAlert = true
                    } label: {
                        Label("Clear Local Cache", systemImage: "trash")
                    }
                    .disabled(appModel.isRefreshing)

                    Button(role: .destructive) {
                        isShowingClearTranslationCacheAlert = true
                    } label: {
                        Label("Clear Translation Cache", systemImage: "character.book.closed")
                    }
                } header: {
                    Text("Storage")
                } footer: {
                    Text("Local cache clears downloaded images and saved hangar snapshots, then performs a full account reload. Translation cache clears only the hosted item dictionary and saved on-device translations. Neither action removes saved accounts, cookies, or credentials.")
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

                    Link(destination: LegalLinkDestinations.privacyPolicyURL) {
                        Label("Privacy Policy", systemImage: "lock.shield")
                    }

                    Link(destination: LegalLinkDestinations.termsOfUseURL) {
                        Label("Terms of Use", systemImage: "doc.text")
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
                Text("Clearing local cache removes downloaded images and saved local snapshots. Hangar Express will then run a full reload to rebuild account data from RSI. Translation cache is not affected.")
            }
            .alert("Clear Translation Cache?", isPresented: $isShowingClearTranslationCacheAlert) {
                Button("Cancel", role: .cancel) {}
                Button("Clear Translation Cache", role: .destructive) {
                    dismiss()
                    Task {
                        await appModel.clearTranslationCache()
                    }
                }
            } message: {
                Text("Clearing translation cache removes the hosted item translation dictionary and saved on-device translations. Your hangar snapshots, images, accounts, cookies, and credentials are not affected.")
            }
            .sheet(isPresented: $isShowingProPlans) {
                ProPlansSheet(subscriptionStore: appModel.subscriptionStore)
                    .presentationDetents([.medium, .large])
            }
        }
    }

    private var translationLoadingBarPreviewBinding: Binding<Bool> {
        Binding(
            get: {
                appModel.previewsTranslationLoadingBar
            },
            set: { newValue in
                appModel.previewsTranslationLoadingBar = newValue
                if newValue {
                    dismiss()
                }
            }
        )
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
    @Binding var showsEarlyAccessBadge: Bool
    let onShowPlans: () -> Void

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: subscriptionStore.isPro ? "checkmark.seal.fill" : "sparkles")
                        .font(.title2)
                        .foregroundStyle(subscriptionStore.isPro ? .green : Color.accentColor)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(subscriptionStore.isPro ? AppLocalizer.string("Early Access Active") : AppLocalizer.string("Hangar Express Early Access"))
                            .font(.headline)

                        Text(statusSummary)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    LabeledContent("Status") {
                        Text(subscriptionStore.isPro ? AppLocalizer.string("Active") : AppLocalizer.string("Inactive"))
                            .foregroundStyle(subscriptionStore.isPro ? .green : .secondary)
                    }

                    if subscriptionStore.isPro {
                        LabeledContent("Plan") {
                            Text(subscriptionStore.proSubscriptionDetails?.displayName ?? AppLocalizer.string("Hangar Express Early Access"))
                                .foregroundStyle(.secondary)
                        }

                        if subscriptionStore.proSubscriptionDetails?.isLifetime == true {
                            LabeledContent("Access") {
                                Text("Lifetime")
                                    .foregroundStyle(.secondary)
                            }
                        } else {
                            LabeledContent("Next Renewal") {
                                Text(nextRenewalLabel)
                                    .foregroundStyle(.secondary)
                            }

                            LabeledContent("Auto Renewal") {
                                Text(autoRenewalLabel)
                                    .foregroundStyle(autoRenewalStyle)
                            }

                            if let accessUntilLabel {
                                LabeledContent("Access Until") {
                                    Text(accessUntilLabel)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
                .font(.subheadline)

                if let message = statusMessage {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(statusIsError ? .red : .secondary)
                } else if let productLoadErrorMessage = subscriptionStore.productLoadErrorMessage {
                    Text(productLoadErrorMessage)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }

                Button(action: onShowPlans) {
                    Text(primaryButtonTitle)
                        .frame(maxWidth: .infinity, alignment: .center)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                if subscriptionStore.isPro {
                    Toggle("Show Early Access Badge", isOn: $showsEarlyAccessBadge)
                        .font(.subheadline)
                }
            }
            .padding(.vertical, 6)
        } header: {
            Text("Early Access Status")
        } footer: {
            Text("Developing Hangar Express takes time and money. Show your *optional* support here.")
        }
        .task {
            await subscriptionStore.start()
        }
    }

    private var primaryButtonTitle: String {
        subscriptionStore.isPro ? AppLocalizer.string("Manage Plans") : AppLocalizer.string("See Plans")
    }

    private var statusSummary: String {
        subscriptionStore.isPro
            ? AppLocalizer.string("Early access to experimental features are enabled.")
            : AppLocalizer.string("Support development and get early access to experimental Labs features.")
    }

    private var nextRenewalLabel: String {
        guard let details = subscriptionStore.proSubscriptionDetails else {
            return AppLocalizer.string("Checking...")
        }

        if details.willAutoRenew == false {
            return AppLocalizer.string("Not scheduled")
        }

        guard let nextRenewalDate = details.nextRenewalDate else {
            return AppLocalizer.string("Unavailable")
        }

        return formattedSubscriptionDate(nextRenewalDate)
    }

    private var autoRenewalLabel: String {
        switch subscriptionStore.proSubscriptionDetails?.willAutoRenew {
        case true:
            return AppLocalizer.string("On")
        case false:
            return AppLocalizer.string("Off")
        case nil:
            return AppLocalizer.string("Checking...")
        }
    }

    private var autoRenewalStyle: Color {
        switch subscriptionStore.proSubscriptionDetails?.willAutoRenew {
        case true:
            return .green
        case false:
            return .orange
        case nil:
            return .secondary
        }
    }

    private var accessUntilLabel: String? {
        guard subscriptionStore.proSubscriptionDetails?.willAutoRenew == false,
              let expirationDate = subscriptionStore.proSubscriptionDetails?.expirationDate else {
            return nil
        }

        return formattedSubscriptionDate(expirationDate)
    }

    private var statusMessage: String? {
        subscriptionStatusMessage(for: subscriptionStore.purchaseStatus)
    }

    private var statusIsError: Bool {
        subscriptionStatusIsError(subscriptionStore.purchaseStatus)
    }
}

private struct ProPlansSheet: View {
    @Environment(\.dismiss) private var dismiss
    let subscriptionStore: SubscriptionStore

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    ProBenefitsCard(isPro: subscriptionStore.isPro)
                    EarlyAccessDisclaimerCard()
                    ProFeatureComparisonCard()
                    ProPlanActionsCard(subscriptionStore: subscriptionStore)
                }
                .padding()
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle(subscriptionStore.isPro ? AppLocalizer.string("Manage Early Access") : AppLocalizer.string("Hangar Express Early Access"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
            .task {
                await subscriptionStore.loadProducts()
                await subscriptionStore.refreshPurchasedProducts()
            }
        }
    }
}

private struct ProBenefitsCard: View {
    let isPro: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: isPro ? "checkmark.seal.fill" : "sparkles")
                    .font(.title2)
                    .foregroundStyle(isPro ? .green : Color.accentColor)

                VStack(alignment: .leading, spacing: 4) {
                    Text(isPro ? AppLocalizer.string("Your Early Access is active") : AppLocalizer.string("Get Hangar Express Early Access"))
                        .font(.headline)

                    Text("Early Access supports ongoing development and unlocks experimental Labs features before their public release.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.background, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private struct EarlyAccessDisclaimerCard: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Early Access Notice", systemImage: "exclamationmark.triangle.fill")
                .font(.headline)
                .foregroundStyle(.orange)

            Text("Early Access is optional support for Hangar Express development. You are not directly purchasing Star Citizen content, RSI items, gameplay access, or any Cloud Imperium Games or Roberts Space Industries entitlement through Hangar Express.")
                .font(.subheadline)
                .foregroundStyle(.primary)

            Text("As a supporter benefit, Hangar Express enables experimental Labs features for you to test. These app features may change, break, or become available to all users later.")
                .font(.subheadline)
                .foregroundStyle(.primary)

            Text("Hangar Express is an unofficial fan-made companion app and is not affiliated with, endorsed by, or sponsored by Cloud Imperium Games, Roberts Space Industries, or Star Citizen.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.orange.opacity(0.12))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.orange.opacity(0.28), lineWidth: 1)
        )
    }
}

private struct ProFeatureComparisonCard: View {
    private let rows = [
        FeatureComparisonRow(feature: "Experimental faster sync", standard: "Up to 2 pages", pro: "Up to 10 pages in Labs"),
        FeatureComparisonRow(feature: "Extended Hangar Log beta", standard: "Latest 5", pro: "Up to 500 in Labs"),
        FeatureComparisonRow(feature: "Multiple account switching beta", standard: "1 account", pro: "Up to 10 accounts in Labs")
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Lab Features Access")
                .font(.headline)

            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 10) {
                GridRow {
                    Text("Feature")
                    Text("Standard")
                    Text("Early Access")
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

                Divider()
                    .gridCellColumns(3)

                ForEach(rows) { row in
                    GridRow {
                        Text(row.feature)
                            .fontWeight(.medium)
                        Text(row.standard)
                            .foregroundStyle(.secondary)
                        Text(row.pro)
                            .foregroundStyle(.primary)
                    }
                }
            }
            .font(.footnote)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.background, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private struct ProPlanActionsCard: View {
    let subscriptionStore: SubscriptionStore

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(sectionTitle)
                .font(.headline)

            if let message = statusMessage {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(statusIsError ? .red : .secondary)
            } else if let productLoadErrorMessage = subscriptionStore.productLoadErrorMessage {
                Text(productLoadErrorMessage)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }

            if subscriptionStore.isPro {
                if let details = subscriptionStore.proSubscriptionDetails {
                    ProCurrentPlanSummary(details: details)
                }

                if subscriptionStore.hasActiveProSubscription {
                    Button {
                        let scene = currentForegroundWindowScene()
                        Task {
                            await subscriptionStore.manageSubscriptions(in: scene)
                        }
                    } label: {
                        Label("Manage Apple Subscription", systemImage: "slider.horizontal.3")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(statusIsBusy)
                }

                Button {
                    Task {
                        await subscriptionStore.restorePurchases()
                    }
                } label: {
                    Label("Restore Purchases", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .disabled(statusIsBusy)

                if !subscriptionStore.hasLifetimePro {
                    redeemCodeButton
                }
            } else {
                if subscriptionStore.proProducts.isEmpty {
                    Button {
                        Task {
                            await subscriptionStore.loadProducts()
                        }
                    } label: {
                        Label(
                            subscriptionStore.isLoadingProducts
                                ? AppLocalizer.string("Loading Plans")
                                : AppLocalizer.string("Load Plans"),
                            systemImage: "arrow.clockwise"
                        )
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(statusIsBusy || subscriptionStore.isLoadingProducts)
                } else {
                    ForEach(subscriptionStore.proProducts, id: \.id) { product in
                        ProPurchasePlanRow(
                            product: product,
                            isBusy: statusIsBusy,
                            onPurchase: {
                                Task {
                                    await subscriptionStore.purchasePro(productID: product.id)
                                }
                            }
                        )
                    }
                }

                Button {
                    Task {
                        await subscriptionStore.restorePurchases()
                    }
                } label: {
                    Label("Restore Purchases", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .disabled(statusIsBusy)

                if !subscriptionStore.hasLifetimePro {
                    redeemCodeButton
                }
            }

            Text("Purchases are managed by Apple. You can change, cancel, or restore subscriptions from your Apple Account at any time.")
                .font(.caption)
                .foregroundStyle(.secondary)

            SubscriptionLegalLinks()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.background, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var statusMessage: String? {
        subscriptionStatusMessage(for: subscriptionStore.purchaseStatus)
    }

    private var statusIsError: Bool {
        subscriptionStatusIsError(subscriptionStore.purchaseStatus)
    }

    private var statusIsBusy: Bool {
        subscriptionStatusIsBusy(subscriptionStore.purchaseStatus)
    }

    private var sectionTitle: String {
        if subscriptionStore.isPro {
            return subscriptionStore.hasLifetimePro && !subscriptionStore.hasActiveProSubscription
                ? AppLocalizer.string("Purchase")
                : AppLocalizer.string("Subscription")
        }

        return AppLocalizer.string("Plans")
    }

    private var redeemCodeButton: some View {
        Button {
            let scene = currentForegroundWindowScene()
            Task {
                await subscriptionStore.redeemCode(in: scene)
            }
        } label: {
            Label("Redeem Code", systemImage: "ticket")
        }
        .buttonStyle(.bordered)
        .disabled(statusIsBusy)
    }
}

private struct SubscriptionLegalLinks: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()

            Text("Review before purchase")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            Link(destination: LegalLinkDestinations.privacyPolicyURL) {
                Label("Privacy Policy", systemImage: "lock.shield")
            }

            Link(destination: LegalLinkDestinations.termsOfUseURL) {
                Label("Terms of Use (EULA)", systemImage: "doc.text")
            }
        }
        .font(.caption)
    }
}

private struct ProPurchasePlanRow: View {
    let product: Product
    let isBusy: Bool
    let onPurchase: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(planTitle(for: product))
                    .font(.subheadline.weight(.semibold))

                Text(planSubtitle(for: product))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer(minLength: 8)

            Button(action: onPurchase) {
                Text(product.displayPrice)
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
                    .frame(minWidth: 72)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
            .disabled(isBusy)
        }
        .padding(.vertical, 4)
    }
}

private struct ProCurrentPlanSummary: View {
    let details: ProSubscriptionDetails

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            LabeledContent("Current Plan", value: details.displayName)

            if details.isLifetime {
                LabeledContent("Access", value: AppLocalizer.string("Lifetime"))
            } else {
                LabeledContent("Auto Renewal", value: autoRenewalLabel)

                if let renewalLabel {
                    LabeledContent("Next Renewal", value: renewalLabel)
                }

                if let accessUntilLabel {
                    LabeledContent("Access Until", value: accessUntilLabel)
                }
            }
        }
        .font(.subheadline)
    }

    private var autoRenewalLabel: String {
        switch details.willAutoRenew {
        case true:
            return AppLocalizer.string("On")
        case false:
            return AppLocalizer.string("Off")
        case nil:
            return AppLocalizer.string("Checking...")
        }
    }

    private var renewalLabel: String? {
        guard details.willAutoRenew != false,
              let nextRenewalDate = details.nextRenewalDate else {
            return nil
        }

        return formattedSubscriptionDate(nextRenewalDate)
    }

    private var accessUntilLabel: String? {
        guard details.willAutoRenew == false,
              let expirationDate = details.expirationDate else {
            return nil
        }

        return formattedSubscriptionDate(expirationDate)
    }
}

private struct FeatureComparisonRow: Identifiable {
    let id: String
    let feature: LocalizedStringKey
    let standard: LocalizedStringKey
    let pro: LocalizedStringKey

    init(feature: String, standard: String, pro: String) {
        id = feature
        self.feature = LocalizedStringKey(feature)
        self.standard = LocalizedStringKey(standard)
        self.pro = LocalizedStringKey(pro)
    }
}

private func planTitle(for product: Product) -> String {
    switch product.id {
    case ProSubscriptionConfiguration.monthlyProductID:
        return AppLocalizer.string("Monthly Early Access")
    case ProSubscriptionConfiguration.yearlyProductID:
        return AppLocalizer.string("Yearly Early Access")
    case ProSubscriptionConfiguration.lifetimeProductID:
        return AppLocalizer.string("Early Access for Life")
    default:
        return AppLocalizer.string("Early Access")
    }
}

private func planSubtitle(for product: Product) -> String {
    switch product.id {
    case ProSubscriptionConfiguration.monthlyProductID:
        return AppLocalizer.string("Labs access - 1 month")
    case ProSubscriptionConfiguration.yearlyProductID:
        return AppLocalizer.string("Labs access - 1 year")
    case ProSubscriptionConfiguration.lifetimeProductID:
        return AppLocalizer.string("Lifetime Labs access")
    default:
        return AppLocalizer.string("Experimental Labs access")
    }
}

private func subscriptionStatusMessage(for purchaseStatus: SubscriptionStore.PurchaseStatus) -> String? {
    switch purchaseStatus {
    case .idle:
        return nil
    case .purchasing:
        return AppLocalizer.string("Opening App Store purchase sheet.")
    case .restoring:
        return AppLocalizer.string("Restoring purchases.")
    case .managing:
        return AppLocalizer.string("Opening Apple subscription management.")
    case .redeeming:
        return AppLocalizer.string("Opening StoreKit code redemption.")
    case let .success(message), let .failed(message):
        return message
    }
}

private func subscriptionStatusIsError(_ purchaseStatus: SubscriptionStore.PurchaseStatus) -> Bool {
    if case .failed = purchaseStatus {
        return true
    }

    return false
}

private func subscriptionStatusIsBusy(_ purchaseStatus: SubscriptionStore.PurchaseStatus) -> Bool {
    switch purchaseStatus {
    case .purchasing, .restoring, .managing, .redeeming:
        return true
    case .idle, .success, .failed:
        return false
    }
}

private func formattedSubscriptionDate(_ date: Date) -> String {
    AppLocalizer.displayDate(date)
}

@MainActor
private func currentForegroundWindowScene() -> UIWindowScene? {
    UIApplication.shared.connectedScenes
        .compactMap { $0 as? UIWindowScene }
        .first { $0.activationState == .foregroundActive }
        ?? UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
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
                    Text("Current")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.green)
                } else if canSwitch {
                    Button("Switch", action: onSwitch)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                } else {
                    Button("EA", action: onUpgrade)
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

        if session.isReadOnly {
            return AppLocalizer.format("%@ saved, read-only account", cookieSummary)
        }

        return cookieSummary
    }
}
