import CryptoKit
import Foundation
import Security

nonisolated enum LimitedShipAccessKind: String, Codable, Sendable {
    case lifetime
    case timed24h = "timed_24h"
}

nonisolated struct LimitedShipAccessEntitlement: Codable, Equatable, Sendable {
    let kind: LimitedShipAccessKind
    let signingKeyID: String
    let deviceID: String
    let codeID: String
    let redeemedAt: Date
    let expiresAt: Date?
    let issuedAt: Date
    let audience: String?
    var lastVerifiedAt: Date

    var isExpired: Bool {
        guard let expiresAt else {
            return false
        }

        return Date() >= expiresAt
    }
}

nonisolated enum LimitedShipAccessError: LocalizedError, Sendable {
    case malformedCode
    case unsupportedVersion
    case wrongFeature
    case unknownKey
    case invalidSignature
    case incompatibleKey
    case missingCodeID
    case missingAssignedEmail
    case unexpectedAssignedEmail
    case missingDeviceID
    case deviceMismatch
    case codeAlreadyRedeemed(Date)
    case audienceMismatch
    case timedCodeAlreadyUsed(Date?)
    case trustedTimeUnavailable

    var errorDescription: String? {
        switch self {
        case .malformedCode:
            return "That access code is not in the expected format."
        case .unsupportedVersion:
            return "That access code was created for an unsupported code format."
        case .wrongFeature:
            return "That access code is not valid for Limited Ship Purchase."
        case .unknownKey:
            return "That access code was signed by an unknown key."
        case .invalidSignature:
            return "That access code signature is invalid."
        case .incompatibleKey:
            return "That access code was signed with the wrong access key."
        case .missingCodeID:
            return "That access code is missing its code ID."
        case .missingAssignedEmail:
            return "That access code must be assigned to an RSI email."
        case .unexpectedAssignedEmail:
            return "That access code was signed by the all-emails key and cannot be assigned to one email."
        case .missingDeviceID:
            return "That access code must be assigned to this device ID."
        case .deviceMismatch:
            return "That access code is not assigned to this device ID."
        case let .codeAlreadyRedeemed(redeemedAt):
            return "That access code was already used on this device at \(redeemedAt.formatted(date: .abbreviated, time: .shortened))."
        case .audienceMismatch:
            return "That access code is not assigned to the current RSI email."
        case let .timedCodeAlreadyUsed(expiresAt):
            if let expiresAt {
                return "That 24-hour access code was already used on this device and expired at \(expiresAt.formatted(date: .abbreviated, time: .shortened))."
            }

            return "That 24-hour access code was already used on this device."
        case .trustedTimeUnavailable:
            return "Online time could not be verified. Connect to the internet and try again."
        }
    }
}

