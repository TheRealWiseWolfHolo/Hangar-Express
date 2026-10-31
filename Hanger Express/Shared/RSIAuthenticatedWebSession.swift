import Foundation
import WebKit

@MainActor
enum RSIAuthenticatedWebSession {
    struct PreparedSession {
        let cookies: [HTTPCookie]
        let scriptArguments: [String: Any]
    }

    static func prepare(cookies: [SessionCookie], in webView: WKWebView) async -> PreparedSession {
        let store = webView.configuration.websiteDataStore.httpCookieStore
        let existingCookies = await allCookies(from: store)
        for cookie in existingCookies {
            guard !Task.isCancelled else { return PreparedSession(cookies: [], scriptArguments: [:]) }
            await delete(cookie, from: store)
        }

        let requestedCookies = RSISessionCookieSet.merging(
            savedCookies: cookies,
            refreshedCookies: []
        ).compactMap(\.httpCookie)
        for cookie in requestedCookies {
            guard !Task.isCancelled else { return PreparedSession(cookies: [], scriptArguments: [:]) }
            await set(cookie, in: store)
        }

        var installedCookies = await allCookies(from: store)
        let installedKeys = Set(installedCookies.map(cookieKey))
        let missingCookies = requestedCookies.filter { !installedKeys.contains(cookieKey($0)) }
        if !missingCookies.isEmpty {
            for cookie in missingCookies {
                await set(cookie, in: store)
            }
            installedCookies = await allCookies(from: store)
        }

        let installedRSICookies = installedCookies.filter(isRSICookie)
        let mergedSessionCookies = RSISessionCookieSet.merging(
            savedCookies: cookies,
            refreshedCookies: installedRSICookies.map(SessionCookie.init)
        )
        let authentication = authenticationValues(from: mergedSessionCookies)

        return PreparedSession(
            cookies: installedRSICookies,
            scriptArguments: [
                "nativeRsiToken": authentication.rsiToken,
                "nativeRsiDevice": authentication.rsiDevice,
                "nativeRsiAccountAuth": cookieValue(
                    names: ["Rsi-Account-Auth"],
                    in: mergedSessionCookies
                )
            ]
        )
    }

    static func request(url: URL, cookies: [HTTPCookie]) -> URLRequest {
        var request = URLRequest(url: url)
        let applicableCookies = cookies.filter { cookie($0, appliesTo: url) }
        for (field, value) in HTTPCookie.requestHeaderFields(with: applicableCookies) {
            request.setValue(value, forHTTPHeaderField: field)
        }
        return request
    }

    nonisolated static func authenticationValues(
        from cookies: [SessionCookie],
        now: Date = .now
    ) -> (rsiToken: String, rsiDevice: String) {
        return (
            rsiToken: RSISecurityPolicy.cookieValue(names: ["Rsi-Token"], in: cookies, now: now) ?? "",
            rsiDevice: RSISecurityPolicy.cookieValue(names: ["_rsi_device"], in: cookies, now: now) ?? ""
        )
    }

    private static func cookieValue(names: [String], in cookies: [SessionCookie], now: Date = .now) -> String {
        RSISecurityPolicy.cookieValue(names: names, in: cookies, now: now) ?? ""
    }

    static func allCookies(from store: WKHTTPCookieStore) async -> [HTTPCookie] {
        await withCheckedContinuation { continuation in
            store.getAllCookies { cookies in
                continuation.resume(returning: cookies)
            }
        }
    }

    static func cookieKey(_ cookie: HTTPCookie) -> String {
        let domain = cookie.domain
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
            .lowercased()
        let path = cookie.path.isEmpty ? "/" : cookie.path
        return "\(domain)|\(path)|\(cookie.name.lowercased())"
    }

    private static func set(_ cookie: HTTPCookie, in store: WKHTTPCookieStore) async {
        await withCheckedContinuation { continuation in
            store.setCookie(cookie) { continuation.resume() }
        }
    }

    private static func delete(_ cookie: HTTPCookie, from store: WKHTTPCookieStore) async {
        await withCheckedContinuation { continuation in
            store.delete(cookie) { continuation.resume() }
        }
    }

    private static func isRSICookie(_ cookie: HTTPCookie) -> Bool {
        RSISecurityPolicy.accepts(SessionCookie(cookie))
    }

    private static func cookie(_ cookie: HTTPCookie, appliesTo url: URL) -> Bool {
        RSISecurityPolicy.cookie(SessionCookie(cookie), appliesTo: url)
    }
}
