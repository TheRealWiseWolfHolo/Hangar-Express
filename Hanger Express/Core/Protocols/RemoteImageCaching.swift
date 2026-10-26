import Foundation

protocol RemoteImageCaching: Sendable {
    func clear() async
    func clear(urls: [URL]) async
    func revalidate(urls: [URL], force: Bool) async -> Set<URL>
}

extension RemoteImageCaching {
    func revalidate(urls: [URL], force: Bool = false) async -> Set<URL> { [] }
}
