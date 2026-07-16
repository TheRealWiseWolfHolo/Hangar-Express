import SwiftUI
import WebKit

struct AuthenticationBrowserChallengeView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var manualFinishRequestID = 0
    @State private var manualFinishMessage: String?

    let challenge: AuthenticationViewModel.BrowserChallenge
    let diagnostics: AuthenticationDiagnosticsStore
    let authService: any AuthenticationServicing
    let isFinishingAuthentication: Bool
    let onCancel: () -> Void
    let onAuthenticationAttempt: (Bool) async -> String?

    var body: some View {
        NavigationStack {
            BrowserChallengeWebView(
                loginIdentifier: challenge.loginIdentifier,
                password: challenge.password,
                diagnostics: diagnostics,
                authService: authService,
                isFinishingAuthentication: isFinishingAuthentication,
                manualFinishRequestID: manualFinishRequestID,
                onAuthenticationAttempt: onAuthenticationAttempt,
                onManualFinishResult: { message in
                    manualFinishMessage = message
                },
            )
            .navigationTitle("RSI Sign In")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                        onCancel()
                    }
                        .disabled(isFinishingAuthentication)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Finished Login") {
                        manualFinishMessage = nil
                        manualFinishRequestID += 1
                    }
                    .disabled(isFinishingAuthentication)
                }
            }
            .safeAreaInset(edge: .top) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(challenge.message)
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    if let manualFinishMessage {
                        Text(manualFinishMessage)
                            .font(.footnote)
                            .foregroundStyle(.orange)
                    }
                }
                .padding(.horizontal)
                .padding(.top, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(.systemBackground).opacity(0.96))
            }
        }
    }
}

