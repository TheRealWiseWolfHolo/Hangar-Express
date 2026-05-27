import SwiftUI
import UIKit
import WebKit

struct RSICheckoutBrowserView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var cookieExportRequestID = 0
    @State private var automationLogs: [String] = []

    let context: RSICheckoutContext
    let onCancel: ([SessionCookie]) -> Void
    let onFinished: ([SessionCookie]) -> Void
    let onSucceeded: ([SessionCookie], URL?) -> Void

    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                ZStack(alignment: .bottom) {
                    RSICheckoutWebView(
                        initialURL: context.checkoutURL,
                        itemTitle: context.itemTitle,
                        cookies: context.cookies,
                        automation: context.automation,
                        cookieExportRequestID: cookieExportRequestID,
                        onAutomationLog: { message in
                            appendAutomationLog(message)
                        },
                        onCookiesExported: { cookies in
                            dismiss()
                            onFinished(cookies)
                        },
                        onCheckoutSucceeded: { cookies, confirmationURL in
                            dismiss()
                            onSucceeded(cookies, confirmationURL)
                        }
                    )

                    if context.automation != nil, !automationLogs.isEmpty {
                        CheckoutAutomationLogPanel(
                            logs: automationLogs,
                            containerSize: geometry.size
                        )
                        .padding(.horizontal, 14)
                        .padding(.bottom, 12)
                    }
                }
            }
            .navigationTitle(context.navigationTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                        onCancel(context.cookies)
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button(context.completionButtonTitle) {
                        cookieExportRequestID += 1
                    }
                }
            }
        }
    }

    private func appendAutomationLog(_ message: String) {
        let trimmedMessage = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedMessage.isEmpty else {
            return
        }

        let timestampedMessage: String
        if trimmedMessage.hasPrefix("[") {
            timestampedMessage = trimmedMessage
        } else {
            timestampedMessage = "[\(Date().formatted(date: .omitted, time: .standard))] \(trimmedMessage)"
        }

        automationLogs.append(timestampedMessage)
        if automationLogs.count > 200 {
            automationLogs.removeFirst(automationLogs.count - 200)
        }
    }
}

private struct CheckoutAutomationLogPanel: View {
    @GestureState private var dragOffset: CGSize = .zero
    @State private var restingOffset: CGSize = .zero

