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

        return sanitizedScalars
            .joined()
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
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
        "Aegis",
        "Anvil",
        "ARGO",
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
        "Tumbril"
    ]
}

struct RSIShipCatalog: Sendable {
    struct Ship: Hashable, Sendable {
        let id: Int
        let name: String
        let manufacturer: String?
        let msrpUSD: Decimal?
        let type: String?
        let focus: String?
        let minCrew: Int?
        let maxCrew: Int?
        let imageURL: URL?

        init(
            id: Int,
            name: String,
            manufacturer: String? = nil,
            msrpUSD: Decimal?,
            type: String? = nil,
            focus: String? = nil,
            minCrew: Int? = nil,
            maxCrew: Int? = nil,
            imageURL: URL?
        ) {
            self.id = id
            self.name = name
            self.manufacturer = manufacturer
            self.msrpUSD = msrpUSD
            self.type = type
            self.focus = focus
            self.minCrew = minCrew
            self.maxCrew = maxCrew
            self.imageURL = imageURL
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

    init(ships: [Ship]) {
        self.ships = ships

        var keyedShips: [String: Ship] = [:]
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
}

struct HostedShipCatalogClient: Sendable {
    let url: URL
    let urlSession: URLSession

    init(
        url: URL = URL(string: "https://fallback.example.invalid/ships.json")!,
        urlSession: URLSession = .shared
    ) {
        self.url = url
        self.urlSession = urlSession
    }

    func fetchCatalog() async throws -> RSIShipCatalog {
        let (data, response) = try await urlSession.data(from: url)

        if let httpResponse = response as? HTTPURLResponse,
           !(200 ..< 300).contains(httpResponse.statusCode) {
            throw HostedShipCatalogError.httpStatus(httpResponse.statusCode)
        }

        return try Self.decodeCatalog(from: data)
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
                    type: ship.type?.nilIfEmpty,
                    focus: ship.focus?.nilIfEmpty,
                    minCrew: ship.minCrew,
                    maxCrew: ship.maxCrew,
                    imageURL: ship.thumbnailURL
                )
            }
        )
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

private struct RemoteHostedShipCatalogPayload: Decodable {
    let ships: [RemoteHostedShip]
}

private struct RemoteHostedShip: Decodable {
    let id: String
    let title: String?
    let name: String?
    let manufacturer: String?
    let msrpUSD: Decimal?
    let type: String?
    let focus: String?
    let minCrew: Int?
    let maxCrew: Int?
    let thumbnailURL: URL?

    enum CodingKeys: String, CodingKey {
        case id
        case title
        case name
        case manufacturer
        case msrpUSD = "msrpUsd"
        case type
        case focus
        case minCrew
        case maxCrew
        case thumbnailURL = "thumbnailUrl"
    }

    var numericID: Int? {
        Int(id)
    }
}

enum FleetRoleFormatter {
    static func summary(type: String?, focus: String?) -> String? {
        categories(type: type, focus: focus)
            .joined(separator: " / ")
            .nilIfEmpty
    }

    static func categories(type: String?, focus: String?) -> [String] {
        var categories: [String] = []

        if let displayType = displayTypeName(for: type) {
            categories.append(displayType)
        }

        let focusCategories = focus?
            .split(separator: "/")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .compactMap(\.nilIfEmpty) ?? []
        categories.append(contentsOf: focusCategories)

        var seen = Set<String>()
        return categories.filter { category in
            seen.insert(category.localizedLowercase).inserted
        }
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

private extension String {
    var nilIfEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
