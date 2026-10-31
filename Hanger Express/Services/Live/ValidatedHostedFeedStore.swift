import CryptoKit
import Foundation

nonisolated enum ValidatedHostedFeedError: Error { case invalidResponse, emptyFeed }

/// Public feed data only. Never stores sessions, cookies or authentication.
/// Disk I/O and decoding run on this actor, not the UI owner. Cache files are
/// keyed by a hash of the complete endpoint configuration and feed kind.
actor ValidatedHostedFeedStore<Value: Sendable> {
    private nonisolated struct Document: Codable, Sendable {
        let data: Data
        var validatedAt: Date
        let source: String
        var etag: String?
        var lastModified: String?
        var maxAge: TimeInterval
        var mayStore: Bool
        var allowsStale: Bool
    }
    private let directory: URL
    private let freshness: TimeInterval
    private let maximumStaleAge: TimeInterval
    private var context: String?
    private var generation: UInt64 = 0
    private var document: Document?
    private var cached: Value?
    private var flight: (id: UUID, task: Task<(Value, Document), Error>)?
    private var needsRefresh = false
    private var failedAt: Date?
    private(set) var isUsingStaleFallback = false

    init(directory: URL, freshness: TimeInterval = 600, maximumStaleAge: TimeInterval = 7 * 86_400) {
        self.directory = directory; self.freshness = freshness; self.maximumStaleAge = maximumStaleAge
    }

    func load(urls: [URL], session: URLSession, forceRefresh: Bool = false, persistent: Bool = true,
              now: Date = .now, decode: @escaping @Sendable (Data) throws -> Value) async throws -> Value {
        let key = Self.hash(urls.map(\.absoluteString).joined(separator: "\n"))
        let requestedContext = "\(key):\(persistent)"
        if context != requestedContext {
            generation &+= 1; flight?.task.cancel(); flight = nil
            context = requestedContext; document = nil; cached = nil
            failedAt = nil; needsRefresh = false; isUsingStaleFallback = false
            if persistent, let data = try? Data(contentsOf: file(key)),
               let restored = try? JSONDecoder().decode(Document.self, from: data),
               let value = try? decode(restored.data) {
                document = restored; cached = value
            }
        }
        if !forceRefresh, let cached, let document {
            if !needsRefresh, now.timeIntervalSince(document.validatedAt) < min(freshness, document.maxAge) {
                isUsingStaleFallback = false; return cached
            }
            if let failedAt, now.timeIntervalSince(failedAt) < 60,
               document.allowsStale, now.timeIntervalSince(document.validatedAt) <= maximumStaleAge {
                isUsingStaleFallback = true; return cached
            }
        }
        let stamp = generation
        let active: (id: UUID, task: Task<(Value, Document), Error>)
        if let flight { active = flight }
        else {
            let old = document
            let task = Task { try await Self.fetch(urls: urls, session: session, previous: old, now: now, decode: decode) }
            active = (UUID(), task); flight = active
        }
        do {
            let (value, accepted) = try await active.task.value
            guard generation == stamp, context == requestedContext else { throw CancellationError() }
            if flight?.id == active.id {
                cached = value; document = accepted; flight = nil; needsRefresh = false; failedAt = nil
                isUsingStaleFallback = false
                // No suspension between the generation check and disk replace:
                // clear cannot be followed by an obsolete completion's write.
                if persistent, accepted.mayStore {
                    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    if let data = try? JSONEncoder().encode(accepted) { try? data.write(to: file(key), options: .atomic) }
                } else if persistent { try? FileManager.default.removeItem(at: file(key)) }
                if !accepted.mayStore { cached = nil; document = nil }
            }
            try Task.checkCancellation()
            return value
        } catch {
            guard generation == stamp, context == requestedContext else { throw CancellationError() }
            if flight?.id == active.id { flight = nil }
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            if let cached, let document, document.allowsStale, now.timeIntervalSince(document.validatedAt) <= maximumStaleAge {
                failedAt = now; needsRefresh = true; isUsingStaleFallback = true
                return cached
            }
            throw error
        }
    }

    func invalidateFreshness() { needsRefresh = true; failedAt = nil }
    func clear() {
        generation &+= 1; flight?.task.cancel(); flight = nil
        document = nil; cached = nil; context = nil; failedAt = nil; needsRefresh = false
        isUsingStaleFallback = false
        try? FileManager.default.removeItem(at: directory)
    }
    private func file(_ key: String) -> URL { directory.appendingPathComponent(key + ".json") }
    private nonisolated static func hash(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    private nonisolated static func fetch(urls: [URL], session: URLSession, previous: Document?, now: Date,
                                         decode: @escaping @Sendable (Data) throws -> Value) async throws -> (Value, Document) {
        var lastError: Error = ValidatedHostedFeedError.invalidResponse
        for url in urls {
            try Task.checkCancellation()
            do {
                var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
                let matching = previous?.source == hash(url.absoluteString) ? previous : nil
                if let etag = matching?.etag { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }
                else if let modified = matching?.lastModified { request.setValue(modified, forHTTPHeaderField: "If-Modified-Since") }
                let (data, response) = try await session.data(for: request)
                guard let response = response as? HTTPURLResponse else { throw ValidatedHostedFeedError.invalidResponse }
                if response.statusCode == 304 {
                    guard var matching, matching.etag != nil || matching.lastModified != nil else { throw ValidatedHostedFeedError.invalidResponse }
                    let value = try decode(matching.data)
                    matching.validatedAt = now
                    matching.etag = response.value(forHTTPHeaderField: "ETag") ?? matching.etag
                    matching.lastModified = response.value(forHTTPHeaderField: "Last-Modified") ?? matching.lastModified
                    if let control = response.value(forHTTPHeaderField: "Cache-Control") {
                        let policy = cachePolicy(control)
                        matching.maxAge = policy.age; matching.mayStore = policy.store; matching.allowsStale = policy.stale
                    }
                    return (value, matching)
                }
                guard (200..<300).contains(response.statusCode) else { throw HostedShipCatalogError.httpStatus(response.statusCode) }
                let value = try decode(data)
                let policy = cachePolicy(response.value(forHTTPHeaderField: "Cache-Control") ?? "")
                return (value, Document(data: data, validatedAt: now, source: hash(url.absoluteString),
                    etag: response.value(forHTTPHeaderField: "ETag"), lastModified: response.value(forHTTPHeaderField: "Last-Modified"),
                    maxAge: policy.age, mayStore: policy.store, allowsStale: policy.stale))
            } catch {
                if error is CancellationError || Task.isCancelled { throw CancellationError() }
                lastError = error
            }
        }
        throw lastError
    }
    private nonisolated static func cachePolicy(_ control: String) -> (age: TimeInterval, store: Bool, stale: Bool) {
        let directives = control.lowercased().split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        let age = directives.first(where: { $0.hasPrefix("max-age=") })
            .flatMap { TimeInterval($0.dropFirst(8).replacingOccurrences(of: "\"", with: "")) } ?? 600
        let prohibited = directives.contains("no-cache") || directives.contains("no-store")
        return (prohibited ? 0 : max(0, age), !directives.contains("no-store"), !prohibited && !directives.contains("must-revalidate"))
    }

}
