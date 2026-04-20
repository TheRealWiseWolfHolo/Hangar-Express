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
    private let diagnostics: AuthenticationDiagnosticsStore
    // Pending state for the browserless GraphQL + verification-code flow.
    private var pendingCredentials: AccountCredentials?
    // Pending state for the separate in-app browser login flow.
    private var pendingBrowserCredentials: AccountCredentials?
    private var pendingBrowserExportedCookies: [SessionCookie] = []

    init(
        recaptchaBroker: any AuthenticationWebSessionProviding,
        diagnostics: AuthenticationDiagnosticsStore
    ) {
        webSession = recaptchaBroker
        self.diagnostics = diagnostics
    }

    func signIn(
        loginIdentifier: String,
        password: String,
        rememberMe: Bool,
        forceBrowserLogin: Bool
    ) async throws -> SignInOutcome {
        let trimmedLoginIdentifier = loginIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedLoginIdentifier.isEmpty, !password.isEmpty else {
            await log(
                stage: "auth.sign-in",
                summary: "The sign-in attempt was blocked because credentials were incomplete.",
                level: .warning
            )
            throw AuthenticationError.invalidInput("Enter your RSI email or Login ID and password.")
        }

        let credentials = AccountCredentials(loginIdentifier: trimmedLoginIdentifier, password: password)
        await resetDiagnostics(
            context: "Starting sign-in for \(maskedIdentifier(trimmedLoginIdentifier))."
        )
        await log(
            stage: "auth.sign-in",
            summary: "Starting the RSI sign-in pipeline.",
            detail: "loginIdentifier=\(maskedIdentifier(trimmedLoginIdentifier)), rememberMe=\(rememberMe), forceBrowserLogin=\(forceBrowserLogin)"
        )
        pendingCredentials = nil
        pendingBrowserCredentials = nil
        pendingBrowserExportedCookies = []

        if forceBrowserLogin {
            pendingBrowserCredentials = credentials
            await log(
                stage: "auth.browser-start",
                summary: "Force Browser Login is enabled. Starting the separate in-app browser sign-in flow."
            )
            return .requiresBrowserChallenge(
                "Forced browser login is enabled. Continue in the in-app browser to finish signing in."
            )
        }

        // The browserless path stays on the original GraphQL flow from v0.4 and does not
        // switch into the in-app browser flow automatically.
        do {
            try await webSession.resetAuthenticationSession()
            await log(
                stage: "auth.graphql-sign-in",
                summary: "Submitting the GraphQL sign-in mutation through the RSI verification helper."
            )
            let signInResponse = try await webSession.signIn(
                loginIdentifier: trimmedLoginIdentifier,
                password: password,
                rememberMe: rememberMe,
                query: Self.signInMutation
            )
            let response = try decodeGraphQL(signInResponse, context: "signin")

            let errors = response.errors ?? []

            if errors.contains(where: { $0.message == "MultiStepRequired" }) {
                pendingCredentials = credentials
                await log(
                    stage: "auth.graphql-sign-in",
                    summary: "RSI requested a verification code after the GraphQL sign-in step."
                )
                return .requiresTwoFactor
            }

            if let account = response.authenticatedAccount(for: "account_signin") {
                await log(
                    stage: "auth.graphql-sign-in",
                    summary: "The GraphQL sign-in mutation returned an authenticated account."
                )
                let session = makeSession(
                    from: account,
                    credentials: credentials,
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

            let message = presentableMessage(
                for: errors,
                context: .signIn,
                fallback: "RSI rejected the sign-in attempt. Check the account email or Login ID and password, then try again."
            )
            await log(
                stage: "auth.graphql-sign-in",
                summary: "The GraphQL sign-in mutation returned an auth failure.",
                detail: message,
                level: .warning
            )
            throw AuthenticationError.signInFailed(message)
        } catch {
            if shouldSuggestBrowserLogin(for: error) {
                let message = "RSI requested an interactive browser challenge for this sign-in. Turn on Force Browser Login in Advanced and try again."
                await log(
                    stage: "auth.graphql-sign-in",
                    summary: "The browserless sign-in path hit a captcha or challenge that needs the separate browser flow.",
                    detail: AuthenticationDebugFormatter.debugDescription(for: error),
                    level: .warning
                )
                throw AuthenticationError.signInFailed(message)
            }

            await log(
                stage: "auth.graphql-sign-in",
                summary: "The GraphQL sign-in path failed.",
                detail: AuthenticationDebugFormatter.debugDescription(for: error),
                level: .error
            )
            throw error
        }
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
            await log(
                stage: "auth.two-factor",
                summary: "The verification-code step expired before it could be submitted.",
                level: .warning
            )
            throw AuthenticationError.pendingVerificationExpired
        }

        await log(
            stage: "auth.two-factor",
            summary: "Submitting the RSI verification code through the browserless GraphQL flow.",
            detail: "deviceName=\(trimmedDeviceName), trustDuration=\(trustDuration.rawValue)"
        )

        let twoFactorResponse = try await webSession.submitTwoFactor(
            code: trimmedCode,
            deviceName: trimmedDeviceName,
            trustDuration: trustDuration,
            query: Self.twoFactorMutation
        )
        let response = try decodeGraphQL(twoFactorResponse, context: "multistep")

        if let account = response.authenticatedAccount(for: "account_multistep") {
            await log(
                stage: "auth.two-factor",
                summary: "The GraphQL verification mutation returned an authenticated account."
            )
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
            await log(
                stage: "auth.two-factor",
                summary: "The verification step expired because the RSI CSRF context was no longer valid.",
                level: .warning
            )
            throw AuthenticationError.pendingVerificationExpired
        }

        if errors.isEmpty {
            throw makeDecodeError(
                response: twoFactorResponse,
                context: "multistep",
                reason: "RSI returned a verification response the app could not understand yet."
            )
        }

        let message = presentableMessage(
            for: errors,
            context: .twoFactor,
            fallback: "The verification code could not be accepted. Try again."
        )
        await log(
            stage: "auth.two-factor",
            summary: "The verification code was rejected.",
            detail: message,
            level: .warning
        )
        throw AuthenticationError.signInFailed(message)
    }

    func completeBrowserAuthentication(cookies: [SessionCookie], trustBrowserSession: Bool) async throws -> UserSession {
        guard let pendingBrowserCredentials else {
            await log(
                stage: "auth.browser-complete",
                summary: "The browser-assisted sign-in no longer had a pending browser credential set to finish.",
                level: .warning
            )
            throw AuthenticationError.pendingVerificationExpired
        }

        let exportedCookies = resolvedBrowserCookies(primary: cookies)
        // The browser path only converges with the rest of authentication here, once the
        // browser-exported cookies are validated and converted into a reusable session.
        if cookies.isEmpty, !exportedCookies.isEmpty {
            await log(
                stage: "auth.browser-complete",
                summary: "The browser finish step arrived without cookies, so Hangar Express reused the last cached browser export.",
                detail: browserCookieDebugSummary(for: exportedCookies),
                level: .warning
            )
        }
        await log(
            stage: "auth.browser-complete",
            summary: "Trying to complete sign-in from the exported in-app browser cookies.",
            detail: browserCookieDebugSummary(for: exportedCookies)
        )

        do {
            let session = try await completeAuthentication(
                credentials: pendingBrowserCredentials,
                cookies: exportedCookies
            )
            self.pendingBrowserCredentials = nil
            self.pendingBrowserExportedCookies = []
            await log(
                stage: "auth.browser-complete",
                summary: "The exported in-app browser cookies were accepted as a reusable RSI session."
            )
            return session
        } catch let authError as AuthenticationError {
            if trustBrowserSession {
                await log(
                    stage: "auth.browser-complete",
                    summary: "The exported in-app browser cookies were not accepted yet.",
                    detail: authError.localizedDescription,
                    level: .warning
                )
                throw remapBrowserImportFailure(authError, cookies: exportedCookies)
            }
            throw authError
        } catch {
            let wrappedError = AuthenticationError.unavailable(
                "Hangar Express could not confirm the exported RSI browser session. \(error.localizedDescription)"
            )
            if trustBrowserSession {
                await log(
                    stage: "auth.browser-complete",
                    summary: "An unexpected error occurred while finishing browser-assisted sign-in.",
                    detail: AuthenticationDebugFormatter.debugDescription(for: error),
                    level: .error
                )
                throw remapBrowserImportFailure(wrappedError, cookies: exportedCookies)
            }
            throw wrappedError
        }
    }

    func rememberBrowserExportedCookies(_ cookies: [SessionCookie]) async {
        guard !cookies.isEmpty else {
            await log(
                stage: "auth.browser-cache",
                summary: "The browser handoff reached the auth service without cookies, so Hangar Express kept the previous cached browser export.",
                detail: browserCookieDebugSummary(for: pendingBrowserExportedCookies),
                level: .warning
            )
            return
        }

        pendingBrowserExportedCookies = cloneCookies(cookies)
        await log(
            stage: "auth.browser-cache",
            summary: "Stored the latest cookies exported from the in-app browser for the pending sign-in.",
            detail: browserCookieDebugSummary(for: pendingBrowserExportedCookies)
        )
    }

    func canCompleteBrowserAuthentication(cookies: [SessionCookie]) async -> Bool {
        guard pendingBrowserCredentials != nil else {
            return false
        }

        do {
            _ = try await AccountSessionClient.fetchAuthenticatedAccount(using: resolvedBrowserCookies(primary: cookies))
            return true
        } catch {
            return false
        }
    }

    func cancelPendingAuthentication() async {
        pendingCredentials = nil
        pendingBrowserCredentials = nil
        pendingBrowserExportedCookies = []
        await log(
            stage: "auth.cancel",
            summary: "Cancelled the pending RSI authentication flow."
        )
        try? await webSession.resetAuthenticationSession()
    }

    private func remapBrowserImportFailure(_ error: AuthenticationError, cookies: [SessionCookie]) -> AuthenticationError {
        let debugSummary = browserCookieDebugSummary(for: cookies)

        switch error {
        case let .unavailable(message):
            return .unavailable(
                """
                Stage: imported-cookie-reuse
                Result: the in-app browser exported RSI cookies, but Hangar Express could not verify them as a reusable signed-in session yet.
                Details: \(debugSummary)

                \(message)
                """
            )
        default:
            return .unavailable(
                """
                Stage: imported-cookie-reuse
                Result: the in-app browser exported RSI cookies, but Hangar Express could not verify them as a reusable signed-in session yet.
                Details: \(debugSummary)

                \(error.localizedDescription)
                """
            )
        }
    }

    private func browserCookieDebugSummary(for cookies: [SessionCookie]) -> String {
        let exportedCookieCount = cookies.count
        let cookieNames = cookies.map(\.name).sorted()
        let authCookieNames = cookies
            .map(\.name)
            .filter { name in
                let lowercasedName = name.lowercased()
                return lowercasedName.contains("rsi")
                    || lowercasedName.contains("csrf")
                    || lowercasedName == "_rsi_device"
            }
            .sorted()

        let requiredNames = ["Rsi-Token", "_rsi_device", "Rsi-Account-Auth"]
        let presentNames = Set(cookies.map { $0.name.lowercased() })
        let missingRequiredNames = requiredNames.filter { !presentNames.contains($0.lowercased()) }

        return [
            "exportedCookieCount=\(exportedCookieCount)",
            "cookieNames=\(cookieNames.isEmpty ? "none" : cookieNames.joined(separator: ","))",
            "authCookies=\(authCookieNames.isEmpty ? "none" : authCookieNames.joined(separator: ","))",
            "missingPreferredCookies=\(missingRequiredNames.isEmpty ? "none" : missingRequiredNames.joined(separator: ","))"
        ].joined(separator: ", ")
    }

    private func resolvedBrowserCookies(primary cookies: [SessionCookie]) -> [SessionCookie] {
        let primaryCookies = cloneCookies(cookies)
        guard !primaryCookies.isEmpty else {
            return pendingBrowserExportedCookies
        }

        return primaryCookies
    }

    private func cloneCookies(_ cookies: [SessionCookie]) -> [SessionCookie] {
        cookies.map { cookie in
            SessionCookie(
                name: cookie.name,
                value: cookie.value,
                domain: cookie.domain,
                path: cookie.path,
                expiresAt: cookie.expiresAt,
                isSecure: cookie.isSecure,
                isHTTPOnly: cookie.isHTTPOnly,
                version: cookie.version
            )
        }
    }

    private func completeAuthentication(
        credentials: AccountCredentials,
        cookies: [SessionCookie]
    ) async throws -> UserSession {
        await log(
            stage: "auth.account-lookup",
            summary: "Validating the RSI session by loading the authenticated account profile.",
            detail: browserCookieDebugSummary(for: cookies)
        )
        let account = try await AccountSessionClient.fetchAuthenticatedAccount(using: cookies)
        await log(
            stage: "auth.account-lookup",
            summary: "RSI account validation succeeded.",
            detail: "displayName=\(account.displayname ?? "n/a"), username=\(account.username ?? "n/a"), emailPresent=\(account.email != nil)"
        )
        return makeSession(
            from: account,
            credentials: credentials,
            cookies: cookies
        )
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

    private func shouldSuggestBrowserLogin(for error: Error) -> Bool {
        let nsError = error as NSError
        let searchSpace = [
            nsError.localizedDescription,
            nsError.userInfo["WKJavaScriptExceptionMessage"] as? String,
            nsError.userInfo["RSIResponseBody"] as? String
        ]
            .compactMap { $0?.lowercased() }
            .joined(separator: " ")

        return searchSpace.contains("captcha")
            || searchSpace.contains("recaptcha")
            || searchSpace.contains("grecaptcha")
            || searchSpace.contains("verification helper")
            || searchSpace.contains("csrf token")
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
            return "RSI requested an additional CAPTCHA challenge. Turn on Force Browser Login in Advanced and try again."
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

    private func resetDiagnostics(context: String) async {
        await MainActor.run {
            diagnostics.reset(context: context)
        }
    }

    private func log(
        stage: String,
        summary: String,
        detail: String? = nil,
        level: AuthenticationDiagnosticsStore.Entry.Level = .info
    ) async {
        await MainActor.run {
            diagnostics.record(stage: stage, summary: summary, detail: detail, level: level)
        }
    }

    private func maskedIdentifier(_ value: String) -> String {
        guard let atIndex = value.firstIndex(of: "@") else {
            let prefix = String(value.prefix(2))
            return prefix + String(repeating: "*", count: max(0, value.count - prefix.count))
        }

        let name = String(value[..<atIndex])
        let domain = String(value[atIndex...])
        let visiblePrefix = String(name.prefix(2))
        return visiblePrefix + String(repeating: "*", count: max(0, name.count - visiblePrefix.count)) + domain
    }
}

private enum AccountSessionClient {
    private static let accountQuery = """
    query account {
      account {
        isAnonymous
        ... on RsiAuthenticatedAccount {
          avatar
          displayname
          email
          username
        }
      }
    }
    """

    static func fetchAuthenticatedAccount(using cookies: [SessionCookie]) async throws -> AuthenticatedAccount {
        let debugSummary = cookieDebugSummary(for: cookies)

        if let missingCriticalCookiesMessage = missingCriticalCookiesMessage(for: cookies) {
            throw AuthenticationError.unavailable(
                """
                Stage: reusable-account-check
                Result: the exported browser cookies do not include the core RSI auth fields Hangar Express needs for account verification.
                Details: \(debugSummary), \(missingCriticalCookiesMessage)
                Action: finish signing in in the in-app browser, wait for the signed-in page to settle, then tap Finished Login again.
                """
            )
        }

        let storage = HTTPCookieStorage()
        cookies.compactMap(\.httpCookie).forEach(storage.setCookie)

        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = storage
        configuration.httpShouldSetCookies = true
        configuration.httpCookieAcceptPolicy = .always
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60

        let session = URLSession(configuration: configuration)
        var request = URLRequest(url: URL(string: "https://robertsspaceindustries.com/graphql")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        request.setValue(Locale.preferredLanguages.first ?? "en-US", forHTTPHeaderField: "Accept-Language")

        if let rsiToken = cookieValue(in: cookies, names: ["Rsi-Token", "rsi-token"]) {
            request.setValue(rsiToken, forHTTPHeaderField: "x-rsi-token")
        }

        if let rsiDevice = cookieValue(in: cookies, names: ["_rsi_device"]) {
            request.setValue(rsiDevice, forHTTPHeaderField: "x-rsi-device")
        }

        request.httpBody = try JSONSerialization.data(
            withJSONObject: [
                "query": accountQuery,
                "variables": [:]
            ]
        )

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AuthenticationError.unavailable(
                """
                Stage: reusable-account-check
                Result: RSI account lookup did not return a valid network response.
                Details: \(debugSummary)
                """
            )
        }

        guard (200 ..< 300).contains(httpResponse.statusCode) else {
            throw AuthenticationError.unavailable(
                """
                Stage: reusable-account-check
                Result: RSI account lookup returned a non-success HTTP response.
                Details: \(debugSummary), httpStatus=\(httpResponse.statusCode)
                """
            )
        }

        let graphQLResponse = try JSONDecoder().decode(GraphQLResponse.self, from: data)
        if let account = graphQLResponse.authenticatedAccount(for: "account") {
            return account
        }

        if let renderedErrors = renderedGraphQLErrors(from: graphQLResponse), !renderedErrors.isEmpty {
            throw AuthenticationError.unavailable(
                """
                Stage: reusable-account-check
                Result: RSI received the exported browser cookies, but the account GraphQL query still returned errors.
                Details: \(debugSummary), graphQLErrors=\(renderedErrors)
                """
            )
        }

        if graphQLResponse.accountIsAnonymous(for: "account") == true {
            throw AuthenticationError.unavailable(
                """
                Stage: reusable-account-check
                Result: RSI still treated the exported browser session as anonymous.
                Details: \(debugSummary), accountIsAnonymous=true
                Action: stay in the signed-in browser for a moment longer, make sure the account is fully logged in, then tap Finished Login again.
                """
            )
        }

        let responseBody = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .prefix(400) ?? ""

        throw AuthenticationError.unavailable(
            """
            Stage: reusable-account-check
            Result: RSI accepted the account lookup request, but Hangar Express still could not read an authenticated account profile from the exported browser session.
            Details: \(debugSummary), responsePreview=\(responseBody.isEmpty ? "n/a" : String(responseBody))
            """
        )
    }

    private static func cookieValue(in cookies: [SessionCookie], names: [String]) -> String? {
        let lowercaseNames = Set(names.map { $0.lowercased() })
        return cookies.first { cookie in
            lowercaseNames.contains(cookie.name.lowercased())
        }?.value
    }

    private static func missingCriticalCookiesMessage(for cookies: [SessionCookie]) -> String? {
        let lowercasedNames = Set(cookies.map { $0.name.lowercased() })
        let requiredNames = ["rsi-token", "_rsi_device"]
        let missingNames = requiredNames.filter { !lowercasedNames.contains($0) }

        guard !missingNames.isEmpty else {
            return nil
        }

        return "missingCriticalCookies=\(missingNames.joined(separator: ","))"
    }

    private static func cookieDebugSummary(for cookies: [SessionCookie]) -> String {
        let cookieNames = cookies.map(\.name).sorted()
        let authCookieNames = cookies
            .map(\.name)
            .filter { name in
                let lowercasedName = name.lowercased()
                return lowercasedName.contains("rsi")
                    || lowercasedName.contains("csrf")
                    || lowercasedName == "_rsi_device"
            }
            .sorted()

        return [
            "cookieCount=\(cookies.count)",
            "cookieNames=\(cookieNames.isEmpty ? "none" : cookieNames.joined(separator: ","))",
            "authCookies=\(authCookieNames.isEmpty ? "none" : authCookieNames.joined(separator: ","))"
        ].joined(separator: ", ")
    }

    private static func renderedGraphQLErrors(from response: GraphQLResponse) -> String? {
        let renderedErrors = (response.errors ?? [])
            .map(\.renderedDescription)
            .filter { !$0.isEmpty }

        guard !renderedErrors.isEmpty else {
            return nil
        }

        return renderedErrors.joined(separator: " || ")
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

    func accountIsAnonymous(for key: String) -> Bool? {
        guard case let .object(values)? = data,
              let value = values[key],
              !value.isNull,
              case let .object(account) = value else {
            return nil
        }

        return account["isAnonymous"]?.boolValue
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

    var boolValue: Bool? {
        switch self {
        case let .bool(value):
            return value
        case let .string(value):
            switch value.lowercased() {
            case "true":
                return true
            case "false":
                return false
            default:
                return nil
            }
        case let .int(value):
            return value != 0
        case let .double(value):
            return value != 0
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
