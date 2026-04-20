import Foundation

protocol RemoteImageCaching: Sendable {
    func clear() async
    func clear(urls: [URL]) async
}
