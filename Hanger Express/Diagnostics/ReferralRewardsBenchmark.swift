#if DEBUG || HANGAR_BENCHMARKS
import Foundation
import UIKit

/// Explicit UI-test data only; excluded from ordinary Release builds.
nonisolated enum ReferralRewardsBenchmark {
    static var enabled: Bool { ProcessInfo.processInfo.environment["HANGAR_REFERRAL_UI_FIXTURE"] == "1" }
    static func artwork(for reward: ReferralReward, ladder: ReferralLadder) -> UIImage? {
        guard let value = ProcessInfo.processInfo.environment["HANGAR_REFERRAL_ARTWORK_\(ladder.rawValue)_\(reward.threshold)"],
              let data = Data(base64Encoded: value) else { return nil }
        return UIImage(data: data)
    }
    static var catalog: ReferralRewardsCatalog {
        let image = URL(string: "https://example.invalid/reward.jpg")!
        return ReferralRewardsCatalog(schemaVersion: 1, reviewedAt: "2026-10-28", current: [
            ReferralReward(threshold: 1, title: "CDS GCD-Army Medium Armor Set", imageURL: image, imageAspectRatio: 16.0 / 9.0),
            ReferralReward(threshold: 2, title: "VOLT Quartz 'GCD-Army' SMG", imageURL: URL(string: "https://example.invalid/current-2.jpg")!, imageAspectRatio: 16.0 / 9.0),
            ReferralReward(threshold: 3, title: "Gladius Dunlevy Model", imageURL: URL(string: "https://example.invalid/current-3.jpg")!, imageAspectRatio: 16.0 / 9.0),
            ReferralReward(threshold: 10, title: "Big Benny's 'Classic' Vending Machine", imageURL: image, imageAspectRatio: 16.0 / 9.0)
        ], legacy: [
            // Simulate old cached catalogs: missing or incorrect picture dimensions.
            ReferralReward(threshold: 1, title: "Badger and Badges", imageURL: URL(string: "https://example.invalid/legacy-1.jpg")!),
            ReferralReward(threshold: 25, title: "Arena Commander Racing Package", imageURL: URL(string: "https://example.invalid/legacy-25.jpg")!, imageAspectRatio: 16.0 / 9.0),
            ReferralReward(threshold: 200, title: "Ready For Battle", imageURL: URL(string: "https://example.invalid/legacy-200.jpg")!)
        ])
    }
}
#endif
