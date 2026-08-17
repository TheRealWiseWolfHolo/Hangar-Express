import Foundation

nonisolated enum RemoteHangarItemTranslationRollout {
    // Cloud submission is opt-in from Settings. Existing and invalid
    // preferences continue to resolve to the on-device mode.
    static let isEnabled = true
}

nonisolated enum HangarItemTranslationMissMode: String, CaseIterable, Sendable {
    case onDevice
    case cloudReview

    static let storageKey = "hangar.itemTranslation.missMode"

    static func resolved(
        from rawValue: String,
        rolloutEnabled: Bool = RemoteHangarItemTranslationRollout.isEnabled
    ) -> Self {
        guard rolloutEnabled else {
            return .onDevice
        }
        return Self(rawValue: rawValue) ?? .onDevice
    }
}

nonisolated enum HangarItemTranslationMethodPromptPolicy {
    static func shouldPrompt(
        for language: HangarItemLanguage,
        rolloutEnabled: Bool = RemoteHangarItemTranslationRollout.isEnabled
    ) -> Bool {
        rolloutEnabled && language.translationLocaleIdentifier != nil
    }

    static func shouldPromptAfterUpgrade(
        rolloutEnabled: Bool = RemoteHangarItemTranslationRollout.isEnabled
    ) -> Bool {
        rolloutEnabled
    }
}

nonisolated enum HangarItemTranslationBackgroundRefreshPolicy {
    static func shouldRefresh(for language: HangarItemLanguage) -> Bool {
        language.translationLocaleIdentifier != nil
    }
}

nonisolated enum RemoteHangarItemTranslationKind: String, Codable, CaseIterable, Sendable {
    case insurance
    case item
    case manufacturer
    case package
    case paint
    case role
    case ship
    case upgrade
}

nonisolated struct RemoteHangarItemTranslationCandidate: Hashable, Sendable {
    private static let couponCodeExpression = try? NSRegularExpression(
        pattern: #"\b([0-9]{1,3}\s*%\s*Coupon)\s*[:：]"#,
        options: [.caseInsensitive]
    )

    let source: String
    let kind: RemoteHangarItemTranslationKind

    init?(source: String, kind: RemoteHangarItemTranslationKind) {
        let remoteSafeSource = Self.removingCouponCode(from: source)
        let containsControlCharacter = remoteSafeSource.unicodeScalars.contains {
            ($0.value <= 0x1F && $0.value != 0x09) || $0.value == 0x7F
        }
        guard !containsControlCharacter,
              !remoteSafeSource.contains("\n"),
              !remoteSafeSource.contains("\r"),
              remoteSafeSource.range(
                  of: #"\b\S+@\S+\.\S+\b"#,
                  options: [.regularExpression, .caseInsensitive]
              ) == nil,
              remoteSafeSource.range(
                  of: #"\b(?:https?://|www\.)\S+"#,
                  options: [.regularExpression, .caseInsensitive]
              ) == nil else {
            return nil
        }
        let normalizedSource = remoteSafeSource
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard !normalizedSource.isEmpty, normalizedSource.count <= 160 else {
            return nil
        }

        self.source = normalizedSource
        self.kind = kind
    }

    private static func removingCouponCode(from source: String) -> String {
        let fullRange = NSRange(source.startIndex ..< source.endIndex, in: source)
        guard let match = couponCodeExpression?.firstMatch(
            in: source,
            range: fullRange
        ),
              let couponRange = Range(match.range(at: 1), in: source) else {
            return source
        }

        return String(source[..<couponRange.upperBound])
    }

    var clientID: String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in "\(kind.rawValue)\n\(normalizedLookupKey)".utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 1_099_511_628_211
        }
        return "\(kind.rawValue)-\(String(hash, radix: 16))"
    }

    fileprivate var normalizedLookupKey: String {
        HangarItemTranslationDictionary.normalizedLookupKey(source)
    }
}

