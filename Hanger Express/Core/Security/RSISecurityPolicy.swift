import Foundation

/// The origins that may receive native RSI credentials. Cookie domain membership
/// alone never grants an origin permission to run privileged browser helpers.
nonisolated enum RSISecurityPolicy {
    static let accountURL = URL(string: "https://robertsspaceindustries.com/")!
    static let graphQLURL = accountURL.appendingPathComponent("graphql")
    static let credentialHosts: Set<String> = ["robertsspaceindustries.com", "www.robertsspaceindustries.com"]

    static func isTrustedOrigin(_ url: URL?) -> Bool {
        guard let url, url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased(), credentialHosts.contains(host),
              url.user == nil, url.password == nil,
              url.port == nil || url.port == 443 else { return false }
        return true
    }

    static func sameOrigin(_ lhs: URL?, _ rhs: URL?) -> Bool {
        guard isTrustedOrigin(lhs), isTrustedOrigin(rhs) else { return false }
        return lhs?.host?.lowercased() == rhs?.host?.lowercased()
    }

    static func isTrustedCookieDomain(_ domain: String) -> Bool {
        let host = domain.lowercased().hasPrefix(".") ? String(domain.dropFirst()).lowercased() : domain.lowercased()
        guard !host.isEmpty, !host.hasPrefix("."), !host.contains(".."), !host.hasSuffix("."),
              host.utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 46 }) else { return false }
        return host == "robertsspaceindustries.com" || host.hasSuffix(".robertsspaceindustries.com")
    }

    static func accepts(_ cookie: SessionCookie, now: Date = .now) -> Bool {
        guard isTrustedCookieDomain(cookie.domain),
              !cookie.name.isEmpty, cookie.name.utf8.allSatisfy({
                  (33...126).contains($0) && ![34, 40, 41, 44, 47, 58, 59, 60, 61, 62, 63, 64, 91, 92, 93, 123, 125].contains($0)
              }),
              !cookie.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !cookie.value.utf8.contains(where: { $0 < 32 || $0 == 127 || $0 == 59 }),
              cookie.path.hasPrefix("/"), !cookie.path.contains("\r"), !cookie.path.contains("\n"),
              cookie.expiresAt.map({ $0 > now }) ?? true else { return false }
        return true
    }

    static func cookie(_ cookie: SessionCookie, appliesTo url: URL, now: Date = .now) -> Bool {
        guard isTrustedOrigin(url), accepts(cookie, now: now), let host = url.host?.lowercased() else { return false }
        let domain = cookie.domain.lowercased()
        // A leading dot is the persisted domain-cookie distinction. Cookies with
        // no dot remain host-only rather than silently gaining subdomain access.
        let matchesHost = domain.hasPrefix(".")
            ? (host == String(domain.dropFirst()) || host.hasSuffix(domain))
            : host == domain
        guard matchesHost, !cookie.isSecure || url.scheme?.lowercased() == "https" else { return false }
        let rawPath = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath ?? url.path
        let path = rawPath.isEmpty ? "/" : rawPath
        return path == cookie.path || (path.hasPrefix(cookie.path) &&
            (cookie.path.hasSuffix("/") || path.dropFirst(cookie.path.count).hasPrefix("/")))
    }

    static func applicableCookies(_ cookies: [SessionCookie], to url: URL, now: Date = .now) -> [SessionCookie] {
        cookies.filter { cookie($0, appliesTo: url, now: now) }.sorted {
            if $0.path.count != $1.path.count { return $0.path.count > $1.path.count }
            return $0.domain < $1.domain
        }
    }

    static func cookieValue(names: [String], in cookies: [SessionCookie], for url: URL = graphQLURL, now: Date = .now) -> String? {
        let names = Set(names.map { $0.lowercased() })
        return applicableCookies(cookies, to: url, now: now).first { names.contains($0.name.lowercased()) }?.value
    }

    static func isCheckoutURL(_ url: URL?) -> Bool {
        guard isTrustedOrigin(url), let url else { return false }
        let path = url.path
        guard !path.contains("\\"), !path.contains("//"), !path.split(separator: "/").contains("..") else { return false }
        return checkoutRoots.contains { path == $0 || path.hasPrefix($0 + "/") }
    }

    static func isCheckoutConfirmationURL(_ url: URL?) -> Bool {
        guard isCheckoutURL(url), let path = url?.path else { return false }
        return checkoutRoots.contains { root in
            guard path.hasPrefix(root + "/confirm/") else { return false }
            let pieces = path.dropFirst((root + "/confirm/").count).split(separator: "/", omittingEmptySubsequences: false)
            let normalized = pieces.last == "" ? Array(pieces.dropLast()) : pieces
            guard normalized.count == 2, normalized[1] == "hangar", (1...200).contains(normalized[0].count) else { return false }
            return normalized[0].utf8.allSatisfy { (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95 }
        }
    }

    /// Evaluated inside the destination document before any privileged work.
    /// Native checks alone are insufficient if navigation occurs while awaiting.
    static let javaScriptOriginGuard = """
    if (location.protocol !== 'https:' ||
        !['robertsspaceindustries.com', 'www.robertsspaceindustries.com'].includes(location.hostname.toLowerCase()) ||
        (location.port !== '' && location.port !== '443') || new URL(location.href).username || new URL(location.href).password) {
      throw new Error('Untrusted RSI document');
    }
    """

    static func verificationHint(in body: String) -> String {
        let value = body.prefix(8_192).lowercased()
        return ["captcha", "verification helper", "browser verification", "human verification", "manual verification", "csrf token"]
            .first { value.contains($0) } ?? ""
    }

    private static let checkoutRoots = ["/en/store/pledge/cart", "/store/pledge/cart", "/en/pledge/cart", "/pledge/cart"]
}
