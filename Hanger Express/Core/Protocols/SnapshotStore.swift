import Foundation

protocol SnapshotStore: Sendable {
    func load(for session: UserSession) async -> HangarSnapshot?
    func save(_ snapshot: HangarSnapshot, for session: UserSession) async
    func delete(for session: UserSession) async
    func clear() async
}
