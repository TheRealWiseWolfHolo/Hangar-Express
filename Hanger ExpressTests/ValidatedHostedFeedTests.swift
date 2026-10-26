import Foundation
import Testing
@testable import Hanger_Express

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct ValidatedHostedFeedTests {
    let resources = TestResources()
    private let url = URL(string: "https://example.invalid/ships.json")!
    private nonisolated static func decode(_ data: Data) throws -> FeedFixture {
        let value = try JSONDecoder().decode(FeedFixture.self, from: data)
        guard !value.values.isEmpty else { throw ValidatedHostedFeedError.emptyFeed }
        return value
    }
    private func loader(_ directory: URL? = nil) -> ValidatedHostedFeedStore<FeedFixture> {
        ValidatedHostedFeedStore(directory: directory ?? resources.temporaryDirectory())
    }

    @Test func concurrentConsumersShareOneRequestAndClearFencesCompletion() async throws {
        let probe = FeedProbe()
        let session = resources.session { try await probe.respond($0) }
        let store = loader()
        let all = Task {
            try await withThrowingTaskGroup(of: FeedFixture.self) { group in
                for _ in 0..<16 {
                    group.addTask { try await store.load(urls: [url], session: session, decode: Self.decode) }
                }
                var values: [FeedFixture] = []
                for try await value in group { values.append(value) }
                return values
            }
        }
        try await probe.started.wait()
        await probe.release.open()
        let results = try await all.value
        #expect(results.count == 16 && results.allSatisfy { $0.values == [1] })
        #expect(await probe.count == 1)

        let blocked = FeedProbe()
        let blockedSession = resources.session { try await blocked.respond($0) }
        let obsolete = Task { try await store.load(urls: [url], session: blockedSession, forceRefresh: true, decode: Self.decode) }
        try await blocked.started.wait()
        await store.clear()
        await blocked.release.open()
        do { _ = try await obsolete.value; Issue.record("Cleared load committed") }
        catch { #expect(error is CancellationError) }
        let fresh = FeedProbe(); await fresh.configure(status: 200, values: [2]); await fresh.release.open()
        let freshSession = resources.session { try await fresh.respond($0) }
        let value = try await store.load(urls: [url], session: freshSession, decode: Self.decode)
        #expect(value.values == [2])
        #expect(await fresh.count == 1)
    }

    @Test func conditional304UsesValidatedBodyAndPersistentOfflineFallback() async throws {
        let directory = resources.temporaryDirectory()
        let store = loader(directory)
        let probe = FeedProbe(); await probe.release.open()
        let session = resources.session { try await probe.respond($0) }
        let date = Date(timeIntervalSince1970: 1_000)
        let first = try await store.load(urls: [url], session: session, now: date, decode: Self.decode)
        await probe.configure(status: 304)
        let same = try await store.load(urls: [url], session: session, forceRefresh: true, now: date.addingTimeInterval(700), decode: Self.decode)
        #expect(same == first)
        #expect(await probe.lastRequest?.value(forHTTPHeaderField: "If-None-Match") == "\"v1\"")
        await probe.setFailure(true)
        let reopened = loader(directory)
        let offline = try await reopened.load(urls: [url], session: session, now: date.addingTimeInterval(1_400), decode: Self.decode)
        #expect(offline == first)
        #expect(await reopened.isUsingStaleFallback)
        #expect(await probe.count == 3)
    }

    @Test func malformedFeedDoesNotReplaceGoodCacheAndChangedConfigurationCannotReuseIt() async throws {
        let store = loader()
        let probe = FeedProbe(); await probe.release.open()
        let session = resources.session { try await probe.respond($0) }
        let first = try await store.load(urls: [url], session: session, decode: Self.decode)
        await probe.setMalformed(true)
        let fallback = try await store.load(urls: [url], session: session, forceRefresh: true, decode: Self.decode)
        #expect(fallback == first)
        let other = URL(string: "https://example.invalid/other.json")!
        do {
            _ = try await store.load(urls: [other], session: session, decode: Self.decode)
            Issue.record("A different feed reused stale data")
        } catch { #expect(error is DecodingError) }
    }

    @Test func noStoreIsNotPersistedOrReusedAndExpiredFallbackIsRejected() async throws {
        let directory = resources.temporaryDirectory()
        let store = loader(directory)
        let probe = FeedProbe(); await probe.configure(control: "no-store"); await probe.release.open()
        let session = resources.session { try await probe.respond($0) }
        let date = Date(timeIntervalSince1970: 1_000)
        _ = try await store.load(urls: [url], session: session, now: date, decode: Self.decode)
        _ = try await store.load(urls: [url], session: session, now: date, decode: Self.decode)
        #expect(await probe.count == 2)
        #expect(!FileManager.default.fileExists(atPath: directory.path))
        await probe.configure(control: "max-age=600")
        _ = try await store.load(urls: [url], session: session, now: date, decode: Self.decode)
        await probe.setFailure(true)
        do {
            _ = try await store.load(urls: [url], session: session, now: date.addingTimeInterval(8 * 86_400), decode: Self.decode)
            Issue.record("Expired offline fallback was accepted")
        } catch { #expect(error is URLError) }
    }
}

private nonisolated struct FeedFixture: Codable, Equatable, Sendable { let values: [Int] }
private actor FeedProbe {
    let started = TestGate(), release = TestGate()
    var count = 0
    var lastRequest: URLRequest?
    private var status = 200
    private var values = [1]
    private var failure = false
    private var malformed = false
    private var control = "max-age=600"
    func configure(status: Int = 200, values: [Int] = [1], control: String = "max-age=600") {
        self.status = status; self.values = values; self.control = control
    }
    func setFailure(_ value: Bool) { failure = value }
    func setMalformed(_ value: Bool) { malformed = value }
    func respond(_ request: URLRequest) async throws -> (HTTPURLResponse, Data) {
        count += 1; lastRequest = request; await started.open(); try await release.wait()
        if failure { throw URLError(.notConnectedToInternet) }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil,
            headerFields: ["ETag": "\"v1\"", "Cache-Control": control])!
        return (response, malformed ? Data("invalid".utf8) : try JSONEncoder().encode(FeedFixture(values: values)))
    }
}
