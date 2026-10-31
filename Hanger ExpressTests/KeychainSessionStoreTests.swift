import Foundation
import Security
import Testing
@testable import Hanger_Express

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct KeychainSessionStoreTests {
    @Test func missingItemLoadsEmptyWithoutWriting() async throws {
        let api = MemorySessionKeychain()
        let snapshot = try await KeychainSessionStore(keychain: api).loadSnapshot()
        #expect(snapshot == .empty)
        #expect(api.calls == ["read"])
    }

    @Test func firstSaveAddsOnlyAfterUpdateReportsMissingAndPreservesIdentifiers() async throws {
        let api = MemorySessionKeychain()
        let session = storageTestSession("first")
        let result = try await KeychainSessionStore(keychain: api).save(session, makeActive: true)
        #expect(result.activeSession == session)
        #expect(api.calls == ["read", "update", "add"])
        let query = try #require(api.lastQuery)
        #expect(query[kSecClass as String] as? String == kSecClassGenericPassword as String)
        #expect(query[kSecAttrService as String] as? String == "com.hangerexpress.rsi-session")
        #expect(query[kSecAttrAccount as String] as? String == "robertsspaceindustries")
        #expect(api.accessibility == kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String)
    }

    @Test func updateFailureNeverDeletesOrReplacesPriorBytes() async throws {
        let old = storageTestSession("old")
        let bytes = try storagePayload(old)
        let api = MemorySessionKeychain(data: bytes)
        api.faults(updates: [errSecAuthFailed])
        await #expect(throws: SessionStoreError.security(.update, errSecAuthFailed)) {
            try await KeychainSessionStore(keychain: api).save(storageTestSession("new"), makeActive: true)
        }
        #expect(api.data == bytes)
        #expect(api.calls == ["read", "update"])
    }

    @Test func successfulUpdateKeepsProtectionClassAndOtherAccounts() async throws {
        let first = storageTestSession("first")
        let second = storageTestSession("second")
        let api = MemorySessionKeychain(data: try storagePayload(first), accessibility: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
        let store = KeychainSessionStore(keychain: api)
        let saved = try await store.save(second, makeActive: false)
        #expect(saved.activeSession == first)
        #expect(Set(saved.savedSessions) == Set([first, second]))
        #expect(api.accessibility == kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
        #expect(api.lastUpdateKeys == Set([kSecValueData as String]))
        let switched = try await store.selectSession(id: second.id)
        #expect(switched.activeSession == second)
        let removed = try await store.deleteSession(id: second.id)
        #expect(removed.savedSessions == [first])
        #expect(!api.calls.contains("delete"))
    }

    @Test func addFailureIsReportedAndDoesNotReturnUnpersistedSession() async throws {
        let api = MemorySessionKeychain()
        api.faults(add: errSecNotAvailable)
        await #expect(throws: SessionStoreError.security(.add, errSecNotAvailable)) {
            try await KeychainSessionStore(keychain: api).save(storageTestSession("new"), makeActive: true)
        }
        #expect(api.data == nil)
        #expect(api.calls == ["read", "update", "add"])
    }

    @Test func lockedOrInaccessibleReadPreventsAnyMutation() async throws {
        for status in [errSecInteractionNotAllowed, errSecNotAvailable, errSecAuthFailed] {
            let bytes = try storagePayload(storageTestSession("old"))
            let api = MemorySessionKeychain(data: bytes)
            api.faults(read: status)
            let store = KeychainSessionStore(keychain: api)
            await #expect(throws: SessionStoreError.security(.read, status)) { try await store.loadSnapshot() }
            await #expect(throws: SessionStoreError.security(.read, status)) {
                try await store.save(storageTestSession("new"), makeActive: true)
            }
            #expect(api.data == bytes)
            #expect(api.calls == ["read", "read"])
        }
    }

    @Test func malformedOrMissingReturnedDataIsNotAnEmptyStore() async throws {
        for data in [Data("invalid payload".utf8), Data()] {
            let api = MemorySessionKeychain(data: data)
            let store = KeychainSessionStore(keychain: api)
            await #expect(throws: SessionStoreError.invalidPayload) {
                try await store.save(storageTestSession("new"), makeActive: true)
            }
            #expect(api.data == data)
            #expect(api.calls == ["read"])
        }
        let api = MemorySessionKeychain()
        api.faults(read: errSecSuccess)
        await #expect(throws: SessionStoreError.invalidPayload) { try await KeychainSessionStore(keychain: api).loadSnapshot() }
    }

    @Test func legacySessionMigratesInPlaceWithoutChangingIdentityOrProtection() async throws {
        let session = storageTestSession("legacy")
        let api = MemorySessionKeychain(data: try JSONEncoder().encode(session), accessibility: kSecAttrAccessibleAfterFirstUnlock as String)
        let result = try await KeychainSessionStore(keychain: api).loadSnapshot()
        #expect(result.activeSession == session)
        let migrated = try JSONDecoder().decode(StoredSessionsPayload.self, from: #require(api.data))
        #expect(migrated.activeSessionID == session.id)
        #expect(migrated.sessions == [session])
        #expect(api.calls == ["read", "update"])
        #expect(api.accessibility == kSecAttrAccessibleAfterFirstUnlock as String)
    }

    @Test func failedLegacyMigrationLeavesLegacyBytesReadableForRetry() async throws {
        let session = storageTestSession("legacy")
        let bytes = try JSONEncoder().encode(session)
        let api = MemorySessionKeychain(data: bytes)
        api.faults(updates: [errSecInteractionNotAllowed])
        let store = KeychainSessionStore(keychain: api)
        await #expect(throws: SessionStoreError.security(.update, errSecInteractionNotAllowed)) { try await store.loadSnapshot() }
        #expect(api.data == bytes)
        let recovered = try await store.loadSnapshot()
        #expect(recovered.activeSession == session)
        #expect(!api.calls.contains("delete"))
    }

    @Test func duplicateDuringAddRetriesUpdateOnceWithoutDelete() async throws {
        let api = MemorySessionKeychain(data: try storagePayload(storageTestSession("old")))
        api.faults(updates: [errSecItemNotFound, errSecSuccess])
        let result = try await KeychainSessionStore(keychain: api).save(storageTestSession("new"), makeActive: true)
        #expect(result.savedSessions.count == 2)
        #expect(api.calls == ["read", "update", "add", "update"])
    }

    @Test func failedDuplicateRetryPreservesOldItemAndIsBounded() async throws {
        let bytes = try storagePayload(storageTestSession("old"))
        let api = MemorySessionKeychain(data: bytes)
        api.faults(updates: [errSecItemNotFound, errSecInteractionNotAllowed])
        await #expect(throws: SessionStoreError.security(.update, errSecInteractionNotAllowed)) {
            try await KeychainSessionStore(keychain: api).save(storageTestSession("new"), makeActive: true)
        }
        #expect(api.data == bytes)
        #expect(api.calls == ["read", "update", "add", "update"])
    }

    @Test func failedClearAndLastAccountDeletePreservePriorData() async throws {
        let session = storageTestSession("old")
        let bytes = try storagePayload(session)
        let api = MemorySessionKeychain(data: bytes)
        api.faults(delete: errSecInteractionNotAllowed)
        let store = KeychainSessionStore(keychain: api)
        await #expect(throws: SessionStoreError.security(.delete, errSecInteractionNotAllowed)) { try await store.clear() }
        await #expect(throws: SessionStoreError.security(.delete, errSecInteractionNotAllowed)) { try await store.deleteSession(id: session.id) }
        #expect(api.data == bytes)
        api.faults()
        let deleted = try await store.deleteSession(id: session.id)
        #expect(deleted == .empty)
        let empty = try await store.clear()
        #expect(empty == .empty)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["HANGAR_RUN_KEYCHAIN_INTEGRATION"] == "1",
                   "Requires an explicitly signed Keychain test host"))
    func realSecurityAdapterRoundTripsOnlyAnIsolatedService() async throws {
        let store = KeychainSessionStore(service: "com.hangerexpress.tests.\(UUID().uuidString)", account: "fixture")
        do {
            let first = storageTestSession("first")
            let second = storageTestSession("second")
            _ = try await store.save(first, makeActive: true)
            _ = try await store.save(second, makeActive: true)
            let loaded = try await store.loadSnapshot()
            #expect(Set(loaded.savedSessions) == Set([first, second]))
            #expect(loaded.activeSession == second)
            _ = try await store.deleteSession(id: second.id)
            let remaining = try await store.loadSnapshot()
            #expect(remaining.savedSessions == [first])
            _ = try await store.clear()
        } catch {
            _ = try? await store.clear()
            throw error
        }
    }
}

