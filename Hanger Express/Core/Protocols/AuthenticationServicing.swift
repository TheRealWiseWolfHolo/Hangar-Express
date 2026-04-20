import Foundation
import Observation

@Observable
final class AuthenticationDiagnosticsStore {
    struct Entry: Identifiable, Equatable {
        enum Level: String {
            case info = "INFO"
            case warning = "WARN"
            case error = "ERROR"
        }

        let id = UUID()
        let timestamp: Date
        let level: Level
        let stage: String
        let summary: String
        let detail: String?

        var timestampLabel: String {
            Entry.timeFormatter.string(from: timestamp)
        }

        private static let timeFormatter: DateFormatter = {
            let formatter = DateFormatter()
            formatter.dateFormat = "HH:mm:ss"
            return formatter
        }()
    }

    private(set) var entries: [Entry] = []

    var latestEntries: [Entry] {
        Array(entries.suffix(12))
    }

    var latestSummary: String? {
        latestEntries.last?.summary
    }

    func reset(context: String? = nil) {
        entries.removeAll()

        if let context, !context.isEmpty {
            record(stage: "auth.attempt", summary: context)
        }
    }

    func record(
        stage: String,
        summary: String,
        detail: String? = nil,
        level: Entry.Level = .info
    ) {
        let trimmedSummary = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedSummary.isEmpty else {
            return
        }

        let trimmedDetail = detail?.trimmingCharacters(in: .whitespacesAndNewlines)
        entries.append(
            Entry(
                timestamp: .now,
                level: level,
                stage: stage,
                summary: trimmedSummary,
                detail: trimmedDetail?.isEmpty == false ? trimmedDetail : nil
            )
        )

        if entries.count > 40 {
            entries.removeFirst(entries.count - 40)
        }
    }
}

protocol AuthenticationServicing: Sendable {
    func signIn(
        loginIdentifier: String,
        password: String,
        rememberMe: Bool,
        forceBrowserLogin: Bool
    ) async throws -> SignInOutcome
    func submitTwoFactor(code: String, deviceName: String, trustDuration: TrustedDeviceDuration) async throws -> UserSession
    func rememberBrowserExportedCookies(_ cookies: [SessionCookie]) async
    func canCompleteBrowserAuthentication(cookies: [SessionCookie]) async -> Bool
    func completeBrowserAuthentication(cookies: [SessionCookie], trustBrowserSession: Bool) async throws -> UserSession
    func cancelPendingAuthentication() async
}

enum SignInOutcome: Sendable {
    case authenticated(UserSession)
    case requiresTwoFactor
    case requiresBrowserChallenge(String)
}

enum AuthenticationError: Error, LocalizedError, Sendable {
    case invalidInput(String)
    case signInFailed(String)
    case requiresBrowserChallenge(String)
    case pendingVerificationExpired
    case unavailable(String)

    var errorDescription: String? {
        switch self {
        case let .invalidInput(message),
             let .signInFailed(message),
             let .requiresBrowserChallenge(message),
             let .unavailable(message):
            return message
        case .pendingVerificationExpired:
            return "The pending verification step expired. Start the sign-in flow again."
        }
    }
}
