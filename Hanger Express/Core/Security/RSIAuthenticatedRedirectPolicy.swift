import Foundation

nonisolated enum RSIAuthenticatedRedirectPolicy {
    static func request(original: URLRequest, response: HTTPURLResponse, proposed: URLRequest,
                        cookies: [SessionCookie]) -> URLRequest? {
        guard [301, 302, 303, 307, 308].contains(response.statusCode),
              RSISecurityPolicy.sameOrigin(original.url, response.url),
              RSISecurityPolicy.sameOrigin(original.url, proposed.url), let url = proposed.url else { return nil }
        var request = proposed
        // Never inherit credential headers from Foundation's proposed request.
        for field in ["Cookie", "Authorization", "Proxy-Authorization", "x-rsi-token", "x-rsi-device", "x-rsi-account-auth"] {
            request.setValue(nil, forHTTPHeaderField: field)
        }
        let applicable = RSISecurityPolicy.applicableCookies(cookies, to: url).compactMap(\.httpCookie)
        for (field, value) in HTTPCookie.requestHeaderFields(with: applicable) { request.setValue(value, forHTTPHeaderField: field) }
        for (field, name) in [("x-rsi-token", "Rsi-Token"), ("x-rsi-device", "_rsi_device"), ("x-rsi-account-auth", "Rsi-Account-Auth")] {
            if original.value(forHTTPHeaderField: field) != nil,
               let value = RSISecurityPolicy.cookieValue(names: [name], in: cookies, for: url) {
                request.setValue(value, forHTTPHeaderField: field)
            }
        }
        if ["GET", "HEAD"].contains(request.httpMethod ?? "GET") {
            request.httpBody = nil
            request.httpBodyStream = nil
            request.setValue(nil, forHTTPHeaderField: "Content-Length")
        }
        return request
    }
}

/// Per-request, bounded redirect handling. Server trust challenges deliberately
/// retain the system's certificate validation; no custom trust acceptance exists.
nonisolated class RSIAuthenticatedRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let redirectLock = NSLock()
    private var redirectCount = 0
    private var cookies: [SessionCookie]

    init(cookies: [SessionCookie] = []) {
        self.cookies = RSISessionCookieSet.merging(savedCookies: cookies, refreshedCookies: [])
        super.init()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        let next: URLRequest? = redirectLock.withLock {
            guard redirectCount < 10, let original = task.originalRequest,
                  RSISecurityPolicy.sameOrigin(original.url, response.url),
                  RSISecurityPolicy.sameOrigin(original.url, request.url) else { return nil }
            redirectCount += 1
            if let url = response.url {
                let headers = response.allHeaderFields.reduce(into: [String: String]()) { result, field in
                    if let key = field.key as? String { result[key] = String(describing: field.value) }
                }
                let received = HTTPCookie.cookies(withResponseHeaderFields: headers, for: url).map(SessionCookie.init)
                cookies = RSISessionCookieSet.merging(savedCookies: cookies, refreshedCookies: received)
            }
            return RSIAuthenticatedRedirectPolicy.request(original: original, response: response, proposed: request, cookies: cookies)
        }
        completionHandler(next)
    }
}
