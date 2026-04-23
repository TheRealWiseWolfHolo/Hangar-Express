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
    let content: (CachedRemoteImagePhase) -> Content

    @Environment(\.displayScale) private var displayScale
    @State private var phase: CachedRemoteImagePhase = .empty

    init(
        url: URL?,
        targetSize: CGSize? = nil,
        reloadToken: UUID? = nil,
        maxRetryCount: Int = 5,
        @ViewBuilder content: @escaping (CachedRemoteImagePhase) -> Content
    ) {
        self.url = url
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
            url?.absoluteString ?? "nil",
            reloadToken?.uuidString ?? "none",
            cacheSizeKey
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
            let image = try await URLCachedImageStore.shared.image(
                for: url,
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
