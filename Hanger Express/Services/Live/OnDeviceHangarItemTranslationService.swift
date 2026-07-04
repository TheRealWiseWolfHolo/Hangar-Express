import Foundation
import Observation
import Translation

nonisolated struct OnDeviceHangarItemTranslationPreloadProgress: Equatable, Sendable {
    enum Phase: Equatable, Sendable {
        case preparing
        case translating
        case finished
        case downloadRequired
        case unavailable
        case failed
    }

    let phase: Phase
    let completedUnitCount: Int
    let totalUnitCount: Int
}

typealias OnDeviceHangarItemTranslationPreloadProgressHandler = @MainActor @Sendable (OnDeviceHangarItemTranslationPreloadProgress) -> Void
typealias OnDeviceHangarItemTranslationPreloadLogHandler = @MainActor @Sendable (String) -> Void

private nonisolated enum TranslationModelInstallStatus: Sendable {
    case installed
    case downloadRequired
    case unavailable
    case timedOut

    var isInstalled: Bool {
        self == .installed
    }
}

private actor OneShotAsyncResult<Value: Sendable> {
    private var continuation: CheckedContinuation<Value, Never>?
    private var pendingValue: Value?
    private var didResume = false

    func install(_ continuation: CheckedContinuation<Value, Never>) {
        guard !didResume else {
            if let pendingValue {
                continuation.resume(returning: pendingValue)
            }
            return
        }

        self.continuation = continuation
    }

    func resume(returning value: Value) {
        guard !didResume else {
            return
        }

        didResume = true

        if let continuation {
            continuation.resume(returning: value)
            self.continuation = nil
        } else {
            pendingValue = value
        }
    }
}

@MainActor
@Observable
final class OnDeviceHangarItemTranslationService {
    static let shared = OnDeviceHangarItemTranslationService()

    private let directoryURL: URL
    private let cacheURL: URL
    private var cachedTranslations: [CacheKey: String] = [:]
    private var preprocessedLocales: Set<String> = []
    private var preprocessedTranslationKeys: Set<CacheKey> = []
    private var installedStatusByLocale: [String: TranslationModelInstallStatus] = [:]
    private var inFlightPreloadKeys: Set<CacheKey> = []
    private var inFlightOnDemandTranslationTasks: [CacheKey: Task<String?, Never>] = [:]
    private(set) var cacheGeneration = 0

    private static let cacheVersion = 1
    private static let batchSize = 16
    private static let concurrentSessionLimit = 2
    private static let modelAvailabilityTimeoutNanoseconds: UInt64 = 8_000_000_000

    init(
        fileManager: FileManager = .default,
        directoryURL: URL? = nil
    ) {
        let rootDirectoryURL = directoryURL ?? Self.defaultDirectoryURL(fileManager: fileManager)
        self.directoryURL = rootDirectoryURL
        cacheURL = rootDirectoryURL.appendingPathComponent("translations.json", isDirectory: false)
        let persistedCache = Self.loadPersistedCache(from: cacheURL)
        cachedTranslations = persistedCache.translations
        preprocessedLocales = persistedCache.preprocessedLocales
        preprocessedTranslationKeys = persistedCache.preprocessedTranslationKeys
    }

    func displayText(
        for source: String,
        using itemTranslator: HangarItemTranslator
    ) -> String {
        let trimmedSource = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedSource.isEmpty else {
            return source
        }

        let strictTranslation = itemTranslator.translated(trimmedSource)
        if strictTranslation != trimmedSource {
            return strictTranslation
        }

        guard itemTranslator.isEnabled,
              let targetLocale = itemTranslator.language.translationLocaleIdentifier else {
            return source
        }

        let cacheKey = CacheKey(
            source: trimmedSource,
            targetLocale: targetLocale,
            dictionaryVersion: itemTranslator.dictionary?.version
        )

        if let cachedTranslation = cachedTranslations[cacheKey] {
            return itemTranslator.normalizedMachineTranslationSpacing(
                cachedTranslation,
                source: trimmedSource
            )
        }

        let protectedTermTranslation = itemTranslator.replacingProtectedTerms(in: trimmedSource)
        return protectedTermTranslation == trimmedSource ? source : protectedTermTranslation
    }

