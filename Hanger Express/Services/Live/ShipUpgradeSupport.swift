import Foundation

struct ShipUpgradePath: Hashable, Sendable {
    let sourceShipName: String
    let targetShipName: String
}

enum UpgradeTitleParser {
    static func parse(_ rawTitle: String) -> ShipUpgradePath? {
        let cleaned = sanitizeTitle(rawTitle)

        guard let separatorRange = cleaned.range(
            of: " to ",
            options: [.caseInsensitive, .diacriticInsensitive]
        ) else {
            return nil
        }

        let source = cleanShipSegment(String(cleaned[..<separatorRange.lowerBound]))
        let target = cleanShipSegment(String(cleaned[separatorRange.upperBound...]))

        guard !source.isEmpty, !target.isEmpty else {
            return nil
        }

        return ShipUpgradePath(sourceShipName: source, targetShipName: target)
    }

    static func normalizedShipKey(_ rawName: String) -> String {
        let lowercase = stripManufacturerPrefix(from: rawName)
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .lowercased()

        let sanitizedScalars = lowercase.unicodeScalars.map { scalar -> String in
            CharacterSet.alphanumerics.contains(scalar) ? String(scalar) : " "
        }

        let normalizedKey = sanitizedScalars
            .joined()
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")

        return canonicalizedShipKey(normalizedKey)
    }

    static func stripManufacturerPrefix(from rawName: String) -> String {
        let trimmed = rawName.trimmingCharacters(in: .whitespacesAndNewlines)

        for manufacturer in manufacturerPrefixes {
            if trimmed.range(of: manufacturer + " ", options: [.anchored, .caseInsensitive]) != nil {
                return String(trimmed.dropFirst(manufacturer.count + 1))
            }
        }

        return trimmed
    }

