import Foundation

nonisolated enum RefreshStage: Hashable, Sendable {
    case preview
    case preparingSession
    case pledges
    case buyback
    case hangarLog
    case account
    case finalizing

    var title: String {
        switch self {
        case .preview:
            return AppLocalizer.string("Loading preview hangar")
        case .preparingSession:
            return AppLocalizer.string("Restoring RSI session")
        case .pledges:
            return AppLocalizer.string("Refreshing hangar pledges")
        case .buyback:
            return AppLocalizer.string("Refreshing buy-back pledges")
        case .hangarLog:
            return AppLocalizer.string("Refreshing hangar log")
        case .account:
            return AppLocalizer.string("Refreshing account overview")
        case .finalizing:
            return AppLocalizer.string("Organizing your inventory")
        }
    }
}

nonisolated struct RefreshProgress: Hashable, Sendable {
    let stage: RefreshStage
    let stepNumber: Int
    let stepCount: Int
    let detail: String
    let completedUnitCount: Int
    let totalUnitCount: Int?
    let trackerID: String?
    let trackerTitle: String?
    let displayStartFraction: Double?
    let displayEndFraction: Double?

    init(
        stage: RefreshStage,
        stepNumber: Int,
        stepCount: Int,
        detail: String,
        completedUnitCount: Int,
        totalUnitCount: Int?,
        trackerID: String? = nil,
        trackerTitle: String? = nil,
        displayStartFraction: Double? = nil,
        displayEndFraction: Double? = nil
    ) {
        self.stage = stage
        self.stepNumber = stepNumber
        self.stepCount = stepCount
        self.detail = detail
        self.completedUnitCount = completedUnitCount
        self.totalUnitCount = totalUnitCount
        self.trackerID = trackerID
        self.trackerTitle = trackerTitle
        self.displayStartFraction = displayStartFraction
        self.displayEndFraction = displayEndFraction
    }

    var fractionCompleted: Double? {
        guard let totalUnitCount, totalUnitCount > 0 else {
            return nil
        }

        let boundedCompletedUnits = min(max(completedUnitCount, 0), totalUnitCount)
        return Double(boundedCompletedUnits) / Double(totalUnitCount)
    }

    var displayFractionCompleted: Double? {
        if let displayStartFraction,
           let displayEndFraction {
            let startFraction = min(max(displayStartFraction, 0), 1)
            let endFraction = min(max(displayEndFraction, startFraction), 1)

            guard let baseFraction = fractionCompleted else {
                return startFraction
            }

            let boundedBaseFraction = min(max(baseFraction, 0), 1)
            return startFraction + (endFraction - startFraction) * boundedBaseFraction
        }

        guard let baseFraction = fractionCompleted, stepCount > 0 else {
            return fractionCompleted
        }

        let boundedStep = min(max(stepNumber, 1), stepCount)
        let boundedStepFraction = min(max(baseFraction, 0), 1)
        return (Double(boundedStep - 1) + boundedStepFraction) / Double(stepCount)
    }

    var stepLabel: String {
        AppLocalizer.format("Step %lld of %lld", stepNumber, stepCount)
    }
}

typealias RefreshProgressHandler = @MainActor @Sendable (RefreshProgress) -> Void
typealias LimitedShipCartLogHandler = @MainActor @Sendable (String) -> Void

nonisolated enum HangarLogFetchMode: Hashable, Sendable {
    case initial
    case expanded

    var entryLimit: Int {
        entryLimit(isPro: ProSubscriptionConfiguration.storedIsPro)
    }

    func entryLimit(isPro: Bool) -> Int {
        switch self {
        case .initial:
            return ProSubscriptionConfiguration.standardHangarLogEntryLimit
        case .expanded:
            return ProSubscriptionConfiguration.hangarLogEntryLimit(isPro: isPro)
        }
    }
}

@MainActor
final class RefreshDiagnosticsStore {
    struct Entry: Identifiable, Equatable {
        enum Level: String {
            case info = "INFO"
            case warning = "WARN"
            case error = "ERROR"
        }

        let id = UUID()
        let timestamp: Date
        let level: Level
        let stage: String
        let summary: String
        let detail: String?