    func onDemandDisplayText(
        for source: String,
        using itemTranslator: HangarItemTranslator
    ) async -> String {
        let trimmedSource = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedSource.isEmpty else {
            return source
        }

        let strictTranslation = itemTranslator.translated(trimmedSource)
        if strictTranslation != trimmedSource {
            return strictTranslation
        }

        guard itemTranslator.isEnabled,
              let targetLocale = itemTranslator.language.translationLocaleIdentifier else {
            return source
        }

        let cacheKey = CacheKey(
            source: trimmedSource,
            targetLocale: targetLocale,
            dictionaryVersion: itemTranslator.dictionary?.version
        )

        if let cachedTranslation = cachedTranslations[cacheKey] {
            return itemTranslator.normalizedMachineTranslationSpacing(
                cachedTranslation,
                source: trimmedSource
            )
        }

        let fallbackText = displayText(for: trimmedSource, using: itemTranslator)
        let modelStatus = await installedStatus(targetLocale: targetLocale)
        guard modelStatus.isInstalled else {
            return fallbackText
        }

        let translationTask: Task<String?, Never>
        let didCreateTranslationTask: Bool
        if let inFlightTask = inFlightOnDemandTranslationTasks[cacheKey] {
            translationTask = inFlightTask
            didCreateTranslationTask = false
        } else {
            let sourceLocale = "en"
            translationTask = Task.detached(priority: .utility) {
                await Self.translateSingleSource(
                    trimmedSource,
                    sourceLocale: sourceLocale,
                    targetLocale: targetLocale,
                    itemTranslator: itemTranslator
                )
            }
            inFlightOnDemandTranslationTasks[cacheKey] = translationTask
            didCreateTranslationTask = true
        }

        let translationResult = await translationTask.value
        if didCreateTranslationTask {
            inFlightOnDemandTranslationTasks[cacheKey] = nil
        }

        guard let translatedText = translationResult?.trimmingCharacters(in: .whitespacesAndNewlines),
              !translatedText.isEmpty,
              translatedText != trimmedSource else {
            return fallbackText
        }

        cachedTranslations[cacheKey] = translatedText
        persistCache()
        cacheGeneration &+= 1

        return itemTranslator.normalizedMachineTranslationSpacing(
            translatedText,
            source: trimmedSource
        )
    }

    func searchableText(
        for source: String,
        using itemTranslator: HangarItemTranslator
    ) -> String {
        let trimmedSource = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedSource.isEmpty else {
            return source
        }

        return [
            trimmedSource,
            itemTranslator.searchableText(for: trimmedSource),
            displayText(for: trimmedSource, using: itemTranslator)
        ]
        .joined(separator: " ")
    }

    func searchableText(
        for sources: [String],
        using itemTranslator: HangarItemTranslator
    ) -> String {
        sources
            .map { searchableText(for: $0, using: itemTranslator) }
            .joined(separator: " ")
    }

    func searchableText(
        forOptional source: String?,
        using itemTranslator: HangarItemTranslator
    ) -> String? {
        guard let source = source?.trimmingCharacters(in: .whitespacesAndNewlines),
              !source.isEmpty else {
            return nil
        }

        return searchableText(for: source, using: itemTranslator)
    }

    func fleetSearchableText(
        for ship: FleetShip,
        using itemTranslator: HangarItemTranslator
    ) -> String {
        [
            searchableText(for: ship.displayName, using: itemTranslator),
            searchableText(for: ship.manufacturer, using: itemTranslator),
            searchableText(
                for: FleetPresentationFormatter.manufacturerDisplayName(ship.manufacturer),
                using: itemTranslator
            ),
            searchableText(for: ship.role, using: itemTranslator),
            searchableText(for: ship.roleCategories, using: itemTranslator),
            ship.insurance,
            searchableText(for: ship.sourcePackageName, using: itemTranslator)
        ]
        .joined(separator: " ")
        .localizedLowercase
    }

