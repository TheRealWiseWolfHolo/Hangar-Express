import Foundation
import Security

/// Support diagnostics only. Never retain a request, its headers/body, certificate
/// contents, remote IP address or the complete NSError.userInfo dictionary.
nonisolated enum RSINetworkDiagnostics {
    static func safeURL(_ url: URL?) -> String {
        guard let url, url.absoluteString.utf8.count <= 2_048,
              var parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              ["https", "http"].contains(parts.scheme?.lowercased() ?? "") else { return "unavailable" }
        parts.user = nil; parts.password = nil; parts.fragment = nil
        let allowedPaths: Set<String> = ["", "/", "/en/account/pledges", "/account/pledges",
            "/en/account/buy-back-pledges", "/account/buy-back-pledges", "/en/account/login", "/en/login", "/login"]
        if !allowedPaths.contains(parts.path) { parts.path = "/[redacted-path]" }
        let safeQuery = Array((parts.queryItems ?? []).filter {
            guard ["page", "pagesize"].contains($0.name.lowercased()), let value = $0.value,
                  !value.isEmpty, value.count <= 6 else { return false }
            return value.utf8.allSatisfy { (48...57).contains($0) }
        }.prefix(2))
        parts.queryItems = safeQuery.isEmpty ? nil : safeQuery
        return String((parts.string ?? "unavailable").prefix(600))
    }

    static func text(_ value: String, secrets: [String] = [], limit: Int = 500) -> String {
        // Omit an oversized message wholesale rather than slicing through a
        // credential or running regular expressions over an unbounded string.
        guard value.utf8.count <= 2_048 else { return "[message omitted: exceeds diagnostic length limit]" }
        var value = value
        for secret in secrets.filter({ !$0.isEmpty }).sorted(by: { $0.count > $1.count }) {
            value = value.replacingOccurrences(of: secret, with: "[redacted]")
        }
        if let regex = try? NSRegularExpression(pattern: #"https?://[^\s<>\"']+"#, options: .caseInsensitive) {
            for match in regex.matches(in: value, range: NSRange(value.startIndex..., in: value)).reversed() {
                guard let range = Range(match.range, in: value) else { continue }
                value.replaceSubrange(range, with: safeURL(URL(string: String(value[range]))))
            }
        }
        // Header-like lines and labeled credentials can occur inside system error text.
        value = value.replacingOccurrences(of: #"(?im)\b(?:authorization|cookie|set-cookie|x-rsi-token|x-rsi-device)\s*[:=][^\r\n]*"#,
            with: "[redacted credential field]", options: .regularExpression)
        value = value.replacingOccurrences(of: #"(?i)\bBearer\s+[^\s,;]+"#, with: "Bearer [redacted]", options: .regularExpression)
        value = value.replacingOccurrences(of: #"(?i)\b(?:password|rsi-token|_rsi_device|token|access_token|refresh_token|code)\s*[:=]\s*(?:\"[^\"]*\"|'[^']*'|[^\s,;]+)"#,
            with: "[redacted credential field]", options: .regularExpression)
        if value.contains("@") {
            value = value.replacingOccurrences(of: #"(?i)[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}"#, with: "[redacted email]", options: .regularExpression)
        }
        value = value.components(separatedBy: .newlines).joined(separator: " ")
        return String(value.prefix(limit))
    }

    static func errorLines(_ error: Error, secrets: [String] = []) -> [String] {
        var queue: [(NSError, Int)] = [(error as NSError, 0)]
        var seen: Set<ObjectIdentifier> = []
        var lines: [String] = [], index = 0
        var truncated = false
        let numericKeys = ["_kCFStreamErrorDomainKey", "_kCFStreamErrorCodeKey",
            "_kCFNetworkCFStreamSSLErrorOriginalValue", "_kCFStreamPropertySSLClientCertificateState"]
        while !queue.isEmpty, index < 8 {
            let (error, depth) = queue.removeFirst()
            guard seen.insert(ObjectIdentifier(error)).inserted else { continue }
            let prefix = "error[\(index)]"
            lines += ["\(prefix).depth=\(depth)", "\(prefix).domain=\(text(error.domain, secrets: secrets, limit: 100))",
                      "\(prefix).code=\(error.code)", "\(prefix).description=\(text(error.localizedDescription, secrets: secrets))"]
            for key in [NSLocalizedFailureReasonErrorKey, NSLocalizedRecoverySuggestionErrorKey] {
                if let message = error.userInfo[key] as? String { lines.append("\(prefix).\(key)=\(text(message, secrets: secrets))") }
            }
            if let url = error.userInfo[NSURLErrorFailingURLErrorKey] as? URL {
                lines.append("\(prefix).failingURL=\(text(safeURL(url), secrets: secrets))")
            } else if let raw = error.userInfo[NSURLErrorFailingURLStringErrorKey] as? String {
                lines.append("\(prefix).failingURL=\(text(safeURL(URL(string: raw)), secrets: secrets))")
            }
            for key in numericKeys {
                if let number = error.userInfo[key] as? NSNumber { lines.append("\(prefix).\(key)=\(number)") }
            }
            if error.domain == NSOSStatusErrorDomain, let code = Int32(exactly: error.code),
               let message = SecCopyErrorMessageString(code, nil) {
                lines.append("\(prefix).osStatusMessage=\(text(message as String, secrets: secrets))")
            }
            if depth < 5 {
                if let nested = error.userInfo[NSUnderlyingErrorKey] as? NSError { queue.append((nested, depth + 1)) }
                if let nested = error.userInfo["NSMultipleUnderlyingErrorsKey"] as? [NSError] {
                    queue.append(contentsOf: nested.prefix(8).map { ($0, depth + 1) })
                    truncated = truncated || nested.count > 8
                }
            } else if error.userInfo[NSUnderlyingErrorKey] != nil || error.userInfo["NSMultipleUnderlyingErrorsKey"] != nil {
                truncated = true
            }
            index += 1
        }
        if truncated || !queue.isEmpty { lines.append("errorChainTruncated=true") }
        return lines
    }

    static func category(_ error: Error) -> String {
        let error = error as NSError
        guard error.domain == NSURLErrorDomain else { return "other" }
        switch error.code {
        case -1206 ... -1200: return "TLS"
        case -1022: return "transportSecurityPolicy"
        case -1001: return "timeout"
        case -1003, -1006: return "DNS"
        case -1004, -1005, -1009: return "connectivity"
        case -999: return "cancelled"
        default: return "other"
        }
    }

    static func milliseconds(_ start: Date?, _ end: Date?) -> String {
        guard let start, let end, end >= start else { return "unavailable" }
        return String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), end.timeIntervalSince(start) * 1_000)
    }
}

