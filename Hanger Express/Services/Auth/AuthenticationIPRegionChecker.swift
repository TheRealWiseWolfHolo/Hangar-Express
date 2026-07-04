import Foundation

struct AuthenticationIPRegionCheckResult: Equatable, Sendable {
    let countryCode: String?
    let errorDescription: String?

    var isMainlandChina: Bool {
        countryCode?.uppercased() == "CN"
    }
}

protocol AuthenticationIPRegionChecking: Sendable {
    func currentRegion() async -> AuthenticationIPRegionCheckResult
}

struct CloudflareAuthenticationIPRegionChecker: AuthenticationIPRegionChecking {
    private let traceURL: URL
    private let urlSession: URLSession

    init(
        traceURL: URL = URL(string: "https://www.cloudflare.com/cdn-cgi/trace")!,
        urlSession: URLSession = .shared
    ) {
        self.traceURL = traceURL
        self.urlSession = urlSession
    }

    func currentRegion() async -> AuthenticationIPRegionCheckResult {
        var request = URLRequest(url: traceURL)
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.timeoutInterval = 1.5

        do {
            let (data, response) = try await urlSession.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse,
                  (200 ..< 300).contains(httpResponse.statusCode) else {
                return AuthenticationIPRegionCheckResult(
                    countryCode: nil,
                    errorDescription: "IP region check returned an unexpected response."
                )
            }

            let trace = String(decoding: data, as: UTF8.self)
            return AuthenticationIPRegionCheckResult(
                countryCode: Self.countryCode(fromCloudflareTrace: trace),
                errorDescription: nil
            )
        } catch {
            return AuthenticationIPRegionCheckResult(
                countryCode: nil,
                errorDescription: error.localizedDescription
            )
        }
    }

    static func countryCode(fromCloudflareTrace trace: String) -> String? {
        for line in trace.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2, parts[0] == "loc" else {
                continue
            }

            let code = parts[1].trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            return code.isEmpty ? nil : code
        }

        return nil
    }
}

struct PreviewAuthenticationIPRegionChecker: AuthenticationIPRegionChecking {
    func currentRegion() async -> AuthenticationIPRegionCheckResult {
        AuthenticationIPRegionCheckResult(countryCode: nil, errorDescription: nil)
    }
}