    func buybackSearchableText(
        for pledge: BuybackPledge,
        using itemTranslator: HangarItemTranslator
    ) -> String {
        [
            searchableText(for: pledge.title, using: itemTranslator),
            pledge.displayedNotes,
            searchableText(forOptional: pledge.sourceRawInfo?.titleText, using: itemTranslator),
            pledge.sourceRawInfo?.containsText,
            pledge.sourceRawInfo?.articleText
        ]
        .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
        .joined(separator: " ")
        .localizedLowercase
    }

    func hangarLogSearchableText(
        for entry: HangarLogEntry,
        using itemTranslator: HangarItemTranslator
    ) -> String {
        [
            searchableText(for: entry.itemName, using: itemTranslator),
            entry.action.rawValue,
            entry.action.title,
            entry.operatorName,
            entry.orderCode,
            entry.sourcePledgeID,
            entry.targetPledgeID,
            searchableText(forOptional: entry.reason, using: itemTranslator),
            searchableText(forOptional: entry.upgradeContext?.sourceShipName, using: itemTranslator),
            searchableText(forOptional: entry.upgradeContext?.targetShipName, using: itemTranslator),
            searchableText(forOptional: entry.upgradeContext?.upgradeName, using: itemTranslator),
            entry.rawText,
            entry.occurredAt.formatted(date: .abbreviated, time: .shortened)
        ]
        .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
        .joined(separator: " ")
        .localizedLowercase
    }

    func allShipsCatalogSearchableText(
        name: String,
        manufacturer: String,
        priceText: String,
        storeAvailability: String?,
        inGameStatus: String?,
        aliases: [String],
        using itemTranslator: HangarItemTranslator
    ) -> String {
        [
            searchableText(for: [name] + aliases, using: itemTranslator),
            manufacturer,
            priceText,
            storeAvailability,
            inGameStatus
        ]
        .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
        .joined(separator: " ")
        .localizedLowercase
    }

    func hasAvailableCache(for language: HangarItemLanguage) -> Bool {
        guard let targetLocale = language.translationLocaleIdentifier else {
            return true
        }

        if preprocessedLocales.contains(targetLocale) {
            return true
        }

        return cachedTranslations.keys.contains { cacheKey in
            cacheKey.targetLocale == targetLocale
        }
    }

    func prepareTranslationModel(
        for language: HangarItemLanguage,
        logHandler: OnDeviceHangarItemTranslationPreloadLogHandler? = nil
    ) async -> Bool {
        guard let targetLocale = language.translationLocaleIdentifier else {
            return true
        }

        installedStatusByLocale.removeValue(forKey: targetLocale)
        let sourceLanguage = Locale.Language(identifier: "en")
        let targetLanguage = Locale.Language(identifier: targetLocale)
        let session = TranslationSession(installedSource: sourceLanguage, target: targetLanguage)

        do {
            logHandler?("Requesting Translation model download for en -> \(targetLocale).")
            try await session.prepareTranslation()
            installedStatusByLocale[targetLocale] = .installed
            logHandler?("Translation model is ready for en -> \(targetLocale).")
            return true
        } catch {
            installedStatusByLocale.removeValue(forKey: targetLocale)
            logHandler?("Translation model download did not complete: \(error.localizedDescription)")
            return false
        }
    }

