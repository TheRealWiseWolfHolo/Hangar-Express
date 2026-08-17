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
        for cookie in existingCookies where isRSICookie(cookie) {
            await delete(cookie, from: store)
        }

        let requestedCookies = RSISessionCookieSet.merging(
            savedCookies: cookies,
            refreshedCookies: []
        ).compactMap(\.httpCookie)
        for cookie in requestedCookies {
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
        let value: ([String]) -> String = { names in
            let acceptedNames = Set(names.map { $0.lowercased() })
            return cookies.reversed().first { cookie in
                acceptedNames.contains(cookie.name.lowercased()) &&
                    !cookie.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
                    (cookie.expiresAt.map { $0 > now } ?? true)
            }?.value ?? ""
        }

        return (
            rsiToken: value(["Rsi-Token", "rsi-token"]),
            rsiDevice: value(["_rsi_device"])
        )
    }

    private static func cookieValue(
        names: [String],
        in cookies: [SessionCookie],
        now: Date = .now
    ) -> String {
        let acceptedNames = Set(names.map { $0.lowercased() })
        return cookies.reversed().first { cookie in
            acceptedNames.contains(cookie.name.lowercased()) &&
                !cookie.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
                (cookie.expiresAt.map { $0 > now } ?? true)
        }?.value ?? ""
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
        cookie.domain.lowercased().contains("robertsspaceindustries.com")
    }

    private static func cookie(_ cookie: HTTPCookie, appliesTo url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }

        let cookieDomain = cookie.domain
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
            .lowercased()
        guard host == cookieDomain || host.hasSuffix(".\(cookieDomain)") else { return false }
        guard !cookie.isSecure || url.scheme?.lowercased() == "https" else { return false }
        guard cookie.expiresDate.map({ $0 > .now }) ?? true else { return false }

        let requestPath = url.path.isEmpty ? "/" : url.path
        let cookiePath = cookie.path.isEmpty ? "/" : cookie.path
        return requestPath.hasPrefix(cookiePath)
    }
}