        var timestampLabel: String {
            Entry.timeFormatter.string(from: timestamp)
        }

        private static let timeFormatter: DateFormatter = {
            let formatter = DateFormatter()
            formatter.dateFormat = "HH:mm:ss"
            return formatter
        }()
    }

    private(set) var entries: [Entry] = []

    func reset(context: String? = nil) {
        entries.removeAll()

        if let context, !context.isEmpty {
            record(stage: "refresh.attempt", summary: context)
        }
    }

    func record(
        stage: String,
        summary: String,
        detail: String? = nil,
        level: Entry.Level = .info
    ) {
        let trimmedSummary = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedSummary.isEmpty else {
            return
        }

        let trimmedDetail = detail?.trimmingCharacters(in: .whitespacesAndNewlines)
        entries.append(
            Entry(
                timestamp: .now,
                level: level,
                stage: stage,
                summary: trimmedSummary,
                detail: trimmedDetail?.isEmpty == false ? trimmedDetail : nil
            )
        )

        if entries.count > 120 {
            entries.removeFirst(entries.count - 120)
        }
    }
}

nonisolated struct MeltPackagesResult: Hashable, Sendable {
    let requestedPledgeIDs: [Int]
    let completedPledgeIDs: [Int]
    let failedPledgeID: Int?
    let failureMessage: String?
    let updatedCookies: [SessionCookie]

    var completedCount: Int {
        completedPledgeIDs.count
    }

    var wasSuccessful: Bool {
        failedPledgeID == nil && failureMessage == nil && completedCount == requestedPledgeIDs.count
    }
}

nonisolated struct GiftPackagesResult: Hashable, Sendable {
    let requestedPledgeIDs: [Int]
    let completedPledgeIDs: [Int]
    let failedPledgeID: Int?
    let failureMessage: String?
    let updatedCookies: [SessionCookie]

    var completedCount: Int {
        completedPledgeIDs.count
    }

    var wasSuccessful: Bool {
        failedPledgeID == nil && failureMessage == nil && completedCount == requestedPledgeIDs.count
    }
}

nonisolated struct UpgradeTargetCandidate: Hashable, Sendable, Codable, Identifiable {
    let pledgeID: Int
    let title: String
    let status: String?
    let insurance: String?
    let thumbnailURL: URL?

    var id: Int {
        pledgeID
    }

    init(
        pledgeID: Int,
        title: String,
        status: String? = nil,
        insurance: String? = nil,
        thumbnailURL: URL? = nil
    ) {
        self.pledgeID = pledgeID
        self.title = title
        self.status = status
        self.insurance = insurance
        self.thumbnailURL = thumbnailURL
    }
}

nonisolated struct ApplyUpgradeResult: Hashable, Sendable {
    let upgradeItemPledgeID: Int
    let targetPledgeID: Int
    let wasSuccessful: Bool
    let failureMessage: String?
    let updatedCookies: [SessionCookie]
}

nonisolated struct BuybackCheckoutPreparation: Hashable, Sendable {
    let buybackPledgeID: Int
    let checkoutURL: URL
    let updatedCookies: [SessionCookie]
}

