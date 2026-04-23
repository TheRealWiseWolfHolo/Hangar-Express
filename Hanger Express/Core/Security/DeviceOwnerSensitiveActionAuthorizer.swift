import Foundation
import LocalAuthentication

@MainActor
final class DeviceOwnerSensitiveActionAuthorizer: SensitiveActionAuthorizing {
    func authorize(reason: String) async throws {
        let context = LAContext()
        var evaluationError: NSError?

        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &evaluationError) else {
            throw mapAvailabilityError(evaluationError)
        }

        do {
            _ = try await evaluate(context: context, reason: reason)
        } catch let error as SensitiveActionAuthorizationError {
            throw error
        } catch {
            throw mapEvaluationError(error)
        }
    }

    private func evaluate(context: LAContext, reason: String) async throws -> Bool {
        try await withCheckedThrowingContinuation { continuation in
            context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { success, error in
                DispatchQueue.main.async {
                    if success {
                        continuation.resume(returning: true)
                    } else {
                        continuation.resume(throwing: self.mapEvaluationError(error))
                    }
                }
            }
        }
    }

    private func mapAvailabilityError(_ error: NSError?) -> SensitiveActionAuthorizationError {
        let fallbackMessage = "Face ID or your iPhone passcode must be enabled before Hangar Express can confirm irreversible RSI account actions."

        guard let error else {
            return .unavailable(fallbackMessage)
        }

        if let laError = error as? LAError {
            switch laError.code {
            case .biometryNotAvailable, .biometryNotEnrolled, .biometryLockout, .passcodeNotSet:
                return .unavailable(fallbackMessage)
            default:
                break
            }
        }

        let message = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        return .unavailable(message.isEmpty ? fallbackMessage : message)
    }

    private func mapEvaluationError(_ error: Error?) -> SensitiveActionAuthorizationError {
        guard let error else {
            return .cancelled
        }

        if let authorizationError = error as? SensitiveActionAuthorizationError {
            return authorizationError
        }

        if let laError = error as? LAError {
            switch laError.code {
            case .userCancel, .systemCancel, .appCancel, .notInteractive:
                return .cancelled
            case .biometryNotAvailable, .biometryNotEnrolled, .biometryLockout, .passcodeNotSet:
                return .unavailable(
                    "Face ID or your iPhone passcode must be enabled before Hangar Express can confirm irreversible RSI account actions."
                )
            default:
                let message = laError.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
                return .failed(message.isEmpty ? "Identity verification failed." : message)
            }
        }

        let nsError = error as NSError
        let message = nsError.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        return .failed(message.isEmpty ? "Identity verification failed." : message)
    }
}
