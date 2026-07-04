import Foundation
import Observation
import SwiftUI

enum HangarItemLanguage: String, CaseIterable, Identifiable, Sendable {
    case original
    case simplifiedChinese

    nonisolated static let storageKey = "hangar.itemLanguage"

    var id: Self { self }

    nonisolated var translationLocaleIdentifier: String? {
        switch self {
        case .original:
            return nil
        case .simplifiedChinese:
            return "zh-Hans"
        }
    }

    @ViewBuilder
    var label: some View {
        switch self {
        case .original:
            Text("Original")
        case .simplifiedChinese:
            Text("简体中文")
        }
    }

    nonisolated static func resolved(from rawValue: String) -> HangarItemLanguage {
        HangarItemLanguage(rawValue: rawValue) ?? .original
    }
}

nonisolated struct HangarItemTranslationDictionary: Equatable, Sendable {
    struct Entry: Equatable, Sendable {
        let source: String
        let translation: String
        let kind: String
        let aliases: [String]
    }

    struct MachineTranslationProtectedTerm: Equatable, Sendable {
        let source: String
        let translation: String
    }

    let locale: String
    let version: Int
    let generatedAt: String?
    let entries: [Entry]
    let machineTranslationProtectedTerms: [MachineTranslationProtectedTerm]
    private let translationsByKey: [String: String]

    init(
        locale: String,
        version: Int,
        generatedAt: String?,
        entries: [Entry],
        expectedLocale: String? = nil
    ) throws {
        let normalizedLocale = locale.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedLocale.isEmpty else {
            throw HostedShipCatalogError.invalidItemTranslationFeed("Missing locale.")
        }

        if let expectedLocale, normalizedLocale != expectedLocale {
            throw HostedShipCatalogError.invalidItemTranslationFeed("Expected locale \(expectedLocale), received \(normalizedLocale).")
        }

        guard version > 0 else {
            throw HostedShipCatalogError.invalidItemTranslationFeed("Version must be greater than zero.")
        }

        guard !entries.isEmpty else {
            throw HostedShipCatalogError.invalidItemTranslationFeed("Entries must not be empty.")
        }

        var lookup: [String: String] = [:]
        var normalizedEntries: [Entry] = []
        normalizedEntries.reserveCapacity(entries.count)

        for entry in entries {
            let source = entry.source.trimmingCharacters(in: .whitespacesAndNewlines)
            let translation = entry.translation.trimmingCharacters(in: .whitespacesAndNewlines)
            let kind = entry.kind.trimmingCharacters(in: .whitespacesAndNewlines)
            let aliases = entry.aliases.map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
            }

            guard !source.isEmpty else {
                throw HostedShipCatalogError.invalidItemTranslationFeed("Entry source must not be empty.")
            }

            guard !translation.isEmpty else {
                throw HostedShipCatalogError.invalidItemTranslationFeed("\(source) is missing a translation.")
            }

            guard !kind.isEmpty else {
                throw HostedShipCatalogError.invalidItemTranslationFeed("\(source) is missing a kind.")
            }

            let normalizedEntry = Entry(
                source: source,
                translation: translation,
                kind: kind,
                aliases: aliases.filter { !$0.isEmpty }
            )
            normalizedEntries.append(normalizedEntry)

            for keySource in [source] + normalizedEntry.aliases {
                let key = Self.normalizedLookupKey(keySource)
                guard !key.isEmpty else {
                    continue
                }

                if lookup[key] != nil {
                    throw HostedShipCatalogError.invalidItemTranslationFeed("Duplicate translation key: \(keySource).")
                }

                lookup[key] = translation
            }
        }

        self.locale = normalizedLocale
        self.version = version
        self.generatedAt = generatedAt?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.entries = normalizedEntries
        machineTranslationProtectedTerms = Self.protectedTerms(from: normalizedEntries)
        translationsByKey = lookup
    }

    func translation(for source: String) -> String? {
        translationsByKey[Self.normalizedLookupKey(source)]
    }

    static func normalizedLookupKey(_ source: String) -> String {
        source
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .lowercased()
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private static func protectedTerms(from entries: [Entry]) -> [MachineTranslationProtectedTerm] {
        var protectedTerms: [MachineTranslationProtectedTerm] = []
        var seenKeys = Set<String>()

        for entry in entries {
            for source in [entry.source] + entry.aliases {
                let trimmedSource = source.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmedSource.isEmpty else {
                    continue
                }

                let key = normalizedLookupKey(trimmedSource)
                guard seenKeys.insert(key).inserted else {
                    continue
                }

                protectedTerms.append(
                    MachineTranslationProtectedTerm(
                        source: trimmedSource,
                        translation: entry.translation
                    )
                )
            }
        }

        return protectedTerms.sorted {
            if $0.source.count != $1.source.count {
                return $0.source.count > $1.source.count
            }

            return $0.source.localizedStandardCompare($1.source) == .orderedAscending
        }
    }
}

