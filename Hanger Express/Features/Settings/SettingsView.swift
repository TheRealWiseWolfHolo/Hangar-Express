import StoreKit
import SwiftUI
import UIKit

private enum LegalLinkDestinations {
    static let privacyPolicyURL = URL(string: "https://github.com/TheRealWiseWolfHolo/Hangar-Express/blob/main/PRIVACY_POLICY.md")!
    static let termsOfUseURL = URL(string: "https://github.com/TheRealWiseWolfHolo/Hangar-Express/blob/main/TERMS_OF_USE.md")!
}

private enum CloudTranslationDictionaryRefreshState: Equatable {
    case idle
    case refreshing
    case succeeded(Date)
    case failed(String)
}

private struct CloudTranslationCoverage {
    let approvedCount: Int
    let totalCount: Int

    init(
        snapshot: HangarSnapshot,
        dictionary: HangarItemTranslationDictionary?
    ) {
        let candidates = RemoteHangarItemTranslationSuggestionClassifier.candidates(
            from: snapshot
        )
        totalCount = candidates.count
        approvedCount = candidates.reduce(into: 0) { count, candidate in
            if dictionary?.translation(for: candidate.source) != nil {
                count += 1
            }
        }
    }

    var fractionComplete: Double {
        guard totalCount > 0 else {
            return 0
        }
        return Double(approvedCount) / Double(totalCount)
    }

