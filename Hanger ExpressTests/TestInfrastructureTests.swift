import Foundation
import Testing
@testable import Hanger_Express

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct TestInfrastructureTests {
    let resources = TestResources()

    @Test func sameURLRequestsKeepTheirOwnHandlersWhileOneResponseIsDelayed() async throws {
        let url = URL(string: "https://example.invalid/same-resource")!
        let arrived = TestGate()
        let release = TestGate()
        let firstSession = resources.session { request in
            await arrived.open()
            try await release.wait()
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data("first".utf8))
        }
        let secondSession = resources.session { request in
            (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data("second".utf8))
        }
        let firstRequest = Task { try await firstSession.data(from: url).0 }
        defer {
            firstRequest.cancel()
            Task { await release.open() }
        }
        try await arrived.wait()
        let (secondData, _) = try await secondSession.data(from: url)
        #expect(secondData == Data("second".utf8))
        await release.open()
        #expect(try await firstRequest.value == Data("first".utf8))
    }

    @Test func unregisteredRequestsFailLocally() async throws {
        let session = resources.translationSession()
        do {
            _ = try await session.data(from: URL(string: "https://example.invalid/unregistered")!)
            Issue.record("An unregistered fixture request must fail without using the network.")
        } catch let error as URLError {
            #expect(error.code == .resourceUnavailable)
        }
    }

    @Test func testResourcesIsolatePreferencesAndCleanUpOwnedFiles() throws {
        var first: TestResources? = TestResources()
        let defaults = try #require(first?.defaults)
        let directory = try #require(first?.directoryURL)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defaults.set(true, forKey: "fixture-only")
        #expect(!resources.defaults.bool(forKey: "fixture-only"))
        first = nil
        #expect(defaults.object(forKey: "fixture-only") == nil)
        #expect(!FileManager.default.fileExists(atPath: directory.path))
    }

    @Test func requestBodyFixturesReadFoundationBodyStreams() throws {
        let body = Data(#"{"items":[{"source":"test"}]}"#.utf8)
        var request = URLRequest(url: URL(string: "https://example.invalid/upload")!)
        request.httpBodyStream = InputStream(data: body)
        #expect(try request.testBodyData() == body)
    }

    @Test func delayedFixtureGateRespondsToCancellation() async throws {
        let gate = TestGate()
        let task = Task { try await gate.wait() }
        task.cancel()
        do {
            try await task.value
            Issue.record("A cancelled delayed response must not remain suspended.")
        } catch is CancellationError {
            // Expected: cleanup does not need a timer or an externally released gate.
        }
    }
}