    func preloadTranslations(
        for sources: [String],
        using itemTranslator: HangarItemTranslator,
        progressHandler: OnDeviceHangarItemTranslationPreloadProgressHandler? = nil,
        logHandler: OnDeviceHangarItemTranslationPreloadLogHandler? = nil
    ) async {
        guard itemTranslator.isEnabled,
              let targetLocale = itemTranslator.language.translationLocaleIdentifier else {
            logHandler?("Strict dictionary unavailable or locale mismatch; cannot start on-device preload.")
            progressHandler?(
                OnDeviceHangarItemTranslationPreloadProgress(
                    phase: .failed,
                    completedUnitCount: 0,
                    totalUnitCount: 0
                )
            )
            return
        }

        logHandler?("On-device preload service started. sources=\(sources.count), targetLocale=\(targetLocale).")
        logHandler?("Building pending machine translation source list off the main actor.")
        let pendingSources = await Self.detachedPendingPreloadSources(
            from: sources,
            targetLocale: targetLocale,
            itemTranslator: itemTranslator,
            cachedTranslationKeys: Set(cachedTranslations.keys),
            preprocessedTranslationKeys: preprocessedTranslationKeys,
            inFlightKeys: inFlightPreloadKeys
        )
        guard !Task.isCancelled else {
            logHandler?("Preload task cancelled after pending source discovery.")
            return
        }
        for pendingSource in pendingSources {
            inFlightPreloadKeys.insert(pendingSource.key)
        }
        logHandler?("Pending machine translation sources=\(pendingSources.count).")
        guard !pendingSources.isEmpty else {
            markLocalePreprocessed(targetLocale)
            logHandler?("No pending machine translation sources; marked locale as preprocessed.")
            progressHandler?(
                OnDeviceHangarItemTranslationPreloadProgress(
                    phase: .finished,
                    completedUnitCount: 0,
                    totalUnitCount: 0
                )
            )
            return
        }

        progressHandler?(
            OnDeviceHangarItemTranslationPreloadProgress(
                phase: .preparing,
                completedUnitCount: 0,
                totalUnitCount: pendingSources.count
            )
        )

        logHandler?("Checking installed Translation model for en -> \(targetLocale).")
        let modelStatus = await installedStatus(targetLocale: targetLocale)
        logHandler?("Translation model status=\(modelStatus).")
        guard !Task.isCancelled else {
            markPreloadFinished(for: pendingSources.map(\.key))
            logHandler?("Preload task cancelled after model availability check.")
            return
        }
        guard modelStatus.isInstalled else {
            markPreloadFinished(for: pendingSources.map(\.key))
            let phase: OnDeviceHangarItemTranslationPreloadProgress.Phase = modelStatus == .downloadRequired
                ? .downloadRequired
                : .unavailable
            progressHandler?(
                OnDeviceHangarItemTranslationPreloadProgress(
                    phase: phase,
                    completedUnitCount: 0,
                    totalUnitCount: pendingSources.count
                )
            )
            return
        }

        progressHandler?(
            OnDeviceHangarItemTranslationPreloadProgress(
                phase: .translating,
                completedUnitCount: 0,
                totalUnitCount: pendingSources.count
            )
        )

        var completedUnitCount = 0
        let batches = pendingSources.chunked(into: Self.batchSize)
        let maxConcurrentSessions = min(Self.concurrentSessionLimit, batches.count)
        logHandler?(
            "Running translation with \(maxConcurrentSessions) concurrent session\(maxConcurrentSessions == 1 ? "" : "s"). batches=\(batches.count)."
        )

        await withTaskGroup(of: TranslationBatchResult.self) { group in
            var nextBatchIndex = 0
            var didEncounterBatchFailure = false

            func enqueueNextBatchIfAvailable() {
                guard nextBatchIndex < batches.count else {
                    return
                }

                let batchIndex = nextBatchIndex
                let batch = batches[batchIndex]
                nextBatchIndex += 1

                group.addTask {
                    await Self.translateBatch(
                        batch,
                        batchIndex: batchIndex,
                        totalBatchCount: batches.count,
                        sourceLocale: "en",
                        targetLocale: targetLocale,
                        itemTranslator: itemTranslator
                    )
                }
            }

            for _ in 0 ..< maxConcurrentSessions {
                enqueueNextBatchIfAvailable()
            }

            while let batchResult = await group.next() {
                guard !Task.isCancelled else {
                    group.cancelAll()
                    markPreloadFinished(for: pendingSources.map(\.key))
                    logHandler?("Preload task cancelled while concurrent translation was running.")
                    return
                }

                for message in batchResult.logMessages {
                    logHandler?(message)
                }

                markPreloadFinished(for: batchResult.finishedKeys)
                if !batchResult.didFail {
                    markPreloadPreprocessed(for: batchResult.finishedKeys)
                }
                didEncounterBatchFailure = didEncounterBatchFailure || batchResult.didFail
                completedUnitCount += batchResult.processedCount

                if !batchResult.translations.isEmpty {
                    for (key, translation) in batchResult.translations {
                        cachedTranslations[key] = translation
                    }
                }
                if !batchResult.didFail || !batchResult.translations.isEmpty {
                    persistCache()
                    cacheGeneration &+= 1
                    logHandler?("Persisted translation cache after batch \(batchResult.batchNumber).")
                }

                let progressPhase: OnDeviceHangarItemTranslationPreloadProgress.Phase
                if completedUnitCount >= pendingSources.count {
                    progressPhase = didEncounterBatchFailure ? .failed : .finished
                } else {
                    progressPhase = .translating
                }

                progressHandler?(
                    OnDeviceHangarItemTranslationPreloadProgress(
                        phase: progressPhase,
                        completedUnitCount: completedUnitCount,
                        totalUnitCount: pendingSources.count
                    )
                )

                enqueueNextBatchIfAvailable()
            }

            if !Task.isCancelled, !didEncounterBatchFailure {
                markLocalePreprocessed(targetLocale)
                logHandler?("Marked locale \(targetLocale) as preprocessed.")
            }
        }
    }

