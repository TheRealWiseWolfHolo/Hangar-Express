import Foundation
import Testing
import UIKit
@testable import Hanger_Express

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct ImageCacheTests {
    let resources = TestResources()

    @Test func expiredProcessedImageDisplaysWithoutWaitingForNetworkValidation() async throws {
        let root = resources.temporaryDirectory()
        let url = URL(string: "https://example.invalid/warm-but-expired.jpg")!
        let bytes = makeSolidImageData(color: .systemBlue)
        let initial = resources.session { request in
            (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                             headerFields: ["ETag": "warm-v1"])!, bytes)
        }
        let first = URLCachedImageStore(cache: URLCache(memoryCapacity: 0, diskCapacity: 0), session: initial,
                                        storageDirectoryURL: root)
        _ = try await first.image(for: url, maxRetries: 1)
        let files = try #require(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
        let metadata = try #require(files.allObjects.compactMap { $0 as? URL }.first { $0.lastPathComponent == "metadata.json" })
        var object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: metadata)) as? [String: Any])
        object["validatedAt"] = Date.distantPast.timeIntervalSinceReferenceDate
        try JSONSerialization.data(withJSONObject: object).write(to: metadata)
        let counter = ImageLoadCounter()
        let offline = resources.session { _ in
            _ = await counter.next()
            throw URLError(.notConnectedToInternet)
        }
        let reopened = URLCachedImageStore(cache: URLCache(memoryCapacity: 0, diskCapacity: 0), session: offline,
                                           storageDirectoryURL: root)
        let restored = try await reopened.image(for: url, maxRetries: 1)
        #expect(colorMatches(sampledColor(from: restored), UIColor.systemBlue))
        #expect(await counter.current == 0)
        let changed = await reopened.revalidate(urls: [url])
        #expect(changed.isEmpty)
        #expect(await counter.current == 1)
        let retained = try await reopened.image(for: url, maxRetries: 1)
        #expect(retained === restored)
    }

    @Test func noOpValidationAnd304KeepWarmImageAndChangedBytesRefreshTheSameURL() async throws {
        let url = URL(string: "https://example.invalid/versioned.jpg")!
        let red = makeSolidImageData(color: .systemRed), green = makeSolidImageData(color: .systemGreen)
        let probe = ImageValidationProbe(data: red)
        let session = resources.session { try await probe.respond($0) }
        let store = URLCachedImageStore(cache: URLCache(memoryCapacity: 4_000_000, diskCapacity: 0), session: session,
                                        storageDirectoryURL: resources.temporaryDirectory())
        let first = try await store.image(for: url, maxRetries: 1)
        let noOp = await store.revalidate(urls: [url], force: false)
        #expect(noOp.isEmpty)
        let warm = try await store.image(for: url, maxRetries: 1)
        #expect(warm === first)
        #expect(await probe.count == 1)
        await probe.configure(status: 304, data: Data())
        let unchanged = await store.revalidate(urls: [url], force: true)
        #expect(unchanged.isEmpty)
        #expect(await probe.lastRequest?.value(forHTTPHeaderField: "If-None-Match") == "\"image-v1\"")
        let validated = try await store.image(for: url, maxRetries: 1)
        #expect(validated === first)
        #expect(await probe.count == 2)
        await probe.configure(status: 200, data: green)
        let changed = await store.revalidate(urls: [url], force: true)
        #expect(changed == [url])
        let refreshed = try await store.image(for: url, maxRetries: 1)
        #expect(colorMatches(sampledColor(from: refreshed), UIColor.systemGreen))
        #expect(await probe.count == 3)
    }

    @Test func clearingOneSourcePreservesUnrelatedDerivedMemoryAndDiskEntries() async throws {
        let root = resources.temporaryDirectory()
        let a = URL(string: "https://example.invalid/a.jpg")!, b = URL(string: "https://example.invalid/b.jpg")!
        let c = URL(string: "https://example.invalid/c.jpg")!, d = URL(string: "https://example.invalid/d.jpg")!
        let data = makeSolidImageData(color: .systemBlue)
        let probe = ImageValidationProbe(data: data)
        let session = resources.session { try await probe.respond($0) }
        let cache = URLCache(memoryCapacity: 4_000_000, diskCapacity: 0)
        let store = URLCachedImageStore(cache: cache, session: session, storageDirectoryURL: root)
        let size = CGSize(width: 96, height: 96)
        _ = try await store.compositeImage(sourceURL: a, targetURL: b, targetPointSize: size, maxRetries: 1)
        let unrelated = try await store.compositeImage(sourceURL: c, targetURL: d, targetPointSize: size, maxRetries: 1)
        let before = await probe.count
        await store.clear(urls: [a])
        let kept = try await store.compositeImage(sourceURL: c, targetURL: d, targetPointSize: size, maxRetries: 1)
        #expect(kept === unrelated)
        #expect(await probe.count == before)
        let offline = resources.session { _ in throw URLError(.notConnectedToInternet) }
        let reopened = URLCachedImageStore(cache: URLCache(memoryCapacity: 0, diskCapacity: 0), session: offline, storageDirectoryURL: root)
        let disk = try await reopened.compositeImage(sourceURL: c, targetURL: d, targetPointSize: size, maxRetries: 1)
        #expect(colorMatches(sampledColor(from: disk, normalizedPoint: CGPoint(x: 0.25, y: 0.5)), UIColor.systemBlue))
    }

    @Test func clearedInFlightSourceCannotRepopulateItsOldPixels() async throws {
        let arrived = TestGate(), release = TestGate()
        defer { Task { await release.open() } }
        let counter = ImageLoadCounter()
        let red = makeSolidImageData(color: .systemRed), green = makeSolidImageData(color: .systemGreen)
        let session = resources.session { request in
            let call = await counter.next()
            if call == 1 { await arrived.open(); try await release.wait() }
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, call == 1 ? red : green)
        }
        let store = URLCachedImageStore(cache: URLCache(memoryCapacity: 4_000_000, diskCapacity: 0), session: session,
                                        storageDirectoryURL: resources.temporaryDirectory())
        let url = URL(string: "https://example.invalid/changed.jpg")!
        let old = Task { try await store.image(for: url, maxRetries: 1) }
        try await arrived.wait()
        await store.clear(urls: [url])
        let current = try await store.image(for: url, maxRetries: 1)
        await release.open()
        do { _ = try await old.value; Issue.record("Obsolete image completed after clear") }
        catch { #expect(error is CancellationError) }
        #expect(colorMatches(sampledColor(from: current), UIColor.systemGreen))
        let kept = try await store.image(for: url, maxRetries: 1)
        #expect(kept === current)
    }

    @Test func targetedClearDoesNotCancelUnrelatedInFlightImage() async throws {
        let arrived = TestGate(), release = TestGate()
        defer { Task { await release.open() } }
        let data = makeSolidImageData(color: .systemBlue)
        let session = resources.session { request in
            await arrived.open(); try await release.wait()
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, data)
        }
        let store = URLCachedImageStore(cache: URLCache(memoryCapacity: 0, diskCapacity: 0), session: session,
                                        storageDirectoryURL: resources.temporaryDirectory())
        let url = URL(string: "https://example.invalid/unrelated.jpg")!
        let loading = Task { try await store.image(for: url, maxRetries: 1) }
        try await arrived.wait()
        await store.clear(urls: [URL(string: "https://example.invalid/other.jpg")!])
        await release.open()
        let image = try await loading.value
        #expect(colorMatches(sampledColor(from: image), UIColor.systemBlue))
    }

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

private actor ImageValidationProbe {
    var count = 0
    var lastRequest: URLRequest?
    private var data: Data
    private var status = 200
    init(data: Data) { self.data = data }
    func configure(status: Int, data: Data) { self.status = status; self.data = data }
    func respond(_ request: URLRequest) throws -> (HTTPURLResponse, Data) {
        count += 1; lastRequest = request
        return (HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil,
                                headerFields: ["ETag": "\"image-v1\""])!, data)
    }
}

private actor ImageLoadCounter {
    private var count = 0
    var current: Int { count }
    func next() -> Int { count += 1; return count }
}
