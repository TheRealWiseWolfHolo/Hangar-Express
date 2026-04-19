import Foundation

actor RSIAuthService: AuthenticationServicing {
    private enum FailureContext {
        case signIn
        case twoFactor
    }

    private static let signInMutation = """
    mutation signin(
      $captcha_code: String
      $captchaToken: String
      $email: String!
      $mark: String
      $password: String!
      $remember: Boolean
    ) {
      account_signin(
        captcha_code: $captcha_code
        captcha_token: $captchaToken
        email: $email
        mark: $mark
        password: $password
        remember: $remember
      ) {
        avatar
        displayname
        email
        hasGamePackage
        referrerReferralCode
        status
        tmid
        username
        syncToken
      }
    }
    """

    private static let twoFactorMutation = """
    mutation multistep($code: String!, $deviceType: String!, $deviceName: String!, $duration: String!) {
      account_multistep(code: $code, device_type: $deviceType, device_name: $deviceName, duration: $duration) {
        avatar
        displayname
        email
        hasGamePackage
        referrerReferralCode
        status
        tmid
        username
        syncToken
      }
    }
    """

    private let webSession: any AuthenticationWebSessionProviding
    private var pendingCredentials: AccountCredentials?

    init(recaptchaBroker: any AuthenticationWebSessionProviding) {
        webSession = recaptchaBroker
    }

    func signIn(loginIdentifier: String, password: String, rememberMe: Bool) async throws -> SignInOutcome {
        let trimmedLoginIdentifier = loginIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedLoginIdentifier.isEmpty, !password.isEmpty else {
            throw AuthenticationError.invalidInput("Enter your RSI email or Login ID and password.")
        }

        pendingCredentials = nil
        try await webSession.resetAuthenticationSession()

        let signInResponse = try await webSession.signIn(
            loginIdentifier: trimmedLoginIdentifier,
            password: password,
            rememberMe: rememberMe,
            query: Self.signInMutation
        )
        let response = try decodeGraphQL(signInResponse, context: "signin")

        let errors = response.errors ?? []

        if errors.contains(where: { $0.message == "MultiStepRequired" }) {
            pendingCredentials = AccountCredentials(loginIdentifier: trimmedLoginIdentifier, password: password)
            return .requiresTwoFactor
        }

        if let account = response.authenticatedAccount(for: "account_signin") {
            let session = makeSession(
                from: account,
                credentials: AccountCredentials(loginIdentifier: trimmedLoginIdentifier, password: password),
                cookies: try await webSession.currentRSICookies()
            )
            pendingCredentials = nil
            return .authenticated(session)
        }

        if errors.isEmpty {
            throw makeDecodeError(
                response: signInResponse,
                context: "signin",
                reason: "RSI returned a sign-in response the app could not understand yet."
            )
        }

        throw AuthenticationError.signInFailed(
            presentableMessage(
                for: errors,
                context: .signIn,
                fallback: "RSI rejected the sign-in attempt. Check the account email or Login ID and password, then try again."
            )
        )
    }

    func submitTwoFactor(code: String, deviceName: String, trustDuration: TrustedDeviceDuration) async throws -> UserSession {
        let trimmedCode = code.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedDeviceName = deviceName.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedCode.isEmpty else {
            throw AuthenticationError.invalidInput("Enter the verification code from RSI.")
        }

        guard !trimmedDeviceName.isEmpty else {
            throw AuthenticationError.invalidInput("Give this device a name before saving the trusted-device setting.")
        }

        guard let pendingCredentials else {
            throw AuthenticationError.pendingVerificationExpired
        }

        let twoFactorResponse = try await webSession.submitTwoFactor(
            code: trimmedCode,
            deviceName: trimmedDeviceName,
            trustDuration: trustDuration,
            query: Self.twoFactorMutation
        )
        let response = try decodeGraphQL(twoFactorResponse, context: "multistep")

        if let account = response.authenticatedAccount(for: "account_multistep") {
            let session = makeSession(
                from: account,
                credentials: pendingCredentials,
                cookies: try await webSession.currentRSICookies()
            )
            self.pendingCredentials = nil
            return session
        }

        let errors = response.errors ?? []

        if errors.contains(where: \.hasExpiredCSRFContext) {
            self.pendingCredentials = nil
            try? await webSession.resetAuthenticationSession()
            throw AuthenticationError.pendingVerificationExpired
        }

        if errors.isEmpty {
            throw makeDecodeError(
                response: twoFactorResponse,
                context: "multistep",
                reason: "RSI returned a verification response the app could not understand yet."
            )
        }

        throw AuthenticationError.signInFailed(
            presentableMessage(
                for: errors,
                context: .twoFactor,
                fallback: "The verification code could not be accepted. Try again."
            )
        )
    }

    func cancelPendingAuthentication() async {
        pendingCredentials = nil
        try? await webSession.resetAuthenticationSession()
    }

    private func decodeGraphQL(_ response: BrowserGraphQLResponse, context: String) throws -> GraphQLResponse {
        guard (200 ..< 300).contains(response.statusCode) else {
            throw makeDecodeError(
                response: response,
                context: context,
                reason: "RSI returned an unexpected network response."
            )
        }

        guard let data = response.body.data(using: .utf8) else {
            throw makeDecodeError(
                response: response,
                context: context,
                reason: "RSI returned a response the app could not decode yet."
            )
        }

        do {
            return try JSONDecoder().decode(GraphQLResponse.self, from: data)
        } catch {
            throw makeDecodeError(
                response: response,
                context: context,
                reason: "RSI returned a response the app could not decode yet.",
                underlyingError: error
            )
        }
    }

    private func makeSession(from account: AuthenticatedAccount, credentials: AccountCredentials, cookies: [SessionCookie]) -> UserSession {
        let displayName = account.displayname ?? account.username ?? credentials.loginIdentifier
        let handle = account.username ?? displayName

        return UserSession(
            handle: handle,
            displayName: displayName,
            email: account.email ?? credentials.loginIdentifier,
            authMode: .rsiNativeLogin,
            notes: "Credentials and RSI cookies were stored in Keychain for future account actions.",
            avatarURL: normalizedRSIURL(from: account.avatar),
            credentials: credentials,
            cookies: cookies,
            createdAt: .now
        )
    }

    private func normalizedRSIURL(from rawValue: String?) -> URL? {
        guard let trimmedValue = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmedValue.isEmpty else {
            return nil
        }

        if trimmedValue.hasPrefix("//") {
            return URL(string: "https:\(trimmedValue)")
        }

        if trimmedValue.hasPrefix("/") {
            return URL(string: "https://robertsspaceindustries.com\(trimmedValue)")
        }

        return URL(string: trimmedValue)
    }

    private func presentableMessage(for errors: [GraphQLError], context: FailureContext, fallback: String) -> String {
        if let friendlyMessage = friendlyMessage(for: errors, context: context) {
            return friendlyMessage
        }

        if let rawMessage = rawMessage(for: errors) {
            return rawMessage
        }

        return fallback
    }

    private func friendlyMessage(for errors: [GraphQLError], context: FailureContext) -> String? {
        let normalized = errors
            .filter { $0.category != "obfuscated" }
            .map(\.normalizedSearchText)
            .filter { !$0.isEmpty }
            .joined(separator: " ")

        guard !normalized.isEmpty else {
            return nil
        }

        if normalized.contains("1034")
            || normalized.contains("maximum number of failed login attempts exceeded")
            || normalized.contains("too many failed login attempts")
            || normalized.contains("failed login attempts exceeded") {
            return "Too many login attempts. RSI temporarily locked this account. Wait about an hour before trying again."
        }

        if normalized.contains("invalidpasswordexception")
            || normalized.contains("incorrect username/password")
            || normalized.contains("wrong credentials")
            || normalized.contains("wrong password")
            || normalized.contains("invalid password") {
            return "Incorrect RSI email/Login ID or password. Check your credentials and try again."
        }

        if normalized.contains("invalid or already used")
            || normalized.contains("invalid code")
            || normalized.contains("incorrect code")
            || normalized.contains("already used")
            || normalized.contains("expired code") {
            switch context {
            case .signIn:
                return "The verification step was not accepted. Try signing in again."
            case .twoFactor:
                return "That verification code was not accepted. Use the newest RSI code and try again."
            }
        }

        if normalized.contains("captcha") || normalized.contains("recaptcha") {
            return "RSI requested an additional CAPTCHA challenge. Try signing in again in a fresh session."
        }

        if normalized.contains("csrf") {
            return "The verification session expired. Start the sign-in flow again."
        }

        return nil
    }

    private func rawMessage(for errors: [GraphQLError]) -> String? {
        let renderedErrors = errors
            .filter { $0.category != "obfuscated" }
            .map(\.renderedDescription)
            .filter { !$0.isEmpty }

        guard !renderedErrors.isEmpty else {
            return nil
        }

        return renderedErrors.joined(separator: "\n\n")
    }

    private func makeDecodeError(
        response: BrowserGraphQLResponse,
        context: String,
        reason: String,
        underlyingError: Error? = nil
    ) -> Error {
        var userInfo: [String: Any] = [
            NSLocalizedDescriptionKey: reason,
            "RSIAuthContext": context,
            "RSIHTTPStatusCode": response.statusCode,
            "RSIResponseBody": response.body
        ]

        if let underlyingError {
            userInfo[NSUnderlyingErrorKey] = underlyingError
        }

        return NSError(domain: "RSIAuthService", code: response.statusCode, userInfo: userInfo)
    }
}

