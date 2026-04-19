import Foundation

nonisolated struct StoredSessionsSnapshot: Hashable, Sendable {
    let activeSession: UserSession?
    let savedSessions: [UserSession]

    static let empty = StoredSessionsSnapshot(activeSession: nil, savedSessions: [])
}

nonisolated struct StoredSessionsPayload: Hashable, Sendable, Codable {
    let activeSessionID: UserSession.ID?
    let sessions: [UserSession]

    var snapshot: StoredSessionsSnapshot {
        let orderedSessions = sessions.sorted { lhs, rhs in
            if lhs.id == activeSessionID {
                return true
            }

            if rhs.id == activeSessionID {
                return false
            }

            if lhs.createdAt != rhs.createdAt {
                return lhs.createdAt > rhs.createdAt
            }

            return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
        }

        let activeSession = orderedSessions.first { $0.id == activeSessionID } ?? orderedSessions.first
        return StoredSessionsSnapshot(activeSession: activeSession, savedSessions: orderedSessions)
    }

    init(activeSessionID: UserSession.ID?, sessions: [UserSession]) {
        let deduplicatedSessions = Self.deduplicatedSessions(sessions)
        let resolvedActiveSessionID: UserSession.ID?

        if deduplicatedSessions.contains(where: { $0.id == activeSessionID }) {
            resolvedActiveSessionID = activeSessionID
        } else {
            resolvedActiveSessionID = deduplicatedSessions.first?.id
        }

        self.activeSessionID = resolvedActiveSessionID
        self.sessions = deduplicatedSessions
    }

    func saving(_ session: UserSession, makeActive: Bool = true) -> StoredSessionsPayload {
        var updatedSessions = sessions.filter {
            $0.id != session.id && $0.accountKey != session.accountKey
        }
        updatedSessions.append(session)

        return StoredSessionsPayload(
            activeSessionID: makeActive ? session.id : activeSessionID,
            sessions: updatedSessions
        )
    }

    func selecting(id: UserSession.ID) -> StoredSessionsPayload {
        StoredSessionsPayload(activeSessionID: id, sessions: sessions)
    }

    func deleting(id: UserSession.ID) -> StoredSessionsPayload {
        let updatedSessions = sessions.filter { $0.id != id }
        let nextActiveSessionID: UserSession.ID?

        if activeSessionID == id {
            nextActiveSessionID = updatedSessions.max { lhs, rhs in
                lhs.createdAt < rhs.createdAt
            }?.id
        } else {
            nextActiveSessionID = activeSessionID
        }

        return StoredSessionsPayload(activeSessionID: nextActiveSessionID, sessions: updatedSessions)
    }

    static let empty = StoredSessionsPayload(activeSessionID: nil, sessions: [])

    private static func deduplicatedSessions(_ sessions: [UserSession]) -> [UserSession] {
        var uniqueByAccountKey: [String: UserSession] = [:]

        for session in sessions {
            uniqueByAccountKey[session.accountKey] = session
        }

        return Array(uniqueByAccountKey.values)
    }
}