actor LimitedShipAccessManager {
    static let shared = LimitedShipAccessManager()

    private let store: LimitedShipAccessStore
    private let verifier: LimitedShipAccessCodeVerifier
    private let timeProvider: LimitedShipTrustedTimeProvider

    init(
        store: LimitedShipAccessStore = LimitedShipAccessStore(),
        verifier: LimitedShipAccessCodeVerifier = LimitedShipAccessCodeVerifier(),
        timeProvider: LimitedShipTrustedTimeProvider = LimitedShipTrustedTimeProvider()
    ) {
        self.store = store
        self.verifier = verifier
        self.timeProvider = timeProvider
    }

    func currentEntitlement(account: UserSession?) async -> LimitedShipAccessEntitlement? {
        var payload = await store.loadPayload()

        guard var entitlement = payload.entitlement else {
            return nil
        }

        guard storedEntitlementMatchesCurrentPolicy(entitlement, account: account) else {
            return nil
        }

        switch entitlement.kind {
        case .lifetime:
            return entitlement
        case .timed24h:
            guard let expiresAt = entitlement.expiresAt else {
                payload.entitlement = nil
                await store.save(payload)
                return nil
            }

            let checkDate = await bestAvailableCheckDate(lastVerifiedAt: entitlement.lastVerifiedAt)
            guard checkDate < expiresAt else {
                return nil
            }

            entitlement.lastVerifiedAt = max(entitlement.lastVerifiedAt, checkDate)
            payload.entitlement = entitlement
            await store.save(payload)
            return entitlement
        }
    }

    func redeem(code: String, account: UserSession?) async throws -> LimitedShipAccessEntitlement {
        let payload = try verifier.verify(code: code)
        try validatePayload(payload, account: account)

        var storePayload = await store.loadPayload()
        let redemptionKey = Self.redemptionKey(for: payload)

        if let redeemedAt = storePayload.redeemedCodeIDs[redemptionKey] {
            switch payload.kind {
            case .lifetime:
                if var activeEntitlement = storePayload.entitlement,
                   activeEntitlement.signingKeyID == payload.keyID,
                   activeEntitlement.codeID == payload.codeID,
                   storedEntitlementMatchesCurrentPolicy(activeEntitlement, account: account) {
                    activeEntitlement.lastVerifiedAt = max(activeEntitlement.lastVerifiedAt, Date())
                    storePayload.entitlement = activeEntitlement
                    await store.save(storePayload)
                    return activeEntitlement
                }

                throw LimitedShipAccessError.codeAlreadyRedeemed(redeemedAt)
            case .timed24h:
                if var activeEntitlement = storePayload.entitlement,
                   activeEntitlement.signingKeyID == payload.keyID,
                   activeEntitlement.codeID == payload.codeID,
                   storedEntitlementMatchesCurrentPolicy(activeEntitlement, account: account),
                   let expiresAt = activeEntitlement.expiresAt {
                    let checkDate = await bestAvailableCheckDate(lastVerifiedAt: activeEntitlement.lastVerifiedAt)

                    if checkDate < expiresAt {
                        activeEntitlement.lastVerifiedAt = max(activeEntitlement.lastVerifiedAt, checkDate)
                        storePayload.entitlement = activeEntitlement
                        await store.save(storePayload)
                        return activeEntitlement
                    }
                }

                let expiresAt = redeemedAt.addingTimeInterval(TimeInterval(payload.durationSeconds ?? Self.defaultTimedAccessSeconds))
                throw LimitedShipAccessError.timedCodeAlreadyUsed(expiresAt)
            }
        }

        switch payload.kind {
        case .lifetime:
            let now = Date()
            let entitlement = LimitedShipAccessEntitlement(
                kind: .lifetime,
                signingKeyID: payload.keyID,
                deviceID: LimitedShipAccessDeviceIdentity.currentID(),
                codeID: payload.codeID,
                redeemedAt: now,
                expiresAt: nil,
                issuedAt: Date(timeIntervalSince1970: TimeInterval(payload.issuedAt)),
                audience: payload.audience,
                lastVerifiedAt: now
            )
            storePayload.entitlement = entitlement
            storePayload.redeemedCodeIDs[redemptionKey] = now
            await store.save(storePayload)
            return entitlement
        case .timed24h:
            let trustedNow = try await timeProvider.currentTime()
            let durationSeconds = payload.durationSeconds ?? Self.defaultTimedAccessSeconds
            let entitlement = LimitedShipAccessEntitlement(
                kind: .timed24h,
                signingKeyID: payload.keyID,
                deviceID: LimitedShipAccessDeviceIdentity.currentID(),
                codeID: payload.codeID,
                redeemedAt: trustedNow,
                expiresAt: trustedNow.addingTimeInterval(TimeInterval(durationSeconds)),
                issuedAt: Date(timeIntervalSince1970: TimeInterval(payload.issuedAt)),
                audience: payload.audience,
                lastVerifiedAt: trustedNow
            )
            storePayload.entitlement = entitlement
            storePayload.redeemedCodeIDs[redemptionKey] = trustedNow
            await store.save(storePayload)
            return entitlement
        }
    }

    private static let defaultTimedAccessSeconds = 86_400

    private func validatePayload(_ payload: LimitedShipAccessCodePayload, account: UserSession?) throws {
        guard payload.version == 1 else {
            throw LimitedShipAccessError.unsupportedVersion
        }

        guard payload.feature == Self.featureName else {
            throw LimitedShipAccessError.wrongFeature
        }

        guard !payload.codeID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LimitedShipAccessError.missingCodeID
        }

        guard let keyPolicy = LimitedShipAccessCodeVerifier.policy(for: payload.keyID) else {
            throw LimitedShipAccessError.unknownKey
        }

        guard keyPolicy.kind == payload.kind else {
            throw LimitedShipAccessError.incompatibleKey
        }

        try validateAudience(payload.audience, requirement: keyPolicy.audienceRequirement, account: account)
        try validateDeviceID(payload.deviceID, requirement: keyPolicy.deviceRequirement)
    }

    private func bestAvailableCheckDate(lastVerifiedAt: Date) async -> Date {
        do {
            return try await timeProvider.currentTime()
        } catch {
            let localNow = Date()
            if localNow < lastVerifiedAt.addingTimeInterval(-300) {
                return lastVerifiedAt
            }

            return max(localNow, lastVerifiedAt)
        }
    }

    private func storedEntitlementMatchesCurrentPolicy(
        _ entitlement: LimitedShipAccessEntitlement,
        account: UserSession?
    ) -> Bool {
        guard let keyPolicy = LimitedShipAccessCodeVerifier.policy(for: entitlement.signingKeyID),
              keyPolicy.kind == entitlement.kind else {
            return false
        }

        do {
            try validateAudience(entitlement.audience, requirement: keyPolicy.audienceRequirement, account: account)
            try validateDeviceID(entitlement.deviceID, requirement: keyPolicy.deviceRequirement)
            return true
        } catch {
            return false
        }
    }

    private func validateAudience(
        _ audience: String?,
        requirement: LimitedShipAccessAudienceRequirement,
        account: UserSession?
    ) throws {
        let trimmedAudience = audience?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        switch requirement {
        case .none:
            guard trimmedAudience.isEmpty else {
                throw LimitedShipAccessError.unexpectedAssignedEmail
            }
        case .rsiEmail:
            guard !trimmedAudience.isEmpty else {
                throw LimitedShipAccessError.missingAssignedEmail
            }

            guard let account,
                  Self.normalizedEmail(account.email) == Self.normalizedEmail(trimmedAudience) else {
                throw LimitedShipAccessError.audienceMismatch
            }
        }
    }

    private func validateDeviceID(
        _ deviceID: String?,
        requirement: LimitedShipAccessDeviceRequirement
    ) throws {
        let trimmedDeviceID = deviceID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        switch requirement {
        case .installDeviceID:
            guard !trimmedDeviceID.isEmpty else {
                throw LimitedShipAccessError.missingDeviceID
            }

            guard Self.normalizedDeviceID(trimmedDeviceID) == Self.normalizedDeviceID(LimitedShipAccessDeviceIdentity.currentID()) else {
                throw LimitedShipAccessError.deviceMismatch
            }
        }
    }

    private static func normalizedEmail(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    private static func normalizedDeviceID(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    private static func redemptionKey(for payload: LimitedShipAccessCodePayload) -> String {
        "\(payload.keyID):\(payload.codeID)"
    }

    private static let featureName = "limited_ship_purchase"
}

nonisolated enum LimitedShipAccessAudienceRequirement: Sendable {
    case none
    case rsiEmail
}

nonisolated enum LimitedShipAccessDeviceRequirement: Sendable {
    case installDeviceID
}

nonisolated struct LimitedShipAccessKeyPolicy: Sendable {
    let kind: LimitedShipAccessKind
    let audienceRequirement: LimitedShipAccessAudienceRequirement
    let deviceRequirement: LimitedShipAccessDeviceRequirement
}

nonisolated struct LimitedShipAccessCodeVerifier: Sendable {
    static let lifetimeAllEmailsKeyID = "limited-ship-lifetime-v1"
    static let lifetimeAssignedEmailKeyID = "limited-ship-lifetime-email-v1"
    static let timedAssignedEmailKeyID = "limited-ship-24h-email-v1"

    private static let codePrefix = "HXLS1"
    private static let publicKeysByID: [String: String] = [
        lifetimeAllEmailsKeyID: "MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEERdxPsnoy7MxgKccVR2V71LBnILUtDWYiZ2mcHb6xNSko6MhRdEBDPt+iT22mWKUZ5k8QSFiFb9r5yDBu8mpIw==",
        lifetimeAssignedEmailKeyID: "MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEfl3sne6rbWFBc7INKXXwj3tMtMnW2GYHW1jzCk9mJWm3WkgaYPIbytdMtlGVdCwFak3TaYtB9h1ZQugo8jtGzQ==",
        timedAssignedEmailKeyID: "MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEIJ8Kmnyvnl04p9c/lS8o9mUpmUwAnHQcvS0yBYyyRMTL9URlyM2xss7GGVWvCBoElzreZm+tTkLCYgtym+ELHQ=="
    ]

    private static let keyPoliciesByID: [String: LimitedShipAccessKeyPolicy] = [
        lifetimeAllEmailsKeyID: LimitedShipAccessKeyPolicy(
            kind: .lifetime,
            audienceRequirement: .none,
            deviceRequirement: .installDeviceID
        ),
        lifetimeAssignedEmailKeyID: LimitedShipAccessKeyPolicy(
            kind: .lifetime,
            audienceRequirement: .rsiEmail,
            deviceRequirement: .installDeviceID
        ),
        timedAssignedEmailKeyID: LimitedShipAccessKeyPolicy(
            kind: .timed24h,
            audienceRequirement: .rsiEmail,
            deviceRequirement: .installDeviceID
        )
    ]

    static func policy(for keyID: String) -> LimitedShipAccessKeyPolicy? {
        keyPoliciesByID[keyID]
    }

    func verify(code: String) throws -> LimitedShipAccessCodePayload {
        let trimmedCode = code.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmedCode.split(separator: ".", omittingEmptySubsequences: false).map(String.init)

        guard parts.count == 3,
              parts[0] == Self.codePrefix,
              let payloadData = LimitedShipAccessBase64URL.decode(parts[1]),
              let signatureData = LimitedShipAccessBase64URL.decode(parts[2]) else {
            throw LimitedShipAccessError.malformedCode
        }

        let payload: LimitedShipAccessCodePayload
        do {
            payload = try JSONDecoder().decode(LimitedShipAccessCodePayload.self, from: payloadData)
        } catch {
            throw LimitedShipAccessError.malformedCode
        }

        guard let publicKeyBase64 = Self.publicKeysByID[payload.keyID],
              let publicKeyData = Data(base64Encoded: publicKeyBase64) else {
            throw LimitedShipAccessError.unknownKey
        }

        let publicKey: P256.Signing.PublicKey
        do {
            publicKey = try P256.Signing.PublicKey(derRepresentation: publicKeyData)
        } catch {
            throw LimitedShipAccessError.unknownKey
        }

        let signature: P256.Signing.ECDSASignature
        do {
            signature = try P256.Signing.ECDSASignature(derRepresentation: signatureData)
        } catch {
            throw LimitedShipAccessError.invalidSignature
        }

        let signedData = Data(parts[1].utf8)

        guard publicKey.isValidSignature(signature, for: signedData) else {
            throw LimitedShipAccessError.invalidSignature
        }

        return payload
    }
}

nonisolated struct LimitedShipAccessCodePayload: Codable, Sendable {
    let version: Int
    let feature: String
    let kind: LimitedShipAccessKind
    let keyID: String
    let deviceID: String?
    let codeID: String
    let issuedAt: Int
    let durationSeconds: Int?
    let audience: String?

    enum CodingKeys: String, CodingKey {
        case version
        case feature
        case kind
        case keyID = "keyId"
        case deviceID = "deviceId"
        case codeID = "codeId"
        case issuedAt
        case durationSeconds
        case audience
    }
}

actor LimitedShipAccessStore {
    private let service: String
    private let account: String
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(
        service: String = "com.hangerexpress.limited-ship-access",
        account: String = "invite-entitlement"
    ) {
        self.service = service
        self.account = account
    }

    func loadPayload() -> LimitedShipAccessStorePayload {
        let query = baseQuery(returnData: true)
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess, let data = result as? Data else {
            return .empty
        }

        return (try? decoder.decode(LimitedShipAccessStorePayload.self, from: data)) ?? .empty
    }

    func save(_ payload: LimitedShipAccessStorePayload) {
        guard let data = try? encoder.encode(payload) else {
            return
        }

        let query = baseQuery(returnData: false)
        SecItemDelete(query as CFDictionary)

        var attributes = query
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly

        SecItemAdd(attributes as CFDictionary, nil)
    }

    private func baseQuery(returnData: Bool) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]

        if returnData {
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne
        }

        return query
    }
}

