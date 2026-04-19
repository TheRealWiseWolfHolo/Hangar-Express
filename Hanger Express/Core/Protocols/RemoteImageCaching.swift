import Foundation

protocol RemoteImageCaching: Sendable {
    func clear() async
}