nonisolated struct HangarItemTranslator: Equatable, Sendable {
    let language: HangarItemLanguage
    let dictionary: HangarItemTranslationDictionary?

    static let original = HangarItemTranslator(language: .original, dictionary: nil)

    var isEnabled: Bool {
        guard let expectedLocale = language.translationLocaleIdentifier else {
            return false
        }

        return dictionary?.locale == expectedLocale
    }

    func translated(_ source: String) -> String {
        guard isEnabled else {
            return source
        }

        return dictionary?.translation(for: source) ?? source
    }

    func searchableText(for source: String) -> String {
        let translatedSource = translated(source)
        if translatedSource == source {
            let replacedSource = replacingProtectedTerms(in: source)
            if replacedSource == source {
                return source
            }

            return "\(source) \(replacedSource)"
        }

        return "\(source) \(translatedSource)"
    }

    func searchableText(for sources: [String]) -> String {
        sources
            .map(searchableText(for:))
            .joined(separator: " ")
    }

    func translatedOptional(_ source: String?) -> String? {
        guard let source = trimmedNonEmpty(source) else {
            return nil
        }

        return translated(source)
    }

    func searchableText(forOptional source: String?) -> String? {
        guard let source = trimmedNonEmpty(source) else {
            return nil
        }

        return searchableText(for: source)
    }

    func searchableText(forOptionalSources sources: [String?]) -> String {
        sources
            .compactMap(searchableText(forOptional:))
            .joined(separator: " ")
    }

    func fleetSearchableText(for ship: FleetShip) -> String {
        [
            searchableText(for: ship.displayName),
            ship.manufacturer,
            ship.role,
            ship.roleCategories.joined(separator: " "),
            ship.insurance,
            searchableText(for: ship.sourcePackageName)
        ]
        .joined(separator: " ")
        .localizedLowercase
    }

    func fleetSourcePackageSummary(for shipGroup: GroupedFleetShip) -> String {
        let distinctPackages = Array(Set(shipGroup.ships.map(\.sourcePackageName))).sorted()

        if distinctPackages.count == 1, let packageName = distinctPackages.first {
            return translated(packageName)
        }

        return AppLocalizer.format("%lld packages", distinctPackages.count)
    }

    func allShipsCatalogSearchableText(
        name: String,
        manufacturer: String,
        priceText: String,
        storeAvailability: String?,
        inGameStatus: String?,
        aliases: [String]
    ) -> String {
        [
            searchableText(for: [name] + aliases),
            manufacturer,
            priceText,
            storeAvailability,
            inGameStatus
        ]
        .compactMap { trimmedNonEmpty($0) }
        .joined(separator: " ")
        .localizedLowercase
    }

    func buybackSearchableText(for pledge: BuybackPledge) -> String {
        [
            searchableText(for: pledge.title),
            pledge.displayedNotes,
            searchableText(forOptional: pledge.sourceRawInfo?.titleText),
            pledge.sourceRawInfo?.containsText,
            pledge.sourceRawInfo?.articleText
        ]
        .compactMap { trimmedNonEmpty($0) }
        .joined(separator: " ")
        .localizedLowercase
    }

    func hangarLogSearchableText(for entry: HangarLogEntry) -> String {
        [
            searchableText(for: entry.itemName),
            entry.action.rawValue,
            entry.action.title,
            entry.operatorName,
            entry.orderCode,
            entry.sourcePledgeID,
            entry.targetPledgeID,
            searchableText(forOptional: entry.reason),
            searchableText(forOptional: entry.upgradeContext?.sourceShipName),
            searchableText(forOptional: entry.upgradeContext?.targetShipName),
            searchableText(forOptional: entry.upgradeContext?.upgradeName),
            entry.rawText,
            entry.occurredAt.formatted(date: .abbreviated, time: .shortened)
        ]
        .compactMap { trimmedNonEmpty($0) }
        .joined(separator: " ")
        .localizedLowercase
    }

    func hangarLogUpgradeSummary(for context: HangarLogUpgradeContext) -> String? {
        if let sourceShipName = context.sourceShipName,
           let targetShipName = context.targetShipName {
            return "\(translated(sourceShipName)) to \(translated(targetShipName))"
        }

        if let targetShipName = context.targetShipName {
            return AppLocalizer.format("Upgraded to %@", translated(targetShipName))
        }

        if let sourceShipName = context.sourceShipName {
            return AppLocalizer.format("Upgraded from %@", translated(sourceShipName))
        }

        return translatedOptional(context.upgradeName)
    }

    func maskedForMachineTranslation(_ source: String) -> MaskedHangarItemText {
        let matches = protectedTermMatches(in: source)
        guard !matches.isEmpty else {
            return MaskedHangarItemText(maskedText: source, replacements: [])
        }

        let orderedMatches = matches.sorted { lhs, rhs in
            lhs.range.location < rhs.range.location
        }

        var maskedText = ""
        var replacements: [MaskedHangarItemText.Replacement] = []
        var currentIndex = source.startIndex

        for (index, match) in orderedMatches.enumerated() {
            guard let range = Range(match.range, in: source) else {
                continue
            }

            maskedText += String(source[currentIndex ..< range.lowerBound])
            let token = "HXTERM\(String(format: "%04d", index))HX"
            maskedText += token
            replacements.append(
                MaskedHangarItemText.Replacement(
                    token: token,
                    translation: match.replacement
                )
            )
            currentIndex = range.upperBound
        }

        maskedText += String(source[currentIndex...])
        return MaskedHangarItemText(maskedText: maskedText, replacements: replacements)
    }

    func replacingProtectedTerms(in source: String) -> String {
        let matches = protectedTermMatches(in: source)
        guard !matches.isEmpty else {
            return source
        }

        var translatedText = ""
        var currentIndex = source.startIndex

        for match in matches {
            guard let range = Range(match.range, in: source) else {
                continue
            }

            translatedText += String(source[currentIndex ..< range.lowerBound])
            translatedText += match.replacement
            currentIndex = range.upperBound
        }

        translatedText += String(source[currentIndex...])
        return translatedText
    }

    func normalizedMachineTranslationSpacing(_ translatedText: String, source: String) -> String {
        let matches = protectedTermMatches(in: source)
        guard !matches.isEmpty else {
            return MaskedHangarItemText.normalizedRestoredSpacing(translatedText)
        }

        var seenProtectedTranslations = Set<String>()
        let protectedTranslations = matches
            .map(\.replacement)
            .filter { $0.count > 1 && seenProtectedTranslations.insert($0).inserted }
            .sorted { lhs, rhs in
                if lhs.count != rhs.count {
                    return lhs.count > rhs.count
                }

                return lhs.localizedStandardCompare(rhs) == .orderedAscending
            }

        let paddedText = protectedTranslations.reduce(translatedText) { partialResult, protectedTranslation in
            partialResult.replacingOccurrences(
                of: protectedTranslation,
                with: " \(protectedTranslation) "
            )
        }

        return MaskedHangarItemText.normalizedRestoredSpacing(paddedText)
    }

    private func protectedTermMatches(in source: String) -> [(range: NSRange, replacement: String)] {
        guard isEnabled,
              let dictionary,
              !dictionary.entries.isEmpty else {
            return []
        }

        let candidates = dictionary.machineTranslationProtectedTerms
        guard !candidates.isEmpty else {
            return []
        }

        let nsSource = source as NSString
        let sourceRange = NSRange(location: 0, length: nsSource.length)
        var occupiedRanges: [NSRange] = []
        var matches: [(range: NSRange, replacement: String)] = []

        for candidate in candidates {
            let candidateLength = (candidate.source as NSString).length
            guard candidateLength > 0, candidateLength <= nsSource.length else {
                continue
            }

            var searchRange = sourceRange
            while searchRange.length > 0 {
                let range = nsSource.range(
                    of: candidate.source,
                    options: [.caseInsensitive, .diacriticInsensitive],
                    range: searchRange
                )
                guard range.location != NSNotFound else {
                    break
                }

                if range.length > 0,
                   hasTermBoundary(in: source, range: range),
                   !occupiedRanges.contains(where: { NSIntersectionRange($0, range).length > 0 }) {
                    occupiedRanges.append(range)
                    matches.append((range, candidate.translation))
                }

                let nextLocation = range.location + max(range.length, 1)
                guard nextLocation < sourceRange.location + sourceRange.length else {
                    break
                }

                searchRange = NSRange(
                    location: nextLocation,
                    length: sourceRange.location + sourceRange.length - nextLocation
                )
            }
        }

        return matches.sorted { lhs, rhs in
            lhs.range.location < rhs.range.location
        }
    }

    private func hasTermBoundary(in source: String, range: NSRange) -> Bool {
        let previousOffset = range.location - 1
        let nextOffset = range.location + range.length

        return !isAlphaNumericUTF16CodeUnit(in: source, at: previousOffset)
            && !isAlphaNumericUTF16CodeUnit(in: source, at: nextOffset)
    }

    private func isAlphaNumericUTF16CodeUnit(in source: String, at offset: Int) -> Bool {
        guard offset >= 0, offset < source.utf16.count else {
            return false
        }

        let index = source.utf16.index(source.utf16.startIndex, offsetBy: offset)
        guard let scalar = UnicodeScalar(Int(source.utf16[index])) else {
            return false
        }

        return CharacterSet.alphanumerics.contains(scalar)
    }

    private func trimmedNonEmpty(_ source: String?) -> String? {
        let trimmedSource = source?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmedSource.isEmpty ? nil : trimmedSource
    }
}

