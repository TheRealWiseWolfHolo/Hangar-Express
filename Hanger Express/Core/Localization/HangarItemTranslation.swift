import Foundation
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

    let locale: String
    let version: Int
    let generatedAt: String?
    let entries: [Entry]
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
            return source
        }

        return "\(source) \(translatedSource)"
    }

    func searchableText(for sources: [String]) -> String {
        sources
            .map(searchableText(for:))
            .joined(separator: " ")
    }
}