    private static func sanitizeTitle(_ rawTitle: String) -> String {
        rawTitle
            .replacingOccurrences(of: "→", with: " to ")
            .replacingOccurrences(of: "->", with: " to ")
            .replacingOccurrences(
                of: #"(?i)\b(ship\s+upgrade|upgrade|ccu)\b"#,
                with: "",
                options: .regularExpression
            )
            .replacingOccurrences(of: #"^[\s\-\:\|]+"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func cleanShipSegment(_ segment: String) -> String {
        segment
            .replacingOccurrences(of: #"^[\s\-\:\|]+"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"[\s\-\:\|]+$"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static let manufacturerPrefixes = [
        "Aegis Dynamics",
        "Anvil Aerospace",
        "Argo Astronautics",
        "Crusader Industries",
        "Drake Interplanetary",
        "Gatac Manufacture",
        "Greycat Industrial",
        "Kruger Intergalactic",
        "Origin Jumpworks",
        "Roberts Space Industries",
        "Aegis",
        "Anvil",
        "ARGO",
        "Aopoa",
        "Banu",
        "Consolidated Outland",
        "Crusader",
        "Drake",
        "Esperia",
        "Gatac",
        "GREY",
        "Grey's Market",
        "Greycat",
        "Kruger",
        "MISC",
        "Mirai",
        "Origin",
        "RSI",
        "Tumbril",
        "Vanduul"
    ]

    private static func canonicalizedShipKey(_ rawKey: String) -> String {
        guard !rawKey.isEmpty else {
            return rawKey
        }

        let tokens = rawKey
            .split(separator: " ")
            .map(String.init)

        guard !tokens.isEmpty else {
            return rawKey
        }

        var normalizedTokens: [String] = []
        normalizedTokens.reserveCapacity(tokens.count)

        var index = 0
        while index < tokens.count {
            let token = tokens[index]

            if token == "mk",
               index + 1 < tokens.count,
               let normalizedMark = normalizedMarkValue(for: tokens[index + 1]) {
                normalizedTokens.append("mk")
                normalizedTokens.append(normalizedMark)
                index += 2
                continue
            }

            if token.hasPrefix("mk"),
               let normalizedMark = normalizedMarkValue(for: String(token.dropFirst(2))) {
                normalizedTokens.append("mk")
                normalizedTokens.append(normalizedMark)
                index += 1
                continue
            }

            if token == "superhornet" {
                normalizedTokens.append("super")
                normalizedTokens.append("hornet")
                index += 1
                continue
            }

            normalizedTokens.append(token)
            index += 1
        }

        let canonicalKey = normalizedTokens.joined(separator: " ")
        return legacyShipAliases[canonicalKey] ?? canonicalKey
    }

    private static func normalizedMarkValue(for token: String) -> String? {
        [
            "1": "i",
            "2": "ii",
            "3": "iii",
            "4": "iv",
            "5": "v",
            "6": "vi",
            "7": "vii",
            "8": "viii",
            "9": "ix",
            "10": "x"
        ][token]
    }

    private static let legacyShipAliases = [
        "dragonfly star kitten edition": "dragonfly black",
        "idris m frigate": "idris m",
        "idris p frigate": "idris p",
        "f7c m hornet mk i": "f7c m super hornet mk i",
        "f7c m hornet mk ii": "f7c m super hornet mk ii",
        "f7c m hornet heartseeker mk i": "f7c m super hornet heartseeker mk i",
        "f7c m hornet heartseeker mk ii": "f7c m super hornet heartseeker mk ii"
    ]
}

struct RSIShipCatalog: Sendable {
    struct ManufacturerAsset: Hashable, Sendable {
        let path: String
        let primaryURL: URL?
        let fallbackURL: URL?

        var rasterPreferredURL: URL? {
            if let primaryURL, primaryURL.isSupportedManufacturerLogoURL {
                return primaryURL
            }

            if let fallbackURL, fallbackURL.isSupportedManufacturerLogoURL {
                return fallbackURL
            }

            return nil
        }
    }

    struct ManufacturerLogos: Hashable, Sendable {
        let `default`: ManufacturerAsset?
        let onLightBackground: ManufacturerAsset?
        let onDarkBackground: ManufacturerAsset?
        let variants: [String: ManufacturerAsset]

        func preferredDisplayURL(preferLightOnDarkBackground: Bool) -> URL? {
            let orderedCandidates: [ManufacturerAsset?]

            if preferLightOnDarkBackground {
                orderedCandidates = [
                    variants["white"],
                    onDarkBackground,
                    `default`,
                    onLightBackground
                ]
            } else {
                orderedCandidates = [
                    `default`,
                    onLightBackground,
                    onDarkBackground,
                    variants["white"]
                ]
            }

            for candidate in orderedCandidates {
                if let url = candidate?.rasterPreferredURL {
                    return url
                }
            }

            for variantKey in preferredVariantKeys(preferLightOnDarkBackground: preferLightOnDarkBackground) {
                if let url = variants[variantKey]?.rasterPreferredURL {
                    return url
                }
            }

            return nil
        }

        private func preferredVariantKeys(preferLightOnDarkBackground: Bool) -> [String] {
            if preferLightOnDarkBackground {
                return ["light", "color", "black", "dark", "primary", "primary-black"]
            }

            return ["color", "black", "dark", "light", "primary", "primary-black"]
        }
    }

    struct Manufacturer: Hashable, Sendable {
        let slug: String
        let name: String
        let aliases: [String]
        let logos: ManufacturerLogos?
    }

    struct Ship: Hashable, Sendable {
        let id: Int
        let name: String
        let manufacturer: String?
        let manufacturerSlug: String?
        let manufacturerLogoURL: URL?
        let msrpUSD: Decimal?
        let msrpLabel: String?
        let type: String?
        let focus: String?
        let minCrew: Int?
        let maxCrew: Int?
        let imageURL: URL?
        let sourceImageURL: URL?

        init(
            id: Int,
            name: String,
            manufacturer: String? = nil,
            manufacturerSlug: String? = nil,
            manufacturerLogoURL: URL? = nil,
            msrpUSD: Decimal?,
            msrpLabel: String? = nil,
            type: String? = nil,
            focus: String? = nil,
            minCrew: Int? = nil,
            maxCrew: Int? = nil,
            imageURL: URL?,
            sourceImageURL: URL? = nil
        ) {
            self.id = id
            self.name = name
            self.manufacturer = manufacturer
            self.manufacturerSlug = manufacturerSlug
            self.manufacturerLogoURL = manufacturerLogoURL
            self.msrpUSD = msrpUSD
            self.msrpLabel = msrpLabel
            self.type = type
            self.focus = focus
            self.minCrew = minCrew
            self.maxCrew = maxCrew
            self.imageURL = imageURL
            self.sourceImageURL = sourceImageURL
        }

        var roleSummary: String? {
            FleetRoleFormatter.summary(type: type, focus: focus)
        }

        var roleCategories: [String] {
            FleetRoleFormatter.categories(type: type, focus: focus)
        }
    }

    let ships: [Ship]
    let manufacturers: [Manufacturer]

    private let shipsByKey: [String: Ship]
    private let mirroredImageURLsBySource: [String: URL]
    private let manufacturersBySlug: [String: Manufacturer]
    private let manufacturersByName: [String: Manufacturer]

    init(ships: [Ship], manufacturers: [Manufacturer] = []) {
        self.ships = ships
        self.manufacturers = manufacturers

        var keyedShips: [String: Ship] = [:]
        var mirroredImages: [String: URL] = [:]
        for ship in ships {
            let directKey = UpgradeTitleParser.normalizedShipKey(ship.name)
            keyedShips[directKey] = keyedShips[directKey] ?? ship

            let strippedKey = UpgradeTitleParser.normalizedShipKey(
                UpgradeTitleParser.stripManufacturerPrefix(from: ship.name)
            )
            keyedShips[strippedKey] = keyedShips[strippedKey] ?? ship

            if let sourceImageURL = ship.sourceImageURL,
               let mirroredImageURL = ship.imageURL,
               sourceImageURL != mirroredImageURL {
                mirroredImages[sourceImageURL.absoluteString] = mirroredImageURL
            }
        }

        shipsByKey = keyedShips
        mirroredImageURLsBySource = mirroredImages
        manufacturersBySlug = Dictionary(
            uniqueKeysWithValues: manufacturers.map { ($0.slug.localizedLowercase, $0) }
        )
        manufacturersByName = Dictionary(
            uniqueKeysWithValues: manufacturers.map { ($0.name.localizedLowercase, $0) }
        )
    }

    func matchShip(named rawName: String) -> Ship? {
        let directKey = UpgradeTitleParser.normalizedShipKey(rawName)
        if let directMatch = shipsByKey[directKey] {
            return directMatch
        }

        let strippedKey = UpgradeTitleParser.normalizedShipKey(
            UpgradeTitleParser.stripManufacturerPrefix(from: rawName)
        )
        return shipsByKey[strippedKey]
    }

    func mirroredAssetURL(for originalURL: URL?) -> URL? {
        guard let originalURL else {
            return nil
        }

        return mirroredImageURLsBySource[originalURL.absoluteString]
    }

    func manufacturer(named name: String?, slug: String?) -> Manufacturer? {
        if let slug = slug?.trimmingCharacters(in: .whitespacesAndNewlines).localizedLowercase,
           let manufacturer = manufacturersBySlug[slug] {
            return manufacturer
        }

        if let normalizedName = name?.trimmingCharacters(in: .whitespacesAndNewlines).localizedLowercase,
           let manufacturer = manufacturersByName[normalizedName] {
            return manufacturer
        }

        return nil
    }
}

struct HostedShipCatalogClient: Sendable {
    let urls: [URL]
    let urlSession: URLSession

    init(
        urls: [URL] = HostedShipFeedEndpoints.catalogURLs,
        urlSession: URLSession = .shared
    ) {
        self.urls = urls
        self.urlSession = urlSession
    }

    func fetchCatalog() async throws -> RSIShipCatalog {
        var lastError: Error?

        for url in urls {
            do {
                let (data, response) = try await urlSession.data(for: Self.makeRequest(for: url))

                if let httpResponse = response as? HTTPURLResponse,
                   !(200 ..< 300).contains(httpResponse.statusCode) {
                    throw HostedShipCatalogError.httpStatus(httpResponse.statusCode)
                }

                return try Self.decodeCatalog(from: data)
            } catch {
                lastError = error
            }
        }

        throw lastError ?? HostedShipCatalogError.httpStatus(-1)
    }

    static func decodeCatalog(from data: Data) throws -> RSIShipCatalog {
        let payload = try JSONDecoder().decode(RemoteHostedShipCatalogPayload.self, from: data)
        return RSIShipCatalog(
            ships: payload.ships.compactMap { ship -> RSIShipCatalog.Ship? in
                guard let id = ship.numericID else {
                    return nil
                }

                let manufacturer = payload.manufacturer(named: ship.manufacturer, slug: ship.manufacturerSlug)

                return RSIShipCatalog.Ship(
                    id: id,
                    name: ship.name?.nilIfEmpty ?? ship.title?.nilIfEmpty ?? "Unknown Ship",
                    manufacturer: ship.manufacturer?.nilIfEmpty,
                    manufacturerSlug: ship.manufacturerSlug?.nilIfEmpty,
                    manufacturerLogoURL: manufacturer?.logos?.preferredDisplayURL(
                        preferLightOnDarkBackground: true
                    ),
                    msrpUSD: ship.msrpUSD,
                    msrpLabel: ship.msrpLabel?.nilIfEmpty,
                    type: ship.type?.nilIfEmpty,
                    focus: ship.focus?.nilIfEmpty,
                    minCrew: ship.minCrew,
                    maxCrew: ship.maxCrew,
                    imageURL: ship.thumbnailURL,
                    sourceImageURL: ship.sourceThumbnailURL
                )
            },
            manufacturers: payload.manufacturers.map { $0.catalogManufacturer }
        )
    }

    private static func makeRequest(for url: URL) -> URLRequest {
        URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
    }
}

enum HostedShipCatalogError: Error, LocalizedError {
    case httpStatus(Int)

    var errorDescription: String? {
        switch self {
        case let .httpStatus(statusCode):
            return "Hosted ship catalog returned HTTP \(statusCode)."
        }
    }
}

struct RSIShipDetailCatalog: Sendable {
    struct SpecItem: Hashable, Sendable, Codable {
        let label: String
        let value: String
    }

    struct TechnicalSection: Hashable, Sendable, Codable {
        let title: String
        let items: [SpecItem]
    }

    struct SpecificationItem: Hashable, Sendable, Codable {
        let name: String
        let internalName: String?
        let countLabel: String?
        let count: Int?
        let size: String?
        let sizeNumber: Int?
        let subtitle: String?
        let level: Int?
        let pageURL: URL?

        var quantityLabel: String? {
            if let countLabel = countLabel?.nilIfEmpty {
                return countLabel
            }

            return count.map { "\($0)x" }
        }

        init(
            name: String,
            internalName: String?,
            countLabel: String?,
            count: Int?,
            size: String?,
            sizeNumber: Int?,
            subtitle: String?,
            level: Int?,
            pageURL: URL?
        ) {
            self.name = name
            self.internalName = internalName
            self.countLabel = countLabel
            self.count = count
            self.size = size
            self.sizeNumber = sizeNumber
            self.subtitle = subtitle
            self.level = level
            self.pageURL = pageURL
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            name = try container.decodeIfPresent(String.self, forKey: .name)?.nilIfEmpty ?? "Component"
            internalName = try container.decodeIfPresent(String.self, forKey: .internalName)?.nilIfEmpty
            countLabel = try container.decodeIfPresent(String.self, forKey: .countLabel)?.nilIfEmpty
            count = try container.decodeIfPresent(Int.self, forKey: .count)
            size = try container.decodeIfPresent(String.self, forKey: .size)?.nilIfEmpty
            sizeNumber = try container.decodeIfPresent(Int.self, forKey: .sizeNumber)
            subtitle = try container.decodeIfPresent(String.self, forKey: .subtitle)?.nilIfEmpty
            level = try container.decodeIfPresent(Int.self, forKey: .level)
            pageURL = try container.decodeIfPresent(URL.self, forKey: .pageURL)
        }

        private enum CodingKeys: String, CodingKey {
            case name
            case internalName
            case countLabel
            case count
            case size
            case sizeNumber
            case subtitle
            case level
            case pageURL = "pageUrl"
        }
    }

    struct SizeSummary: Hashable, Sendable, Codable {
        let size: String?
        let sizeNumber: Int?
        let count: Int
        let entryCount: Int

        init(size: String?, sizeNumber: Int?, count: Int, entryCount: Int) {
            self.size = size
            self.sizeNumber = sizeNumber
            self.count = count
            self.entryCount = entryCount
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            size = try container.decodeIfPresent(String.self, forKey: .size)?.nilIfEmpty
            sizeNumber = try container.decodeIfPresent(Int.self, forKey: .sizeNumber)
            count = try container.decodeIfPresent(Int.self, forKey: .count) ?? 0
            entryCount = try container.decodeIfPresent(Int.self, forKey: .entryCount) ?? 0
        }
    }

    struct SectionSizeSummary: Hashable, Sendable, Codable {
        let tab: String
        let section: String
        let size: String?
        let sizeNumber: Int?
        let count: Int
        let entryCount: Int

        init(tab: String, section: String, size: String?, sizeNumber: Int?, count: Int, entryCount: Int) {
            self.tab = tab
            self.section = section
            self.size = size
            self.sizeNumber = sizeNumber
            self.count = count
            self.entryCount = entryCount
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            tab = try container.decodeIfPresent(String.self, forKey: .tab)?.nilIfEmpty ?? "Specifications"
            section = try container.decodeIfPresent(String.self, forKey: .section)?.nilIfEmpty ?? "Components"
            size = try container.decodeIfPresent(String.self, forKey: .size)?.nilIfEmpty
            sizeNumber = try container.decodeIfPresent(Int.self, forKey: .sizeNumber)
            count = try container.decodeIfPresent(Int.self, forKey: .count) ?? 0
            entryCount = try container.decodeIfPresent(Int.self, forKey: .entryCount) ?? 0
        }
    }

    struct SpecificationSummary: Hashable, Sendable, Codable {
        let totalEntries: Int
        let totalCount: Int
        let bySection: [SectionSizeSummary]
        let bySize: [SizeSummary]

        static let empty = SpecificationSummary(
            totalEntries: 0,
            totalCount: 0,
            bySection: [],
            bySize: []
        )

        init(
            totalEntries: Int,
            totalCount: Int,
            bySection: [SectionSizeSummary],
            bySize: [SizeSummary]
        ) {
            self.totalEntries = totalEntries
            self.totalCount = totalCount
            self.bySection = bySection
            self.bySize = bySize
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            totalEntries = try container.decodeIfPresent(Int.self, forKey: .totalEntries) ?? 0
            totalCount = try container.decodeIfPresent(Int.self, forKey: .totalCount) ?? 0
            bySection = try container.decodeIfPresent([SectionSizeSummary].self, forKey: .bySection) ?? []
            bySize = try container.decodeIfPresent([SizeSummary].self, forKey: .bySize) ?? []
        }
    }

    struct SpecificationSection: Hashable, Sendable, Codable {
        let tab: String
        let title: String
        let items: [SpecificationItem]
        let summaryBySize: [SizeSummary]

        init(tab: String, title: String, items: [SpecificationItem], summaryBySize: [SizeSummary]) {
            self.tab = tab
            self.title = title
            self.items = items
            self.summaryBySize = summaryBySize
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            tab = try container.decodeIfPresent(String.self, forKey: .tab)?.nilIfEmpty ?? "Specifications"
            title = try container.decodeIfPresent(String.self, forKey: .title)?.nilIfEmpty ?? "Components"
            items = try container.decodeIfPresent([SpecificationItem].self, forKey: .items) ?? []
            summaryBySize = try container.decodeIfPresent([SizeSummary].self, forKey: .summaryBySize) ?? []
        }
    }

    struct SpecificationEntry: Hashable, Sendable, Codable {
        let tab: String
        let section: String
        let name: String
        let internalName: String?
        let countLabel: String?
        let count: Int?
        let size: String?
        let sizeNumber: Int?
        let subtitle: String?
        let level: Int?
        let pageURL: URL?

        var item: SpecificationItem {
            SpecificationItem(
                name: name,
                internalName: internalName,
                countLabel: countLabel,
                count: count,
                size: size,
                sizeNumber: sizeNumber,
                subtitle: subtitle,
                level: level,
                pageURL: pageURL
            )
        }

        init(
            tab: String,
            section: String,
            name: String,
            internalName: String?,
            countLabel: String?,
            count: Int?,
            size: String?,
            sizeNumber: Int?,
            subtitle: String?,
            level: Int?,
            pageURL: URL?
        ) {
            self.tab = tab
            self.section = section
            self.name = name
            self.internalName = internalName
            self.countLabel = countLabel
            self.count = count
            self.size = size
            self.sizeNumber = sizeNumber
            self.subtitle = subtitle
            self.level = level
            self.pageURL = pageURL
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            tab = try container.decodeIfPresent(String.self, forKey: .tab)?.nilIfEmpty ?? "Specifications"
            section = try container.decodeIfPresent(String.self, forKey: .section)?.nilIfEmpty ?? "Components"
            name = try container.decodeIfPresent(String.self, forKey: .name)?.nilIfEmpty ?? "Component"
            internalName = try container.decodeIfPresent(String.self, forKey: .internalName)?.nilIfEmpty
            countLabel = try container.decodeIfPresent(String.self, forKey: .countLabel)?.nilIfEmpty
            count = try container.decodeIfPresent(Int.self, forKey: .count)
            size = try container.decodeIfPresent(String.self, forKey: .size)?.nilIfEmpty
            sizeNumber = try container.decodeIfPresent(Int.self, forKey: .sizeNumber)
            subtitle = try container.decodeIfPresent(String.self, forKey: .subtitle)?.nilIfEmpty
            level = try container.decodeIfPresent(Int.self, forKey: .level)
            pageURL = try container.decodeIfPresent(URL.self, forKey: .pageURL)
        }

        private enum CodingKeys: String, CodingKey {
            case tab
            case section
            case name
            case internalName
            case countLabel
            case count
            case size
            case sizeNumber
            case subtitle
            case level
            case pageURL = "pageUrl"
        }
    }

    struct ShipDetail: Hashable, Sendable {
        let name: String
        let manufacturer: String?
        let manufacturerSlug: String?
        let manufacturerLogoURL: URL?
        let career: String?
        let role: String?
        let size: String?
        let inGameStatus: String?
        let pledgeAvailability: String?
        let minCrew: Int?
        let maxCrew: Int?
        let description: String?
        let technicalSpecs: [SpecItem]
        let technicalSections: [TechnicalSection]
        let specificationSections: [SpecificationSection]
        let componentEntries: [SpecificationEntry]
        let weaponsUtilityEntries: [SpecificationEntry]
        let componentSummary: SpecificationSummary
        let weaponsUtilitySummary: SpecificationSummary
        let pageURL: URL?
        let spviewerPageURL: URL?
        let unavailableReason: String?

        var roleSummary: String? {
            FleetRoleFormatter.summary(type: career, focus: role)
        }

        var crewSummary: String? {
            switch (minCrew, maxCrew) {
            case let (minCrew?, maxCrew?) where minCrew != maxCrew:
                return "\(minCrew)-\(maxCrew)"
            case (_, let maxCrew?):
                return "\(maxCrew)"
            case (let minCrew?, _):
                return "\(minCrew)"
            default:
                return nil
            }
        }

        var isUnavailable: Bool {
            unavailableReason?.nilIfEmpty != nil
        }

        var sourceDetailURL: URL? {
            spviewerPageURL ?? pageURL
        }

        var hasSpecificationData: Bool {
            !specificationSections.isEmpty
                || !componentEntries.isEmpty
                || !weaponsUtilityEntries.isEmpty
        }

        var componentSections: [SpecificationSection] {
            specificationSections.filter { section in
                section.tab != "Weapons & Utility"
            }
        }

        var weaponsUtilitySections: [SpecificationSection] {
            specificationSections.filter { section in
                section.tab == "Weapons & Utility"
            }
        }

        var technicalSectionsForDisplay: [TechnicalSection] {
            let specificationTitles = Set(specificationSections.map(\.title))
            return technicalSections.filter { section in
                !specificationTitles.contains(section.title)
            }
        }
    }

    let ships: [ShipDetail]
    let manufacturers: [RSIShipCatalog.Manufacturer]

    private let shipsByKey: [String: ShipDetail]
    private let manufacturersBySlug: [String: RSIShipCatalog.Manufacturer]
    private let manufacturersByName: [String: RSIShipCatalog.Manufacturer]

    init(ships: [ShipDetail], manufacturers: [RSIShipCatalog.Manufacturer] = []) {
        self.ships = ships
        self.manufacturers = manufacturers

        var keyedShips: [String: ShipDetail] = [:]
        for ship in ships {
            let directKey = UpgradeTitleParser.normalizedShipKey(ship.name)
            keyedShips[directKey] = keyedShips[directKey] ?? ship

            let strippedKey = UpgradeTitleParser.normalizedShipKey(
                UpgradeTitleParser.stripManufacturerPrefix(from: ship.name)
            )
            keyedShips[strippedKey] = keyedShips[strippedKey] ?? ship
        }

        shipsByKey = keyedShips
        manufacturersBySlug = Dictionary(
            uniqueKeysWithValues: manufacturers.map { ($0.slug.localizedLowercase, $0) }
        )
        manufacturersByName = Dictionary(
            uniqueKeysWithValues: manufacturers.map { ($0.name.localizedLowercase, $0) }
        )
    }

    func matchShip(named rawName: String) -> ShipDetail? {
        let directKey = UpgradeTitleParser.normalizedShipKey(rawName)
        if let directMatch = shipsByKey[directKey] {
            return directMatch
        }

        let strippedKey = UpgradeTitleParser.normalizedShipKey(
            UpgradeTitleParser.stripManufacturerPrefix(from: rawName)
        )
        return shipsByKey[strippedKey]
    }

    func manufacturer(named name: String?, slug: String?) -> RSIShipCatalog.Manufacturer? {
        if let slug = slug?.trimmingCharacters(in: .whitespacesAndNewlines).localizedLowercase,
           let manufacturer = manufacturersBySlug[slug] {
            return manufacturer
        }

        if let normalizedName = name?.trimmingCharacters(in: .whitespacesAndNewlines).localizedLowercase,
           let manufacturer = manufacturersByName[normalizedName] {
            return manufacturer
        }

        return nil
    }
}

struct HostedShipDetailCatalogClient: Sendable {
    let urls: [URL]
    let urlSession: URLSession

    init(
        urls: [URL] = HostedShipFeedEndpoints.detailCatalogURLs,
        urlSession: URLSession = .shared
    ) {
        self.urls = urls
        self.urlSession = urlSession
    }

    func fetchCatalog() async throws -> RSIShipDetailCatalog {
        var lastError: Error?

        for url in urls {
            do {
                let (data, response) = try await urlSession.data(for: Self.makeRequest(for: url))

                if let httpResponse = response as? HTTPURLResponse,
                   !(200 ..< 300).contains(httpResponse.statusCode) {
                    throw HostedShipCatalogError.httpStatus(httpResponse.statusCode)
                }

                return try Self.decodeCatalog(from: data)
            } catch {
                lastError = error
            }
        }

        throw lastError ?? HostedShipCatalogError.httpStatus(-1)
    }

    static func decodeCatalog(from data: Data) throws -> RSIShipDetailCatalog {
        let payload = try JSONDecoder().decode(RemoteHostedShipDetailCatalogPayload.self, from: data)
        return RSIShipDetailCatalog(
            ships: payload.ships.map { ship in
                let manufacturer = payload.manufacturer(named: ship.manufacturer, slug: ship.manufacturerSlug)
                return RSIShipDetailCatalog.ShipDetail(
                    name: ship.name,
                    manufacturer: ship.manufacturer?.nilIfEmpty,
                    manufacturerSlug: ship.manufacturerSlug?.nilIfEmpty,
                    manufacturerLogoURL: manufacturer?.logos?.preferredDisplayURL(
                        preferLightOnDarkBackground: true
                    ),
                    career: ship.career?.nilIfEmpty,
                    role: ship.role?.nilIfEmpty,
                    size: ship.size?.nilIfEmpty,
                    inGameStatus: ship.inGameStatus?.nilIfEmpty,
                    pledgeAvailability: ship.pledgeAvailability?.nilIfEmpty,
                    minCrew: ship.minCrew,
                    maxCrew: ship.maxCrew,
                    description: ship.description?.nilIfEmpty,
                    technicalSpecs: ship.technicalSpecs.map {
                        RSIShipDetailCatalog.SpecItem(
                            label: $0.label,
                            value: $0.value?.nilIfEmpty ?? ""
                        )
                    },
                    technicalSections: ship.technicalSections.map { section in
                        RSIShipDetailCatalog.TechnicalSection(
                            title: section.title,
                            items: section.items.map {
                                RSIShipDetailCatalog.SpecItem(
                                    label: $0.label,
                                    value: $0.value?.nilIfEmpty ?? ""
                                )
                            }
                        )
                    },
                    specificationSections: ship.specificationSections,
                    componentEntries: ship.componentEntries,
                    weaponsUtilityEntries: ship.weaponsUtilityEntries,
                    componentSummary: ship.componentSummary,
                    weaponsUtilitySummary: ship.weaponsUtilitySummary,
                    pageURL: ship.pageURL,
                    spviewerPageURL: ship.spviewerPageURL,
                    unavailableReason: ship.unavailableReason?.nilIfEmpty
                )
            },
            manufacturers: payload.manufacturers.map { $0.catalogManufacturer }
        )
    }

    private static func makeRequest(for url: URL) -> URLRequest {
        URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
    }
}

actor HostedShipDetailCatalogStore {
    static let shared = HostedShipDetailCatalogStore()

    private var cachedCatalog: RSIShipDetailCatalog?

    func catalog(using client: HostedShipDetailCatalogClient) async throws -> RSIShipDetailCatalog {
        if let cachedCatalog {
            return cachedCatalog
        }

        let catalog = try await client.fetchCatalog()
        cachedCatalog = catalog
        return catalog
    }

    func clear() {
        cachedCatalog = nil
    }
}

public enum HostedShipFeedEndpoints {
    public static let primaryBaseURL = URL(string: "https://starcitizen-info.pages.dev")!
    public static let fallbackBaseURL = URL(string: "https://therealwisewolfholo.github.io/StarCitizen-Info")!

    public static let catalogURLs: [URL] = [
        primaryBaseURL.appendingPathComponent("ships.json"),
        fallbackBaseURL.appendingPathComponent("ships.json")
    ]

    public static let detailCatalogURLs: [URL] = [
        primaryBaseURL.appendingPathComponent("ship-details.json"),
        fallbackBaseURL.appendingPathComponent("ship-details.json")
    ]
}

private struct RemoteHostedShipDetailCatalogPayload: Decodable {
    let manufacturers: [RemoteHostedManufacturer]
    let ships: [RemoteHostedShipDetail]

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        manufacturers = try container.decodeIfPresent([RemoteHostedManufacturer].self, forKey: .manufacturers) ?? []
        ships = try container.decode([RemoteHostedShipDetail].self, forKey: .ships)
    }

    func manufacturer(named name: String?, slug: String?) -> RSIShipCatalog.Manufacturer? {
        if let normalizedSlug = slug?.trimmingCharacters(in: .whitespacesAndNewlines).localizedLowercase,
           let match = manufacturers.first(where: { $0.slug.localizedLowercase == normalizedSlug }) {
            return match.catalogManufacturer
        }

        if let normalizedName = name?.trimmingCharacters(in: .whitespacesAndNewlines).localizedLowercase,
           let match = manufacturers.first(where: { $0.name.localizedLowercase == normalizedName }) {
            return match.catalogManufacturer
        }

        return nil
    }

    private enum CodingKeys: String, CodingKey {
        case manufacturers
        case ships
    }
}

private struct RemoteHostedShipDetail: Decodable {
    struct SpecItem: Decodable {
        let label: String
        let value: String?
    }

