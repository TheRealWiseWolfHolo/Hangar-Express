import Foundation
import Testing
import UIKit
import WebKit
@testable import Hanger_Express

@MainActor
@Suite(.serialized, .timeLimit(.minutes(1)))
struct RSISecurityWebViewTests {
    @Test func trustedLoginFillsOnlyTheMainDocumentWithoutCredentialGlobals() async throws {
        let fixture = SecurityWebViewFixture()
        defer { fixture.close() }
        try await fixture.load(html: Self.loginHTML, baseURL: URL(string: "https://robertsspaceindustries.com/en/")!)
        let result = try await RSILoginAutofill.fill(in: fixture.webView, loginIdentifier: "fixture@example.invalid", password: "fixture-password")
        #expect(result?["filled"] as? Bool == true)
        let values = try await fixture.webView.callAsyncJavaScript("""
        return {
          login: document.querySelector('[name=email]').value,
          password: document.querySelector('[type=password]').value,
          globalType: typeof window.__hangerExpressBrowserLoginCredentials,
          framePassword: document.querySelector('iframe').contentDocument.querySelector('input').value
        };
        """, arguments: [:], in: nil, contentWorld: .page) as? [String: String]
        #expect(values?["login"] == "fixture@example.invalid")
        #expect(values?["password"] == "fixture-password")
        #expect(values?["globalType"] == "undefined")
        #expect(values?["framePassword"] == "")
    }

    @Test(arguments: ["https://robertsspaceindustries.com.attacker.invalid/",
                      "https://www.alipay.com/checkout", "https://wx.tenpay.com/checkout"])
    func foreignDocumentReceivesNoAutofillAndRejectsTheInDocumentRaceGuard(_ rawURL: String) async throws {
        let fixture = SecurityWebViewFixture()
        defer { fixture.close() }
        try await fixture.load(html: Self.loginHTML, baseURL: URL(string: rawURL)!)
        #expect(try await RSILoginAutofill.fill(in: fixture.webView, loginIdentifier: "fixture", password: "never-inject") == nil)
        do {
            _ = try await fixture.webView.callAsyncJavaScript(RSILoginAutofill.script,
                arguments: ["loginIdentifier": "fixture", "password": "never-inject"], in: nil, contentWorld: .defaultClient)
            Issue.record("The document-side guard must reject a navigation race")
        } catch { #expect((error as NSError).domain == WKErrorDomain) }
        let value = try await fixture.webView.evaluateJavaScript("document.querySelector('[type=password]').value") as? String
        #expect(value == "")
    }

    @Test func isolatedCheckoutNeverImportsSharedCookiesAndStopsExportingAfterDetach() async throws {
        let fixture = SecurityWebViewFixture()
        defer { fixture.close() }
        let url = URL(string: "https://robertsspaceindustries.com/en/store/pledge/cart")!
        try await fixture.load(html: "<p>Offline checkout fixture</p>", baseURL: url)
        let cookieFixture = SharedCookieSecurityFixture()
        let active = try await cookieFixture.seed()
        do {
            _ = await RSIAuthenticatedWebSession.prepare(cookies: [active], in: fixture.webView)
            let coordinator = RSICheckoutWebView.Coordinator(checkoutID: UUID(), initialURL: url, itemTitle: "Fixture",
                cookies: [active], automation: nil, onAutomationLog: { _ in }, onCookiesExported: { _ in },
                onCheckoutSucceeded: { _, _ in })
            coordinator.attach(fixture.webView)
            let exported = await coordinator.currentRSICookies()
            #expect(exported.contains { $0.name == active.name })
            #expect(!exported.contains { $0.value == "account-b" })
            coordinator.detach()
            #expect(await coordinator.currentRSICookies().isEmpty)
        }
        await cookieFixture.cleanup()
    }

    @Test func realCheckoutBridgeRejectsSubframesAndAcceptsOneCurrentConfirmation() async throws {
        let fixture = SecurityWebViewFixture()
        defer { fixture.close() }
        let url = URL(string: "https://robertsspaceindustries.com/en/store/pledge/cart/confirm/offline-order/hangar")!
        try await fixture.load(html: Self.loginHTML, baseURL: url)
        let checkoutID = UUID(), logReceived = TestGate(), completed = TestGate()
        var logs: [String] = [], completions = 0
        let coordinator = RSICheckoutWebView.Coordinator(checkoutID: checkoutID, initialURL: url, itemTitle: "Fixture",
            cookies: [], automation: nil, onAutomationLog: { text in
                logs.append(text)
                Task { await logReceived.open() }
            }, onCookiesExported: { _ in }, onCheckoutSucceeded: { _, receivedURL in
                #expect(receivedURL == url)
                completions += 1
                Task { await completed.open() }
            })
        let controller = fixture.webView.configuration.userContentController
        controller.add(coordinator, name: RSICheckoutWebView.Coordinator.checkoutAutomationMessageName)
        coordinator.attach(fixture.webView)
        defer {
            controller.removeScriptMessageHandler(forName: RSICheckoutWebView.Coordinator.checkoutAutomationMessageName)
            coordinator.detach()
        }
        let arguments: [String: Any] = ["checkoutID": checkoutID.uuidString, "documentID": coordinator.documentID.uuidString]
        _ = try await fixture.webView.callAsyncJavaScript("""
        const body = { kind: 'log', checkoutID, documentID, message: 'rejected-subframe' };
        document.querySelector('iframe').contentWindow.webkit.messageHandlers.checkoutAutomationLog.postMessage(body);
        window.webkit.messageHandlers.checkoutAutomationLog.postMessage({ ...body, message: 'accepted-main-frame' });
        """, arguments: arguments, in: nil, contentWorld: .page)
        try await logReceived.wait()
        #expect(logs == ["accepted-main-frame"])
        _ = try await fixture.webView.callAsyncJavaScript("""
        const body = { kind: 'confirmation', checkoutID, documentID, url: location.href };
        window.webkit.messageHandlers.checkoutAutomationLog.postMessage(body);
        window.webkit.messageHandlers.checkoutAutomationLog.postMessage(body);
        """, arguments: arguments, in: nil, contentWorld: .page)
        try await completed.wait()
        #expect(completions == 1)
    }

    private static let loginHTML = """
    <!doctype html><html><body>
    <input name="email"><input type="password">
    <iframe srcdoc="<input type='password'>"></iframe>
    </body></html>
    """
}

/// No network request: HTML is loaded with a synthetic base URL and an ephemeral
/// WebKit store. The main document and same-origin iframe still use real WebKit.
@MainActor
private final class SecurityWebViewFixture: NSObject, WKNavigationDelegate {
    let webView: WKWebView
    private var pending: CheckedContinuation<Void, Error>?
    private var timeout: Task<Void, Never>?
    private var hostWindow: UIWindow?

