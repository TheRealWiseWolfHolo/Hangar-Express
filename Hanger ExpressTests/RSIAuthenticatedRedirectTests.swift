import Foundation
import Testing
@testable import Hanger_Express

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct RSIAuthenticatedRedirectTests {
    @Test(arguments: [301, 302, 303, 307, 308])
    func realTaskDelegateRejectsCrossOriginRedirectsBeforeAnyRequestCanBeSent(status: Int) throws {
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        var original = URLRequest(url: URL(string: "https://robertsspaceindustries.com/api/fixture")!)
        original.httpMethod = "POST"
        original.httpBody = Data("password=must-not-replay".utf8)
        original.setValue("native-token", forHTTPHeaderField: "x-rsi-token")
        let task = session.dataTask(with: original) // Deliberately never resumed: no DNS/network traffic.
        let delegate = RSIAuthenticatedRedirectDelegate()
        let response = try #require(HTTPURLResponse(url: original.url!, statusCode: status, httpVersion: nil, headerFields: nil))
        for raw in ["https://receiver.invalid/", "http://robertsspaceindustries.com/", "https://robertsspaceindustries.com:444/", "https://www.robertsspaceindustries.com/"] {
            var proposed = original; proposed.url = URL(string: raw)!
            var called = false
            delegate.urlSession(session, task: task, willPerformHTTPRedirection: response, newRequest: proposed) { next in
                called = true
                #expect(next == nil)
            }
            #expect(called)
        }
        task.cancel()
    }

    @Test func delegateRebuildsRotatedCookiesAndBoundsRedirectLoops() throws {
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let start = URL(string: "https://robertsspaceindustries.com/account/start")!
        var original = URLRequest(url: start)
        original.setValue("old-token", forHTTPHeaderField: "x-rsi-token")
        let task = session.dataTask(with: original)
        let cookie = SessionCookie(name: "Rsi-Token", value: "old-token", domain: "robertsspaceindustries.com", path: "/account",
            expiresAt: nil, isSecure: true, isHTTPOnly: true, version: 0)
        let delegate = RSIAuthenticatedRedirectDelegate(cookies: [cookie])
        let response = try #require(HTTPURLResponse(url: start, statusCode: 302, httpVersion: nil,
            headerFields: ["Set-Cookie": "Rsi-Token=rotated-token; Path=/account; Secure; HttpOnly"]))
        var proposed = URLRequest(url: URL(string: "https://robertsspaceindustries.com/account/end")!)
        proposed.setValue("inherited-token", forHTTPHeaderField: "x-rsi-token")
        proposed.setValue("Bearer inherited", forHTTPHeaderField: "Authorization")
        for _ in 0..<10 {
            delegate.urlSession(session, task: task, willPerformHTTPRedirection: response, newRequest: proposed) { next in
                #expect(next?.value(forHTTPHeaderField: "x-rsi-token") == "rotated-token")
                #expect(next?.value(forHTTPHeaderField: "Cookie") == "Rsi-Token=rotated-token")
                #expect(next?.value(forHTTPHeaderField: "Authorization") == nil)
            }
        }
        delegate.urlSession(session, task: task, willPerformHTTPRedirection: response, newRequest: proposed) { next in
            #expect(next == nil)
        }
        task.cancel()
    }

    @Test func sameOrigin307PreservesTheBodyBut303DoesNotReplayIt() throws {
        let start = URL(string: "https://robertsspaceindustries.com/api/start")!
        var original = URLRequest(url: start)
        original.httpMethod = "POST"; original.httpBody = Data("fixture-body".utf8)
        var proposed = original; proposed.url = URL(string: "https://robertsspaceindustries.com/api/end")!
        let temporary = try #require(HTTPURLResponse(url: start, statusCode: 307, httpVersion: nil, headerFields: nil))
        #expect(RSIAuthenticatedRedirectPolicy.request(original: original, response: temporary, proposed: proposed, cookies: [])?.httpBody == original.httpBody)
        proposed.httpMethod = "GET"
        let seeOther = try #require(HTTPURLResponse(url: start, statusCode: 303, httpVersion: nil, headerFields: nil))
        #expect(RSIAuthenticatedRedirectPolicy.request(original: original, response: seeOther, proposed: proposed, cookies: [])?.httpBody == nil)
    }
}
