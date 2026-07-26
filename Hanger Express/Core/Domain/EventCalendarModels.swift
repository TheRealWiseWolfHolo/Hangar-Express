import Foundation

nonisolated struct EventCalendarFeed: Codable, Hashable, Sendable {
    let schemaVersion: Int
    let generatedAt: Date
    let count: Int
    let sources: [EventCalendarSource]
    let events: [StarCitizenEvent]
}

nonisolated struct EventCalendarSource: Codable, Hashable, Sendable, Identifiable {
    let id: String
    let name: String
    let url: URL
    let status: String
    let usedPreviousData: Bool
}

nonisolated struct StarCitizenEvent: Codable, Hashable, Sendable, Identifiable {
    enum Category: String, Codable, CaseIterable, Sendable {
        case official
        case barCitizen
    }

    enum EventType: String, Codable, Sendable {
        case online
        case inPerson
    }

    enum Status: String, Codable, Sendable {
        case scheduled
        case cancelled
        case postponed
        case completed
    }

    enum DateConfidence: String, Codable, Sendable {
        case confirmed
        case anticipated
    }

    let id: String
    let title: String
    let category: Category
    let eventType: EventType
    let organizer: String
    let verification: String
    let dateConfidence: DateConfidence?
    let status: Status
    let schedule: StarCitizenEventSchedule
    let location: StarCitizenEventLocation
    let summary: String
    let links: [StarCitizenEventLink]
    let lastVerifiedAt: Date

    var sourceURL: URL? {
        links.first(where: { $0.role == "source" })?.url
    }

    var displayTitle: String {
        AppLocalizer.string(title)
    }

    var isAnticipated: Bool {
        dateConfidence == .anticipated
    }

    var startsAt: Date {
        schedule.startsAt
    }

    var endsAt: Date {
        schedule.endsAt
    }

    func hasEnded(at date: Date = .now) -> Bool {
        endsAt < date
    }

    func matches(searchText: String) -> Bool {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            return true
        }

        return [
            title,
            displayTitle,
            organizer,
            summary,
            location.name,
            location.city,
            location.region,
            location.countryCode,
            location.formattedAddress
        ]
        .compactMap { $0 }
        .contains { $0.localizedCaseInsensitiveContains(query) }
    }
}

nonisolated enum StarCitizenEventSchedule: Hashable, Sendable {
    case timed(
        startsAt: Date,
        endsAt: Date,
        timeZoneIdentifier: String?,
        originalTimeZone: String?
    )
    case allDay(
        startDate: Date,
        endDateExclusive: Date,
        timeZoneIdentifier: String?
    )

    var startsAt: Date {
        switch self {
        case let .timed(startsAt, _, _, _):
            return startsAt
        case let .allDay(startDate, _, _):
            return startDate
        }
    }

    var endsAt: Date {
        switch self {
        case let .timed(_, endsAt, _, _):
            return endsAt
        case let .allDay(_, endDateExclusive, _):
            return endDateExclusive
        }
    }

    var isAllDay: Bool {
        if case .allDay = self {
            return true
        }
        return false
    }

    var originalTimeZone: String? {
        switch self {
        case let .timed(_, _, _, originalTimeZone):
            return originalTimeZone
        case let .allDay(_, _, timeZoneIdentifier):
            return timeZoneIdentifier
        }
    }

    private enum CodingKeys: String, CodingKey {
        case kind
        case startsAt
        case endsAt
        case startDate
        case endDateExclusive
        case timeZone
        case originalTimeZone
    }

    private enum Kind: String, Codable {
        case timed
        case allDay
    }
}

extension StarCitizenEventSchedule: Codable {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(Kind.self, forKey: .kind)

        switch kind {
        case .timed:
            self = .timed(
                startsAt: try container.decode(Date.self, forKey: .startsAt),
                endsAt: try container.decode(Date.self, forKey: .endsAt),
                timeZoneIdentifier: try container.decodeIfPresent(String.self, forKey: .timeZone),
                originalTimeZone: try container.decodeIfPresent(String.self, forKey: .originalTimeZone)
            )
        case .allDay:
            let startDate = try Self.decodeDateOnly(
                try container.decode(String.self, forKey: .startDate),
                codingPath: decoder.codingPath + [CodingKeys.startDate]
            )
            let endDate = try Self.decodeDateOnly(
                try container.decode(String.self, forKey: .endDateExclusive),
                codingPath: decoder.codingPath + [CodingKeys.endDateExclusive]
            )
            self = .allDay(
                startDate: startDate,
                endDateExclusive: endDate,
                timeZoneIdentifier: try container.decodeIfPresent(String.self, forKey: .timeZone)
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        switch self {
        case let .timed(startsAt, endsAt, timeZoneIdentifier, originalTimeZone):
            try container.encode(Kind.timed, forKey: .kind)
            try container.encode(startsAt, forKey: .startsAt)
            try container.encode(endsAt, forKey: .endsAt)
            try container.encodeIfPresent(timeZoneIdentifier, forKey: .timeZone)
            try container.encodeIfPresent(originalTimeZone, forKey: .originalTimeZone)
        case let .allDay(startDate, endDateExclusive, timeZoneIdentifier):
            try container.encode(Kind.allDay, forKey: .kind)
            try container.encode(Self.dateOnlyFormatter.string(from: startDate), forKey: .startDate)
            try container.encode(Self.dateOnlyFormatter.string(from: endDateExclusive), forKey: .endDateExclusive)
            try container.encodeIfPresent(timeZoneIdentifier, forKey: .timeZone)
        }
    }

    private static func decodeDateOnly(_ value: String, codingPath: [CodingKey]) throws -> Date {
        guard let date = dateOnlyFormatter.date(from: value) else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: codingPath,
                    debugDescription: "Expected an ISO 8601 date in YYYY-MM-DD format."
                )
            )
        }
        return date
    }

    private static let dateOnlyFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}

nonisolated struct StarCitizenEventLocation: Codable, Hashable, Sendable {
    let isOnline: Bool
    let name: String?
    let city: String?
    let region: String?
    let countryCode: String?
    let formattedAddress: String?

    init(
        isOnline: Bool,
        name: String? = nil,
        city: String? = nil,
        region: String? = nil,
        countryCode: String? = nil,
        formattedAddress: String? = nil
    ) {
        self.isOnline = isOnline
        self.name = name
        self.city = city
        self.region = region
        self.countryCode = countryCode
        self.formattedAddress = formattedAddress
    }

    var displayName: String {
        if isOnline {
            return name ?? AppLocalizer.string("Online")
        }
        return name ?? formattedAddress ?? city ?? AppLocalizer.string("Location unavailable")
    }
}

nonisolated struct StarCitizenEventLink: Codable, Hashable, Sendable {
    let role: String
    let label: String
    let url: URL
}
