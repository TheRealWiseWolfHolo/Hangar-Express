import SwiftUI
import UIKit

enum CachedRemoteImagePhase {
    case empty
    case success(Image)
    case failure
}

struct CachedRemoteImage<Content: View>: View {
    let url: URL?
    let targetSize: CGSize?
    let reloadToken: UUID?
    let maxRetryCount: Int
    let trimsTransparentPadding: Bool
    let content: (CachedRemoteImagePhase) -> Content

    @Environment(\.displayScale) private var displayScale
    @State private var phase: CachedRemoteImagePhase = .empty

    init(
        url: URL?,
        targetSize: CGSize? = nil,
        reloadToken: UUID? = nil,
        maxRetryCount: Int = 5,
        trimsTransparentPadding: Bool = false,
        @ViewBuilder content: @escaping (CachedRemoteImagePhase) -> Content
    ) {
        self.url = url
        self.targetSize = targetSize
        self.reloadToken = reloadToken
        self.maxRetryCount = maxRetryCount
        self.trimsTransparentPadding = trimsTransparentPadding
        self.content = content
    }

    var body: some View {
        content(phase)
            .task(id: reloadTaskID) {
                await loadImage()
            }
    }

    private var reloadTaskID: String {
        [
            url?.absoluteString ?? "nil",
            reloadToken?.uuidString ?? "none",
            cacheSizeKey,
            trimsTransparentPadding ? "trim" : "raw"
        ].joined(separator: "|")
    }

    private var cacheSizeKey: String {
        guard let targetSize else {
            return "original"
        }

        return "\(Int(targetSize.width.rounded(.up)))x\(Int(targetSize.height.rounded(.up)))@\(Int((displayScale * 100).rounded(.up)))"
    }

    private func loadImage() async {
        guard let url else {
            phase = .failure
            return
        }

        if let targetSize,
           (targetSize.width <= 1 || targetSize.height <= 1) {
            return
        }

        phase = .empty

        do {
            let loadedImage = try await URLCachedImageStore.shared.image(
                for: url,
                targetPointSize: targetSize,
                displayScale: displayScale,
                maxRetries: maxRetryCount
            )
            let image = trimsTransparentPadding
                ? (loadedImage.trimmingTransparentPadding() ?? loadedImage)
                : loadedImage

            guard !Task.isCancelled else {
                return
            }

            phase = .success(Image(uiImage: image))
        } catch {
            guard !Task.isCancelled else {
                return
            }

            phase = .failure
        }
    }
}

extension UIImage {
    nonisolated func trimmingTransparentPadding(alphaThreshold: UInt8 = 1) -> UIImage? {
        guard let cgImage else {
            return nil
        }

        let width = cgImage.width
        let height = cgImage.height
        guard width > 0, height > 0 else {
            return nil
        }

        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        var buffer = [UInt8](repeating: 0, count: height * bytesPerRow)

        guard let context = CGContext(
            data: &buffer,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }

        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        var minX = width
        var minY = height
        var maxX = -1
        var maxY = -1

        for y in 0 ..< height {
            let rowOffset = y * bytesPerRow
            for x in 0 ..< width {
                let alphaIndex = rowOffset + (x * bytesPerPixel) + 3
                if buffer[alphaIndex] > alphaThreshold {
                    minX = min(minX, x)
                    minY = min(minY, y)
                    maxX = max(maxX, x)
                    maxY = max(maxY, y)
                }
            }
        }

        guard maxX >= minX, maxY >= minY else {
            return nil
        }

        let cropRect = CGRect(
            x: minX,
            y: minY,
            width: maxX - minX + 1,
            height: maxY - minY + 1
        )

        guard cropRect.width > 0,
              cropRect.height > 0,
              cropRect.width < CGFloat(width) || cropRect.height < CGFloat(height),
              let croppedCGImage = cgImage.cropping(to: cropRect) else {
            return nil
        }

        return UIImage(cgImage: croppedCGImage, scale: scale, orientation: imageOrientation)
    }
}

struct CachedUpgradeCompositeImage<Content: View>: View {
    let sourceURL: URL?
    let targetURL: URL?
    let targetSize: CGSize
    let reloadToken: UUID?
    let maxRetryCount: Int
    let content: (CachedRemoteImagePhase) -> Content

    @Environment(\.displayScale) private var displayScale
    @State private var phase: CachedRemoteImagePhase = .empty

    init(
        sourceURL: URL?,
        targetURL: URL?,
        targetSize: CGSize,
        reloadToken: UUID? = nil,
        maxRetryCount: Int = 5,
        @ViewBuilder content: @escaping (CachedRemoteImagePhase) -> Content
    ) {
        self.sourceURL = sourceURL
        self.targetURL = targetURL
        self.targetSize = targetSize
        self.reloadToken = reloadToken
        self.maxRetryCount = maxRetryCount
        self.content = content
    }

    var body: some View {
        content(phase)
            .task(id: reloadTaskID) {
                await loadImage()
            }
    }

    private var reloadTaskID: String {
        [
            sourceURL?.absoluteString ?? "nil",
            targetURL?.absoluteString ?? "nil",
            reloadToken?.uuidString ?? "none",
            "\(Int(targetSize.width.rounded(.up)))x\(Int(targetSize.height.rounded(.up)))@\(Int((displayScale * 100).rounded(.up)))"
        ].joined(separator: "|")
    }

    private func loadImage() async {
        guard targetSize.width > 1, targetSize.height > 1 else {
            return
        }

        phase = .empty

        do {
            let image = try await URLCachedImageStore.shared.compositeImage(
                sourceURL: sourceURL,
                targetURL: targetURL,
                targetPointSize: targetSize,
                displayScale: displayScale,
                maxRetries: maxRetryCount
            )

            guard !Task.isCancelled else {
                return
            }

            phase = .success(Image(uiImage: image))
        } catch {
            guard !Task.isCancelled else {
                return
            }

            phase = .failure
        }
    }
}
