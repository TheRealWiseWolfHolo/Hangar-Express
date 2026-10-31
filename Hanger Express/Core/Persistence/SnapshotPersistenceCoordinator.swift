import Foundation

nonisolated enum SnapshotStorageError: Error, LocalizedError {
    case unavailable, corrupted, unsupportedVersion
    var errorDescription: String? {
        switch self {
        case .unavailable: AppLocalizer.string("Local snapshot storage is unavailable. The latest changes may not be saved. Please try again.")
        case .corrupted: AppLocalizer.string("The local snapshot could not be read. The original file has been preserved.")
        case .unsupportedVersion: AppLocalizer.string("This snapshot was saved by a newer app version. The original file has been preserved.")
        }
    }
}

nonisolated enum SnapshotWriteOutcome: Sendable { case persisted, superseded }

nonisolated struct SnapshotWriteReceipt: Sendable {
    fileprivate let reply = AccountOperationResult<SnapshotWriteOutcome>()
    func value() async throws -> SnapshotWriteOutcome {
        try await withCheckedThrowingContinuation { reply.install($0) }
    }
    fileprivate func resolve(_ result: Result<SnapshotWriteOutcome, Error>) { reply.resolve(result) }
}

/// Submission occurs synchronously on the UI owner. Only one backend operation
/// runs at a time, even if that backend suspends or ignores task cancellation.
/// Pending saves for an account coalesce; their receipts acknowledge the newest
/// coalesced state. Deletion supersedes queued saves and follows any active I/O.
@MainActor
final class SnapshotPersistenceCoordinator {
    private struct Save {
        let session: UserSession
        var snapshot: HangarSnapshot
        let revision: UInt64
        let epoch: UInt64
        var receipts: [SnapshotWriteReceipt]
    }
    private enum Work {
        case save(Save), delete(UserSession, SnapshotWriteReceipt), clear(SnapshotWriteReceipt), barrier(SnapshotWriteReceipt)
    }
    private let store: any SnapshotStore
    private var queue: [Work] = []
    private var running = false
    private var epochs: [String: UInt64] = [:]
    private var revisions: [String: UInt64] = [:]
    private(set) var committedRevisions: [String: UInt64] = [:]

    init(store: any SnapshotStore) { self.store = store }

    func submit(_ snapshot: HangarSnapshot, for session: UserSession) -> SnapshotWriteReceipt {
        revisions[session.accountKey, default: 0] &+= 1
        let revision = revisions[session.accountKey, default: 0]
        let receipt = SnapshotWriteReceipt()
        let epoch = epochs[session.accountKey, default: 0]
        // Do not coalesce across a delete/clear/read barrier.
        for index in queue.indices.reversed() {
            guard case .save(let old) = queue[index] else { break }
            if old.session.accountKey == session.accountKey && old.epoch == epoch {
                queue[index] = .save(Save(session: session, snapshot: snapshot, revision: revision,
                                          epoch: epoch, receipts: old.receipts + [receipt]))
                start(); return receipt
            }
        }
        queue.append(.save(Save(session: session, snapshot: snapshot, revision: revision, epoch: epoch, receipts: [receipt])))
        start(); return receipt
    }

    func load(for session: UserSession) async throws -> HangarSnapshot? {
        await flush()
        return try await store.load(for: session)
    }
    func delete(for session: UserSession) async throws {
        epochs[session.accountKey, default: 0] &+= 1
        discardQueuedSaves(accountKey: session.accountKey)
        let receipt = SnapshotWriteReceipt()
        queue.append(.delete(session, receipt)); start()
        _ = try await receipt.value()
    }
    func clear() async throws {
        discardQueuedSaves(accountKey: nil)
        // In-flight writes complete before this clear. New submissions are
        // ordered after it, so old work cannot recreate deleted files.
        let receipt = SnapshotWriteReceipt()
        queue.append(.clear(receipt)); start()
        _ = try await receipt.value()
    }
    /// Waits for all work accepted before this barrier. Individual receipts
    /// report their own failures; a flush never cancels accepted writes.
    func flush() async {
        let receipt = SnapshotWriteReceipt()
        queue.append(.barrier(receipt)); start()
        _ = try? await receipt.value()
    }
    private func discardQueuedSaves(accountKey: String?) {
        queue.removeAll { item in
            guard case .save(let save) = item, accountKey == nil || save.session.accountKey == accountKey else { return false }
            save.receipts.forEach { $0.resolve(.success(.superseded)) }
            return true
        }
    }
    private func start() {
        guard !running else { return }
        running = true
        Task { await drain() }
    }
    private func drain() async {
        while !queue.isEmpty {
            let item = queue.removeFirst()
            var receipts: [SnapshotWriteReceipt] = []
            do {
                switch item {
                case .save(let save):
                    receipts = save.receipts
                    guard epochs[save.session.accountKey, default: 0] == save.epoch else {
                        receipts.forEach { $0.resolve(.success(.superseded)) }; continue
                    }
                    try await store.save(save.snapshot, for: save.session)
                    committedRevisions[save.session.accountKey] = save.revision
                case .delete(let session, let receipt):
                    receipts = [receipt]; try await store.delete(for: session)
                    committedRevisions.removeValue(forKey: session.accountKey)
                case .clear(let receipt):
                    receipts = [receipt]; try await store.clear()
                    committedRevisions.removeAll()
                case .barrier(let receipt): receipts = [receipt]
                }
                receipts.forEach { $0.resolve(.success(.persisted)) }
            } catch { receipts.forEach { $0.resolve(.failure(error)) } }
        }
        running = false
    }
}
