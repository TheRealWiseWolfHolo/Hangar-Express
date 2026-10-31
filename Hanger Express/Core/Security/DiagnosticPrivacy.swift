import Foundation
import UIKit
import UniformTypeIdentifiers

/// One policy for collected support fields, visible diagnostic previews and
/// clipboard exports. Never serialize arbitrary error userInfo or response bodies.
nonisolated enum DiagnosticPrivacy {
    static let maximumReportBytes = 65_536
    static let clipboardLifetime: TimeInterval = 600

    static func text(_ input: String, secrets: [String] = [], limit: Int = 16_384) -> String {
        let inputLimit = min(max(limit, 1), maximumReportBytes)
        guard input.utf8.prefix(inputLimit + 1).count <= inputLimit else {
            return "[message omitted: exceeds diagnostic length limit]"
        }
        var value = input.replacingOccurrences(of: "\\/", with: "/")
        for host in privateEndpointHosts { value = value.replacingOccurrences(of: host, with: "[redacted endpoint]", options: .caseInsensitive) }
        for secret in Set(secrets.filter { !$0.isEmpty }).sorted(by: { $0.count > $1.count }) {
            value = value.replacingOccurrences(of: secret, with: "[redacted]")
            if let encoded = secret.addingPercentEncoding(withAllowedCharacters: .alphanumerics), encoded != secret {
                value = value.replacingOccurrences(of: encoded, with: "[redacted]", options: .caseInsensitive)
            }
        }
        value = replacing(#"(?im)\b(?:authorization|proxy-authorization|cookie|set-cookie|x-rsi-token|x-rsi-device|x-rsi-account-auth)\s*[:=][^\r\n]*"#,
                          in: value, with: "[redacted credential field]")
        value = replacing(#"(?i)\bBearer\s+[^\s,;]+"#, in: value, with: "Bearer [redacted]")
        value = replacing(#"(?i)["']?\b(?:password|current_password|rsi-token|rsi-account-auth|_rsi_device|token|session_id|device_id|access_token|refresh_token|captchaToken|captcha_code|verificationCode|mfa_code|totp|otp|loginIdentifier|displayName|email|handle|account|accountID|recipient|responsePreview|responseBody|RSIResponseBody|bodyPreview)["']?\s*[:=]\s*(?:"[^"\r\n]*"|'[^'\r\n]*'|[^,;\r\n]+)"#,
                          in: value, with: "[redacted private field]")
        value = replacing(#"(?i)["']?\bcode["']?\s*[:=]\s*(?:"[^"\r\n]*"|'[^'\r\n]*'|[A-Za-z0-9]{6,})"#,
                          in: value, with: "[redacted verification field]")
        value = replacing(#"(?i)https?%3a%2f%2f[^\s<>"']+"#, in: value, with: "[redacted endpoint]")
        value = replacing(#"(?i)\b[A-Z0-9.-]+\.(?:workers|pages)\.dev\b"#, in: value, with: "[redacted endpoint]")
        if let regex = try? NSRegularExpression(pattern: #"https?://[^\s<>"']+"#, options: .caseInsensitive) {
            for match in regex.matches(in: value, range: NSRange(value.startIndex..., in: value)).reversed() {
                guard let range = Range(match.range, in: value) else { continue }
                value.replaceSubrange(range, with: safeURL(URL(string: String(value[range]))))
            }
        }
        value = replacing(#"(?i)[A-Z0-9._%+*-]+@[A-Z0-9.-]+\.[A-Z]{2,}"#, in: value, with: "[redacted email]")
        return value
    }

    static func report(_ fields: [String], secrets: [String] = []) -> String {
        var output = ""
        for field in fields.prefix(512) {
            let safe = text(field, secrets: secrets)
            guard output.utf8.count + safe.utf8.count + 1 <= maximumReportBytes - 32 else {
                return output + "\n[report truncated]"
            }
            if !output.isEmpty { output += "\n" }
            output += safe
        }
        return fields.count > 512 ? output + "\n[report truncated]" : output
    }

    static func safeURL(_ url: URL?) -> String {
        guard let url, url.absoluteString.utf8.prefix(2_049).count <= 2_048,
              var parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              ["https", "http"].contains(parts.scheme?.lowercased() ?? ""),
              let host = parts.host?.lowercased(), RSISecurityPolicy.credentialHosts.contains(host) else { return "[redacted endpoint]" }
        parts.user = nil; parts.password = nil; parts.fragment = nil
        let paths: Set<String> = ["", "/", "/en/account/pledges", "/account/pledges", "/en/account/buy-back-pledges",
            "/account/buy-back-pledges", "/en/account/login", "/en/login", "/login", "/graphql"]
        if !paths.contains(parts.path) { parts.path = "/[redacted-path]" }
        let query = Array((parts.queryItems ?? []).filter {
            ["page", "pagesize"].contains($0.name.lowercased()) && ($0.value.map {
                !$0.isEmpty && $0.utf8.prefix(7).count <= 6 && $0.utf8.allSatisfy { (48...57).contains($0) }
            } ?? false)
        }.prefix(2))
        parts.queryItems = query.isEmpty ? nil : query
        return parts.string ?? "unavailable"
    }

    static func sensitiveValues(for session: UserSession) -> [String] {
        [session.credentials?.password ?? "", session.credentials?.loginIdentifier ?? "", session.email,
            session.handle, session.displayName] + session.cookies.map(\.value)
    }

    @MainActor static func copy(_ report: String) {
        UIPasteboard.general.setItems([[UTType.utf8PlainText.identifier: DiagnosticPrivacy.report(report.components(separatedBy: .newlines))]],
            options: [.localOnly: true, .expirationDate: Date().addingTimeInterval(clipboardLifetime)])
    }

    private static let privateEndpointHosts: [String] = {
        let config = RemoteServiceConfiguration.live
        return [config.primaryBaseURL, config.fallbackBaseURL, config.translationBaseURL, config.ipRegionURL, config.referralRewardsBaseURL]
            .compactMap { $0?.host }.filter { !RSISecurityPolicy.credentialHosts.contains($0.lowercased()) }
    }()

    private static func replacing(_ pattern: String, in value: String, with replacement: String) -> String {
        value.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression)
    }
}
