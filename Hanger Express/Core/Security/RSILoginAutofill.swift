import Foundation
import WebKit

@MainActor
enum RSILoginAutofill {
    static func fill(in webView: WKWebView, loginIdentifier: String, password: String) async throws -> [String: Any]? {
        guard !Task.isCancelled, let documentURL = webView.url, RSISecurityPolicy.isTrustedOrigin(documentURL) else { return nil }
        return try await webView.callAsyncJavaScript(
            script, arguments: ["loginIdentifier": loginIdentifier, "password": password, "expectedDocumentURL": documentURL.absoluteString],
            in: nil, contentWorld: .defaultClient
        ) as? [String: Any]
    }

    static let script = """
            return (() => {
              \(RSISecurityPolicy.javaScriptOriginGuard)
              if (location.href !== expectedDocumentURL) { throw new Error('RSI document changed'); }

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
                const credentials = { loginIdentifier, password };
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

              return tick();
            })();
            """

}