    let logs: [String]
    let containerSize: CGSize

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Label("Checkout Automation", systemImage: "bolt.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.primary)

                Spacer()

                Image(systemName: "arrow.up.and.down.and.arrow.left.and.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
            .gesture(panelDragGesture)

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(logs.enumerated()), id: \.offset) { entry in
                            Text(entry.element)
                                .font(.caption2.monospaced())
                                .foregroundStyle(.primary)
                                .textSelection(.enabled)
                                .id(entry.offset)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .frame(maxHeight: 150)
                .onAppear {
                    scrollToLatestLog(using: proxy)
                }
                .onChange(of: logs) { _, _ in
                    scrollToLatestLog(using: proxy)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .shadow(color: Color.black.opacity(0.18), radius: 12, x: 0, y: 4)
        .offset(
            x: restingOffset.width + dragOffset.width,
            y: restingOffset.height + dragOffset.height
        )
        .accessibilityHint("Drag the panel header to move it.")
    }

    private func scrollToLatestLog(using proxy: ScrollViewProxy) {
        guard let lastIndex = logs.indices.last else {
            return
        }

        withAnimation(.easeOut(duration: 0.15)) {
            proxy.scrollTo(lastIndex, anchor: .bottom)
        }
    }

    private var panelDragGesture: some Gesture {
        DragGesture(minimumDistance: 4)
            .updating($dragOffset) { value, state, _ in
                state = value.translation
            }
            .onEnded { value in
                restingOffset = boundedPanelOffset(
                    CGSize(
                        width: restingOffset.width + value.translation.width,
                        height: restingOffset.height + value.translation.height
                    )
                )
            }
    }

    private func boundedPanelOffset(_ offset: CGSize) -> CGSize {
        let width = max(containerSize.width, 1)
        let height = max(containerSize.height, 1)
        return CGSize(
            width: min(max(offset.width, -width * 0.45), width * 0.45),
            height: min(max(offset.height, -height * 0.65), height * 0.2)
        )
    }
}

private struct RSICheckoutWebView: UIViewRepresentable {
    let initialURL: URL
    let itemTitle: String
    let cookies: [SessionCookie]
    let automation: RSICheckoutAutomation?
    let cookieExportRequestID: Int
    let onAutomationLog: @MainActor @Sendable (String) -> Void
    let onCookiesExported: @MainActor @Sendable ([SessionCookie]) -> Void
    let onCheckoutSucceeded: @MainActor @Sendable ([SessionCookie], URL?) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            initialURL: initialURL,
            itemTitle: itemTitle,
            cookies: cookies,
            automation: automation,
            onAutomationLog: onAutomationLog,
            onCookiesExported: onCookiesExported,
            onCheckoutSucceeded: onCheckoutSucceeded
        )
    }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
        configuration.userContentController.add(
            context.coordinator,
            name: Coordinator.checkoutAutomationMessageName
        )

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
            itemTitle: itemTitle,
            cookies: cookies,
            automation: automation,
            cookieExportRequestID: cookieExportRequestID
        )
    }

    static func dismantleUIView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.configuration.userContentController.removeScriptMessageHandler(
            forName: Coordinator.checkoutAutomationMessageName
        )
        coordinator.detach()
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
        static let checkoutAutomationMessageName = "checkoutAutomationLog"

        private weak var webView: WKWebView?
        private var initialURL: URL
        private var itemTitle: String
        private var cookies: [SessionCookie]
        private var automation: RSICheckoutAutomation?
        private var lastCookieExportRequestID = 0
        private var didLoadInitialPage = false
        private var didReportCheckoutSuccess = false
        private let onAutomationLog: @MainActor @Sendable (String) -> Void
        private let onCookiesExported: @MainActor @Sendable ([SessionCookie]) -> Void
        private let onCheckoutSucceeded: @MainActor @Sendable ([SessionCookie], URL?) -> Void

        init(
            initialURL: URL,
            itemTitle: String,
            cookies: [SessionCookie],
            automation: RSICheckoutAutomation?,
            onAutomationLog: @escaping @MainActor @Sendable (String) -> Void,
            onCookiesExported: @escaping @MainActor @Sendable ([SessionCookie]) -> Void,
            onCheckoutSucceeded: @escaping @MainActor @Sendable ([SessionCookie], URL?) -> Void
        ) {
            self.initialURL = initialURL
            self.itemTitle = itemTitle
            self.cookies = cookies
            self.automation = automation
            self.onAutomationLog = onAutomationLog
            self.onCookiesExported = onCookiesExported
            self.onCheckoutSucceeded = onCheckoutSucceeded
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
            itemTitle: String,
            cookies: [SessionCookie],
            automation: RSICheckoutAutomation?,
            cookieExportRequestID: Int
        ) {
            self.initialURL = initialURL
            self.itemTitle = itemTitle
            self.cookies = cookies
            self.automation = automation

            guard cookieExportRequestID != lastCookieExportRequestID else {
                return
            }

            lastCookieExportRequestID = cookieExportRequestID
            Task { @MainActor in
                let exportedCookies = await currentRSICookies()
                onCookiesExported(exportedCookies.isEmpty ? cookies : exportedCookies)
            }
        }

        func userContentController(
            _: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            let renderedMessage = Self.renderScriptMessage(message.body)
            guard !renderedMessage.isEmpty else {
                return
            }

            Task { @MainActor in
                onAutomationLog(renderedMessage)
            }

            if let confirmationURL = Self.checkoutConfirmationURL(from: renderedMessage) {
                reportCheckoutSuccess(confirmationURL: confirmationURL)
            }
        }

        func webView(_ webView: WKWebView, didFinish _: WKNavigation!) {
            startCheckoutAutomationIfNeeded(in: webView)
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

        private func startCheckoutAutomationIfNeeded(in webView: WKWebView) {
            guard let automation else {
                return
            }

            let script = Self.checkoutAutomationScript(
                amountText: automation.storeCreditAmount.cartCreditInputString,
                itemTitle: itemTitle,
                messageName: Self.checkoutAutomationMessageName
            )
            Task { @MainActor in
                onAutomationLog("Injecting checkout automation for \(automation.storeCreditAmount.cartCreditInputString) USD.")
            }
            webView.evaluateJavaScript(script) { [weak self] _, error in
                guard let error else {
                    return
                }

                let message = "Checkout automation injection failed: \(error.localizedDescription)"
                Task { @MainActor in
                    self?.onAutomationLog(message)
                }
            }
        }

        private func reportCheckoutSuccess(confirmationURL: URL?) {
            guard !didReportCheckoutSuccess else {
                return
            }

            didReportCheckoutSuccess = true
            Task { @MainActor in
                let exportedCookies = await currentRSICookies()
                onCheckoutSucceeded(exportedCookies.isEmpty ? cookies : exportedCookies, confirmationURL)
            }
        }

        private static func renderScriptMessage(_ body: Any) -> String {
            if let string = body as? String {
                return string.trimmingCharacters(in: .whitespacesAndNewlines)
            }

            if JSONSerialization.isValidJSONObject(body),
               let data = try? JSONSerialization.data(withJSONObject: body),
               let string = String(data: data, encoding: .utf8) {
                return string.trimmingCharacters(in: .whitespacesAndNewlines)
            }

            return String(describing: body).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        private static func checkoutConfirmationURL(from message: String) -> URL? {
            guard let markerRange = message.range(of: "Checkout confirmation URL reached:") else {
                return nil
            }

            let urlText = message[markerRange.upperBound...]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return URL(string: urlText)
        }

        private static func checkoutAutomationScript(amountText: String, itemTitle: String, messageName: String) -> String {
            let amountLiteral = javaScriptStringLiteral(amountText)
            let itemTitleLiteral = javaScriptStringLiteral(itemTitle)
            let messageLiteral = javaScriptStringLiteral(messageName)

            return #"""
            (() => {
              if (window.__hangerExpressCheckoutAutomation?.active) {
                return 'already-active';
              }

              const amountText = \#(amountLiteral);
              const expectedItemTitle = \#(itemTitleLiteral);
              const messageName = \#(messageLiteral);
              const expectedCartTotal = Number(String(amountText).replace(/[^0-9.]/g, '')) || 0;
              const normalizeKey = (value) => String(value || '')
                .replace(/\s+/g, ' ')
                .trim()
                .toLowerCase()
                .replace(/&/g, ' and ')
                .replace(/[^a-z0-9]+/g, ' ')
                .trim();
              const expectedItemKey = normalizeKey(expectedItemTitle);
              const state = {
                active: true,
                startedAt: Date.now(),
                clickedAtByKey: {},
                creditAddedAt: 0,
                creditInputFilled: false,
                summaryExpandedAt: 0,
                duplicateRemovalCount: 0,
                lastStatusLogAt: 0,
                graphQLCreditUpdateAttempted: false,
                graphQLCreditApplied: false,
                graphQLCheckoutAttempted: false,
                graphQLCheckoutCompleted: false,
                graphQLCheckoutStartedAt: 0,
                completed: false
              };
              window.__hangerExpressCheckoutAutomation = state;

              const normalizeText = (value) => String(value || '').replace(/\s+/g, ' ').trim();
              const lowerText = (value) => normalizeText(value).toLowerCase();
              const wait = (milliseconds) => new Promise(resolve => setTimeout(resolve, milliseconds));
              const postLog = (message) => {
                const entry = `[${new Date().toISOString()}] ${String(message || '')}`;
                try {
                  window.webkit?.messageHandlers?.[messageName]?.postMessage(entry);
                } catch (error) {
                  // Native logging is best-effort; keep automation running if the bridge is unavailable.
                }
                return entry;
              };

              const visible = (node) => {
                if (!node || !node.getBoundingClientRect) {
                  return false;
                }

                const rect = node.getBoundingClientRect();
                const style = window.getComputedStyle(node);
                return rect.width > 0 &&
                  rect.height > 0 &&
                  style.visibility !== 'hidden' &&
                  style.display !== 'none' &&
                  style.opacity !== '0';
              };
              const inViewport = (node) => {
                if (!node?.getBoundingClientRect) {
                  return false;
                }

                const rect = node.getBoundingClientRect();
                return rect.bottom > 0 &&
                  rect.top < window.innerHeight &&
                  rect.right > 0 &&
                  rect.left < window.innerWidth;
              };

              const disabled = (node) => Boolean(
                !node ||
                node.disabled ||
                node.matches?.('[disabled], [aria-disabled="true"]') ||
                node.closest?.('.disabled, .-disabled, [aria-disabled="true"]')
              );

              const textFor = (node) => normalizeText([
                node?.innerText,
                node?.textContent,
                node?.getAttribute?.('aria-label'),
                node?.getAttribute?.('title'),
                node?.getAttribute?.('value')
              ].filter(Boolean).join(' '));
              const conciseTextFor = (node) => {
                const text = textFor(node);
                return text.length > 80 ? `${text.slice(0, 77)}...` : text;
              };

              const dispatchClick = (node) => {
                node.scrollIntoView({ block: 'center', inline: 'center' });
                const rect = node.getBoundingClientRect();
                const clientX = Math.max(0, rect.left + rect.width / 2);
                const clientY = Math.max(0, rect.top + rect.height / 2);
                const target = document.elementFromPoint(clientX, clientY) || node;
                const options = { bubbles: true, cancelable: true, composed: true, view: window, clientX, clientY, button: 0 };
                const PointerEventConstructor = window.PointerEvent || MouseEvent;

                target.dispatchEvent(new PointerEventConstructor('pointerdown', { ...options, pointerId: 1, pointerType: 'mouse', isPrimary: true }));
                target.dispatchEvent(new MouseEvent('mousedown', options));
                target.dispatchEvent(new PointerEventConstructor('pointerup', { ...options, pointerId: 1, pointerType: 'mouse', isPrimary: true }));
                target.dispatchEvent(new MouseEvent('mouseup', options));
                target.dispatchEvent(new MouseEvent('click', options));
                if (target !== node) {
                  node.click();
                }
              };

              const clickOnce = (key, node, label) => {
                if (!node || disabled(node) || !visible(node)) {
                  return false;
                }

                const lastClickAt = state.clickedAtByKey[key] || 0;
                if (Date.now() - lastClickAt < 5000) {
                  return false;
                }

                state.clickedAtByKey[key] = Date.now();
                postLog(`Clicking ${label}.`);
                dispatchClick(node);
                return true;
              };

              const setInputValue = (input, value) => {
                input.focus();
                const prototype = Object.getPrototypeOf(input);
                const valueSetter = Object.getOwnPropertyDescriptor(prototype, 'value')?.set ||
                  Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value')?.set;

                if (valueSetter) {
                  valueSetter.call(input, value);
                } else {
                  input.value = value;
                }

                input.dispatchEvent(new InputEvent('input', { bubbles: true, cancelable: true, inputType: 'insertText', data: value }));
                input.dispatchEvent(new Event('change', { bubbles: true, cancelable: true }));
                input.dispatchEvent(new KeyboardEvent('keyup', { bubbles: true, cancelable: true, key: 'Enter' }));
              };

              const uniqueNodes = (nodes) => Array.from(new Set(nodes.filter(Boolean)));
              const actionableAncestor = (node) =>
                node?.closest?.('button') ||
                node?.closest?.('a[href]') ||
                node?.closest?.('[role="button"]') ||
                node?.closest?.('[data-cy-id="__place-order-button"]') ||
                node?.closest?.('.m-cartActionBar__button') ||
                null;

              const buttonLikeNodes = (root = document, includeDisabled = false) => Array.from(root.querySelectorAll?.('button, [role="button"], input[type="button"], input[type="submit"]') || [])
                .filter((node) => visible(node) && (includeDisabled || !disabled(node)));
              const buttons = () => buttonLikeNodes(document, false)
                .filter((node) => visible(node) && !disabled(node));

              const findButton = (predicate) => buttons().find((button) => predicate(lowerText(textFor(button)), button)) || null;
              const findButtonIn = (root, predicate, includeDisabled = false) =>
                buttonLikeNodes(root, includeDisabled)
                  .find((button) => predicate(lowerText(textFor(button)), button)) || null;
              const findExactButton = (label) => findButton((text) => text === label);
              const findCartContinueButton = () => {
                const isContinue = (node) => {
                  const text = lowerText(textFor(node));
                  return (text.includes('continue') || text.includes('proceed to pay') || text.includes('place order')) &&
                    !text.includes('shopping');
                };
                const isCartPrimaryAction = (node) => {
                  if (!node || disabled(node) || !visible(node)) {
                    return false;
                  }

                  const text = lowerText(textFor(node));
                  if (text.includes('continue shopping') || text === 'add' || text.includes('remove all')) {
                    return false;
                  }

                  return isContinue(node) ||
                    node.getAttribute?.('data-cy-id') === '__place-order-button' ||
                    node.matches?.('[data-cy-id="__place-order-button"], .m-cartActionBar__button') ||
                    Boolean(node.closest?.('.m-cartActionBar') && node.matches?.('button, [role="button"], [data-cy-id="button"]'));
                };
                const actionBarCandidates = uniqueNodes(Array.from(document.querySelectorAll([
                  '[data-cy-id="__place-order-button"]',
                  '[data-cy-id="cart-action-bar"] [data-cy-id="__place-order-button"]',
                  '[data-cy-id="cart-action-bar"] [data-cy-id="button"]',
                  '[data-cy-id="cart-action-bar"] button',
                  '[data-cy-id="cart-action-bar"] [role="button"]',
                  '[data-cy-id="cart-action-bar"] .m-cartActionBar__button',
                  '.m-cartActionBar__button',
                  '.m-cartActionBar button',
                  '.m-cartActionBar [role="button"]'
                ].join(','))).map(actionableAncestor))
                  .filter((button) => visible(button) && !disabled(button));
                const sortedActionBarCandidates = [...actionBarCandidates].sort((first, second) => {
                  const firstRect = first.getBoundingClientRect();
                  const secondRect = second.getBoundingClientRect();
                  const firstInViewport = firstRect.bottom > 0 && firstRect.top < window.innerHeight;
                  const secondInViewport = secondRect.bottom > 0 && secondRect.top < window.innerHeight;
                  if (firstInViewport !== secondInViewport) {
                    return firstInViewport ? -1 : 1;
                  }

                  return secondRect.top - firstRect.top;
                });

                const textMatchedButton = sortedActionBarCandidates.find(isContinue) ||
                  findExactButton('proceed to pay') ||
                  findExactButton('place order') ||
                  findExactButton('continue');
                if (textMatchedButton) {
                  return textMatchedButton;
                }

                const placeOrderButton = sortedActionBarCandidates.find((button) =>
                  button.getAttribute?.('data-cy-id') === '__place-order-button' ||
                  button.matches?.('[data-cy-id="__place-order-button"], .m-cartActionBar__button')
                );
                if (placeOrderButton) {
                  return placeOrderButton;
                }

                const textNodes = Array.from(document.querySelectorAll('body *'))
                  .filter((node) => visible(node) && ['continue', 'proceed to pay', 'place order'].includes(lowerText(textFor(node))))
                  .map(actionableAncestor)
                  .filter((node) => visible(node) && !disabled(node));
                if (textNodes.length) {
                  return textNodes[0];
                }

                const viewportCandidates = [];
                const lowestY = Math.max(0, window.innerHeight - 900);
                const yValues = [];
                for (let y = window.innerHeight - 28; y >= lowestY; y -= 32) {
                  yValues.push(y);
                }
                const xValues = [
                  window.innerWidth * 0.12,
                  window.innerWidth * 0.25,
                  window.innerWidth * 0.5,
                  window.innerWidth * 0.75,
                  window.innerWidth * 0.88
                ];
                for (const y of yValues) {
                  for (const x of xValues) {
                    viewportCandidates.push(actionableAncestor(document.elementFromPoint(x, y)));
                  }
                }

                const scannedCandidates = uniqueNodes(viewportCandidates)
                  .filter(isCartPrimaryAction)
                  .sort((first, second) => {
                    const firstRect = first.getBoundingClientRect();
                    const secondRect = second.getBoundingClientRect();
                    return secondRect.top - firstRect.top;
                  });
                if (scannedCandidates.length) {
                  const selected = scannedCandidates[0];
                  postLog(`Found cart action by viewport scan. label="${conciseTextFor(selected) || 'unlabeled'}", rect=${Math.round(selected.getBoundingClientRect().left)},${Math.round(selected.getBoundingClientRect().top)},${Math.round(selected.getBoundingClientRect().width)}x${Math.round(selected.getBoundingClientRect().height)}.`);
                  return selected;
                }

                return null;
              };
              const logStatus = (message) => {
                if (Date.now() - state.lastStatusLogAt < 2000) {
                  return;
                }

                state.lastStatusLogAt = Date.now();
                postLog(message);
              };
              const parseUSD = (value) => {
                const match = String(value || '').replace(/,/g, '').match(/-?\d+(?:\.\d{1,2})?/);
                const amount = match ? Number(match[0]) : Number.NaN;
                return Number.isFinite(amount) ? amount : null;
              };
              const parseMoneyValue = (value) => {
                if (typeof value === 'number' && Number.isFinite(value)) {
                  if (expectedCartTotal > 0 && Math.abs((value / 100) - expectedCartTotal) <= 0.01) {
                    return value / 100;
                  }

                  return value;
                }

                if (typeof value === 'string') {
                  return parseUSD(value);
                }

                if (value && typeof value === 'object') {
                  return parseMoneyValue(value.amount ?? value.value ?? value.formatted ?? value.raw);
                }

                return null;
              };
              const visibleCartTotal = () => {
                const nodes = Array.from(document.querySelectorAll([
                  '.m-cartActionBar',
                  '[data-cy-id="summary-unit"]',
                  '.m-summaryLineItem'
                ].join(',')));
                const totals = [];

                for (const node of nodes) {
                  if (!visible(node)) {
                    continue;
                  }

                  const text = normalizeText(node.innerText || node.textContent || '');
                  const regex = /\b(?:subtotal|total)\b[^$]{0,120}\$?\s*([0-9][0-9,]*(?:\.[0-9]{1,2})?)\s*usd\b/ig;
                  let match;
                  while ((match = regex.exec(text))) {
                    const amount = parseUSD(match[1]);
                    if (amount !== null) {
                      totals.push(amount);
                    }
                  }
                }

                return totals.length ? Math.max(...totals) : null;
              };
              const visibleFinalTotal = () => {
                const nodes = Array.from(document.querySelectorAll([
                  '.m-cartActionBar',
                  '[data-cy-id="summary-unit"]',
                  '.m-summaryLineItem'
                ].join(',')));
                const totals = [];

                for (const node of nodes) {
                  if (!visible(node)) {
                    continue;
                  }

                  const text = normalizeText(node.innerText || node.textContent || '');
                  const regex = /\btotal\b[^$]{0,120}\$?\s*([0-9][0-9,]*(?:\.[0-9]{1,2})?)\s*usd\b/ig;
                  let match;
                  while ((match = regex.exec(text))) {
                    const amount = parseUSD(match[1]);
                    if (amount !== null) {
                      totals.push(amount);
                    }
                  }
                }

                return totals.length ? Math.min(...totals) : null;
              };
              const storeCreditApplied = () => {
                if (state.graphQLCreditApplied) {
                  return true;
                }

                const finalTotal = visibleFinalTotal();
                if (finalTotal !== null && finalTotal <= 0.01) {
                  return true;
                }

                const text = lowerText(document.body?.innerText || '');
                const escapedAmountText = amountText.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
                if (
                  text.includes('store credits') &&
                  new RegExp(`[-−]\\s*\\$?\\s*${escapedAmountText}(?:\\.00)?\\s*usd`).test(text)
                ) {
                  return true;
                }

                const expectedAmount = expectedCartTotal > 0 ? expectedCartTotal : parseUSD(amountText);
                if (expectedAmount === null) {
                  return false;
                }

                const storeCreditUsedPattern = new RegExp(
                  `\\$?\\s*${expectedAmount.toFixed(2).replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}\\s*usd\\s*store\\s+credits?\\s+used`
                );
                if (storeCreditUsedPattern.test(text)) {
                  return true;
                }

                const creditSection = findStoreCreditSection?.();
                const creditSectionText = lowerText(creditSection?.innerText || creditSection?.textContent);
                if (
                  creditSection &&
                  !findStoreCreditInput?.(creditSection) &&
                  !findStoreCreditMaxButton?.(creditSection) &&
                  creditSectionText.includes('usd')
                ) {
                  const amounts = Array.from(creditSectionText.matchAll(/\$?\s*([0-9][0-9,]*(?:\.[0-9]{1,2})?)\s*usd/ig))
                    .map((match) => parseUSD(match[1]))
                    .filter((amount) => amount !== null);
                  if (amounts.some((amount) => Math.abs(amount - expectedAmount) <= 0.01)) {
                    return true;
                  }
                }

                const roots = [creditSection, document].filter(Boolean);
                const tokenSelector = [
                  '.a-tag',
                  '[class*="chip"]',
                  '[class*="token"]',
                  '[class*="pill"]',
                  'button',
                  '[role="button"]'
                ].join(',');

                for (const root of roots) {
                  const tokens = Array.from(root.querySelectorAll?.(tokenSelector) || [])
                    .filter((node) => visible(node));

                  for (const token of tokens) {
                    const tokenText = lowerText(textFor(token));
                    if (!tokenText.includes('usd')) {
                      continue;
                    }

                    const tokenAmount = parseUSD(tokenText);
                    if (tokenAmount !== null && Math.abs(tokenAmount - expectedAmount) <= 0.01) {
                      return true;
                    }
                  }
                }

                return false;
              };
              const cartLineItems = () => Array.from(document.querySelectorAll('[data-cy-id="cart-line-item"], .c-cartLineItem'))
                .filter((node) => visible(node));
              const cartLineItemName = (item) => normalizeText(
                item?.querySelector?.('[data-cy-id="__name"], .c-cartLineItem__name, h1, h2, h3, h4')?.innerText ||
                item?.querySelector?.('[data-cy-id="__name"], .c-cartLineItem__name, h1, h2, h3, h4')?.textContent ||
                ''
              );
              const itemMatchesExpected = (name) => {
                const key = normalizeKey(name);
                if (!expectedItemKey || !key) {
                  return false;
                }

                return key === expectedItemKey ||
                  key.includes(expectedItemKey) ||
                  expectedItemKey.includes(key);
              };
              const visibleCartItemCount = () => {
                const text = normalizeText(document.body?.innerText || '');
                const bracketCount = text.match(/\[(\d+)\s+items?\]/i)?.[1];
                if (bracketCount) {
                  const parsedCount = Number.parseInt(bracketCount, 10);
                  if (Number.isFinite(parsedCount)) {
                    return parsedCount;
                  }
                }

                const lines = cartLineItems();
                return lines.length ? lines.length : null;
              };
              const findCartLineItemDeleteButton = (item) => Array.from(item?.querySelectorAll?.([
                '[data-cy-id="__delete-button"]',
                'button[aria-label*="delete" i]',
                'button[aria-label*="remove" i]',
                'button[class*="delete" i]',
                'button[class*="remove" i]'
              ].join(',')) || [])
                .find((button) => visible(button) && !disabled(button)) || null;
              const findCartLineItemDecreaseButton = (item) => Array.from(item?.querySelectorAll?.([
                '[data-cy-id="number_field__decrease_button"]',
                '.m-numberField button[aria-label="-"]',
                'button[aria-label="-"]'
              ].join(',')) || [])
                .find((button) => visible(button) && !disabled(button)) || null;
              const removeDuplicateCartItemIfNeeded = () => {
                const total = visibleCartTotal();
                const itemCount = visibleCartItemCount();
                const lines = cartLineItems();
                const matchingLines = lines.filter((item) => itemMatchesExpected(cartLineItemName(item)));
                const hasDuplicateTotal = total !== null && expectedCartTotal > 0 && total > expectedCartTotal + 0.01;
                const hasDuplicateCount = itemCount !== null && itemCount > 1;

                if (!hasDuplicateTotal && !hasDuplicateCount) {
                  return false;
                }

                if (matchingLines.length > 1) {
                  const duplicate = matchingLines[matchingLines.length - 1];
                  const deleteButton = findCartLineItemDeleteButton(duplicate);
                  if (deleteButton && clickOnce(`remove-duplicate-${state.duplicateRemovalCount}`, deleteButton, 'duplicate cart item delete')) {
                    state.duplicateRemovalCount += 1;
                    postLog(`Removing duplicate ${expectedItemTitle || 'cart item'} before applying store credit. visibleItemCount=${itemCount ?? 'unknown'}, visibleTotal=${total === null ? 'unknown' : `$${total.toFixed(2)}`}.`);
                    return true;
                  }
                }

                if (matchingLines.length === 1 && hasDuplicateCount) {
                  const decreaseButton = findCartLineItemDecreaseButton(matchingLines[0]);
                  if (decreaseButton && clickOnce(`decrease-duplicate-${state.duplicateRemovalCount}`, decreaseButton, 'duplicate cart item quantity decrease')) {
                    state.duplicateRemovalCount += 1;
                    postLog(`Reducing duplicate ${expectedItemTitle || 'cart item'} quantity before applying store credit. visibleItemCount=${itemCount ?? 'unknown'}, visibleTotal=${total === null ? 'unknown' : `$${total.toFixed(2)}`}.`);
                    return true;
                  }
                }

                if (hasDuplicateTotal) {
                  state.active = false;
                  postLog(`Cart total/subtotal ${total === null ? 'unknown' : `$${total.toFixed(2)}`} exceeds expected $${expectedCartTotal.toFixed(2)}, and duplicate cleanup could not safely remove extras. Stopping checkout automation.`);
                  return false;
                }

                return false;
              };
              const ensureExpectedCartTotal = () => {
                const total = visibleCartTotal();
                if (total === null || expectedCartTotal <= 0 || total <= expectedCartTotal + 0.01) {
                  return true;
                }

                state.active = false;
                postLog(`Cart total $${total.toFixed(2)} exceeds expected $${expectedCartTotal.toFixed(2)}. Stopping checkout automation so duplicate cart items are not purchased.`);
                return false;
              };

              const storeFrontName = 'pledge';
              const recaptchaSiteKey = '6LerBOgUAAAAAKPg6vsAFPTN66Woz-jBClxdQU-o';
              const cookieValue = (name) => {
                const escapedName = name.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
                const match = document.cookie.match(new RegExp(`(?:^|;\\s*)${escapedName}=([^;]*)`));
                return match ? decodeURIComponent(match[1]) : '';
              };
              const csrfToken = () => normalizeText(
                document.querySelector('meta[name="csrf-token"]')?.getAttribute('content') ||
                document.querySelector('meta[name="csrf"]')?.getAttribute('content') ||
                document.querySelector('input[name="_token"]')?.getAttribute('value') ||
                cookieValue('XSRF-TOKEN')
              );
              const errorMessage = (error) => normalizeText(error?.message || error || 'unknown error');
              const graphQLRequest = async (operationName, query, variables = {}) => {
                const headers = {
                  accept: 'application/json',
                  'content-type': 'application/json'
                };
                const csrf = csrfToken();
                const rsiToken = cookieValue('Rsi-Token');
                const rsiDevice = cookieValue('_rsi_device');
                const accountAuth = cookieValue('Rsi-Account-Auth');
                if (csrf) {
                  headers['x-csrf-token'] = csrf;
                }
                if (rsiToken) {
                  headers['x-rsi-token'] = rsiToken;
                }
                if (rsiDevice) {
                  headers['x-rsi-device'] = rsiDevice;
                }
                if (accountAuth) {
                  headers['x-rsi-account-auth'] = accountAuth;
                }

                const response = await fetch(new URL('/graphql', window.location.origin).toString(), {
                  method: 'POST',
                  credentials: 'same-origin',
                  headers,
                  body: JSON.stringify({ operationName, query, variables })
                });
                const responseText = await response.text();
                let payload = {};
                try {
                  payload = responseText ? JSON.parse(responseText) : {};
                } catch (error) {
                  throw new Error(`GraphQL ${operationName} returned non-JSON HTTP ${response.status}: ${responseText.slice(0, 220)}`);
                }

                if (!response.ok) {
                  throw new Error(`GraphQL ${operationName} failed with HTTP ${response.status}: ${responseText.slice(0, 220)}`);
                }

                const messages = Array.isArray(payload.errors)
                  ? payload.errors.map((entry) => entry?.message).filter(Boolean)
                  : [];
                if (messages.length) {
                  throw new Error(`GraphQL ${operationName} returned errors: ${messages.join('; ').slice(0, 220)}`);
                }

                return payload.data || {};
              };
              const cartFlowFields = `
                flow {
                  steps {
                    step
                    action
                    finalStep
                    active
                    __typename
                  }
                  current {
                    orderCreated
                    __typename
                  }
                  __typename
                }
              `;
              const cartFlowLabel = (data) => {
                const steps = data?.store?.cart?.flow?.steps || data?.cart?.flow?.steps || [];
                const activeStep = Array.isArray(steps) ? steps.find((step) => step?.active) : null;
                if (!activeStep) {
                  return 'unknown';
                }

                return [
                  activeStep.step,
                  activeStep.action,
                  activeStep.finalStep ? 'final' : ''
                ].filter(Boolean).join('/') || 'unknown';
              };
              const currentCartStateGraphQL = () => graphQLRequest(
                'CartStateQuery',
                `query CartStateQuery($storeFront: String) {
                  store(name: $storeFront) {
                    cart {
                      totals {
                        total
                        subTotal
                        __typename
                      }
                      ${cartFlowFields}
                      __typename
                    }
                    order {
                      slug
                      __typename
                    }
                    __typename
                  }
                }`,
                { storeFront: storeFrontName }
              );
              const updateStoreCreditGraphQL = (amount) => graphQLRequest(
                'AddCreditMutation',
                `mutation AddCreditMutation($amount: Float!, $storeFront: String) {
                  store(name: $storeFront) {
                    cart {
                      mutations {
                        credit_update(amount: $amount)
                        __typename
                      }
                      totals {
                        total
                        subTotal
                        credits {
                          amount
                          maxApplicable
                          applicable
                          __typename
                        }
                        __typename
                      }
                      ${cartFlowFields}
                      __typename
                    }
                    __typename
                  }
                }`,
                { amount, storeFront: storeFrontName }
              );
              const moveNextGraphQL = () => graphQLRequest(
                'NextStepMutation',
                `mutation NextStepMutation($storeFront: String) {
                  store(name: $storeFront) {
                    cart {
                      mutations {
                        flow {
                          moveNext
                          __typename
                        }
                        __typename
                      }
                      ${cartFlowFields}
                      __typename
                    }
                    order {
                      slug
                      __typename
                    }
                    __typename
                  }
                }`,
                { storeFront: storeFrontName }
              );
              const addressBookGraphQL = () => graphQLRequest(
                'AddressBookQuery',
                `query AddressBookQuery($storeFront: String) {
                  store(name: $storeFront) {
                    addressBook {
                      id
                      defaultBilling
                      defaultShipping
                      firstname
                      lastname
                      __typename
                    }
                    cart {
                      billingRequired
                      shippingRequired
                      billingAddress {
                        id
                        __typename
                      }
                      shippingAddress {
                        id
                        __typename
                      }
                      ${cartFlowFields}
                      __typename
                    }
                    __typename
                  }
                }`,
                { storeFront: storeFrontName }
              );
              const assignAddressGraphQL = (billing, shipping) => graphQLRequest(
                'CartAddressAssignMutation',
                `mutation CartAddressAssignMutation($billing: ID, $shipping: ID, $storeFront: String) {
                  store(name: $storeFront) {
                    cart {
                      mutations {
                        assignAddresses(assign: { billing: $billing, shipping: $shipping })
                        __typename
                      }
                      billingAddress {
                        id
                        __typename
                      }
                      shippingAddress {
                        id
                        __typename
                      }
                      ${cartFlowFields}
                      __typename
                    }
                    __typename
                  }
                }`,
                { billing, shipping, storeFront: storeFrontName }
              );
              const validateCartGraphQL = (token, mark) => graphQLRequest(
                'CartValidateCartMutation',
                `mutation CartValidateCartMutation($storeFront: String, $token: String, $mark: String) {
                  store(name: $storeFront) {
                    cart {
                      mutations {
                        validate(mark: $mark, token: $token)
                        __typename
                      }
                      ${cartFlowFields}
                      __typename
                    }
                    order {
                      slug
                      __typename
                    }
                    __typename
                  }
                }`,
                { storeFront: storeFrontName, token, mark }
              );
              const randomValidationMark = () => {
                const chars = '0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ';
                return Array.from({ length: 22 }, () => chars[Math.floor(Math.random() * chars.length)]).join('');
              };
              const executeRecaptcha = () => new Promise((resolve, reject) => {
                const recaptcha = window.grecaptcha?.enterprise || window.grecaptcha;
                if (!recaptcha?.execute) {
                  reject(new Error('reCAPTCHA Enterprise is unavailable on the RSI checkout page'));
                  return;
                }

                let settled = false;
                const finish = (resolver, value) => {
                  if (settled) {
                    return;
                  }

                  settled = true;
                  resolver(value);
                };
                const run = () => {
                  Promise.resolve(recaptcha.execute(recaptchaSiteKey, { action: 'checkout' }))
                    .then((token) => {
                      const normalizedToken = normalizeText(token);
                      if (normalizedToken) {
                        finish(resolve, normalizedToken);
                      } else {
                        finish(reject, new Error('RSI returned an empty reCAPTCHA token'));
                      }
                    })
                    .catch((error) => finish(reject, error));
                };

                window.setTimeout(() => finish(reject, new Error('Timed out waiting for reCAPTCHA token')), 10000);
                if (recaptcha.ready) {
                  recaptcha.ready(run);
                } else {
                  run();
                }
              });
              const selectedAddressIDs = (data) => {
                const store = data?.store || {};
                const cart = store.cart || {};
                const addresses = Array.isArray(store.addressBook) ? store.addressBook : [];
                const idFor = (address) => normalizeText(address?.id);
                const fallbackAddressID = idFor(addresses.find((address) => address?.defaultBilling)) ||
                  idFor(addresses.find((address) => address?.defaultShipping)) ||
                  idFor(addresses[0]);
                return {
                  billing: cart.billingRequired === false ? null : (idFor(cart.billingAddress) || fallbackAddressID || null),
                  shipping: cart.shippingRequired === false ? null : (idFor(cart.shippingAddress) || fallbackAddressID || null)
                };
              };
              const graphQLCreditTotals = (data) => data?.store?.cart?.totals || data?.cart?.totals || {};
              const graphQLCreditUpdateConfirmed = (data) => {
                const totals = graphQLCreditTotals(data);
                const finalTotal = parseMoneyValue(totals.total);
                if (finalTotal !== null && finalTotal <= 0.01) {
                  return true;
                }

                const credits = Array.isArray(totals.credits)
                  ? totals.credits
                  : (totals.credits ? [totals.credits] : []);
                const creditAmounts = credits
                  .flatMap((credit) => [
                    credit?.amount,
                    credit?.applied,
                    credit?.used,
                    credit?.value
                  ])
                  .map(parseMoneyValue)
                  .filter((amount) => amount !== null);

                return creditAmounts.some((amount) => Math.abs(amount - expectedCartTotal) <= 0.01);
              };
              const updateStoreCreditWithGraphQLIfPossible = async () => {
                if (state.graphQLCreditUpdateAttempted || expectedCartTotal <= 0) {
                  return false;
                }

                state.graphQLCreditUpdateAttempted = true;
                try {
                  const data = await updateStoreCreditGraphQL(expectedCartTotal);
                  const totals = graphQLCreditTotals(data);
                  const finalTotal = parseMoneyValue(totals.total);
                  if (graphQLCreditUpdateConfirmed(data)) {
                    state.graphQLCreditApplied = true;
                    state.creditAddedAt = Date.now();
                    postLog(`GraphQL store credit update confirmed for $${expectedCartTotal.toFixed(2)} USD. finalTotal=${finalTotal === null ? 'unknown' : `$${finalTotal.toFixed(2)}`}.`);
                    return true;
                  }

                  postLog(`GraphQL store credit update sent, but RSI did not confirm the applied credit in the response. finalTotal=${finalTotal === null ? 'unknown' : `$${finalTotal.toFixed(2)}`}. Continuing with page controls.`);
                } catch (error) {
                  postLog(`GraphQL store credit update failed: ${errorMessage(error)}. Continuing with page controls.`);
                }

                return false;
              };
              const pageAppearsPastCartStep = () => {
                const text = lowerText(document.body?.innerText || '');
                return text.includes('billing information') ||
                  text.includes('place order') ||
                  text.includes('proceed to pay') ||
                  text.includes('disclaimer') ||
                  text.includes('go back to step 1');
              };
              const cartFlowAppearsPastCartStep = (data) => {
                const label = cartFlowLabel(data).toLowerCase();
                return label !== 'unknown' &&
                  !label.includes('cart') &&
                  !label.includes('basket');
              };
              const graphQLCheckoutIfPossible = async () => {
                if (state.graphQLCheckoutAttempted || state.graphQLCheckoutCompleted) {
                  return false;
                }

                state.graphQLCheckoutAttempted = true;
                state.graphQLCheckoutStartedAt = Date.now();
                postLog('Starting RSI GraphQL checkout flow.');

                try {
                  const initialState = await currentCartStateGraphQL();
                  postLog(`GraphQL cart state before checkout: ${cartFlowLabel(initialState)}.`);

                  if (!storeCreditApplied() && expectedCartTotal > 0) {
                    const creditData = await updateStoreCreditGraphQL(expectedCartTotal);
                    state.graphQLCreditUpdateAttempted = true;
                    if (graphQLCreditUpdateConfirmed(creditData)) {
                      state.graphQLCreditApplied = true;
                      postLog(`GraphQL store credit update confirmed for $${expectedCartTotal.toFixed(2)} USD.`);
                    } else {
                      postLog(`GraphQL store credit update sent for $${expectedCartTotal.toFixed(2)} USD, but the response did not confirm the applied credit.`);
                    }
                    await wait(350);
                  } else {
                    postLog('Store credit already appears applied; skipping GraphQL credit update.');
                  }

                  if (!pageAppearsPastCartStep() && !cartFlowAppearsPastCartStep(initialState)) {
                    const movedState = await moveNextGraphQL();
                    postLog(`GraphQL cart flow moveNext sent. New state: ${cartFlowLabel(movedState)}.`);
                    await wait(350);
                  } else {
                    postLog('Checkout page appears past the cart step; skipping GraphQL moveNext.');
                  }

                  const addressData = await addressBookGraphQL();
                  const addressIDs = selectedAddressIDs(addressData);
                  if (addressIDs.billing || addressIDs.shipping) {
                    const assignedState = await assignAddressGraphQL(addressIDs.billing, addressIDs.shipping);
                    postLog(`GraphQL address assignment sent. billing=${addressIDs.billing ? 'selected' : 'none'}, shipping=${addressIDs.shipping ? 'selected' : 'none'}, state=${cartFlowLabel(assignedState)}.`);
                    await wait(350);
                  } else {
                    postLog('GraphQL address assignment skipped because RSI did not return a saved address.');
                  }

                  const token = await executeRecaptcha();
                  postLog('reCAPTCHA token acquired for RSI cart validation.');
                  const validatedState = await validateCartGraphQL(token, randomValidationMark());
                  const orderSlug = normalizeText(validatedState?.store?.order?.slug);
                  const orderCreated = validatedState?.store?.cart?.flow?.current?.orderCreated;
                  postLog(`GraphQL cart validation returned state=${cartFlowLabel(validatedState)}, orderCreated=${orderCreated === undefined ? 'unknown' : orderCreated}, orderSlug=${orderSlug || 'none'}.`);

                  state.graphQLCheckoutCompleted = true;
                  if (orderSlug) {
                    const confirmURL = new URL(`/en/store/pledge/cart/confirm/${encodeURIComponent(orderSlug)}/hangar`, window.location.origin).toString();
                    postLog(`Opening RSI confirmation page: ${confirmURL}`);
                    window.location.href = confirmURL;
                    return true;
                  }

                  if (orderCreated === false) {
                    state.active = false;
                    state.completed = true;
                    postLog('GraphQL cart validation completed and RSI did not require a browser confirmation page.');
                    return true;
                  }

                  postLog('GraphQL cart validation completed without a confirmation slug; waiting for the RSI page to update.');
                  return true;
                } catch (error) {
                  postLog(`GraphQL checkout flow failed: ${errorMessage(error)}. Falling back to RSI page controls.`);
                  return false;
                }
              };

              const summaryCandidates = () => Array.from(document.querySelectorAll([
                '[data-cy-id="summary"]',
                '.cart-summary-unit',
                '.c-summary',
                '.l-cart__summary',
                '[class*="summary" i]'
              ].join(',')));

              const findOrderSummary = () => {
                const summaries = summaryCandidates()
                  .filter((node) => lowerText(node.innerText || node.textContent).includes('order summary'));
                const visibleSummaries = summaries.filter((node) => visible(node));
                return visibleSummaries.find((node) => inViewport(node)) ||
                  visibleSummaries[0] ||
                  summaries[0] ||
                  null;
              };

              const summaryIsOpen = (summary) => Boolean(
                summary?.querySelector?.('.c-summary__collapsible.-isOpen, [data-cy-id="__collapsible-container"].-isOpen')
              );

              const findSummaryToggleButton = (summary) => Array.from(summary?.querySelectorAll?.([
                '.m-cartHeader button[data-cy-id="__button"]',
                '[data-cy-id="__header"] button[data-cy-id="__button"]',
                '[data-cy-id="__header"] button',
                'button'
              ].join(',')) || [])
                .find((button) => visible(button) && !disabled(button)) || null;
              const findVisibleOrderSummaryExpandButton = (summary = null) => {
                const candidateRoots = [summary, document].filter(Boolean);
                for (const root of candidateRoots) {
                  const candidates = uniqueNodes(Array.from(root.querySelectorAll?.('button, [role="button"]') || []))
                    .filter((button) => {
                      if (!visible(button) || disabled(button)) {
                        return false;
                      }

                      const label = lowerText(textFor(button));
                      const ariaLabel = lowerText(button.getAttribute?.('aria-label'));
                      if (!label.includes('expand') && !ariaLabel.includes('expand')) {
                        return false;
                      }

                      const context = button.closest?.('[data-cy-id="summary"], .c-summary, .cart-summary-unit, .l-cart__summary, [data-cy-id="__header"], .m-cartHeader, section, div');
                      return lowerText(context?.innerText || context?.textContent).includes('order summary');
                    })
                    .sort((first, second) => Number(inViewport(second)) - Number(inViewport(first)));
                  if (candidates.length) {
                    return candidates[0];
                  }
                }

                return null;
              };

              const expandOrderSummaryIfNeeded = () => {
                const summary = findOrderSummary();
                if (!summary) {
                  logStatus('Order Summary panel was not found yet.');
                  return false;
                }

                const visibleCreditInput = findStoreCreditInput(findStoreCreditSection());
                if (visibleCreditInput) {
                  return false;
                }

                const visibleExpandButton = findVisibleOrderSummaryExpandButton(summary);
                if (visibleExpandButton) {
                  if (clickOnce('order-summary-expand', visibleExpandButton, 'Order Summary expand')) {
                    state.summaryExpandedAt = Date.now();
                  }

                  return true;
                }

                if (summaryIsOpen(summary) && lowerText(summary.innerText || summary.textContent).includes('add store credits')) {
                  return false;
                }

                const toggleButton = findSummaryToggleButton(summary);
                if (!toggleButton) {
                  logStatus('Order Summary expand button was not available yet.');
                  return false;
                }

                if (clickOnce('order-summary-expand', toggleButton, 'Order Summary expand')) {
                  state.summaryExpandedAt = Date.now();
                }

                return true;
              };

              const scrollTowardStoreCredit = () => {
                const creditNode = Array.from(document.querySelectorAll('[data-cy-id="summary-unit"], .a-summaryUnitBlock, .m-summaryLineItem, label, p, div'))
                  .find((node) => visible(node) && lowerText(node.innerText || node.textContent).includes('add store credits'));
                if (creditNode?.scrollIntoView) {
                  creditNode.scrollIntoView({ block: 'center', inline: 'nearest' });
                  return;
                }

                const summary = findOrderSummary();
                if (summary?.scrollIntoView) {
                  summary.scrollIntoView({ block: 'center', inline: 'nearest' });
                }
              };

              const storeCreditContext = (node) => node?.closest?.([
                '[data-cy-id="summary-unit"]',
                '.a-summaryUnitBlock',
                '.m-summaryLineItem',
                '.m-inputBase',
                '.c-summary',
                'section',
                'form'
              ].join(',')) || null;

              const storeCreditContextText = (node, section = null) => {
                if (section?.contains?.(node)) {
                  return lowerText(section.innerText || section.textContent);
                }

                const context = storeCreditContext(node);
                return lowerText(context?.innerText || context?.textContent);
              };

              const isStoreCreditControl = (node, section = null) => {
                const contextText = storeCreditContextText(node, section);
                return Boolean(section?.contains?.(node)) ||
                  contextText.includes('add store credits') ||
                  contextText.includes('store credits') ||
                  contextText.includes('amount');
              };

              const findStoreCreditSection = () => {
                const selectors = [
                  '[data-cy-id="summary-unit"]',
                  '.a-summaryUnitBlock',
                  '.m-summaryLineItem',
                  '.m-inputBase'
                ];
                return Array.from(document.querySelectorAll(selectors.join(',')))
                  .find((node) => lowerText(node.innerText || node.textContent).includes('add store credits')) || null;
              };

              const findStoreCreditInput = (section) => {
                const inputs = [
                  ...Array.from(section?.querySelectorAll?.('input:not([type="hidden"])') || []),
                  ...Array.from(document.querySelectorAll('input:not([type="hidden"])'))
                ];
                return inputs.find((input) => {
                  if (!visible(input) || disabled(input)) {
                    return false;
                  }

                  const contextText = storeCreditContextText(input, section);
                  const labelText = lowerText(document.querySelector(`label[for="${input.id}"]`)?.innerText || '');
                  return contextText.includes('add store credits') ||
                    contextText.includes('store credits') ||
                    labelText.includes('amount');
                }) || null;
              };

              const findStoreCreditMaxButton = (section) => {
                const candidateButtons = [
                  ...Array.from(section?.querySelectorAll?.('button, [role="button"], input[type="button"], input[type="submit"]') || []),
                  ...buttons()
                ];

                return candidateButtons.find((button) => {
                  if (!visible(button) || disabled(button)) {
                    return false;
                  }

                  const label = lowerText(textFor(button));
                  const ariaLabel = lowerText(button.getAttribute?.('aria-label'));
                  if (!label.includes('max') && !ariaLabel.includes('max')) {
                    return false;
                  }

                  return isStoreCreditControl(button, section);
                }) || null;
              };

              const findStoreCreditAddButton = (section) => {
                const candidateButtons = [
                  ...Array.from(section?.querySelectorAll?.('button, [role="button"], input[type="button"], input[type="submit"]') || []),
                  ...buttons()
                ];

                return candidateButtons.find((button) => {
                  if (!visible(button) || disabled(button)) {
                    return false;
                  }

                  const label = lowerText(textFor(button));
                  const ariaLabel = lowerText(button.getAttribute?.('aria-label'));
                  return isStoreCreditControl(button, section) &&
                    (ariaLabel.includes('validate credit') || label === 'add');
                }) || null;
              };

              const findStoreCreditExpandTarget = (section) => {
                const explicitTarget = Array.from(section?.querySelectorAll?.([
                  'button',
                  '[role="button"]',
                  '[aria-expanded="false"]'
                ].join(',')) || [])
                  .find((button) => {
                    if (!visible(button) || disabled(button)) {
                      return false;
                    }

                    const label = lowerText(textFor(button));
                    const ariaLabel = lowerText(button.getAttribute?.('aria-label'));
                    return button.getAttribute?.('aria-expanded') === 'false' ||
                      label.includes('expand') ||
                      ariaLabel.includes('expand') ||
                      ariaLabel.includes('open');
                  });

                if (explicitTarget) {
                  return explicitTarget;
                }

                return [
                  section?.querySelector?.('.m-summaryLineItem__row'),
                  section?.querySelector?.('.a-summaryUnitBlock__inside'),
                  section
                ].find((node) => visible(node) && !disabled(node)) || null;
              };

              const findDisclaimerModal = () => Array.from(document.querySelectorAll('[data-cy-id="modal"], dialog, .c-modal__modal, .c-modal'))
                .find((node) => visible(node) && lowerText(node.innerText || node.textContent).includes('disclaimer')) || null;

              const findDisclaimerJumpButton = (modal) => findButtonIn(
                modal || document,
                (text) => text.includes('jump to bottom'),
                false
              );

              const findDisclaimerAgreeButton = (modal, includeDisabled = false) => findButtonIn(
                modal || document,
                (text, button) => text === 'i agree' ||
                  text.includes('i agree') ||
                  button.getAttribute?.('data-cy-id') === 'modal_footer__primary_button',
                includeDisabled
              );

              const scrollDisclaimerToBottom = (modal) => {
                const content = modal?.querySelector?.('.cartDisclaimerModal, [data-cy-id="modal_content"], .m-modalContent');
                if (content) {
                  content.scrollTop = content.scrollHeight;
                  content.dispatchEvent(new Event('scroll', { bubbles: true, cancelable: false }));
                }

                const footer = modal?.querySelector?.('[data-cy-id="modal_footer"], .m-modalFooter');
                footer?.scrollIntoView?.({ block: 'end', inline: 'nearest' });
              };

              const disclaimerCheckboxChecked = (checkbox) => {
                const label = checkbox?.closest?.('label') || document.querySelector(`label[for="${checkbox?.id}"]`);
                return Boolean(
                  checkbox?.checked ||
                  checkbox?.getAttribute?.('aria-checked') === 'true' ||
                  label?.classList?.contains('on')
                );
              };
              const setDisclaimerCheckboxValue = (checkbox) => {
                const valueSetter = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'checked')?.set ||
                  Object.getOwnPropertyDescriptor(Object.getPrototypeOf(checkbox), 'checked')?.set;
                if (valueSetter) {
                  valueSetter.call(checkbox, true);
                } else {
                  checkbox.checked = true;
                }

                checkbox.setAttribute('aria-checked', 'true');
                checkbox.dispatchEvent(new InputEvent('input', { bubbles: true, cancelable: true, inputType: 'insertText', data: 'true' }));
                checkbox.dispatchEvent(new Event('change', { bubbles: true, cancelable: true }));
              };
              const disclaimerCheckboxClickTarget = (checkbox) => {
                const wrapper = checkbox?.closest?.('[data-cy-id="checkbox"], .a-checkbox');
                return checkbox?.closest?.('label') ||
                  document.querySelector(`label[for="${checkbox?.id}"]`) ||
                  wrapper?.querySelector?.('[data-cy-id="checkbox__display"], .a-checkboxDisplay, .a-checkbox__wrapper') ||
                  checkbox;
              };
              const ensureDisclaimerCheckbox = async (root = document, shouldLogMissing = true) => {
                const checkbox = root.querySelector?.('.cartDisclaimerModal input[type="checkbox"], [data-cy-id="checkbox__input"], input[type="checkbox"]') ||
                  document.querySelector('.cartDisclaimerModal input[type="checkbox"], [data-cy-id="checkbox__input"], input[type="checkbox"]');
                if (!checkbox || disabled(checkbox)) {
                  if (shouldLogMissing) {
                    postLog('Disclaimer checkbox was not found or is disabled.');
                  }
                  return false;
                }

                if (disclaimerCheckboxChecked(checkbox)) {
                  return true;
                }

                const lastClickAt = state.clickedAtByKey['disclaimer-checkbox'] || 0;
                if (Date.now() - lastClickAt < 800) {
                  return false;
                }

                state.clickedAtByKey['disclaimer-checkbox'] = Date.now();
                const target = disclaimerCheckboxClickTarget(checkbox);
                postLog('Checking disclaimer checkbox.');
                if (target) {
                  dispatchClick(target);
                  target.click?.();
                }

                await wait(350);
                if (disclaimerCheckboxChecked(checkbox)) {
                  return true;
                }

                checkbox.click?.();
                await wait(250);
                if (disclaimerCheckboxChecked(checkbox)) {
                  return true;
                }

                postLog('Disclaimer checkbox did not update from click; setting checked state and dispatching input/change events.');
                setDisclaimerCheckboxValue(checkbox);
                await wait(250);
                return disclaimerCheckboxChecked(checkbox);
              };

              const handleDisclaimerModalIfPresent = async () => {
                const modal = findDisclaimerModal();
                if (!modal) {
                  return false;
                }

                const jumpButton = findDisclaimerJumpButton(modal);
                if (jumpButton && clickOnce('disclaimer-jump-bottom', jumpButton, 'Jump to bottom')) {
                  await wait(600);
                  return true;
                }

                scrollDisclaimerToBottom(modal);
                const checkboxReady = await ensureDisclaimerCheckbox(modal, false);
                if (!checkboxReady) {
                  await wait(600);
                  return true;
                }

                const agreeButton = findDisclaimerAgreeButton(modal, true);
                if (!agreeButton) {
                  logStatus('Disclaimer modal is open, but the I Agree button was not found yet.');
                  await wait(600);
                  return true;
                }

                if (disabled(agreeButton)) {
                  logStatus('Disclaimer I Agree button is still disabled after jumping to the bottom.');
                  await wait(600);
                  return true;
                }

                clickOnce('agree-disclaimer', agreeButton, 'I agree');
                await wait(900);
                return true;
              };

              const isConfirmURL = () => /\/(?:store\/)?pledge\/cart\/confirm\/[^/]+\/hangar\/?$/i.test(window.location.pathname);

              const applyStoreCreditIfAvailable = async () => {
                if (storeCreditApplied()) {
                  return true;
                }

                if (await updateStoreCreditWithGraphQLIfPossible()) {
                  return true;
                }

                if (expandOrderSummaryIfNeeded()) {
                  logStatus('Expanded Order Summary to reveal store credit controls.');
                  await wait(450);
                  return false;
                }

                const section = findStoreCreditSection();
                const input = findStoreCreditInput(section);
                if (!section) {
                  scrollTowardStoreCredit();
                  logStatus('Waiting for the store credit section to appear.');
                  return false;
                }

                const maxButton = findStoreCreditMaxButton(section);
                const inputAmount = input
                  ? Number(String(input.value || '').replace(/[^0-9.]/g, '')) || 0
                  : 0;
                logStatus(`Store credit controls visible. input=${input ? `"${normalizeText(input.value)}"` : 'missing'}, max=${maxButton ? 'yes' : 'no'}, inputAmount=${inputAmount}.`);
                if (maxButton && (!input || inputAmount <= 0)) {
                  if (clickOnce('store-credit-max', maxButton, 'store credit MAX')) {
                    state.creditInputFilled = true;
                    postLog('Clicked MAX in the store credit section.');
                    await wait(500);
                    return false;
                  }
                }

                if (!input) {
                  const expandTarget = findStoreCreditExpandTarget(section);
                  if (expandTarget && clickOnce('store-credit-expand', expandTarget, 'store credit expand')) {
                    await wait(450);
                    return false;
                  }

                  scrollTowardStoreCredit();
                  logStatus('Store credit section was found, but the amount input is still hidden.');
                  return false;
                }

                input.scrollIntoView({ block: 'center', inline: 'nearest' });
                if (!state.creditInputFilled || normalizeText(input.value) !== amountText) {
                  setInputValue(input, amountText);
                  state.creditInputFilled = true;
                  postLog(`Entered ${amountText} USD into the store credit field.`);
                  await wait(250);
                }

                const addButton = findStoreCreditAddButton(section);
                if (!addButton) {
                  logStatus('Store credit amount is entered; waiting for the Add credit button.');
                  return true;
                }

                if (clickOnce('add-credit', addButton, 'store credit Add')) {
                  state.creditAddedAt = Date.now();
                }

                return true;
              };

              const drive = async () => {
                postLog(`Checkout automation started. Store credit amount=${amountText} USD.`);

                while (state.active && Date.now() - state.startedAt < 120000) {
                  if (isConfirmURL()) {
                    state.active = false;
                    state.completed = true;
                    postLog(`Checkout confirmation URL reached: ${window.location.href}`);
                    return;
                  }

                  if (removeDuplicateCartItemIfNeeded()) {
                    await wait(900);
                    continue;
                  }

                  if (!state.active || !ensureExpectedCartTotal()) {
                    return;
                  }

                  if (await handleDisclaimerModalIfPresent()) {
                    continue;
                  }

                  const handledWithGraphQL = await graphQLCheckoutIfPossible();
                  if (handledWithGraphQL) {
                    await wait(900);
                    continue;
                  }

                  const agreeButton = findExactButton('i agree');
                  if (agreeButton && lowerText(document.body?.innerText || '').includes('disclaimer')) {
                    await ensureDisclaimerCheckbox();
                    await wait(250);
                    clickOnce('agree-disclaimer', agreeButton, 'I agree');
                    await wait(900);
                    continue;
                  }

                  const proceedToPayButton = findExactButton('proceed to pay');
                  if (proceedToPayButton) {
                    clickOnce('proceed-to-pay', proceedToPayButton, 'Proceed to pay');
                    await wait(900);
                    continue;
                  }

                  const primaryActionButton = findCartContinueButton();
                  const primaryActionText = lowerText(textFor(primaryActionButton));
                  if (
                    primaryActionButton &&
                    (primaryActionText.includes('proceed to pay') || primaryActionText.includes('place order'))
                  ) {
                    const primaryActionKey = `cart-primary-action-${normalizeKey(primaryActionText).slice(0, 32) || 'button'}`;
                    clickOnce(primaryActionKey, primaryActionButton, conciseTextFor(primaryActionButton) || 'cart primary action');
                    await wait(900);
                    continue;
                  }

                  const handledCredit = await applyStoreCreditIfAvailable();
                  if (handledCredit) {
                    if (!storeCreditApplied()) {
                      if (state.creditAddedAt && Date.now() - state.creditAddedAt < 3000) {
                        await wait(300);
                        continue;
                      }

                      logStatus('Waiting for store credit to apply to the order total.');
                      await wait(300);
                      continue;
                    }

                    const continueButton = findCartContinueButton();
                    if (continueButton) {
                      clickOnce('cart-continue', continueButton, conciseTextFor(continueButton) || 'cart primary action');
                    } else {
                      postLog('Continue button was not available yet.');
                    }

                    await wait(700);
                    continue;
                  }

                  scrollTowardStoreCredit();
                  await wait(500);
                }

                state.active = false;
                postLog(`Checkout automation stopped before confirmation. url=${window.location.href}, title=${document.title}`);
              };

              drive();
              return 'started';
            })();
            """#
        }

        private static func javaScriptStringLiteral(_ value: String) -> String {
            if let data = try? JSONSerialization.data(withJSONObject: [value]),
               let arrayLiteral = String(data: data, encoding: .utf8) {
                return String(arrayLiteral.dropFirst().dropLast())
            }

            let escapedValue = value
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
                .replacingOccurrences(of: "\n", with: "\\n")
                .replacingOccurrences(of: "\r", with: "\\r")
            return "\"\(escapedValue)\""
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

private extension Decimal {
    var cartCreditInputString: String {
        NSDecimalNumber(decimal: self).stringValue
    }
}
