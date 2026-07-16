import Foundation
import Observation

private nonisolated enum ItemTranslationDictionaryLoadResult: Sendable {
    case loaded(HangarItemTranslationDictionary)
    case unavailable
    case timedOut

    var dictionary: HangarItemTranslationDictionary? {
        switch self {
        case let .loaded(dictionary):
            return dictionary
        case .unavailable, .timedOut:
            return nil
        }
    }
}

enum SyncPreferences {
    enum InventoryAutoRefreshInterval: String, CaseIterable, Identifiable {
        case everyLaunch
        case oneDay
        case threeDays
        case sevenDays
        case thirtyDays
        case never

        var id: Self { self }

        var title: String {
            switch self {
            case .everyLaunch:
                return "Every Time I Open the App"
            case .oneDay:
                return "1 Day"
            case .threeDays:
                return "3 Days"
            case .sevenDays:
                return "7 Days"
            case .thirtyDays:
                return "30 Days"
            case .never:
                return "Never"
            }
        }

        var refreshInterval: TimeInterval? {
            switch self {
            case .everyLaunch:
                return 0
            case .oneDay:
                return 24 * 60 * 60
            case .threeDays:
                return 3 * 24 * 60 * 60
            case .sevenDays:
                return 7 * 24 * 60 * 60
            case .thirtyDays:
                return 30 * 24 * 60 * 60
            case .never:
                return nil
            }
        }
    }

    static let workerCountKey = "sync.workerCount"
    static let inventoryAutoRefreshIntervalKey = "sync.inventoryAutoRefreshInterval"
    static let defaultWorkerCount = ProSubscriptionConfiguration.standardRefreshWorkerLimit
    static let defaultInventoryAutoRefreshInterval = InventoryAutoRefreshInterval.sevenDays
    static let minWorkerCount = 1
    static let maxWorkerCount = ProSubscriptionConfiguration.proRefreshWorkerLimit

    static func maxWorkerCount(isPro: Bool) -> Int {
        ProSubscriptionConfiguration.refreshWorkerLimit(isPro: isPro)
    }

    static func constrainedWorkerCount(_ count: Int, isPro: Bool) -> Int {
        min(
            max(count, minWorkerCount),
            maxWorkerCount(isPro: isPro)
        )
    }

    static func resolvedInventoryAutoRefreshInterval(
        from rawValue: String?
    ) -> InventoryAutoRefreshInterval {
        guard let rawValue else {
            return defaultInventoryAutoRefreshInterval
        }

        return InventoryAutoRefreshInterval(rawValue: rawValue) ?? defaultInventoryAutoRefreshInterval
    }

    static func shouldAutoRefreshInventory(
        lastRefreshAt: Date?,
        interval: InventoryAutoRefreshInterval,
        now: Date = .now
    ) -> Bool {
        guard let refreshInterval = interval.refreshInterval else {
            return false
        }

        guard let lastRefreshAt else {
            return true
        }

        return now.timeIntervalSince(lastRefreshAt) >= refreshInterval
    }
}

enum DisplayPreferences {
    static let compositeUpgradeThumbnailModeKey = "display.compositeUpgradeThumbnails"
    static let compositeUpgradeThumbnailsEnabledByDefault = true
    static let hangarUpgradedShipDisplayModeKey = "display.hangarUpgradedShipDisplayMode"
    static let hangarUpgradedShipDisplayEnabledByDefault = true
    static let hangarGiftedHighlightKey = "display.hangarGiftedHighlight"
    static let hangarGiftedHighlightEnabledByDefault = true
    static let hangarUpgradedHighlightKey = "display.hangarUpgradedHighlight"
    static let hangarUpgradedHighlightEnabledByDefault = true
    static let earlyAccessBadgeKey = "display.earlyAccessBadge"
    static let earlyAccessBadgeEnabledByDefault = true
    static let sharePictureAutoCopiesDebugLogKey = "display.sharePictureAutoCopiesDebugLog"
    static let sharePictureAutoCopiesDebugLogEnabledByDefault = false
    static let hangarBulkSelectionKey = "display.hangarBulkSelection"
    static let hangarBulkSelectionEnabledByDefault = false
}

@MainActor
private final class RefreshProgressDisplayRelay {
    private static let displayCadenceNanoseconds: UInt64 = 500_000_000
    private static let regressionTolerance = 0.0001

    private struct ProgressKey: Hashable {
        let rawValue: String

        init(_ progress: RefreshProgress) {
            rawValue = progress.trackerID.map { "tracker:\($0)" } ?? "single"
        }
    }

    private let apply: (RefreshProgress) -> Void
    private var pendingProgress: [ProgressKey: RefreshProgress] = [:]
    private var pendingProgressKeys: [ProgressKey] = []
    private var displayedFractions: [ProgressKey: Double] = [:]
    private var displayTask: Task<Void, Never>?
    private var isCancelled = false

    init(apply: @escaping (RefreshProgress) -> Void) {
        self.apply = apply
    }

    func submit(_ progress: RefreshProgress) {
        guard !isCancelled else {
            return
        }

        let key = ProgressKey(progress)
        guard shouldAccept(progress, for: key) else {
            return
        }

        if pendingProgress[key] == nil {
            pendingProgressKeys.append(key)
        }
        pendingProgress[key] = progress

        guard displayTask == nil else {
            return
        }

        displayTask = Task { [weak self] in
            await self?.drain()
        }
    }

    func cancel() {
        isCancelled = true
        pendingProgress.removeAll()
        pendingProgressKeys.removeAll()
        displayedFractions.removeAll()
        displayTask?.cancel()
        displayTask = nil
    }

    private func drain() async {
        while !Task.isCancelled {
            guard !pendingProgress.isEmpty, !isCancelled else {
                displayTask = nil
                return
            }

            let progressBatch = pendingProgressKeys.compactMap { key -> (ProgressKey, RefreshProgress)? in
                guard let progress = pendingProgress[key] else {
                    return nil
                }

                return (key, progress)
            }
            pendingProgress.removeAll(keepingCapacity: true)
            pendingProgressKeys.removeAll(keepingCapacity: true)

            for (key, progress) in progressBatch {
                if let displayFraction = progress.displayFractionCompleted {
                    displayedFractions[key] = max(displayedFractions[key] ?? displayFraction, displayFraction)
                }
                apply(progress)
            }

            try? await Task.sleep(nanoseconds: Self.displayCadenceNanoseconds)
        }
    }

    private func shouldAccept(_ progress: RefreshProgress, for key: ProgressKey) -> Bool {
        guard let incomingFraction = progress.displayFractionCompleted else {
            return true
        }

        if let pendingFraction = pendingProgress[key]?.displayFractionCompleted,
           pendingFraction - incomingFraction > Self.regressionTolerance {
            return false
        }

        if let displayedFraction = displayedFractions[key],
           displayedFraction - incomingFraction > Self.regressionTolerance {
            return false
        }

        return true
    }
}

@MainActor
@Observable
final class AppModel {
    struct AuthenticationDraft {
        let loginIdentifier: String
        let password: String
        let rememberMe: Bool
        let notice: String?
    }

    struct ReauthenticationPrompt: Identifiable {
        let id = UUID()
        let title: String
        let message: String
    }

    struct VersionRefreshPrompt: Identifiable {
        let id = UUID()
        let previousVersion: String
        let currentVersion: String
        let updateNoteKeys: [String]

        init(
            previousVersion: String,
            currentVersion: String,
            updateNoteKeys: [String] = []
        ) {
            self.previousVersion = previousVersion
            self.currentVersion = currentVersion
            self.updateNoteKeys = updateNoteKeys
        }

        var title: String {
            AppLocalizer.string("App Updated")
        }

        var message: String {
            AppLocalizer.format(
                "Hangar Express was updated from %@ to %@. Run a full refresh so your cached hangar, fleet, buy-back, and log data stay in sync with this build.",
                previousVersion,
                currentVersion
            )
        }

        var updateNotesTitle: String {
            AppLocalizer.string("What's New")
        }

        var updateNotes: [String] {
            updateNoteKeys.map(AppLocalizer.string)
        }
    }

    struct ItemTranslationPreprocessPrompt: Identifiable {
        enum Reason {
            case missingCache
            case cacheCleared
        }

        let id = UUID()
        let language: HangarItemLanguage
        let reason: Reason

        var title: String {
            switch language {
            case .original:
                switch reason {
                case .missingCache:
                    return AppLocalizer.string("Pre-process Hangar Item Translations?")
                case .cacheCleared:
                    return AppLocalizer.string("Rebuild Hangar Item Translations?")
                }
            case .simplifiedChinese:
                switch reason {
                case .missingCache:
                    return "预处理机库物品翻译？"
                case .cacheCleared:
                    return "重建机库物品翻译？"
                }
            }
        }

        var message: String {
            switch language {
            case .original:
                switch reason {
                case .missingCache:
                    return AppLocalizer.string("Hangar Express could not find a saved translation cache for your selected hangar item language. Pre-process now to translate this hangar in the background and keep browsing smooth.")
                case .cacheCleared:
                    return AppLocalizer.string("Translation cache was cleared. Rebuild the translation cache now to keep browsing smooth.")
                }
            case .simplifiedChinese:
                switch reason {
                case .missingCache:
                    return "未找到当前机库物品语言的已保存翻译缓存。现在预处理可在后台翻译此机库，并保持浏览流畅。"
                case .cacheCleared:
                    return "翻译缓存已清除。现在重建翻译缓存可保持浏览流畅。"
                }
            }
        }

        var primaryActionTitle: String {
            switch language {
            case .original:
                switch reason {
                case .missingCache:
                    return AppLocalizer.string("Pre-process")
                case .cacheCleared:
                    return AppLocalizer.string("Rebuild")
                }
            case .simplifiedChinese:
                switch reason {
                case .missingCache:
                    return "预处理"
                case .cacheCleared:
                    return "重建"
                }
            }
        }

        var secondaryActionTitle: String {
            switch language {
            case .original:
                return AppLocalizer.string("Later")
            case .simplifiedChinese:
                return "稍后"
            }
        }
    }

    struct ItemTranslationPreloadProgress: Equatable {
        enum Phase: Equatable {
            case preparing
            case translating
            case finished
            case downloadRequired
            case unavailable
            case failed
            case timedOut
        }

        let language: HangarItemLanguage
        let phase: Phase
        let completedUnitCount: Int
        let totalUnitCount: Int

        var title: String {
            switch language {
            case .original:
                return englishTitle
            case .simplifiedChinese:
                return simplifiedChineseTitle
            }
        }

        var detail: String {
            switch language {
            case .original:
                return englishDetail
            case .simplifiedChinese:
                return simplifiedChineseDetail
            }
        }

        var fractionCompleted: Double? {
            guard totalUnitCount > 0 else {
                return nil
            }

            let boundedCompletedCount = min(max(completedUnitCount, 0), totalUnitCount)
            return Double(boundedCompletedCount) / Double(totalUnitCount)
        }

        var isTerminal: Bool {
            switch phase {
            case .finished, .downloadRequired, .unavailable, .failed, .timedOut:
                return true
            case .preparing, .translating:
                return false
            }
        }

        var showsCancelAction: Bool {
            switch phase {
            case .downloadRequired, .unavailable, .failed, .timedOut:
                return true
            case .preparing, .translating, .finished:
                return false
            }
        }

        var showsDownloadModelAction: Bool {
            phase == .downloadRequired
        }

        var downloadModelActionTitle: String {
            switch language {
            case .original:
                return "Download Translation Model"
            case .simplifiedChinese:
                return "下载翻译模型"
            }
        }

        var cancelActionTitle: String {
            switch language {
            case .original:
                return AppLocalizer.string("Cancel")
            case .simplifiedChinese:
                return "取消"
            }
        }

        private var englishTitle: String {
            switch phase {
            case .preparing:
                return "Preparing Hangar Item Translations"
            case .translating:
                return "Pre-processing Hangar Item Translations"
            case .finished:
                return "Hangar Item Translations Ready"
            case .downloadRequired:
                return "Translation Model Required"
            case .unavailable:
                return "Translation Model Unavailable"
            case .failed:
                return "Hangar Item Translation Failed"
            case .timedOut:
                return "Hangar Item Translation Timed Out"
            }
        }

        private var simplifiedChineseTitle: String {
            switch phase {
            case .preparing:
                return "正在准备机库物品翻译"
            case .translating:
                return "正在预处理机库物品翻译"
            case .finished:
                return "机库物品翻译已准备好"
            case .downloadRequired:
                return "需要下载翻译模型"
            case .unavailable:
                return "翻译模型不可用"
            case .failed:
                return "机库物品翻译失败"
            case .timedOut:
                return "机库物品翻译超时"
            }
        }

        private var englishDetail: String {
            switch phase {
            case .preparing:
                return "Checking the saved cache and on-device translation model."
            case .translating:
                return "Processed \(completedUnitCount) of \(totalUnitCount) items."
            case .finished:
                if totalUnitCount > 0 {
                    return "Processed \(completedUnitCount) of \(totalUnitCount) items."
                }
                return "No new translations were needed."
            case .downloadRequired:
                return "Download the English to Chinese on-device translation model to pre-process hangar item translations."
            case .unavailable:
                return "The English to Chinese on-device translation model is not available on this device."
            case .failed:
                return "Unable to finish pre-processing. You can try again later."
            case .timedOut:
                return "The translation preparation stopped responding. Try again after the on-device translation model is available."
            }
        }

        private var simplifiedChineseDetail: String {
            switch phase {
            case .preparing:
                return "正在检查已保存缓存和本机翻译模型。"
            case .translating:
                return "已处理 \(completedUnitCount) / \(totalUnitCount) 项。"
            case .finished:
                if totalUnitCount > 0 {
                    return "已处理 \(completedUnitCount) / \(totalUnitCount) 项。"
                }
                return "没有新的翻译需要处理。"
            case .downloadRequired:
                return "下载英语到简体中文的本机翻译模型后，即可预处理机库物品翻译。"
            case .unavailable:
                return "此设备暂不支持英语到简体中文的本机翻译模型。"
            case .failed:
                return "无法完成预处理。稍后可以再试。"
            case .timedOut:
                return "翻译准备没有响应。请确认本机翻译模型可用后再试。"
            }
        }
    }

    struct ItemTranslationPreloadLogEntry: Identifiable, Equatable {
        let id = UUID()
        let occurredAt: Date
        let message: String
    }

    struct StartupActivity: Identifiable, Equatable {
        let id = UUID()
        let title: String
        let detail: String
    }

    struct ConcurrentRefreshEntry: Identifiable, Hashable {
        enum Area: String, Hashable, CaseIterable {
            case hangar
            case buyback
            case account

            var title: String {
                switch self {
                case .hangar:
                    return AppLocalizer.string("Hangar")
                case .buyback:
                    return AppLocalizer.string("Buy Back")
                case .account:
                    return AppLocalizer.string("Account")
                }
            }

            var syncReadyMessage: String {
                switch self {
                case .hangar:
                    return AppLocalizer.string("Hangar sync is ready.")
                case .buyback:
                    return AppLocalizer.string("Buyback sync is ready.")
                case .account:
                    return AppLocalizer.string("Account sync is ready.")
                }
            }
        }

        let area: Area
        let progress: RefreshProgress
        let isComplete: Bool

        var id: Area { area }
    }

