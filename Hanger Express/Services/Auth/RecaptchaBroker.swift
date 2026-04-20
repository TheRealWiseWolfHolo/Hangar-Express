import Foundation
import Observation
import SwiftUI
import WebKit

enum RecaptchaAction: String, Sendable {
    case login = "Login"
}

struct BrowserGraphQLResponse: Sendable {
    let statusCode: Int
    let body: String
}

protocol AuthenticationWebSessionProviding: AnyObject, Sendable {
    @MainActor func resetAuthenticationSession() async throws
    @MainActor func signIn(loginIdentifier: String, password: String, rememberMe: Bool, query: String) async throws -> BrowserGraphQLResponse
    @MainActor func submitTwoFactor(code: String, deviceName: String, trustDuration: TrustedDeviceDuration, query: String) async throws -> BrowserGraphQLResponse
    @MainActor func currentRSICookies() async throws -> [SessionCookie]
}

@MainActor
@Observable
final class RecaptchaBroker: NSObject, @unchecked Sendable, AuthenticationWebSessionProviding {
    // RSI's auth flow couples reCAPTCHA, CSRF, and cookies to the same browser session,
    // so the login mutations must run inside the web view instead of a separate URLSession.
    static let helperURL = URL(string: "https://robertsspaceindustries.com/en/")!
    static let siteKey = "6LerBOgUAAAAAKPg6vsAFPTN66Woz-jBClxdQU-o"

    private let diagnostics: AuthenticationDiagnosticsStore
    private weak var webView: WKWebView?
    private var isReady = false
    private var readyError: Error?
    private var readyContinuations: [CheckedContinuation<Void, Error>] = []
    var isPreparing = true
    var statusMessage = "Preparing RSI sign-in services."

    init(diagnostics: AuthenticationDiagnosticsStore) {
        self.diagnostics = diagnostics
        super.init()
    }

    func attach(webView: WKWebView) {
        self.webView = webView
        isReady = false
        readyError = nil
        isPreparing = true
        statusMessage = "Preparing RSI sign-in services."
        diagnostics.record(
            stage: "recaptcha.attach",
            summary: "Attached the RSI verification helper web view."
        )
    }

    func detach(webView: WKWebView) {
        guard self.webView === webView else {
            return
        }

        self.webView = nil
        isPreparing = false
        diagnostics.record(
            stage: "recaptcha.detach",
            summary: "The RSI verification helper web view was released before sign-in finished.",
            level: .warning
        )
        failReadyWaiters(with: AuthenticationError.unavailable("The RSI verification helper was released before it finished loading."))
    }

    func markReady() {
        isReady = true
        readyError = nil
        isPreparing = false
        statusMessage = "RSI sign-in is ready."
        diagnostics.record(
            stage: "recaptcha.ready",
            summary: "The RSI verification helper finished loading and is ready."
        )

        let continuations = readyContinuations
        readyContinuations.removeAll()
        continuations.forEach { $0.resume() }
    }

    func markFailed(_ error: Error) {
        isPreparing = false
        statusMessage = "RSI sign-in warmup hit a problem."
        diagnostics.record(
            stage: "recaptcha.ready",
            summary: "The RSI verification helper failed during warmup.",
            detail: AuthenticationDebugFormatter.debugDescription(for: error),
            level: .error
        )
        failReadyWaiters(with: error)
    }

    func resetAuthenticationSession() async throws {
        isPreparing = true
        statusMessage = "Refreshing the RSI sign-in session."
        diagnostics.record(
            stage: "recaptcha.reset",
            summary: "Resetting the RSI verification helper session and clearing RSI cookies."
        )
        try await awaitReady()
        try await clearRSICookies()
        try await reloadHelperPage()
    }