private func storageTestSession(_ name: String) -> UserSession {
    UserSession(handle: name, displayName: name, email: "\(name)@example.invalid", authMode: .developerPreview,
                notes: "storage test", credentials: nil, cookies: [], createdAt: Date(timeIntervalSince1970: 100))
}

private func storagePayload(_ session: UserSession) throws -> Data {
    try JSONEncoder().encode(StoredSessionsPayload(activeSessionID: session.id, sessions: [session]))
}

/// Models Security's item atomicity; failed updates leave the old bytes intact.
/// Only this injected fake is used for fault tests, never the user's Keychain.
private nonisolated final class MemorySessionKeychain: SessionKeychainAccess, @unchecked Sendable {
    private let lock = NSLock()
    private var bytes: Data?
    private var protection: String?
    private var history: [String] = []
    private var query: [String: Any]?
    private var updateKeys: Set<String> = []
    private var readFailure: OSStatus?
    private var updates: [OSStatus] = []
    private var addFailure: OSStatus?
    private var deleteFailure: OSStatus?
    init(data: Data? = nil, accessibility: String? = nil) { bytes = data; protection = accessibility }
    var data: Data? { lock.withLock { bytes } }
    var calls: [String] { lock.withLock { history } }
    var accessibility: String? { lock.withLock { protection } }
    var lastQuery: [String: Any]? { lock.withLock { query } }
    var lastUpdateKeys: Set<String> { lock.withLock { updateKeys } }
    func faults(read: OSStatus? = nil, updates: [OSStatus] = [], add: OSStatus? = nil, delete: OSStatus? = nil) {
        lock.withLock { readFailure = read; self.updates = updates; addFailure = add; deleteFailure = delete }
    }
    func read(_ query: [String: Any]) -> (OSStatus, Data?) {
        lock.withLock {
            history.append("read"); self.query = query
            return (readFailure ?? (bytes == nil ? errSecItemNotFound : errSecSuccess), bytes)
        }
    }
    func update(_ query: [String: Any], attributes: [String: Any]) -> OSStatus {
        lock.withLock {
            history.append("update"); self.query = query; updateKeys = Set(attributes.keys)
            let status = updates.isEmpty ? (bytes == nil ? errSecItemNotFound : errSecSuccess) : updates.removeFirst()
            if status == errSecSuccess { bytes = attributes[kSecValueData as String] as? Data }
            return status
        }
    }
    func add(_ attributes: [String: Any]) -> OSStatus {
        lock.withLock {
            history.append("add"); query = attributes
            let status = addFailure ?? (bytes == nil ? errSecSuccess : errSecDuplicateItem)
            if status == errSecSuccess {
                bytes = attributes[kSecValueData as String] as? Data
                protection = attributes[kSecAttrAccessible as String] as? String
            }
            return status
        }
    }
    func delete(_ query: [String: Any]) -> OSStatus {
        lock.withLock {
            history.append("delete"); self.query = query
            let status = deleteFailure ?? (bytes == nil ? errSecItemNotFound : errSecSuccess)
            if status == errSecSuccess { bytes = nil }
            return status
        }
    }
}

