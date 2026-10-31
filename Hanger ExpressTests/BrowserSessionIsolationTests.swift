import Foundation
import Testing
@testable import Hanger_Express

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct BrowserSessionIsolationTests {
    @Test func supersededBrowserCannotContaminateTheNextBrowserCookieCache() async throws {
        let service = makeService { cookies in
            #expect(cookies.map(\.value) == ["current-account"])
            return Self.account
        }
        _ = try await service.beginReadOnlySignIn()
        let oldID = try #require(await service.browserSessionIdentifier())
        await service.rememberBrowserExportedCookies([Self.cookie("old-account")], sessionIdentifier: oldID)
        await service.cancelPendingAuthentication()
        _ = try await service.beginReadOnlySignIn()
        let currentID = try #require(await service.browserSessionIdentifier())
        #expect(currentID != oldID)
        await service.rememberBrowserExportedCookies([Self.cookie("current-account")], sessionIdentifier: currentID)
        await service.rememberBrowserExportedCookies([Self.cookie("old-account")], sessionIdentifier: oldID)
        let session = try await service.completeBrowserAuthentication(cookies: [], trustBrowserSession: true)
        #expect(session.isReadOnly)
        #expect(session.cookies.map(\.value) == ["current-account"])
    }

    @Test func delayedBrowserCompletionDoesNotClearOrCompleteTheNewFlow() async throws {
        let started = TestGate(), release = TestGate()
        let service = makeService { cookies in
            if cookies.first?.value == "old-account" {
                await started.open()
                try await release.wait()
            }
            return Self.account
        }
        _ = try await service.beginReadOnlySignIn()
        let oldID = try #require(await service.browserSessionIdentifier())
        await service.rememberBrowserExportedCookies([Self.cookie("old-account")], sessionIdentifier: oldID)
        let pending = Task { try await service.completeBrowserAuthentication(cookies: [], trustBrowserSession: true) }
        try await started.wait()
        await service.cancelPendingAuthentication()
        _ = try await service.beginReadOnlySignIn()
        let currentID = try #require(await service.browserSessionIdentifier())
        await service.rememberBrowserExportedCookies([Self.cookie("current-account")], sessionIdentifier: currentID)
        await release.open()
        do { _ = try await pending.value; Issue.record("The superseded browser must not complete") }
        catch { #expect(error is CancellationError) }
        #expect(await service.browserSessionIdentifier() == currentID)
        let current = try await service.completeBrowserAuthentication(cookies: [], trustBrowserSession: true)
        #expect(current.cookies.map(\.value) == ["current-account"])
    }

    private func makeService(fetcher: @escaping @Sendable ([SessionCookie]) async throws -> AuthenticatedAccount) -> RSIAuthService {
        RSIAuthService(recaptchaBroker: FakeAuthenticationWebSession(signInResponse: .init(statusCode: 200, body: "{}")),
            diagnostics: AuthenticationDiagnosticsStore(), usesLauncherAPI: false, accountFetcher: fetcher)
    }
    nonisolated private static var account: AuthenticatedAccount {
        AuthenticatedAccount(avatar: nil, displayname: "Fixture", email: "fixture@example.invalid", username: "Fixture")
    }
    nonisolated private static func cookie(_ value: String) -> SessionCookie {
        SessionCookie(name: "Rsi-Token", value: value, domain: ".robertsspaceindustries.com", path: "/", expiresAt: nil,
            isSecure: true, isHTTPOnly: true, version: 0)
    }
}