    struct TechnicalSection: Decodable {
        let title: String
        let items: [SpecItem]
    }

    let name: String
    let manufacturer: String?
    let manufacturerSlug: String?
    let career: String?
    let role: String?
    let size: String?
    let inGameStatus: String?
    let pledgeAvailability: String?
    let minCrew: Int?
    let maxCrew: Int?
    let description: String?
    let technicalSpecs: [SpecItem]
    let technicalSections: [TechnicalSection]
    let specificationSections: [RSIShipDetailCatalog.SpecificationSection]
    let componentEntries: [RSIShipDetailCatalog.SpecificationEntry]
    let weaponsUtilityEntries: [RSIShipDetailCatalog.SpecificationEntry]
    let componentSummary: RSIShipDetailCatalog.SpecificationSummary
    let weaponsUtilitySummary: RSIShipDetailCatalog.SpecificationSummary
    let pageURL: URL?
    let spviewerPageURL: URL?
    let unavailableReason: String?

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        manufacturer = try container.decodeIfPresent(String.self, forKey: .manufacturer)
        manufacturerSlug = try container.decodeIfPresent(String.self, forKey: .manufacturerSlug)
        career = try container.decodeIfPresent(String.self, forKey: .career)
        role = try container.decodeIfPresent(String.self, forKey: .role)
        size = try container.decodeIfPresent(String.self, forKey: .size)
        inGameStatus = try container.decodeIfPresent(String.self, forKey: .inGameStatus)
        pledgeAvailability = try container.decodeIfPresent(String.self, forKey: .pledgeAvailability)
        minCrew = try container.decodeIfPresent(Int.self, forKey: .minCrew)
        maxCrew = try container.decodeIfPresent(Int.self, forKey: .maxCrew)
        description = try container.decodeIfPresent(String.self, forKey: .description)
        technicalSpecs = try container.decodeIfPresent([SpecItem].self, forKey: .technicalSpecs) ?? []
        technicalSections = try container.decodeIfPresent([TechnicalSection].self, forKey: .technicalSections) ?? []
        specificationSections = try container.decodeIfPresent(
            [RSIShipDetailCatalog.SpecificationSection].self,
            forKey: .specificationSections
        ) ?? []
        componentEntries = try container.decodeIfPresent(
            [RSIShipDetailCatalog.SpecificationEntry].self,
            forKey: .componentEntries
        ) ?? []
        weaponsUtilityEntries = try container.decodeIfPresent(
            [RSIShipDetailCatalog.SpecificationEntry].self,
            forKey: .weaponsUtilityEntries
        ) ?? []
        componentSummary = try container.decodeIfPresent(
            RSIShipDetailCatalog.SpecificationSummary.self,
            forKey: .componentSummary
        ) ?? .empty
        weaponsUtilitySummary = try container.decodeIfPresent(
            RSIShipDetailCatalog.SpecificationSummary.self,
            forKey: .weaponsUtilitySummary
        ) ?? .empty
        pageURL = try container.decodeIfPresent(URL.self, forKey: .pageURL)
        spviewerPageURL = try container.decodeIfPresent(URL.self, forKey: .spviewerPageURL)
        unavailableReason = try container.decodeIfPresent(String.self, forKey: .unavailableReason)
    }