    func clear() {
        for task in inFlightOnDemandTranslationTasks.values {
            task.cancel()
        }
        cachedTranslations.removeAll()
        preprocessedLocales.removeAll()
        preprocessedTranslationKeys.removeAll()
        installedStatusByLocale.removeAll()
        inFlightPreloadKeys.removeAll()
        inFlightOnDemandTranslationTasks.removeAll()
        cacheGeneration &+= 1
        try? FileManager.default.removeItem(at: directoryURL)
    }

    private func installedStatus(targetLocale: String) async -> TranslationModelInstallStatus {
        if let status = installedStatusByLocale[targetLocale] {
            return status
        }

        let status = await Self.detachedInstalledStatus(
            sourceLocale: "en",
            targetLocale: targetLocale,
            timeoutNanoseconds: Self.modelAvailabilityTimeoutNanoseconds
        )

        if status == .installed {
            installedStatusByLocale[targetLocale] = status
        }

        return status
    }

    private nonisolated static func detachedInstalledStatus(
        sourceLocale: String,
        targetLocale: String,
        timeoutNanoseconds: UInt64
    ) async -> TranslationModelInstallStatus {
        let result = OneShotAsyncResult<TranslationModelInstallStatus>()

        Task.detached(priority: .utility) {
            let availability = LanguageAvailability()
            let sourceLanguage = Locale.Language(identifier: sourceLocale)
            let targetLanguage = Locale.Language(identifier: targetLocale)
            let status = await availability.status(from: sourceLanguage, to: targetLanguage)
            let installStatus: TranslationModelInstallStatus
            switch status {
            case .installed:
                installStatus = .installed
            case .supported:
                installStatus = .downloadRequired
            case .unsupported:
                installStatus = .unavailable
            @unknown default:
                installStatus = .unavailable
            }
            await result.resume(returning: installStatus)
        }

        Task.detached(priority: .utility) {
            try? await Task.sleep(nanoseconds: timeoutNanoseconds)
            await result.resume(returning: .timedOut)
        }

        return await withCheckedContinuation { continuation in
            Task {
                await result.install(continuation)
            }
        }
    }