nonisolated enum RemoteHangarItemTranslationSuggestionClassifier {
    static func candidates(
        from snapshot: HangarSnapshot,
        excluding dictionary: HangarItemTranslationDictionary? = nil
    ) -> [RemoteHangarItemTranslationCandidate] {
        var candidates: [RemoteHangarItemTranslationCandidate] = []
        var occupiedKeys = Set<String>()

        func add(_ source: String?, kind: RemoteHangarItemTranslationKind) {
            guard let source,
                  let candidate = RemoteHangarItemTranslationCandidate(
                      source: source,
                      kind: kind
                  ),
                  dictionary?.translation(for: candidate.source) == nil else {
                return
            }
            let key = "\(candidate.kind.rawValue)\n\(candidate.normalizedLookupKey)"
            guard occupiedKeys.insert(key).inserted else {
                return
            }
            candidates.append(candidate)
        }

        for package in snapshot.packages {
            add(package.title, kind: .package)
            add(package.insurance, kind: .insurance)
            for insuranceOption in package.insuranceOptions ?? [] {
                add(insuranceOption, kind: .insurance)
            }

            for item in package.contents {
                let kind: RemoteHangarItemTranslationKind
                switch item.category {
                case .ship, .vehicle:
                    kind = .ship
                case .gamePackage:
                    kind = .package
                case .upgrade:
                    kind = .upgrade
                case .flair, .perk:
                    kind = .item
                }
                add(item.title, kind: kind)

                if let pricing = item.upgradePricing {
                    add(pricing.sourceShipName, kind: .ship)
                    add(pricing.targetShipName, kind: .ship)
                }
            }
        }

        for ship in snapshot.fleet {
            add(ship.displayName, kind: .ship)
            add(ship.manufacturer, kind: .manufacturer)
            add(
                FleetPresentationFormatter.manufacturerDisplayName(ship.manufacturer),
                kind: .manufacturer
            )
            add(ship.role, kind: .role)
            for roleCategory in ship.roleCategories {
                add(roleCategory, kind: .role)
            }
            add(ship.insurance, kind: .insurance)
            add(ship.sourcePackageName, kind: .package)
        }

        return candidates
    }
}

nonisolated struct RemoteHangarItemTranslationResult: Equatable, Sendable {
    enum Status: String, Decodable, Sendable {
        case approved
        case pending
        case rejected
        case ineligible
        case unavailable
    }

    let candidate: RemoteHangarItemTranslationCandidate
    let status: Status
    let reason: String?
}

nonisolated struct RemoteHangarItemTranslationUploadProgress: Equatable, Sendable {
    let completedCount: Int
    let totalCount: Int

    var fractionComplete: Double {
        guard totalCount > 0 else {
            return 0
        }
        return Double(min(max(completedCount, 0), totalCount)) / Double(totalCount)
    }
}

nonisolated enum RemoteHangarItemTranslationClientError: Error, Equatable {
    case missingConfiguration
    case invalidResponse
    case httpStatus(Int)
}

