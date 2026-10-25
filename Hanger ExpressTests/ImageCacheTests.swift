import Foundation
import Testing
import UIKit
@testable import Hanger_Express

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct ImageCacheTests {
    let resources = TestResources()

    @Test func urlCachedImageStoreLoadsPersistedThumbnailWithoutNetwork() async throws {
        let tempDirectory = resources.temporaryDirectory()
        let imageURL = try #require(URL(string: "https://example.com/ship.jpg"))
        let targetSize = CGSize(width: 84, height: 84)
        let redImageData = makeSolidImageData(color: .systemRed)

        let initialSession = resources.session { request in
            (
                try #require(HTTPURLResponse(url: request.url ?? imageURL, statusCode: 200, httpVersion: nil, headerFields: nil)),
                redImageData
            )
        }

        let firstStore = URLCachedImageStore(
            cache: URLCache(memoryCapacity: 0, diskCapacity: 0),
            session: initialSession,
            storageDirectoryURL: tempDirectory
        )
        let initialImage = try await firstStore.image(
            for: imageURL,
            targetPointSize: targetSize,
            displayScale: 2,
            maxRetries: 1
        )

        #expect(colorMatches(sampledColor(from: initialImage), UIColor.systemRed))

        let offlineSession = resources.session { _ in
            throw URLError(.notConnectedToInternet)
        }

        let secondStore = URLCachedImageStore(
            cache: URLCache(memoryCapacity: 0, diskCapacity: 0),
            session: offlineSession,
            storageDirectoryURL: tempDirectory
        )
        let restoredImage = try await secondStore.image(
            for: imageURL,
            targetPointSize: targetSize,
            displayScale: 2,
            maxRetries: 1
        )

        #expect(colorMatches(sampledColor(from: restoredImage), UIColor.systemRed))
    }

    @Test func urlCachedImageStoreClearsCompositeImagesWhenSourceURLsInvalidate() async throws {
        let tempDirectory = resources.temporaryDirectory()
        let sourceURL = try #require(URL(string: "https://example.com/source.jpg"))
        let targetURL = try #require(URL(string: "https://example.com/target.jpg"))
        let targetSize = CGSize(width: 96, height: 96)
        let sourceDataBox = MutableImageDataBox(data: makeSolidImageData(color: .systemRed))
        let targetImageData = makeSolidImageData(color: .systemBlue)

        let session = resources.session { request in
            let response = try #require(
                HTTPURLResponse(url: request.url ?? sourceURL, statusCode: 200, httpVersion: nil, headerFields: nil)
            )

            switch request.url?.lastPathComponent {
            case "source.jpg":
                return (response, sourceDataBox.data)
            case "target.jpg":
                return (response, targetImageData)
            default:
                throw URLError(.badURL)
            }
        }

        let store = URLCachedImageStore(
            cache: URLCache(memoryCapacity: 0, diskCapacity: 0),
            session: session,
            storageDirectoryURL: tempDirectory
        )

        let firstComposite = try await store.compositeImage(
            sourceURL: sourceURL,
            targetURL: targetURL,
            targetPointSize: targetSize,
            displayScale: 2,
            maxRetries: 1
        )

        #expect(colorMatches(sampledColor(from: firstComposite, normalizedPoint: CGPoint(x: 0.25, y: 0.5)), UIColor.systemRed))
        #expect(colorMatches(sampledColor(from: firstComposite, normalizedPoint: CGPoint(x: 0.75, y: 0.5)), UIColor.systemBlue))

        sourceDataBox.data = makeSolidImageData(color: .systemGreen)
        await store.clear(urls: [sourceURL])

        let refreshedComposite = try await store.compositeImage(
            sourceURL: sourceURL,
            targetURL: targetURL,
            targetPointSize: targetSize,
            displayScale: 2,
            maxRetries: 1
        )

        #expect(colorMatches(sampledColor(from: refreshedComposite, normalizedPoint: CGPoint(x: 0.25, y: 0.5)), UIColor.systemGreen))
        #expect(colorMatches(sampledColor(from: refreshedComposite, normalizedPoint: CGPoint(x: 0.75, y: 0.5)), UIColor.systemBlue))
    }

    @Test func urlCachedImageStorePersistsFleetCardBaseImagesWithoutRemoteSources() async throws {
        let tempDirectory = resources.temporaryDirectory()
        let shipImageURL = try #require(URL(string: "https://example.com/fleet-card-ship.jpg"))
        let recipe = FleetCardBaseSnapshotRecipe(
            style: .compact,
            pointSize: CGSize(width: 220, height: 232),
            manufacturerName: "Aegis Dynamics",
            backdropURL: shipImageURL,
            logoURL: nil
        )
        let initialSession = resources.session { request in
            (
                try #require(HTTPURLResponse(url: request.url ?? shipImageURL, statusCode: 200, httpVersion: nil, headerFields: nil)),
                makeSolidImageData(color: .systemRed)
            )
        }

        let firstStore = URLCachedImageStore(
            cache: URLCache(memoryCapacity: 0, diskCapacity: 0),
            session: initialSession,
            storageDirectoryURL: tempDirectory
        )

        let initialImage = try await firstStore.fleetCardBaseImage(
            for: recipe,
            displayScale: 2,
            maxRetries: 1
        )
        let sampledPoint = CGPoint(x: 0.72, y: 0.36)
        let initialColor = sampledColor(from: initialImage, normalizedPoint: sampledPoint)
        #expect(initialImage.size.width > 0)
        #expect(initialImage.size.height > 0)

        try? FileManager.default.removeItem(at: tempDirectory.appendingPathComponent("Remote", isDirectory: true))

        let offlineSession = resources.session { _ in
            throw URLError(.notConnectedToInternet)
        }

        let secondStore = URLCachedImageStore(
            cache: URLCache(memoryCapacity: 0, diskCapacity: 0),
            session: offlineSession,
            storageDirectoryURL: tempDirectory
        )

        let restoredImage = try await secondStore.fleetCardBaseImage(
            for: recipe,
            displayScale: 2,
            maxRetries: 1
        )
        let restoredColor = sampledColor(from: restoredImage, normalizedPoint: sampledPoint)

        #expect(colorsMatch(restoredColor, initialColor, tolerance: 0.03))
    }

    @Test func urlCachedImageStoreClearsFleetCardBaseImagesWhenSourceURLsInvalidate() async throws {
        let tempDirectory = resources.temporaryDirectory()
        let shipImageURL = try #require(URL(string: "https://example.com/fleet-card-refresh.jpg"))
        let sourceDataBox = MutableImageDataBox(data: makeSolidImageData(color: .systemRed))
        let recipe = FleetCardBaseSnapshotRecipe(
            style: .compact,
            pointSize: CGSize(width: 220, height: 232),
            manufacturerName: "Origin Jumpworks",
            backdropURL: shipImageURL,
            logoURL: nil
        )

        let session = resources.session { request in
            (
                try #require(HTTPURLResponse(url: request.url ?? shipImageURL, statusCode: 200, httpVersion: nil, headerFields: nil)),
                sourceDataBox.data
            )
        }

        let store = URLCachedImageStore(
            cache: URLCache(memoryCapacity: 0, diskCapacity: 0),
            session: session,
            storageDirectoryURL: tempDirectory
        )

        let sampledPoint = CGPoint(x: 0.72, y: 0.36)
        let firstImage = try await store.fleetCardBaseImage(
            for: recipe,
            displayScale: 2,
            maxRetries: 1
        )
        let firstColor = sampledColor(from: firstImage, normalizedPoint: sampledPoint)

        sourceDataBox.data = makeSolidImageData(color: .systemGreen)
        await store.clear(urls: [shipImageURL])

        let refreshedImage = try await store.fleetCardBaseImage(
            for: recipe,
            displayScale: 2,
            maxRetries: 1
        )
        let refreshedColor = sampledColor(from: refreshedImage, normalizedPoint: sampledPoint)

        #expect(!colorsMatch(refreshedColor, firstColor, tolerance: 0.08))
    }

}

private final class MutableImageDataBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storedData: Data

    var data: Data {
        get { lock.withLock { storedData } }
        set { lock.withLock { storedData = newValue } }
    }

    init(data: Data) {
        storedData = data
    }
}
