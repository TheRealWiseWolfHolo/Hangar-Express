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
    struct Ship: Hashable, Sendable {
        let id: Int
        let name: String
        let manufacturer: String?
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

    private let shipsByKey: [String: Ship]
    private let mirroredImageURLsBySource: [String: URL]

    init(ships: [Ship]) {
        self.ships = ships

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

                return RSIShipCatalog.Ship(
                    id: id,
                    name: ship.name?.nilIfEmpty ?? ship.title?.nilIfEmpty ?? "Unknown Ship",
                    manufacturer: ship.manufacturer?.nilIfEmpty,
                    msrpUSD: ship.msrpUSD,
                    msrpLabel: ship.msrpLabel?.nilIfEmpty,
                    type: ship.type?.nilIfEmpty,
                    focus: ship.focus?.nilIfEmpty,
                    minCrew: ship.minCrew,
                    maxCrew: ship.maxCrew,
                    imageURL: ship.thumbnailURL,
                    sourceImageURL: ship.sourceThumbnailURL
                )
            }
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

    struct ShipDetail: Hashable, Sendable {
        let name: String
        let manufacturer: String?
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
        let pageURL: URL?
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
    }

    let ships: [ShipDetail]

    private let shipsByKey: [String: ShipDetail]

    init(ships: [ShipDetail]) {
        self.ships = ships

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
                RSIShipDetailCatalog.ShipDetail(
                    name: ship.name,
                    manufacturer: ship.manufacturer?.nilIfEmpty,
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
                    pageURL: ship.pageURL,
                    unavailableReason: ship.unavailableReason?.nilIfEmpty
                )
            }
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
    public static let primaryBaseURL = URL(string: "https://starcitizen-info.remote.example.invalid")!
    public static let fallbackBaseURL = URL(string: "https://fallback.example.invalid")!

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
    let ships: [RemoteHostedShipDetail]
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
    let pageURL: URL?
    let unavailableReason: String?

    enum CodingKeys: String, CodingKey {
        case name
        case manufacturer
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
        case pageURL = "pageUrl"
        case unavailableReason
    }
}

private struct RemoteHostedShipCatalogPayload: Decodable {
    let ships: [RemoteHostedShip]
}

private struct RemoteHostedShip: Decodable {
    let id: String
    let title: String?
    let name: String?
    let manufacturer: String?
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
