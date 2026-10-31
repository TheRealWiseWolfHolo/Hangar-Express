import Foundation
import Testing
import WebKit
@testable import Hanger_Express

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct RSISecurityPolicyTests {
    let resources = TestResources()

    @Test func credentialOriginsRejectLookalikesCredentialsSchemesAndPorts() throws {
        for raw in ["https://robertsspaceindustries.com/", "https://www.robertsspaceindustries.com:443/en/"] {
            #expect(RSISecurityPolicy.isTrustedOrigin(URL(string: raw)))
        }
        for raw in ["https://robertsspaceindustries.com.attacker.invalid/", "https://notrobertsspaceindustries.com/",
                    "https://cdn.robertsspaceindustries.com/", "http://robertsspaceindustries.com/",
                    "https://robertsspaceindustries.com:444/", "https://pilot:secret@robertsspaceindustries.com/",
                    "https://robertsspaceindustries.com./", "about:blank", "data:text/html,login", "file:///login"] {
            #expect(!RSISecurityPolicy.isTrustedOrigin(URL(string: raw)))
        }
        #expect(!RSISecurityPolicy.isTrustedOrigin(nil))
    }

    @Test func cookieDomainExpiryPathAndHostOnlyBoundariesAreEnforced() {
        let now = Date(timeIntervalSince1970: 1_000)
        let hostOnly = cookie(domain: "robertsspaceindustries.com", path: "/account")
        let domainCookie = cookie(domain: ".robertsspaceindustries.com", path: "/account")
        #expect(RSISecurityPolicy.cookie(hostOnly, appliesTo: url("/account"), now: now))
        #expect(RSISecurityPolicy.cookie(hostOnly, appliesTo: url("/account/pledges"), now: now))
        #expect(!RSISecurityPolicy.cookie(hostOnly, appliesTo: url("/accounting"), now: now))
        #expect(!RSISecurityPolicy.cookie(hostOnly, appliesTo: URL(string: "https://www.robertsspaceindustries.com/account")!, now: now))
        #expect(RSISecurityPolicy.cookie(domainCookie, appliesTo: URL(string: "https://www.robertsspaceindustries.com/account")!, now: now))
        #expect(!RSISecurityPolicy.cookie(domainCookie, appliesTo: URL(string: "http://robertsspaceindustries.com/account")!, now: now))
        #expect(!RSISecurityPolicy.cookie(cookie(expiresAt: now), appliesTo: url("/"), now: now))
        #expect(RSISecurityPolicy.cookie(cookie(), appliesTo: url("/"), now: now))
        #expect(!RSISecurityPolicy.cookie(hostOnly, appliesTo: url("/account%2Fpledges"), now: now))
        for domain in ["robertsspaceindustries.com.attacker.invalid", "notrobertsspaceindustries.com", "..robertsspaceindustries.com", "robertsspaceindustries.com."] {
            #expect(!RSISecurityPolicy.accepts(cookie(domain: domain), now: now))
        }
        #expect(!RSISecurityPolicy.accepts(cookie(value: "unsafe\r\nCookie: injected"), now: now))
    }

    @Test func importedCookiesAndAuthenticationValuesIgnoreForeignOrInapplicableValues() {
        let legitimate = cookie(value: "legitimate")
        let foreign = cookie(value: "foreign", domain: "robertsspaceindustries.com.attacker.invalid")
        let unrelatedPath = cookie(value: "wrong-path", path: "/unrelated")
        let expired = cookie(value: "expired", expiresAt: .distantPast)
        let merged = RSISessionCookieSet.merging(savedCookies: [legitimate], refreshedCookies: [foreign])
        #expect(merged == [legitimate])
        #expect(RSISessionCookieSet.merging(savedCookies: [legitimate], refreshedCookies: [expired]).isEmpty)
        #expect(RSISecurityPolicy.cookieValue(names: ["Rsi-Token"], in: [foreign, unrelatedPath, legitimate]) == "legitimate")
        let request = RSIAuthenticatedWebSession.request(url: url("/graphql"), cookies: [foreign, unrelatedPath, legitimate].compactMap(\.httpCookie))
        #expect(request.value(forHTTPHeaderField: "Cookie") == "Rsi-Token=legitimate")
        #expect(RSIAuthenticatedWebSession.authenticationValues(from: [foreign, expired]).rsiToken.isEmpty)
    }

    @Test func directHTTPHeaderConstructionUsesOnlyApplicableCookies() async throws {
        let legitimate = cookie(value: "legitimate")
        let session = resources.session { request in
            #expect(request.value(forHTTPHeaderField: "Cookie") == "Rsi-Token=legitimate")
            #expect(request.value(forHTTPHeaderField: "x-rsi-token") == "legitimate")
            return (HTTPURLResponse(url: request.url!, statusCode: 503, httpVersion: nil, headerFields: nil)!, Data())
        }
        let client = RSIAccountHTTPPageClient(cookies: [cookie(value: "foreign", domain: "attacker.invalid"),
            cookie(value: "wrong-path", path: "/private"), legitimate], session: session)
        do { _ = try await client.fetchPledgePage(page: 1, pageSize: 50); Issue.record("Expected fixture 503") }
        catch { #expect(error.localizedDescription.contains("503")) }
    }

    @Test func checkoutNavigationKeepsPaymentSupportOutsideThePrivilegedBrowser() {
        #expect(RSICheckoutNavigationPolicy.decision(for: url("/en/store/pledge/cart"), isMainFrame: true) == .inApp)
        #expect(RSICheckoutNavigationPolicy.decision(for: URL(string: "https://www.paypal.com/checkout"), isMainFrame: true) == .external)
        #expect(RSICheckoutNavigationPolicy.decision(for: URL(string: "alipays://pay"), isMainFrame: true) == .external)
        #expect(RSICheckoutNavigationPolicy.decision(for: URL(string: "https://attacker.invalid/"), isMainFrame: true) == .cancel)
        #expect(RSICheckoutNavigationPolicy.decision(for: URL(string: "https://attacker.invalid/"), isMainFrame: true, isUserLink: true) == .external)
        #expect(RSICheckoutNavigationPolicy.decision(for: URL(string: "https://www.paypal.com.attacker.invalid/"), isMainFrame: true) == .cancel)
        for raw in ["javascript:alert(1)", "data:text/html,login", "file:///login", "http://robertsspaceindustries.com/"] {
            #expect(RSICheckoutNavigationPolicy.decision(for: URL(string: raw), isMainFrame: true) == .cancel)
        }
        #expect(RSISecurityPolicy.isCheckoutURL(url("/en/store/pledge/cart")))
        #expect(!RSISecurityPolicy.isCheckoutURL(url("/en/store/pledge/cartoon")))
        #expect(!RSISecurityPolicy.isCheckoutURL(url("/en/account/pledges")))
    }

    @Test func checkoutBridgeRejectsSpoofedStaleAndOversizedMessages() {
        let current = url("/en/store/pledge/cart/confirm/order-123/hangar")
        let valid: [String: Any] = ["kind": "confirmation", "checkoutID": "checkout", "documentID": "document", "url": current.absoluteString]
        func event(_ body: Any, main: Bool = true, origin: URL? = nil, frame: URL? = nil, checkout: String = "checkout", document: String = "document") -> RSICheckoutBridgePolicy.Event? {
            RSICheckoutBridgePolicy.event(body: body, isMainFrame: main, senderOrigin: origin ?? url("/"),
                frameURL: frame ?? current, currentURL: current, checkoutID: checkout, documentID: document)
        }
        #expect(event(valid) == .confirmation(current))
        #expect(event(valid, main: false) == nil)
        #expect(event(valid, origin: URL(string: "https://attacker.invalid/")!) == nil)
        #expect(event(valid, frame: url("/en/store/pledge/cart")) == nil)
        #expect(event(valid, checkout: "obsolete") == nil)
        #expect(event(valid, document: "old-document") == nil)
        #expect(event("Checkout confirmation URL reached: \(current.absoluteString)") == nil)
        var forged = valid; forged["url"] = "https://attacker.invalid/order"
        #expect(event(forged) == nil)
        var log: [String: Any] = ["kind": "log", "checkoutID": "checkout", "documentID": "document", "message": "Checkout confirmation URL reached: \(current.absoluteString)"]
        #expect(event(log) == .log(log["message"] as! String))
        log["message"] = String(repeating: "x", count: 2_049)
        #expect(event(log) == nil)
    }

    @Test func redirectPolicyRejectsForeignOriginsAndRebuildsScopedCredentials() {
        var original = URLRequest(url: url("/account/start"))
        original.httpMethod = "POST"
        original.httpBody = Data("password=fixture".utf8)
        original.setValue("original", forHTTPHeaderField: "x-rsi-token")
        for status in [301, 302, 303, 307, 308] {
            let response = HTTPURLResponse(url: original.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            for target in ["https://attacker.invalid/", "http://robertsspaceindustries.com/", "https://www.robertsspaceindustries.com/", "https://robertsspaceindustries.com:444/"] {
                #expect(RSIAuthenticatedRedirectPolicy.request(original: original, response: response, proposed: URLRequest(url: URL(string: target)!), cookies: [cookie()]) == nil)
            }
            var proposed = URLRequest(url: url("/account/end"))
            proposed.httpMethod = status == 307 || status == 308 ? "POST" : "GET"
            proposed.setValue("inherited-credential", forHTTPHeaderField: "Authorization")
            proposed.setValue("inherited-cookie", forHTTPHeaderField: "Cookie")
            proposed.setValue("inherited-token", forHTTPHeaderField: "x-rsi-token")
            let result = RSIAuthenticatedRedirectPolicy.request(original: original, response: response, proposed: proposed,
                cookies: [cookie(value: "scoped", path: "/account"), cookie(value: "wrong-path", path: "/unrelated")])
            #expect(result?.value(forHTTPHeaderField: "x-rsi-token") == "scoped")
            #expect(result?.value(forHTTPHeaderField: "Cookie") == "Rsi-Token=scoped")
            #expect(result?.value(forHTTPHeaderField: "Authorization") == nil)
        }
    }

    private func url(_ path: String) -> URL { URL(string: "https://robertsspaceindustries.com" + path)! }
    private func cookie(value: String = "fixture", domain: String = ".robertsspaceindustries.com", path: String = "/", expiresAt: Date? = nil) -> SessionCookie {
        SessionCookie(name: "Rsi-Token", value: value, domain: domain, path: path, expiresAt: expiresAt, isSecure: true, isHTTPOnly: true, version: 0)
    }
}