nonisolated struct RSINetworkTransaction: Sendable {
    let endpoint: String
    let status: Int?
    let protocolName: String?
    let tlsVersion: String?
    let cipher: String?
    let proxy: Bool
    let reused: Bool
    let cellular: Bool
    let expensive: Bool
    let constrained: Bool
    let dns: String
    let connect: String
    let tls: String
    let request: String
    let firstByte: String
    let response: String
    let requestHeaderBytes: Int64
    let responseHeaderBytes: Int64
    let responseBodyBytes: Int64
    let tlsStarted: Bool
    let tlsCompleted: Bool
    let requestStarted: Bool
    let responseStarted: Bool

    init(_ metric: URLSessionTaskTransactionMetrics) {
        endpoint = RSINetworkDiagnostics.safeURL(metric.request.url)
        status = (metric.response as? HTTPURLResponse)?.statusCode
        protocolName = metric.networkProtocolName
        tlsVersion = metric.negotiatedTLSProtocolVersion.map { String(format: "0x%04X", $0.rawValue) }
        cipher = metric.negotiatedTLSCipherSuite.map { String(format: "0x%04X", $0.rawValue) }
        proxy = metric.isProxyConnection; reused = metric.isReusedConnection
        cellular = metric.isCellular; expensive = metric.isExpensive; constrained = metric.isConstrained
        dns = RSINetworkDiagnostics.milliseconds(metric.domainLookupStartDate, metric.domainLookupEndDate)
        connect = RSINetworkDiagnostics.milliseconds(metric.connectStartDate, metric.connectEndDate)
        tls = RSINetworkDiagnostics.milliseconds(metric.secureConnectionStartDate, metric.secureConnectionEndDate)
        request = RSINetworkDiagnostics.milliseconds(metric.requestStartDate, metric.requestEndDate)
        firstByte = RSINetworkDiagnostics.milliseconds(metric.requestEndDate, metric.responseStartDate)
        response = RSINetworkDiagnostics.milliseconds(metric.responseStartDate, metric.responseEndDate)
        requestHeaderBytes = metric.countOfRequestHeaderBytesSent
        responseHeaderBytes = metric.countOfResponseHeaderBytesReceived
        responseBodyBytes = metric.countOfResponseBodyBytesReceived
        tlsStarted = metric.secureConnectionStartDate != nil; tlsCompleted = metric.secureConnectionEndDate != nil
        requestStarted = metric.requestStartDate != nil; responseStarted = metric.responseStartDate != nil
    }

    func lines(index: Int) -> [String] {
        let prefix = "transaction[\(index)]"
        return ["\(prefix).endpoint=\(endpoint)", "\(prefix).status=\(status.map(String.init) ?? "unavailable")",
            "\(prefix).protocol=\(RSINetworkDiagnostics.text(protocolName ?? "unavailable", limit: 40))",
            "\(prefix).tlsVersion=\(tlsVersion ?? "unavailable")", "\(prefix).cipher=\(cipher ?? "unavailable")",
            "\(prefix).proxy=\(proxy), reused=\(reused), cellular=\(cellular), expensive=\(expensive), constrained=\(constrained)",
            "\(prefix).dnsMs=\(dns), connectMs=\(connect), tlsMs=\(tls), requestMs=\(request), firstByteMs=\(firstByte), responseMs=\(response)",
            "\(prefix).requestHeaderBytes=\(requestHeaderBytes), responseHeaderBytes=\(responseHeaderBytes), responseBodyBytes=\(responseBodyBytes)",
            "\(prefix).tlsStarted=\(tlsStarted), tlsCompleted=\(tlsCompleted), requestStarted=\(requestStarted), responseStarted=\(responseStarted)"]
    }
}

