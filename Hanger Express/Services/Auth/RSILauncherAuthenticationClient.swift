import Foundation

nonisolated struct RSILauncherSignInResponse: Decodable, Sendable {
    struct SessionData: Decodable, Sendable {
        let sessionID: String
        let deviceID: String?

        private enum CodingKeys: String, CodingKey {
            case sessionID = "session_id"
            case deviceID = "device_id"
        }
    }

    let success: Int
    let code: String
    let message: String
    let data: SessionData?

    var succeeded: Bool { success == 1 }

    private enum CodingKeys: String, CodingKey {
        case success
        case code
        case message = "msg"
        case data
    }
}

actor RSILauncherAuthenticationClient {
    private static let baseURL = URL(string: "https://robertsspaceindustries.com/")!

    private let cookieStorage: HTTPCookieStorage
    private let session: URLSession
    private var responseSessionID: String?
    private var responseDeviceID: String?

    init() {
        let cookieStorage = HTTPCookieStorage()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = cookieStorage
        configuration.httpShouldSetCookies = true
        configuration.httpCookieAcceptPolicy = .always
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60
        self.cookieStorage = cookieStorage
        session = URLSession(configuration: configuration)
    }

    func reset() {
        responseSessionID = nil
        responseDeviceID = nil
        cookieStorage.cookies?.forEach(cookieStorage.deleteCookie)
    }

    func signIn(
        loginIdentifier: String,
        password: String,
        rememberMe: Bool,
        captcha: String? = nil
    ) async throws -> RSILauncherSignInResponse {
        var body: [String: Any] = [
            "username": loginIdentifier,
            "password": password,
            "remember": rememberMe
        ]
        if let captcha, !captcha.isEmpty {
            body["captcha"] = captcha
        }

        return try await postJSON(path: "api/launcher/v3/signin", body: body)
    }

    func submitTwoFactor(
        code: String,
        deviceName: String,
        trustDuration: TrustedDeviceDuration
    ) async throws -> RSILauncherSignInResponse {
        try await postJSON(
            path: "api/launcher/v3/signin/multiStep",
            body: [
                "code": code,
                "device_name": deviceName,
                "device_type": "computer",
                "duration": trustDuration.rawValue
            ]
        )
    }

    func captchaImage() async throws -> Data {
        var request = try makeRequest(path: "api/launcher/v3/signin/captcha")
        request.httpBody = Data("{}".utf8)
        let (data, response) = try await session.data(for: request)
        try validate(response: response, data: data)
        guard !data.isEmpty else {
            throw AuthenticationError.unavailable("RSI returned an empty CAPTCHA image. Try again.")
        }
        return data
    }

    func currentCookies() -> [SessionCookie] {
        var cookiesByName: [String: SessionCookie] = [:]
        for cookie in cookieStorage.cookies ?? [] where cookie.domain.localizedCaseInsensitiveContains("robertsspaceindustries.com") {
            cookiesByName[cookie.name.lowercased()] = SessionCookie(cookie)
        }

        if let responseSessionID, !responseSessionID.isEmpty {
            cookiesByName["rsi-token"] = launcherCookie(name: "Rsi-Token", value: responseSessionID)
        }
        if let responseDeviceID, !responseDeviceID.isEmpty {
            cookiesByName["_rsi_device"] = launcherCookie(name: "_rsi_device", value: responseDeviceID)
        }

        return cookiesByName.values.sorted { $0.name < $1.name }
    }

    private func postJSON(path: String, body: [String: Any]) async throws -> RSILauncherSignInResponse {
        var request = try makeRequest(path: path)
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await session.data(for: request)
        try validate(response: response, data: data)

        do {
            let result = try JSONDecoder().decode(RSILauncherSignInResponse.self, from: data)
            if let sessionData = result.data {
                if !sessionData.sessionID.isEmpty {
                    responseSessionID = sessionData.sessionID
                }
                if let deviceID = sessionData.deviceID, !deviceID.isEmpty {
                    responseDeviceID = deviceID
                }
            }
            return result
        } catch {
            throw NSError(
                domain: "RSILauncherAuthenticationClient",
                code: 1,
                userInfo: [
                    NSLocalizedDescriptionKey: "RSI returned a launcher sign-in response Hangar Express could not decode.",
                    "RSIResponseBody": String(data: data, encoding: .utf8) ?? "",
                    NSUnderlyingErrorKey: error
                ]
            )
        }
    }

    private func makeRequest(path: String) throws -> URLRequest {
        guard let url = URL(string: path, relativeTo: Self.baseURL) else {
            throw AuthenticationError.unavailable("Hangar Express could not create the RSI launcher request.")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Hangar Express/1.0", forHTTPHeaderField: "User-Agent")
        request.setValue(Self.baseURL.absoluteString, forHTTPHeaderField: "Referer")
        request.setValue(Locale.preferredLanguages.first ?? "en-US", forHTTPHeaderField: "Accept-Language")
        if let responseSessionID, !responseSessionID.isEmpty {
            request.setValue(responseSessionID, forHTTPHeaderField: "x-rsi-token")
        }
        if let responseDeviceID, !responseDeviceID.isEmpty {
            request.setValue(responseDeviceID, forHTTPHeaderField: "x-rsi-device")
        }
        return request
    }

    private func validate(response: URLResponse, data: Data) throws {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AuthenticationError.unavailable("RSI launcher sign-in did not return a valid network response.")
        }
        guard (200 ..< 300).contains(httpResponse.statusCode) else {
            throw NSError(
                domain: "RSILauncherAuthenticationClient",
                code: httpResponse.statusCode,
                userInfo: [
                    NSLocalizedDescriptionKey: "RSI launcher sign-in returned HTTP \(httpResponse.statusCode).",
                    "RSIResponseBody": String(data: data, encoding: .utf8) ?? ""
                ]
            )
        }
    }

    private func launcherCookie(name: String, value: String) -> SessionCookie {
        SessionCookie(
            name: name,
            value: value,
            domain: ".robertsspaceindustries.com",
            path: "/",
            expiresAt: nil,
            isSecure: true,
            isHTTPOnly: true,
            version: 0
        )
    }
}