    struct TransientBanner: Identifiable, Equatable {
        enum Style: Equatable {
            case success
        }

        let id = UUID()
        let title: String
        let message: String
        let style: Style
    }

    enum Tab: Hashable {
        case hangar
        case fleet
        case buyback
        case account
    }

    enum RefreshScope: Hashable {
        case full
        case hangar
        case buyback
        case hangarLog
        case account

        var errorSubject: String {
            switch self {
            case .full:
                return AppLocalizer.string("the full account snapshot")
            case .hangar:
                return AppLocalizer.string("the hangar and fleet data")
            case .buyback:
                return AppLocalizer.string("the buy-back data")
            case .hangarLog:
                return AppLocalizer.string("the hangar log")
            case .account:
                return AppLocalizer.string("the account overview")
            }
        }
    }

    enum LoadState {
        case idle
        case loading
        case loaded(HangarSnapshot)
        case failed(String)
    }

    enum RefreshIndicatorStyle {
        case standardCard
        case compactTopLeading
    }

    @Observable
    final class RefreshPresentation {
        var progress: RefreshProgress?
        var concurrentEntries: [ConcurrentRefreshEntry] = []
        var indicatorStyle: RefreshIndicatorStyle = .standardCard

        var isVisible: Bool {
            progress != nil || !concurrentEntries.isEmpty
        }
    }

    var selectedTab: Tab = .hangar
    var session: UserSession?
    var savedSessions: [UserSession] = []
    var loadState: LoadState = .idle
    var lastRefreshAt: Date?
    var lastRefreshErrorMessage: String?
    var lastRefreshErrorScope: RefreshScope?
    var activeRefreshScope: RefreshScope?
    let refreshPresentation = RefreshPresentation()
    var hangarFleetImageReloadToken = UUID()
    var buybackImageReloadToken = UUID()
    var accountImageReloadToken = UUID()
    var authenticationFlowID = UUID()
    var reauthenticationPrompt: ReauthenticationPrompt?
    var versionRefreshPrompt: VersionRefreshPrompt?
    var itemTranslationPreprocessPrompt: ItemTranslationPreprocessPrompt?
    var itemTranslationPreloadProgress: ItemTranslationPreloadProgress?
    var itemTranslationPreloadLogEntries: [ItemTranslationPreloadLogEntry] = []
    private var hangarLogRefreshPreviewLogs: [HangarLogEntry] = []
    var previewsTranslationLoadingBar = false
    var startupActivity: StartupActivity?
    var transientBanner: TransientBanner?

    let authService: any AuthenticationServicing
    let recaptchaBroker: RecaptchaBroker
    let authIPRegionChecker: any AuthenticationIPRegionChecking
    let authDiagnostics: AuthenticationDiagnosticsStore
    let refreshDiagnostics: RefreshDiagnosticsStore
    let subscriptionStore: SubscriptionStore

    private let sessionStore: any SessionStore
    private let snapshotStore: any SnapshotStore
    private let imageCache: any RemoteImageCaching
    private let hangarRepository: any HangarRepository
    private let sensitiveActionAuthorizer: any SensitiveActionAuthorizing
    private let userDefaults: UserDefaults
    private var hasBootstrapped = false
    private var pendingAuthenticationDraft: AuthenticationDraft?
    private var silentHangarActionReconciliationTask: Task<Void, Never>?
    private var silentHangarActionReconciliationGeneration = 0
    private var itemTranslationPreloadTask: Task<Void, Never>?
    private var itemTranslationPreloadProgressDismissalTask: Task<Void, Never>?
    private var itemTranslationPreloadStallTask: Task<Void, Never>?
    private var itemTranslationPreloadGeneration = 0
    private var suspendedItemTranslationAutoPreloadLanguages: Set<HangarItemLanguage> = []
    private var dismissedItemTranslationPreprocessLanguages: Set<HangarItemLanguage> = []

    private enum ItemTranslationPreloadPresentation {
        case visible
        case silent
    }

    private static let lastLaunchedVersionDefaultsKey = "app.lastLaunchedVersion"
    private static let meltRequestTimeoutSeconds = 20
    private static let giftRequestTimeoutSeconds = 20
    private static let upgradeRequestTimeoutSeconds = 20
    private static let upgradeTargetLookupTimeoutSeconds = 20
    private static let characterRepairRequestTimeoutSeconds = 25
    private static let buybackCheckoutPreparationTimeoutSeconds = 30
    private static let limitedShipCartInsertionTimeoutSeconds = 30
    private static let authorizedDevicesRequestTimeoutSeconds = 20
    private static let actionCompletionBannerDurationNanoseconds: UInt64 = 2_000_000_000
    private static let postRefreshImageInvalidationDelayNanoseconds: UInt64 = 250_000_000
    private static let itemTranslationPreloadPreparingTimeoutNanoseconds: UInt64 = 35_000_000_000
    private static let itemTranslationPreloadTranslatingTimeoutNanoseconds: UInt64 = 60_000_000_000
    private static let itemTranslationDictionaryLoadTimeoutNanoseconds: UInt64 = 12_000_000_000
    private static let itemTranslationPreloadMaximumLogEntries = 80
    private static let itemTranslationPendingPreloadLanguageDefaultsKey = "hangar.itemTranslation.pendingPreloadLanguage"
    private static let versionUpdateNoteKeysByShortVersion: [String: [String]] = [
        "1.0.8": [
            "Request an RSI character repair from Hangar Express when your account is eligible.",
            "The CCU calculator feels smoother when choosing ships.",
            "Hangar and Fleet images appear sooner while you scroll.",
            "Hangar Log opens right away and starts showing entries in small groups as they load.",
            "Hangar Log refreshes should feel smoother and less likely to freeze the app."
        ],
        "1.0.7": [
            "Added Character Reset, allowing eligible users to request an RSI character repair from within Hangar Express.",
            "Improved Simplified Chinese localization across app flows.",
            "Resolved visual inconsistencies across multiple screens for a more consistent interface.",
            "Fixed Buyback CCU value calculation in CCU calculator."
        ]
    ]

    init(environment: AppEnvironment) {
        sessionStore = environment.sessionStore
        snapshotStore = environment.snapshotStore
        imageCache = environment.imageCache
        hangarRepository = environment.hangarRepository
        sensitiveActionAuthorizer = environment.sensitiveActionAuthorizer
        authService = environment.authService
        recaptchaBroker = environment.recaptchaBroker
        authIPRegionChecker = environment.authIPRegionChecker
        authDiagnostics = environment.authDiagnostics
        refreshDiagnostics = environment.refreshDiagnostics
        subscriptionStore = environment.subscriptionStore
        userDefaults = .standard
    }

    var snapshot: HangarSnapshot? {
        guard case let .loaded(snapshot) = loadState else {
            return nil
        }

        return snapshot
    }

    var hangarLogPresentationSnapshot: HangarSnapshot? {
        guard let snapshot else {
            return nil
        }

        guard isRefreshing(.hangarLog),
              !hangarLogRefreshPreviewLogs.isEmpty else {
            return snapshot
        }

        return snapshot.updatingHangarLogs(
            hangarLogs: hangarLogRefreshPreviewLogs,
            lastSyncedAt: snapshot.lastSyncedAt
        )
    }

    var isRefreshing: Bool {
        activeRefreshScope != nil
    }

    var refreshProgress: RefreshProgress? {
        get { refreshPresentation.progress }
        set { refreshPresentation.progress = newValue }
    }

    var concurrentRefreshEntries: [ConcurrentRefreshEntry] {
        get { refreshPresentation.concurrentEntries }
        set { refreshPresentation.concurrentEntries = newValue }
    }

    var refreshIndicatorStyle: RefreshIndicatorStyle {
        get { refreshPresentation.indicatorStyle }
        set { refreshPresentation.indicatorStyle = newValue }
    }

    var isPro: Bool {
        subscriptionStore.isPro
    }

    var refreshWorkerLimit: Int {
        SyncPreferences.maxWorkerCount(isPro: isPro)
    }

    var hangarLogEntryLimit: Int {
        ProSubscriptionConfiguration.hangarLogEntryLimit(isPro: isPro)
    }

    var allowsMultiAccountSwitching: Bool {
        isPro
    }

    var compositeUpgradeThumbnailsEnabled: Bool {
        userDefaults.object(forKey: DisplayPreferences.compositeUpgradeThumbnailModeKey) as? Bool
            ?? DisplayPreferences.compositeUpgradeThumbnailsEnabledByDefault
    }

    var showsUpgradedShipInHangar: Bool {
        userDefaults.object(forKey: DisplayPreferences.hangarUpgradedShipDisplayModeKey) as? Bool
            ?? DisplayPreferences.hangarUpgradedShipDisplayEnabledByDefault
    }

    func isRefreshing(_ scope: RefreshScope) -> Bool {
        guard let activeRefreshScope else {
            return false
        }

        if activeRefreshScope == .full {
            return true
        }

        return activeRefreshScope == scope
    }

    func requestItemTranslationPreprocessingForCurrentSnapshot() {
        guard let snapshot else {
            return
        }

        requestItemTranslationPreload(
            for: snapshot,
            promptsWhenCacheIsMissing: false,
            presentation: .visible
        )
    }

    func beginItemTranslationPreprocessing() {
        if let language = itemTranslationPreprocessPrompt?.language {
            dismissedItemTranslationPreprocessLanguages.insert(language)
        }
        itemTranslationPreprocessPrompt = nil

        guard let snapshot else {
            return
        }

        scheduleItemTranslationPreload(for: snapshot, presentation: .visible)
    }

    func downloadItemTranslationModel() async {
        let language = itemTranslationPreloadProgress?.language ?? currentHangarItemLanguage
        guard language.translationLocaleIdentifier != nil else {
            clearPendingItemTranslationPreload(for: language)
            return
        }

        markPendingItemTranslationPreload(for: language)
        itemTranslationPreprocessPrompt = nil
        itemTranslationPreloadTask?.cancel()
        itemTranslationPreloadTask = nil
        itemTranslationPreloadGeneration &+= 1
        let generation = itemTranslationPreloadGeneration
        itemTranslationPreloadStallTask?.cancel()
        itemTranslationPreloadStallTask = nil
        itemTranslationPreloadProgressDismissalTask?.cancel()
        itemTranslationPreloadProgressDismissalTask = nil
        let totalUnitCount = itemTranslationPreloadProgress?.totalUnitCount ?? 0
        resetItemTranslationPreloadLogs()
        itemTranslationPreloadProgress = ItemTranslationPreloadProgress(
            language: language,
            phase: .preparing,
            completedUnitCount: 0,
            totalUnitCount: totalUnitCount
        )
        appendItemTranslationPreloadLog("User requested Translation model download for language=\(language.rawValue).")

        let didPrepareModel = await OnDeviceHangarItemTranslationService.shared.prepareTranslationModel(
            for: language,
            logHandler: { [weak self] message in
                self?.appendItemTranslationPreloadLog(message)
            }
        )

        guard generation == itemTranslationPreloadGeneration else {
            return
        }

        guard didPrepareModel else {
            itemTranslationPreloadProgress = ItemTranslationPreloadProgress(
                language: language,
                phase: .downloadRequired,
                completedUnitCount: 0,
                totalUnitCount: totalUnitCount
            )
            return
        }

        guard let snapshot else {
            clearPendingItemTranslationPreload(for: language)
            itemTranslationPreloadProgress = nil
            return
        }

        scheduleItemTranslationPreload(for: snapshot, presentation: .visible)
    }

    func dismissItemTranslationPreprocessPrompt() {
        if let language = itemTranslationPreprocessPrompt?.language {
            dismissedItemTranslationPreprocessLanguages.insert(language)
        }
        itemTranslationPreprocessPrompt = nil
    }

    func cancelItemTranslationPreload() {
        if let language = itemTranslationPreloadProgress?.language {
            clearPendingItemTranslationPreload(for: language)
        }
        appendItemTranslationPreloadLog("User cancelled translation preload.")
        itemTranslationPreloadTask?.cancel()
        itemTranslationPreloadTask = nil
        itemTranslationPreloadGeneration &+= 1
        itemTranslationPreloadStallTask?.cancel()
        itemTranslationPreloadStallTask = nil
        itemTranslationPreloadProgressDismissalTask?.cancel()
        itemTranslationPreloadProgressDismissalTask = nil
        itemTranslationPreloadProgress = nil
        resetItemTranslationPreloadLogs()
    }

    var quickLoginSessions: [UserSession] {
        let liveSessions = savedSessions.filter { $0.authMode != .developerPreview }
        guard allowsMultiAccountSwitching else {
            return Array(liveSessions.prefix(1))
        }

        return liveSessions
    }

    func prepareSubscriptions() async {
        await subscriptionStore.start()
    }

    func bootstrap() async {
        guard !hasBootstrapped else {
            return
        }

        hasBootstrapped = true
        startupActivity = StartupActivity(
            title: AppLocalizer.string("Starting Hangar Express"),
            detail: AppLocalizer.string("Restoring your saved RSI session and local cache.")
        )
        authDiagnostics.record(
            stage: "app.bootstrap",
            summary: "Bootstrapping the app and restoring saved RSI sessions."
        )
        defer { startupActivity = nil }
        applyStoredSessions(await sessionStore.loadSnapshot(), resetContent: true)
        detectAppUpdateIfNeeded()
        await reconcileLaunchState()
    }

    func enablePreviewSession() async {
        let preview = UserSession.preview
        applyStoredSessions(await sessionStore.save(preview, makeActive: true), resetContent: true)
        await refresh(scope: .full)
    }

    func completeAuthentication(_ session: UserSession) async {
        reauthenticationPrompt = nil
        pendingAuthenticationDraft = nil
        authDiagnostics.record(
            stage: "auth.complete",
            summary: "Authentication completed. Starting a full refresh for the signed-in account.",
            detail: "displayName=\(session.displayName), cookieCount=\(session.cookies.count)"
        )
        applyStoredSessions(await sessionStore.save(session, makeActive: true), resetContent: true)
        await refresh(scope: .full)
    }

    func clearSession() async {
        await authService.cancelPendingAuthentication()
        authDiagnostics.record(
            stage: "auth.clear-session",
            summary: "Clearing the active RSI session and local snapshot state."
        )
        reauthenticationPrompt = nil
        pendingAuthenticationDraft = nil
        applyStoredSessions(await sessionStore.clear(), resetContent: true)
        await snapshotStore.clear()
        selectedTab = .hangar
    }

    func clearSavedKeychainContent() async {
        await authService.cancelPendingAuthentication()
        authDiagnostics.record(
            stage: "auth.clear-keychain",
            summary: "Removing all saved RSI accounts, cookies, and credentials from Keychain.",
            level: .warning
        )
        reauthenticationPrompt = nil
        pendingAuthenticationDraft = nil
        authenticationFlowID = UUID()
        applyStoredSessions(await sessionStore.clear(), resetContent: true)
        selectedTab = .hangar
    }

    func beginAddingAccount() async {
        let savedLiveSessionCount = savedSessions.filter { $0.authMode != .developerPreview }.count
        guard allowsMultiAccountSwitching || savedLiveSessionCount == 0 else {
            await subscriptionStore.purchasePro()
            return
        }

        await authService.cancelPendingAuthentication()
        authDiagnostics.record(
            stage: "auth.add-account",
            summary: "Opening a fresh sign-in flow for a new or replacement RSI account."
        )
        reauthenticationPrompt = nil
        pendingAuthenticationDraft = nil
        session = nil
        lastRefreshAt = nil
        loadState = .idle
        refreshProgress = nil
        concurrentRefreshEntries = []
        lastRefreshErrorMessage = nil
        lastRefreshErrorScope = nil
        activeRefreshScope = nil
    }

