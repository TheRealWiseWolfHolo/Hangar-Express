import Foundation
@testable import Hanger_Express

/// Swift Testing creates a fresh suite instance for each test. This owner keeps
/// HTTP handlers, preferences, and temporary files within that test's lifetime.
final class TestResources: @unchecked Sendable {
    let defaults: UserDefaults
    let directoryURL: URL
    let responses = TestHTTPResponses()
    private let suiteName = "HangarExpressTests.\(UUID().uuidString)"
    private let lock = NSLock()
    private var sessions: [(id: String, session: URLSession)] = []

    @MainActor
    init() {
        defaults = UserDefaults(suiteName: suiteName)!
        defaults.set("english", forKey: AppLanguage.storageKey)
        defaults.set(
            SyncPreferences.InventoryAutoRefreshInterval.never.rawValue,
            forKey: SyncPreferences.inventoryAutoRefreshIntervalKey
        )
        directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("HangarExpressTests-\(UUID().uuidString)", isDirectory: true)
    }

    deinit {
        for entry in sessions {
            entry.session.invalidateAndCancel()
            TestURLProtocol.removeHandler(for: entry.id)
        }
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: directoryURL)
    }

    func temporaryDirectory() -> URL {
        directoryURL.appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    func translationSession() -> URLSession {
        let responses = responses
        return session { request in try responses.response(for: request) }
    }

    func session(handler: @escaping TestURLProtocol.Handler) -> URLSession {
        let id = UUID().uuidString
        TestURLProtocol.register(handler, for: id)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TestURLProtocol.self]
        configuration.httpAdditionalHeaders = [TestURLProtocol.handlerHeader: id]
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        let session = URLSession(configuration: configuration)
        lock.withLock { sessions.append((id, session)) }
        return session
    }
}

extension URLRequest {
    func testBodyData() throws -> Data {
        if let httpBody { return httpBody }
        guard let stream = httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count < 0 { throw stream.streamError ?? URLError(.cannotDecodeRawData) }
            if count == 0 { return data }
            data.append(contentsOf: buffer.prefix(count))
        }
    }
}

enum TestHTTPResponse: Sendable {
    case response(statusCode: Int, data: Data)
    case error(any Error)
}

final class TestHTTPResponses: @unchecked Sendable {
    private let lock = NSLock()
    private var responses: [URL: TestHTTPResponse] = [:]

    func register(_ response: TestHTTPResponse, for url: URL) {
        lock.withLock { responses[url] = response }
    }

    func response(for request: URLRequest) throws -> (HTTPURLResponse, Data) {
        guard let url = request.url,
              let response = lock.withLock({ responses[url] }) else {
            throw URLError(.resourceUnavailable)
        }
        switch response {
        case let .response(statusCode, data):
            guard let httpResponse = HTTPURLResponse(
                url: url, statusCode: statusCode, httpVersion: nil, headerFields: nil
            ) else { throw URLError(.badServerResponse) }
            return (httpResponse, data)
        case let .error(error):
            throw error
        }
    }
}

final class TestURLProtocol: URLProtocol, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) async throws -> (HTTPURLResponse, Data)
    static let handlerHeader = "X-Hangar-Test-Handler"
    private static let registryLock = NSLock()
    nonisolated(unsafe) private static var handlers: [String: Handler] = [:]
    private let taskLock = NSLock()
    private var responseTask: Task<Void, Never>?
    private var stopped = false

    static func register(_ handler: @escaping Handler, for id: String) {
        registryLock.withLock { handlers[id] = handler }
    }

    static func removeHandler(for id: String) {
        _ = registryLock.withLock { handlers.removeValue(forKey: id) }
    }

    // Every request in a stubbed session is intercepted. An unregistered URL or
    // missing handler must fail rather than fall through to a live server.
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let id = request.value(forHTTPHeaderField: Self.handlerHeader),
              let handler = Self.registryLock.withLock({ Self.handlers[id] }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable))
            return
        }
        let loadingTask = Task { [self] in
            do {
                let (response, data) = try await handler(request)
                try Task.checkCancellation()
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: data)
                client?.urlProtocolDidFinishLoading(self)
            } catch {
                if !Task.isCancelled {
                    client?.urlProtocol(self, didFailWithError: error)
                }
            }
        }
        taskLock.withLock {
            if stopped { loadingTask.cancel() }
            else { responseTask = loadingTask }
        }
    }

    override func stopLoading() {
        taskLock.withLock {
            stopped = true
            responseTask?.cancel()
            responseTask = nil
        }
    }
}