nonisolated struct UserSession: Hashable, Sendable, Codable, Identifiable {
    let id: UUID

    enum AuthMode: String, Hashable, Sendable, Codable {
        case rsiNativeLogin = "RSI Login"
        case importedCookies = "Imported cookies"
        case developerPreview = "Demo data"

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            let rawValue = try container.decode(String.self)

            self = AuthMode(rawValue: rawValue) ?? .rsiNativeLogin
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode(rawValue)
        }
    }

    let handle: String
    let displayName: String
    let email: String
    let authMode: AuthMode
    let notes: String
    let avatarURL: URL?
    let credentials: AccountCredentials?
    let cookies: [SessionCookie]
    let createdAt: Date

    var hasStoredCredentials: Bool {
        credentials != nil
    }

    var accountKey: String {
        if let loginIdentifier = credentials?.loginIdentifier.normalizedAccountKeyComponent {
            return "login:\(loginIdentifier)"
        }

        if let email = email.normalizedAccountKeyComponent {
            return "email:\(email)"
        }

        if let handle = handle.normalizedAccountKeyComponent {
            return "handle:\(handle)"
        }

        return "session:\(id.uuidString.lowercased())"
    }

    static let preview = UserSession(
        handle: "WiseWolfHolo",
        displayName: "WiseWolfHolo",
        email: "preview@hangerexpress.invalid",
        authMode: .developerPreview,
        notes: "Uses local sample data while the live RSI integration is being built.",
        avatarURL: nil,
        credentials: nil,
        cookies: [],
        createdAt: .now
    )

    init(
        id: UUID = UUID(),
        handle: String,
        displayName: String,
        email: String,
        authMode: AuthMode,
        notes: String,
        avatarURL: URL? = nil,
        credentials: AccountCredentials?,
        cookies: [SessionCookie],
        createdAt: Date
    ) {
        self.id = id
        self.handle = handle
        self.displayName = displayName
        self.email = email
        self.authMode = authMode
        self.notes = notes
        self.avatarURL = avatarURL
        self.credentials = credentials
        self.cookies = cookies
        self.createdAt = createdAt
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case handle
        case displayName
        case email
        case authMode
        case notes
        case avatarURL
        case credentials
        case cookies
        case createdAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        handle = try container.decode(String.self, forKey: .handle)
        displayName = try container.decodeIfPresent(String.self, forKey: .displayName) ?? handle
        email = try container.decodeIfPresent(String.self, forKey: .email) ?? ""
        authMode = try container.decodeIfPresent(AuthMode.self, forKey: .authMode) ?? .rsiNativeLogin
        notes = try container.decodeIfPresent(String.self, forKey: .notes) ?? ""
        avatarURL = try container.decodeIfPresent(URL.self, forKey: .avatarURL)
        credentials = try container.decodeIfPresent(AccountCredentials.self, forKey: .credentials)
        cookies = try container.decodeIfPresent([SessionCookie].self, forKey: .cookies) ?? []
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? .now
    }

    func clearingCookies(notes: String? = nil) -> UserSession {
        UserSession(
            id: id,
            handle: handle,
            displayName: displayName,
            email: email,
            authMode: authMode,
            notes: notes ?? self.notes,
            avatarURL: avatarURL,
            credentials: credentials,
            cookies: [],
            createdAt: createdAt
        )
    }
}

nonisolated struct AccountCredentials: Hashable, Sendable, Codable {
    let loginIdentifier: String
    let password: String

    private enum CodingKeys: String, CodingKey {
        case loginIdentifier
        case password
    }

    init(loginIdentifier: String, password: String) {
        self.loginIdentifier = loginIdentifier
        self.password = password
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        loginIdentifier = try container.decode(String.self, forKey: .loginIdentifier)
        password = try container.decode(String.self, forKey: .password)
    }
}

nonisolated struct SessionCookie: Hashable, Sendable, Codable {
    let name: String
    let value: String
    let domain: String
    let path: String
    let expiresAt: Date?
    let isSecure: Bool
    let isHTTPOnly: Bool
    let version: Int

    init(_ cookie: HTTPCookie) {
        name = cookie.name
        value = cookie.value
        domain = cookie.domain
        path = cookie.path
        expiresAt = cookie.expiresDate
        isSecure = cookie.isSecure
        isHTTPOnly = cookie.isHTTPOnly
        version = cookie.version
    }

    var httpCookie: HTTPCookie? {
        var properties: [HTTPCookiePropertyKey: Any] = [
            .name: name,
            .value: value,
            .domain: domain,
            .path: path
        ]

        if let expiresAt {
            properties[.expires] = expiresAt
        }

        if isSecure {
            properties[.secure] = "TRUE"
        }

        if isHTTPOnly {
            properties[HTTPCookiePropertyKey("HttpOnly")] = "TRUE"
        }

        properties[.version] = version
        return HTTPCookie(properties: properties)
    }

    private enum CodingKeys: String, CodingKey {
        case name
        case value
        case domain
        case path
        case expiresAt
        case isSecure
        case isHTTPOnly
        case version
    }

    init(
        name: String,
        value: String,
        domain: String,
        path: String,
        expiresAt: Date?,
        isSecure: Bool,
        isHTTPOnly: Bool,
        version: Int
    ) {
        self.name = name
        self.value = value
        self.domain = domain
        self.path = path
        self.expiresAt = expiresAt
        self.isSecure = isSecure
        self.isHTTPOnly = isHTTPOnly
        self.version = version
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        name = try container.decode(String.self, forKey: .name)
        value = try container.decode(String.self, forKey: .value)
        domain = try container.decode(String.self, forKey: .domain)
        path = try container.decodeIfPresent(String.self, forKey: .path) ?? "/"
        expiresAt = try container.decodeIfPresent(Date.self, forKey: .expiresAt)
        isSecure = try container.decodeIfPresent(Bool.self, forKey: .isSecure) ?? true
        isHTTPOnly = try container.decodeIfPresent(Bool.self, forKey: .isHTTPOnly) ?? true
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 0
    }
}

enum TrustedDeviceDuration: String, CaseIterable, Identifiable, Hashable, Sendable, Codable {
    case session
    case day
    case week
    case month
    case year

    var id: String {
        rawValue
    }

