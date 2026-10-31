import Foundation
import Testing
@testable import Hanger_Express

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct SnapshotPersistenceTests {
    let resources = TestResources()
    private var session: UserSession { BenchmarkInventory.make(pledgeCount: 100).session }
    private func snapshot(_ time: Double) -> HangarSnapshot {
        let base = PreviewHangarRepository.sampleSnapshot
        return HangarSnapshot(accountHandle: base.accountHandle, lastSyncedAt: Date(timeIntervalSince1970: time),
                              storeCreditUSD: base.storeCreditUSD, packages: base.packages, fleet: base.fleet,
                              buyback: base.buyback, hangarLogs: base.hangarLogs)
    }

    @Test func delayedOlderWriteCannotFinishAfterNewerStateAndPendingSavesCoalesce() async throws {
        let backend = GatedSnapshotBackend()
        let writer = SnapshotPersistenceCoordinator(store: backend)
        let first = writer.submit(snapshot(1), for: session)
        try await backend.started.wait()
        let second = writer.submit(snapshot(2), for: session)
        let third = writer.submit(snapshot(3), for: session)
        #expect(backend.saved.isEmpty)
        await backend.release.open()
        _ = try await first.value(); _ = try await second.value(); _ = try await third.value()
        #expect(backend.saved.map(\.lastSyncedAt) == [Date(timeIntervalSince1970: 1), Date(timeIntervalSince1970: 3)])
        #expect(backend.value?.lastSyncedAt == Date(timeIntervalSince1970: 3))
        #expect(writer.committedRevisions[session.accountKey] == 3)
    }

    @Test func deletionWaitsForActiveWriteAndSupersedesQueuedOldEpoch() async throws {
        let backend = GatedSnapshotBackend()
        let writer = SnapshotPersistenceCoordinator(store: backend)
        let first = writer.submit(snapshot(1), for: session)
        try await backend.started.wait()
        let queued = writer.submit(snapshot(2), for: session)
        let deleting = Task { try await writer.delete(for: session) }
        // The superseded receipt is also the deterministic signal that delete
        // has entered the writer; no timing sleeps are needed.
        let outcome = try await queued.value()
        #expect(outcome == .superseded)
        await backend.release.open()
        _ = try await first.value(); try await deleting.value
        await writer.flush()
        #expect(backend.value == nil)
        #expect(backend.saved.count == 1)
        let next = writer.submit(snapshot(3), for: session)
        _ = try await next.value()
        #expect(backend.value?.lastSyncedAt == Date(timeIntervalSince1970: 3))
    }

    @Test func clearCannotBeUndoneByAlreadyActiveWrite() async throws {
        let backend = GatedSnapshotBackend()
        let writer = SnapshotPersistenceCoordinator(store: backend)
        let first = writer.submit(snapshot(1), for: session)
        try await backend.started.wait()
        let queued = writer.submit(snapshot(2), for: session)
        let clearing = Task { try await writer.clear() }
        let outcome = try await queued.value()
        #expect(outcome == .superseded)
        await backend.release.open()
        _ = try await first.value(); try await clearing.value
        #expect(backend.value == nil)
    }

    @Test func failureIsReportedAndDoesNotPoisonFollowingWrites() async throws {
        let backend = GatedSnapshotBackend()
        backend.fail = true
        await backend.release.open()
        let writer = SnapshotPersistenceCoordinator(store: backend)
        let failed = writer.submit(snapshot(1), for: session)
        do { _ = try await failed.value(); Issue.record("Expected a write failure") }
        catch { #expect(error is SnapshotStorageError) }
        backend.fail = false
        let next = writer.submit(snapshot(2), for: session)
        _ = try await next.value()
        await writer.flush()
        #expect(backend.value?.lastSyncedAt == Date(timeIntervalSince1970: 2))
    }

    @Test func legacySnapshotLoadsAndNextSaveUsesVersionedEnvelope() async throws {
        let directory = resources.temporaryDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = FileSnapshotStore(directoryURL: directory)
        let url = file(in: directory)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(snapshot(1)).write(to: url)
        let restored = try await store.load(for: session)
        #expect(restored == snapshot(1))
        try await store.save(snapshot(2), for: session)
        let object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        #expect(object["schemaVersion"] as? Int == 1)
        let updated = try await store.load(for: session)
        #expect(updated == snapshot(2))
    }

    @Test func missingCorruptAndFutureFilesAreDistinctAndPreserved() async throws {
        let directory = resources.temporaryDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = FileSnapshotStore(directoryURL: directory)
        let missing = try await store.load(for: session)
        #expect(missing == nil)
        let url = file(in: directory)
        for data in [Data("broken".utf8), Data("{\"schemaVersion\":999}".utf8)] {
            try data.write(to: url)
            do { _ = try await store.load(for: session); Issue.record("Invalid snapshot accepted") }
            catch { #expect(error is SnapshotStorageError) }
            #expect(try Data(contentsOf: url) == data)
        }
    }

    @Test func refreshPreservesCorruptOriginalAndRefusesFutureVersionOverwrite() async throws {
        let directory = resources.temporaryDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = FileSnapshotStore(directoryURL: directory)
        let url = file(in: directory)
        let damaged = Data("damaged cache".utf8)
        try damaged.write(to: url)
        try await store.save(snapshot(1), for: session)
        let backups = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.contains("unreadable-") }
        #expect(backups.count == 1)
        #expect(try Data(contentsOf: #require(backups.first)) == damaged)
        let future = Data("{\"schemaVersion\":999}".utf8)
        try future.write(to: url)
        do { try await store.save(snapshot(2), for: session); Issue.record("Future schema overwritten") }
        catch { #expect(error is SnapshotStorageError) }
        #expect(try Data(contentsOf: url) == future)
        try await store.delete(for: session)
        #expect(try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).isEmpty)
    }

    @Test func unavailableDirectoryReportsSaveFailure() async throws {
        let root = resources.temporaryDirectory()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let directory = root.appendingPathComponent("file")
        try Data("not a directory".utf8).write(to: directory)
        let store = FileSnapshotStore(directoryURL: directory)
        do { try await store.save(snapshot(1), for: session); Issue.record("Expected I/O failure") }
        catch { #expect(error is SnapshotStorageError) }
        #expect(try Data(contentsOf: directory) == Data("not a directory".utf8))
    }
    private func file(in directory: URL) -> URL {
        let name = Data(session.accountKey.utf8).base64EncodedString().replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "=", with: "")
        return directory.appendingPathComponent(name + ".json")
    }
}

@MainActor private final class GatedSnapshotBackend: SnapshotStore {
    let started = TestGate(), release = TestGate()
    var saved: [HangarSnapshot] = []
    var value: HangarSnapshot?
    var fail = false
    func load(for session: UserSession) async -> HangarSnapshot? { value }
    func save(_ snapshot: HangarSnapshot, for session: UserSession) async throws {
        await started.open(); try await release.wait()
        if fail { throw SnapshotStorageError.unavailable }
        saved.append(snapshot); value = snapshot
    }
    func delete(for session: UserSession) async { value = nil }
    func clear() async { value = nil }
}