    enum CodingKeys: String, CodingKey {
        case name
        case manufacturer
        case manufacturerSlug
        case career
        case role
        case size
        case inGameStatus
        case pledgeAvailability
        case minCrew
        case maxCrew
        case description
        case technicalSpecs
        case technicalSections
        case specificationSections
        case componentEntries
        case weaponsUtilityEntries
        case componentSummary
        case weaponsUtilitySummary
        case pageURL = "pageUrl"
        case spviewerPageURL = "spviewerPageUrl"
        case unavailableReason
    }
}

private struct RemoteHostedShipCatalogPayload: Decodable {
    let manufacturers: [RemoteHostedManufacturer]
    let ships: [RemoteHostedShip]

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        manufacturers = try container.decodeIfPresent([RemoteHostedManufacturer].self, forKey: .manufacturers) ?? []
        ships = try container.decode([RemoteHostedShip].self, forKey: .ships)
    }

    func manufacturer(named name: String?, slug: String?) -> RSIShipCatalog.Manufacturer? {
        if let normalizedSlug = slug?.trimmingCharacters(in: .whitespacesAndNewlines).localizedLowercase,
           let match = manufacturers.first(where: { $0.slug.localizedLowercase == normalizedSlug }) {
            return match.catalogManufacturer
        }

        if let normalizedName = name?.trimmingCharacters(in: .whitespacesAndNewlines).localizedLowercase,
           let match = manufacturers.first(where: { $0.name.localizedLowercase == normalizedName }) {
            return match.catalogManufacturer
        }

        return nil
    }

    private enum CodingKeys: String, CodingKey {
        case manufacturers
        case ships
    }
}