nonisolated struct LimitedShipAvailabilitySlot: Identifiable, Hashable, Sendable, Codable {
    let startsAt: Date
    let endsAt: Date

    init(startsAt: Date, endsAt: Date) {
        self.startsAt = startsAt
        self.endsAt = endsAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        if let startsAt = try container.decodeIfPresent(Date.self, forKey: .startsAt)
            ?? container.decodeIfPresent(Date.self, forKey: .startAt) {
            self.startsAt = startsAt
        } else {
            throw DecodingError.keyNotFound(
                CodingKeys.startsAt,
                DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Missing startsAt")
            )
        }

        if let endsAt = try container.decodeIfPresent(Date.self, forKey: .endsAt)
            ?? container.decodeIfPresent(Date.self, forKey: .endAt) {
            self.endsAt = endsAt
        } else {
            throw DecodingError.keyNotFound(
                CodingKeys.endsAt,
                DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Missing endsAt")
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(startsAt, forKey: .startsAt)
        try container.encode(endsAt, forKey: .endsAt)
    }

    var id: String {
        "\(startsAt.timeIntervalSince1970)-\(endsAt.timeIntervalSince1970)"
    }

    var isValid: Bool {
        endsAt > startsAt
    }

    func contains(_ date: Date) -> Bool {
        startsAt <= date && date <= endsAt
    }

    func isWithinStartWindow(at date: Date, leadTime: TimeInterval) -> Bool {
        if contains(date) {
            return true
        }

        let secondsUntilStart = startsAt.timeIntervalSince(date)
        return secondsUntilStart >= 0 && secondsUntilStart <= leadTime
    }

    func fireDate(at date: Date) -> Date {
        if contains(date) {
            return date
        }

        return max(date, startsAt.addingTimeInterval(-1))
    }

    private enum CodingKeys: String, CodingKey {
        case startsAt
        case startAt
        case endsAt
        case endAt
    }
}

nonisolated struct LimitedShipSale: Identifiable, Hashable, Sendable, Codable {
    let id: String
    let name: String
    let manufacturer: String
    let priceUSD: Decimal
    let availabilitySlots: [LimitedShipAvailabilitySlot]
    let storeURL: URL
    let imageURL: URL?
    let manufacturerLogoURL: URL?

    var priceText: String {
        "$\(NSDecimalNumber(decimal: priceUSD).stringValue) USD"
    }

    var validAvailabilitySlots: [LimitedShipAvailabilitySlot] {
        availabilitySlots
            .filter(\.isValid)
            .sorted { $0.startsAt < $1.startsAt }
    }

    func bestAvailabilitySlot(at date: Date) -> LimitedShipAvailabilitySlot? {
        if let activeSlot = validAvailabilitySlots.first(where: { $0.contains(date) }) {
            return activeSlot
        }

        if let upcomingSlot = validAvailabilitySlots.first(where: { $0.startsAt > date }) {
            return upcomingSlot
        }

        return validAvailabilitySlots.last
    }

    func slotWithinStartWindow(at date: Date, leadTime: TimeInterval) -> LimitedShipAvailabilitySlot? {
        validAvailabilitySlots.first { slot in
            slot.isWithinStartWindow(at: date, leadTime: leadTime)
        }
    }

    func replacingHostedAssets(imageURL: URL?, manufacturerLogoURL: URL?) -> LimitedShipSale {
        LimitedShipSale(
            id: id,
            name: name,
            manufacturer: manufacturer,
            priceUSD: priceUSD,
            availabilitySlots: availabilitySlots,
            storeURL: storeURL,
            imageURL: self.imageURL ?? imageURL,
            manufacturerLogoURL: self.manufacturerLogoURL ?? manufacturerLogoURL
        )
    }
}

nonisolated struct LimitedShipCartInsertionResult: Hashable, Sendable {
    let shipID: String
    let cartURL: URL
    let attemptCount: Int
    let debugSummary: String?
    let debugLog: [String]
    let updatedCookies: [SessionCookie]
}

nonisolated struct AuthorizedDevice: Identifiable, Hashable, Sendable {
    static let hangarExpressDeviceName = "Hangar Express"

    let id: String
    let name: String
    let type: String?
    let createdAtLabel: String?
    let duration: String?
    let isCurrent: Bool

    init(
        id: String,
        name: String,
        type: String? = nil,
        createdAtLabel: String? = nil,
        duration: String? = nil,
        isCurrent: Bool = false
    ) {
        self.id = id
        self.name = name
        self.type = type
        self.createdAtLabel = createdAtLabel
        self.duration = duration
        self.isCurrent = isCurrent
    }

    var displayName: String {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedName.isEmpty ? AppLocalizer.string("Unnamed Device") : trimmedName
    }

    var displayType: String {
        let normalizedType = type?.trimmingCharacters(in: .whitespacesAndNewlines).localizedLowercase ?? ""

        switch normalizedType {
        case "mobile":
            return AppLocalizer.string("Mobile")
        case "tablet":
            return AppLocalizer.string("Tablet")
        case "desktop":
            return AppLocalizer.string("Desktop")
        case "browser":
            return AppLocalizer.string("Browser")
        default:
            return normalizedType.isEmpty ? AppLocalizer.string("Device") : normalizedType.capitalized
        }
    }

    var durationLabel: String {
        let normalizedDuration = duration?.trimmingCharacters(in: .whitespacesAndNewlines).localizedLowercase ?? ""

        switch normalizedDuration {
        case "session":
            return AppLocalizer.string("This session")
        case "day":
            return AppLocalizer.string("1 day")
        case "week":
            return AppLocalizer.string("1 week")
        case "month":
            return AppLocalizer.string("1 month")
        case "year":
            return AppLocalizer.string("1 year")
        default:
            return normalizedDuration.isEmpty ? AppLocalizer.string("Unknown") : normalizedDuration.capitalized
        }
    }

    var matchesHangarExpressDeviceName: Bool {
        displayName.localizedCaseInsensitiveCompare(Self.hangarExpressDeviceName) == .orderedSame
    }

    var shouldProtectFromBulkRemoval: Bool {
        isCurrent
    }
}

protocol HangarRepository: Sendable {
    func fetchSnapshot(
        for session: UserSession,
        progress: @escaping RefreshProgressHandler
    ) async throws -> HangarSnapshot

    func refreshHangarData(
        for session: UserSession,
        from snapshot: HangarSnapshot,
        progress: @escaping RefreshProgressHandler
    ) async throws -> HangarSnapshot

    func refreshHangarData(
        for session: UserSession,
        from snapshot: HangarSnapshot,
        affectedPledgeIDs: [Int],
        progress: @escaping RefreshProgressHandler
    ) async throws -> HangarSnapshot

    func refreshBuybackData(
        for session: UserSession,
        from snapshot: HangarSnapshot,
        progress: @escaping RefreshProgressHandler
    ) async throws -> HangarSnapshot

    func refreshHangarLogData(
        for session: UserSession,
        from snapshot: HangarSnapshot,
        mode: HangarLogFetchMode,
        progress: @escaping RefreshProgressHandler
    ) async throws -> HangarSnapshot

    func refreshAccountData(
        for session: UserSession,
        from snapshot: HangarSnapshot,
        progress: @escaping RefreshProgressHandler
    ) async throws -> HangarSnapshot

    func meltPackages(
        for session: UserSession,
        pledgeIDs: [Int],
        password: String
    ) async throws -> MeltPackagesResult

    func giftPackages(
        for session: UserSession,
        pledgeIDs: [Int],
        password: String,
        recipientEmail: String,
        recipientName: String
    ) async throws -> GiftPackagesResult

    func fetchUpgradeTargets(
        for session: UserSession,
        upgradeItemPledgeID: Int
    ) async throws -> [UpgradeTargetCandidate]

    func applyUpgrade(
        for session: UserSession,
        upgradeItemPledgeID: Int,
        targetPledgeID: Int,
        password: String
    ) async throws -> ApplyUpgradeResult

    func prepareBuybackCheckout(
        for session: UserSession,
        pledge: BuybackPledge
    ) async throws -> BuybackCheckoutPreparation

    func fetchLimitedShipSales() async throws -> [LimitedShipSale]

    func addLimitedShipToCart(
        for session: UserSession,
        ship: LimitedShipSale,
        log: @escaping LimitedShipCartLogHandler
    ) async throws -> LimitedShipCartInsertionResult

    func fetchAuthorizedDevices(
        for session: UserSession,
        password: String?
    ) async throws -> [AuthorizedDevice]

    func removeAuthorizedDevice(
        for session: UserSession,
        device: AuthorizedDevice,
        password: String?
    ) async throws

    func removeAuthorizedDevices(
        for session: UserSession,
        devices: [AuthorizedDevice],
        password: String?
    ) async throws
}

extension HangarRepository {
    func refreshHangarLogData(
        for session: UserSession,
        from snapshot: HangarSnapshot,
        progress: @escaping RefreshProgressHandler
    ) async throws -> HangarSnapshot {
        try await refreshHangarLogData(
            for: session,
            from: snapshot,
            mode: .initial,
            progress: progress
        )
    }
}
