import Foundation
import UIKit

actor URLCachedImageStore: RemoteImageCaching {
    static let shared = URLCachedImageStore()

    private let cache: URLCache
    private let session: URLSession

    init(
        cache: URLCache = URLCachedImageStore.makeCache()
    ) {
        self.cache = cache

        let configuration = URLSessionConfiguration.default
        configuration.urlCache = cache
        configuration.requestCachePolicy = .useProtocolCachePolicy
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60
        session = URLSession(configuration: configuration)
    }

    func image(for url: URL, maxRetries: Int = 5) async throws -> UIImage {
        let request = Self.makeRequest(for: url)

        if let cachedResponse = cache.cachedResponse(for: request),
           let image = UIImage(data: cachedResponse.data) {
            return image
        }

        var lastError: Error?
        let attempts = max(1, maxRetries)

        for attempt in 1 ... attempts {
            do {
                let (data, response) = try await session.data(for: request)

                if let httpResponse = response as? HTTPURLResponse,
                   !(200 ..< 300).contains(httpResponse.statusCode) {
                    throw URLError(.badServerResponse)
                }

                guard let image = UIImage(data: data) else {
                    throw RemoteImageStoreError.invalidImageData(url)
                }

                cache.storeCachedResponse(
                    CachedURLResponse(response: response, data: data),
                    for: request
                )

                return image
            } catch {
                lastError = error

                guard attempt < attempts else {
                    break
                }

                let delayNanoseconds = UInt64(attempt) * 300_000_000
                try? await Task.sleep(nanoseconds: delayNanoseconds)
            }
        }

        throw lastError ?? RemoteImageStoreError.unexpectedFailure(url)
    }

    func clear() async {
        cache.removeAllCachedResponses()
    }

    func clear(urls: [URL]) async {
        let uniqueURLs = Array(Set(urls))
        for url in uniqueURLs {
            cache.removeCachedResponse(for: Self.makeRequest(for: url))
        }
    }

    private nonisolated static func makeCache(fileManager: FileManager = .default) -> URLCache {
        let cachesDirectory = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        let diskPath = cachesDirectory
            .appendingPathComponent("HangerExpress", isDirectory: true)
            .appendingPathComponent("RemoteImages", isDirectory: true)
            .path

        return URLCache(
            memoryCapacity: 64 * 1024 * 1024,
            diskCapacity: 512 * 1024 * 1024,
            diskPath: diskPath
        )
    }

    private nonisolated static func makeRequest(for url: URL) -> URLRequest {
        URLRequest(url: url, cachePolicy: .useProtocolCachePolicy, timeoutInterval: 30)
    }
}

enum RemoteImageStoreError: LocalizedError {
    case invalidImageData(URL)
    case unexpectedFailure(URL)

    var errorDescription: String? {
        switch self {
        case let .invalidImageData(url):
            return "The downloaded image data from \(url.absoluteString) was invalid."
        case let .unexpectedFailure(url):
            return "The image at \(url.absoluteString) could not be loaded."
        }
    }
}
