import Foundation

nonisolated struct RSIGamePackageMatch: Identifiable, Sendable {
    let package: HangarPackage
    let accessItems: [PackageItem]
    var id: Int { package.id }
}

/// Match explicit game-license contents, never a ship/pledge's marketing name.
/// This describes saved Hangar contents, not the authoritative account entitlement.
nonisolated enum RSIGamePackageResolver {
    private static let aliases: [RSIGame: [String]] = [
        .starCitizen: ["starcitizen", "星际公民"],
        .squadron42: ["squadron42", "sq42", "42中队", "中队42"]
    ]
    private static let licenseLabels: Set<String> = [
        "digitaldownload", "gamedownload", "gameaccess", "gamepackage", "gamelicense",
        "digitalgame", "download", "digitaldownloadgamepackage", "gamepackagedigitaldownload",
        "数字下载", "游戏下载", "游戏权限", "游戏组合包", "数字版"
    ]
    private static let excludedStatusWords: Set<String> = [
        "reclaimed", "melted", "exchanged", "gifted", "cancelled", "canceled", "revoked"
    ]

    static func index(packages: [HangarPackage]) throws -> [RSIGame: [RSIGamePackageMatch]] {
        var result = Dictionary(uniqueKeysWithValues: RSIGame.allCases.map { ($0, [RSIGamePackageMatch]()) })
        for (offset, package) in packages.enumerated() {
            if offset.isMultiple(of: 64) { try Task.checkCancellation() }
            let statusWords = Set(package.status.lowercased().split { !$0.isLetter }.map(String.init))
            guard statusWords.isDisjoint(with: excludedStatusWords) else { continue }
            var itemsByGame: [RSIGame: [PackageItem]] = [:]
            for item in package.contents {
                for game in games(in: item) { itemsByGame[game, default: []].append(item) }
            }
            for game in RSIGame.allCases {
                if let items = itemsByGame[game] { result[game, default: []].append(.init(package: package, accessItems: items)) }
            }
        }
        try Task.checkCancellation()
        return result
    }

    static func games(in item: PackageItem) -> Set<RSIGame> {
        let title = normalized(item.title), detail = normalized(item.detail)
        let negative = ["notincluded", "doesnotinclude", "withoutgameaccess", "nogameaccess", "upgradeonly"]
        guard !negative.contains(where: { title.contains($0) || detail.contains($0) }) else { return [] }
        var residue = title
        var found: Set<RSIGame> = []
        for game in RSIGame.allCases {
            for alias in aliases[game] ?? [] where residue.contains(alias) {
                found.insert(game)
                residue = residue.replacingOccurrences(of: alias, with: "")
            }
        }
        guard !found.isEmpty else { return [] }
        // A combined SC + SQ42 download can use a single line of contents.
        if found.count > 1 { residue = residue.replacingOccurrences(of: "and", with: "") }
        if licenseLabels.contains(residue) { return found }
        if residue.isEmpty && (item.category == .gamePackage || licenseLabels.contains(detail)) { return found }
        return []
    }

    private static func normalized(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                      locale: Locale(identifier: "en_US_POSIX"))
            .lowercased().filter { $0.isLetter || $0.isNumber }
    }
}