nonisolated struct RemoteHangarItemTranslationClient: Sendable {
    static let maximumServerBatchSize = 50
    static let maximumConcurrentUploads = 4

    let baseURL: URL?
    let urlSession: URLSession
    let maximumBatchSize: Int

    init(
        baseURL: URL? = RemoteServiceConfiguration.live.translationBaseURL,
        urlSession: URLSession = .shared,
        maximumBatchSize: Int = Self.maximumServerBatchSize
    ) {
        self.baseURL = baseURL
        self.urlSession = urlSession
        self.maximumBatchSize = min(
            max(maximumBatchSize, 1),
            Self.maximumServerBatchSize
        )
    }

    func submit(
        _ candidates: [RemoteHangarItemTranslationCandidate],
        dictionaryVersion: Int?,
        batchHandler: (
            @Sendable (
                [RemoteHangarItemTranslationResult],
                RemoteHangarItemTranslationUploadProgress
            ) async -> Void
        )? = nil
    ) async throws -> [RemoteHangarItemTranslationResult] {
        let uniqueCandidates = Self.deduplicated(candidates)
        let batches = stride(
            from: 0,
            to: uniqueCandidates.count,
            by: maximumBatchSize
        ).map { batchStart in
            let batchEnd = min(
                batchStart + maximumBatchSize,
                uniqueCandidates.count
            )
            return Array(uniqueCandidates[batchStart ..< batchEnd])
        }
        guard !batches.isEmpty else {
            return []
        }

        var orderedResults = Array<[RemoteHangarItemTranslationResult]?>(
            repeating: nil,
            count: batches.count
        )
        var completedCount = 0
        try await withThrowingTaskGroup(
            of: (Int, [RemoteHangarItemTranslationResult]).self
        ) { group in
            var nextBatchIndex = 0
            let initialUploadCount = min(
                Self.maximumConcurrentUploads,
                batches.count
            )
            for batchIndex in 0 ..< initialUploadCount {
                group.addTask { [self] in
                    (
                        batchIndex,
                        try await submitBatch(
                            batches[batchIndex],
                            dictionaryVersion: dictionaryVersion
                        )
                    )
                }
                nextBatchIndex += 1
            }

            while let (batchIndex, batchResults) = try await group.next() {
                orderedResults[batchIndex] = batchResults
                completedCount += batchResults.count
                await batchHandler?(
                    batchResults,
                    RemoteHangarItemTranslationUploadProgress(
                        completedCount: completedCount,
                        totalCount: uniqueCandidates.count
                    )
                )
                if nextBatchIndex < batches.count {
                    let batchIndex = nextBatchIndex
                    group.addTask { [self] in
                        (
                            batchIndex,
                            try await submitBatch(
                                batches[batchIndex],
                                dictionaryVersion: dictionaryVersion
                            )
                        )
                    }
                    nextBatchIndex += 1
                }
            }
        }
        return orderedResults.compactMap { $0 }.flatMap { $0 }
    }

    private func submitBatch(
        _ candidates: [RemoteHangarItemTranslationCandidate],
        dictionaryVersion: Int?
    ) async throws -> [RemoteHangarItemTranslationResult] {
        guard !candidates.isEmpty else {
            return []
        }

        let request = try resolveRequest(
            for: candidates,
            dictionaryVersion: dictionaryVersion
        )
        let (data, response) = try await urlSession.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw RemoteHangarItemTranslationClientError.invalidResponse
        }
        guard (200 ..< 300).contains(httpResponse.statusCode) else {
            throw RemoteHangarItemTranslationClientError.httpStatus(
                httpResponse.statusCode
            )
        }

        let payload: ResolveResponse
        do {
            payload = try JSONDecoder().decode(ResolveResponse.self, from: data)
        } catch {
            throw RemoteHangarItemTranslationClientError.invalidResponse
        }
        let candidatesByID = Dictionary(
            uniqueKeysWithValues: candidates.map { ($0.clientID, $0) }
        )
        guard payload.translations.count == candidates.count,
              Set(payload.translations.map(\.clientID)).count == candidates.count else {
            throw RemoteHangarItemTranslationClientError.invalidResponse
        }

        return try payload.translations.map { result in
            guard let candidate = candidatesByID[result.clientID],
                  result.source == candidate.source else {
                throw RemoteHangarItemTranslationClientError.invalidResponse
            }
            return RemoteHangarItemTranslationResult(
                candidate: candidate,
                status: result.status,
                reason: result.reason
            )
        }
    }

    func resolveRequest(
        for candidates: [RemoteHangarItemTranslationCandidate],
        dictionaryVersion: Int?
    ) throws -> URLRequest {
        guard let baseURL else {
            throw RemoteHangarItemTranslationClientError.missingConfiguration
        }
        let endpoint = baseURL
            .appendingPathComponent("v1")
            .appendingPathComponent("translations")
            .appendingPathComponent("resolve")
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 30
        request.allowsConstrainedNetworkAccess = false
        request.allowsExpensiveNetworkAccess = false
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue("application/json", forHTTPHeaderField: "accept")
        request.httpBody = try JSONEncoder().encode(
            ResolveRequest(
                sourceLocale: "en",
                targetLocale: "zh-Hans",
                dictionaryVersion: dictionaryVersion.flatMap {
                    $0 > 0 ? $0 : nil
                },
                items: candidates.map {
                    ResolveRequest.Item(
                        clientID: $0.clientID,
                        source: $0.source,
                        kind: $0.kind
                    )
                }
            )
        )
        return request
    }

    private static func deduplicated(
        _ candidates: [RemoteHangarItemTranslationCandidate]
    ) -> [RemoteHangarItemTranslationCandidate] {
        var unique: [RemoteHangarItemTranslationCandidate] = []
        var occupiedIDs = Set<String>()
        for candidate in candidates where occupiedIDs.insert(candidate.clientID).inserted {
            unique.append(candidate)
        }
        return unique
    }

    private struct ResolveRequest: Encodable {
        struct Item: Encodable {
            let clientID: String
            let source: String
            let kind: RemoteHangarItemTranslationKind
        }

        let sourceLocale: String
        let targetLocale: String
        let dictionaryVersion: Int?
        let items: [Item]
    }

    private struct ResolveResponse: Decodable {
        struct Result: Decodable {
            let clientID: String
            let source: String
            let status: RemoteHangarItemTranslationResult.Status
            let reason: String?
        }

        let translations: [Result]
    }
}

