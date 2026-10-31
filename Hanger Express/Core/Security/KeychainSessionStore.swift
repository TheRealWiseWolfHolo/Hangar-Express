import Foundation
import Security

/// Synchronous calls stay inside the store actor, making each read/modify/write
/// operation non-reentrant and keeping Security work off the main actor.
nonisolated protocol SessionKeychainAccess: Sendable {
    func read(_ query: [String: Any]) -> (OSStatus, Data?)
    func update(_ query: [String: Any], attributes: [String: Any]) -> OSStatus
    func add(_ attributes: [String: Any]) -> OSStatus
    func delete(_ query: [String: Any]) -> OSStatus
}

nonisolated struct SystemSessionKeychainAccess: SessionKeychainAccess {
    func read(_ query: [String: Any]) -> (OSStatus, Data?) {
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        return (status, result as? Data)
    }
    func update(_ query: [String: Any], attributes: [String: Any]) -> OSStatus {
        SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
    }
    func add(_ attributes: [String: Any]) -> OSStatus {
        SecItemAdd(attributes as CFDictionary, nil)
    }
    func delete(_ query: [String: Any]) -> OSStatus {
        SecItemDelete(query as CFDictionary)
    }
}

actor KeychainSessionStore: SessionStore {
    private let service: String
    private let account: String
    private let keychain: any SessionKeychainAccess
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(
        service: String = "com.hangerexpress.rsi-session",
        account: String = "robertsspaceindustries",
        keychain: any SessionKeychainAccess = SystemSessionKeychainAccess()
    ) {
        self.service = service
        self.account = account
        self.keychain = keychain
    }

    func loadSnapshot() async throws -> StoredSessionsSnapshot {
        try loadPayload().snapshot
    }

    func save(_ session: UserSession, makeActive: Bool) async throws -> StoredSessionsSnapshot {
        let updated = try loadPayload().saving(session, makeActive: makeActive)
        try persist(updated)
        return updated.snapshot
    }

    func selectSession(id: UserSession.ID) async throws -> StoredSessionsSnapshot {
        let updated = try loadPayload().selecting(id: id)
        try persist(updated)
        return updated.snapshot
    }

    func deleteSession(id: UserSession.ID) async throws -> StoredSessionsSnapshot {
        let updated = try loadPayload().deleting(id: id)
        try persist(updated)
        return updated.snapshot
    }

    func clear() async throws -> StoredSessionsSnapshot {
        try deletePayload()
        return .empty
    }

    private func baseQuery(returnData: Bool = false) -> [String: Any] {
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

    private func loadPayload() throws -> StoredSessionsPayload {
        let (status, data) = keychain.read(baseQuery(returnData: true))
        if status == errSecItemNotFound { return .empty }
        guard status == errSecSuccess else { throw SessionStoreError.security(.read, status) }
        guard let data else { throw SessionStoreError.invalidPayload }
        if let payload = try? decoder.decode(StoredSessionsPayload.self, from: data) { return payload }
        if let legacy = try? decoder.decode(UserSession.self, from: data) {
            let migrated = StoredSessionsPayload(activeSessionID: legacy.id, sessions: [legacy])
            try persist(migrated)
            return migrated
        }
        throw SessionStoreError.invalidPayload
    }

    private func deletePayload() throws {
        let status = keychain.delete(baseQuery())
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw SessionStoreError.security(.delete, status)
        }
    }

    private func persist(_ payload: StoredSessionsPayload) throws {
        if payload.sessions.isEmpty { try deletePayload(); return }
        let data: Data
        do { data = try encoder.encode(payload) }
        catch { throw SessionStoreError.encodingFailed }
        let query = baseQuery()
        // Updating only value data preserves the existing protection class and
        // never removes the last usable item before a replacement is accepted.
        let values = [kSecValueData as String: data]
        let status = keychain.update(query, attributes: values)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw SessionStoreError.security(.update, status) }
        var attributes = query
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let addStatus = keychain.add(attributes)
        if addStatus == errSecSuccess { return }
        // Another writer may create the item between update and add. Retry the
        // non-destructive update once; never delete to resolve a duplicate.
        if addStatus == errSecDuplicateItem {
            let retryStatus = keychain.update(query, attributes: values)
            guard retryStatus == errSecSuccess else { throw SessionStoreError.security(.update, retryStatus) }
            return
        }
        throw SessionStoreError.security(.add, addStatus)
    }
}
