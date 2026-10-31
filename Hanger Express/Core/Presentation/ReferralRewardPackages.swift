import Foundation

/// Resolves real saved pledges; a reached milestone alone never creates an item.
actor ReferralRewardPackageMatcher {
    static let shared = ReferralRewardPackageMatcher()

    func matches(reward: ReferralReward, ladder: ReferralLadder,
                 groups: [GroupedHangarPackage]) throws -> [GroupedHangarPackage] {
        let fullName = Self.key(reward.title)
        guard !fullName.isEmpty else { return [] }
        let names = Set(([reward.title] + Self.aliases(for: reward, ladder: ladder)).map(Self.key))
        var bestScore = 0
        var result: [GroupedHangarPackage] = []
        for (offset, group) in groups.enumerated() {
            if offset.isMultiple(of: 64) { try Task.checkCancellation() }
            let active = group.packages.filter(Self.isActive)
            guard let representative = active.first else { continue }
            var score = 0
            for package in active {
                let referral = Self.isReferral(package.title)
                    || package.contents.contains { Self.isReferral($0.detail) }
                let packageName = Self.key(package.title)
                if packageName == fullName || (referral && names.contains(packageName)) {
                    score = max(score, referral ? 4 : 3)
                    continue
                }
                for item in package.contents {
                    let title = Self.key(item.title)
                    if referral && names.contains(title) { score = max(score, 2) }
                    else if title == fullName { score = max(score, 1) }
                }
            }
            guard score > 0, score >= bestScore else { continue }
            if score > bestScore { result.removeAll(); bestScore = score }
            result.append(GroupedHangarPackage(representative: representative, packages: active))
        }
        try Task.checkCancellation()
        return result
    }

    private nonisolated static func aliases(for reward: ReferralReward, ladder: ReferralLadder) -> [String] {
        let known: [Int: (String, [String])]
        if ladder == .legacy {
            known = [75: ("Speed Racer", ["Referral 75"]), 100: ("Dog Fighter", ["Referral 100"]),
                     200: ("Ready For Battle", ["Referral 200"]), 500: ("Anvil Ship Package", ["Referral 500"]),
                     1042: ("Million Mile High Club Access", ["Referral 1042", "Million Mile High Club"]),
                     2017: ("Star Crossing", ["Referral 2017"])]
        } else {
            known = [15: ("Spirit of the Starman Statue", ["Spirit of the Starman"]),
                     25: ("Enemy of the Empire Statue", ["Enemy of the Empire"]),
                     42: ("Aegis Gladius Dunlevy", ["Gladius Dunlevy"]), 50: ("MISC RAPTOR", ["RAPTOR"]),
                     200: ("Esperia Stinger", ["Stinger"]), 500: ("Captured Vanduul Scythe", ["Vanduul Scythe", "Scythe"]),
                     1042: ("Idris-M", ["Idris-M Frigate", "RSI Idris-M"])]
        }
        guard let (title, aliases) = known[reward.threshold], key(title) == key(reward.title) else { return [] }
        return aliases
    }

    private nonisolated static func isReferral(_ text: String) -> Bool {
        text.lowercased().split { !$0.isLetter }.contains("referral")
    }

    private nonisolated static func isActive(_ package: HangarPackage) -> Bool {
        let words = Set(package.status.lowercased().split { !$0.isLetter }.map(String.init))
        return words.isDisjoint(with: ["gifted", "reclaimed", "melted", "exchanged", "cancelled", "canceled", "revoked"])
    }

    private nonisolated static func key(_ source: String) -> String {
        var text = source.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                                  locale: Locale(identifier: "en_US_POSIX")).lowercased()
            .replacingOccurrences(of: "–", with: "-").replacingOccurrences(of: "—", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let prefixes = ["referral reward - ", "referral bonus - ", "referral - ", "gear - ",
                        "standalone ships - ", "standalone ship - ", "add-ons - ", "add-on - ", "package - "]
        while let prefix = prefixes.first(where: { text.hasPrefix($0) }) {
            text = String(text.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        for suffix in [" - referral reward", " - referral bonus"] where text.hasSuffix(suffix) {
            text = String(text.dropLast(suffix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        text = text.replacingOccurrences(of: "&", with: "and")
        return String(String.UnicodeScalarView(text.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }))
    }
}

nonisolated struct ReferralRewardDestination: Identifiable, Hashable {
    let id = UUID()
    let title: String
    let groups: [GroupedHangarPackage]
}