    var displayName: String {
        switch self {
        case .session:
            return "This session"
        case .day:
            return "1 day"
        case .week:
            return "1 week"
        case .month:
            return "1 month"
        case .year:
            return "1 year"
        }
    }
}

struct HangarSnapshot: Hashable, Sendable, Codable {
    let accountHandle: String
    let lastSyncedAt: Date
    let avatarURL: URL?
    let primaryOrganization: AccountOrganization?
    let storeCreditUSD: Decimal?
    let totalSpendUSD: Decimal?
    let packages: [HangarPackage]
    let fleet: [FleetShip]
    let buyback: [BuybackPledge]
    let referralStats: ReferralStats

    init(
        accountHandle: String,
        lastSyncedAt: Date,
        avatarURL: URL? = nil,
        primaryOrganization: AccountOrganization? = nil,
        storeCreditUSD: Decimal?,
        totalSpendUSD: Decimal? = nil,
        packages: [HangarPackage],
        fleet: [FleetShip],
        buyback: [BuybackPledge],
        referralStats: ReferralStats = .unavailable
    ) {
        self.accountHandle = accountHandle
        self.lastSyncedAt = lastSyncedAt
        self.avatarURL = avatarURL
        self.primaryOrganization = primaryOrganization
        self.storeCreditUSD = storeCreditUSD
        self.totalSpendUSD = totalSpendUSD
        self.packages = packages
        self.fleet = fleet
        self.buyback = buyback
        self.referralStats = referralStats
    }

    private enum CodingKeys: String, CodingKey {
        case accountHandle
        case lastSyncedAt
        case avatarURL
        case primaryOrganization
        case storeCreditUSD
        case totalSpendUSD
        case packages
        case fleet
        case buyback
        case referralStats
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        accountHandle = try container.decode(String.self, forKey: .accountHandle)
        lastSyncedAt = try container.decode(Date.self, forKey: .lastSyncedAt)
        avatarURL = try container.decodeIfPresent(URL.self, forKey: .avatarURL)
        primaryOrganization = try container.decodeIfPresent(AccountOrganization.self, forKey: .primaryOrganization)
        storeCreditUSD = try container.decodeIfPresent(Decimal.self, forKey: .storeCreditUSD)
        totalSpendUSD = try container.decodeIfPresent(Decimal.self, forKey: .totalSpendUSD)
        packages = try container.decodeIfPresent([HangarPackage].self, forKey: .packages) ?? []
        fleet = try container.decodeIfPresent([FleetShip].self, forKey: .fleet) ?? []
        buyback = try container.decodeIfPresent([BuybackPledge].self, forKey: .buyback) ?? []
        referralStats = try container.decodeIfPresent(ReferralStats.self, forKey: .referralStats) ?? .unavailable
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(accountHandle, forKey: .accountHandle)
        try container.encode(lastSyncedAt, forKey: .lastSyncedAt)
        try container.encodeIfPresent(avatarURL, forKey: .avatarURL)
        try container.encodeIfPresent(primaryOrganization, forKey: .primaryOrganization)
        try container.encodeIfPresent(storeCreditUSD, forKey: .storeCreditUSD)
        try container.encodeIfPresent(totalSpendUSD, forKey: .totalSpendUSD)
        try container.encode(packages, forKey: .packages)
        try container.encode(fleet, forKey: .fleet)
        try container.encode(buyback, forKey: .buyback)
        try container.encode(referralStats, forKey: .referralStats)
    }

    func updatingHangar(
        packages: [HangarPackage],
        fleet: [FleetShip],
        lastSyncedAt: Date = .now
    ) -> HangarSnapshot {
        HangarSnapshot(
            accountHandle: accountHandle,
            lastSyncedAt: lastSyncedAt,
            avatarURL: avatarURL,
            primaryOrganization: primaryOrganization,
            storeCreditUSD: storeCreditUSD,
            totalSpendUSD: totalSpendUSD,
            packages: packages,
            fleet: fleet,
            buyback: buyback,
            referralStats: referralStats
        )
    }

    func updatingBuyback(
        buyback: [BuybackPledge],
        lastSyncedAt: Date = .now
    ) -> HangarSnapshot {
        HangarSnapshot(
            accountHandle: accountHandle,
            lastSyncedAt: lastSyncedAt,
            avatarURL: avatarURL,
            primaryOrganization: primaryOrganization,
            storeCreditUSD: storeCreditUSD,
            totalSpendUSD: totalSpendUSD,
            packages: packages,
            fleet: fleet,
            buyback: buyback,
            referralStats: referralStats
        )
    }