extension Hanger_ExpressTests {
    @Test func cookieStorageFailureDoesNotTurnCompletedMeltIntoAnActionFailure() async throws {
        let cookie = try #require(HTTPCookie(properties: [
            .name: "test-cookie", .value: "fixture", .domain: "example.invalid", .path: "/"
        ]))
        let active = UserSession(handle: "action", displayName: "action", email: "action@example.invalid",
                                 authMode: .rsiNativeLogin, notes: "test", credentials: .init(loginIdentifier: "fixture", password: "fixture"),
                                 cookies: [SessionCookie(cookie)], createdAt: Date(timeIntervalSince1970: 100))
        let bytes = try storagePayload(active)
        let api = MemorySessionKeychain(data: bytes)
        api.faults(updates: [errSecNotAvailable])
        let (model, _, repository) = storageFailureModel(api: api, active: active)
        let group = try #require(model.snapshot?.packages.groupedForInventoryDisplay.first)
        let removedID = try #require(group.packages.first?.id)
        // Only the injected repository is called; no live RSI action is sent.
        try await model.melt(packageGroup: group, quantity: 1)
        #expect(repository.meltRequests() == [[removedID]])
        #expect(model.snapshot?.packages.contains(where: { $0.id == removedID }) == false)
        #expect(model.sessionStorageErrorMessage != nil)
        #expect(api.data == bytes)
        #expect(api.calls.prefix(2) == ["read", "update"])
        await model.refresh(scope: .hangar)
    }

    @Test func secureStorageBootstrapFailureIsVisibleAndCanBeRetried() async throws {
        let old = storageTestSession("existing")
        let api = MemorySessionKeychain(data: try storagePayload(old))
        api.faults(read: errSecInteractionNotAllowed)
        let (model, _, _) = storageFailureModel(api: api, active: old)
        await model.bootstrap()
        #expect(model.session == old)
        #expect(model.snapshot == PreviewHangarRepository.sampleSnapshot)
        #expect(model.sessionStorageErrorMessage != nil)
        await model.bootstrap()
        #expect(api.calls == ["read", "read"])
    }

    @Test func failedAuthenticationSaveKeepsPriorAccountAndContent() async throws {
        let old = storageTestSession("existing")
        let bytes = try storagePayload(old)
        let api = MemorySessionKeychain(data: bytes)
        api.faults(updates: [errSecNotAvailable])
        let (model, _, _) = storageFailureModel(api: api, active: old)
        await model.completeAuthentication(storageTestSession("new"))
        #expect(model.session == old)
        #expect(model.savedSessions == [old])
        #expect(model.snapshot == PreviewHangarRepository.sampleSnapshot)
        #expect(model.sessionStorageErrorMessage != nil)
        #expect(api.data == bytes)
    }

    @Test func failedKeychainClearDoesNotSignOutOrDeleteCachedContent() async throws {
        let old = storageTestSession("existing")
        let api = MemorySessionKeychain(data: try storagePayload(old))
        api.faults(delete: errSecInteractionNotAllowed)
        let (model, snapshots, _) = storageFailureModel(api: api, active: old)
        await model.clearSession()
        #expect(model.session == old)
        #expect(model.savedSessions == [old])
        #expect(model.snapshot == PreviewHangarRepository.sampleSnapshot)
        #expect(await snapshots.load(for: old) == PreviewHangarRepository.sampleSnapshot)
        #expect(model.sessionStorageErrorMessage != nil)
        await model.clearSavedKeychainContent()
        #expect(model.session == old)
    }

    @Test func failedSavedAccountRemovalDoesNotDeleteItsCachedSnapshot() async throws {
        let old = storageTestSession("existing")
        let api = MemorySessionKeychain(data: try storagePayload(old))
        api.faults(delete: errSecAuthFailed)
        let (model, snapshots, _) = storageFailureModel(api: api, active: old)
        await model.removeSavedAccount(id: old.id)
        #expect(model.session == old)
        #expect(model.savedSessions == [old])
        #expect(await snapshots.load(for: old) == PreviewHangarRepository.sampleSnapshot)
        #expect(model.sessionStorageErrorMessage != nil)
    }

    @Test func failedAccountSelectionKeepsThePreviousActiveAccount() async throws {
        let old = storageTestSession("existing")
        let other = storageTestSession("other")
        let bytes = try JSONEncoder().encode(StoredSessionsPayload(activeSessionID: old.id, sessions: [old, other]))
        let api = MemorySessionKeychain(data: bytes)
        api.faults(updates: [errSecInteractionNotAllowed])
        let (model, _, _) = storageFailureModel(api: api, active: old)
        // Non-Pro switching permits the first saved account. Keep it first so
        // this exercises persistence failure rather than the subscription gate.
        model.savedSessions = [other, old]
        await model.switchAccount(to: other.id)
        #expect(model.session == old)
        #expect(model.savedSessions == [other, old])
        #expect(model.snapshot == PreviewHangarRepository.sampleSnapshot)
        #expect(model.sessionStorageErrorMessage != nil)
        #expect(api.data == bytes)
    }

    private func storageFailureModel(api: MemorySessionKeychain, active: UserSession) -> (AppModel, FakeSnapshotStore, FakeHangarRepository) {
        let snapshots = FakeSnapshotStore(snapshot: PreviewHangarRepository.sampleSnapshot)
        let repository = FakeHangarRepository(snapshot: PreviewHangarRepository.sampleSnapshot)
        let model = AppModel(environment: makeTestAppEnvironment(
            sessionStore: KeychainSessionStore(keychain: api), snapshotStore: snapshots,
            hangarRepository: repository
        ))
        model.session = active
        model.savedSessions = [active]
        model.loadState = .loaded(PreviewHangarRepository.sampleSnapshot)
        return (model, snapshots, repository)
    }
}