    private nonisolated static func detachedPendingPreloadSources(
        from sources: [String],
        targetLocale: String,
        itemTranslator: HangarItemTranslator,
        cachedTranslationKeys: Set<CacheKey>,
        preprocessedTranslationKeys: Set<CacheKey>,
        inFlightKeys: Set<CacheKey>
    ) async -> [PendingPreloadSource] {
        let worker = Task.detached(priority: .utility) {
            var seenSources = Set<String>()
            var pendingSources: [PendingPreloadSource] = []

            for source in sources {
                guard !Task.isCancelled else {
                    return pendingSources
                }

                let trimmedSource = source.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmedSource.isEmpty,
                      seenSources.insert(trimmedSource).inserted,
                      itemTranslator.translated(trimmedSource) == trimmedSource else {
                    continue
                }

                let key = CacheKey(
                    source: trimmedSource,
                    targetLocale: targetLocale,
                    dictionaryVersion: itemTranslator.dictionary?.version
                )

                guard !cachedTranslationKeys.contains(key),
                      !preprocessedTranslationKeys.contains(key),
                      !inFlightKeys.contains(key) else {
                    continue
                }

                pendingSources.append(
                    PendingPreloadSource(
                        identifier: "preload-\(pendingSources.count)",
                        source: trimmedSource,
                        key: key
                    )
                )
            }

            return pendingSources
        }

        return await withTaskCancellationHandler {
            await worker.value
        } onCancel: {
            worker.cancel()
        }
    }

    private nonisolated static func detachedPreparedPreloadSources(
        from pendingSources: [PendingPreloadSource],
        itemTranslator: HangarItemTranslator
    ) async -> [PreparedPreloadSource] {
        let worker = Task.detached(priority: .utility) {
            var preparedSources: [PreparedPreloadSource] = []
            preparedSources.reserveCapacity(pendingSources.count)

            for pendingSource in pendingSources {
                guard !Task.isCancelled else {
                    return preparedSources
                }

                preparedSources.append(
                    PreparedPreloadSource(
                        identifier: pendingSource.identifier,
                        source: pendingSource.source,
                        key: pendingSource.key,
                        maskedText: itemTranslator.maskedForMachineTranslation(pendingSource.source)
                    )
                )
            }

            return preparedSources
        }

        return await withTaskCancellationHandler {
            await worker.value
        } onCancel: {
            worker.cancel()
        }
    }

