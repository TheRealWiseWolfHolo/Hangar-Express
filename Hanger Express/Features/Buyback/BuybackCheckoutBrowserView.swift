import SwiftUI
import UIKit
import WebKit

struct BuybackCheckoutBrowserView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var cookieExportRequestID = 0

    let context: BuybackCheckoutContext
    let onCancel: ([SessionCookie]) -> Void
    let onFinished: ([SessionCookie]) -> Void

    var body: some View {
        NavigationStack {
            BuybackCheckoutWebView(
                initialURL: context.checkoutURL,
                cookies: context.cookies,
                cookieExportRequestID: cookieExportRequestID,
                onCookiesExported: { cookies in
                    dismiss()
                    onFinished(cookies)
                }
            )
            .navigationTitle("Buy-back Checkout")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                        onCancel(context.cookies)
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Finished Shopping") {
                        cookieExportRequestID += 1
                    }
                }
            }
        }
    }
}

private struct BuybackCheckoutWebView: UIViewRepresentable {
    let initialURL: URL
    let cookies: [SessionCookie]
    let cookieExportRequestID: Int
    let onCookiesExported: @MainActor @Sendable ([SessionCookie]) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            initialURL: initialURL,
            cookies: cookies,
            onCookiesExported: onCookiesExported
        )
    }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = true

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true

        context.coordinator.attach(webView)
        context.coordinator.loadInitialPage()
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.update(
            initialURL: initialURL,
            cookies: cookies,
            cookieExportRequestID: cookieExportRequestID
        )
    }

    static func dismantleUIView(_ webView: WKWebView, coordinator: Coordinator) {
        coordinator.detach()
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        private weak var webView: WKWebView?
        private var initialURL: URL
        private var cookies: [SessionCookie]
        private var lastCookieExportRequestID = 0
        private var didLoadInitialPage = false
        private let onCookiesExported: @MainActor @Sendable ([SessionCookie]) -> Void

        init(
            initialURL: URL,
            cookies: [SessionCookie],
            onCookiesExported: @escaping @MainActor @Sendable ([SessionCookie]) -> Void
        ) {
            self.initialURL = initialURL
            self.cookies = cookies
            self.onCookiesExported = onCookiesExported
        }

        func attach(_ webView: WKWebView) {
            self.webView = webView
        }

        func detach() {
            webView = nil
        }

        func loadInitialPage() {
            guard !didLoadInitialPage, let webView else {
                return
            }

            didLoadInitialPage = true
            Task { @MainActor in
                await installCookies(cookies, in: webView)
                webView.load(URLRequest(url: initialURL))
            }
        }

        func update(
            initialURL: URL,
            cookies: [SessionCookie],
            cookieExportRequestID: Int
        ) {
            self.initialURL = initialURL
            self.cookies = cookies

            guard cookieExportRequestID != lastCookieExportRequestID else {
                return
            }

            lastCookieExportRequestID = cookieExportRequestID
            Task { @MainActor in
                let exportedCookies = await currentRSICookies()
                onCookiesExported(exportedCookies.isEmpty ? cookies : exportedCookies)
            }
        }

        func webView(
            _ webView: WKWebView,
            createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction,
            windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            if let url = navigationAction.request.url, shouldOpenExternally(url) {
                openExternalURL(url)
                return nil
            }

            if navigationAction.targetFrame == nil {
                webView.load(navigationAction.request)
            }

            return nil
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            guard let url = navigationAction.request.url else {
                decisionHandler(.allow)
                return
            }

            if shouldOpenExternally(url) {
                openExternalURL(url)
                decisionHandler(.cancel)
                return
            }

            decisionHandler(.allow)
        }

        private func installCookies(_ cookies: [SessionCookie], in webView: WKWebView) async {
            let store = webView.configuration.websiteDataStore.httpCookieStore
            let existingCookies = await withCheckedContinuation { continuation in
                store.getAllCookies { cookies in
                    continuation.resume(returning: cookies)
                }
            }

            for cookie in existingCookies where cookie.domain.contains("robertsspaceindustries.com") {
                await withCheckedContinuation { continuation in
                    store.delete(cookie) {
                        continuation.resume()
                    }
                }
            }

            for cookie in cookies {
                guard let httpCookie = cookie.httpCookie else {
                    continue
                }

                await withCheckedContinuation { continuation in
                    store.setCookie(httpCookie) {
                        continuation.resume()
                    }
                }
            }
        }

        private func currentRSICookies() async -> [SessionCookie] {
            guard let webView else {
                return []
            }

            let store = webView.configuration.websiteDataStore.httpCookieStore
            let storeCookies = await withCheckedContinuation { continuation in
                store.getAllCookies { cookies in
                    continuation.resume(returning: cookies)
                }
            }

            var combined: [String: HTTPCookie] = [:]

            for cookie in storeCookies {
                combined[cookieKey(cookie)] = cookie
            }

            for cookie in HTTPCookieStorage.shared.cookies ?? [] where combined[cookieKey(cookie)] == nil {
                combined[cookieKey(cookie)] = cookie
            }

            return combined.values
                .filter { $0.domain.contains("robertsspaceindustries.com") }
                .map(SessionCookie.init)
                .sorted { lhs, rhs in
                    if lhs.domain == rhs.domain {
                        return lhs.name < rhs.name
                    }

                    return lhs.domain < rhs.domain
                }
        }

        private func cookieKey(_ cookie: HTTPCookie) -> String {
            "\(cookie.domain)|\(cookie.path)|\(cookie.name)"
        }

        private func shouldOpenExternally(_ url: URL) -> Bool {
            guard let scheme = url.scheme?.lowercased() else {
                return false
            }

            if !Self.inAppSchemes.contains(scheme) {
                return true
            }

            guard scheme == "https",
                  let host = url.host?.lowercased() else {
                return false
            }

            return Self.externalPaymentDomains.contains { domain in
                host == domain || host.hasSuffix(".\(domain)")
            }
        }

        private func openExternalURL(_ url: URL) {
            Task { @MainActor in
                UIApplication.shared.open(url, options: [:])
            }
        }

        private static let inAppSchemes: Set<String> = [
            "about",
            "blob",
            "data",
            "http",
            "https",
            "javascript"
        ]

        private static let externalPaymentDomains: Set<String> = [
            "alipay.com",
            "alipay.hk",
            "alipayobjects.com",
            "tenpay.com",
            "wechatpay.com",
            "paypal.com",
            "paypalobjects.com",
            "unionpay.com",
            "95516.com"
        ]
    }
}
