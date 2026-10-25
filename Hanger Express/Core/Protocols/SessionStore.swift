import Foundation

protocol SessionStore: Sendable {
    func loadSnapshot() async throws -> StoredSessionsSnapshot
    func save(_ session: UserSession, makeActive: Bool) async throws -> StoredSessionsSnapshot
    func selectSession(id: UserSession.ID) async throws -> StoredSessionsSnapshot
    func deleteSession(id: UserSession.ID) async throws -> StoredSessionsSnapshot
    func clear() async throws -> StoredSessionsSnapshot
}

nonisolated enum SessionStoreError: Error, Equatable, LocalizedError {
    enum Operation: String, Sendable { case read, update, add, delete }
    case security(Operation, Int32)
    case invalidPayload
    case encodingFailed

    var errorDescription: String? {
        switch self {
        case .security:
            AppLocalizer.string("Secure storage is unavailable. Unlock your device and try again. Your saved accounts have not been replaced.")
        case .invalidPayload:
            AppLocalizer.string("The saved account data could not be read. It has been preserved in secure storage.")
        case .encodingFailed:
            AppLocalizer.string("The account could not be saved. Your existing saved accounts have been preserved.")
        }
    }
}