    func switchAccount(to id: UserSession.ID) async {
        guard session?.id != id else {
            return
        }

        guard allowsMultiAccountSwitching || savedSessions.first?.id == id else {
            await subscriptionStore.purchasePro()
            return
        }

        await authService.cancelPendingAuthentication()
        authDiagnostics.record(
            stage: "auth.switch-account",
            summary: "Switching to another saved RSI account."
        )
        reauthenticationPrompt = nil
        pendingAuthenticationDraft = nil
        applyStoredSessions(await sessionStore.selectSession(id: id), resetContent: true)

        if let session {
            let restoredSnapshot = await restoreCachedSnapshot(for: session)
            if !restoredSnapshot {
                await refresh(scope: .full)
            }
        }
    }

    func removeSavedAccount(id: UserSession.ID) async {
        let wasActiveSession = session?.id == id
        let removedSession = savedSessions.first(where: { $0.id == id })
        await authService.cancelPendingAuthentication()
        authDiagnostics.record(
            stage: "auth.remove-saved-account",
            summary: "Removing a saved RSI account from local storage.",
            detail: "wasActive=\(wasActiveSession)",
            level: .warning
        )
        if let removedSession {
            await snapshotStore.delete(for: removedSession)
        }
        if removedSession?.id == session?.id {
            reauthenticationPrompt = nil
        }
        applyStoredSessions(await sessionStore.deleteSession(id: id), resetContent: wasActiveSession)

        if wasActiveSession, let session {
            let restoredSnapshot = await restoreCachedSnapshot(for: session)
            if !restoredSnapshot {
                await refresh(scope: .full)
            }
        }
    }

    func openSavedAccount(id: UserSession.ID) async {
        guard let savedSession = savedSessions.first(where: { $0.id == id }) else {
            return
        }

        if !allowsMultiAccountSwitching,
           session?.id != id,
           savedSessions.first?.id != id {
            await subscriptionStore.purchasePro()
            return
        }

        if savedSession.cookies.isEmpty {
            authDiagnostics.record(
                stage: "auth.saved-account",
                summary: "The selected saved account does not have reusable RSI cookies and needs a fresh sign-in.",
                detail: "displayName=\(savedSession.displayName)",
                level: .warning
            )
            await transitionToAuthentication(
                using: savedSession,
                notice: AppLocalizer.string("This saved RSI account needs a fresh sign-in before live refresh can continue.")
            )
            return
        }

        authDiagnostics.record(
            stage: "auth.saved-account",
            summary: "Opening a saved RSI account with stored cookies.",
            detail: "displayName=\(savedSession.displayName), cookieCount=\(savedSession.cookies.count)"
        )
        await switchAccount(to: id)
    }

    func refresh(
        scope: RefreshScope = .full,
        affectedPledgeIDs: [Int]? = nil
    ) async {
        cancelSilentHangarActionReconciliation()

        guard let session else {
            loadState = .idle
            return
        }

        guard !isRefreshing else {
            return
        }

        let existingSnapshot = snapshot
        let resolvedScope = existingSnapshot == nil ? RefreshScope.full : scope
        if resolvedScope == .hangarLog {
            hangarLogRefreshPreviewLogs = existingSnapshot?.hangarLogs ?? []
        } else {
            hangarLogRefreshPreviewLogs = []
        }

        if resolvedScope == .full || resolvedScope == .hangar {
            await HostedShipCatalogStore.shared.clear()
            await HostedShipDetailCatalogStore.shared.clear()
        }

        if existingSnapshot == nil {
            loadState = .loading
        }
        lastRefreshErrorMessage = nil
        lastRefreshErrorScope = nil

        activeRefreshScope = resolvedScope
        refreshIndicatorStyle = .standardCard
        concurrentRefreshEntries = initialConcurrentRefreshEntries(for: session, scope: resolvedScope)
        refreshProgress = concurrentRefreshEntries.isEmpty ? initialProgress(for: session, scope: resolvedScope) : nil
        beginRefreshDiagnostics(for: resolvedScope, session: session)
        let progressRelay = RefreshProgressDisplayRelay { [weak self] progress in
            self?.applyIncomingRefreshProgress(progress)
        }
        defer {
            progressRelay.cancel()
        }

        do {
            let snapshot: HangarSnapshot
            if resolvedScope == .full, session.authMode != .developerPreview {
                refreshProgress = nil
                snapshot = try await refreshFullSnapshotConcurrently(
                    for: session,
                    existingSnapshot: existingSnapshot,
                    progressRelay: progressRelay
                )
            } else {
                let hangarLogBatchHandler = hangarLogBatchHandler(
                    for: resolvedScope,
                    fallbackSnapshot: existingSnapshot
                )
                snapshot = try await refreshedSnapshot(
                    for: session,
                    existingSnapshot: existingSnapshot,
                    scope: resolvedScope,
                    affectedPledgeIDs: affectedPledgeIDs,
                    hangarLogBatchHandler: hangarLogBatchHandler
                ) { progress in
                    progressRelay.submit(progress)
                }
            }

            completeVisibleRefresh(
                snapshot,
                diagnosticsStage: "refresh.complete",
                diagnosticsSummary: "\(refreshScopeDisplayName(resolvedScope)) refresh finished successfully."
            )
            requestItemTranslationPreload(for: snapshot, promptsWhenCacheIsMissing: true)
            persistSnapshotInBackground(snapshot, for: session)
            schedulePostRefreshImageInvalidation(
                for: resolvedScope,
                previousSnapshot: existingSnapshot,
                refreshedSnapshot: snapshot
            )
            return
        } catch {
            if await handleReauthenticationIfNeeded(
                for: error,
                session: session,
                existingSnapshot: existingSnapshot
            ) {
                clearRefreshPresentation()
                return
            }

            let message = AppLocalizer.format(
                "Unable to refresh %@. %@",
                resolvedScope.errorSubject,
                error.localizedDescription
            )
            let partialHangarLogSnapshot = resolvedScope == .hangarLog
                ? partialHangarLogRefreshSnapshot(fallbackSnapshot: existingSnapshot)
                : nil
            let fallbackSnapshot = resolvedScope == .hangarLog
                ? (partialHangarLogSnapshot ?? snapshot ?? existingSnapshot)
                : existingSnapshot
            if let fallbackSnapshot {
                loadState = .loaded(fallbackSnapshot)
                presentRefreshError(message, scope: resolvedScope, error: error)
            } else {
                presentRefreshError(message, scope: resolvedScope, error: error)
                loadState = .failed(message)
            }
        }

        clearRefreshPresentation()
    }

    private func completeVisibleRefresh(
        _ snapshot: HangarSnapshot,
        diagnosticsStage: String,
        diagnosticsSummary: String
    ) {
        lastRefreshAt = snapshot.lastSyncedAt
        loadState = .loaded(snapshot)
        lastRefreshErrorMessage = nil
        lastRefreshErrorScope = nil
        clearRefreshPresentation()
        refreshDiagnostics.record(
            stage: diagnosticsStage,
            summary: diagnosticsSummary
        )
    }

    private func partialHangarLogRefreshSnapshot(fallbackSnapshot: HangarSnapshot?) -> HangarSnapshot? {
        guard !hangarLogRefreshPreviewLogs.isEmpty,
              let baseSnapshot = snapshot ?? fallbackSnapshot else {
            return nil
        }

        return baseSnapshot.updatingHangarLogs(
            hangarLogs: hangarLogRefreshPreviewLogs,
            lastSyncedAt: baseSnapshot.lastSyncedAt
        )
    }

    private func hangarLogBatchHandler(
        for scope: RefreshScope,
        fallbackSnapshot: HangarSnapshot?
    ) -> HangarLogBatchHandler? {
        guard scope == .hangarLog else {
            return nil
        }

        return { [weak self] hangarLogs in
            guard let self,
                  !hangarLogs.isEmpty else {
                return
            }

            self.hangarLogRefreshPreviewLogs = hangarLogs
        }
    }

    private func clearRefreshPresentation() {
        refreshProgress = nil
        concurrentRefreshEntries = []
        activeRefreshScope = nil
        hangarLogRefreshPreviewLogs = []
    }

    private func persistSnapshotInBackground(_ snapshot: HangarSnapshot, for session: UserSession) {
        let snapshotStore = snapshotStore
        Task.detached(priority: .utility) {
            await snapshotStore.save(snapshot, for: session)
        }
    }

    private func resetItemTranslationPreloadLogs() {
        itemTranslationPreloadLogEntries.removeAll(keepingCapacity: true)
    }

    private func appendItemTranslationPreloadLog(_ message: String) {
        itemTranslationPreloadLogEntries.append(
            ItemTranslationPreloadLogEntry(
                occurredAt: .now,
                message: message
            )
        )

        if itemTranslationPreloadLogEntries.count > Self.itemTranslationPreloadMaximumLogEntries {
            itemTranslationPreloadLogEntries.removeFirst(
                itemTranslationPreloadLogEntries.count - Self.itemTranslationPreloadMaximumLogEntries
            )
        }

#if DEBUG
        print("ItemTranslationPreload: \(message)")
#endif
    }

    private var currentHangarItemLanguage: HangarItemLanguage {
        HangarItemLanguage.resolved(
            from: userDefaults.string(forKey: HangarItemLanguage.storageKey)
                ?? HangarItemLanguage.original.rawValue
        )
    }

    private func pendingItemTranslationPreloadLanguage() -> HangarItemLanguage? {
        guard let rawValue = userDefaults.string(forKey: Self.itemTranslationPendingPreloadLanguageDefaultsKey) else {
            return nil
        }

        let language = HangarItemLanguage.resolved(from: rawValue)
        return language.translationLocaleIdentifier == nil ? nil : language
    }

    private func markPendingItemTranslationPreload(for language: HangarItemLanguage) {
        guard language.translationLocaleIdentifier != nil else {
            clearPendingItemTranslationPreload(for: language)
            return
        }

        userDefaults.set(language.rawValue, forKey: Self.itemTranslationPendingPreloadLanguageDefaultsKey)
    }

    private func clearPendingItemTranslationPreload(for language: HangarItemLanguage? = nil) {
        guard let language else {
            userDefaults.removeObject(forKey: Self.itemTranslationPendingPreloadLanguageDefaultsKey)
            return
        }

        guard pendingItemTranslationPreloadLanguage() == language else {
            return
        }

        userDefaults.removeObject(forKey: Self.itemTranslationPendingPreloadLanguageDefaultsKey)
    }

    private func requestItemTranslationPreload(
        for snapshot: HangarSnapshot,
        promptsWhenCacheIsMissing: Bool,
        presentation: ItemTranslationPreloadPresentation = .silent
    ) {
        let language = currentHangarItemLanguage
        guard language.translationLocaleIdentifier != nil else {
            itemTranslationPreloadTask?.cancel()
            itemTranslationPreloadTask = nil
            itemTranslationPreloadGeneration &+= 1
            itemTranslationPreloadStallTask?.cancel()
            itemTranslationPreloadStallTask = nil
            itemTranslationPreloadProgressDismissalTask?.cancel()
            itemTranslationPreloadProgressDismissalTask = nil
            itemTranslationPreloadProgress = nil
            resetItemTranslationPreloadLogs()
            itemTranslationPreprocessPrompt = nil
            clearPendingItemTranslationPreload()
            return
        }

        guard !suspendedItemTranslationAutoPreloadLanguages.contains(language) else {
            appendItemTranslationPreloadLog("Automatic translation preload skipped while waiting for cache-clear rebuild confirmation.")
            return
        }

        let resumesPendingPreload = pendingItemTranslationPreloadLanguage() == language
        if promptsWhenCacheIsMissing,
           !resumesPendingPreload,
           !OnDeviceHangarItemTranslationService.shared.hasAvailableCache(for: language) {
            guard !dismissedItemTranslationPreprocessLanguages.contains(language) else {
                appendItemTranslationPreloadLog(
                    "Automatic translation preload skipped because missing-cache prompt was dismissed for language=\(language.rawValue)."
                )
                return
            }

            itemTranslationPreloadTask?.cancel()
            itemTranslationPreloadTask = nil
            itemTranslationPreloadGeneration &+= 1
            itemTranslationPreloadStallTask?.cancel()
            itemTranslationPreloadStallTask = nil
            resetItemTranslationPreloadLogs()
            appendItemTranslationPreloadLog("Saved preprocessed cache not found for language=\(language.rawValue); showing prompt.")
            itemTranslationPreprocessPrompt = ItemTranslationPreprocessPrompt(
                language: language,
                reason: .missingCache
            )
            return
        }

        scheduleItemTranslationPreload(
            for: snapshot,
            presentation: resumesPendingPreload ? .visible : presentation
        )
    }

    private func scheduleItemTranslationPreload(
        for snapshot: HangarSnapshot,
        presentation: ItemTranslationPreloadPresentation
    ) {
        let language = currentHangarItemLanguage
        guard language.translationLocaleIdentifier != nil else {
            itemTranslationPreloadTask?.cancel()
            itemTranslationPreloadTask = nil
            itemTranslationPreloadGeneration &+= 1
            itemTranslationPreloadStallTask?.cancel()
            itemTranslationPreloadStallTask = nil
            itemTranslationPreloadProgressDismissalTask?.cancel()
            itemTranslationPreloadProgressDismissalTask = nil
            itemTranslationPreloadProgress = nil
            resetItemTranslationPreloadLogs()
            clearPendingItemTranslationPreload()
            return
        }

        let sources = itemTranslationPreloadSources(for: snapshot)
        guard !sources.isEmpty else {
            resetItemTranslationPreloadLogs()
            appendItemTranslationPreloadLog("No preload source strings were found in the current snapshot.")
            clearPendingItemTranslationPreload(for: language)
            return
        }

        itemTranslationPreloadTask?.cancel()
        itemTranslationPreloadGeneration &+= 1
        let preloadGeneration = itemTranslationPreloadGeneration
        let showsProgress = presentation == .visible
        resetItemTranslationPreloadLogs()
        itemTranslationPreloadStallTask?.cancel()
        itemTranslationPreloadStallTask = nil
        itemTranslationPreloadProgressDismissalTask?.cancel()
        itemTranslationPreloadProgressDismissalTask = nil
        itemTranslationPreloadProgress = nil
        appendItemTranslationPreloadLog(
            "Scheduled \(showsProgress ? "visible" : "silent") preload. generation=\(preloadGeneration), language=\(language.rawValue), sourceCandidates=\(sources.count)."
        )
        appendItemTranslationPreloadLog("Fetching StarCitizen-Info item translation dictionary.")
        itemTranslationPreloadTask = Task.detached(priority: .utility) { [weak self] in
            guard let self else {
                return
            }

            let dictionaryResult = await Self.loadItemTranslationDictionary(
                for: language,
                timeoutNanoseconds: Self.itemTranslationDictionaryLoadTimeoutNanoseconds
            )

            switch dictionaryResult {
            case let .loaded(dictionary):
                await self.appendItemTranslationPreloadLog(
                    "Dictionary loaded. locale=\(dictionary.locale), version=\(dictionary.version), entries=\(dictionary.entries.count)."
                )
            case .unavailable:
                await self.appendItemTranslationPreloadLog("Dictionary unavailable from network and disk cache.")
            case .timedOut:
                await self.appendItemTranslationPreloadLog("Dictionary lookup timed out before returning cached or remote data.")
            }
            let itemTranslator = HangarItemTranslator(
                language: language,
                dictionary: dictionaryResult.dictionary
            )
            if showsProgress {
                await OnDeviceHangarItemTranslationService.shared.preloadTranslations(
                    for: sources,
                    using: itemTranslator,
                    progressHandler: { progress in
                        self.applyItemTranslationPreloadProgress(
                            progress,
                            language: language,
                            generation: preloadGeneration
                        )
                    },
                    logHandler: { message in
                        self.appendItemTranslationPreloadLog(message)
                    }
                )
            } else {
                await OnDeviceHangarItemTranslationService.shared.preloadTranslations(
                    for: sources,
                    using: itemTranslator,
                    progressHandler: { progress in
                        self.applySilentItemTranslationPreloadProgress(
                            progress,
                            language: language,
                            generation: preloadGeneration
                        )
                    },
                    logHandler: { message in
                        self.appendItemTranslationPreloadLog(message)
                    }
                )
            }
        }
    }

