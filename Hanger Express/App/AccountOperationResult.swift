import Foundation

/// Allows a cancelled caller to stop waiting even when a dependency ignores
/// cancellation. The abandoned job remains fenced by its invalid operation ID.
nonisolated final class AccountOperationResult<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?
    private var result: Result<Value, Error>?
    func install(_ continuation: CheckedContinuation<Value, Error>) {
        let existing: Result<Value, Error>? = lock.withLock {
            if let result { return result }
            self.continuation = continuation
            return nil
        }
        if let existing { continuation.resume(with: existing) }
    }
    func resolve(_ result: Result<Value, Error>) {
        let pending = lock.withLock {
            guard self.result == nil else { return nil as CheckedContinuation<Value, Error>? }
            self.result = result
            let pending = continuation
            continuation = nil
            return pending
        }
        pending?.resume(with: result)
    }
}
