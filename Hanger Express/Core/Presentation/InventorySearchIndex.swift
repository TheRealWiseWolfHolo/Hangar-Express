import Foundation

/// Immutable copy-on-write translation inputs for a background index build.
/// The completed index retains strings, not this whole mutable service cache.
nonisolated struct InventoryTranslationContext: Sendable {
    let translator: HangarItemTranslator
    let translations: [CacheKey: String]
    func displayText(_ source: String) -> String {
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return source }
        let strict = translator.translated(trimmed)
        if strict != trimmed { return strict }
        guard translator.isEnabled, let locale = translator.language.translationLocaleIdentifier else { return source }
        if let cached = translations[CacheKey(source: trimmed, targetLocale: locale, dictionaryVersion: translator.dictionary?.version)] {
            return translator.normalizedMachineTranslationSpacing(cached, source: trimmed)
        }
        let protected = translator.replacingProtectedTerms(in: trimmed)
        return protected == trimmed ? source : protected
    }
    func text(_ source: String) -> String {
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return source }
        return [trimmed, translator.searchableText(for: trimmed), displayText(trimmed)].joined(separator: " ")
    }
    func text(_ sources: [String]) -> String { sources.map(text).joined(separator: " ") }
    func optional(_ source: String?) -> String? {
        guard let source = source?.trimmingCharacters(in: .whitespacesAndNewlines), !source.isEmpty else { return nil }
        return text(source)
    }
    func package(_ package: HangarPackage, upgraded: Bool) -> String {
        let titles = package.contents.flatMap { item -> [String] in
            guard let pricing = item.upgradePricing else { return [item.title] }
            return [item.title, pricing.sourceShipName, pricing.targetShipName]
        }
        return [text(package.title), text(package.debugDisplayTitle(showsUpgradedShipInHangar: upgraded)),
                package.status, package.searchableInsuranceText, text(titles)].joined(separator: " ").localizedLowercase
    }
    func fleet(_ ship: FleetShip) -> String {
        [text(ship.displayName), text(ship.manufacturer), text(FleetPresentationFormatter.manufacturerDisplayName(ship.manufacturer)),
         text(ship.role), text(ship.roleCategories), ship.insurance, text(ship.sourcePackageName)].joined(separator: " ").localizedLowercase
    }
    func buyback(_ pledge: BuybackPledge) -> String {
        [text(pledge.title), pledge.displayedNotes, optional(pledge.sourceRawInfo?.titleText),
         pledge.sourceRawInfo?.containsText, pledge.sourceRawInfo?.articleText]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            .joined(separator: " ").localizedLowercase
    }
}

nonisolated struct InventorySearchQuery: Sendable {
    let value: String
    let isASCII: Bool
    var isEmpty: Bool { value.isEmpty }
    init(_ value: String) {
        self.value = value.trimmingCharacters(in: .whitespacesAndNewlines).localizedLowercase.precomposedStringWithCanonicalMapping
        isASCII = self.value.utf8.allSatisfy { $0 < 128 }
    }
}

/// Literal search is a fast rejection over canonically normalized strings.
/// Non-ASCII matches still use Swift's grapheme-aware contains semantics, so a
/// component of a joined emoji or combining character cannot become a new match.
nonisolated struct InventorySearchText: Sendable, Equatable {
    let value: String
    private let isASCII: Bool
    init(_ value: String) {
        self.value = value.precomposedStringWithCanonicalMapping
        isASCII = self.value.utf8.allSatisfy { $0 < 128 }
    }
    func contains(_ query: InventorySearchQuery) -> Bool {
        guard value.range(of: query.value, options: .literal) != nil else { return false }
        if isASCII && query.isASCII { return true }
        return value.contains(query.value)
    }
    func contains(_ query: String) -> Bool { contains(InventorySearchQuery(query)) }
}

nonisolated enum InventorySearchSection: String, Hashable, Sendable { case hangar, fleet, buyback }

nonisolated struct InventorySearchKey: Hashable, Sendable {
    let presentation: InventoryPresentationKey
    let language: String
    let dictionaryLocale: String?
    let dictionaryVersion: Int?
    let cacheGeneration: Int
    let upgradedNames: Bool
    let section: InventorySearchSection
    init(presentation: InventoryPresentationKey, language: String, dictionaryLocale: String?, dictionaryVersion: Int?,
         cacheGeneration: Int, upgradedNames: Bool, section: InventorySearchSection = .buyback) {
        self.presentation = presentation; self.language = language; self.dictionaryLocale = dictionaryLocale
        self.dictionaryVersion = dictionaryVersion; self.cacheGeneration = cacheGeneration
        self.upgradedNames = upgradedNames; self.section = section
    }
}

nonisolated struct InventorySearchIndex: Sendable {
    let key: InventorySearchKey
    let packages: [String: InventorySearchText]
    let fleet: [String: [InventorySearchText]]
    let buyback: [String: InventorySearchText]
    static func build(presentation: InventoryPresentation, context: InventoryTranslationContext, key: InventorySearchKey) throws -> Self {
        var packages: [String: InventorySearchText] = [:], fleet: [String: [InventorySearchText]] = [:], buyback: [String: InventorySearchText] = [:]
        if key.section == .hangar {
            for (offset, group) in presentation.packages.enumerated() {
                if offset % 64 == 0 { try Task.checkCancellation() }
                packages[group.id] = InventorySearchText(context.package(group.representative, upgraded: key.upgradedNames))
            }
        }
        if key.section == .fleet {
            for (offset, group) in presentation.fleet.enumerated() {
                if offset % 64 == 0 { try Task.checkCancellation() }
                fleet[group.id] = group.ships.map { InventorySearchText(context.fleet($0)) }
            }
        }
        if key.section == .buyback {
            for (offset, group) in presentation.buyback.enumerated() {
                if offset % 64 == 0 { try Task.checkCancellation() }
                buyback[group.id] = InventorySearchText(context.buyback(group.representative))
            }
        }
        try Task.checkCancellation()
        return Self(key: key, packages: packages, fleet: fleet, buyback: buyback)
    }
}

/// One current context per inventory section, at most three in total.
/// No cache of arbitrary query combinations is retained.
actor InventorySearchBuilder {
    private var entries: [InventorySearchIndex] = []
    private(set) var buildCount = 0
    var cachedContextCount: Int { entries.count }
    func index(presentation: InventoryPresentation, context: InventoryTranslationContext, key: InventorySearchKey) throws -> InventorySearchIndex {
        try Task.checkCancellation()
        if let value = entries.first(where: { $0.key == key }) { return value }
        assert(!Thread.isMainThread)
        let value = try PerformanceTrace.measure("InventorySearchIndex") { try InventorySearchIndex.build(presentation: presentation, context: context, key: key) }
        entries.removeAll { $0.key.presentation.accountID != key.presentation.accountID || $0.key.section == key.section }
        buildCount += 1
        entries.append(value)
        if entries.count > 3 { entries.removeFirst(entries.count - 3) }
        return value
    }
    func clear() { entries.removeAll() }
}

nonisolated struct InventoryQuerySignature: Equatable {
    let presentation: InventoryPresentationKey?
    let search: InventorySearchKey?
    let query: String
    let requiredFlags: InventoryFilterFlags
}