    private nonisolated static func loadItemTranslationDictionary(
        for language: HangarItemLanguage,
        timeoutNanoseconds: UInt64
    ) async -> ItemTranslationDictionaryLoadResult {
        await withTaskGroup(of: ItemTranslationDictionaryLoadResult.self) { group in
            group.addTask {
                let dictionary = await HostedHangarItemTranslationStore.shared.dictionary(
                    for: language,
                    using: HostedHangarItemTranslationClient(language: language),
                    preferCachedData: true
                )

                if let dictionary {
                    return .loaded(dictionary)
                }

                return .unavailable
            }

            group.addTask {
                try? await Task.sleep(nanoseconds: timeoutNanoseconds)
                return .timedOut
            }

            let result = await group.next() ?? .unavailable
            group.cancelAll()
            return result
        }
    }

    private func applySilentItemTranslationPreloadProgress(
        _ progress: OnDeviceHangarItemTranslationPreloadProgress,
        language: HangarItemLanguage,
        generation: Int
    ) {
        guard generation == itemTranslationPreloadGeneration else {
            return
        }

        let phase = ItemTranslationPreloadProgress.Phase(progress.phase)
        appendItemTranslationPreloadLog(
            "Silent progress updated. phase=\(phase), completed=\(progress.completedUnitCount), total=\(progress.totalUnitCount)."
        )

        if phase == .finished {
            clearPendingItemTranslationPreload(for: language)
        } else if progress.totalUnitCount > 0 {
            markPendingItemTranslationPreload(for: language)
        }
    }

    private func applyItemTranslationPreloadProgress(
        _ progress: OnDeviceHangarItemTranslationPreloadProgress,
        language: HangarItemLanguage,
        generation: Int
    ) {
        guard generation == itemTranslationPreloadGeneration else {
            return
        }

        let displayProgress = ItemTranslationPreloadProgress(
            language: language,
            phase: ItemTranslationPreloadProgress.Phase(progress.phase),
            completedUnitCount: progress.completedUnitCount,
            totalUnitCount: progress.totalUnitCount
        )

        appendItemTranslationPreloadLog(
            "Progress updated. phase=\(displayProgress.phase), completed=\(displayProgress.completedUnitCount), total=\(displayProgress.totalUnitCount)."
        )

        if displayProgress.phase == .finished,
           displayProgress.totalUnitCount == 0 {
            clearPendingItemTranslationPreload(for: language)
            itemTranslationPreloadProgress = nil
            itemTranslationPreloadStallTask?.cancel()
            itemTranslationPreloadStallTask = nil
            itemTranslationPreloadProgressDismissalTask?.cancel()
            itemTranslationPreloadProgressDismissalTask = nil
            return
        }

        if displayProgress.totalUnitCount > 0 {
            markPendingItemTranslationPreload(for: language)
        }

        itemTranslationPreloadProgress = displayProgress
        itemTranslationPreloadStallTask?.cancel()
        itemTranslationPreloadStallTask = nil
        itemTranslationPreloadProgressDismissalTask?.cancel()
        itemTranslationPreloadProgressDismissalTask = nil

        if displayProgress.isTerminal {
            if displayProgress.phase == .finished {
                clearPendingItemTranslationPreload(for: language)
                scheduleItemTranslationPreloadProgressDismissal()
            }
            return
        }

        scheduleItemTranslationPreloadStallTimeout(
            for: displayProgress,
            generation: generation
        )
    }

    private func scheduleItemTranslationPreloadStallTimeout(
        for observedProgress: ItemTranslationPreloadProgress,
        generation: Int
    ) {
        let timeoutNanoseconds: UInt64
        switch observedProgress.phase {
        case .preparing:
            timeoutNanoseconds = Self.itemTranslationPreloadPreparingTimeoutNanoseconds
        case .translating:
            timeoutNanoseconds = Self.itemTranslationPreloadTranslatingTimeoutNanoseconds
        case .finished, .downloadRequired, .unavailable, .failed, .timedOut:
            return
        }

        itemTranslationPreloadStallTask?.cancel()
        appendItemTranslationPreloadLog(
            "Armed stall watchdog. phase=\(observedProgress.phase), timeoutSeconds=\(timeoutNanoseconds / 1_000_000_000)."
        )
        itemTranslationPreloadStallTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: timeoutNanoseconds)
            guard !Task.isCancelled else {
                return
            }