    override init() {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 400, height: 700), configuration: config)
        super.init()
        webView.navigationDelegate = self
    }

    func load(html: String, baseURL: URL) async throws {
        // A real view hierarchy gives WebKit normal visibility/lifecycle on cold
        // hosted simulators. The serialized suite owns and removes this subview.
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = try #require(scene.windows.first(where: { $0.isKeyWindow }) ?? scene.windows.first)
        // Add above the SwiftUI host as a sibling, never inside its managed view.
        let host = window
        hostWindow = window
        webView.frame = host.bounds
        webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        host.addSubview(webView)
        try await withCheckedThrowingContinuation { continuation in
            pending = continuation
            timeout = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(15)) } catch { return }
                self?.finish(URLError(.timedOut))
            }
            webView.loadHTMLString(html, baseURL: baseURL)
        }
    }

    func close() {
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.removeFromSuperview()
        hostWindow = nil
        finish(CancellationError())
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finish(nil) }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { finish(error) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { finish(error) }
    private func finish(_ error: Error?) {
        timeout?.cancel(); timeout = nil
        guard let pending else { return }; self.pending = nil
        if let error { pending.resume(throwing: error) } else { pending.resume() }
    }
}

/// Shared cookie storage may synchronously consult its daemon on first access.
/// Keep fixture setup/cleanup on an actor, never the interactive WebKit thread.
private actor SharedCookieSecurityFixture {
    private let ioQueue = DispatchQueue(label: "HangarSecurityTests.CookieFixture", qos: .utility)
    private var foreign: SessionCookie?

    func seed() async throws -> SessionCookie {
        let result: (SessionCookie, SessionCookie) = try await withCheckedThrowingContinuation { continuation in
            ioQueue.async {
                guard let active = HTTPCookie(properties: [.name: "active-fixture", .value: "account-a", .domain: "robertsspaceindustries.com", .path: "/"]),
                      let other = HTTPCookie(properties: [.name: "other-fixture-\(UUID().uuidString)", .value: "account-b", .domain: "robertsspaceindustries.com", .path: "/"]) else {
                    continuation.resume(throwing: URLError(.cannotParseResponse)); return
                }
                HTTPCookieStorage.shared.setCookie(other)
                continuation.resume(returning: (SessionCookie(active), SessionCookie(other)))
            }
        }
        foreign = result.1
        return result.0
    }

    func cleanup() async {
        guard let cookie = foreign else { return }
        await withCheckedContinuation { continuation in
            ioQueue.async {
                if let stored = cookie.httpCookie { HTTPCookieStorage.shared.deleteCookie(stored) }
                continuation.resume()
            }
        }
        foreign = nil
    }
}