    func updatingAccount(
        accountHandle: String? = nil,
        avatarURL: URL?,
        primaryOrganization: AccountOrganization?,
        storeCreditUSD: Decimal?,
        totalSpendUSD: Decimal?,
        referralStats: ReferralStats,
        lastSyncedAt: Date = .now
    ) -> HangarSnapshot {
        HangarSnapshot(
            accountHandle: accountHandle ?? self.accountHandle,
            lastSyncedAt: lastSyncedAt,
            avatarURL: avatarURL,
            primaryOrganization: primaryOrganization,
            storeCreditUSD: storeCreditUSD,
            totalSpendUSD: totalSpendUSD,
            packages: packages,
            fleet: fleet,
            buyback: buyback,
            referralStats: referralStats
        )
    }

    var metrics: HangarMetrics {
        HangarMetrics(
            packageCount: packages.count,
            shipCount: fleet.count,
            giftableCount: packages.filter(\.canGift).count,
            reclaimableCount: packages.filter(\.canReclaim).count,
            storeCreditUSD: storeCreditUSD,
            totalSpendUSD: totalSpendUSD,
            totalOriginalValue: packages.reduce(into: Decimal.zero) { partialResult, package in
                partialResult += package.originalValueUSD
            },
            totalCurrentValue: packages.reduce(into: Decimal.zero) { partialResult, package in
                partialResult += package.currentValueUSD
            }
        )
    }
}

struct AccountOrganization: Hashable, Sendable, Codable {
    let name: String
    let rank: String?

    var summaryText: String {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedRank = rank?.trimmingCharacters(in: .whitespacesAndNewlines)

        guard let trimmedRank, !trimmedRank.isEmpty else {
            return trimmedName
        }

        return "\(trimmedName) | \(trimmedRank)"
    }
}

struct ReferralStats: Hashable, Sendable, Codable {
    let currentLadderCount: Int?
    let legacyLadderCount: Int?
    let hasLegacyLadder: Bool

    static let unavailable = ReferralStats(
        currentLadderCount: nil,
        legacyLadderCount: nil,
        hasLegacyLadder: false
    )

    var currentSummary: String {
        "New \(currentLadderCount.map(String.init) ?? "Unavailable")"
    }

    var legacySummary: String {
        if hasLegacyLadder {
            return "Legacy \(legacyLadderCount.map(String.init) ?? "Unavailable")"
        }

        return "Legacy N/A"
    }
}

struct HangarMetrics: Hashable, Sendable, Codable {
    let packageCount: Int
    let shipCount: Int
    let giftableCount: Int
    let reclaimableCount: Int
    let storeCreditUSD: Decimal?
    let totalSpendUSD: Decimal?
    let totalOriginalValue: Decimal
    let totalCurrentValue: Decimal
}

private extension String {
    nonisolated var normalizedAccountKeyComponent: String? {
        let normalized = trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized.isEmpty ? nil : normalized
    }
}

struct HangarPackage: Identifiable, Hashable, Sendable, Codable {
    let id: Int
    let title: String
    let status: String
    let insurance: String
    let insuranceOptions: [String]?
    let acquiredAt: Date
    let originalValueUSD: Decimal
    let currentValueUSD: Decimal
    let canGift: Bool
    let canReclaim: Bool
    let canUpgrade: Bool
    let packageThumbnailURL: URL?
    let contents: [PackageItem]

    init(
        id: Int,
        title: String,
        status: String,
        insurance: String,
        insuranceOptions: [String]? = nil,
        acquiredAt: Date,
        originalValueUSD: Decimal,
        currentValueUSD: Decimal,
        canGift: Bool,
        canReclaim: Bool,
        canUpgrade: Bool,
        packageThumbnailURL: URL? = nil,
        contents: [PackageItem]
    ) {
        self.id = id
        self.title = title
        self.status = status
        self.insurance = insurance
        self.insuranceOptions = insuranceOptions
        self.acquiredAt = acquiredAt
        self.originalValueUSD = originalValueUSD
        self.currentValueUSD = currentValueUSD
        self.canGift = canGift
        self.canReclaim = canReclaim
        self.canUpgrade = canUpgrade
        self.packageThumbnailURL = packageThumbnailURL
        self.contents = contents
    }

    var thumbnailURL: URL? {
        packageThumbnailURL ?? contents.compactMap(\.imageURL).first
    }

    var hasLifetimeInsurance: Bool {
        allInsuranceLevels.contains(where: { $0.localizedCaseInsensitiveContains("LTI") })
    }

    var hasUpgradeItems: Bool {
        contents.contains(where: { $0.category == .upgrade })
    }