/// One short-lived collector per request, including shipping Release builds.
/// Authentication challenges and redirects retain Foundation's default handling.
nonisolated final class RSIRequestMetricsDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var transactions: [RSINetworkTransaction] = []
    private var transactionCount: Int?
    private var redirects: Int?
    private var taskDuration: TimeInterval?
    private var waitedForConnectivity = false
    private let profilingDelegate: (any URLSessionTaskDelegate)?

    init(profilingDelegate: (any URLSessionTaskDelegate)? = nil) { self.profilingDelegate = profilingDelegate }

    func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        let values = metrics.transactionMetrics.suffix(6).map(RSINetworkTransaction.init)
        lock.withLock {
            transactions = values; transactionCount = metrics.transactionMetrics.count
            redirects = metrics.redirectCount; taskDuration = metrics.taskInterval.duration
        }
        profilingDelegate?.urlSession?(session, task: task, didFinishCollecting: metrics)
    }
    func urlSession(_ session: URLSession, taskIsWaitingForConnectivity task: URLSessionTask) {
        lock.withLock { waitedForConnectivity = true }
    }
    func lines() -> [String] {
        lock.withLock {
            var result = ["metricsStatus=\(transactionCount == nil ? "unavailable" : "collected")",
                "transactionCount=\(transactionCount.map(String.init) ?? "unavailable")",
                "redirectCount=\(redirects.map(String.init) ?? "unavailable")",
                "taskDurationMs=\(taskDuration.map { String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), $0 * 1_000) } ?? "unavailable")",
                "waitedForConnectivity=\(waitedForConnectivity)",
                "metricsNote=missing phases may mean failure, connection reuse, caching or unavailable system metrics; zero byte counts may be unavailable"]
            let offset = (transactionCount ?? 0) - transactions.count
            for (index, transaction) in transactions.enumerated() { result += transaction.lines(index: offset + index) }
            return result
        }
    }
}

typealias RSIHTTPDiagnosticsHandler = @MainActor @Sendable (_ detail: String, _ failed: Bool) -> Void