private struct BrowserChallengeWebView: UIViewRepresentable {
    let loginIdentifier: String
    let password: String
    let diagnostics: AuthenticationDiagnosticsStore
    let authService: any AuthenticationServicing
    let isFinishingAuthentication: Bool
    let manualFinishRequestID: Int
    let onAuthenticationAttempt: (Bool) async -> String?
    let onManualFinishResult: @MainActor (String?) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            loginIdentifier: loginIdentifier,
            password: password,
            diagnostics: diagnostics,
            authService: authService,
            onAuthenticationAttempt: onAuthenticationAttempt,
            onManualFinishResult: onManualFinishResult,
        )
    }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        configuration.userContentController.addUserScript(
            WKUserScript(
                source: Self.mediaSuppressorScript,
                injectionTime: .atDocumentEnd,
                forMainFrameOnly: false
            )
        )

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true

        context.coordinator.attach(webView)
        webView.load(URLRequest(url: Coordinator.loginURL))
        return webView
    }

    private static let mediaSuppressorScript = """
    (() => {
      if (window.__hangerExpressMediaSuppressorInstalled) {
        window.__hangerExpressSuppressMedia?.();
        return;
      }

      window.__hangerExpressMediaSuppressorInstalled = true;

      const mediaSelector = [
        'video',
        'audio',
        'iframe[src*="youtube" i]',
        'iframe[src*="youtu.be" i]',
        'iframe[src*="vimeo" i]',
        'iframe[src*="twitch" i]'
      ].join(',');

      const closeSelector = [
        '[aria-label*="close" i]',
        '[title*="close" i]',
        '[class*="close" i]',
        '[id*="close" i]',
        'button'
      ].join(',');

      const loginControlSelector = [
        'input[type="password"]',
        'input[type="email"]',
        'input[name="email" i]',
        'input[name="username" i]',
        'input[autocomplete="username" i]',
        'iframe[src*="captcha" i]',
        'iframe[src*="recaptcha" i]'
      ].join(',');

      const normalize = (value) => (value ?? '').replace(/\\s+/g, ' ').trim().toLowerCase();

      const isVisible = (element) => {
        if (!element || !element.isConnected) {
          return false;
        }

        const style = window.getComputedStyle(element);
        if (style.display === 'none' || style.visibility === 'hidden' || style.opacity === '0') {
          return false;
        }

        const rect = element.getBoundingClientRect();
        return rect.width > 0 && rect.height > 0;
      };

      const containsLoginControl = (element) => Boolean(element?.querySelector?.(loginControlSelector));

      const looksLikeVideoOverlay = (element) => {
        if (!element || element === document.body || element === document.documentElement) {
          return false;
        }

        const style = window.getComputedStyle(element);
        const rect = element.getBoundingClientRect();
        const className = normalize(element.className);
        const id = normalize(element.id);
        const label = `${className} ${id} ${normalize(element.getAttribute('role'))}`;
        const isOverlayName = /(modal|overlay|lightbox|popup|dialog|video|player|fullscreen)/.test(label);
        const coversViewport = (style.position === 'fixed' || style.position === 'absolute')
          && rect.width >= window.innerWidth * 0.45
          && rect.height >= window.innerHeight * 0.25;

        return isOverlayName || coversViewport || element.getAttribute('aria-modal') === 'true';
      };

      const closestVideoOverlay = (media) => {
        let current = media?.parentElement;
        while (current && current !== document.body && current !== document.documentElement) {
          if (looksLikeVideoOverlay(current) && !containsLoginControl(current)) {
            return current;
          }

          current = current.parentElement;
        }

        return null;
      };

      const closeOverlay = (overlay) => {
        if (!overlay || !overlay.isConnected) {
          return false;
        }

        const closeButton = Array.from(overlay.querySelectorAll(closeSelector)).find((candidate) => {
          if (!isVisible(candidate)) {
            return false;
          }

          const label = normalize([
            candidate.textContent,
            candidate.getAttribute('aria-label'),
            candidate.getAttribute('title'),
            candidate.value
          ].filter(Boolean).join(' '));

          return label === 'x'
            || label === '×'
            || label.includes('close')
            || label.includes('dismiss')
            || label.includes('skip');
        });

        if (closeButton) {
          closeButton.click();
        }

        overlay.setAttribute('aria-hidden', 'true');
        overlay.style.setProperty('display', 'none', 'important');
        overlay.style.setProperty('visibility', 'hidden', 'important');
        return true;
      };

      window.__hangerExpressSuppressMedia = () => {
        let pausedMediaCount = 0;
        let closedOverlayCount = 0;
        const mediaElements = Array.from(document.querySelectorAll(mediaSelector));

        for (const media of mediaElements) {
          media.removeAttribute('autoplay');
          media.setAttribute('preload', 'none');

          if ('muted' in media) {
            media.muted = true;
          }

          if (typeof media.pause === 'function' && !media.paused) {
            try {
              media.pause();
              pausedMediaCount += 1;
            } catch {}
          }

          if (document.activeElement === media && typeof media.blur === 'function') {
            media.blur();
          }

          const overlay = closestVideoOverlay(media);
          if (overlay && closeOverlay(overlay)) {
            closedOverlayCount += 1;
          }
        }

        return { pausedMediaCount, closedOverlayCount };
      };

      document.addEventListener('play', (event) => {
        if (event.target?.matches?.('video,audio')) {
          event.target.pause();
        }
      }, true);

      const observer = new MutationObserver(() => {
        window.__hangerExpressSuppressMedia();
      });

      observer.observe(document.documentElement, {
        childList: true,
        subtree: true,
        attributes: true,
        attributeFilter: ['autoplay', 'src', 'class', 'style']
      });

      window.__hangerExpressSuppressMedia();
      window.setTimeout(window.__hangerExpressSuppressMedia, 500);
      window.setTimeout(window.__hangerExpressSuppressMedia, 1500);
      window.setTimeout(window.__hangerExpressSuppressMedia, 3500);
    })();
    """

    func updateUIView(_ uiView: WKWebView, context: Context) {
        context.coordinator.update(
            loginIdentifier: loginIdentifier,
            password: password,
            isFinishingAuthentication: isFinishingAuthentication,
            manualFinishRequestID: manualFinishRequestID
        )
    }

    static func dismantleUIView(_ uiView: WKWebView, coordinator: Coordinator) {
        coordinator.detach()
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        static let loginURL = URL(string: "https://robertsspaceindustries.com/en/")!

        private weak var webView: WKWebView?
        private var loginIdentifier: String
        private var password: String
        private let diagnostics: AuthenticationDiagnosticsStore
        private let authService: any AuthenticationServicing
        private var isFinishingAuthentication = false
        private var isAuthenticating = false
        private var lastManualFinishRequestID = 0
        private let onAuthenticationAttempt: (Bool) async -> String?
        private let onManualFinishResult: @MainActor (String?) -> Void

        init(
            loginIdentifier: String,
            password: String,
            diagnostics: AuthenticationDiagnosticsStore,
            authService: any AuthenticationServicing,
            onAuthenticationAttempt: @escaping (Bool) async -> String?,
            onManualFinishResult: @escaping @MainActor (String?) -> Void
        ) {
            self.loginIdentifier = loginIdentifier
            self.password = password
            self.diagnostics = diagnostics
            self.authService = authService
            self.onAuthenticationAttempt = onAuthenticationAttempt
            self.onManualFinishResult = onManualFinishResult
        }

        func attach(_ webView: WKWebView) {
            self.webView = webView
        }

        func detach() {
            webView = nil
        }

        func update(
            loginIdentifier: String,
            password: String,
            isFinishingAuthentication: Bool,
            manualFinishRequestID: Int
        ) {
            self.loginIdentifier = loginIdentifier
            self.password = password
            self.isFinishingAuthentication = isFinishingAuthentication

            guard manualFinishRequestID != lastManualFinishRequestID else {
                return
            }

            lastManualFinishRequestID = manualFinishRequestID
            log(
                stage: "browser.manual-finish",
                summary: "The tester tapped Finished Login in the in-app browser."
            )
            Task { @MainActor in
                await tryCompleteAuthenticationIfPossible(reportsManualResult: true)
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            log(
                stage: "browser.page-finish",
                summary: "The in-app RSI browser finished loading a page.",
                detail: webView.url?.absoluteString
            )
            Task { @MainActor in
                await autofillCredentialsIfPossible()
            }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            log(
                stage: "browser.page-fail",
                summary: "The in-app RSI browser failed after starting navigation.",
                detail: AuthenticationDebugFormatter.debugDescription(for: error),
                level: .error
            )
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            log(
                stage: "browser.page-fail",
                summary: "The in-app RSI browser failed before the page could load.",
                detail: AuthenticationDebugFormatter.debugDescription(for: error),
                level: .error
            )
        }

        func webView(
            _ webView: WKWebView,
            createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction,
            windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            let requestURL = navigationAction.request.url?.absoluteString ?? "n/a"
            let targetIsMainFrame = navigationAction.targetFrame?.isMainFrame == true

            log(
                stage: "browser.popup",
                summary: "The in-app browser intercepted a popup navigation request.",
                detail: "requestURL=\(requestURL), targetIsMainFrame=\(targetIsMainFrame)"
            )

            if navigationAction.targetFrame == nil {
                webView.load(navigationAction.request)
                log(
                    stage: "browser.popup",
                    summary: "The popup request was opened in the existing in-app browser instead of being dropped.",
                    detail: requestURL
                )
            }

            return nil
        }

        func webViewDidClose(_ webView: WKWebView) {
            log(
                stage: "browser.popup",
                summary: "The in-app browser popup window closed."
            )
        }

        @MainActor
        private func autofillCredentialsIfPossible() async {
            guard let webView else {
                return
            }

            let script = """
            (() => {
              window.__hangerExpressBrowserLoginCredentials = {
                loginIdentifier,
                password
              };

              if (window.__hangerExpressBrowserLoginHelperInstalled) {
                return { installed: true, reused: true };
              }

              window.__hangerExpressBrowserLoginHelperInstalled = true;

              const loginSelectors = [
                'input[name="email"]',
                'input[name="username"]',
                'input[type="email"]',
                'input[autocomplete="username"]',
                'input[id*="email" i]',
                'input[id*="username" i]',
                'input[placeholder*="email" i]',
                'input[placeholder*="login" i]'
              ];

              const passwordSelectors = [
                'input[type="password"]',
                'input[autocomplete="current-password"]'
              ];

              const clickableSelectors = [
                'button',
                'a',
                '[role="button"]',
                'input[type="submit"]',
                'input[type="button"]'
              ];

              const normalize = (value) => (value ?? '')
                .replace(/\\s+/g, ' ')
                .trim()
                .toLowerCase();

              const isVisible = (element) => {
                if (!element) {
                  return false;
                }

                const style = window.getComputedStyle(element);
                if (style.display === 'none' || style.visibility === 'hidden' || style.opacity === '0') {
                  return false;
                }

                const rect = element.getBoundingClientRect();
                return rect.width > 0 && rect.height > 0;
              };

              const findVisibleElement = (selectors) => {
                for (const selector of selectors) {
                  const element = document.querySelector(selector);
                  if (isVisible(element)) {
                    return element;
                  }
                }

                return null;
              };

              const setValue = (element, value) => {
                if (!element || value == null) {
                  return false;
                }

                const prototype = element.tagName === 'TEXTAREA'
                  ? HTMLTextAreaElement.prototype
                  : HTMLInputElement.prototype;
                const setter = Object.getOwnPropertyDescriptor(prototype, 'value')?.set;

                if (element.value === value) {
                  return true;
                }

                if (setter) {
                  setter.call(element, value);
                } else {
                  element.value = value;
                }

                element.dispatchEvent(new Event('input', { bubbles: true }));
                element.dispatchEvent(new Event('change', { bubbles: true }));
                return true;
              };

              const fillCredentials = () => {
                const credentials = window.__hangerExpressBrowserLoginCredentials ?? {};
                const loginInput = findVisibleElement(loginSelectors);
                const passwordInput = findVisibleElement(passwordSelectors);

                let filled = false;

                if (loginInput && credentials.loginIdentifier) {
                  filled = setValue(loginInput, credentials.loginIdentifier) || filled;
                }

                if (passwordInput && credentials.password) {
                  filled = setValue(passwordInput, credentials.password) || filled;
                }

                return {
                  foundLoginInput: Boolean(loginInput),
                  foundPasswordInput: Boolean(passwordInput),
                  filled
                };
              };

              const clickSignInEntry = () => {
                const candidates = Array.from(document.querySelectorAll(clickableSelectors.join(',')));
                const labels = ['sign in', 'signin', 'log in', 'login'];

                const match = candidates.find((candidate) => {
                  if (!isVisible(candidate)) {
                    return false;
                  }

                  const values = [
                    candidate.textContent,
                    candidate.getAttribute('aria-label'),
                    candidate.getAttribute('title'),
                    candidate.value
                  ].map(normalize);

                  return labels.some((label) => values.some((value) => value.includes(label)));
                });

                if (!match) {
                  return false;
                }

                match.click();
                return true;
              };

              const tick = () => {
                const state = fillCredentials();
                if (state.foundLoginInput || state.foundPasswordInput) {
                  return state;
                }

                clickSignInEntry();
                return fillCredentials();
              };

              let attempts = 0;
              const interval = window.setInterval(() => {
                attempts += 1;
                const state = tick();
                if ((state.foundLoginInput && state.foundPasswordInput) || attempts >= 20) {
                  window.clearInterval(interval);
                }
              }, 500);

              tick();

              return { installed: true, reused: false };
            })();
            """

            do {
                let result = try await webView.callAsyncJavaScript(
                    script,
                    arguments: [
                        "loginIdentifier": loginIdentifier,
                        "password": password
                    ],
                    in: nil,
                    contentWorld: .page
                )

                if let payload = result as? [String: Any] {
                    let foundLoginInput = (payload["foundLoginInput"] as? Bool) == true
                    let foundPasswordInput = (payload["foundPasswordInput"] as? Bool) == true
                    let filled = (payload["filled"] as? Bool) == true
                    let reused = (payload["reused"] as? Bool) == true

                    log(
                        stage: "browser.autofill",
                        summary: "The in-app browser checked whether it could prefill the RSI login form.",
                        detail: "foundLoginInput=\(foundLoginInput), foundPasswordInput=\(foundPasswordInput), filled=\(filled), reusedHelper=\(reused)"
                    )
                } else {
                    log(
                        stage: "browser.autofill",
                        summary: "The in-app browser ran the login-form autofill helper."
                    )
                }
            } catch {
                log(
                    stage: "browser.autofill",
                    summary: "The in-app browser could not inspect or prefill the RSI login form.",
                    detail: AuthenticationDebugFormatter.debugDescription(for: error),
                    level: .warning
                )
            }
        }

        @MainActor
        private func tryCompleteAuthenticationIfPossible(reportsManualResult: Bool = false) async {
            guard !isFinishingAuthentication,
                  !isAuthenticating,
                  let webView else {
                if reportsManualResult {
                    onManualFinishResult("Hangar Express could not access the browser session. Reopen the browser login and try again.")
                }
                return
            }

            let pageSnapshot = await browserPageSnapshot(from: webView)
            let cookies = await exportedRSICookies(from: webView)
            guard !cookies.isEmpty else {
                log(
                    stage: "browser.cookie-export",
                    summary: "Finished Login was tapped, but the browser did not expose any RSI cookies yet.",
                    detail: "exportedCookieCount=0, \(pageSnapshot)",
                    level: .warning
                )
                if reportsManualResult {
                    onManualFinishResult(
                        """
                        Stage: browser-cookie-export
                        Result: the in-app browser did not export any RSI cookies yet.
                        Details: exportedCookieCount=0, \(pageSnapshot)
                        Action: finish signing in in the browser, wait for the signed-in page to settle, then tap Finished Login again.
                        """
                    )
                }
                return
            }

            let authCookieNames = cookies
                .map(\.name)
                .filter { name in
                    let lowercasedName = name.lowercased()
                    return lowercasedName.contains("rsi")
                        || lowercasedName.contains("csrf")
                        || lowercasedName == "_rsi_device"
                }
                .sorted()

            if authCookieNames.isEmpty, reportsManualResult {
                log(
                    stage: "browser.cookie-export",
                    summary: "Finished Login was tapped, but the browser did not expose recognizable RSI auth cookies yet.",
                    detail: "exportedCookieCount=\(cookies.count), authCookies=none, cookieNames=\(cookieNamesList(from: cookies)), \(pageSnapshot)",
                    level: .warning
                )
                onManualFinishResult(
                    """
                    Stage: browser-cookie-export
                    Result: the in-app browser exported cookies, but none of them looked like RSI auth cookies yet.
                    Details: exportedCookieCount=\(cookies.count), authCookies=none, cookieNames=\(cookieNamesList(from: cookies)), \(pageSnapshot)
                    Action: make sure you are fully signed in in the browser, then tap Finished Login again.
                    """
                )
                return
            }

            log(
                stage: "browser.cookie-export",
                summary: "Exported RSI cookies from the in-app browser and sent them to the auth service for validation.",
                detail: "exportedCookieCount=\(cookies.count), authCookies=\(authCookieNames.joined(separator: ",")), cookieNames=\(cookieNamesList(from: cookies)), \(pageSnapshot)"
            )
            await authService.rememberBrowserExportedCookies(cookies)
            isAuthenticating = true
            let failureMessage = await onAuthenticationAttempt(true)
            if reportsManualResult {
                onManualFinishResult(failureMessage)
            }
            isAuthenticating = false
        }

        @MainActor
        private func exportedRSICookies(from webView: WKWebView) async -> [SessionCookie] {
            let maxAttempts = 5

            for attempt in 1 ... maxAttempts {
                let cookies = await allRSICookies(from: webView)
                if !cookies.isEmpty {
                    if attempt > 1 {
                        log(
                            stage: "browser.cookie-export",
                            summary: "The browser cookie store needed a short delay before RSI cookies became visible.",
                            detail: "attempt=\(attempt), exportedCookieCount=\(cookies.count)"
                        )
                    }
                    return cookies
                }

                guard attempt < maxAttempts else {
                    return cookies
                }

                try? await Task.sleep(for: .milliseconds(250))
            }

            return []
        }

        @MainActor
        private func allRSICookies(from webView: WKWebView) async -> [SessionCookie] {
            let store = webView.configuration.websiteDataStore.httpCookieStore
            let storeCookies = await withCheckedContinuation { continuation in
                store.getAllCookies { cookies in
                    continuation.resume(returning: cookies)
                }
            }

            var combined: [String: HTTPCookie] = [:]

            for cookie in storeCookies {
                let key = cookieKey(cookie)
                combined[key] = cookie
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

        @MainActor
        private func browserPageSnapshot(from webView: WKWebView) async -> String {
            do {
                let script = """
                (() => {
                  const text = document.body?.innerText ?? '';
                  const accessibleCookies = document.cookie
                    ? document.cookie.split(';').map(value => value.split('=')[0].trim()).filter(Boolean)
                    : [];
                  const signedInHints = [
                    'Welcome to your account',
                    'My Hangar',
                    'MY HANGAR',
                    'Account Dashboard',
                    'Settings',
                    'Back to Dashboard'
                  ].filter(hint => text.includes(hint));

                  return {
                    href: location.href,
                    title: document.title || '',
                    readyState: document.readyState,
                    accessibleCookies,
                    signedInHints,
                    avatarImageCount: document.querySelectorAll('img[alt*="avatar" i], img[src*="avatar"]').length,
                    accountLikePath: /\\/account|\\/pledges|\\/buy-back-pledges|\\/settings/.test(location.pathname)
                  };
                })()
                """

                let result = try await webView.callAsyncJavaScript(
                    script,
                    arguments: [:],
                    in: nil,
                    contentWorld: .page
                )

                guard let payload = result as? [String: Any] else {
                    return "pageSnapshot=unavailable"
                }

                let href = payload["href"] as? String ?? "n/a"
                let title = payload["title"] as? String ?? "n/a"
                let readyState = payload["readyState"] as? String ?? "n/a"
                let accessibleCookies = (payload["accessibleCookies"] as? [String]) ?? []
                let signedInHints = (payload["signedInHints"] as? [String]) ?? []
                let avatarImageCount = (payload["avatarImageCount"] as? NSNumber)?.intValue ?? 0
                let accountLikePath = (payload["accountLikePath"] as? Bool) == true

                return [
                    "pageURL=\(href)",
                    "pageTitle=\(title.replacingOccurrences(of: ",", with: " "))",
                    "readyState=\(readyState)",
                    "pageAccessibleCookies=\(accessibleCookies.isEmpty ? "none" : accessibleCookies.joined(separator: ","))",
                    "pageHints=\(signedInHints.isEmpty ? "none" : signedInHints.joined(separator: "|"))",
                    "avatarImageCount=\(avatarImageCount)",
                    "accountLikePath=\(accountLikePath)"
                ].joined(separator: ", ")
            } catch {
                return "pageSnapshotError=\(AuthenticationDebugFormatter.debugDescription(for: error).replacingOccurrences(of: "\n", with: " "))"
            }
        }

        private func cookieKey(_ cookie: HTTPCookie) -> String {
            "\(cookie.domain)|\(cookie.path)|\(cookie.name)"
        }

        private func cookieNamesList(from cookies: [SessionCookie]) -> String {
            let names = cookies.map(\.name).sorted()
            return names.isEmpty ? "none" : names.joined(separator: ",")
        }

        private func log(
            stage: String,
            summary: String,
            detail: String? = nil,
            level: AuthenticationDiagnosticsStore.Entry.Level = .info
        ) {
            diagnostics.record(stage: stage, summary: summary, detail: detail, level: level)
        }

    }
}