    var isUpgradeOnlyPledge: Bool {
        let hasUpgradeLikeTitle =
            title.localizedCaseInsensitiveContains("upgrade")
            || title.localizedCaseInsensitiveContains("ccu")
            || title.contains(" to ")
        let hasUpgradeLikeContents = contents.contains(where: { $0.category == .upgrade })

        guard hasUpgradeLikeTitle || hasUpgradeLikeContents else {
            return false
        }

        return !contents.contains(where: { $0.isShipLike || $0.category == .gamePackage })
    }

    var displayedInsurance: String? {
        guard let trimmedInsurance = primaryInsurance else {
            return nil
        }

        guard !trimmedInsurance.isEmpty else {
            return nil
        }

        if isUpgradeOnlyPledge,
           trimmedInsurance.localizedCaseInsensitiveCompare("Unknown") == .orderedSame
        {
            return nil
        }

        return trimmedInsurance
    }

    var detailInsuranceText: String? {
        let levels = allInsuranceLevels

        if !levels.isEmpty {
            if levels.count == 1,
               levels[0].localizedCaseInsensitiveCompare("Unknown") == .orderedSame
            {
                return displayedInsurance
            }

            return levels.joined(separator: ", ")
        }

        return displayedInsurance
    }

    var searchableInsuranceText: String {
        if let detailInsuranceText {
            return detailInsuranceText
        }

        return insurance.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var isMultiShipPackage: Bool {
        contents.filter(\.isShipLike).count > 1
    }

    var inventoryGroupingKey: InventoryGroupingKey {
        InventoryGroupingKey(
            title: title,
            status: status,
            insurance: insurance,
            insuranceOptions: allInsuranceLevels,
            acquiredAt: acquiredAt.inventoryGroupingDate,
            originalValueUSD: originalValueUSD,
            currentValueUSD: currentValueUSD,
            canGift: canGift,
            canReclaim: canReclaim,
            canUpgrade: canUpgrade,
            packageThumbnailURL: packageThumbnailURL,
            contents: contents.map(\.inventoryGroupingKey)
        )
    }

    struct InventoryGroupingKey: Hashable, Sendable {
        let title: String
        let status: String
        let insurance: String
        let insuranceOptions: [String]
        let acquiredAt: Date
        let originalValueUSD: Decimal
        let currentValueUSD: Decimal
        let canGift: Bool
        let canReclaim: Bool
        let canUpgrade: Bool
        let packageThumbnailURL: URL?
        let contents: [PackageItem.InventoryGroupingKey]
    }

    private var allInsuranceLevels: [String] {
        let normalizedOptions = Self.normalizedInsuranceLevels(insuranceOptions ?? [])
        if !normalizedOptions.isEmpty {
            return normalizedOptions
        }

        guard let normalizedInsurance = Self.normalizedInsuranceLabel(from: insurance) else {
            return []
        }

        return [normalizedInsurance]
    }

    private var primaryInsurance: String? {
        allInsuranceLevels.first
    }

    nonisolated static func normalizedInsuranceLevels(_ rawValues: [String]) -> [String] {
        var seen = Set<String>()
        let normalizedValues = rawValues.compactMap(Self.normalizedInsuranceLabel(from:))

        let deduplicated = normalizedValues.filter { value in
            seen.insert(value.localizedLowercase).inserted
        }

        return deduplicated.sorted { lhs, rhs in
            let lhsRank = insuranceRanking(for: lhs)
            let rhsRank = insuranceRanking(for: rhs)

            if lhsRank.priority != rhsRank.priority {
                return lhsRank.priority > rhsRank.priority
            }

            if lhsRank.months != rhsRank.months {
                return lhsRank.months > rhsRank.months
            }

            return lhs.localizedCaseInsensitiveCompare(rhs) == .orderedAscending
        }
    }

    nonisolated static func normalizedInsuranceLabel(from rawValue: String) -> String? {
        let trimmedValue = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedValue.isEmpty else {
            return nil
        }

        let lowercased = trimmedValue.localizedLowercase

        if lowercased.contains("lti") || lowercased.contains("lifetime") {
            return "LTI"
        }

        if let months = insuranceValueMatch(in: lowercased, pattern: #"(\d+)\s*(month|months|mo)\b"#) {
            return "\(months) months"
        }

        if let years = insuranceValueMatch(in: lowercased, pattern: #"(\d+)\s*(year|years|yr)\b"#) {
            return "\(years * 12) months"
        }

        if lowercased == "unknown" {
            return "Unknown"
        }

        return trimmedValue
    }

    private nonisolated static func insuranceRanking(for value: String) -> (priority: Int, months: Int) {
        let normalizedValue = normalizedInsuranceLabel(from: value) ?? value
        let lowercased = normalizedValue.localizedLowercase

        if lowercased == "lti" {
            return (priority: 2, months: .max)
        }

        if lowercased == "unknown" {
            return (priority: 0, months: -1)
        }

        if let months = insuranceValueMatch(in: lowercased, pattern: #"(\d+)\s*months?\b"#) {
            return (priority: 1, months: months)
        }

        return (priority: 1, months: 0)
    }

    private nonisolated static func insuranceValueMatch(in text: String, pattern: String) -> Int? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return nil
        }

        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              let captureRange = Range(match.range(at: 1), in: text) else {
            return nil
        }

