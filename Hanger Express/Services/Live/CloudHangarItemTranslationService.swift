import Foundation

nonisolated enum CloudHangarItemTranslationRollout {
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
        rolloutEnabled: Bool = CloudHangarItemTranslationRollout.isEnabled
    ) -> Self {
        guard rolloutEnabled else {
            return .onDevice
        }
        return Self(rawValue: rawValue) ?? .onDevice
    }
}

nonisolated enum CloudHangarItemTranslationKind: String, Codable, CaseIterable, Sendable {
    case insurance
    case item
    case manufacturer
    case package
    case paint
    case role
    case ship
    case upgrade
}

nonisolated struct CloudHangarItemTranslationCandidate: Hashable, Sendable {
    let source: String
    let kind: CloudHangarItemTranslationKind

    init?(source: String, kind: CloudHangarItemTranslationKind) {
        let containsControlCharacter = source.unicodeScalars.contains {
            ($0.value <= 0x1F && $0.value != 0x09) || $0.value == 0x7F
        }
        guard !containsControlCharacter,
              !source.contains("\n"),
              !source.contains("\r"),
              source.range(
                  of: #"\b\S+@\S+\.\S+\b"#,
                  options: [.regularExpression, .caseInsensitive]
              ) == nil,
              source.range(
                  of: #"\b(?:https?://|www\.)\S+"#,
                  options: [.regularExpression, .caseInsensitive]
              ) == nil else {
            return nil
        }
        let normalizedSource = source
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

nonisolated enum CloudHangarItemTranslationSuggestionClassifier {
    static func candidates(
        from snapshot: HangarSnapshot,
        excluding dictionary: HangarItemTranslationDictionary? = nil
    ) -> [CloudHangarItemTranslationCandidate] {
        var candidates: [CloudHangarItemTranslationCandidate] = []
        var occupiedKeys = Set<String>()

        func add(_ source: String?, kind: CloudHangarItemTranslationKind) {
            guard let source,
                  dictionary?.translation(for: source) == nil,
                  let candidate = CloudHangarItemTranslationCandidate(
                      source: source,
                      kind: kind
                  ) else {
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
                let kind: CloudHangarItemTranslationKind
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

nonisolated struct CloudHangarItemTranslationResult: Equatable, Sendable {
    enum Status: String, Decodable, Sendable {
        case approved
        case pending
        case rejected
        case ineligible
        case unavailable
    }

    let candidate: CloudHangarItemTranslationCandidate
    let status: Status
    let reason: String?
}

nonisolated enum CloudHangarItemTranslationClientError: Error, Equatable {
    case invalidResponse
    case httpStatus(Int)
}

nonisolated struct CloudHangarItemTranslationClient: Sendable {
    static let maximumServerBatchSize = 6
    static let productionBaseURL = URL(
        string: "https://hangar-express-translations.liuchen2004.remote.example.invalid"
    )!

    let baseURL: URL
    let urlSession: URLSession
    let maximumBatchSize: Int

    init(
        baseURL: URL = Self.productionBaseURL,
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
        _ candidates: [CloudHangarItemTranslationCandidate],
        dictionaryVersion: Int?
    ) async throws -> [CloudHangarItemTranslationResult] {
        let uniqueCandidates = Self.deduplicated(candidates)
        var results: [CloudHangarItemTranslationResult] = []
        results.reserveCapacity(uniqueCandidates.count)

        for batchStart in stride(
            from: 0,
            to: uniqueCandidates.count,
            by: maximumBatchSize
        ) {
            let batchEnd = min(batchStart + maximumBatchSize, uniqueCandidates.count)
            results.append(
                contentsOf: try await submitBatch(
                    Array(uniqueCandidates[batchStart ..< batchEnd]),
                    dictionaryVersion: dictionaryVersion
                )
            )
        }
        return results
    }

    private func submitBatch(
        _ candidates: [CloudHangarItemTranslationCandidate],
        dictionaryVersion: Int?
    ) async throws -> [CloudHangarItemTranslationResult] {
        guard !candidates.isEmpty else {
            return []
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

        let (data, response) = try await urlSession.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw CloudHangarItemTranslationClientError.invalidResponse
        }
        guard (200 ..< 300).contains(httpResponse.statusCode) else {
            throw CloudHangarItemTranslationClientError.httpStatus(
                httpResponse.statusCode
            )
        }

        let payload: ResolveResponse
        do {
            payload = try JSONDecoder().decode(ResolveResponse.self, from: data)
        } catch {
            throw CloudHangarItemTranslationClientError.invalidResponse
        }
        let candidatesByID = Dictionary(
            uniqueKeysWithValues: candidates.map { ($0.clientID, $0) }
        )
        guard payload.translations.count == candidates.count,
              Set(payload.translations.map(\.clientID)).count == candidates.count else {
            throw CloudHangarItemTranslationClientError.invalidResponse
        }

        return try payload.translations.map { result in
            guard let candidate = candidatesByID[result.clientID],
                  result.source == candidate.source else {
                throw CloudHangarItemTranslationClientError.invalidResponse
            }
            return CloudHangarItemTranslationResult(
                candidate: candidate,
                status: result.status,
                reason: result.reason
            )
        }
    }

    private static func deduplicated(
        _ candidates: [CloudHangarItemTranslationCandidate]
    ) -> [CloudHangarItemTranslationCandidate] {
        var unique: [CloudHangarItemTranslationCandidate] = []
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
            let kind: CloudHangarItemTranslationKind
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
            let status: CloudHangarItemTranslationResult.Status
            let reason: String?
        }

        let translations: [Result]
    }
}

nonisolated enum CloudHangarItemTranslationSubmissionOutcome: Equatable, Sendable {
    case disabled
    case dictionaryUnavailable
    case noEligibleCandidates
    case alreadySubmitted
    case submitted(Int)
    case unavailable(Int)
}

actor CloudHangarItemTranslationSubmissionStore {
    static let shared = CloudHangarItemTranslationSubmissionStore()

    private var state: CloudHangarItemTranslationSubmissionState
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
               CloudHangarItemTranslationSubmissionState.self,
               from: data
           ) {
            state = decoded
        } else {
            state = CloudHangarItemTranslationSubmissionState()
        }
    }

    func submitSuggestions(
        for snapshot: HangarSnapshot,
        excluding dictionary: HangarItemTranslationDictionary?,
        mode: HangarItemTranslationMissMode,
        client: CloudHangarItemTranslationClient = CloudHangarItemTranslationClient(),
        now: Date = .now,
        rolloutEnabled: Bool = CloudHangarItemTranslationRollout.isEnabled
    ) async -> CloudHangarItemTranslationSubmissionOutcome {
        guard rolloutEnabled, mode == .cloudReview else {
            return .disabled
        }
        guard let dictionary, dictionary.version > 0 else {
            return .dictionaryUnavailable
        }
        guard !isSubmitting else {
            return .alreadySubmitted
        }

        let candidates = CloudHangarItemTranslationSuggestionClassifier.candidates(
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

        do {
            let results = try await client.submit(
                pendingCandidates,
                dictionaryVersion: dictionary.version
            )
            for result in results {
                state.record(
                    result,
                    dictionaryVersion: dictionary.version,
                    now: now
                )
            }
            saveState()
            return .submitted(results.count)
        } catch {
            for candidate in pendingCandidates {
                state.record(
                    CloudHangarItemTranslationResult(
                        candidate: candidate,
                        status: .unavailable,
                        reason: nil
                    ),
                    dictionaryVersion: dictionary.version,
                    now: now
                )
            }
            saveState()
            return .unavailable(pendingCandidates.count)
        }
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
                "CloudHangarItemTranslationSubmissionStore failed to save state: \(error)"
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
                "CloudItemTranslationSuggestions",
                isDirectory: true
            )
    }
}

nonisolated struct CloudHangarItemTranslationSubmissionState: Codable, Equatable, Sendable {
    private struct Record: Codable, Equatable, Sendable {
        var dictionaryVersion: Int
        var retryCount: Int
        var retryAfter: Date?
        var terminalForVersion: Bool
    }

    private var records: [String: Record] = [:]

    mutating func record(
        _ result: CloudHangarItemTranslationResult,
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
        _ candidate: CloudHangarItemTranslationCandidate,
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