nonisolated struct MaskedHangarItemText: Equatable, Sendable {
    struct Replacement: Equatable, Sendable {
        let token: String
        let translation: String
    }

    let maskedText: String
    let replacements: [Replacement]

    var hasReplacements: Bool {
        !replacements.isEmpty
    }

    func restoringTerms(in translatedText: String) -> String {
        let restoredText = replacements.reduce(translatedText) { partialResult, replacement in
            partialResult.replacingOccurrences(
                of: replacement.token,
                with: " \(replacement.translation) "
            )
        }

        return Self.normalizedRestoredSpacing(restoredText)
    }

    static func normalizedRestoredSpacing(_ text: String) -> String {
        text
            .replacingOccurrences(
                of: #"\s+"#,
                with: " ",
                options: .regularExpression
            )
            .replacingOccurrences(of: "战争债券 版", with: "战争债券版")
            .replacingOccurrences(of: "标准 版", with: "标准版")
            .replacingOccurrences(
                of: #" ([,.;:!?，。！？；：、）】》])"#,
                with: "$1",
                options: .regularExpression
            )
            .replacingOccurrences(
                of: #"([（(【《]) "#,
                with: "$1",
                options: .regularExpression
            )
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

@MainActor
@Observable
final class HangarItemTranslationViewState {
    private var dictionary: HangarItemTranslationDictionary?
    private var loadedRawValue: String?
    private var requestedRawValue: String?

    func translator(for rawValue: String) -> HangarItemTranslator {
        let language = HangarItemLanguage.resolved(from: rawValue)
        return HangarItemTranslator(
            language: language,
            dictionary: dictionary
        )
    }

    func loadDictionary(for rawValue: String) async {
        guard loadedRawValue != rawValue else {
            return
        }

        let language = HangarItemLanguage.resolved(from: rawValue)
        requestedRawValue = rawValue

        guard language.translationLocaleIdentifier != nil else {
            dictionary = nil
            loadedRawValue = rawValue
            return
        }

        let loadedDictionary = await HostedHangarItemTranslationStore.shared.dictionary(
            for: language,
            using: HostedHangarItemTranslationClient(language: language)
        )

        guard requestedRawValue == rawValue else {
            return
        }

        dictionary = loadedDictionary
        loadedRawValue = rawValue
    }
}
