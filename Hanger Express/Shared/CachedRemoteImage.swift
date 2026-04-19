import SwiftUI
import UIKit

enum CachedRemoteImagePhase {
    case empty
    case success(Image)
    case failure
}

struct CachedRemoteImage<Content: View>: View {
    let url: URL?
    let reloadToken: UUID?
    let maxRetryCount: Int
    let content: (CachedRemoteImagePhase) -> Content

    @State private var phase: CachedRemoteImagePhase = .empty

    init(
        url: URL?,
        reloadToken: UUID? = nil,
        maxRetryCount: Int = 5,
        @ViewBuilder content: @escaping (CachedRemoteImagePhase) -> Content
    ) {
        self.url = url
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
        "\(url?.absoluteString ?? "nil")|\(reloadToken?.uuidString ?? "none")"
    }

    private func loadImage() async {
        guard let url else {
            phase = .failure
            return
        }

        phase = .empty

        do {
            let image = try await URLCachedImageStore.shared.image(for: url, maxRetries: maxRetryCount)

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
