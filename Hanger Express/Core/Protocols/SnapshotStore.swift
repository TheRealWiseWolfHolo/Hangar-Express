import Foundation

protocol SnapshotStore: Sendable {
    func load(for session: UserSession) async throws -> HangarSnapshot?
    func save(_ snapshot: HangarSnapshot, for session: UserSession) async throws
    func delete(for session: UserSession) async throws
    func clear() async throws
}
