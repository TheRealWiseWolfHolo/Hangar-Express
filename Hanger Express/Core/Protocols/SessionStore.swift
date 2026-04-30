import Foundation

protocol SessionStore: Sendable {
    func loadSnapshot() async -> StoredSessionsSnapshot
    func save(_ session: UserSession, makeActive: Bool) async -> StoredSessionsSnapshot
    func selectSession(id: UserSession.ID) async -> StoredSessionsSnapshot
    func deleteSession(id: UserSession.ID) async -> StoredSessionsSnapshot
    func clear() async -> StoredSessionsSnapshot
}
