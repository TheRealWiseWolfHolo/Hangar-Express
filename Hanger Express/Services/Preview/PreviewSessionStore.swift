import Foundation

actor PreviewSessionStore: SessionStore {
    private var payload = StoredSessionsPayload.empty

    func loadSnapshot() async -> StoredSessionsSnapshot {
        payload.snapshot
    }

    func save(_ session: UserSession, makeActive: Bool) async -> StoredSessionsSnapshot {
        payload = payload.saving(session, makeActive: makeActive)
        return payload.snapshot
    }

    func selectSession(id: UserSession.ID) async -> StoredSessionsSnapshot {
        payload = payload.selecting(id: id)
        return payload.snapshot
    }

    func deleteSession(id: UserSession.ID) async -> StoredSessionsSnapshot {
        payload = payload.deleting(id: id)
        return payload.snapshot
    }

    func clear() async -> StoredSessionsSnapshot {
        payload = .empty
        return payload.snapshot
    }
}