    private nonisolated static func translateBatch(
        _ batch: [PendingPreloadSource],
        batchIndex: Int,
        totalBatchCount: Int,
        sourceLocale: String,
        targetLocale: String,
        itemTranslator: HangarItemTranslator
    ) async -> TranslationBatchResult {
        let batchNumber = batchIndex + 1
        let finishedKeys = batch.map(\.key)
        var logMessages = [
            "Preparing batch \(batchNumber)/\(totalBatchCount). items=\(batch.count)."
        ]

        guard !Task.isCancelled else {
            logMessages.append("Batch \(batchNumber) cancelled before preparation.")
            return TranslationBatchResult(
                batchNumber: batchNumber,
                processedCount: 0,
                finishedKeys: [],
                translations: [:],
                logMessages: logMessages,
                didFail: true
            )
        }

        let preparedBatch = await detachedPreparedPreloadSources(
            from: batch,
            itemTranslator: itemTranslator
        )
        guard !Task.isCancelled else {
            logMessages.append("Batch \(batchNumber) cancelled while preparing masked source text.")
            return TranslationBatchResult(
                batchNumber: batchNumber,
                processedCount: 0,
                finishedKeys: [],
                translations: [:],
                logMessages: logMessages,
                didFail: true
            )
        }

        guard !preparedBatch.isEmpty else {
            logMessages.append("Batch \(batchNumber) had no prepared source text.")
            return TranslationBatchResult(
                batchNumber: batchNumber,
                processedCount: batch.count,
                finishedKeys: finishedKeys,
                translations: [:],
                logMessages: logMessages,
                didFail: false
            )
        }

        let sourceLanguage = Locale.Language(identifier: sourceLocale)
        let targetLanguage = Locale.Language(identifier: targetLocale)
        let session = TranslationSession(installedSource: sourceLanguage, target: targetLanguage)

        do {
            try await session.prepareTranslation()
            guard !Task.isCancelled else {
                logMessages.append("Batch \(batchNumber) cancelled after TranslationSession preparation.")
                return TranslationBatchResult(
                    batchNumber: batchNumber,
                    processedCount: 0,
                    finishedKeys: [],
                    translations: [:],
                    logMessages: logMessages,
                    didFail: true
                )
            }

            logMessages.append("Translating batch \(batchNumber)/\(totalBatchCount). items=\(preparedBatch.count).")
            let requests = preparedBatch.map {
                TranslationSession.Request(
                    sourceText: $0.maskedText.maskedText,
                    clientIdentifier: $0.identifier
                )
            }
            let pendingByIdentifier = Dictionary(uniqueKeysWithValues: preparedBatch.map { ($0.identifier, $0) })
            let responses = try await session.translations(from: requests)
            logMessages.append("Batch \(batchNumber) returned \(responses.count) responses.")

            var translations: [CacheKey: String] = [:]
            for response in responses {
                guard let identifier = response.clientIdentifier,
                      let pending = pendingByIdentifier[identifier] else {
                    continue
                }

                let restoredTranslation = pending.maskedText
                    .restoringTerms(in: response.targetText)
                    .trimmingCharacters(in: .whitespacesAndNewlines)

                guard !restoredTranslation.isEmpty,
                      restoredTranslation != pending.source else {
                    continue
                }

                translations[pending.key] = restoredTranslation
            }

            return TranslationBatchResult(
                batchNumber: batchNumber,
                processedCount: batch.count,
                finishedKeys: finishedKeys,
                translations: translations,
                logMessages: logMessages,
                didFail: false
            )
        } catch {
            logMessages.append("Batch \(batchNumber) failed: \(error.localizedDescription)")
            return TranslationBatchResult(
                batchNumber: batchNumber,
                processedCount: batch.count,
                finishedKeys: finishedKeys,
                translations: [:],
                logMessages: logMessages,
                didFail: true
            )
        }
    }

    private nonisolated static func translateSingleSource(
        _ source: String,
        sourceLocale: String,
        targetLocale: String,
        itemTranslator: HangarItemTranslator
    ) async -> String? {
        guard !Task.isCancelled else {
            return nil
        }

        let maskedText = itemTranslator.maskedForMachineTranslation(source)
        let sourceLanguage = Locale.Language(identifier: sourceLocale)
        let targetLanguage = Locale.Language(identifier: targetLocale)
        let session = TranslationSession(installedSource: sourceLanguage, target: targetLanguage)

        do {
            try await session.prepareTranslation()
            guard !Task.isCancelled else {
                return nil
            }

            let requests = [
                TranslationSession.Request(
                    sourceText: maskedText.maskedText,
                    clientIdentifier: "on-demand"
                )
            ]
            guard let response = try await session.translations(from: requests).first else {
                return nil
            }

            let restoredTranslation = maskedText
                .restoringTerms(in: response.targetText)
                .trimmingCharacters(in: .whitespacesAndNewlines)

            guard !restoredTranslation.isEmpty else {
                return nil
            }

            return restoredTranslation
        } catch {
            return nil
        }
    }

    private func markPreloadFinished(for keys: [CacheKey]) {
        for key in keys {
            inFlightPreloadKeys.remove(key)
        }
    }

    private func markPreloadPreprocessed(for keys: [CacheKey]) {
        for key in keys {
            preprocessedTranslationKeys.insert(key)
        }
    }

    private func markLocalePreprocessed(_ targetLocale: String) {
        guard preprocessedLocales.insert(targetLocale).inserted else {
            return
        }

        persistCache()
        cacheGeneration &+= 1
    }