nonisolated struct LimitedShipAccessStorePayload: Codable, Sendable {
    var entitlement: LimitedShipAccessEntitlement?
    var redeemedCodeIDs: [String: Date]

    static let empty = LimitedShipAccessStorePayload(
        entitlement: nil,
        redeemedCodeIDs: [:]
    )

    enum CodingKeys: String, CodingKey {
        case entitlement
        case redeemedCodeIDs
        case redeemedTimedCodeIDs
    }

    init(entitlement: LimitedShipAccessEntitlement?, redeemedCodeIDs: [String: Date]) {
        self.entitlement = entitlement
        self.redeemedCodeIDs = redeemedCodeIDs
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        entitlement = try container.decodeIfPresent(LimitedShipAccessEntitlement.self, forKey: .entitlement)
        redeemedCodeIDs = try container.decodeIfPresent([String: Date].self, forKey: .redeemedCodeIDs)
            ?? container.decodeIfPresent([String: Date].self, forKey: .redeemedTimedCodeIDs)
            ?? [:]
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(entitlement, forKey: .entitlement)
        try container.encode(redeemedCodeIDs, forKey: .redeemedCodeIDs)
    }
}

nonisolated struct LimitedShipTrustedTimeProvider: Sendable {
    func currentTime() async throws -> Date {
        for url in Self.trustedTimeURLs {
            do {
                var request = URLRequest(url: url)
                request.httpMethod = "HEAD"
                request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
                request.timeoutInterval = 8

                let (_, response) = try await URLSession.shared.data(for: request)
                guard let httpResponse = response as? HTTPURLResponse,
                      let dateHeader = httpResponse.value(forHTTPHeaderField: "Date"),
                      let date = Self.httpDateFormatter.date(from: dateHeader) else {
                    continue
                }

                return date
            } catch {
                continue
            }
        }

        throw LimitedShipAccessError.trustedTimeUnavailable
    }

    private static let trustedTimeURLs = [
        URL(string: "https://robertsspaceindustries.com/")!,
        URL(string: "https://www.apple.com/")!
    ]

    private static var httpDateFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss zzz"
        return formatter
    }
}

nonisolated enum LimitedShipAccessDeviceIdentity {
    private static let storageKey = "limitedShipAccess.installDeviceID"

    static func currentID(userDefaults: UserDefaults = .standard) -> String {
        if let storedID = userDefaults.string(forKey: storageKey)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !storedID.isEmpty {
            return storedID
        }

        let newID = "hxlsd-\(UUID().uuidString.lowercased())"
        userDefaults.set(newID, forKey: storageKey)
        return newID
    }
}

nonisolated enum LimitedShipAccessBase64URL {
    static func decode(_ value: String) -> Data? {
        var base64 = value
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")

        let paddingLength = (4 - base64.count % 4) % 4
        base64.append(String(repeating: "=", count: paddingLength))

        return Data(base64Encoded: base64)
    }
}
