import Foundation

protocol SensitiveActionAuthorizing: Sendable {
    @MainActor
    func authorize(reason: String) async throws
}

enum SensitiveActionAuthorizationError: Error, LocalizedError, Sendable, Equatable {
    case unavailable(String)
    case cancelled
    case failed(String)

    var isCancellation: Bool {
        if case .cancelled = self {
            return true
        }

        return false
    }

    var errorDescription: String? {
        switch self {
        case let .unavailable(message), let .failed(message):
            return message
        case .cancelled:
            return "Identity verification was cancelled."
        }
    }
}

struct PreviewSensitiveActionAuthorizer: SensitiveActionAuthorizing {
    @MainActor
    func authorize(reason: String) async throws {}
}
