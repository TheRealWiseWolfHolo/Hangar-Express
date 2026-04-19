import Foundation

nonisolated enum RefreshStage: Hashable, Sendable {
    case preview
    case preparingSession
    case pledges
    case buyback
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

    func refreshBuybackData(
        for session: UserSession,
        from snapshot: HangarSnapshot,
        progress: @escaping RefreshProgressHandler
    ) async throws -> HangarSnapshot

    func refreshAccountData(
        for session: UserSession,
        from snapshot: HangarSnapshot,
        progress: @escaping RefreshProgressHandler
    ) async throws -> HangarSnapshot
}
