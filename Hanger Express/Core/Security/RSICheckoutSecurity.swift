import Foundation

nonisolated enum RSICheckoutNavigationPolicy {
    enum Decision { case inApp, external, cancel }

    static func decision(for url: URL?, isMainFrame: Bool, isUserLink: Bool = false) -> Decision {
        guard let url, let scheme = url.scheme?.lowercased(), url.user == nil, url.password == nil else { return .cancel }
        if !isMainFrame {
            return scheme == "https" || url.absoluteString == "about:blank" ? .inApp : .cancel
        }
        if RSISecurityPolicy.isTrustedOrigin(url) { return .inApp }
        if scheme == "https", let host = url.host?.lowercased(), url.port == nil || url.port == 443 {
            if embeddedPaymentDomains.contains(where: { host == $0 || host.hasSuffix("." + $0) }) { return .inApp }
            if isUserLink || externalPaymentDomains.contains(where: { host == $0 || host.hasSuffix("." + $0) }) { return .external }
        }
        if ["alipays", "alipay", "weixin", "wechat", "paypal"].contains(scheme) { return .external }
        return .cancel
    }

    static func allowsResponse(for url: URL?, isMainFrame: Bool) -> Bool {
        !isMainFrame || decision(for: url, isMainFrame: true) == .inApp
    }

    // Browsing permission does not grant native RSI credentials or automation.
    private static let embeddedPaymentDomains: Set<String> = ["alipay.com", "alipay.hk", "alipayobjects.com",
        "tenpay.com", "wechatpay.com", "wechatpay.cn", "wechatpay.com.cn", "pay.weixin.qq.com"]
    private static let externalPaymentDomains: Set<String> = ["paypal.com", "paypalobjects.com", "unionpay.com", "95516.com"]
}

nonisolated enum RSICheckoutBridgePolicy {
    enum Event: Equatable { case log(String), confirmation(URL) }

    static func event(body: Any, isMainFrame: Bool, senderOrigin: URL?, frameURL: URL?, currentURL: URL?,
                      checkoutID: String, documentID: String) -> Event? {
        guard isMainFrame, RSISecurityPolicy.sameOrigin(senderOrigin, currentURL),
              RSISecurityPolicy.sameOrigin(frameURL, currentURL),
              RSISecurityPolicy.isCheckoutURL(currentURL),
              let value = body as? [String: Any], value.count == 4,
              value["checkoutID"] as? String == checkoutID,
              value["documentID"] as? String == documentID,
              let kind = value["kind"] as? String else { return nil }
        switch kind {
        case "log":
            guard let message = value["message"] as? String, message.utf8.count <= 2_048 else { return nil }
            return .log(message)
        case "confirmation":
            guard let raw = value["url"] as? String, raw.utf8.count <= 2_048, let url = URL(string: raw),
                  RSISecurityPolicy.isCheckoutConfirmationURL(url),
                  url == currentURL, url == frameURL else { return nil }
            return .confirmation(url)
        default: return nil
        }
    }
}
