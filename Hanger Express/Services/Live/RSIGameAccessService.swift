import Foundation

nonisolated enum RSIGame: String, CaseIterable, Identifiable, Sendable {
    case starCitizen
    case squadron42

    var id: String { rawValue }

    var title: String {
        switch self {
        case .starCitizen: "Star Citizen"
        case .squadron42: "Squadron 42"
        }
    }

    fileprivate func matches(_ entitlement: RSIGameEntitlement) -> Bool {
        let names = [entitlement.game, entitlement.gameName]
            .compactMap { $0?.lowercased().filter { $0.isLetter || $0.isNumber } }

        switch self {
        case .starCitizen:
            return names.contains("starcitizen")
        case .squadron42:
            return names.contains("squadron42")
        }
    }
}

nonisolated enum RSIGameAccess: String, Codable, Hashable, Sendable {
    case granted
    case notGranted
    case unknown
}

nonisolated struct RSIGameAccessSummary: Codable, Hashable, Sendable {
    let starCitizen: RSIGameAccess
    let squadron42: RSIGameAccess

    func access(for game: RSIGame) -> RSIGameAccess {
        switch game {
        case .starCitizen: starCitizen
        case .squadron42: squadron42
        }
    }
}

nonisolated enum RSIGameAccessService {
    private static let query = """
    query GetGameEntitlements {
      account {
        isAnonymous
      }
      gameEntitlements {
        game
        gameName
        status
      }
    }
    """

    @MainActor
    static func fetch(using savedCookies: [SessionCookie]) async throws -> RSIGameAccessSummary {
        let cookies = RSISessionCookieSet.merging(savedCookies: savedCookies, refreshedCookies: [])
        guard !cookies.isEmpty else {
            throw RSIGameAccessError.missingSession
        }

        // The signed-in Games Library reads this query with a plain GET. A POST can be
        // rejected by RSI even when the same browser cookies can open the page.
        do {
            return try await fetchWithURLSession(cookies: cookies)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if Task.isCancelled { throw CancellationError() }
            // Reuse the browser session path used by the other RSI account pages when
            // the direct request is blocked by RSI's browser/session checks.
            let browser = RSIAccountPageBrowser()
            let data = try await browser.fetchGameEntitlements(
                using: cookies,
                query: query
            )
            return try decode(data)
        }
    }

    private static func fetchWithURLSession(cookies: [SessionCookie]) async throws -> RSIGameAccessSummary {
        guard var components = URLComponents(string: "https://robertsspaceindustries.com/graphql") else {
            throw RSIGameAccessError.invalidResponse
        }
        components.queryItems = [URLQueryItem(name: "query", value: query)]
        guard let url = components.url else { throw RSIGameAccessError.invalidResponse }

        let storage = HTTPCookieStorage()
        cookies.compactMap(\.httpCookie).forEach(storage.setCookie)

        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = storage
        configuration.httpShouldSetCookies = true
        configuration.httpCookieAcceptPolicy = .always
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 30
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 20
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")

        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse,
              (200 ..< 300).contains(response.statusCode),
              response.url?.host == "robertsspaceindustries.com" else {
            throw RSIGameAccessError.invalidResponse
        }

        return try decode(data)
    }

    static func decode(_ data: Data) throws -> RSIGameAccessSummary {
        let response = try JSONDecoder().decode(GraphQLResponse.self, from: data)
        guard response.errors?.isEmpty != false,
              response.data?.account?.isAnonymous == false,
              let entitlements = response.data?.gameEntitlements else {
            throw RSIGameAccessError.invalidResponse
        }

        return RSIGameAccessSummary(
            starCitizen: access(for: .starCitizen, in: entitlements),
            squadron42: access(for: .squadron42, in: entitlements)
        )
    }

    private static func access(
        for game: RSIGame,
        in entitlements: [RSIGameEntitlement]
    ) -> RSIGameAccess {
        let matching = entitlements.filter(game.matches)
        guard !matching.isEmpty else { return .notGranted }

        let statuses = matching.map { $0.status?.lowercased() ?? "" }
        if statuses.contains(where: { ["active", "granted", "owned"].contains($0) }) {
            return .granted
        }
        if statuses.allSatisfy({ ["inactive", "revoked", "expired", "disabled", "suspended"].contains($0) }) {
            return .notGranted
        }
        return .unknown
    }

    private struct GraphQLResponse: Decodable {
        struct Payload: Decodable {
            struct Account: Decodable {
                let isAnonymous: Bool?
            }

            let account: Account?
            let gameEntitlements: [RSIGameEntitlement]?
        }

        struct GraphQLError: Decodable {
            let message: String?
        }

        let data: Payload?
        let errors: [GraphQLError]?
    }
}

private nonisolated struct RSIGameEntitlement: Decodable, Sendable {
    let game: String?
    let gameName: String?
    let status: String?
}

private nonisolated enum RSIGameAccessError: Error {
    case missingSession
    case invalidResponse
}