private struct RemoteHostedShip: Decodable {
    let id: String
    let title: String?
    let name: String?
    let manufacturer: String?
    let manufacturerSlug: String?
    let msrpUSD: Decimal?
    let msrpLabel: String?
    let type: String?
    let focus: String?
    let minCrew: Int?
    let maxCrew: Int?
    let thumbnailURL: URL?
    let sourceThumbnailURL: URL?

    enum CodingKeys: String, CodingKey {
        case id
        case title
        case name
        case manufacturer
        case manufacturerSlug
        case msrpUSD = "msrpUsd"
        case msrpLabel
        case type
        case focus
        case minCrew
        case maxCrew
        case thumbnailURL = "thumbnailUrl"
        case sourceThumbnailURL = "sourceThumbnailUrl"
    }

    var numericID: Int? {
        Int(id)
    }
}

private struct RemoteHostedManufacturer: Decodable {
    struct Logos: Decodable {
        let `default`: RemoteHostedManufacturerAsset?
        let onLightBackground: RemoteHostedManufacturerAsset?
        let onDarkBackground: RemoteHostedManufacturerAsset?
        let variants: [String: RemoteHostedManufacturerAsset]

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            `default` = try container.decodeIfPresent(RemoteHostedManufacturerAsset.self, forKey: .default)
            onLightBackground = try container.decodeIfPresent(RemoteHostedManufacturerAsset.self, forKey: .onLightBackground)
            onDarkBackground = try container.decodeIfPresent(RemoteHostedManufacturerAsset.self, forKey: .onDarkBackground)
            variants = try container.decodeIfPresent([String: RemoteHostedManufacturerAsset].self, forKey: .variants) ?? [:]
        }