nonisolated enum RemoteHangarItemTranslationSubmissionOutcome: Equatable, Sendable {
    case disabled
    case dictionaryUnavailable
    case noEligibleCandidates
    case alreadySubmitted
    case submitted(Int)
    case unavailable(Int)
}

actor RemoteHangarItemTranslationSubmissionStore {
    static let shared = RemoteHangarItemTranslationSubmissionStore()

    private var state: RemoteHangarItemTranslationSubmissionState
    private var isSubmitting = false
    private let fileManager: FileManager
    private let directoryURL: URL

    init(
        fileManager: FileManager = .default,
        directoryURL: URL? = nil
    ) {
        self.fileManager = fileManager
        self.directoryURL = directoryURL ?? Self.defaultDirectoryURL(
            fileManager: fileManager
        )
        let stateURL = self.directoryURL.appendingPathComponent(
            "submission-state.json",
            isDirectory: false
        )
        if let data = try? Data(contentsOf: stateURL),
           let decoded = try? JSONDecoder().decode(
               RemoteHangarItemTranslationSubmissionState.self,
               from: data
           ) {
            state = decoded
        } else {
            state = RemoteHangarItemTranslationSubmissionState()
        }
    }

    func submitSuggestions(
        for snapshot: HangarSnapshot,
        excluding dictionary: HangarItemTranslationDictionary?,
        mode: HangarItemTranslationMissMode,
        client: RemoteHangarItemTranslationClient = RemoteHangarItemTranslationClient(),
        now: Date = .now,
        rolloutEnabled: Bool = RemoteHangarItemTranslationRollout.isEnabled,
        progressHandler: (
            @MainActor @Sendable (RemoteHangarItemTranslationUploadProgress) -> Void
        )? = nil
    ) async -> RemoteHangarItemTranslationSubmissionOutcome {
        guard rolloutEnabled, mode == .cloudReview else {
            return .disabled
        }
        guard let dictionary, dictionary.version > 0 else {
            return .dictionaryUnavailable
        }
        guard !isSubmitting else {
            return .alreadySubmitted
        }

        let candidates = RemoteHangarItemTranslationSuggestionClassifier.candidates(
            from: snapshot,
            excluding: dictionary
        )
        guard !candidates.isEmpty else {
            return .noEligibleCandidates
        }
        let pendingCandidates = candidates.filter {
            state.shouldSubmit(
                $0,
                dictionaryVersion: dictionary.version,
                now: now
            )
        }
        guard !pendingCandidates.isEmpty else {
            return .alreadySubmitted
        }

        isSubmitting = true
        defer { isSubmitting = false }

        await progressHandler?(
            RemoteHangarItemTranslationUploadProgress(
                completedCount: 0,
                totalCount: pendingCandidates.count
            )
        )

        do {
            let results = try await client.submit(
                pendingCandidates,
                dictionaryVersion: dictionary.version,
                batchHandler: { [weak self] batchResults, progress in
                    await self?.recordCompletedBatch(
                        batchResults,
                        dictionaryVersion: dictionary.version,
                        now: now
                    )
                    await progressHandler?(progress)
                }
            )
            return .submitted(results.count)
        } catch {
            let retryCandidates = pendingCandidates.filter {
                state.shouldSubmit(
                    $0,
                    dictionaryVersion: dictionary.version,
                    now: now
                )
            }
            for candidate in retryCandidates {
                state.record(
                    RemoteHangarItemTranslationResult(
                        candidate: candidate,
                        status: .unavailable,
                        reason: nil
                    ),
                    dictionaryVersion: dictionary.version,
                    now: now
                )
            }
            saveState()
            return .unavailable(retryCandidates.count)
        }
    }

    private func recordCompletedBatch(
        _ results: [RemoteHangarItemTranslationResult],
        dictionaryVersion: Int,
        now: Date
    ) {
        for result in results {
            state.record(
                result,
                dictionaryVersion: dictionaryVersion,
                now: now
            )
        }
        saveState()
    }

    private func saveState() {
        do {
            try fileManager.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(state)
            try data.write(
                to: directoryURL.appendingPathComponent(
                    "submission-state.json",
                    isDirectory: false
                ),
                options: [.atomic]
            )
        } catch {
#if DEBUG
            print(
                "RemoteHangarItemTranslationSubmissionStore failed to save state: \(error)"
            )
#endif
        }
    }

    private static func defaultDirectoryURL(
        fileManager: FileManager
    ) -> URL {
        let appSupportURL = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? fileManager.temporaryDirectory
        return appSupportURL
            .appendingPathComponent("HangerExpress", isDirectory: true)
            .appendingPathComponent(
                "RemoteItemTranslationSuggestions",
                isDirectory: true
            )
    }
}

