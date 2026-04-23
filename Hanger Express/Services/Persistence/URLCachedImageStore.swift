import CryptoKit
import Foundation
import ImageIO
import UIKit

actor URLCachedImageStore: RemoteImageCaching {
    static let shared = URLCachedImageStore()

    private let cache: URLCache
    private let session: URLSession
    private let remoteDirectoryURL: URL
    private let compositeDirectoryURL: URL
    private let memoryCache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.totalCostLimit = 128 * 1024 * 1024
        return cache
    }()

    private var inFlightRemoteTasks: [String: Task<UIImage, Error>] = [:]
    private var inFlightCompositeTasks: [String: Task<UIImage, Error>] = [:]

    init(
        cache: URLCache = URLCachedImageStore.makeCache(),
        session: URLSession? = nil,
        storageDirectoryURL: URL? = nil
    ) {
        self.cache = cache

        let rootDirectoryURL = storageDirectoryURL ?? Self.makeStorageDirectoryURL(fileManager: .default)
        remoteDirectoryURL = rootDirectoryURL.appendingPathComponent("Remote", isDirectory: true)
        compositeDirectoryURL = rootDirectoryURL.appendingPathComponent("Composite", isDirectory: true)

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
                maxRetries: maxRetries
            )
        }

        inFlightRemoteTasks[cacheDescriptor.identifier] = task

        do {
            let image = try await task.value
            inFlightRemoteTasks[cacheDescriptor.identifier] = nil
            return image
        } catch {
            inFlightRemoteTasks[cacheDescriptor.identifier] = nil
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
                maxRetries: maxRetries
            )
        }

        inFlightCompositeTasks[compositeDescriptor.identifier] = task

        do {
            let image = try await task.value
            inFlightCompositeTasks[compositeDescriptor.identifier] = nil
            return image
        } catch {
            inFlightCompositeTasks[compositeDescriptor.identifier] = nil
            throw error
        }
    }

    func clear() async {
        cancelInFlightTasks()
        memoryCache.removeAllObjects()
        cache.removeAllCachedResponses()
        removeItemIfPresent(at: remoteDirectoryURL)
        removeItemIfPresent(at: compositeDirectoryURL)
    }

    private func loadRemoteImage(
        for url: URL,
        descriptor: ImageCacheDescriptor,
        maxRetries: Int
    ) async throws -> UIImage {
        let data = try await resolvedImageData(for: url, maxRetries: maxRetries)
        let image = try decodeImage(
            from: data,
            targetPixelSize: descriptor.pixelSize
        )
        try persistImage(image, to: descriptor.fileURL)
        storeInMemory(image, identifier: descriptor.identifier)
        return image
    }

    private func loadCompositeImage(
        sourceURL: URL?,
        targetURL: URL?,
        descriptor: ImageCacheDescriptor,
        targetPointSize: CGSize,
        displayScale: CGFloat,
        maxRetries: Int
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

        try persistImage(compositeImage, to: descriptor.fileURL)
        storeInMemory(compositeImage, identifier: descriptor.identifier)
        return compositeImage
    }

    func clear(urls: [URL]) async {
        let uniqueURLs = Array(Set(urls))
        guard !uniqueURLs.isEmpty else {
            return
        }

        cancelInFlightTasks()
        memoryCache.removeAllObjects()

        for url in uniqueURLs {
            cache.removeCachedResponse(for: Self.makeRequest(for: url))
            let remoteURLHash = Self.hash(url.absoluteString)
            removeItemIfPresent(
                at: remoteDirectoryURL.appendingPathComponent(remoteURLHash, isDirectory: true)
            )
        }

        // Composite thumbnails can depend on multiple ship images, so any targeted invalidation
        // drops the derived composites as well.
        removeItemIfPresent(at: compositeDirectoryURL)
    }

    private func resolvedImageData(for url: URL, maxRetries: Int) async throws -> Data {
        let request = Self.makeRequest(for: url)

        if let cachedResponse = cache.cachedResponse(for: request),
           !cachedResponse.data.isEmpty {
            return cachedResponse.data
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

                cache.storeCachedResponse(
                    CachedURLResponse(response: response, data: data),
                    for: request
                )

                return data
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

    private func decodeImage(from data: Data, targetPixelSize: CGSize?) throws -> UIImage {
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

    private func persistImage(_ image: UIImage, to fileURL: URL) throws {
        try ensureDirectoryExists(at: fileURL.deletingLastPathComponent())

        guard let data = image.jpegData(compressionQuality: 0.86) ?? image.pngData() else {
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

        inFlightRemoteTasks.removeAll()
        inFlightCompositeTasks.removeAll()
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
        return ImageCacheDescriptor(identifier: identifier, fileURL: fileURL, pixelSize: pixelSize)
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
        let identifier = "composite:\(compositeHash)"
        let fileURL = compositeDirectoryURL.appendingPathComponent("\(compositeHash).img", isDirectory: false)
        return ImageCacheDescriptor(identifier: identifier, fileURL: fileURL, pixelSize: pixelSize)
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
}

private struct ImageCacheDescriptor: Sendable {
    let identifier: String
    let fileURL: URL
    let pixelSize: CGSize?
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
