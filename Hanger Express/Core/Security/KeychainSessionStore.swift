import Foundation
import Security

actor KeychainSessionStore: SessionStore {
    private let service: String
    private let account: String
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(
        service: String = "com.hangerexpress.rsi-session",
        account: String = "robertsspaceindustries"
    ) {
        self.service = service
        self.account = account
    }

    func loadSnapshot() async -> StoredSessionsSnapshot {
        guard let payload = loadPayload() else {
            return .empty
        }

        return payload.snapshot
    }

    func save(_ session: UserSession, makeActive: Bool) async -> StoredSessionsSnapshot {
        let updatedPayload = (loadPayload() ?? .empty).saving(session, makeActive: makeActive)
        persist(updatedPayload)
        return updatedPayload.snapshot
    }

    func selectSession(id: UserSession.ID) async -> StoredSessionsSnapshot {
        let updatedPayload = (loadPayload() ?? .empty).selecting(id: id)
        persist(updatedPayload)
        return updatedPayload.snapshot
    }

    func deleteSession(id: UserSession.ID) async -> StoredSessionsSnapshot {
        let updatedPayload = (loadPayload() ?? .empty).deleting(id: id)
        persist(updatedPayload)
        return updatedPayload.snapshot
    }

    func clear() async -> StoredSessionsSnapshot {
        SecItemDelete(baseQuery(returnData: false) as CFDictionary)
        return .empty
    }

    private func baseQuery(returnData: Bool) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]

        if returnData {
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne
        }

        return query
    }

    private func loadPayload() -> StoredSessionsPayload? {
        let query = baseQuery(returnData: true)
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess, let data = result as? Data else {
            return nil
        }

        if let payload = try? decoder.decode(StoredSessionsPayload.self, from: data) {
            return payload
        }

        if let legacySession = try? decoder.decode(UserSession.self, from: data) {
            let migratedPayload = StoredSessionsPayload(
                activeSessionID: legacySession.id,
                sessions: [legacySession]
            )
            persist(migratedPayload)
            return migratedPayload
        }

#if DEBUG
        print("KeychainSessionStore failed to decode the saved RSI session payload.")
#endif
        return nil
    }

    private func persist(_ payload: StoredSessionsPayload) {
        if payload.sessions.isEmpty {
            SecItemDelete(baseQuery(returnData: false) as CFDictionary)
            return
        }

        guard let data = try? encoder.encode(payload) else {
            return
        }

        let query = baseQuery(returnData: false)
        SecItemDelete(query as CFDictionary)

        var attributes = query
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly

        SecItemAdd(attributes as CFDictionary, nil)
    }
}
