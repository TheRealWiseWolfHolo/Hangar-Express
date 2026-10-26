import Foundation

nonisolated enum SnapshotSection: String, Codable, CaseIterable, Hashable, Sendable {
    case hangar, buyback, account, hangarLog
    var title: String {
        switch self {
        case .hangar: AppLocalizer.string("Hangar")
        case .buyback: AppLocalizer.string("Buy Back")
        case .account: AppLocalizer.string("Account")
        case .hangarLog: AppLocalizer.string("Hangar Log")
        }
    }
}

nonisolated struct SnapshotSectionState: Codable, Hashable, Sendable {
    var refreshedAt: Date?
    var contentRevision: UInt64
    var failedAt: Date?
    var requiresAuthentication: Bool = false
    init(refreshedAt: Date? = nil, contentRevision: UInt64 = 0, failedAt: Date? = nil) {
        self.refreshedAt = refreshedAt; self.contentRevision = contentRevision; self.failedAt = failedAt
    }
    func refreshed(at date: Date, changed: Bool) -> Self {
        Self(refreshedAt: date, contentRevision: contentRevision &+ (changed ? 1 : 0))
    }
}

nonisolated struct SnapshotSectionStates: Codable, Hashable, Sendable {
    var hangar: SnapshotSectionState
    var buyback: SnapshotSectionState
    var account: SnapshotSectionState
    var hangarLog: SnapshotSectionState
    static let empty = Self(legacyDate: nil)
    init(legacyDate: Date?) {
        let state = SnapshotSectionState(refreshedAt: legacyDate, contentRevision: legacyDate == nil ? 0 : 1)
        hangar = state; buyback = state; account = state; hangarLog = state
    }
    subscript(_ section: SnapshotSection) -> SnapshotSectionState {
        get {
            switch section { case .hangar: hangar; case .buyback: buyback; case .account: account; case .hangarLog: hangarLog }
        }
        set {
            switch section { case .hangar: hangar = newValue; case .buyback: buyback = newValue; case .account: account = newValue; case .hangarLog: hangarLog = newValue }
        }
    }
    var failedSections: [SnapshotSection] { SnapshotSection.allCases.filter { self[$0].failedAt != nil } }
    func refreshing(_ section: SnapshotSection, at date: Date, changed: Bool) -> Self {
        var next = self; next[section] = self[section].refreshed(at: date, changed: changed); return next
    }
}
