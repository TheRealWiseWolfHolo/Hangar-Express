import Foundation

nonisolated enum SnapshotSectionOutcome: Sendable {
    case success(HangarSnapshot)
    case failure(requiresAuthentication: Bool)
}

/// Applies only the data owned by each successful section. Package/fleet data
/// always commits together; failures preserve cached values and their age.
nonisolated enum SnapshotRefreshMerger {
    static func merge(base: HangarSnapshot, outcomes: [SnapshotSection: SnapshotSectionOutcome], at date: Date) -> HangarSnapshot {
        var result = base
        for section in SnapshotSection.allCases {
            guard let outcome = outcomes[section] else { continue }
            switch outcome {
            case .success(let value):
                switch section {
                case .hangar:
                    result = result.updatingHangar(packages: value.packages, fleet: value.fleet, lastSyncedAt: date)
                case .buyback:
                    result = result.updatingBuyback(buyback: value.buyback, lastSyncedAt: date)
                case .hangarLog:
                    result = result.updatingHangarLogs(hangarLogs: value.hangarLogs, lastSyncedAt: date)
                case .account:
                    result = result.updatingAccount(accountHandle: value.accountHandle, avatarURL: value.avatarURL,
                        primaryOrganization: value.primaryOrganization, didRefreshPrimaryOrganization: value.didRefreshPrimaryOrganization,
                        storeCreditUSD: value.storeCreditUSD, totalSpendUSD: value.totalSpendUSD,
                        referralStats: value.referralStats, gameAccess: value.gameAccess, lastSyncedAt: date)
                }
            case .failure(let authentication):
                var states = result.sections
                states[section].failedAt = date
                states[section].requiresAuthentication = authentication
                result = result.replacingSections(states)
            }
        }
        return result
    }
}
