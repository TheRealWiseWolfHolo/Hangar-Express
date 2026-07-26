import Foundation

nonisolated enum HostedEventCalendarError: LocalizedError, Equatable {
    case invalidFeed(String)
    case unavailable(String)

    var errorDescription: String? {
        switch self {
        case let .invalidFeed(message), let .unavailable(message):
            return message
        }
    }
}

actor HostedEventCalendarClient {
    private let urlSession: URLSession
    private let feedURLs: [URL]
    private let cacheURL: URL

    init(
        urlSession: URLSession = .shared,
        feedURLs: [URL] = HostedShipFeedEndpoints.eventCalendarURLs,
        cacheURL: URL? = nil
    ) {
        self.urlSession = urlSession
        self.feedURLs = feedURLs
        self.cacheURL = cacheURL ?? Self.defaultCacheURL
    }

    func cachedFeed() -> EventCalendarFeed? {
        guard let data = try? Data(contentsOf: cacheURL) else {
            return nil
        }
        return try? Self.decodeFeed(from: data)
    }

    func refresh() async throws -> EventCalendarFeed {
        var errors: [String] = []

        for url in feedURLs {
            do {
                var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 25)
                request.setValue("application/json", forHTTPHeaderField: "Accept")
                let (data, response) = try await urlSession.data(for: request)
                guard let httpResponse = response as? HTTPURLResponse,
                      (200..<300).contains(httpResponse.statusCode) else {
                    throw HostedEventCalendarError.unavailable("The server returned an invalid response.")
                }

                let feed = try Self.decodeFeed(from: data)
                try saveCache(data)
                return feed
            } catch {
                errors.append("\(url.host ?? url.absoluteString): \(error.localizedDescription)")
            }
        }

        if let cachedFeed = cachedFeed() {
            return cachedFeed
        }

        throw HostedEventCalendarError.unavailable(
            errors.isEmpty
                ? AppLocalizer.string("No event calendar feed is configured.")
                : errors.joined(separator: "\n")
        )
    }

    nonisolated static func decodeFeed(from data: Data) throws -> EventCalendarFeed {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)
            let fractionalFormatter = ISO8601DateFormatter()
            fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let formatter = ISO8601DateFormatter()
            if let date = fractionalFormatter.date(from: value)
                ?? formatter.date(from: value) {
                return date
            }
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Expected an ISO 8601 date."
            )
        }

        let feed = try decoder.decode(EventCalendarFeed.self, from: data)
        guard feed.schemaVersion == 1 else {
            throw HostedEventCalendarError.invalidFeed(
                AppLocalizer.format("Unsupported event feed version: %lld", feed.schemaVersion)
            )
        }
        guard feed.count == feed.events.count else {
            throw HostedEventCalendarError.invalidFeed(
                AppLocalizer.string("The event feed count does not match its event list.")
            )
        }
        guard feed.events.allSatisfy({ $0.endsAt > $0.startsAt }) else {
            throw HostedEventCalendarError.invalidFeed(
                AppLocalizer.string("The event feed contains an invalid date range.")
            )
        }
        return feed
    }

    private func saveCache(_ data: Data) throws {
        try FileManager.default.createDirectory(
            at: cacheURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: cacheURL, options: .atomic)
    }

    private nonisolated static var defaultCacheURL: URL {
        let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return directory
            .appendingPathComponent("HangarExpress", isDirectory: true)
            .appendingPathComponent("event-calendar-v1.json")
    }

}