        return Int(text[captureRange])
    }
}

struct GroupedHangarPackage: Identifiable, Hashable, Sendable {
    let representative: HangarPackage
    let packages: [HangarPackage]

    init(representative: HangarPackage, packages: [HangarPackage]) {
        self.representative = representative
        self.packages = packages
    }

    var id: String {
        packages
            .map(\.id)
            .sorted()
            .map(String.init)
            .joined(separator: "-")
    }

    var quantity: Int {
        packages.count
    }

    var containsMultipleCopies: Bool {
        quantity > 1
    }
}

extension Sequence where Element == HangarPackage {
    var groupedForInventoryDisplay: [GroupedHangarPackage] {
        var orderedKeys: [HangarPackage.InventoryGroupingKey] = []
        var groupedPackages: [HangarPackage.InventoryGroupingKey: [HangarPackage]] = [:]

        for package in self {
            let key = package.inventoryGroupingKey
            if groupedPackages[key] == nil {
                orderedKeys.append(key)
            }

            groupedPackages[key, default: []].append(package)
        }

        return orderedKeys.compactMap { key in
            guard let packages = groupedPackages[key], let representative = packages.first else {
                return nil
            }

            return GroupedHangarPackage(
                representative: representative,
                packages: packages
            )
        }
    }
}

struct PackageItem: Identifiable, Hashable, Sendable, Codable {
    enum Category: String, Hashable, Sendable, Codable {
        case ship = "Ship"
        case vehicle = "Vehicle"
        case gamePackage = "Game Package"
        case flair = "Flair"
        case upgrade = "Upgrade"
        case perk = "Perk"
    }

    struct UpgradePricing: Hashable, Sendable, Codable {
        let sourceShipName: String
        let sourceShipMSRPUSD: Decimal?
        let targetShipName: String
        let targetShipMSRPUSD: Decimal?
        let actualValueUSD: Decimal?
        let meltValueUSD: Decimal?
    }

    let id: String
    let title: String
    let detail: String
    let category: Category
    let imageURL: URL?
    let upgradePricing: UpgradePricing?

    var inventoryGroupingKey: InventoryGroupingKey {
        InventoryGroupingKey(
            title: title,
            detail: detail,
            category: category,
            imageURL: imageURL,
            upgradePricing: upgradePricing
        )
    }

    var isShipLike: Bool {
        switch category {
        case .ship, .vehicle:
            return true
        case .gamePackage, .flair, .upgrade, .perk:
            return false
        }
    }

    struct InventoryGroupingKey: Hashable, Sendable {
        let title: String
        let detail: String
        let category: Category
        let imageURL: URL?
        let upgradePricing: UpgradePricing?
    }
}

struct FleetShip: Identifiable, Hashable, Sendable, Codable {
    let id: Int
    let displayName: String
    let manufacturer: String
    let role: String
    let roleCategories: [String]
    let msrpUSD: Decimal?
    let insurance: String
    let sourcePackageID: Int
    let sourcePackageName: String
    let meltValueUSD: Decimal
    let canGift: Bool
    let canReclaim: Bool
    let imageURL: URL?

