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
            return "Loading preview hangar"
        case .preparingSession:
            return "Restoring RSI session"
        case .pledges:
            return "Refreshing hangar pledges"
        case .buyback:
            return "Refreshing buy-back pledges"
        case .hangarLog:
            return "Refreshing hangar log"
        case .account:
            return "Refreshing account overview"
        case .finalizing:
            return "Organizing your inventory"
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

    init(
        stage: RefreshStage,
        stepNumber: Int,
        stepCount: Int,
        detail: String,
        completedUnitCount: Int,
        totalUnitCount: Int?,
        trackerID: String? = nil,
        trackerTitle: String? = nil
    ) {
        self.stage = stage
        self.stepNumber = stepNumber
        self.stepCount = stepCount
        self.detail = detail
        self.completedUnitCount = completedUnitCount
        self.totalUnitCount = totalUnitCount
        self.trackerID = trackerID
        self.trackerTitle = trackerTitle
    }

    var fractionCompleted: Double? {
        guard let totalUnitCount, totalUnitCount > 0 else {
            return nil
        }

        let boundedCompletedUnits = min(max(completedUnitCount, 0), totalUnitCount)
        return Double(boundedCompletedUnits) / Double(totalUnitCount)
    }

    var stepLabel: String {
        "Step \(stepNumber) of \(stepCount)"
    }
}

typealias RefreshProgressHandler = @MainActor @Sendable (RefreshProgress) -> Void

nonisolated enum HangarLogFetchMode: Hashable, Sendable {
    case initial
    case expanded

    var entryLimit: Int {
        switch self {
        case .initial:
            return 10
        case .expanded:
            return 500
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
