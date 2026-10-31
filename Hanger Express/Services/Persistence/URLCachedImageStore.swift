import CryptoKit
import Foundation
import ImageIO
import UIKit
import WebKit

nonisolated struct RemoteImagePrefetchRequest: Hashable, Sendable {
    let url: URL
    let targetPointSize: CGSize?
    let displayScale: CGFloat
    let maxRetries: Int

    init(
        url: URL,
        targetPointSize: CGSize? = nil,
        displayScale: CGFloat = 1,
        maxRetries: Int = 2
    ) {
        self.url = url
        self.targetPointSize = targetPointSize
        self.displayScale = displayScale
        self.maxRetries = maxRetries
    }
}

nonisolated struct UpgradeCompositeImagePrefetchRequest: Hashable, Sendable {
    let sourceURL: URL?
    let targetURL: URL?
    let targetPointSize: CGSize
    let displayScale: CGFloat
    let maxRetries: Int

    init(
        sourceURL: URL?,
        targetURL: URL?,
        targetPointSize: CGSize,
        displayScale: CGFloat = 1,
        maxRetries: Int = 2
    ) {
        self.sourceURL = sourceURL
        self.targetURL = targetURL
        self.targetPointSize = targetPointSize
        self.displayScale = displayScale
        self.maxRetries = maxRetries
    }
}