        private enum CodingKeys: String, CodingKey {
            case `default`
            case onLightBackground
            case onDarkBackground
            case variants
        }
    }

    let slug: String
    let name: String
    let aliases: [String]
    let logos: Logos?

    var catalogManufacturer: RSIShipCatalog.Manufacturer {
        RSIShipCatalog.Manufacturer(
            slug: slug,
            name: name,
            aliases: aliases,
            logos: logos.map { logos in
                RSIShipCatalog.ManufacturerLogos(
                    default: logos.default?.catalogAsset,
                    onLightBackground: logos.onLightBackground?.catalogAsset,
                    onDarkBackground: logos.onDarkBackground?.catalogAsset,
                    variants: logos.variants.mapValues { $0.catalogAsset }
                )
            }
        )
    }

    enum CodingKeys: String, CodingKey {
        case slug
        case name
        case aliases
        case logos
    }
}

private struct RemoteHostedManufacturerAsset: Decodable {
    let path: String
    let primaryURL: URL?
    let fallbackURL: URL?

    var catalogAsset: RSIShipCatalog.ManufacturerAsset {
        RSIShipCatalog.ManufacturerAsset(
            path: path,
            primaryURL: primaryURL,
            fallbackURL: fallbackURL
        )
    }

    enum CodingKeys: String, CodingKey {
        case path
        case primaryURL = "primaryUrl"
        case fallbackURL = "fallbackUrl"
    }
}