    init(
        id: Int,
        displayName: String,
        manufacturer: String,
        role: String,
        roleCategories: [String] = [],
        msrpUSD: Decimal? = nil,
        insurance: String,
        sourcePackageID: Int,
        sourcePackageName: String,
        meltValueUSD: Decimal,
        canGift: Bool,
        canReclaim: Bool,
        imageURL: URL? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.manufacturer = manufacturer
        self.role = role
        self.roleCategories = roleCategories
        self.msrpUSD = msrpUSD
        self.insurance = insurance
        self.sourcePackageID = sourcePackageID
        self.sourcePackageName = sourcePackageName
        self.meltValueUSD = meltValueUSD
        self.canGift = canGift
        self.canReclaim = canReclaim
        self.imageURL = imageURL
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case displayName
        case manufacturer
        case role
        case roleCategories
        case msrpUSD
        case insurance
        case sourcePackageID
        case sourcePackageName
        case meltValueUSD
        case canGift
        case canReclaim
        case imageURL
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        id = try container.decode(Int.self, forKey: .id)
        displayName = try container.decode(String.self, forKey: .displayName)
        manufacturer = try container.decode(String.self, forKey: .manufacturer)
        role = try container.decode(String.self, forKey: .role)
        roleCategories = try container.decodeIfPresent([String].self, forKey: .roleCategories)
            ?? role
                .split(separator: "/")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        msrpUSD = try container.decodeIfPresent(Decimal.self, forKey: .msrpUSD)
        insurance = try container.decode(String.self, forKey: .insurance)
        sourcePackageID = try container.decode(Int.self, forKey: .sourcePackageID)
        sourcePackageName = try container.decode(String.self, forKey: .sourcePackageName)
        meltValueUSD = try container.decode(Decimal.self, forKey: .meltValueUSD)
        canGift = try container.decode(Bool.self, forKey: .canGift)
        canReclaim = try container.decode(Bool.self, forKey: .canReclaim)
        imageURL = try container.decodeIfPresent(URL.self, forKey: .imageURL)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(displayName, forKey: .displayName)
        try container.encode(manufacturer, forKey: .manufacturer)
        try container.encode(role, forKey: .role)
        try container.encode(roleCategories, forKey: .roleCategories)
        try container.encodeIfPresent(msrpUSD, forKey: .msrpUSD)
        try container.encode(insurance, forKey: .insurance)
        try container.encode(sourcePackageID, forKey: .sourcePackageID)
        try container.encode(sourcePackageName, forKey: .sourcePackageName)
        try container.encode(meltValueUSD, forKey: .meltValueUSD)
        try container.encode(canGift, forKey: .canGift)
        try container.encode(canReclaim, forKey: .canReclaim)
        try container.encodeIfPresent(imageURL, forKey: .imageURL)
    }

    var searchHaystack: String {
        [
            displayName,
            manufacturer,
            role,
            roleCategories.joined(separator: " "),
            insurance,
            sourcePackageName
        ]
        .joined(separator: " ")
        .localizedLowercase
    }

    var groupingKey: GroupingKey {
        GroupingKey(
            displayName: displayName,
            manufacturer: manufacturer,
            role: role,
            insurance: insurance,
            canGift: canGift,
            canReclaim: canReclaim
        )
    }

    struct GroupingKey: Hashable, Sendable {
        let displayName: String
        let manufacturer: String
        let role: String
        let insurance: String
        let canGift: Bool
        let canReclaim: Bool
    }
}

struct GroupedFleetShip: Identifiable, Hashable, Sendable {
    let representative: FleetShip
    let ships: [FleetShip]

    init(representative: FleetShip, ships: [FleetShip]) {
        self.representative = representative
        self.ships = ships
    }

    var id: String {
        ships
            .map(\.id)
            .sorted()
            .map(String.init)
            .joined(separator: "-")
    }

    var quantity: Int {
        ships.count
    }

    var totalMeltValueUSD: Decimal {
        ships.reduce(into: Decimal.zero) { partialResult, ship in
            partialResult += ship.meltValueUSD
        }
    }

    var individualMeltValuesUSD: [Decimal] {
        Array(Set(ships.map(\.meltValueUSD))).sorted {
            NSDecimalNumber(decimal: $0).compare(NSDecimalNumber(decimal: $1)) == .orderedAscending
        }
    }

    var sourcePackageSummary: String {
        let distinctPackages = Array(Set(ships.map(\.sourcePackageName))).sorted()

        if distinctPackages.count == 1, let packageName = distinctPackages.first {
            return packageName
        }

        return "\(distinctPackages.count) packages"
    }
}

extension Sequence where Element == FleetShip {
    var groupedForFleetDisplay: [GroupedFleetShip] {
        var orderedKeys: [FleetShip.GroupingKey] = []
        var groupedShips: [FleetShip.GroupingKey: [FleetShip]] = [:]

        for ship in self {
            let key = ship.groupingKey
            if groupedShips[key] == nil {
                orderedKeys.append(key)
            }

            groupedShips[key, default: []].append(ship)
        }

        return orderedKeys.compactMap { key in
            guard let ships = groupedShips[key], !ships.isEmpty else {
                return nil
            }

            let representative = ships.max { lhs, rhs in
                lhs.representativePriority < rhs.representativePriority
            } ?? ships[0]

            return GroupedFleetShip(representative: representative, ships: ships)
        }
    }
}

private extension FleetShip {
    var representativePriority: Int {
        var score = 0

        if msrpUSD != nil {
            score += 8
        }

        if imageURL != nil {
            score += 4
        }

        if !roleCategories.isEmpty {
            score += 2
        }

        if manufacturer.localizedCaseInsensitiveCompare("Unknown") != .orderedSame {
            score += 1
        }

        return score
    }
}

