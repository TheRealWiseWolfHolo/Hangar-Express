import Foundation
import Testing
@testable import Hanger_Express

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct RSINetworkDiagnosticsTests {
    let resources = TestResources()

    @Test func nestedTLSErrorsKeepUsefulCodesWithoutExportingSecrets() {
        let url = URL(string: "https://pilot:private-password@robertsspaceindustries.com/en/account/pledges?page=1&pagesize=50&token=private-query#private-fragment")!
        let ssl = NSError(domain: NSOSStatusErrorDomain, code: -9807, userInfo: ["Certificate": "private-certificate"])
        let cf = NSError(domain: "kCFErrorDomainCFNetwork", code: -1200, userInfo: [NSUnderlyingErrorKey: ssl,
            "_kCFStreamErrorDomainKey": 3, "_kCFStreamErrorCodeKey": -9824])
        let root = NSError(domain: NSURLErrorDomain, code: -1200, userInfo: [NSUnderlyingErrorKey: cf,
            NSURLErrorFailingURLErrorKey: url,
            NSLocalizedDescriptionKey: "TLS failed for \(url.absoluteString)\nCookie: Rsi-Token=private-cookie\nBearer private-bearer\npassword=private-password\npilot@example.invalid opaque-private-value",
            "UnrecognizedField": "unknown-private-value"])
        let output = RSINetworkDiagnostics.errorLines(root, secrets: ["opaque-private-value"]).joined(separator: "\n")
        #expect(output.contains("error[0].code=-1200"))
        #expect(output.contains("error[1]._kCFStreamErrorCodeKey=-9824"))
        #expect(output.contains("error[2].domain=NSOSStatusErrorDomain"))
        #expect(output.contains("page=1&pagesize=50"))
        for secret in ["private-password", "private-query", "private-fragment", "private-cookie", "private-bearer",
                       "pilot@example.invalid", "opaque-private-value", "unknown-private-value", "private-certificate"] {
            #expect(!output.contains(secret))
        }
        #expect(RSINetworkDiagnostics.category(root) == "TLS")
    }

    @Test func unknownErrorFieldsAndLongErrorChainsStayBounded() {
        var error = NSError(domain: "example", code: 1, userInfo: [:])
        for index in 0..<20 {
            error = NSError(domain: "example", code: index, userInfo: [NSUnderlyingErrorKey: error,
                NSLocalizedDescriptionKey: String(repeating: "a", count: 20_000), "PrivateData": "do-not-export"])
        }
        let lines = RSINetworkDiagnostics.errorLines(error)
        let result = lines.joined(separator: "\n")
        #expect(result.contains("errorChainTruncated=true"))
        #expect(result.count < 5_000)
        #expect(!result.contains("do-not-export"))
        #expect(!result.contains("error[6]"))
    }

    @Test func missingOrIncompleteTimingIsNotReportedAsZero() {
        let date = Date(timeIntervalSince1970: 100)
        #expect(RSINetworkDiagnostics.milliseconds(date, date.addingTimeInterval(0.125)) == "125.00")
        #expect(RSINetworkDiagnostics.milliseconds(date, nil) == "unavailable")
        #expect(RSINetworkDiagnostics.milliseconds(nil, date) == "unavailable")
        #expect(RSINetworkDiagnostics.milliseconds(date, date.addingTimeInterval(-1)) == "unavailable")
        let result = RSIRequestMetricsDelegate().lines().joined(separator: "\n")
        #expect(result.contains("metricsStatus=unavailable"))
        #expect(result.contains("transactionCount=unavailable"))
        #expect(!result.contains("tlsMs=0"))
        let unknownPath = URL(string: "https://example.invalid/reset/private-code?code=private-query")!
        #expect(!RSINetworkDiagnostics.safeURL(unknownPath).contains("private"))
    }

    @Test func directHTTPFailureExportsMetricsAndSafeUnderlyingErrorToSupportLog() async throws {
        let underlying = NSError(domain: NSOSStatusErrorDomain, code: -9824)
        let failure = NSError(domain: NSURLErrorDomain, code: -1200, userInfo: [NSUnderlyingErrorKey: underlying])
        let session = resources.session { _ in throw failure }
        let cookie = try #require(HTTPCookie(properties: [.name: "Rsi-Token", .value: "never-export-this-cookie",
                                                         .domain: "robertsspaceindustries.com", .path: "/"]))
        var recorded = ""
        let client = RSIAccountHTTPPageClient(cookies: [SessionCookie(cookie)], session: session, diagnostics: { detail, failed in
            #expect(failed); recorded = detail
        })
        do {
            _ = try await client.fetchPledgePage(page: 1, pageSize: 50)
            Issue.record("Expected the synthetic TLS error")
        } catch {
            let message = error.localizedDescription
            #expect(message.contains("failureCategory=TLS"))
            #expect(message.contains("code=-9824"))
            #expect(message.contains("elapsedMs="))
            #expect(message.contains("requestID="))
            #expect(message.contains("metricsStatus="))
            #expect(message.contains("serverTrust=systemDefault"))
            #expect(message.contains("responseBytes=unavailable"))
            #expect(!message.contains(cookie.value))
            #expect(recorded == message)
        }
    }

    @Test func unsuccessfulHTTPResponseOmitsPrivateAccountHTMLAndHeaders() async throws {
        let session = resources.session { request in
            (HTTPURLResponse(url: request.url!, statusCode: 503, httpVersion: nil,
                headerFields: ["Set-Cookie": "private-cookie", "CF-Ray": "1234567890abcdef-IAD",
                               "Date": "Tue, 27 Oct 2026 10:00:00 GMT"])!, Data("private-account-html".utf8))
        }
        var recorded = ""
        let client = RSIAccountHTTPPageClient(cookies: [], session: session, diagnostics: { detail, _ in recorded = detail })
        do { _ = try await client.fetchBuybackPage(page: 1, pageSize: 100); Issue.record("Expected HTTP 503") }
        catch {
            #expect(recorded.contains("httpStatus=503"))
            #expect(recorded.contains("cfRay=1234567890abcdef-IAD"))
            #expect(recorded.contains("serverDateUTC="))
            #expect(recorded.contains("responseBody=omitted"))
            #expect(!recorded.contains("private-account-html"))
            #expect(!recorded.contains("private-cookie"))
        }
    }

    @Test func cancellingRequestStillCancelsAndReportsItsCancellationState() async throws {
        let started = TestGate(), release = TestGate()
        defer { Task { await release.open() } }
        let session = resources.session { _ in
            await started.open(); try await release.wait()
            throw URLError(.cancelled)
        }
        var recorded = ""
        let client = RSIAccountHTTPPageClient(cookies: [], session: session, diagnostics: { detail, _ in recorded = detail })
        let request = Task { try await client.fetchPledgePage(page: 1, pageSize: 50) }
        try await started.wait()
        request.cancel()
        do { _ = try await request.value; Issue.record("Expected cancellation") }
        catch { #expect(error is CancellationError) }
        #expect(recorded.contains("taskCancelled=true"))
        #expect(recorded.contains("failureCategory=cancelled"))
    }
}
