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

struct RemoteAuthenticationIPRegionChecker: AuthenticationIPRegionChecking {
    private struct RegionPayload: Decodable {
        let countryCode: String?
    }

    private let endpointURL: URL?
    private let urlSession: URLSession

    init(
        endpointURL: URL? = RemoteServiceConfiguration.live.ipRegionURL,
        urlSession: URLSession = .shared
    ) {
        self.endpointURL = endpointURL
        self.urlSession = urlSession
    }

    func currentRegion() async -> AuthenticationIPRegionCheckResult {
        guard let endpointURL else {
            return AuthenticationIPRegionCheckResult(
                countryCode: nil,
                errorDescription: "IP region check is not configured."
            )
        }

        var request = URLRequest(url: endpointURL)
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

            return AuthenticationIPRegionCheckResult(
                countryCode: Self.countryCode(fromResponse: data),
                errorDescription: nil
            )
        } catch {
            return AuthenticationIPRegionCheckResult(
                countryCode: nil,
                errorDescription: error.localizedDescription
            )
        }
    }

    static func countryCode(fromResponse data: Data) -> String? {
        if let payload = try? JSONDecoder().decode(RegionPayload.self, from: data),
           let code = normalizedCountryCode(payload.countryCode) {
            return code
        }

        let response = String(decoding: data, as: UTF8.self)
        for line in response.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2, parts[0] == "loc" else {
                continue
            }
            return normalizedCountryCode(String(parts[1]))
        }

        return nil
    }

    private static func normalizedCountryCode(_ value: String?) -> String? {
        let code = value?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
        guard let code, code.count == 2, code.allSatisfy(\.isLetter) else {
            return nil
        }
        return code
    }
}

struct PreviewAuthenticationIPRegionChecker: AuthenticationIPRegionChecking {
    func currentRegion() async -> AuthenticationIPRegionCheckResult {
        AuthenticationIPRegionCheckResult(countryCode: nil, errorDescription: nil)
    }
}