nonisolated struct RemoteHangarItemTranslationSubmissionState: Codable, Equatable, Sendable {
    private struct Record: Codable, Equatable, Sendable {
        var dictionaryVersion: Int
        var retryCount: Int
        var retryAfter: Date?
        var terminalForVersion: Bool
    }

    private var records: [String: Record] = [:]

    mutating func record(
        _ result: RemoteHangarItemTranslationResult,
        dictionaryVersion: Int,
        now: Date
    ) {
        switch result.status {
        case .approved, .pending, .rejected, .ineligible:
            records[result.candidate.clientID] = Record(
                dictionaryVersion: dictionaryVersion,
                retryCount: 0,
                retryAfter: nil,
                terminalForVersion: true
            )
        case .unavailable:
            let previous = records[result.candidate.clientID]
            let retryCount = previous?.dictionaryVersion == dictionaryVersion
                ? previous!.retryCount + 1
                : 1
            records[result.candidate.clientID] = Record(
                dictionaryVersion: dictionaryVersion,
                retryCount: retryCount,
                retryAfter: Self.retryDate(
                    afterFailure: retryCount,
                    now: now
                ),
                terminalForVersion: false
            )
        }
    }

    func shouldSubmit(
        _ candidate: RemoteHangarItemTranslationCandidate,
        dictionaryVersion: Int,
        now: Date
    ) -> Bool {
        guard let record = records[candidate.clientID],
              record.dictionaryVersion == dictionaryVersion else {
            return true
        }
        if record.terminalForVersion {
            return false
        }
        return record.retryAfter.map { $0 <= now } ?? true
    }

    private static func retryDate(afterFailure retryCount: Int, now: Date) -> Date {
        switch retryCount {
        case 1:
            return now.addingTimeInterval(60 * 60)
        case 2:
            return now.addingTimeInterval(6 * 60 * 60)
        default:
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(secondsFromGMT: 0)!
            let nextDay = calendar.date(byAdding: .day, value: 1, to: now) ?? now
            return calendar.startOfDay(for: nextDay)
        }
    }
}