private nonisolated struct GraphQLResponse: Decodable {
    let data: GraphQLJSONValue?
    let errors: [GraphQLError]?

    func authenticatedAccount(for key: String) -> AuthenticatedAccount? {
        guard case let .object(values)? = data,
              let value = values[key],
              !value.isNull else {
            return nil
        }

        guard case let .object(account) = value else {
            return nil
        }

        return AuthenticatedAccount(
            avatar: account["avatar"]?.stringValue,
            displayname: account["displayname"]?.stringValue,
            email: account["email"]?.stringValue,
            username: account["username"]?.stringValue
        )
    }
}

private nonisolated struct GraphQLError: Decodable {
    let message: String
    let code: GraphQLJSONValue?
    private let rawCategory: String?
    let extensions: GraphQLErrorExtensions?

    enum CodingKeys: String, CodingKey {
        case message
        case code
        case rawCategory = "category"
        case extensions
    }

    var category: String? {
        rawCategory ?? extensions?.category
    }

    var detailMessage: String? {
        extensions?.details?.firstNonEmptyString
    }

    var normalizedSearchText: String {
        let segments = [message, code?.firstNonEmptyString, category] + detailStrings.map(Optional.some)

        return segments
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .lowercased()
    }

    var renderedDescription: String {
        var segments: [String] = []

        if !message.isEmpty, message != "ErrValidationFailed" {
            segments.append(message)
        }

        if let codeValue = code?.firstNonEmptyString,
           !codeValue.isEmpty,
           codeValue.caseInsensitiveCompare(message) != .orderedSame {
            segments.append("code: \(codeValue)")
        }

        if let category, !category.isEmpty {
            segments.append("category: \(category)")
        }

        if let details = extensions?.details?.renderedSingleLine, !details.isEmpty {
            segments.append("details: \(details)")
        }

        return segments.joined(separator: " | ")
    }

    var hasExpiredCSRFContext: Bool {
        guard case let .object(values)? = extensions?.details,
              let csrfTokenState = values["csrfToken"]?.stringValue else {
            return false
        }

        return csrfTokenState == "Invalid" || csrfTokenState == "Required"
    }

    private var detailStrings: [String] {
        extensions?.details?.allNonEmptyStrings ?? []
    }
}