actor URLCachedImageStore: RemoteImageCaching {
    static let shared = URLCachedImageStore()

    private let cache: URLCache
    private let session: URLSession
    private let remoteDirectoryURL: URL
    private let compositeDirectoryURL: URL
    private let fleetCardDirectoryURL: URL
    private let memoryCache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.totalCostLimit = 128 * 1024 * 1024
        cache.countLimit = 4096
        return cache
    }()

    private var inFlightRemoteTasks: [String: Task<UIImage, Error>] = [:]
    private var inFlightCompositeTasks: [String: Task<UIImage, Error>] = [:]
    private var inFlightFleetCardTasks: [String: Task<UIImage, Error>] = [:]

    private nonisolated struct Version: Equatable, Sendable {
        let global: UInt64
        let dependencies: [String: UInt64]
    }
    private nonisolated struct Freshness: Codable, Sendable {
        var validatedAt: Date
        let fingerprint: String
        let etag: String?
        let lastModified: String?
    }
    private var epoch: UInt64 = 0
    private var sourceEpochs: [String: UInt64] = [:]
    private var descriptors: [String: ImageCacheDescriptor] = [:]
    private var descriptorAccesses: UInt64 = 0
    private var freshness: [String: Freshness] = [:]
    private var validationFailures: [String: Date] = [:]
    private var validationTasks: [String: Task<(Data, HTTPURLResponse), Error>] = [:]

    init(
        cache: URLCache = URLCachedImageStore.makeCache(),
        session: URLSession? = nil,
        storageDirectoryURL: URL? = nil
    ) {
        self.cache = cache

        let rootDirectoryURL = storageDirectoryURL ?? Self.makeStorageDirectoryURL(fileManager: .default)
        remoteDirectoryURL = rootDirectoryURL.appendingPathComponent("Remote", isDirectory: true)
        compositeDirectoryURL = rootDirectoryURL.appendingPathComponent("Composite", isDirectory: true)
        fleetCardDirectoryURL = rootDirectoryURL.appendingPathComponent("FleetCards", isDirectory: true)

        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.default
            configuration.urlCache = cache
            configuration.requestCachePolicy = .useProtocolCachePolicy
            configuration.timeoutIntervalForRequest = 30
            configuration.timeoutIntervalForResource = 60
            self.session = URLSession(configuration: configuration)
        }
    }

    func image(
        for url: URL,
        targetPointSize: CGSize? = nil,
        displayScale: CGFloat = 1,
        maxRetries: Int = 5
    ) async throws -> UIImage {
        let cacheDescriptor = remoteCacheDescriptor(
            for: url,
            targetPointSize: targetPointSize,
            displayScale: displayScale
        )

        remember(cacheDescriptor)
        let stamp = currentVersion(for: cacheDescriptor)

        if let cachedImage = memoryCache.object(forKey: cacheDescriptor.identifier as NSString) {
            return cachedImage
        }

        if let persistedImage = loadPersistedImage(at: cacheDescriptor.fileURL) {
            storeInMemory(persistedImage, identifier: cacheDescriptor.identifier)
            return persistedImage
        }

        if let task = inFlightRemoteTasks[cacheDescriptor.identifier] {
            return try await task.value
        }

        let task = Task { [self] in
            try await loadRemoteImage(
                for: url,
                descriptor: cacheDescriptor,
                maxRetries: maxRetries,
                version: stamp
            )
        }

        inFlightRemoteTasks[cacheDescriptor.identifier] = task

        do {
            let image = try await task.value
            if isCurrent(stamp, for: cacheDescriptor) { inFlightRemoteTasks[cacheDescriptor.identifier] = nil }
            return image
        } catch {
            if isCurrent(stamp, for: cacheDescriptor) { inFlightRemoteTasks[cacheDescriptor.identifier] = nil }
            throw error
        }
    }

    func compositeImage(
        sourceURL: URL?,
        targetURL: URL?,
        targetPointSize: CGSize,
        displayScale: CGFloat = 1,
        maxRetries: Int = 5
    ) async throws -> UIImage {
        let normalizedTargetSize = Self.normalizedPointSize(targetPointSize)
        let compositeDescriptor = compositeCacheDescriptor(
            sourceURL: sourceURL,
            targetURL: targetURL,
            targetPointSize: normalizedTargetSize,
            displayScale: displayScale
        )

        remember(compositeDescriptor)
        let stamp = currentVersion(for: compositeDescriptor)

        if let cachedImage = memoryCache.object(forKey: compositeDescriptor.identifier as NSString) {
            return cachedImage
        }

        if let persistedImage = loadPersistedImage(at: compositeDescriptor.fileURL) {
            storeInMemory(persistedImage, identifier: compositeDescriptor.identifier)
            return persistedImage
        }

        if let task = inFlightCompositeTasks[compositeDescriptor.identifier] {
            return try await task.value
        }

        let task = Task { [self] in
            try await loadCompositeImage(
                sourceURL: sourceURL,
                targetURL: targetURL,
                descriptor: compositeDescriptor,
                targetPointSize: normalizedTargetSize,
                displayScale: displayScale,
                maxRetries: maxRetries,
                version: stamp
            )
        }

        inFlightCompositeTasks[compositeDescriptor.identifier] = task

        do {
            let image = try await task.value
            if isCurrent(stamp, for: compositeDescriptor) { inFlightCompositeTasks[compositeDescriptor.identifier] = nil }
            return image
        } catch {
            if isCurrent(stamp, for: compositeDescriptor) { inFlightCompositeTasks[compositeDescriptor.identifier] = nil }
            throw error
        }
    }

    func fleetCardBaseImage(
        for recipe: FleetCardBaseSnapshotRecipe,
        displayScale: CGFloat = 1,
        maxRetries: Int = 5
    ) async throws -> UIImage {
        let descriptor = fleetCardCacheDescriptor(for: recipe, displayScale: displayScale)

        remember(descriptor)
        let stamp = currentVersion(for: descriptor)

        if let cachedImage = memoryCache.object(forKey: descriptor.identifier as NSString) {
            return cachedImage
        }

        if let persistedImage = loadPersistedImage(at: descriptor.fileURL) {
            storeInMemory(persistedImage, identifier: descriptor.identifier)
            return persistedImage
        }

        if let task = inFlightFleetCardTasks[descriptor.identifier] {
            return try await task.value
        }

        let task = Task { [self] in
            try await loadFleetCardBaseImage(
                for: recipe,
                descriptor: descriptor,
                displayScale: displayScale,
                maxRetries: maxRetries,
                version: stamp
            )
        }

        inFlightFleetCardTasks[descriptor.identifier] = task

        do {
            let image = try await task.value
            if isCurrent(stamp, for: descriptor) { inFlightFleetCardTasks[descriptor.identifier] = nil }
            return image
        } catch {
            if isCurrent(stamp, for: descriptor) { inFlightFleetCardTasks[descriptor.identifier] = nil }
            throw error
        }
    }

    func prefetchImages(for requests: [RemoteImagePrefetchRequest]) async {
        for request in Self.uniquePreservingOrder(requests) {
            guard !Task.isCancelled else {
                return
            }

            _ = try? await image(
                for: request.url,
                targetPointSize: request.targetPointSize,
                displayScale: request.displayScale,
                maxRetries: request.maxRetries
            )
        }
    }

    func prefetchCompositeImages(for requests: [UpgradeCompositeImagePrefetchRequest]) async {
        for request in Self.uniquePreservingOrder(requests) {
            guard !Task.isCancelled else {
                return
            }

            _ = try? await compositeImage(
                sourceURL: request.sourceURL,
                targetURL: request.targetURL,
                targetPointSize: request.targetPointSize,
                displayScale: request.displayScale,
                maxRetries: request.maxRetries
            )
        }
    }

    func prefetchFleetCardBaseImages(
        for recipes: [FleetCardBaseSnapshotRecipe],
        displayScale: CGFloat = 1,
        maxRetries: Int = 2
    ) async {
        for recipe in Self.uniquePreservingOrder(recipes) {
            guard !Task.isCancelled else {
                return
            }

            _ = try? await fleetCardBaseImage(
                for: recipe,
                displayScale: displayScale,
                maxRetries: maxRetries
            )
        }
    }

    func clear() async {
        epoch &+= 1
        sourceEpochs.removeAll(); descriptors.removeAll(); freshness.removeAll(); validationFailures.removeAll()
        validationTasks.values.forEach { $0.cancel() }; validationTasks.removeAll()
        cancelInFlightTasks()
        memoryCache.removeAllObjects()
        cache.removeAllCachedResponses()
        removeItemIfPresent(at: remoteDirectoryURL)
        removeItemIfPresent(at: compositeDirectoryURL)
        removeItemIfPresent(at: fleetCardDirectoryURL)
    }

    private func loadRemoteImage(
        for url: URL,
        descriptor: ImageCacheDescriptor,
        maxRetries: Int,
        version: Version
    ) async throws -> UIImage {
        let data = try await resolvedImageData(for: url, maxRetries: maxRetries)
        let image = try await decodeImage(
            from: data,
            sourceURL: url,
            targetPixelSize: descriptor.pixelSize
        )
        try Task.checkCancellation()
        guard isCurrent(version, for: descriptor) else { throw CancellationError() }
        try persistImage(image, to: descriptor.fileURL, preferredPathExtension: url.pathExtension)
        storeInMemory(image, identifier: descriptor.identifier)
        return image
    }

    private func loadCompositeImage(
        sourceURL: URL?,
        targetURL: URL?,
        descriptor: ImageCacheDescriptor,
        targetPointSize: CGSize,
        displayScale: CGFloat,
        maxRetries: Int,
        version: Version
    ) async throws -> UIImage {
        let sourceImage = try await loadCompositeSliceImage(
            from: sourceURL,
            targetPointSize: CGSize(width: targetPointSize.width / 2, height: targetPointSize.height),
            displayScale: displayScale,
            maxRetries: maxRetries
        )
        let targetImage = try await loadCompositeSliceImage(
            from: targetURL,
            targetPointSize: CGSize(width: targetPointSize.width / 2, height: targetPointSize.height),
            displayScale: displayScale,
            maxRetries: maxRetries
        )

        let compositeImage = renderCompositeImage(
            sourceImage: sourceImage,
            targetImage: targetImage,
            targetPointSize: targetPointSize,
            displayScale: displayScale
        )

        try Task.checkCancellation()
        guard isCurrent(version, for: descriptor) else { throw CancellationError() }
        try persistImage(compositeImage, to: descriptor.fileURL)
        storeInMemory(compositeImage, identifier: descriptor.identifier)
        return compositeImage
    }

    private func loadFleetCardBaseImage(
        for recipe: FleetCardBaseSnapshotRecipe,
        descriptor: ImageCacheDescriptor,
        displayScale: CGFloat,
        maxRetries: Int,
        version: Version
    ) async throws -> UIImage {
        async let backdropImage = loadFleetCardComponentImage(
            from: recipe.backdropURL,
            targetPointSize: recipe.pointSize,
            displayScale: displayScale,
            maxRetries: maxRetries
        )
        async let logoImage = loadFleetCardComponentImage(
            from: recipe.logoURL,
            targetPointSize: recipe.logoTargetSize,
            displayScale: displayScale,
            maxRetries: maxRetries,
            trimsTransparentPadding: true
        )

        let resolvedBackdropImage = await backdropImage
        let resolvedLogoImage = await logoImage

        let renderedImage = try await FleetCardBaseSnapshotRenderer.render(
            recipe: recipe,
            backdropImage: resolvedBackdropImage,
            logoImage: resolvedLogoImage,
            displayScale: displayScale
        )

        try Task.checkCancellation()
        guard isCurrent(version, for: descriptor) else { throw CancellationError() }
        try persistImage(renderedImage, to: descriptor.fileURL, preferredPathExtension: "png")
        storeInMemory(renderedImage, identifier: descriptor.identifier)
        return renderedImage
    }

    func clear(urls: [URL]) async {
        invalidateSources(Set(urls), removeRaw: true)
    }

    private func remember(_ descriptor: ImageCacheDescriptor) {
        descriptors[descriptor.identifier] = descriptor
        descriptorAccesses &+= 1
        guard descriptors.count > 1024, descriptorAccesses % 256 == 0 else { return }
        descriptors = descriptors.filter { key, _ in
            memoryCache.object(forKey: key as NSString) != nil || inFlightRemoteTasks[key] != nil
                || inFlightCompositeTasks[key] != nil || inFlightFleetCardTasks[key] != nil
        }
        let retained = Set(descriptors.values.flatMap(\.dependencies)).union(validationTasks.keys)
        freshness = freshness.filter { retained.contains($0.key) }
        validationFailures = validationFailures.filter { retained.contains($0.key) }
    }

    private func currentVersion(for descriptor: ImageCacheDescriptor) -> Version {
        Version(global: epoch, dependencies: Dictionary(uniqueKeysWithValues: descriptor.dependencies.map { ($0, sourceEpochs[$0, default: 0]) }))
    }
    private func isCurrent(_ version: Version, for descriptor: ImageCacheDescriptor) -> Bool {
        version == currentVersion(for: descriptor)
    }
    private func invalidateSources(_ urls: Set<URL>, removeRaw: Bool) {
        let hashes = Set(urls.map { Self.hash($0.absoluteString) })
        guard !hashes.isEmpty else { return }
        for hash in hashes {
            sourceEpochs[hash, default: 0] &+= 1
            validationTasks.removeValue(forKey: hash)?.cancel()
        }
        for (key, descriptor) in descriptors where !descriptor.dependencies.isDisjoint(with: hashes) {
            inFlightRemoteTasks.removeValue(forKey: key)?.cancel()
            inFlightCompositeTasks.removeValue(forKey: key)?.cancel()
            inFlightFleetCardTasks.removeValue(forKey: key)?.cancel()
            memoryCache.removeObject(forKey: key as NSString)
            removeItemIfPresent(at: descriptor.fileURL)
        }
        descriptors = descriptors.filter { $0.value.dependencies.isDisjoint(with: hashes) }
        for url in urls {
            let hash = Self.hash(url.absoluteString)
            if removeRaw { cache.removeCachedResponse(for: Self.makeRequest(for: url)) }
            freshness.removeValue(forKey: hash); validationFailures.removeValue(forKey: hash)
            removeItemIfPresent(at: remoteDirectoryURL.appendingPathComponent(hash, isDirectory: true))
        }
        // Dependency hashes are part of derived filenames, including entries
        // created in earlier processes and not yet loaded into this process.
        for directory in [compositeDirectoryURL, fleetCardDirectoryURL] {
            for file in (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
                where hashes.contains(where: { file.lastPathComponent.contains($0) }) {
                removeItemIfPresent(at: file)
            }
        }
    }

    /// Validation is scheduled by AppModel after refresh, never on the critical
    /// path for presenting an already processed image.
    /// Only sources already present in the processed cache are revalidated.
    /// A no-op inventory refresh within the ten-minute image freshness window
    /// issues no requests and keeps decoded/derived variants intact.
    func revalidate(urls: [URL], force: Bool = false) async -> Set<URL> {
        var changed: Set<URL> = []
        for url in Set(urls) {
            guard !Task.isCancelled else { break }
            let hash = Self.hash(url.absoluteString)
            guard let old = readFreshness(url: url) else { continue }
            if !force, Date.now.timeIntervalSince(old.validatedAt) < 600 { continue }
            if !force, let failure = validationFailures[hash], Date.now.timeIntervalSince(failure) < 60 { continue }
            let originalEpoch = epoch
            let originalSourceEpoch = sourceEpochs[hash, default: 0]
            let task: Task<(Data, HTTPURLResponse), Error>
            if let pending = validationTasks[hash] { task = pending }
            else {
                let session = session
                task = Task {
                    var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
                    if let etag = old.etag { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }
                    else if let modified = old.lastModified { request.setValue(modified, forHTTPHeaderField: "If-Modified-Since") }
                    let (data, response) = try await session.data(for: request)
                    guard let response = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
                    return (data, response)
                }
                validationTasks[hash] = task
            }
            do {
                let (data, response) = try await task.value
                guard epoch == originalEpoch else { continue }
                guard sourceEpochs[hash, default: 0] == originalSourceEpoch else { changed.insert(url); continue }
                validationTasks[hash] = nil
                if response.statusCode == 304 {
                    guard old.etag != nil || old.lastModified != nil else { throw URLError(.badServerResponse) }
                    var updated = old; updated.validatedAt = .now
                    writeFreshness(updated, url: url)
                } else {
                    guard (200..<300).contains(response.statusCode), Self.isImageData(data) else { throw URLError(.cannotDecodeContentData) }
                    let updated = Self.makeFreshness(data: data, response: response)
                    if updated.fingerprint != old.fingerprint {
                        invalidateSources([url], removeRaw: true)
                        changed.insert(url)
                    }
                    cache.storeCachedResponse(CachedURLResponse(response: response, data: data), for: Self.makeRequest(for: url))
                    writeFreshness(updated, url: url)
                }
                validationFailures[hash] = nil
            } catch {
                if epoch == originalEpoch, sourceEpochs[hash, default: 0] == originalSourceEpoch {
                    validationTasks[hash] = nil; validationFailures[hash] = .now
                }
                // Offline validation retains a usable processed image.
            }
        }
        return changed
    }

    private func metadataURL(_ url: URL) -> URL {
        remoteDirectoryURL.appendingPathComponent(Self.hash(url.absoluteString), isDirectory: true).appendingPathComponent("metadata.json")
    }
    private func readFreshness(url: URL) -> Freshness? {
        let hash = Self.hash(url.absoluteString)
        if let value = freshness[hash] { return value }
        if let data = try? Data(contentsOf: metadataURL(url)), let value = try? JSONDecoder().decode(Freshness.self, from: data) {
            freshness[hash] = value; return value
        }
        // Migrate legacy processed files without discarding them. Their oldest
        // modification time provides a conservative initial freshness date.
        let folder = metadataURL(url).deletingLastPathComponent()
        let dates = ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
            .filter { $0.pathExtension == "img" }.compactMap { try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate }
        guard let date = dates.min() else { return nil }
        let cached = cache.cachedResponse(for: Self.makeRequest(for: url))
        let response = cached?.response as? HTTPURLResponse
        let value = Freshness(validatedAt: date, fingerprint: cached.map { Self.fingerprint($0.data) } ?? "",
            etag: response?.value(forHTTPHeaderField: "ETag"), lastModified: response?.value(forHTTPHeaderField: "Last-Modified"))
        writeFreshness(value, url: url); return value
    }
    private func writeFreshness(_ value: Freshness, url: URL) {
        freshness[Self.hash(url.absoluteString)] = value
        let file = metadataURL(url)
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(value) { try? data.write(to: file, options: .atomic) }
    }
    private nonisolated static func makeFreshness(data: Data, response: URLResponse) -> Freshness {
        let http = response as? HTTPURLResponse
        return Freshness(validatedAt: .now, fingerprint: fingerprint(data), etag: http?.value(forHTTPHeaderField: "ETag"),
                         lastModified: http?.value(forHTTPHeaderField: "Last-Modified"))
    }
    private nonisolated static func fingerprint(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    private nonisolated static func isImageData(_ data: Data) -> Bool {
        data.isLikelySVGImageData || CGImageSourceCreateWithData(data as CFData, nil) != nil
    }

    private func resolvedImageData(for url: URL, maxRetries: Int) async throws -> Data {
        let request = Self.makeRequest(for: url)

        if let cachedResponse = cache.cachedResponse(for: request),
           !cachedResponse.data.isEmpty {
            if freshness[Self.hash(url.absoluteString)] == nil {
                writeFreshness(Self.makeFreshness(data: cachedResponse.data, response: cachedResponse.response), url: url)
            }
            return cachedResponse.data
        }

        var lastError: Error?
        let attempts = max(1, maxRetries)

        for attempt in 1 ... attempts {
            try Task.checkCancellation()
            do {
                let (data, response) = try await session.data(for: request)

                if let httpResponse = response as? HTTPURLResponse,
                   !(200 ..< 300).contains(httpResponse.statusCode) {
                    throw URLError(.badServerResponse)
                }

                try Task.checkCancellation()
                guard Self.isImageData(data) else { throw URLError(.cannotDecodeContentData) }
                writeFreshness(Self.makeFreshness(data: data, response: response), url: url)
                cache.storeCachedResponse(
                    CachedURLResponse(response: response, data: data),
                    for: request
                )

                return data
            } catch {
                if Task.isCancelled || error is CancellationError { throw CancellationError() }
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

    private func decodeImage(
        from data: Data,
        sourceURL: URL,
        targetPixelSize: CGSize?
    ) async throws -> UIImage {
        if sourceURL.isSVGImageURL || data.isLikelySVGImageData {
            return try await SVGImageRasterizer.rasterize(
                svgData: data,
                targetPixelSize: targetPixelSize
            )
        }

        return try decodeRasterImage(from: data, targetPixelSize: targetPixelSize)
    }

    private func decodeRasterImage(from data: Data, targetPixelSize: CGSize?) throws -> UIImage {
        guard let imageSource = CGImageSourceCreateWithData(
            data as CFData,
            [kCGImageSourceShouldCache: false] as CFDictionary
        ) else {
            throw RemoteImageStoreError.invalidImageData(nil)
        }

        if let targetPixelSize {
            let maxDimension = Int(max(targetPixelSize.width, targetPixelSize.height).rounded(.up))
            if maxDimension > 0,
               let cgImage = CGImageSourceCreateThumbnailAtIndex(
                   imageSource,
                   0,
                   [
                       kCGImageSourceCreateThumbnailFromImageAlways: true,
                       kCGImageSourceCreateThumbnailWithTransform: true,
                       kCGImageSourceShouldCacheImmediately: true,
                       kCGImageSourceThumbnailMaxPixelSize: maxDimension
                   ] as CFDictionary
               ) {
                return UIImage(cgImage: cgImage)
            }
        }

        if let cgImage = CGImageSourceCreateImageAtIndex(
            imageSource,
            0,
            [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
        ) {
            return UIImage(cgImage: cgImage)
        }

        throw RemoteImageStoreError.invalidImageData(nil)
    }

    private func loadCompositeSliceImage(
        from url: URL?,
        targetPointSize: CGSize,
        displayScale: CGFloat,
        maxRetries: Int
    ) async throws -> UIImage? {
        guard let url else {
            return nil
        }

        do {
            return try await image(
                for: url,
                targetPointSize: targetPointSize,
                displayScale: displayScale,
                maxRetries: maxRetries
            )
        } catch {
            return nil
        }
    }

    private func loadFleetCardComponentImage(
        from url: URL?,
        targetPointSize: CGSize,
        displayScale: CGFloat,
        maxRetries: Int,
        trimsTransparentPadding: Bool = false
    ) async -> UIImage? {
        guard let url else {
            return nil
        }

        do {
            let image = try await image(
                for: url,
                targetPointSize: targetPointSize,
                displayScale: displayScale,
                maxRetries: maxRetries
            )

            if trimsTransparentPadding {
                return image.trimmingTransparentPadding() ?? image
            }

            return image
        } catch {
            return nil
        }
    }

    private func renderCompositeImage(
        sourceImage: UIImage?,
        targetImage: UIImage?,
        targetPointSize: CGSize,
        displayScale: CGFloat
    ) -> UIImage {
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = max(displayScale, 1)
        format.opaque = true

        let renderer = UIGraphicsImageRenderer(size: targetPointSize, format: format)
        return renderer.image { context in
            let bounds = CGRect(origin: .zero, size: targetPointSize)
            let leftRect = CGRect(x: 0, y: 0, width: bounds.width / 2, height: bounds.height)
            let rightRect = CGRect(x: bounds.width / 2, y: 0, width: bounds.width / 2, height: bounds.height)

            UIColor.tertiarySystemBackground.setFill()
            context.fill(bounds)

            drawCompositeSlice(
                sourceImage,
                fallbackSystemImage: "arrow.uturn.backward.circle.fill",
                in: leftRect,
                context: context.cgContext
            )
            drawCompositeSlice(
                targetImage,
                fallbackSystemImage: "arrow.up.right.circle.fill",
                in: rightRect,
                context: context.cgContext
            )

            UIColor.black.withAlphaComponent(0.35).setFill()
            context.fill(CGRect(x: bounds.midX - 2, y: 0, width: 4, height: bounds.height))

            UIColor.white.withAlphaComponent(0.9).setFill()
            context.fill(CGRect(x: bounds.midX - 0.75, y: 0, width: 1.5, height: bounds.height))

            let circleRect = CGRect(x: bounds.midX - 16, y: bounds.midY - 16, width: 32, height: 32)
            let circlePath = UIBezierPath(ovalIn: circleRect)
            UIColor.black.withAlphaComponent(0.4).setFill()
            circlePath.fill()
            UIColor.white.withAlphaComponent(0.15).setStroke()
            circlePath.lineWidth = 0.75
            circlePath.stroke()

            let arrowConfiguration = UIImage.SymbolConfiguration(pointSize: 16, weight: .bold)
            let arrowImage = UIImage(systemName: "arrow.right", withConfiguration: arrowConfiguration)?
                .withTintColor(.white, renderingMode: .alwaysOriginal)
            arrowImage?.draw(in: CGRect(x: bounds.midX - 8, y: bounds.midY - 8, width: 16, height: 16))
        }
    }

    private func drawCompositeSlice(
        _ image: UIImage?,
        fallbackSystemImage: String,
        in rect: CGRect,
        context: CGContext
    ) {
        context.saveGState()
        context.clip(to: rect)

        if let image {
            let drawRect = aspectFillRect(for: image.size, in: rect)
            image.draw(in: drawRect)
        } else {
            let colors = [
                UIColor.systemGray5.cgColor,
                UIColor.systemGray4.cgColor
            ] as CFArray
            let colorSpace = CGColorSpaceCreateDeviceRGB()
            let locations: [CGFloat] = [0, 1]

            if let gradient = CGGradient(colorsSpace: colorSpace, colors: colors, locations: locations) {
                context.drawLinearGradient(
                    gradient,
                    start: CGPoint(x: rect.minX, y: rect.minY),
                    end: CGPoint(x: rect.maxX, y: rect.maxY),
                    options: []
                )
            }

            let symbolConfiguration = UIImage.SymbolConfiguration(pointSize: 22, weight: .semibold)
            let fallbackImage = UIImage(systemName: fallbackSystemImage, withConfiguration: symbolConfiguration)?
                .withTintColor(UIColor.secondaryLabel, renderingMode: .alwaysOriginal)

            let symbolRect = CGRect(x: rect.midX - 11, y: rect.midY - 11, width: 22, height: 22)
            fallbackImage?.draw(in: symbolRect)
        }

        context.restoreGState()
    }

    private func persistImage(
        _ image: UIImage,
        to fileURL: URL,
        preferredPathExtension: String? = nil
    ) throws {
        try ensureDirectoryExists(at: fileURL.deletingLastPathComponent())

        let pngPreferredExtensions: Set<String> = ["png", "svg", "webp", "gif", "heic", "heif", "avif"]
        let prefersPNG = preferredPathExtension.map { pngPreferredExtensions.contains($0.localizedLowercase) } ?? false
        let data = prefersPNG
            ? image.pngData() ?? image.jpegData(compressionQuality: 0.9)
            : image.jpegData(compressionQuality: 0.86) ?? image.pngData()

        guard let data else {
            throw RemoteImageStoreError.unexpectedFailure(fileURL)
        }

        try data.write(to: fileURL, options: .atomic)
    }

    private func loadPersistedImage(at fileURL: URL) -> UIImage? {
        guard let data = try? Data(contentsOf: fileURL),
              let image = UIImage(data: data) else {
            return nil
        }

        return image
    }

    private func storeInMemory(_ image: UIImage, identifier: String) {
        memoryCache.setObject(
            image,
            forKey: identifier as NSString,
            cost: estimatedMemoryCost(for: image)
        )
    }

    private func estimatedMemoryCost(for image: UIImage) -> Int {
        let scale = image.scale > 0 ? image.scale : 1
        let pixelWidth = Int((image.size.width * scale).rounded(.up))
        let pixelHeight = Int((image.size.height * scale).rounded(.up))
        return max(1, pixelWidth * pixelHeight * 4)
    }

    private func ensureDirectoryExists(at directoryURL: URL) throws {
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true,
            attributes: nil
        )
    }

    private func removeItemIfPresent(at url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return
        }

        try? FileManager.default.removeItem(at: url)
    }

    private func cancelInFlightTasks() {
        for task in inFlightRemoteTasks.values {
            task.cancel()
        }

        for task in inFlightCompositeTasks.values {
            task.cancel()
        }

        for task in inFlightFleetCardTasks.values {
            task.cancel()
        }

        inFlightRemoteTasks.removeAll()
        inFlightCompositeTasks.removeAll()
        inFlightFleetCardTasks.removeAll()
    }

    private func aspectFillRect(for imageSize: CGSize, in containerRect: CGRect) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0 else {
            return containerRect
        }

        let scale = max(containerRect.width / imageSize.width, containerRect.height / imageSize.height)
        let drawSize = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        return CGRect(
            x: containerRect.midX - (drawSize.width / 2),
            y: containerRect.midY - (drawSize.height / 2),
            width: drawSize.width,
            height: drawSize.height
        )
    }

    private func remoteCacheDescriptor(
        for url: URL,
        targetPointSize: CGSize?,
        displayScale: CGFloat
    ) -> ImageCacheDescriptor {
        let urlHash = Self.hash(url.absoluteString)
        let pixelSize = Self.normalizedPixelSize(for: targetPointSize, displayScale: displayScale)
        let variantKey = Self.cacheVariantKey(for: pixelSize)
        let identifier = "remote:\(urlHash):\(variantKey)"
        let fileURL = remoteDirectoryURL
            .appendingPathComponent(urlHash, isDirectory: true)
            .appendingPathComponent("\(variantKey).img", isDirectory: false)
        return ImageCacheDescriptor(identifier: identifier, fileURL: fileURL, pixelSize: pixelSize, dependencies: [urlHash])
    }

    private func compositeCacheDescriptor(
        sourceURL: URL?,
        targetURL: URL?,
        targetPointSize: CGSize,
        displayScale: CGFloat
    ) -> ImageCacheDescriptor {
        let pixelSize = Self.normalizedPixelSize(for: targetPointSize, displayScale: displayScale)
            ?? CGSize(width: 1, height: 1)
        let payload = [
            sourceURL?.absoluteString ?? "none",
            targetURL?.absoluteString ?? "none",
            Self.cacheVariantKey(for: pixelSize)
        ].joined(separator: "|")
        let compositeHash = Self.hash(payload)
        let dependencies = Set([sourceURL, targetURL].compactMap { $0 }.map { Self.hash($0.absoluteString) })
        let compositeKey = ([compositeHash] + dependencies.sorted()).joined(separator: "-")
        let identifier = "composite:\(compositeKey)"
        let fileURL = compositeDirectoryURL.appendingPathComponent("\(compositeKey).img", isDirectory: false)
        return ImageCacheDescriptor(identifier: identifier, fileURL: fileURL, pixelSize: pixelSize, dependencies: dependencies)
    }

    private func fleetCardCacheDescriptor(
        for recipe: FleetCardBaseSnapshotRecipe,
        displayScale: CGFloat
    ) -> ImageCacheDescriptor {
        let pixelSize = Self.normalizedPixelSize(for: recipe.pointSize, displayScale: displayScale)
            ?? CGSize(width: 1, height: 1)
        let payload = [
            recipe.cachePayload,
            Self.cacheVariantKey(for: pixelSize)
        ].joined(separator: "|")
        let renderedHash = Self.hash(payload)
        let dependencies = Set([recipe.backdropURL, recipe.logoURL].compactMap { $0 }.map { Self.hash($0.absoluteString) })
        let renderedKey = ([renderedHash] + dependencies.sorted()).joined(separator: "-")
        let identifier = "fleet-card:\(renderedKey)"
        let fileURL = fleetCardDirectoryURL.appendingPathComponent("\(renderedKey).img", isDirectory: false)
        return ImageCacheDescriptor(identifier: identifier, fileURL: fileURL, pixelSize: pixelSize, dependencies: dependencies)
    }

    private nonisolated static func normalizedPixelSize(
        for pointSize: CGSize?,
        displayScale: CGFloat
    ) -> CGSize? {
        guard let pointSize else {
            return nil
        }

        let normalizedPointSize = normalizedPointSize(pointSize)
        return CGSize(
            width: ceil(normalizedPointSize.width * max(displayScale, 1)),
            height: ceil(normalizedPointSize.height * max(displayScale, 1))
        )
    }

    private nonisolated static func normalizedPointSize(_ size: CGSize) -> CGSize {
        CGSize(
            width: max(1, size.width.rounded(.up)),
            height: max(1, size.height.rounded(.up))
        )
    }

    private nonisolated static func cacheVariantKey(for pixelSize: CGSize?) -> String {
        guard let pixelSize else {
            return "original"
        }

        return "\(Int(pixelSize.width))x\(Int(pixelSize.height))"
    }

    private nonisolated static func makeStorageDirectoryURL(fileManager: FileManager) -> URL {
        let cachesDirectory = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        return cachesDirectory
            .appendingPathComponent("HangerExpress", isDirectory: true)
            .appendingPathComponent("ProcessedImages", isDirectory: true)
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

    private nonisolated static func hash(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private nonisolated static func uniquePreservingOrder<Value: Hashable>(_ values: [Value]) -> [Value] {
        var seen: Set<Value> = []
        var uniqueValues: [Value] = []
        uniqueValues.reserveCapacity(values.count)

        for value in values where seen.insert(value).inserted {
            uniqueValues.append(value)
        }

        return uniqueValues
    }
}

private extension URL {
    nonisolated var isSVGImageURL: Bool {
        pathExtension.localizedLowercase == "svg"
    }
}

private extension Data {
    nonisolated var isLikelySVGImageData: Bool {
        let sampleLength = Swift.min(count, 1024)
        guard sampleLength > 0 else {
            return false
        }

        let sample = prefix(sampleLength)
        guard let text = String(data: sample, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .localizedLowercase else {
            return false
        }

        return text.contains("<svg") || text.contains("<?xml")
    }
}

@MainActor
private final class SVGImageRasterizer: NSObject, WKNavigationDelegate {
    private var navigationContinuation: CheckedContinuation<Void, Error>?
    private var webView: WKWebView?

    static func rasterize(svgData: Data, targetPixelSize: CGSize?) async throws -> UIImage {
        let rasterizer = SVGImageRasterizer()
        return try await rasterizer.rasterize(svgData: svgData, targetPixelSize: targetPixelSize)
    }

    private func rasterize(svgData: Data, targetPixelSize: CGSize?) async throws -> UIImage {
        let viewportSize = Self.viewportSize(for: targetPixelSize)
        let webView = Self.makeWebView(size: viewportSize)
        webView.navigationDelegate = self
        self.webView = webView

        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                navigationContinuation = continuation
                webView.loadHTMLString(Self.htmlDocument(for: svgData), baseURL: nil)
            }

            let configuration = WKSnapshotConfiguration()
            configuration.rect = CGRect(origin: .zero, size: viewportSize)
            configuration.afterScreenUpdates = true

            let image = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<UIImage, Error>) in
                webView.takeSnapshot(with: configuration) { image, error in
                    if let error {
                        continuation.resume(throwing: error)
                        return
                    }

                    guard let image else {
                        continuation.resume(
                            throwing: RemoteImageStoreError.invalidImageData(nil)
                        )
                        return
                    }

                    continuation.resume(returning: image)
                }
            }

            self.webView = nil
            return image
        } catch {
            self.webView = nil
            throw error
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        navigationContinuation?.resume()
        navigationContinuation = nil
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        navigationContinuation?.resume(throwing: error)
        navigationContinuation = nil
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        navigationContinuation?.resume(throwing: error)
        navigationContinuation = nil
    }

    private static func viewportSize(for targetPixelSize: CGSize?) -> CGSize {
        guard let targetPixelSize,
              targetPixelSize.width > 0,
              targetPixelSize.height > 0 else {
            return CGSize(width: 1024, height: 1024)
        }

        return CGSize(
            width: max(1, targetPixelSize.width.rounded(.up)),
            height: max(1, targetPixelSize.height.rounded(.up))
        )
    }

    private static func makeWebView(size: CGSize) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: CGRect(origin: .zero, size: size), configuration: configuration)
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        webView.scrollView.isScrollEnabled = false
        return webView
    }

    private static func htmlDocument(for svgData: Data) -> String {
        let base64 = svgData.base64EncodedString()
        return """
        <!doctype html>
        <html>
        <head>
          <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no">
          <style>
            html, body {
              margin: 0;
              padding: 0;
              width: 100%;
              height: 100%;
              background: transparent;
              overflow: hidden;
            }

            body {
              display: flex;
              align-items: center;
              justify-content: center;
            }

            img {
              display: block;
              width: 100%;
              height: 100%;
              object-fit: contain;
            }
          </style>
        </head>
        <body>
          <img alt="" src="data:image/svg+xml;base64,\(base64)" />
        </body>
        </html>
        """
    }
}

private nonisolated struct ImageCacheDescriptor: Sendable {
    let identifier: String
    let fileURL: URL
    let pixelSize: CGSize?
    let dependencies: Set<String>
}

enum RemoteImageStoreError: LocalizedError {
    case invalidImageData(URL?)
    case unexpectedFailure(URL)

    var errorDescription: String? {
        switch self {
        case let .invalidImageData(url):
            if let url {
                return "The downloaded image data from \(url.absoluteString) was invalid."
            }

            return "The downloaded image data was invalid."
        case let .unexpectedFailure(url):
            return "The image at \(url.absoluteString) could not be loaded."
        }
    }
}