    func signIn(loginIdentifier: String, password: String, rememberMe: Bool, query: String) async throws -> BrowserGraphQLResponse {
        diagnostics.record(
            stage: "recaptcha.graphql-signin",
            summary: "Starting the GraphQL sign-in flow inside the RSI verification helper.",
            detail: "loginIdentifier=\(maskedIdentifier(loginIdentifier)), rememberMe=\(rememberMe)"
        )
        try await awaitReady()

        guard let webView else {
            diagnostics.record(
                stage: "recaptcha.graphql-signin",
                summary: "The RSI verification helper web view was unavailable during GraphQL sign-in.",
                level: .error
            )
            throw AuthenticationError.unavailable("The RSI verification helper is not ready yet.")
        }

        do {
            let script = """
            const csrfToken = document.querySelector('meta[name="csrf-token"]')?.getAttribute('content');
            if (!csrfToken) {
              throw new Error("The RSI page did not expose a CSRF token.");
            }

            const markMatch = document.documentElement.innerHTML.match(/window\\.Mark = new Turbulent\\.Mark\\(\\{ 'name' : 'Rsi-XSRF', 'token' : '([^']+)'/);
            const mark = markMatch ? markMatch[1] : null;

            const captchaToken = await new Promise((resolve, reject) => {
              if (!window.grecaptcha || !window.grecaptcha.enterprise) {
                reject(new Error("reCAPTCHA Enterprise is unavailable on the RSI page."));
                return;
              }

              window.grecaptcha.enterprise.ready(() => {
                window.grecaptcha.enterprise.execute(siteKey, { action })
                  .then(resolve)
                  .catch(error => reject(error instanceof Error ? error : new Error(String(error))));
              });
            });

            const response = await fetch('/graphql', {
              method: 'POST',
              credentials: 'include',
              headers: {
                'Content-Type': 'application/json',
                'X-CSRF-TOKEN': csrfToken,
                'Accept-Language': navigator.language || 'en-US'
              },
              body: JSON.stringify({
                operationName: 'signin',
                query,
                variables: {
                  captcha_code: null,
                  captchaToken,
                  email: loginIdentifier,
                  mark,
                  password,
                  remember: rememberMe
                }
              })
            });

            return {
              statusCode: response.status,
              body: await response.text()
            };
            """
            let result = try await webView.callAsyncJavaScript(
                script,
                arguments: [
                    "loginIdentifier": loginIdentifier,
                    "password": password,
                    "rememberMe": rememberMe,
                    "query": query,
                    "siteKey": Self.siteKey,
                    "action": RecaptchaAction.login.rawValue
                ],
                in: nil,
                contentWorld: .page
            )

            let response = try decodeBrowserResponse(result)
            diagnostics.record(
                stage: "recaptcha.graphql-signin",
                summary: "The GraphQL sign-in request finished inside the RSI verification helper.",
                detail: "httpStatus=\(response.statusCode), responseBytes=\(response.body.utf8.count)"
            )
            return response
        } catch {
            diagnostics.record(
                stage: "recaptcha.graphql-signin",
                summary: "The GraphQL sign-in request failed inside the RSI verification helper.",
                detail: AuthenticationDebugFormatter.debugDescription(for: error),
                level: .error
            )
            throw error
        }
    }

    func submitTwoFactor(code: String, deviceName: String, trustDuration: TrustedDeviceDuration, query: String) async throws -> BrowserGraphQLResponse {
        diagnostics.record(
            stage: "recaptcha.graphql-two-factor",
            summary: "Submitting the RSI verification code inside the verification helper.",
            detail: "deviceName=\(deviceName), trustDuration=\(trustDuration.rawValue)"
        )
        try await awaitReady()

        guard let webView else {
            diagnostics.record(
                stage: "recaptcha.graphql-two-factor",
                summary: "The RSI verification helper web view was unavailable during verification-code submission.",
                level: .error
            )
            throw AuthenticationError.unavailable("The RSI verification helper is not ready yet.")
        }

        do {
            let script = """
            const csrfToken = document.querySelector('meta[name="csrf-token"]')?.getAttribute('content');
            if (!csrfToken) {
              throw new Error("The RSI page did not expose a CSRF token.");
            }

            const response = await fetch('/graphql', {
              method: 'POST',
              credentials: 'include',
              headers: {
                'Content-Type': 'application/json',
                'X-CSRF-TOKEN': csrfToken,
                'Accept-Language': navigator.language || 'en-US'
              },
              body: JSON.stringify({
                operationName: 'multistep',
                query,
                variables: {
                  code,
                  deviceType: 'computer',
                  deviceName,
                  duration
                }
              })
            });

            return {
              statusCode: response.status,
              body: await response.text()
            };
            """
            let result = try await webView.callAsyncJavaScript(
                script,
                arguments: [
                    "code": code,
                    "deviceName": deviceName,
                    "duration": trustDuration.rawValue,
                    "query": query
                ],
                in: nil,
                contentWorld: .page
            )

            let response = try decodeBrowserResponse(result)
            diagnostics.record(
                stage: "recaptcha.graphql-two-factor",
                summary: "The GraphQL verification request finished inside the RSI verification helper.",
                detail: "httpStatus=\(response.statusCode), responseBytes=\(response.body.utf8.count)"
            )
            return response
        } catch {
            diagnostics.record(
                stage: "recaptcha.graphql-two-factor",
                summary: "The GraphQL verification request failed inside the RSI verification helper.",
                detail: AuthenticationDebugFormatter.debugDescription(for: error),
                level: .error
            )
            throw error
        }
    }

