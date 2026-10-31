import Foundation

nonisolated enum ReferralLadder: String, CaseIterable, Identifiable {
    case current, legacy
    var id: Self { self }
    var title: String { AppLocalizer.string(self == .current ? "New Ladder" : "Legacy Ladder") }
    func count(in stats: ReferralStats) -> Int? {
        let count = self == .current ? stats.currentLadderCount : (stats.hasLegacyLadder ? stats.legacyLadderCount : nil)
        return count.flatMap { $0 >= 0 ? $0 : nil }
    }
}

nonisolated struct ReferralReward: Codable, Hashable, Sendable, Identifiable {
    let threshold: Int
    let title: String
    let imageURL: URL
    var imageAspectRatio: Double? = nil
    var id: Int { threshold }
}

nonisolated struct ReferralRewardsCatalog: Codable, Sendable {
    let schemaVersion: Int
    let reviewedAt: String
    let current: [ReferralReward]
    let legacy: [ReferralReward]

    func rewards(for ladder: ReferralLadder) -> [ReferralReward] { ladder == .current ? current : legacy }
    static func decode(_ data: Data) throws -> Self {
        guard data.count <= 1_000_000 else { throw ValidatedHostedFeedError.invalidResponse }
        let value = try JSONDecoder().decode(Self.self, from: data)
        guard value.schemaVersion == 1, !value.reviewedAt.isEmpty else { throw ValidatedHostedFeedError.invalidResponse }
        for rewards in [value.current, value.legacy] {
            guard !rewards.isEmpty, rewards.count <= 100,
                  rewards.map(\.threshold) == rewards.map(\.threshold).sorted(),
                  Set(rewards.map(\.threshold)).count == rewards.count,
                  rewards.allSatisfy({ $0.threshold > 0 && !$0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                      && $0.imageURL.scheme == "https" && $0.imageURL.host != nil
                      && $0.imageURL.user == nil && $0.imageURL.password == nil
                      && ($0.imageAspectRatio.map { $0.isFinite && (0.2...5).contains($0) } ?? true) }) else {
                throw ValidatedHostedFeedError.invalidResponse
            }
        }
        return value
    }
}