struct BuybackPledge: Identifiable, Hashable, Sendable, Codable {
    let id: Int
    let title: String
    let recoveredValueUSD: Decimal
    let addedToBuybackAt: Date
    let notes: String
    let imageURL: URL?

    init(
        id: Int,
        title: String,
        recoveredValueUSD: Decimal,
        addedToBuybackAt: Date,
        notes: String,
        imageURL: URL? = nil
    ) {
        self.id = id
        self.title = title
        self.recoveredValueUSD = recoveredValueUSD
        self.addedToBuybackAt = addedToBuybackAt
        self.notes = notes
        self.imageURL = imageURL
    }

    var displayedNotes: String? {
        let trimmedNotes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedNotes.isEmpty,
              trimmedNotes != Self.placeholderNotes else {
            return nil
        }

        return trimmedNotes
    }

    var searchHaystack: String {
        [title, displayedNotes ?? ""]
            .joined(separator: " ")
            .localizedLowercase
    }

    var groupingKey: GroupingKey {
        GroupingKey(
            title: title,
            displayedNotes: displayedNotes ?? ""
        )
    }

    var isSkin: Bool {
        let haystack = searchHaystack
        return haystack.contains("paint")
            || haystack.contains("skin")
            || haystack.contains("livery")
    }

    var isUpgrade: Bool {
        let haystack = searchHaystack
        return haystack.contains("upgrade")
            || haystack.contains("ccu")
    }

    var isGear: Bool {
        if isUpgrade || isSkin {
            return false
        }

        let haystack = searchHaystack
        let gearKeywords = [
            "armor",
            "helmet",
            "undersuit",
            "backpack",
            "weapon",
            "rifle",
            "shotgun",
            "pistol",
            "sniper",
            "smg",
            "lmg",
            "knife",
            "grenade",
            "multitool",
            "multi-tool",
            "tractor beam",
            "tractor",
            "medgun",
            "equipment",
            "gear",
            "tool"
        ]

        return gearKeywords.contains { haystack.contains($0) }
    }

    var isPackage: Bool {
        if isGear || isUpgrade || isSkin {
            return false
        }

        let haystack = searchHaystack
        return haystack.contains("game package")
            || haystack.contains("starter package")
            || haystack.contains("starter pack")
            || haystack.contains("package")
            || haystack.contains("bundle")
    }

    var isStandaloneShip: Bool {
        if isUpgrade || isSkin || isPackage || isGear {
            return false
        }

        let haystack = searchHaystack
        if haystack.contains("standalone ship")
            || haystack.contains("ship")
            || haystack.contains("vehicle")
            || haystack.contains("fighter")
            || haystack.contains("freighter")
            || haystack.contains("gunboat")
            || haystack.contains("rover") {
            return true
        }

        return true
    }

    var isShip: Bool {
        isStandaloneShip
    }

    private static let placeholderNotes = "Recovered from the RSI buy-back page."

    struct GroupingKey: Hashable, Sendable {
        let title: String
        let displayedNotes: String
    }
}

struct GroupedBuybackPledge: Identifiable, Hashable, Sendable {
    let representative: BuybackPledge
    let pledges: [BuybackPledge]

    init(representative: BuybackPledge, pledges: [BuybackPledge]) {
        self.representative = representative
        self.pledges = pledges
    }

    var id: String {
        pledges
            .map(\.id)
            .sorted()
            .map(String.init)
            .joined(separator: "-")
    }

    var quantity: Int {
        pledges.count
    }

    var latestAddedToBuybackAt: Date {
        pledges.map(\.addedToBuybackAt).max() ?? representative.addedToBuybackAt
    }

    var earliestAddedToBuybackAt: Date {
        pledges.map(\.addedToBuybackAt).min() ?? representative.addedToBuybackAt
    }
}

extension Sequence where Element == BuybackPledge {
    var groupedForBuybackDisplay: [GroupedBuybackPledge] {
        var orderedKeys: [BuybackPledge.GroupingKey] = []
        var groupedPledges: [BuybackPledge.GroupingKey: [BuybackPledge]] = [:]

        for pledge in self {
            let key = pledge.groupingKey
            if groupedPledges[key] == nil {
                orderedKeys.append(key)
            }

            groupedPledges[key, default: []].append(pledge)
        }

        return orderedKeys.compactMap { key in
            guard let pledges = groupedPledges[key], let representative = pledges.first else {
                return nil
            }

            return GroupedBuybackPledge(
                representative: representative,
                pledges: pledges
            )
        }
    }
}

private extension Date {
    var inventoryGroupingDate: Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        return calendar.startOfDay(for: self)
    }
}
