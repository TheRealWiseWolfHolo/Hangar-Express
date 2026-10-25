import CryptoKit
import Foundation
import Observation

nonisolated struct AccountOperationOwner: Equatable, Sendable {
    let coordinatorID: UUID
    let generation: UInt64
    let accountID: UUID
    let id: UUID
    let mutation: Bool
}

nonisolated enum AccountOperationContext {
    @TaskLocal static var owner: AccountOperationOwner?
}

nonisolated enum AccountOperationError: Error, LocalizedError {
    case busy
    case reviewRequired
    case obsolete
    var errorDescription: String? {
        switch self {
        case .busy: AppLocalizer.string("Another account action is still running. Wait for it to finish.")
        case .reviewRequired: AppLocalizer.string("The previous action may have reached RSI. Open Account to refresh and review it before allowing another action.")
        case .obsolete: AppLocalizer.string("This operation was cancelled because the account changed.")
        }
    }
}

/// Main-actor ownership is checked independently of cooperative cancellation.
/// A durable, hashed account marker fences retries after uncertain submissions.
@MainActor @Observable
final class AccountOperationCoordinator {
    private let id = UUID()
    private(set) var generation: UInt64 = 0
    private var valid: Set<UUID> = []
    private struct Job { let accountID: UUID; let cancel: () -> Void }
    private var jobs: [UUID: Job] = [:]
    private var idleWaiters: [UUID: (UUID?, CheckedContinuation<Void, Never>)] = [:]
    private var mutation: AccountOperationOwner?
    private var reconciling: UUID?
    private var submitted: Set<UUID> = []
    private var acknowledged: Set<UUID> = []
    private var inFlight: [String: Set<UUID>] = [:]
    private let defaults: UserDefaults
    private let pendingKey = "operations.unconfirmedAccounts.v1"
    private var pending: Set<String>
    private var reviewedGeneration: [String: UInt64] = [:]
    private var recoveryRevision: [String: UInt64] = [:]

    init(defaults: UserDefaults) {
        self.defaults = defaults
        pending = Set(defaults.stringArray(forKey: pendingKey) ?? [])
    }
    var hasMutation: Bool { mutation != nil }
    var isReconciling: Bool { reconciling != nil }
    func requiresReview(_ session: UserSession) -> Bool { pending.contains(key(session)) }
    func canAcknowledgeReview(_ session: UserSession) -> Bool {
        requiresReview(session) && reviewedGeneration[key(session)] == generation && (inFlight[key(session)]?.isEmpty ?? true)
    }
    func recoveryReadStamp(_ session: UserSession) -> UInt64? {
        guard inFlight[key(session)]?.isEmpty ?? true else { return nil }
        return recoveryRevision[key(session), default: 0]
    }
    func recordRecoveryRead(_ session: UserSession, stamp: UInt64?) {
        guard let stamp, recoveryReadStamp(session) == stamp else { return }
        reviewedGeneration[key(session)] = generation
    }
    func acknowledgeReview(_ session: UserSession) {
        guard canAcknowledgeReview(session) else { return }
        pending.remove(key(session)); persistPending()
    }
    private func key(_ session: UserSession) -> String {
        SHA256.hash(data: Data(session.accountKey.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    private func persistPending() { defaults.set(pending.sorted(), forKey: pendingKey) }

    func begin(session: UserSession, mutation: Bool) throws -> AccountOperationOwner {
        if mutation {
            guard self.mutation == nil else { throw AccountOperationError.busy }
            guard !requiresReview(session) else { throw AccountOperationError.reviewRequired }
        }
        let owner = AccountOperationOwner(coordinatorID: id, generation: generation,
                                          accountID: session.id, id: UUID(), mutation: mutation)
        valid.insert(owner.id)
        if mutation { self.mutation = owner }
        return owner
    }
    func isCurrent(_ owner: AccountOperationOwner, session: UserSession?) -> Bool {
        owner.coordinatorID == id && owner.generation == generation && owner.accountID == session?.id && valid.contains(owner.id)
    }
    func track(_ owner: AccountOperationOwner, id: UUID, cancel: @escaping () -> Void) {
        guard valid.contains(owner.id) else { cancel(); return }
        jobs[id] = Job(accountID: owner.accountID, cancel: cancel)
    }
    func finishedJob(_ id: UUID) {
        jobs.removeValue(forKey: id)
        let ready = idleWaiters.filter { _, waiter in
            !jobs.values.contains { waiter.0 == nil || $0.accountID == waiter.0 }
        }
        for (id, waiter) in ready { idleWaiters.removeValue(forKey: id); waiter.1.resume() }
    }
    /// Joins actual worker completion, not merely a cancelled caller's reply.
    /// Never used to delay account switching or sign-out.
    func waitForJobs(accountID: UUID? = nil) async {
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled || !jobs.values.contains(where: { accountID == nil || $0.accountID == accountID }) {
                    continuation.resume()
                } else { idleWaiters[id] = (accountID, continuation) }
            }
        } onCancel: {
            Task { @MainActor in self.idleWaiters.removeValue(forKey: id)?.1.resume() }
        }
    }
    func willSubmit(_ owner: AccountOperationOwner, session: UserSession) {
        guard owner.mutation, isCurrent(owner, session: session) else { return }
        recoveryRevision[key(session), default: 0] &+= 1
        submitted.insert(owner.id)
        acknowledged.remove(owner.id)
        inFlight[key(session), default: []].insert(owner.id)
        pending.insert(key(session)); reviewedGeneration.removeValue(forKey: key(session)); persistPending()
    }
    func receivedResponse(_ owner: AccountOperationOwner, session: UserSession) {
        guard isCurrent(owner, session: session) else { return }
        acknowledged.insert(owner.id)
    }
    func finishedSubmission(_ owner: AccountOperationOwner, session: UserSession) {
        if inFlight[key(session)]?.remove(owner.id) != nil {
            recoveryRevision[key(session), default: 0] &+= 1
        }
    }
    func handOffReconciliation(_ owner: AccountOperationOwner) {
        guard valid.contains(owner.id), mutation == owner else { return }
        reconciling = owner.id
    }
    func finish(_ owner: AccountOperationOwner, session: UserSession, succeeded: Bool, responseIsUsable: Bool = false) {
        guard reconciling != owner.id else { return }
        if (succeeded || (responseIsUsable && acknowledged.contains(owner.id))) && submitted.contains(owner.id) {
            pending.remove(key(session)); persistPending()
        }
        valid.remove(owner.id); submitted.remove(owner.id); acknowledged.remove(owner.id)
        if mutation == owner { mutation = nil }
    }
    func completeReconciliation(_ owner: AccountOperationOwner, session: UserSession) {
        guard reconciling == owner.id, isCurrent(owner, session: session) else { return }
        pending.remove(key(session)); persistPending()
    }
    func finishReconciliation(_ owner: AccountOperationOwner) {
        guard reconciling == owner.id else { return }
        reconciling = nil; valid.remove(owner.id); submitted.remove(owner.id); acknowledged.remove(owner.id)
        if mutation == owner { mutation = nil }
    }
    func invalidate() {
        generation &+= 1
        let callbacks = jobs.values.map(\.cancel)
        valid.removeAll(); mutation = nil
        reconciling = nil; submitted.removeAll(); acknowledged.removeAll(); reviewedGeneration.removeAll()
        callbacks.forEach { $0() }
        // Submitted markers survive cancellation, account switches and relaunch.
    }
}