    var missingCount: Int {
        max(totalCount - approvedCount, 0)
    }
}

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage(AppLanguage.storageKey) private var appLanguageRawValue = AppLanguage.system.rawValue
    @AppStorage(HangarItemLanguage.storageKey) private var hangarItemLanguageRawValue = HangarItemLanguage.original.rawValue
    @AppStorage(HangarItemTranslationMissMode.storageKey) private var itemTranslationMissModeRawValue = HangarItemTranslationMissMode.onDevice.rawValue
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
    @State private var itemTranslationState = HangarItemTranslationViewState()
    @State private var cloudDictionaryRefreshState = CloudTranslationDictionaryRefreshState.idle
    @State private var itemTranslationMethodPrompt: AppModel.ItemTranslationMethodPrompt?

    let appModel: AppModel
    let snapshot: HangarSnapshot

    private let repositoryURL = URL(string: "https://github.com/TheRealWiseWolfHolo/Hangar-Express")!
    private let spviewerURL = URL(string: "https://www.spviewer.eu/")!
    private let starCitizenWikiURL = URL(string: "https://starcitizen.tools/")!
    private let anywhereExpURL = URL(string: "https://robertsspaceindustries.com/en/orgs/ANYWHEREXP")!

    var body: some View {
        NavigationStack {
            List {
                ProSubscriptionSection(
                    subscriptionStore: appModel.subscriptionStore,
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
                    .onChange(of: hangarItemLanguageRawValue) { _, newValue in
                        handleItemLanguageChange(
                            HangarItemLanguage.resolved(from: newValue)
                        )
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

                if RemoteHangarItemTranslationRollout.isEnabled,
                   HangarItemLanguage.resolved(
                       from: hangarItemLanguageRawValue
                   ) == .simplifiedChinese {
                    Section {
                        Picker(
                            "Translation Mode",
                            selection: $itemTranslationMissModeRawValue
                        ) {
                            Text("Local")
                                .tag(HangarItemTranslationMissMode.onDevice.rawValue)
                            Text("Cloud")
                                .tag(HangarItemTranslationMissMode.cloudReview.rawValue)
                        }
                        .pickerStyle(.menu)
                        .onChange(of: itemTranslationMissModeRawValue) { _, _ in
                            let mode = HangarItemTranslationMissMode(
                                rawValue: itemTranslationMissModeRawValue
                            ) ?? .onDevice
                            appModel.selectItemTranslationMissMode(mode)
                        }

                        if HangarItemTranslationMissMode.resolved(
                            from: itemTranslationMissModeRawValue
                        ) == .cloudReview {
                            CloudTranslationDictionaryStatusView(
                                coverage: CloudTranslationCoverage(
                                    snapshot: snapshot,
                                    dictionary: itemTranslationState.dictionary
                                ),
                                dictionary: itemTranslationState.dictionary,
                                uploadProgress: appModel.cloudItemTranslationUploadProgress,
                                refreshState: cloudDictionaryRefreshState,
                                onRefresh: {
                                    Task {
                                        await refreshCloudTranslationDictionary()
                                    }
                                }
                            )
                            .task(
                                id: "\(hangarItemLanguageRawValue)-\(appModel.itemTranslationDictionaryRefreshGeneration)"
                            ) {
                                await itemTranslationState.loadDictionary(
                                    for: hangarItemLanguageRawValue,
                                    refreshGeneration: appModel.itemTranslationDictionaryRefreshGeneration
                                )
                            }
                        }
                    } header: {
                        Text("Item Translation")
                    } footer: {
                        if HangarItemTranslationMissMode.resolved(
                            from: itemTranslationMissModeRawValue
                        ) == .cloudReview {
                            Text(
                                "Only text that needs translation is uploaded. No personally identifiable information is uploaded. New terms remain in English until reviewed and published."
                            )
                        } else {
                            Text(
                                "Both modes download the approved hosted dictionary. Local mode uses Apple's on-device translation model for missing terms and does not send those terms to the Hangar Express translation service."
                            )
                        }
                    }
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
                    Text("Hangar Express is open-source software and an unofficial Star Citizen fan project. It is not affiliated with the Cloud Imperium group of companies. Star Citizen, Squadron 42, Roberts Space Industries, and related game content shown by this app belong to the Cloud Imperium group of companies and their respective owners.")
                        .font(.footnote)

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
                ProPlansSheet(
                    subscriptionStore: appModel.subscriptionStore,
                    showsEarlyAccessBadge: $showsEarlyAccessBadge
                )
                    .presentationDetents([.medium, .large])
            }
            .sheet(item: $itemTranslationMethodPrompt) { prompt in
                ItemTranslationMethodChooserView(
                    prompt: prompt,
                    onSelect: { mode in
                        itemTranslationMethodPrompt = nil
                        appModel.selectItemTranslationMissMode(mode)
                    }
                )
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .interactiveDismissDisabled()
            }
        }
    }

    private func handleItemLanguageChange(_ language: HangarItemLanguage) {
        guard HangarItemTranslationMethodPromptPolicy.shouldPrompt(
            for: language
        ) else {
            itemTranslationMethodPrompt = nil
            appModel.requestItemTranslationPreprocessingForCurrentSnapshot()
            return
        }

        itemTranslationMethodPrompt = AppModel.ItemTranslationMethodPrompt(
            language: language,
            currentMode: HangarItemTranslationMissMode.resolved(
                from: itemTranslationMissModeRawValue
            ),
            reason: .languageSelection
        )
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

    private func refreshCloudTranslationDictionary() async {
        guard cloudDictionaryRefreshState != .refreshing else {
            return
        }

        cloudDictionaryRefreshState = .refreshing
        do {
            try await itemTranslationState.refreshDictionary(
                for: hangarItemLanguageRawValue
            )
            appModel.didRefreshHostedItemTranslationDictionary()
            cloudDictionaryRefreshState = .succeeded(.now)
        } catch {
            cloudDictionaryRefreshState = .failed(error.localizedDescription)
        }
    }
}

private struct ProSubscriptionSection: View {
    let subscriptionStore: SubscriptionStore
    let onShowPlans: () -> Void

    var body: some View {
        Section {
            Button(action: onShowPlans) {
                HStack(spacing: 14) {
                    ZStack {
                        Circle()
                            .fill(statusColor.opacity(0.14))
                            .frame(width: 46, height: 46)

                        Image(systemName: subscriptionStore.isPro ? "checkmark.seal.fill" : "sparkles")
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(statusColor)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            Text("Early Access")
                                .font(.headline)

                            if subscriptionStore.isPro {
                                Text("Active")
                                    .font(.caption2.weight(.bold))
                                    .foregroundStyle(.green)
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 3)
                                    .background(.green.opacity(0.14), in: Capsule())
                            }
                        }

                        Text(planSummary)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(subscriptionStore.isPro ? 1 : 2)

                        if let accessSummary {
                            Text(accessSummary)
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                        }
                    }

                    Spacer(minLength: 8)

                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                .padding(.vertical, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint(Text(primaryButtonTitle))
        }
        .task {
            await subscriptionStore.start()
        }
    }

    private var primaryButtonTitle: String {
        subscriptionStore.isPro ? AppLocalizer.string("Manage Plans") : AppLocalizer.string("See Plans")
    }

    private var statusColor: Color {
        subscriptionStore.isPro ? .green : Color.accentColor
    }

    private var planSummary: String {
        guard subscriptionStore.isPro else {
            return AppLocalizer.string("Support development and get early access to experimental Labs features.")
        }

        if subscriptionStore.proSubscriptionDetails?.isLifetime == true {
            return AppLocalizer.string("Lifetime Access")
        }

        return subscriptionStore.proSubscriptionDetails?.displayName
            ?? AppLocalizer.string("Hangar Express Early Access")
    }

    private var accessSummary: String? {
        guard subscriptionStore.isPro else {
            return AppLocalizer.string("See Plans")
        }

        guard let details = subscriptionStore.proSubscriptionDetails else {
            return AppLocalizer.string("Access verified")
        }

        if details.isLifetime {
            return nil
        }

        if details.willAutoRenew == false, let expirationDate = details.expirationDate {
            return AppLocalizer.format("Access ends %@", formattedSubscriptionDate(expirationDate))
        }

        if let nextRenewalDate = details.nextRenewalDate {
            return AppLocalizer.format("Renews %@", formattedSubscriptionDate(nextRenewalDate))
        }

        return AppLocalizer.string("Access verified")
    }
}

private struct ProPlansSheet: View {
    @Environment(\.dismiss) private var dismiss
    let subscriptionStore: SubscriptionStore
    @Binding var showsEarlyAccessBadge: Bool

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    ProBenefitsCard(isPro: subscriptionStore.isPro)
                    if subscriptionStore.isPro {
                        EarlyAccessPreferencesCard(
                            showsEarlyAccessBadge: $showsEarlyAccessBadge
                        )
                    }
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

private struct CloudTranslationDictionaryStatusView: View {
    let coverage: CloudTranslationCoverage
    let dictionary: HangarItemTranslationDictionary?
    let uploadProgress: AppModel.CloudItemTranslationUploadProgress?
    let refreshState: CloudTranslationDictionaryRefreshState
    let onRefresh: () -> Void

    private var isRefreshing: Bool {
        refreshState == .refreshing
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Text("Approved catalog coverage")
                        .font(.subheadline.weight(.semibold))

                    Spacer()

                    Text(
                        AppLocalizer.format(
                            "%lld of %lld",
                            Int64(coverage.approvedCount),
                            Int64(coverage.totalCount)
                        )
                    )
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                }

                ProgressView(value: coverage.fractionComplete)
                    .tint(.blue)

                Text(
                    AppLocalizer.format(
                        "%lld catalog terms are still missing from the approved dictionary.",
                        Int64(coverage.missingCount)
                    )
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            if let uploadProgress {
                Divider()

                VStack(alignment: .leading, spacing: 7) {
                    HStack {
                        uploadProgressTitle(uploadProgress.phase)
                            .font(.subheadline.weight(.semibold))

                        Spacer()

                        Text(
                            AppLocalizer.format(
                                "%lld of %lld",
                                Int64(uploadProgress.completedCount),
                                Int64(uploadProgress.totalCount)
                            )
                        )
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    }

                    ProgressView(value: uploadProgress.fractionComplete)
                        .tint(uploadProgress.phase == .interrupted ? .orange : .blue)

                    uploadProgressDetail(uploadProgress)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    if let dictionary {
                        Text(
                            AppLocalizer.format(
                                "Dictionary v%lld • %lld approved entries",
                                Int64(dictionary.version),
                                Int64(dictionary.entries.count)
                            )
                        )
                        .font(.caption.weight(.medium))
                    } else {
                        Text("No verified cloud dictionary is available.")
                            .font(.caption.weight(.medium))
                    }

                    refreshDetail
                        .font(.caption)
                        .foregroundStyle(refreshDetailColor)
                }

                Spacer(minLength: 8)

                Button(action: onRefresh) {
                    if isRefreshing {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                }
                .buttonStyle(.bordered)
                .disabled(isRefreshing)
                .accessibilityLabel("Refresh translations from cloud")
            }
        }
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private func uploadProgressTitle(
        _ phase: AppModel.CloudItemTranslationUploadProgress.Phase
    ) -> some View {
        switch phase {
        case .uploading:
            Text("Uploading missing terms")
        case .interrupted:
            Text("Upload paused")
        }
    }

    @ViewBuilder
    private func uploadProgressDetail(
        _ progress: AppModel.CloudItemTranslationUploadProgress
    ) -> some View {
        switch progress.phase {
        case .uploading:
            Text(
                AppLocalizer.format(
                    "%lld of %lld catalog terms uploaded.",
                    Int64(progress.completedCount),
                    Int64(progress.totalCount)
                )
            )
        case .interrupted:
            Text("Completed batches were saved. The remaining terms will retry later.")
        }
    }

    @ViewBuilder
    private var refreshDetail: some View {
        switch refreshState {
        case .idle:
            Text("Refresh to check for newly approved translations.")
        case .refreshing:
            Text("Downloading and verifying the latest cloud dictionary…")
        case let .succeeded(date):
            Text(
                AppLocalizer.format(
                    "Updated %@",
                    date.formatted(.relative(presentation: .numeric))
                )
            )
        case let .failed(message):
            Text(AppLocalizer.format("Refresh failed: %@", message))
        }
    }

    private var refreshDetailColor: Color {
        if case .failed = refreshState {
            return .red
        }
        return .secondary
    }
}

private struct EarlyAccessPreferencesCard: View {
    @Binding var showsEarlyAccessBadge: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Preferences")
                .font(.headline)

            Toggle("Show Early Access Badge", isOn: $showsEarlyAccessBadge)

            Text("Show or hide the Early Access badge beside your profile name.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .earlyAccessCardStyle()
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

                    Text("Hangar Express is free, but development takes time, money, and resources. Show your *optional* support here.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .earlyAccessCardStyle()
    }
}

private struct EarlyAccessDisclaimerCard: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Early Access Notice", systemImage: "exclamationmark.triangle.fill")
                .font(.headline)
                .foregroundStyle(.orange)

            Text("Supporting Hangar Express supports this app's independent development only. It does not buy any Star Citizen content, RSI items, gameplay access, products, or entitlements from Cloud Imperium Games or Roberts Space Industries.")
                .font(.subheadline)
                .foregroundStyle(.primary)

            Text("Early Access may include experimental Labs features, but support does not guarantee any specific app feature, continued availability, or future functionality. Features may change, break, be removed, or become available to everyone.")
                .font(.subheadline)
                .foregroundStyle(.primary)

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
        FeatureComparisonRow(feature: "Sync Speed", standard: "2x", pro: "Up to 10x"),
        FeatureComparisonRow(feature: "Hangar Log", standard: "Up to 5 Entries", pro: "Up to 500 Entries"),
        FeatureComparisonRow(feature: "Account Switching", standard: "1 Account", pro: "Up to 10 Accounts")
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
        .earlyAccessCardStyle()
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
                    Label("Restore Access", systemImage: "arrow.clockwise")
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
                    Label("Restore Access", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .disabled(statusIsBusy)

                if !subscriptionStore.hasLifetimePro {
                    redeemCodeButton
                }
            }

            Text("Your plan is managed by Apple. You can change, cancel, or restore access from your Apple Account at any time.")
                .font(.caption)
                .foregroundStyle(.secondary)

            SubscriptionLegalLinks()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .earlyAccessCardStyle()
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
                ? AppLocalizer.string("Plan Details")
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

private struct EarlyAccessCardStyle: ViewModifier {
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)

        content
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: shape)
            .overlay {
                shape.stroke(Color.primary.opacity(0.10), lineWidth: 1)
            }
    }
}

private extension View {
    func earlyAccessCardStyle() -> some View {
        modifier(EarlyAccessCardStyle())
    }
}

private struct SubscriptionLegalLinks: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()

            Text("Legal & Privacy")
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
        return AppLocalizer.string("Opening App Store confirmation.")
    case .restoring:
        return AppLocalizer.string("Restoring access.")
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
