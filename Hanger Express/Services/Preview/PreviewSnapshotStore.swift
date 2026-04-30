import Foundation

actor PreviewSnapshotStore: SnapshotStore {
    private var snapshotsByAccountKey: [String: HangarSnapshot] = [:]

    func load(for session: UserSession) async -> HangarSnapshot? {
        snapshotsByAccountKey[session.accountKey]
    }

    func save(_ snapshot: HangarSnapshot, for session: UserSession) async {
        snapshotsByAccountKey[session.accountKey] = snapshot
    }

    func delete(for session: UserSession) async {
        snapshotsByAccountKey.removeValue(forKey: session.accountKey)
    }

    func clear() async {
        snapshotsByAccountKey.removeAll()
    }
}
