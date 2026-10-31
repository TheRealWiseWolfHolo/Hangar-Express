import Foundation
import Testing
import WebKit
@testable import Hanger_Express

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct DiagnosticPrivacyTests {
    @Test func credentialsURLsAndAccountContextAreRedactedBeforeRetention() throws {
        let auth = AuthenticationDiagnosticsStore()
        let refresh = RefreshDiagnosticsStore()
        let secret = "opaque+session/value"
        auth.protect(values: [secret]); refresh.protect(values: [secret])
        let detail = """
        Cookie: Rsi-Token=header-secret
        Authorization: Bearer bearer-secret
        {"password":"json-secret","email":"pilot@example.invalid","code":"code-secret"}
        https://pilot:url-secret@robertsspaceindustries.com/en/account/pledges?page=1&pagesize=50&token=query-secret#fragment-secret
        https://private-service.invalid/config?key=endpoint-secret
        https%3A%2F%2Fencoded-endpoint.invalid%2Fpath%3Ftoken%3Dencoded-secret
        account=private-name, handle=private-handle, opaque \(secret)
        """
        auth.record(stage: "auth.fixture", summary: "Fixture", detail: detail)
        refresh.record(stage: "refresh.fixture", summary: "Fixture", detail: detail)
        let authText = try #require(auth.entries.first?.detail)
        let refreshText = try #require(refresh.entries.first?.detail)
        for text in [authText, refreshText] {
            for value in ["header-secret", "bearer-secret", "json-secret", "code-secret", "encoded-endpoint.invalid", "encoded-secret", "pilot@example.invalid", "url-secret",
                          "query-secret", "fragment-secret", "private-service.invalid", "endpoint-secret", "private-name", "private-handle", secret] {
                #expect(!text.contains(value))
            }
            #expect(text.contains("page=1&pagesize=50"))
        }
        let report = RefreshDebugReportBuilder.build(entries: refresh.entries, scope: .account, errorMessage: "password=visible-secret")
        #expect(!report.contains("visible-secret"))
        #expect(!report.contains("private-name"))
    }

    @Test func exportedErrorsKeepCodesButOmitUnknownPayloadsAndRawBodies() {
        let nested = NSError(domain: NSOSStatusErrorDomain, code: -9824)
        let error = NSError(domain: WKErrorDomain, code: 4, userInfo: [
            NSLocalizedDescriptionKey: "TLS failed: password=private-password",
            "WKJavaScriptExceptionMessage": "Failure token=private-js-token",
            "WKJavaScriptExceptionLineNumber": 17,
            "RSIResponseBody": "private-account-html",
            "UnrecognizedField": ["secret": "unknown-private"], NSUnderlyingErrorKey: nested
        ])
        let result = AuthenticationDebugFormatter.present(error)
        let all = result.message + (result.debugDetails ?? "")
        #expect(all.contains("-9824"))
        #expect(all.contains("17"))
        for secret in ["private-password", "private-js-token", "private-account-html", "unknown-private"] {
            #expect(!all.contains(secret))
        }
    }

    @Test func cyclicErrorsAndVeryLargeUnicodeMessagesAreBounded() {
        let cycle = CyclicDiagnosticError(domain: "fixture-cycle", code: -1200)
        let output = AuthenticationDebugFormatter.debugDescription(for: cycle)
        #expect(output.utf8.count < 4_000)
        #expect(output.contains("-1200"))
        #expect(!output.contains("private-cycle-body"))
        let huge = String(repeating: "🛡️", count: 200_000) + "password=trailing-secret"
        let bounded = DiagnosticPrivacy.text(huge)
        #expect(bounded.utf8.count < 200)
        #expect(!bounded.contains("trailing-secret"))
        let fields = (0..<300).map { _ in String(repeating: "🛡️", count: 1_000) }
        let report = DiagnosticPrivacy.report(fields)
        #expect(report.utf8.count <= DiagnosticPrivacy.maximumReportBytes)
        #expect(report.contains("report truncated"))
    }

    @Test func diagnosticResetClearsOldFieldsAndAcceptsNewSecretContext() {
        let diagnostics = AuthenticationDiagnosticsStore()
        diagnostics.protect(values: ["first-account-secret"])
        diagnostics.record(stage: "fixture", summary: "first-account-secret")
        diagnostics.reset()
        diagnostics.protect(values: ["second-account-secret"])
        diagnostics.record(stage: "fixture", summary: "second-account-secret")
        #expect(diagnostics.entries.count == 1)
        #expect(diagnostics.entries[0].summary == "[redacted]")
    }
}

private final class CyclicDiagnosticError: NSError, @unchecked Sendable {
    override var userInfo: [String: Any] {
        [NSLocalizedDescriptionKey: "Bounded cycle fixture", NSUnderlyingErrorKey: self,
         "RSIResponseBody": "private-cycle-body"]
    }
}