enum FleetRoleFormatter {
    static func summary(type: String?, focus: String?) -> String? {
        let displayType = displayTypeName(for: type)
        let focusCategories = focusComponents(from: focus)

        if let displayType, !focusCategories.isEmpty {
            return "\(displayType): \(focusCategories.joined(separator: " | "))"
        }

        if let displayType {
            return displayType
        }

        return focusCategories
            .joined(separator: " | ")
            .nilIfEmpty
    }

    static func categories(type: String?, focus: String?) -> [String] {
        var categories: [String] = []

        if let displayType = displayTypeName(for: type) {
            categories.append(displayType)
        }

        categories.append(contentsOf: focusComponents(from: focus))

        var seen = Set<String>()
        return categories.filter { category in
            seen.insert(category.localizedLowercase).inserted
        }
    }

    private static func focusComponents(from rawFocus: String?) -> [String] {
        rawFocus?
            .split(separator: "/")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .compactMap(\.nilIfEmpty) ?? []
    }

    private static func displayTypeName(for rawType: String?) -> String? {
        guard let trimmedType = rawType?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty else {
            return nil
        }

        switch trimmedType.localizedLowercase {
        case "multi":
            return "Multi"
        case "ground":
            return "Ground"
        default:
            return trimmedType
                .replacingOccurrences(of: "-", with: " ")
                .split(separator: " ")
                .map { $0.localizedCapitalized }
                .joined(separator: " ")
        }
    }
}