            await MainActor.run {
                guard let self,
                      generation == self.itemTranslationPreloadGeneration,
                      self.itemTranslationPreloadProgress == observedProgress else {
                    return
                }

                self.itemTranslationPreloadTask?.cancel()
                self.itemTranslationPreloadTask = nil
                self.itemTranslationPreloadGeneration &+= 1
                self.itemTranslationPreloadStallTask = nil
                self.appendItemTranslationPreloadLog(
                    "Stall watchdog fired. phase=\(observedProgress.phase), completed=\(observedProgress.completedUnitCount), total=\(observedProgress.totalUnitCount)."
                )
                self.itemTranslationPreloadProgress = ItemTranslationPreloadProgress(
                    language: observedProgress.language,
                    phase: .timedOut,
                    completedUnitCount: observedProgress.completedUnitCount,
                    totalUnitCount: observedProgress.totalUnitCount
                )
            }
        }
    }

    private func scheduleItemTranslationPreloadProgressDismissal() {
        itemTranslationPreloadProgressDismissalTask?.cancel()
        itemTranslationPreloadProgressDismissalTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            guard !Task.isCancelled else {
                return
            }

            await MainActor.run {
                self?.itemTranslationPreloadProgress = nil
                self?.itemTranslationPreloadProgressDismissalTask = nil
            }
        }
    }

    private func itemTranslationPreloadSources(for snapshot: HangarSnapshot) -> [String] {
        var sources: [String] = []
        var seenSources = Set<String>()

        func add(_ source: String?) {
            let trimmedSource = source?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !trimmedSource.isEmpty,
                  seenSources.insert(trimmedSource).inserted else {
                return
            }

            sources.append(trimmedSource)
        }

        for package in snapshot.packages {
            add(package.title)
            add(package.debugDisplayTitle(showsUpgradedShipInHangar: showsUpgradedShipInHangar))
            for item in package.contents {
                add(item.title)
                add("\(item.category.rawValue) • \(item.detail)")

                if let pricing = item.upgradePricing {
                    add(pricing.sourceShipName)
                    add(pricing.targetShipName)
                }
            }
        }

        for ship in snapshot.fleet {
            add(ship.displayName)
            add(ship.manufacturer)
            add(FleetPresentationFormatter.manufacturerDisplayName(ship.manufacturer))
            add(ship.role)
            add(
                FleetPresentationFormatter.roleSummary(
                    role: ship.role,
                    categories: ship.roleCategories
                )
            )
            for roleCategory in ship.roleCategories {
                add(roleCategory)
            }
            add(ship.sourcePackageName)
        }

        for buybackPledge in snapshot.buyback {
            add(buybackPledge.title)
            add(buybackPledge.displayedNotes)
            add(buybackPledge.sourceRawInfo?.titleText)
        }

        for logEntry in snapshot.hangarLogs {
            add(logEntry.itemName)
            add(logEntry.reason)
            add(logEntry.upgradeContext?.sourceShipName)
            add(logEntry.upgradeContext?.targetShipName)
            add(logEntry.upgradeContext?.upgradeName)
        }

        return sources
    }

    private func schedulePostRefreshImageInvalidation(
        for scope: RefreshScope,
        previousSnapshot: HangarSnapshot?,
        refreshedSnapshot: HangarSnapshot
    ) {
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.postRefreshImageInvalidationDelayNanoseconds)
            await self?.invalidateImageCache(
                for: scope,
                previousSnapshot: previousSnapshot,
                refreshedSnapshot: refreshedSnapshot
            )
        }
    }

    func dismissRefreshError() {
        lastRefreshErrorMessage = nil
        lastRefreshErrorScope = nil
    }

    func dismissReauthenticationPrompt() {
        reauthenticationPrompt = nil
    }

    func dismissVersionRefreshPrompt() {
        versionRefreshPrompt = nil
    }

    func handleAppDidBecomeActive() async {
        await subscriptionStore.refreshPurchasedProducts()

        guard hasBootstrapped else {
            await bootstrap()
            return
        }

        startupActivity = StartupActivity(
            title: AppLocalizer.string("Waking Up"),
            detail: AppLocalizer.string("Checking your saved RSI session and cached hangar data.")
        )
        defer { startupActivity = nil }
        await reconcileLaunchState()
    }

    func beginReauthentication() async {
        guard let session else {
            reauthenticationPrompt = nil
            return
        }

        let notice = reauthenticationPrompt?.message ?? AppLocalizer.string("Your saved RSI session is no longer valid. Sign in again to continue refreshing live data.")
        await transitionToAuthentication(using: session, notice: notice)
    }

    func consumePendingAuthenticationDraft() -> AuthenticationDraft? {
        defer { pendingAuthenticationDraft = nil }
        return pendingAuthenticationDraft
    }

    func clearLocalCache() async {
        let suspendedTranslationLanguage = HangarItemLanguage.resolved(
            from: userDefaults.string(forKey: HangarItemLanguage.storageKey)
                ?? HangarItemLanguage.original.rawValue
        )
        let shouldSuspendTranslationPreload = suspendedTranslationLanguage.translationLocaleIdentifier != nil
        if shouldSuspendTranslationPreload {
            suspendedItemTranslationAutoPreloadLanguages.insert(suspendedTranslationLanguage)
        }
        defer {
            if shouldSuspendTranslationPreload {
                suspendedItemTranslationAutoPreloadLanguages.remove(suspendedTranslationLanguage)
            }
        }

        await snapshotStore.clear()
        URLCache.shared.removeAllCachedResponses()
        await imageCache.clear()
        await HostedShipCatalogStore.shared.clear()
        await HostedShipDetailCatalogStore.shared.clear()
        hangarFleetImageReloadToken = UUID()
        buybackImageReloadToken = UUID()
        accountImageReloadToken = UUID()
        lastRefreshErrorMessage = nil
        lastRefreshErrorScope = nil

        guard session != nil else {
            loadState = .idle
            refreshProgress = nil
            concurrentRefreshEntries = []
            activeRefreshScope = nil
            lastRefreshAt = nil
            return
        }

        await refresh(scope: .full)
    }

    func clearTranslationCache() async {
        let rebuildPromptLanguage = HangarItemLanguage.resolved(
            from: userDefaults.string(forKey: HangarItemLanguage.storageKey)
                ?? HangarItemLanguage.original.rawValue
        )

        await HostedHangarItemTranslationStore.shared.clear()
        itemTranslationPreloadTask?.cancel()
        itemTranslationPreloadTask = nil
        itemTranslationPreloadGeneration &+= 1
        itemTranslationPreloadStallTask?.cancel()
        itemTranslationPreloadStallTask = nil
        itemTranslationPreloadProgressDismissalTask?.cancel()
        itemTranslationPreloadProgressDismissalTask = nil
        itemTranslationPreloadProgress = nil
        resetItemTranslationPreloadLogs()
        dismissedItemTranslationPreprocessLanguages.removeAll()
        itemTranslationPreprocessPrompt = nil
        clearPendingItemTranslationPreload()
        OnDeviceHangarItemTranslationService.shared.clear()

        if rebuildPromptLanguage.translationLocaleIdentifier != nil,
           snapshot != nil {
            itemTranslationPreprocessPrompt = ItemTranslationPreprocessPrompt(
                language: rebuildPromptLanguage,
                reason: .cacheCleared
            )
        }
    }

    func melt(packageGroup: GroupedHangarPackage, quantity: Int) async throws {
        guard !isRefreshing else {
            throw HangarAccountActionError.actionInProgress
        }

        guard quantity > 0, quantity <= packageGroup.quantity else {
            throw HangarAccountActionError.invalidMeltQuantity(maximum: packageGroup.quantity)
        }

        guard let session else {
            throw HangarAccountActionError.missingSession
        }

        let preMeltSnapshot = snapshot

        guard let credentials = session.credentials,
              !credentials.password.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw HangarAccountActionError.missingStoredPassword
        }

        try await sensitiveActionAuthorizer.authorize(
            reason: meltAuthorizationReason(for: packageGroup, quantity: quantity)
        )

        let pledgeIDs = Array(packageGroup.packages.prefix(quantity).map(\.id))
        let timeoutSeconds = Self.meltRequestTimeoutSeconds
        let result = try await withTimeout(seconds: timeoutSeconds) { [self] in
            try await self.hangarRepository.meltPackages(
                for: session,
                pledgeIDs: pledgeIDs,
                password: credentials.password
            )
        } onTimeout: {
            HangarAccountActionError.meltTimedOut(timeoutSeconds: timeoutSeconds)
        }

        if !result.updatedCookies.isEmpty {
            let updatedSession = session.updatingCookies(result.updatedCookies)
            applyStoredSessions(await sessionStore.save(updatedSession, makeActive: true), resetContent: false)
        }

        if result.wasSuccessful {
            let affectedPledgeIDs = result.completedPledgeIDs.isEmpty
                ? result.requestedPledgeIDs
                : result.completedPledgeIDs
            applyOptimisticRemovalUpdate(
                affectedPledgeIDs: affectedPledgeIDs,
                session: self.session ?? session
            )
            let reconciliationSession = self.session ?? session
            scheduleSilentHangarActionReconciliation(
                using: reconciliationSession,
                previousSnapshotForHangarRefresh: preMeltSnapshot,
                affectedPledgeIDs: affectedPledgeIDs,
                logInitialDetail: AppLocalizer.string("Waiting for RSI to post the new melt entry to your hangar log."),
                logRetryDetail: AppLocalizer.string("RSI has not posted the new melt log entry yet. Checking again."),
                refreshFailurePrefix: AppLocalizer.string("The melt completed, but the background hangar refresh could not finish.")
            )
            showCompletedActionBanner(
                title: AppLocalizer.string("Melt Complete"),
                message: quantity == 1
                    ? AppLocalizer.string("The selected pledge was successfully reclaimed.")
                    : AppLocalizer.format("%lld pledges were successfully reclaimed.", quantity)
            )
            return
        }

        await refresh(scope: .hangar)

        guard result.wasSuccessful else {
            throw HangarAccountActionError.partialMelt(
                completedCount: result.completedCount,
                requestedCount: result.requestedPledgeIDs.count,
                message: result.failureMessage ?? AppLocalizer.string("RSI stopped the melt request before all selected copies were reclaimed.")
            )
        }
    }

    func melt(packageGroups: [GroupedHangarPackage]) async throws {
        guard !isRefreshing else {
            throw HangarAccountActionError.actionInProgress
        }

        let packages = packageGroups.flatMap(\.packages)
        guard !packages.isEmpty else {
            throw HangarAccountActionError.emptyPledgeSelection
        }

        guard packages.allSatisfy(\.canReclaim) else {
            throw HangarAccountActionError.ineligibleMeltSelection
        }

        guard let session else {
            throw HangarAccountActionError.missingSession
        }

        let preMeltSnapshot = snapshot

        guard let credentials = session.credentials,
              !credentials.password.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw HangarAccountActionError.missingStoredPassword
        }

        try await sensitiveActionAuthorizer.authorize(
            reason: bulkMeltAuthorizationReason(for: packages)
        )

        let pledgeIDs = packages.map(\.id)
        let timeoutSeconds = Self.meltRequestTimeoutSeconds
        let result = try await withTimeout(seconds: timeoutSeconds) { [self] in
            try await self.hangarRepository.meltPackages(
                for: session,
                pledgeIDs: pledgeIDs,
                password: credentials.password
            )
        } onTimeout: {
            HangarAccountActionError.meltTimedOut(timeoutSeconds: timeoutSeconds)
        }

        if !result.updatedCookies.isEmpty {
            let updatedSession = session.updatingCookies(result.updatedCookies)
            applyStoredSessions(await sessionStore.save(updatedSession, makeActive: true), resetContent: false)
        }

        if result.wasSuccessful {
            let affectedPledgeIDs = result.completedPledgeIDs.isEmpty
                ? result.requestedPledgeIDs
                : result.completedPledgeIDs
            applyOptimisticRemovalUpdate(
                affectedPledgeIDs: affectedPledgeIDs,
                session: self.session ?? session
            )
            let reconciliationSession = self.session ?? session
            scheduleSilentHangarActionReconciliation(
                using: reconciliationSession,
                previousSnapshotForHangarRefresh: preMeltSnapshot,
                affectedPledgeIDs: affectedPledgeIDs,
                logInitialDetail: AppLocalizer.string("Waiting for RSI to post the new melt entries to your hangar log."),
                logRetryDetail: AppLocalizer.string("RSI has not posted the new melt log entries yet. Checking again."),
                refreshFailurePrefix: AppLocalizer.string("The bulk melt completed, but the background hangar refresh could not finish.")
            )
            showCompletedActionBanner(
                title: AppLocalizer.string("Melt Complete"),
                message: AppLocalizer.format("%lld pledges were successfully reclaimed.", packages.count)
            )
            return
        }

        await refresh(scope: .hangar)

        guard result.wasSuccessful else {
            throw HangarAccountActionError.partialMelt(
                completedCount: result.completedCount,
                requestedCount: result.requestedPledgeIDs.count,
                message: result.failureMessage ?? AppLocalizer.string("RSI stopped the bulk melt request before all selected pledges were reclaimed.")
            )
        }
    }

    func gift(
        packageGroup: GroupedHangarPackage,
        quantity: Int,
        recipientName: String,
        recipientEmail: String
    ) async throws {
        guard !isRefreshing else {
            throw HangarAccountActionError.actionInProgress
        }

        guard quantity > 0, quantity <= packageGroup.quantity else {
            throw HangarAccountActionError.invalidGiftQuantity(maximum: packageGroup.quantity)
        }

        guard let session else {
            throw HangarAccountActionError.missingSession
        }

        let trimmedRecipientEmail = recipientEmail.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedRecipientEmail.isEmpty else {
            throw HangarAccountActionError.missingGiftRecipientEmail
        }

        guard Self.isValidGiftRecipientEmail(trimmedRecipientEmail) else {
            throw HangarAccountActionError.invalidGiftRecipientEmail
        }

        let resolvedRecipientName = resolvedGiftRecipientName(from: recipientName, session: session)
        let preGiftSnapshot = snapshot

        guard let credentials = session.credentials,
              !credentials.password.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw HangarAccountActionError.missingStoredPassword
        }

        try await sensitiveActionAuthorizer.authorize(
            reason: giftAuthorizationReason(
                for: packageGroup,
                quantity: quantity,
                recipientEmail: trimmedRecipientEmail
            )
        )

        let pledgeIDs = Array(packageGroup.packages.prefix(quantity).map(\.id))
        let timeoutSeconds = Self.giftRequestTimeoutSeconds
        let result = try await withTimeout(seconds: timeoutSeconds) { [self] in
            try await self.hangarRepository.giftPackages(
                for: session,
                pledgeIDs: pledgeIDs,
                password: credentials.password,
                recipientEmail: trimmedRecipientEmail,
                recipientName: resolvedRecipientName
            )
        } onTimeout: {
            HangarAccountActionError.giftTimedOut(timeoutSeconds: timeoutSeconds)
        }

        if !result.updatedCookies.isEmpty {
            let updatedSession = session.updatingCookies(result.updatedCookies)
            applyStoredSessions(await sessionStore.save(updatedSession, makeActive: true), resetContent: false)
        }

        if result.wasSuccessful {
            let affectedPledgeIDs = result.completedPledgeIDs.isEmpty
                ? result.requestedPledgeIDs
                : result.completedPledgeIDs
            applyOptimisticRemovalUpdate(
                affectedPledgeIDs: affectedPledgeIDs,
                session: self.session ?? session
            )
            let reconciliationSession = self.session ?? session
            scheduleSilentHangarActionReconciliation(
                using: reconciliationSession,
                previousSnapshotForHangarRefresh: preGiftSnapshot,
                affectedPledgeIDs: affectedPledgeIDs,
                logInitialDetail: AppLocalizer.string("Waiting for RSI to post the new gift entry to your hangar log."),
                logRetryDetail: AppLocalizer.string("RSI has not posted the new gift log entry yet. Checking again."),
                refreshFailurePrefix: AppLocalizer.string("The gift completed, but the background hangar refresh could not finish.")
            )
            showCompletedActionBanner(
                title: AppLocalizer.string("Gift Complete"),
                message: quantity == 1
                    ? AppLocalizer.string("The selected pledge was successfully gifted.")
                    : AppLocalizer.format("%lld pledges were successfully gifted.", quantity)
            )
            return
        }

        await refresh(scope: .hangar)

        guard result.wasSuccessful else {
            throw HangarAccountActionError.partialGift(
                completedCount: result.completedCount,
                requestedCount: result.requestedPledgeIDs.count,
                message: result.failureMessage ?? AppLocalizer.string("RSI stopped the gift request before all selected copies were sent.")
            )
        }
    }

    func gift(
        packageGroups: [GroupedHangarPackage],
        recipientName: String,
        recipientEmail: String
    ) async throws {
        guard !isRefreshing else {
            throw HangarAccountActionError.actionInProgress
        }

        let packages = packageGroups.flatMap(\.packages)
        guard !packages.isEmpty else {
            throw HangarAccountActionError.emptyPledgeSelection
        }

        guard packages.allSatisfy(\.canGift) else {
            throw HangarAccountActionError.ineligibleGiftSelection
        }

        guard let session else {
            throw HangarAccountActionError.missingSession
        }

        let trimmedRecipientEmail = recipientEmail.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedRecipientEmail.isEmpty else {
            throw HangarAccountActionError.missingGiftRecipientEmail
        }

        guard Self.isValidGiftRecipientEmail(trimmedRecipientEmail) else {
            throw HangarAccountActionError.invalidGiftRecipientEmail
        }

        let resolvedRecipientName = resolvedGiftRecipientName(from: recipientName, session: session)
        let preGiftSnapshot = snapshot

        guard let credentials = session.credentials,
              !credentials.password.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw HangarAccountActionError.missingStoredPassword
        }

        try await sensitiveActionAuthorizer.authorize(
            reason: bulkGiftAuthorizationReason(
                for: packages,
                recipientEmail: trimmedRecipientEmail
            )
        )

        let pledgeIDs = packages.map(\.id)
        let timeoutSeconds = Self.giftRequestTimeoutSeconds
        let result = try await withTimeout(seconds: timeoutSeconds) { [self] in
            try await self.hangarRepository.giftPackages(
                for: session,
                pledgeIDs: pledgeIDs,
                password: credentials.password,
                recipientEmail: trimmedRecipientEmail,
                recipientName: resolvedRecipientName
            )
        } onTimeout: {
            HangarAccountActionError.giftTimedOut(timeoutSeconds: timeoutSeconds)
        }

        if !result.updatedCookies.isEmpty {
            let updatedSession = session.updatingCookies(result.updatedCookies)
            applyStoredSessions(await sessionStore.save(updatedSession, makeActive: true), resetContent: false)
        }

        if result.wasSuccessful {
            let affectedPledgeIDs = result.completedPledgeIDs.isEmpty
                ? result.requestedPledgeIDs
                : result.completedPledgeIDs
            applyOptimisticRemovalUpdate(
                affectedPledgeIDs: affectedPledgeIDs,
                session: self.session ?? session
            )
            let reconciliationSession = self.session ?? session
            scheduleSilentHangarActionReconciliation(
                using: reconciliationSession,
                previousSnapshotForHangarRefresh: preGiftSnapshot,
                affectedPledgeIDs: affectedPledgeIDs,
                logInitialDetail: AppLocalizer.string("Waiting for RSI to post the new gift entries to your hangar log."),
                logRetryDetail: AppLocalizer.string("RSI has not posted the new gift log entries yet. Checking again."),
                refreshFailurePrefix: AppLocalizer.string("The bulk gift completed, but the background hangar refresh could not finish.")
            )
            showCompletedActionBanner(
                title: AppLocalizer.string("Gift Complete"),
                message: AppLocalizer.format("%lld pledges were successfully gifted.", packages.count)
            )
            return
        }

        await refresh(scope: .hangar)

        guard result.wasSuccessful else {
            throw HangarAccountActionError.partialGift(
                completedCount: result.completedCount,
                requestedCount: result.requestedPledgeIDs.count,
                message: result.failureMessage ?? AppLocalizer.string("RSI stopped the bulk gift request before all selected pledges were sent.")
            )
        }
    }

    func fetchUpgradeTargets(for packageGroup: GroupedHangarPackage) async throws -> [UpgradeTargetCandidate] {
        guard let session else {
            throw HangarAccountActionError.missingSession
        }

        let upgradeItemPledgeID = try selectedUpgradeItemPledgeID(for: packageGroup)
        let timeoutSeconds = Self.upgradeTargetLookupTimeoutSeconds

        do {
            let targets = try await withTimeout(seconds: timeoutSeconds) { [self] in
                try await self.hangarRepository.fetchUpgradeTargets(
                    for: session,
                    upgradeItemPledgeID: upgradeItemPledgeID
                )
            } onTimeout: {
                HangarAccountActionError.upgradeTargetLookupFailed(
                    message: AppLocalizer.format(
                        "RSI did not return the eligible upgrade targets within %lld seconds.",
                        timeoutSeconds
                    )
                )
            }

            let enrichedTargets = enrichUpgradeTargets(targets, from: snapshot)
            guard !enrichedTargets.isEmpty else {
                throw HangarAccountActionError.noEligibleUpgradeTargets
            }

            return enrichedTargets
        } catch let error as HangarAccountActionError {
            throw error
        } catch {
            throw HangarAccountActionError.upgradeTargetLookupFailed(message: error.localizedDescription)
        }
    }

    func applyUpgrade(
        packageGroup: GroupedHangarPackage,
        target: UpgradeTargetCandidate
    ) async throws {
        guard !isRefreshing else {
            throw HangarAccountActionError.actionInProgress
        }

        guard let session else {
            throw HangarAccountActionError.missingSession
        }

        let upgradeItemPledgeID = try selectedUpgradeItemPledgeID(for: packageGroup)
        guard target.pledgeID > 0 else {
            throw HangarAccountActionError.invalidUpgradeTarget
        }

        let preUpgradeSnapshot = snapshot

        guard let credentials = session.credentials,
              !credentials.password.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw HangarAccountActionError.missingStoredPassword
        }

        try await sensitiveActionAuthorizer.authorize(
            reason: upgradeAuthorizationReason(for: packageGroup, target: target)
        )

        let timeoutSeconds = Self.upgradeRequestTimeoutSeconds
        let result = try await withTimeout(seconds: timeoutSeconds) { [self] in
            try await self.hangarRepository.applyUpgrade(
                for: session,
                upgradeItemPledgeID: upgradeItemPledgeID,
                targetPledgeID: target.pledgeID,
                password: credentials.password
            )
        } onTimeout: {
            HangarAccountActionError.upgradeTimedOut(timeoutSeconds: timeoutSeconds)
        }

        if !result.updatedCookies.isEmpty {
            let updatedSession = session.updatingCookies(result.updatedCookies)
            applyStoredSessions(await sessionStore.save(updatedSession, makeActive: true), resetContent: false)
        }

        guard result.wasSuccessful else {
            throw HangarAccountActionError.upgradeRejected(
                message: result.failureMessage ?? AppLocalizer.string("RSI stopped the upgrade request before Hangar Express could confirm it.")
            )
        }

        let consumedUpgradePledgeID = result.upgradeItemPledgeID > 0
            ? result.upgradeItemPledgeID
            : upgradeItemPledgeID
        let upgradedTargetPledgeID = result.targetPledgeID > 0
            ? result.targetPledgeID
            : target.pledgeID
        applyOptimisticRemovalUpdate(
            affectedPledgeIDs: [consumedUpgradePledgeID],
            session: self.session ?? session
        )

        let reconciliationSession = self.session ?? session
        scheduleSilentHangarActionReconciliation(
            using: reconciliationSession,
            previousSnapshotForHangarRefresh: preUpgradeSnapshot,
            affectedPledgeIDs: [consumedUpgradePledgeID, upgradedTargetPledgeID],
            logInitialDetail: AppLocalizer.string("Waiting for RSI to post the new upgrade entry to your hangar log."),
            logRetryDetail: AppLocalizer.string("RSI has not posted the new upgrade log entry yet. Checking again."),
            refreshFailurePrefix: AppLocalizer.string("The upgrade completed, but the background hangar refresh could not finish.")
        )

        showCompletedActionBanner(
            title: AppLocalizer.string("Upgrade Complete"),
            message: AppLocalizer.string("The selected upgrade was successfully applied.")
        )
    }

    func requestCharacterRepair() async throws {
        guard !isRefreshing else {
            throw HangarAccountActionError.actionInProgress
        }

        guard let session else {
            throw HangarAccountActionError.missingSession
        }

        guard let credentials = session.credentials,
              !credentials.password.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw HangarAccountActionError.missingStoredPassword
        }

        try await sensitiveActionAuthorizer.authorize(
            reason: characterRepairAuthorizationReason()
        )

        let timeoutSeconds = Self.characterRepairRequestTimeoutSeconds
        do {
            let result = try await withTimeout(seconds: timeoutSeconds) { [self] in
                try await self.hangarRepository.requestCharacterRepair(
                    for: session,
                    password: credentials.password
                )
            } onTimeout: {
                HangarAccountActionError.characterRepairTimedOut(timeoutSeconds: timeoutSeconds)
            }

            if !result.updatedCookies.isEmpty {
                await persistUpdatedSessionCookies(result.updatedCookies, baseSession: session)
            }

            guard result.wasSuccessful else {
                throw HangarAccountActionError.characterRepairRejected(
                    message: result.failureMessage ?? AppLocalizer.string("RSI stopped the character repair request before Hangar Express could confirm it.")
                )
            }

            showCompletedActionBanner(
                title: AppLocalizer.string("Success"),
                message: AppLocalizer.string("Your character has been reset")
            )
        } catch let error as HangarAccountActionError {
            throw error
        } catch {
            if await handleReauthenticationIfNeeded(
                for: error,
                session: session,
                existingSnapshot: snapshot
            ) {
                throw HangarAccountActionError.characterRepairRejected(
                    message: AppLocalizer.string("Your saved RSI session expired. Sign in again before requesting a character repair.")
                )
            }

            throw HangarAccountActionError.characterRepairRejected(message: error.localizedDescription)
        }
    }

    func prepareBuybackCheckout(for pledge: BuybackPledge) async throws -> BuybackCheckoutPreparation {
        guard !isRefreshing else {
            throw HangarAccountActionError.actionInProgress
        }

        guard pledge.id > 0 else {
            throw HangarAccountActionError.invalidBuybackItem
        }

        guard let session else {
            throw HangarAccountActionError.missingSession
        }

        let timeoutSeconds = Self.buybackCheckoutPreparationTimeoutSeconds
        do {
            let result = try await withTimeout(seconds: timeoutSeconds) { [self] in
                try await self.hangarRepository.prepareBuybackCheckout(
                    for: session,
                    pledge: pledge
                )
            } onTimeout: {
                HangarAccountActionError.buybackCheckoutRejected(
                    message: AppLocalizer.format(
                        "RSI did not prepare the buy-back cart within %lld seconds.",
                        timeoutSeconds
                    )
                )
            }

            if !result.updatedCookies.isEmpty {
                await persistUpdatedSessionCookies(result.updatedCookies, baseSession: session)
            }

            return result
        } catch let error as HangarAccountActionError {
            throw error
        } catch {
            throw HangarAccountActionError.buybackCheckoutRejected(message: error.localizedDescription)
        }
    }

    func fetchLimitedShipSales() async throws -> [LimitedShipSale] {
        try await hangarRepository.fetchLimitedShipSales()
    }

    func addLimitedShipToCart(
        _ ship: LimitedShipSale,
        log: @escaping LimitedShipCartLogHandler = { _ in }
    ) async throws -> LimitedShipCartInsertionResult {
        guard !isRefreshing else {
            throw HangarAccountActionError.actionInProgress
        }

        guard !ship.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw HangarAccountActionError.invalidLimitedShip
        }

        guard let session else {
            throw HangarAccountActionError.missingSession
        }

        let timeoutSeconds = Self.limitedShipCartInsertionTimeoutSeconds
        do {
            let result = try await withTimeout(seconds: timeoutSeconds) { [self] in
                try await self.hangarRepository.addLimitedShipToCart(
                    for: session,
                    ship: ship,
                    log: log
                )
            } onTimeout: {
                HangarAccountActionError.limitedShipCartInsertionTimedOut(timeoutSeconds: timeoutSeconds)
            }

            if !result.updatedCookies.isEmpty {
                await persistUpdatedSessionCookies(result.updatedCookies, baseSession: session)
            }

            return result
        } catch let error as HangarAccountActionError {
            throw error
        } catch {
            throw HangarAccountActionError.limitedShipCartInsertionRejected(message: error.localizedDescription)
        }
    }

    func fetchAuthorizedDevices() async throws -> [AuthorizedDevice] {
        guard let session else {
            throw HangarAccountActionError.missingSession
        }

        let timeoutSeconds = Self.authorizedDevicesRequestTimeoutSeconds
        let password = session.credentials?.password
        do {
            return try await withTimeout(seconds: timeoutSeconds) { [self] in
                try await self.hangarRepository.fetchAuthorizedDevices(for: session, password: password)
            } onTimeout: {
                HangarAccountActionError.authorizedDevicesUnavailable(
                    message: AppLocalizer.format(
                        "RSI did not return the authorized-device list within %lld seconds.",
                        timeoutSeconds
                    )
                )
            }
        } catch let error as HangarAccountActionError {
            throw error
        } catch {
            if await handleReauthenticationIfNeeded(
                for: error,
                session: session,
                existingSnapshot: snapshot
            ) {
                throw HangarAccountActionError.authorizedDevicesUnavailable(
                    message: AppLocalizer.string("Your saved RSI session expired. Sign in again before managing authorized devices.")
                )
            }

            throw HangarAccountActionError.authorizedDevicesUnavailable(message: error.localizedDescription)
        }
    }

    func removeAuthorizedDevice(_ device: AuthorizedDevice) async throws {
        guard let session else {
            throw HangarAccountActionError.missingSession
        }

        guard !device.shouldProtectFromBulkRemoval else {
            throw HangarAccountActionError.authorizedDeviceRemovalRejected(
                message: AppLocalizer.string("Hangar Express will not remove the authorized device currently used by this app.")
            )
        }

        try await sensitiveActionAuthorizer.authorize(
            reason: AppLocalizer.format("Confirm removing %@ from your authorized RSI devices.", device.displayName)
        )

        let timeoutSeconds = Self.authorizedDevicesRequestTimeoutSeconds
        let password = session.credentials?.password
        do {
            try await withTimeout(seconds: timeoutSeconds) { [self] in
                try await self.hangarRepository.removeAuthorizedDevice(for: session, device: device, password: password)
            } onTimeout: {
                HangarAccountActionError.authorizedDeviceRemovalRejected(
                    message: AppLocalizer.format(
                        "RSI did not remove %@ within %lld seconds.",
                        device.displayName,
                        timeoutSeconds
                    )
                )
            }
        } catch let error as HangarAccountActionError {
            throw error
        } catch {
            if await handleReauthenticationIfNeeded(
                for: error,
                session: session,
                existingSnapshot: snapshot
            ) {
                throw HangarAccountActionError.authorizedDeviceRemovalRejected(
                    message: AppLocalizer.string("Your saved RSI session expired. Sign in again before managing authorized devices.")
                )
            }

            throw HangarAccountActionError.authorizedDeviceRemovalRejected(message: error.localizedDescription)
        }
    }

    func removeAuthorizedDevicesExceptCurrent(_ devices: [AuthorizedDevice]) async throws {
        let hasCurrentDeviceMarker = devices.contains(where: \.isCurrent)
        let hasHangarExpressFallback = devices.contains(where: \.matchesHangarExpressDeviceName)
        guard hasCurrentDeviceMarker || hasHangarExpressFallback else {
            throw HangarAccountActionError.authorizedDeviceRemovalRejected(
                message: AppLocalizer.string("Hangar Express could not identify this app's current RSI device, so it did not remove all devices.")
            )
        }

        let removableDevices = devices.filter { device in
            if hasCurrentDeviceMarker {
                return !device.isCurrent
            }

            // The RSI current-device marker should normally be present. If it is not,
            // keep Hangar Express-named sessions so the bulk action cannot sign out this app.
            return !device.matchesHangarExpressDeviceName
        }
        guard !removableDevices.isEmpty else {
            return
        }

        try await sensitiveActionAuthorizer.authorize(
            reason: AppLocalizer.format(
                "Confirm removing %lld authorized RSI devices except this app.",
                removableDevices.count
            )
        )

        guard let session else {
            throw HangarAccountActionError.missingSession
        }

        let timeoutSeconds = max(Self.authorizedDevicesRequestTimeoutSeconds, removableDevices.count * 8)
        let password = session.credentials?.password
        do {
            try await withTimeout(seconds: timeoutSeconds) { [self] in
                try await self.hangarRepository.removeAuthorizedDevices(for: session, devices: removableDevices, password: password)
            } onTimeout: {
                HangarAccountActionError.authorizedDeviceRemovalRejected(
                    message: AppLocalizer.format(
                        "RSI did not remove %lld logged-in devices within %lld seconds.",
                        removableDevices.count,
                        timeoutSeconds
                    )
                )
            }
        } catch let error as HangarAccountActionError {
            throw error
        } catch {
            if await handleReauthenticationIfNeeded(
                for: error,
                session: session,
                existingSnapshot: snapshot
            ) {
                throw HangarAccountActionError.authorizedDeviceRemovalRejected(
                    message: AppLocalizer.string("Your saved RSI session expired. Sign in again before managing authorized devices.")
                )
            }

            throw HangarAccountActionError.authorizedDeviceRemovalRejected(message: error.localizedDescription)
        }
    }

    func persistBrowserCookies(_ cookies: [SessionCookie]) async {
        guard !cookies.isEmpty, let session else {
            return
        }

        await persistUpdatedSessionCookies(cookies, baseSession: session)
    }

    private func cancelSilentHangarActionReconciliation() {
        silentHangarActionReconciliationTask?.cancel()
        silentHangarActionReconciliationTask = nil
        silentHangarActionReconciliationGeneration += 1
    }

    private func persistUpdatedSessionCookies(_ cookies: [SessionCookie], baseSession: UserSession) async {
        guard !cookies.isEmpty else {
            return
        }

        let updatedSession = baseSession.updatingCookies(cookies)
        applyStoredSessions(await sessionStore.save(updatedSession, makeActive: true), resetContent: false)
    }

    private func scheduleSilentHangarActionReconciliation(
        using session: UserSession,
        previousSnapshotForHangarRefresh: HangarSnapshot?,
        affectedPledgeIDs: [Int],
        logInitialDetail: String,
        logRetryDetail: String,
        refreshFailurePrefix: String
    ) {
        cancelSilentHangarActionReconciliation()

        let generation = silentHangarActionReconciliationGeneration
        silentHangarActionReconciliationTask = Task { @MainActor [weak self] in
            guard let self else {
                return
            }

            await reconcileSuccessfulHangarAction(
                using: session,
                previousSnapshotForHangarRefresh: previousSnapshotForHangarRefresh,
                affectedPledgeIDs: affectedPledgeIDs,
                logInitialDetail: logInitialDetail,
                logRetryDetail: logRetryDetail,
                refreshFailurePrefix: refreshFailurePrefix,
                generation: generation
            )

            guard self.silentHangarActionReconciliationGeneration == generation else {
                return
            }

            self.silentHangarActionReconciliationTask = nil
        }
    }

    private func applyOptimisticRemovalUpdate(
        affectedPledgeIDs: [Int],
        session: UserSession
    ) {
        guard let snapshot, !affectedPledgeIDs.isEmpty else {
            return
        }

        let affectedPackageIDs = Set(affectedPledgeIDs)
        let optimisticSnapshot = snapshot.removingPackages(
            withIDs: affectedPackageIDs,
            lastSyncedAt: snapshot.lastSyncedAt
        )

        loadState = .loaded(optimisticSnapshot)
        lastRefreshErrorMessage = nil
        lastRefreshErrorScope = nil
        persistSnapshotInBackground(optimisticSnapshot, for: session)
    }

    private func reconcileSuccessfulHangarAction(
        using session: UserSession,
        previousSnapshotForHangarRefresh: HangarSnapshot?,
        affectedPledgeIDs: [Int],
        logInitialDetail: String,
        logRetryDetail: String,
        refreshFailurePrefix: String,
        generation: Int
    ) async {
        guard shouldContinueSilentHangarActionReconciliation(using: session, generation: generation) else {
            return
        }

        let displayedSnapshot = snapshot
        let repositorySnapshot = previousSnapshotForHangarRefresh ?? displayedSnapshot
        let baselineHangarLogs = repositorySnapshot?.hangarLogs ?? displayedSnapshot?.hangarLogs ?? []

        guard let repositorySnapshot else {
            refreshDiagnostics.record(
                stage: "refresh.hangar.background-skipped",
                summary: "Skipped a background post-action reconciliation because no baseline snapshot was available.",
                level: .warning
            )
            return
        }

        beginRefreshDiagnostics(
            for: .hangarLog,
            session: session,
            context: "Starting the post-action hangar log refresh before rebuilding the affected hangar pages."
        )

        let logSnapshotBase = displayedSnapshot ?? repositorySnapshot
        let shouldContinueToHangarRefresh = await refreshHangarLogAfterSuccessfulAction(
            using: session,
            existingSnapshot: logSnapshotBase,
            baselineLogs: baselineHangarLogs,
            initialDetail: logInitialDetail,
            retryDetail: logRetryDetail,
            generation: generation,
            updatesVisibleProgress: false
        )

        guard shouldContinueToHangarRefresh,
              shouldContinueSilentHangarActionReconciliation(using: session, generation: generation) else {
            return
        }

        let latestDisplayedSnapshot = snapshot

        do {
            let refreshedSnapshot = try await refreshedSnapshot(
                for: session,
                existingSnapshot: repositorySnapshot,
                scope: .hangar,
                affectedPledgeIDs: affectedPledgeIDs
            ) { _ in }

            guard shouldContinueSilentHangarActionReconciliation(using: session, generation: generation) else {
                return
            }
            lastRefreshAt = refreshedSnapshot.lastSyncedAt
            loadState = .loaded(refreshedSnapshot)
            lastRefreshErrorMessage = nil
            lastRefreshErrorScope = nil
            refreshDiagnostics.record(
                stage: "refresh.hangar.background-complete",
                summary: "The background post-action hangar refresh finished successfully."
            )
            persistSnapshotInBackground(refreshedSnapshot, for: session)
            schedulePostRefreshImageInvalidation(
                for: .hangar,
                previousSnapshot: displayedSnapshot,
                refreshedSnapshot: refreshedSnapshot
            )
        } catch {
            if await handleReauthenticationIfNeeded(
                for: error,
                session: session,
                existingSnapshot: latestDisplayedSnapshot
            ) {
                return
            }

            refreshDiagnostics.record(
                stage: "refresh.hangar.background-failed",
                summary: refreshFailurePrefix,
                detail: "errorType=\(String(reflecting: type(of: error))), localizedDescription=\(error.localizedDescription)",
                level: .warning
            )
        }

        guard shouldContinueSilentHangarActionReconciliation(using: session, generation: generation) else {
            return
        }
    }

    private func refreshHangarLogAfterSuccessfulAction(
        using session: UserSession,
        existingSnapshot: HangarSnapshot,
        baselineLogs: [HangarLogEntry],
        initialDetail: String,
        retryDetail: String,
        generation: Int,
        updatesVisibleProgress: Bool
    ) async -> Bool {
        var logSnapshot = existingSnapshot
        let progressRelay = RefreshProgressDisplayRelay { [weak self] progress in
            self?.applyIncomingRefreshProgress(progress)
        }
        defer {
            progressRelay.cancel()
        }

        for attempt in 1 ... 3 {
            guard shouldContinueSilentHangarActionReconciliation(using: session, generation: generation) else {
                return false
            }

            if updatesVisibleProgress {
                activeRefreshScope = .hangarLog
                refreshProgress = RefreshProgress(
                    stage: .hangarLog,
                    stepNumber: 1,
                    stepCount: 2,
                    detail: attempt == 1
                        ? initialDetail
                        : retryDetail,
                    completedUnitCount: 0,
                    totalUnitCount: 1
                )
            }
            try? await Task.sleep(nanoseconds: 1_000_000_000)

            guard shouldContinueSilentHangarActionReconciliation(using: session, generation: generation) else {
                return false
            }

            do {
                let refreshedSnapshot = try await refreshedSnapshot(
                    for: session,
                    existingSnapshot: logSnapshot,
                    scope: .hangarLog
                ) { progress in
                    guard updatesVisibleProgress else {
                        return
                    }

                    progressRelay.submit(progress)
                }

                guard shouldContinueSilentHangarActionReconciliation(using: session, generation: generation) else {
                    return false
                }
                lastRefreshAt = refreshedSnapshot.lastSyncedAt
                loadState = .loaded(refreshedSnapshot)
                lastRefreshErrorMessage = nil
                lastRefreshErrorScope = nil
                refreshDiagnostics.record(
                    stage: "refresh.hangar-log.attempt",
                    summary: "A post-action hangar log refresh attempt completed.",
                    detail: "attempt=\(attempt), cachedLogCount=\(refreshedSnapshot.hangarLogs.count)"
                )
                logSnapshot = refreshedSnapshot
                persistSnapshotInBackground(refreshedSnapshot, for: session)
            } catch {
                if await handleReauthenticationIfNeeded(
                    for: error,
                    session: session,
                    existingSnapshot: snapshot
                ) {
                    return false
                }

                if attempt == 3 {
                    refreshDiagnostics.record(
                        stage: "refresh.hangar-log.retry",
                        summary: "The post-action hangar log refresh exhausted its retries and will fall back to the hangar rebuild.",
                        detail: "attempt=\(attempt), errorType=\(String(reflecting: type(of: error))), localizedDescription=\(error.localizedDescription)",
                        level: .warning
                    )
                    return true
                }

                refreshDiagnostics.record(
                    stage: "refresh.hangar-log.retry",
                    summary: "A post-action hangar log refresh attempt failed and will retry.",
                    detail: "attempt=\(attempt), errorType=\(String(reflecting: type(of: error))), localizedDescription=\(error.localizedDescription)",
                    level: .warning
                )
                continue
            }

            guard shouldContinueSilentHangarActionReconciliation(using: session, generation: generation) else {
                return false
            }

            if hangarLogContainsNewEntries(comparedTo: baselineLogs) {
                return true
            }
        }

        return true
    }

    private func shouldContinueSilentHangarActionReconciliation(
        using session: UserSession,
        generation: Int
    ) -> Bool {
        !Task.isCancelled
            && silentHangarActionReconciliationGeneration == generation
            && self.session?.accountKey == session.accountKey
    }

    private func hangarLogContainsNewEntries(comparedTo baselineLogs: [HangarLogEntry]) -> Bool {
        guard let currentLogs = snapshot?.hangarLogs,
              !currentLogs.isEmpty else {
            return false
        }

        guard !baselineLogs.isEmpty else {
            return true
        }

        let baselineRecentEntryIDs = Set(baselineLogs.prefix(25).map(\.id))
        let currentRecentLogs = currentLogs.prefix(25)

        if currentLogs.count > baselineLogs.count {
            return true
        }

        return currentRecentLogs.contains { entry in
            !baselineRecentEntryIDs.contains(entry.id)
        }
    }

    private func handleReauthenticationIfNeeded(
        for error: Error,
        session: UserSession,
        existingSnapshot: HangarSnapshot?
    ) async -> Bool {
        guard let liveError = error as? LiveHangarRepositoryError,
              liveError.requiresReauthentication else {
            return false
        }

        let invalidatedSession = session.clearingCookies(
            notes: "The saved RSI session expired and needs a fresh sign-in."
        )
        authDiagnostics.record(
            stage: "auth.reauthenticate",
            summary: "The saved RSI session can no longer refresh live data and needs a fresh sign-in.",
            detail: "reason=\(liveError.localizedDescription)",
            level: .warning
        )
        applyStoredSessions(await sessionStore.save(invalidatedSession, makeActive: true), resetContent: false)
        lastRefreshErrorMessage = nil
        lastRefreshErrorScope = nil

        let notice = liveError == .sessionExpired
            ? AppLocalizer.string("Your saved RSI session expired. Sign in again to continue refreshing live data.")
            : AppLocalizer.string("This saved RSI account no longer has a usable session. Sign in again to continue refreshing live data.")

        if let existingSnapshot {
            loadState = .loaded(existingSnapshot)
            reauthenticationPrompt = ReauthenticationPrompt(
                title: AppLocalizer.string("Sign In Again"),
                message: notice
            )
        } else {
            await transitionToAuthentication(using: invalidatedSession, notice: notice)
        }

        return true
    }

    private func transitionToAuthentication(using session: UserSession, notice: String) async {
        await authService.cancelPendingAuthentication()
        authDiagnostics.record(
            stage: "auth.transition",
            summary: "Returning to the login flow for the selected RSI account.",
            detail: "displayName=\(session.displayName), notice=\(notice)"
        )
        reauthenticationPrompt = nil
        pendingAuthenticationDraft = AuthenticationDraft(
            loginIdentifier: session.credentials?.loginIdentifier ?? session.email,
            password: session.credentials?.password ?? "",
            rememberMe: true,
            notice: notice
        )
        authenticationFlowID = UUID()
        selectedTab = .hangar
        self.session = nil
        lastRefreshAt = nil
        loadState = .idle
        refreshProgress = nil
        concurrentRefreshEntries = []
        lastRefreshErrorMessage = nil
        lastRefreshErrorScope = nil
        activeRefreshScope = nil
        refreshIndicatorStyle = .standardCard
    }

    private func restoreCachedSnapshot(for session: UserSession) async -> Bool {
        guard let cachedSnapshot = await snapshotStore.load(for: session) else {
            return false
        }

        lastRefreshAt = cachedSnapshot.lastSyncedAt
        loadState = .loaded(cachedSnapshot)
        refreshProgress = nil
        concurrentRefreshEntries = []
        lastRefreshErrorMessage = nil
        lastRefreshErrorScope = nil
        activeRefreshScope = nil
        reauthenticationPrompt = nil
        requestItemTranslationPreload(for: cachedSnapshot, promptsWhenCacheIsMissing: true)
        return true
    }

    private func reconcileLaunchState() async {
        guard let session else {
            authDiagnostics.record(
                stage: "auth.launch-state",
                summary: "No active RSI session was found. Showing the login flow."
            )
            loadState = .idle
            return
        }

        guard session.authMode == .developerPreview || !session.cookies.isEmpty else {
            authDiagnostics.record(
                stage: "auth.launch-state",
                summary: "An active RSI account was found, but it no longer has saved cookies.",
                detail: "displayName=\(session.displayName)",
                level: .warning
            )
            await transitionToAuthentication(
                using: session,
                notice: AppLocalizer.string("Your saved RSI session is no longer available. Sign in again to continue.")
            )
            return
        }

        let restoredSnapshot = await restoreCachedSnapshot(for: session)

        if restoredSnapshot {
            authDiagnostics.record(
                stage: "auth.launch-state",
                summary: "Restored the cached snapshot for the active RSI account.",
                detail: "displayName=\(session.displayName), shouldAutoRefresh=\(shouldAutoRefreshAfterResume)"
            )
            guard shouldAutoRefreshAfterResume else {
                return
            }

            await refresh(scope: .full)
            return
        }

        authDiagnostics.record(
            stage: "auth.launch-state",
            summary: "No cached snapshot was available for the active RSI account. Starting a full refresh.",
            detail: "displayName=\(session.displayName)"
        )
        await refresh(scope: .full)
    }

    private var shouldAutoRefreshAfterResume: Bool {
        guard session != nil,
              !isRefreshing,
              versionRefreshPrompt == nil else {
            return false
        }

        return SyncPreferences.shouldAutoRefreshInventory(
            lastRefreshAt: lastRefreshAt,
            interval: SyncPreferences.resolvedInventoryAutoRefreshInterval(
                from: userDefaults.string(forKey: SyncPreferences.inventoryAutoRefreshIntervalKey)
            )
        )
    }

    private func refreshedSnapshot(
        for session: UserSession,
        existingSnapshot: HangarSnapshot?,
        scope: RefreshScope,
        affectedPledgeIDs: [Int]? = nil,
        hangarLogBatchHandler: HangarLogBatchHandler? = nil,
        progress: @escaping RefreshProgressHandler
    ) async throws -> HangarSnapshot {
        switch scope {
        case .full:
            return try await hangarRepository.fetchSnapshot(for: session, progress: progress)
        case .hangar:
            guard let existingSnapshot else {
                return try await hangarRepository.fetchSnapshot(for: session, progress: progress)
            }

            if let affectedPledgeIDs, !affectedPledgeIDs.isEmpty {
                return try await hangarRepository.refreshHangarData(
                    for: session,
                    from: existingSnapshot,
                    affectedPledgeIDs: affectedPledgeIDs,
                    progress: progress
                )
            }

            return try await hangarRepository.refreshHangarData(
                for: session,
                from: existingSnapshot,
                progress: progress
            )
        case .buyback:
            guard let existingSnapshot else {
                return try await hangarRepository.fetchSnapshot(for: session, progress: progress)
            }

            return try await hangarRepository.refreshBuybackData(
                for: session,
                from: existingSnapshot,
                progress: progress
            )
        case .hangarLog:
            guard let existingSnapshot else {
                return try await hangarRepository.fetchSnapshot(for: session, progress: progress)
            }

            let mode: HangarLogFetchMode = isPro ? .expanded : .initial
            return try await hangarRepository.refreshHangarLogData(
                for: session,
                from: existingSnapshot,
                mode: mode,
                progress: progress,
                batchHandler: hangarLogBatchHandler
            )
        case .account:
            guard let existingSnapshot else {
                return try await hangarRepository.fetchSnapshot(for: session, progress: progress)
            }

            return try await hangarRepository.refreshAccountData(
                for: session,
                from: existingSnapshot,
                progress: progress
            )
        }
    }

    private func refreshFullSnapshotConcurrently(
        for session: UserSession,
        existingSnapshot: HangarSnapshot?,
        progressRelay: RefreshProgressDisplayRelay
    ) async throws -> HangarSnapshot {
        let refreshedSnapshot = try await hangarRepository.fetchSnapshot(for: session) { progress in
            progressRelay.submit(progress)
        }

        guard refreshedSnapshot.hangarLogs.isEmpty,
              let existingSnapshot,
              !existingSnapshot.hangarLogs.isEmpty else {
            return refreshedSnapshot
        }

        return refreshedSnapshot.updatingHangarLogs(
            hangarLogs: existingSnapshot.hangarLogs
        )
    }

    func loadMoreHangarLogEntries() async {
        guard let session,
              let existingSnapshot = snapshot,
              !isRefreshing,
              isPro else {
            return
        }

        activeRefreshScope = .hangarLog
        refreshIndicatorStyle = .standardCard
        refreshProgress = RefreshProgress(
            stage: .hangarLog,
            stepNumber: 1,
            stepCount: 2,
            detail: AppLocalizer.string("Loading older hangar log entries from RSI."),
            completedUnitCount: 0,
            totalUnitCount: 1
        )
        beginRefreshDiagnostics(
            for: .hangarLog,
            session: session,
            context: AppLocalizer.string("Loading older hangar log entries from RSI.")
        )
        let progressRelay = RefreshProgressDisplayRelay { [weak self] progress in
            self?.applyIncomingRefreshProgress(progress)
        }

        defer {
            progressRelay.cancel()
            refreshProgress = nil
            concurrentRefreshEntries = []
            activeRefreshScope = nil
        }

        do {
            let refreshedSnapshot = try await hangarRepository.refreshHangarLogData(
                for: session,
                from: existingSnapshot,
                mode: .expanded
            ) { progress in
                progressRelay.submit(progress)
            }

            completeVisibleRefresh(
                refreshedSnapshot,
                diagnosticsStage: "refresh.hangar-log.expanded",
                diagnosticsSummary: "Loaded additional hangar log history from RSI."
            )
            persistSnapshotInBackground(refreshedSnapshot, for: session)
            return
        } catch {
            if await handleReauthenticationIfNeeded(
                for: error,
                session: session,
                existingSnapshot: existingSnapshot
            ) {
                return
            }

            loadState = .loaded(existingSnapshot)
            presentRefreshError(
                AppLocalizer.format("Unable to refresh the hangar log. %@", error.localizedDescription),
                scope: .hangarLog,
                error: error
            )
        }
    }

    private func applyIncomingRefreshProgress(_ progress: RefreshProgress) {
        guard let trackerID = progress.trackerID,
              let area = ConcurrentRefreshEntry.Area(rawValue: trackerID) else {
            concurrentRefreshEntries = []
            refreshProgress = progress
            return
        }

        refreshProgress = nil

        let isComplete = isCompletedConcurrentRefreshProgress(progress)
        let entry = ConcurrentRefreshEntry(
            area: area,
            progress: progress,
            isComplete: isComplete || concurrentRefreshEntries.first(where: { $0.area == area })?.isComplete == true
        )

        if let existingIndex = concurrentRefreshEntries.firstIndex(where: { $0.area == area }) {
            concurrentRefreshEntries[existingIndex] = entry
        } else {
            concurrentRefreshEntries.append(entry)
        }

        concurrentRefreshEntries.sort { lhs, rhs in
            refreshAreaSortIndex(lhs.area) < refreshAreaSortIndex(rhs.area)
        }

        if isComplete, concurrentRefreshEntries.allSatisfy(\.isComplete) {
            refreshProgress = RefreshProgress(
                stage: .finalizing,
                stepNumber: max(progress.stepNumber, progress.stepCount),
                stepCount: progress.stepCount,
                detail: AppLocalizer.string("Hangar, buyback, and account syncs are ready."),
                completedUnitCount: 0,
                totalUnitCount: nil
            )
        }
    }

    private func isCompletedConcurrentRefreshProgress(_ progress: RefreshProgress) -> Bool {
        guard let totalUnitCount = progress.totalUnitCount, totalUnitCount > 0 else {
            return false
        }

        return progress.completedUnitCount >= totalUnitCount
    }

    private func refreshAreaSortIndex(_ area: ConcurrentRefreshEntry.Area) -> Int {
        switch area {
        case .hangar:
            return 0
        case .buyback:
            return 1
        case .account:
            return 2
        }
    }

    private func initialProgress(for session: UserSession, scope: RefreshScope) -> RefreshProgress {
        if session.authMode == .developerPreview {
            return RefreshProgress(
                stage: .preview,
                stepNumber: 1,
                stepCount: 1,
                detail: AppLocalizer.string("Loading the local sample hangar snapshot."),
                completedUnitCount: 0,
                totalUnitCount: 1
            )
        }

        return RefreshProgress(
            stage: .preparingSession,
            stepNumber: 1,
            stepCount: stepCount(for: scope),
            detail: initialRefreshDetail(for: scope),
            completedUnitCount: 0,
            totalUnitCount: 1
        )
    }

    private func initialConcurrentRefreshEntries(
        for session: UserSession,
        scope: RefreshScope
    ) -> [ConcurrentRefreshEntry] {
        guard scope == .full, session.authMode != .developerPreview else {
            return []
        }

        return ConcurrentRefreshEntry.Area.allCases.map { area in
            ConcurrentRefreshEntry(
                area: area,
                progress: RefreshProgress(
                    stage: .preparingSession,
                    stepNumber: 1,
                    stepCount: 1,
                    detail: AppLocalizer.string("Waiting for refresh to start."),
                    completedUnitCount: 0,
                    totalUnitCount: nil,
                    trackerID: area.rawValue,
                    trackerTitle: area.title
                ),
                isComplete: false
            )
        }
    }

    private func stepCount(for scope: RefreshScope) -> Int {
        switch scope {
        case .full:
            return 5
        case .hangar:
            return 3
        case .buyback, .hangarLog, .account:
            return 2
        }
    }

    private func initialRefreshDetail(for scope: RefreshScope) -> String {
        switch scope {
        case .full:
            return AppLocalizer.string("Preparing your saved RSI cookies for a full refresh.")
        case .hangar:
            return AppLocalizer.string("Preparing your saved RSI cookies for a hangar refresh.")
        case .buyback:
            return AppLocalizer.string("Preparing your saved RSI cookies for a buy-back refresh.")
        case .hangarLog:
            return AppLocalizer.string("Preparing your saved RSI cookies for a hangar log refresh.")
        case .account:
            return AppLocalizer.string("Preparing your saved RSI cookies for an account refresh.")
        }
    }

    private func applyStoredSessions(_ snapshot: StoredSessionsSnapshot, resetContent: Bool) {
        let previousSessionID = session?.id

        session = snapshot.activeSession
        savedSessions = snapshot.savedSessions

        guard resetContent || previousSessionID != snapshot.activeSession?.id else {
            return
        }

        lastRefreshAt = nil
        loadState = .idle
        refreshProgress = nil
        concurrentRefreshEntries = []
        lastRefreshErrorMessage = nil
        lastRefreshErrorScope = nil
        activeRefreshScope = nil
        refreshIndicatorStyle = .standardCard
    }

    private func beginRefreshDiagnostics(
        for scope: RefreshScope,
        session: UserSession,
        context: String? = nil
    ) {
        refreshDiagnostics.reset(
            context: context ?? "Starting a \(refreshScopeDisplayName(scope).lowercased()) refresh."
        )
        refreshDiagnostics.record(
            stage: "refresh.context",
            summary: "Prepared the \(refreshScopeDisplayName(scope).lowercased()) refresh pipeline.",
            detail: [
                "account=\(session.displayName)",
                "handle=\(session.handle)",
                "cookieCount=\(session.cookies.count)",
                "authMode=\(session.authMode.rawValue)",
                "lastRefreshAt=\(lastRefreshAt?.formatted(date: .abbreviated, time: .standard) ?? "none")"
            ].joined(separator: ", ")
        )
    }

    private func presentRefreshError(
        _ message: String,
        scope: RefreshScope,
        error: Error
    ) {
        lastRefreshErrorMessage = message
        lastRefreshErrorScope = scope
        recordRefreshFailure(message, scope: scope, error: error)
    }

    private func recordRefreshFailure(
        _ message: String,
        scope: RefreshScope,
        error: Error
    ) {
        refreshDiagnostics.record(
            stage: "refresh.failed",
            summary: "\(refreshScopeDisplayName(scope)) refresh failed.",
            detail: [
                "message=\(message)",
                "errorType=\(String(reflecting: type(of: error)))",
                "localizedDescription=\(error.localizedDescription)"
            ].joined(separator: "\n"),
            level: .error
        )
    }

    private func refreshScopeDisplayName(_ scope: RefreshScope) -> String {
        switch scope {
        case .full:
            return AppLocalizer.string("Full account")
        case .hangar:
            return AppLocalizer.string("Hangar")
        case .buyback:
            return AppLocalizer.string("Buy Back")
        case .hangarLog:
            return AppLocalizer.string("Hangar Log")
        case .account:
            return AppLocalizer.string("Account")
        }
    }

    private func detectAppUpdateIfNeeded() {
        guard let currentVersion = currentAppVersionIdentifier() else {
            return
        }

        let previousVersion = userDefaults.string(forKey: Self.lastLaunchedVersionDefaultsKey)
        userDefaults.set(currentVersion, forKey: Self.lastLaunchedVersionDefaultsKey)

        guard let previousVersion,
              previousVersion != currentVersion,
              session != nil else {
            return
        }

        versionRefreshPrompt = VersionRefreshPrompt(
            previousVersion: previousVersion,
            currentVersion: currentVersion,
            updateNoteKeys: updateNoteKeys(for: currentVersion)
        )
    }

    private func updateNoteKeys(for versionIdentifier: String) -> [String] {
        let shortVersion = versionIdentifier
            .split(separator: " ", maxSplits: 1)
            .first
            .map(String.init) ?? versionIdentifier
        return Self.versionUpdateNoteKeysByShortVersion[shortVersion] ?? []
    }

    private func meltAuthorizationReason(for packageGroup: GroupedHangarPackage, quantity: Int) -> String {
        let packageTitle = packageGroup.representative.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let quantityLabel = quantity == 1
            ? AppLocalizer.string("this item")
            : AppLocalizer.format("%lld copies", quantity)
        let titleSegment = packageTitle.isEmpty ? "" : " (\(packageTitle))"
        return AppLocalizer.format(
            "Confirm melting %@%@. This action cannot be undone.",
            quantityLabel,
            titleSegment
        )
    }

    private func selectedUpgradeItemPledgeID(for packageGroup: GroupedHangarPackage) throws -> Int {
        guard packageGroup.representative.canApplyStoredUpgrade else {
            throw HangarAccountActionError.notOwnedUpgradeItem
        }

        guard let upgradeItemPledgeID = packageGroup.packages.first?.id, upgradeItemPledgeID > 0 else {
            throw HangarAccountActionError.notOwnedUpgradeItem
        }

        return upgradeItemPledgeID
    }

    private func enrichUpgradeTargets(
        _ targets: [UpgradeTargetCandidate],
        from snapshot: HangarSnapshot?
    ) -> [UpgradeTargetCandidate] {
        guard let snapshot else {
            return targets
        }

        let packagesByID = Dictionary(uniqueKeysWithValues: snapshot.packages.map { ($0.id, $0) })

        return targets.map { target in
            guard let package = packagesByID[target.pledgeID] else {
                return target
            }

            return UpgradeTargetCandidate(
                pledgeID: target.pledgeID,
                title: package.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? target.title : package.title,
                status: package.status.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? target.status : package.status,
                insurance: package.displayedInsurance ?? target.insurance,
                thumbnailURL: package.thumbnailURL ?? target.thumbnailURL
            )
        }
    }

    private func upgradeAuthorizationReason(
        for packageGroup: GroupedHangarPackage,
        target: UpgradeTargetCandidate
    ) -> String {
        let upgradeTitle = packageGroup.representative.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedUpgradeTitle = upgradeTitle.isEmpty ? AppLocalizer.string("this stored upgrade") : upgradeTitle
        let targetTitle = target.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedTargetTitle = targetTitle.isEmpty ? AppLocalizer.string("the selected pledge") : targetTitle
        return AppLocalizer.format(
            "Confirm applying %@ to %@. Hangar Express will reuse your saved RSI password after this verification.",
            resolvedUpgradeTitle,
            resolvedTargetTitle
        )
    }

    private func characterRepairAuthorizationReason() -> String {
        AppLocalizer.string("Confirm requesting an RSI character repair. This action cannot be undone and can only be requested once every 1 hour.")
    }

    private func giftAuthorizationReason(
        for packageGroup: GroupedHangarPackage,
        quantity: Int,
        recipientEmail: String
    ) -> String {
        let packageTitle = packageGroup.representative.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let quantityLabel = quantity == 1
            ? AppLocalizer.string("this item")
            : AppLocalizer.format("%lld copies", quantity)
        let titleSegment = packageTitle.isEmpty ? "" : " (\(packageTitle))"
        return AppLocalizer.format(
            "Confirm gifting %@%@ to %@. RSI will send the gift email after this verification.",
            quantityLabel,
            titleSegment,
            recipientEmail
        )
    }

    private func bulkMeltAuthorizationReason(for packages: [HangarPackage]) -> String {
        let selectionLabel = AppLocalizer.format("%lld selected pledge(s)", packages.count)
        return AppLocalizer.format(
            "Confirm melting %@. This action cannot be undone.",
            selectionLabel
        )
    }

    private func bulkGiftAuthorizationReason(
        for packages: [HangarPackage],
        recipientEmail: String
    ) -> String {
        let selectionLabel = AppLocalizer.format("%lld selected pledge(s)", packages.count)
        return AppLocalizer.format(
            "Confirm gifting %@ to %@. RSI will send the gift email after this verification.",
            selectionLabel,
            recipientEmail
        )
    }

    private func resolvedGiftRecipientName(from rawValue: String, session: UserSession) -> String {
        let trimmedValue = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedValue.isEmpty {
            return trimmedValue
        }

        return AppLocalizer.string("User")
    }

    private static func isValidGiftRecipientEmail(_ value: String) -> Bool {
        let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let components = trimmedValue.split(separator: "@", omittingEmptySubsequences: false)
        guard components.count == 2,
              !components[0].isEmpty,
              !components[1].isEmpty else {
            return false
        }

        let domainParts = components[1].split(separator: ".", omittingEmptySubsequences: false)
        return domainParts.count >= 2 && !domainParts.contains(where: \.isEmpty)
    }

    private func showCompletedActionBanner(title: String, message: String) {
        showTransientBanner(
            title: title,
            message: message,
            durationNanoseconds: Self.actionCompletionBannerDurationNanoseconds
        )
    }

    private func showTransientBanner(
        title: String,
        message: String,
        style: TransientBanner.Style = .success,
        durationNanoseconds: UInt64? = nil
    ) {
        let resolvedDurationNanoseconds = durationNanoseconds ?? Self.actionCompletionBannerDurationNanoseconds
        let banner = TransientBanner(
            title: title,
            message: message,
            style: style
        )
        transientBanner = banner

        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: resolvedDurationNanoseconds)

            guard self?.transientBanner?.id == banner.id else {
                return
            }

            self?.transientBanner = nil
        }
    }

    private func withTimeout<T>(
        seconds: Int,
        operation: @escaping @Sendable () async throws -> T,
        onTimeout: @escaping @Sendable () -> Error
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await operation()
            }

            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds) * 1_000_000_000)
                throw onTimeout()
            }

            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }

    private func currentAppVersionIdentifier() -> String? {
        let shortVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let buildVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String

        switch (shortVersion?.trimmingCharacters(in: .whitespacesAndNewlines), buildVersion?.trimmingCharacters(in: .whitespacesAndNewlines)) {
        case let (.some(shortVersion), .some(buildVersion)) where !shortVersion.isEmpty && !buildVersion.isEmpty:
            return "\(shortVersion) (\(buildVersion))"
        case let (.some(shortVersion), _) where !shortVersion.isEmpty:
            return shortVersion
        case let (_, .some(buildVersion)) where !buildVersion.isEmpty:
            return buildVersion
        default:
            return nil
        }
    }

    private func invalidateImageCache(
        for scope: RefreshScope,
        previousSnapshot: HangarSnapshot?,
        refreshedSnapshot: HangarSnapshot
    ) async {
        let urlsToInvalidate = imageURLsToInvalidate(
            for: scope,
            previousSnapshot: previousSnapshot,
            refreshedSnapshot: refreshedSnapshot
        )

        guard !urlsToInvalidate.isEmpty || scope == .full else {
            return
        }

        if !urlsToInvalidate.isEmpty {
            await imageCache.clear(urls: Array(urlsToInvalidate))
        }

        switch scope {
        case .full:
            hangarFleetImageReloadToken = UUID()
            buybackImageReloadToken = UUID()
            accountImageReloadToken = UUID()
        case .hangar:
            hangarFleetImageReloadToken = UUID()
        case .buyback:
            buybackImageReloadToken = UUID()
        case .account:
            accountImageReloadToken = UUID()
        case .hangarLog:
            break
        }
    }

    private func imageURLsToInvalidate(
        for scope: RefreshScope,
        previousSnapshot: HangarSnapshot?,
        refreshedSnapshot: HangarSnapshot
    ) -> Set<URL> {
        let previousURLs: Set<URL>
        let refreshedURLs: Set<URL>

        switch scope {
        case .full:
            previousURLs = allImageURLs(in: previousSnapshot)
            refreshedURLs = allImageURLs(in: refreshedSnapshot)
        case .hangar:
            previousURLs = hangarAndFleetImageURLs(in: previousSnapshot)
            refreshedURLs = hangarAndFleetImageURLs(in: refreshedSnapshot)
        case .buyback:
            previousURLs = buybackImageURLs(in: previousSnapshot)
            refreshedURLs = buybackImageURLs(in: refreshedSnapshot)
        case .account:
            previousURLs = accountImageURLs(in: previousSnapshot)
            refreshedURLs = accountImageURLs(in: refreshedSnapshot)
        case .hangarLog:
            return []
        }

        return previousURLs.union(refreshedURLs)
    }

    private func allImageURLs(in snapshot: HangarSnapshot?) -> Set<URL> {
        hangarAndFleetImageURLs(in: snapshot)
            .union(buybackImageURLs(in: snapshot))
            .union(accountImageURLs(in: snapshot))
    }

    private func hangarAndFleetImageURLs(in snapshot: HangarSnapshot?) -> Set<URL> {
        guard let snapshot else {
            return []
        }

        var urls = Set<URL>()

        for package in snapshot.packages {
            if let thumbnailURL = package.thumbnailURL {
                urls.insert(thumbnailURL)
            }

            for item in package.contents {
                if let imageURL = item.imageURL {
                    urls.insert(imageURL)
                }

                if let sourceImageURL = item.upgradePricing?.sourceShipImageURL {
                    urls.insert(sourceImageURL)
                }

                if let targetImageURL = item.upgradePricing?.targetShipImageURL {
                    urls.insert(targetImageURL)
                }
            }
        }

        for ship in snapshot.fleet {
            if let imageURL = ship.imageURL {
                urls.insert(imageURL)
            }

            if let manufacturerLogoURL = ship.manufacturerLogoURL {
                urls.insert(manufacturerLogoURL)
            }
        }

        return urls
    }

    private func buybackImageURLs(in snapshot: HangarSnapshot?) -> Set<URL> {
        guard let snapshot else {
            return []
        }

        return Set(snapshot.buyback.compactMap(\.imageURL))
    }

    private func accountImageURLs(in snapshot: HangarSnapshot?) -> Set<URL> {
        guard let snapshot else {
            return []
        }

        var urls = Set<URL>()

        if let avatarURL = snapshot.avatarURL {
            urls.insert(avatarURL)
        }

        // Account surfaces can use fleet images as profile-card backgrounds and picker thumbnails.
        for ship in snapshot.fleet {
            if let imageURL = ship.imageURL {
                urls.insert(imageURL)
            }
        }

        return urls
    }
}

private extension AppModel.ItemTranslationPreloadProgress.Phase {
    init(_ phase: OnDeviceHangarItemTranslationPreloadProgress.Phase) {
        switch phase {
        case .preparing:
            self = .preparing
        case .translating:
            self = .translating
        case .finished:
            self = .finished
        case .downloadRequired:
            self = .downloadRequired
        case .unavailable:
            self = .unavailable
        case .failed:
            self = .failed
        }
    }
}