    func currentRSICookies() async throws -> [SessionCookie] {
        let cookies = try await currentCookies()
        return cookies.map(SessionCookie.init)
            .sorted { lhs, rhs in
                if lhs.domain == rhs.domain {
                    return lhs.name < rhs.name
                }

                return lhs.domain < rhs.domain
            }
    }

    private func awaitReady() async throws {
        if let readyError {
            throw readyError
        }

        if isReady {
            return
        }

        try await withCheckedThrowingContinuation { continuation in
            readyContinuations.append(continuation)
        }
    }

    private func currentCookies() async throws -> [HTTPCookie] {
        let cookies = try await allCookies()
        return cookies.filter(\.isRSICookie)
    }

    private func clearRSICookies() async throws {
        let store = try cookieStore()
        let cookiesToDelete = try await currentCookies()
        diagnostics.record(
            stage: "recaptcha.cookies",
            summary: "Clearing RSI cookies from the verification helper session.",
            detail: "cookieCount=\(cookiesToDelete.count)"
        )

        for cookie in cookiesToDelete {
            await withCheckedContinuation { continuation in
                store.delete(cookie) {
                    continuation.resume()
                }
            }
        }
    }

    private func reloadHelperPage() async throws {
        guard let webView else {
            diagnostics.record(
                stage: "recaptcha.reload",
                summary: "The verification helper could not reload because its web view was unavailable.",
                level: .error
            )
            throw AuthenticationError.unavailable("The RSI verification helper is not ready yet.")
        }

        isReady = false
        readyError = nil
        isPreparing = true
        statusMessage = "Preparing the RSI sign-in page."
        diagnostics.record(
            stage: "recaptcha.reload",
            summary: "Reloading the RSI sign-in helper page."
        )
        webView.load(URLRequest(url: Self.helperURL))
        try await awaitReady()
    }

    private func allCookies() async throws -> [HTTPCookie] {
        let store = try cookieStore()

        return await withCheckedContinuation { continuation in
            store.getAllCookies { cookies in
                continuation.resume(returning: cookies)
            }
        }
    }

    private func cookieStore() throws -> WKHTTPCookieStore {
        guard let webView else {
            throw AuthenticationError.unavailable("The RSI verification helper is not ready yet.")
        }

        return webView.configuration.websiteDataStore.httpCookieStore
    }

    private func decodeBrowserResponse(_ result: Any?) throws -> BrowserGraphQLResponse {
        guard let payload = result as? [String: Any],
              let statusValue = payload["statusCode"] as? NSNumber,
              let body = payload["body"] as? String else {
            diagnostics.record(
                stage: "recaptcha.decode-response",
                summary: "The RSI verification helper returned an unexpected response shape.",
                detail: String(describing: result),
                level: .error
            )
            throw AuthenticationError.unavailable("The RSI verification helper returned an unexpected response.")
        }

        return BrowserGraphQLResponse(statusCode: statusValue.intValue, body: body)
    }

    private func failReadyWaiters(with error: Error) {
        readyError = error
        isReady = false

        let continuations = readyContinuations
        readyContinuations.removeAll()
        continuations.forEach { $0.resume(throwing: error) }
    }

    private func maskedIdentifier(_ value: String) -> String {
        guard let atIndex = value.firstIndex(of: "@") else {
            let prefix = String(value.prefix(2))
            return prefix + String(repeating: "*", count: max(0, value.count - prefix.count))
        }

        let name = String(value[..<atIndex])
        let domain = String(value[atIndex...])
        let visiblePrefix = String(name.prefix(2))
        return visiblePrefix + String(repeating: "*", count: max(0, name.count - visiblePrefix.count)) + domain
    }
}

private extension HTTPCookie {
    var isRSICookie: Bool {
        domain.contains("robertsspaceindustries.com")
    }
}

struct RecaptchaBridgeView: UIViewRepresentable {
    let broker: RecaptchaBroker

    func makeCoordinator() -> Coordinator {
        Coordinator(broker: broker)
    }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.isScrollEnabled = false
        webView.navigationDelegate = context.coordinator

        Task { @MainActor in
            broker.attach(webView: webView)
        }

        webView.load(URLRequest(url: RecaptchaBroker.helperURL))
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    static func dismantleUIView(_ uiView: WKWebView, coordinator: Coordinator) {
        Task { @MainActor in
            coordinator.broker.detach(webView: uiView)
        }
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        let broker: RecaptchaBroker

        init(broker: RecaptchaBroker) {
            self.broker = broker
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            Task { @MainActor in
                broker.markReady()
            }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            Task { @MainActor in
                broker.markFailed(error)
            }
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            Task { @MainActor in
                broker.markFailed(error)
            }
        }
    }
}