enum FleetPresentationFormatter {
    static func roleSummary(role: String, categories: [String]) -> String? {
        let normalizedCategories = categories.compactMap(\.nilIfEmpty)
        if let formattedFromCategories = summary(from: normalizedCategories) {
            return formattedFromCategories
        }

        let trimmedRole = role.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedRole.isEmpty else {
            return nil
        }

        if trimmedRole.contains(":") {
            return trimmedRole
        }

        let parts = trimmedRole
            .split(separator: "/")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .compactMap(\.nilIfEmpty)

        return summary(from: parts) ?? trimmedRole
    }

    static func manufacturerDisplayName(_ rawManufacturer: String) -> String {
        let trimmed = rawManufacturer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return rawManufacturer
        }

        let canonicalNames: [String: String] = [
            "aegis": "Aegis Dynamics",
            "aegis dynamics": "Aegis Dynamics",
            "anvil": "Anvil Aerospace",
            "anvil aerospace": "Anvil Aerospace",
            "aopoa": "Aopoa",
            "argo": "Argo Astronautics",
            "argo astronauts": "Argo Astronautics",
            "argo astronautics": "Argo Astronautics",
            "banu": "Banu",
            "consolidated outland": "Consolidated Outland",
            "crusader": "Crusader Industries",
            "crusader industries": "Crusader Industries",
            "drake": "Drake Interplanetary",
            "drake interplanetary": "Drake Interplanetary",
            "esperia": "Esperia",
            "gatac": "Gatac Manufacture",
            "gatac manufacture": "Gatac Manufacture",
            "grey": "Grey's Market",
            "grey's market": "Grey's Market",
            "greycat": "Greycat Industrial",
            "greycat industrial": "Greycat Industrial",
            "kruger": "Kruger Intergalactic",
            "kruger intergalactic": "Kruger Intergalactic",
            "misc": "MISC",
            "mirai": "Mirai",
            "origin": "Origin Jumpworks",
            "origin jumpworks": "Origin Jumpworks",
            "rsi": "Roberts Space Industries",
            "roberts space industries": "Roberts Space Industries",
            "tumbril": "Tumbril",
            "vanduul": "Vanduul"
        ]

        return canonicalNames[trimmed.localizedLowercase] ?? trimmed
    }

    private static func summary(from categories: [String]) -> String? {
        guard let first = categories.first else {
            return nil
        }

        if categories.count == 1 {
            return first
        }

        return "\(first): \(categories.dropFirst().joined(separator: " | "))"
    }
}

private extension String {
    var nilIfEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

private extension URL {
    var isSupportedManufacturerLogoURL: Bool {
        let supportedExtensions: Set<String> = [
            "png",
            "jpg",
            "jpeg",
            "svg",
            "webp",
            "gif",
            "heic",
            "heif",
            "avif"
        ]

        return supportedExtensions.contains(pathExtension.localizedLowercase)
    }
}