    private func persistCache() {
        do {
            try FileManager.default.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true
            )
            let payload = PersistedTranslationCache(
                version: Self.cacheVersion,
                preprocessedLocales: Array(preprocessedLocales).sorted(),
                preprocessedEntries: preprocessedTranslationKeys.map { key in
                    PersistedTranslationCache.ProcessedEntry(
                        source: key.source,
                        targetLocale: key.targetLocale,
                        dictionaryVersion: key.dictionaryVersion
                    )
                },
                entries: cachedTranslations.map { key, translation in
                    PersistedTranslationCache.Entry(
                        source: key.source,
                        targetLocale: key.targetLocale,
                        dictionaryVersion: key.dictionaryVersion,
                        translation: translation
                    )
                }
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(payload)
            try data.write(to: cacheURL, options: [.atomic])
        } catch {
#if DEBUG
            print("OnDeviceHangarItemTranslationService failed to persist cache: \(error)")
#endif
        }
    }

    private static func loadPersistedCache(from cacheURL: URL) -> PersistedTranslationCacheState {
        guard let data = try? Data(contentsOf: cacheURL),
              let payload = try? JSONDecoder().decode(PersistedTranslationCache.self, from: data),
              payload.version == cacheVersion else {
            return PersistedTranslationCacheState(
                translations: [:],
                preprocessedLocales: [],
                preprocessedTranslationKeys: []
            )
        }

        var cache: [CacheKey: String] = [:]
        for entry in payload.entries {
            let source = entry.source.trimmingCharacters(in: .whitespacesAndNewlines)
            let translation = entry.translation.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !source.isEmpty, !translation.isEmpty else {
                continue
            }

            cache[
                CacheKey(
                    source: source,
                    targetLocale: entry.targetLocale,
                    dictionaryVersion: entry.dictionaryVersion
                )
            ] = translation
        }

        var preprocessedKeys = Set<CacheKey>()
        for entry in payload.preprocessedEntries ?? [] {
            let source = entry.source.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !source.isEmpty else {
                continue
            }

            preprocessedKeys.insert(
                CacheKey(
                    source: source,
                    targetLocale: entry.targetLocale,
                    dictionaryVersion: entry.dictionaryVersion
                )
            )
        }

        return PersistedTranslationCacheState(
            translations: cache,
            preprocessedLocales: Set(payload.preprocessedLocales ?? []),
            preprocessedTranslationKeys: preprocessedKeys
        )
    }

    private static func defaultDirectoryURL(fileManager: FileManager) -> URL {
        let appSupportURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory

        return appSupportURL
            .appendingPathComponent("HangerExpress", isDirectory: true)
            .appendingPathComponent("OnDeviceItemTranslations", isDirectory: true)
    }
}

private nonisolated struct CacheKey: Hashable, Sendable {
    let source: String
    let targetLocale: String
    let dictionaryVersion: Int?
}

private nonisolated struct PendingPreloadSource: Sendable {
    let identifier: String
    let source: String
    let key: CacheKey
}

private nonisolated struct PreparedPreloadSource: Sendable {
    let identifier: String
    let source: String
    let key: CacheKey
    let maskedText: MaskedHangarItemText
}

private nonisolated struct TranslationBatchResult: Sendable {
    let batchNumber: Int
    let processedCount: Int
    let finishedKeys: [CacheKey]
    let translations: [CacheKey: String]
    let logMessages: [String]
    let didFail: Bool
}

private struct PersistedTranslationCache: Codable {
    struct Entry: Codable {
        let source: String
        let targetLocale: String
        let dictionaryVersion: Int?
        let translation: String
    }

    struct ProcessedEntry: Codable {
        let source: String
        let targetLocale: String
        let dictionaryVersion: Int?
    }

    let version: Int
    let preprocessedLocales: [String]?
    let preprocessedEntries: [ProcessedEntry]?
    let entries: [Entry]
}

private struct PersistedTranslationCacheState {
    let translations: [CacheKey: String]
    let preprocessedLocales: Set<String>
    let preprocessedTranslationKeys: Set<CacheKey>
}

private extension Array {
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0, !isEmpty else {
            return []
        }

        return stride(from: 0, to: count, by: size).map { startIndex in
            Array(self[startIndex ..< Swift.min(startIndex + size, count)])
        }
    }
}