private nonisolated struct GraphQLErrorExtensions: Decodable {
    let category: String?
    let details: GraphQLJSONValue?
}

private nonisolated struct AuthenticatedAccount: Sendable {
    let avatar: String?
    let displayname: String?
    let email: String?
    let username: String?
}

private nonisolated enum GraphQLJSONValue: Codable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case object([String: GraphQLJSONValue])
    case array([GraphQLJSONValue])
    case null

    var isNull: Bool {
        if case .null = self {
            return true
        }

        return false
    }

    var stringValue: String? {
        switch self {
        case let .string(value):
            return value
        case let .int(value):
            return String(value)
        case let .double(value):
            return String(value)
        case let .bool(value):
            return String(value)
        case .object, .array, .null:
            return nil
        }
    }

    var firstNonEmptyString: String? {
        switch self {
        case let .string(value):
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        case .int, .double, .bool:
            return stringValue
        case let .object(values):
            for key in values.keys.sorted() {
                if let nested = values[key]?.firstNonEmptyString {
                    return nested
                }
            }
            return nil
        case let .array(values):
            for value in values {
                if let nested = value.firstNonEmptyString {
                    return nested
                }
            }
            return nil
        case .null:
            return nil
        }
    }

    var allNonEmptyStrings: [String] {
        switch self {
        case .string, .int, .double, .bool:
            return firstNonEmptyString.map { [$0] } ?? []
        case let .object(values):
            return values.keys.sorted().flatMap { key in
                values[key]?.allNonEmptyStrings ?? []
            }
        case let .array(values):
            return values.flatMap(\.allNonEmptyStrings)
        case .null:
            return []
        }
    }

    var renderedSingleLine: String {
        switch self {
        case .string, .int, .double, .bool:
            return firstNonEmptyString ?? ""
        case let .object(values):
            return values.keys.sorted().compactMap { key in
                guard let value = values[key] else {
                    return nil
                }

                let renderedValue = value.renderedSingleLine
                guard !renderedValue.isEmpty else {
                    return nil
                }

                return "\(key)=\(renderedValue)"
            }.joined(separator: ", ")
        case let .array(values):
            return values
                .map(\.renderedSingleLine)
                .filter { !$0.isEmpty }
                .joined(separator: ", ")
        case .null:
            return ""
        }
    }

    func decode<Value: Decodable>(as type: Value.Type) throws -> Value {
        let data = try JSONEncoder().encode(self)
        return try JSONDecoder().decode(type, from: data)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int.self) {
            self = .int(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([String: GraphQLJSONValue].self) {
            self = .object(value)
        } else if let value = try? container.decode([GraphQLJSONValue].self) {
            self = .array(value)
        } else {
            throw DecodingError.typeMismatch(
                GraphQLJSONValue.self,
                .init(codingPath: decoder.codingPath, debugDescription: "Unsupported JSON value.")
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()

        switch self {
        case let .string(value):
            try container.encode(value)
        case let .int(value):
            try container.encode(value)
        case let .double(value):
            try container.encode(value)
        case let .bool(value):
            try container.encode(value)
        case let .object(value):
            try container.encode(value)
        case let .array(value):
            try container.encode(value)
        case .null:
            try container.encodeNil()
        }
    }
}
