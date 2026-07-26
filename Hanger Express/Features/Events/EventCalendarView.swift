import EventKit
import SafariServices
import SwiftUI
import UIKit

struct EventCalendarView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var feed: EventCalendarFeed?
    @State private var isLoading = true
    @State private var isRefreshing = false
    @State private var errorMessage: String?
    @State private var searchText = ""
    @State private var selectedCategory = EventCalendarFilter.all
    @State private var selectedCountryCode: String?
    @State private var selectedEvent: StarCitizenEvent?
    @State private var showsPastEvents = false

    private let client = HostedEventCalendarClient()

    var body: some View {
        NavigationStack {
            Group {
                if let feed {
                    calendarContent(feed)
                } else if isLoading {
                    ProgressView("Loading events...")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ContentUnavailableView {
                        Label("Unable to Load Events", systemImage: "calendar.badge.exclamationmark")
                    } description: {
                        Text(errorMessage ?? AppLocalizer.string("The event calendar is unavailable."))
                    } actions: {
                        Button("Try Again") {
                            Task { await refresh() }
                        }
                    }
                }
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Event Calendar")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $searchText, prompt: "Search events, cities, countries")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        Task { await refresh() }
                    } label: {
                        if isRefreshing {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                    .disabled(isRefreshing)
                    .accessibilityLabel("Refresh event calendar")
                }

                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
            .task {
                await load()
            }
            .sheet(item: $selectedEvent) { event in
                EventCalendarDetailView(event: event)
            }
        }
    }

    private func calendarContent(_ feed: EventCalendarFeed) -> some View {
        let visibleEvents = filteredEvents(in: feed)
        let upcomingEvents = visibleEvents.filter { !$0.hasEnded() }
        let pastEvents = visibleEvents.filter { $0.hasEnded() }.reversed()

        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                filterBar(for: feed)

                if let nextEvent = upcomingEvents.first {
                    EventCalendarHeroCard(event: nextEvent) {
                        selectedEvent = nextEvent
                    }
                }

                if upcomingEvents.isEmpty {
                    ContentUnavailableView(
                        "No Matching Events",
                        systemImage: "calendar",
                        description: Text("Try another category, location, or search.")
                    )
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 32)
                } else {
                    eventGroups(Array(upcomingEvents), heading: "Upcoming")
                }

                if !pastEvents.isEmpty {
                    DisclosureGroup(isExpanded: $showsPastEvents) {
                        eventGroups(Array(pastEvents), heading: nil)
                            .padding(.top, 10)
                    } label: {
                        Label("Past Events", systemImage: "clock.arrow.circlepath")
                            .font(.headline)
                    }
                    .padding(16)
                    .background(
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .fill(Color(.secondarySystemGroupedBackground))
                    )
                }

                HStack(spacing: 6) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                    Text(AppLocalizer.format("Updated %@", AppLocalizer.displayDateTime(feed.generatedAt)))
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            }
            .padding(16)
        }
        .refreshable {
            await refresh()
        }
    }

    private func filterBar(for feed: EventCalendarFeed) -> some View {
        VStack(spacing: 12) {
            Picker("Event Type", selection: $selectedCategory) {
                ForEach(EventCalendarFilter.allCases) { filter in
                    Text(filter.title).tag(filter)
                }
            }
            .pickerStyle(.segmented)

            if !countryCodes(in: feed).isEmpty {
                Menu {
                    Button("All Locations") {
                        selectedCountryCode = nil
                    }
                    ForEach(countryCodes(in: feed), id: \.self) { countryCode in
                        Button(countryName(for: countryCode)) {
                            selectedCountryCode = countryCode
                        }
                    }
                } label: {
                    Label(
                        selectedCountryCode.map(countryName(for:)) ?? AppLocalizer.string("All Locations"),
                        systemImage: "mappin.and.ellipse"
                    )
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color(.tertiarySystemGroupedBackground))
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder
    private func eventGroups(_ events: [StarCitizenEvent], heading: String?) -> some View {
        let groups = Dictionary(grouping: events) {
            Calendar.current.startOfDay(for: $0.startsAt)
        }
        let dates = groups.keys.sorted()

        VStack(alignment: .leading, spacing: 12) {
            if let heading {
                Text(AppLocalizer.string(heading))
                    .font(.title3.bold())
                    .padding(.horizontal, 2)
            }

            ForEach(dates, id: \.self) { date in
                VStack(alignment: .leading, spacing: 10) {
                    Text(EventCalendarFormatting.sectionDate(date))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4)

                    VStack(spacing: 0) {
                        ForEach(groups[date] ?? []) { event in
                            Button {
                                selectedEvent = event
                            } label: {
                                EventCalendarRow(event: event)
                            }
                            .buttonStyle(.plain)

                            if event.id != groups[date]?.last?.id {
                                Divider()
                                    .padding(.leading, 80)
                            }
                        }
                    }
                    .background(
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .fill(Color(.secondarySystemGroupedBackground))
                    )
                }
            }
        }
    }

    private func filteredEvents(in feed: EventCalendarFeed) -> [StarCitizenEvent] {
        feed.events
            .filter { event in
                selectedCategory.includes(event)
                    && event.matches(searchText: searchText)
                    && (selectedCountryCode == nil || event.location.countryCode == selectedCountryCode)
                    && event.status != .cancelled
            }
            .sorted { left, right in
                left.startsAt == right.startsAt
                    ? left.title.localizedCaseInsensitiveCompare(right.title) == .orderedAscending
                    : left.startsAt < right.startsAt
            }
    }

    private func countryCodes(in feed: EventCalendarFeed) -> [String] {
        Array(Set(feed.events.compactMap(\.location.countryCode))).sorted {
            countryName(for: $0).localizedCaseInsensitiveCompare(countryName(for: $1)) == .orderedAscending
        }
    }

    private func countryName(for countryCode: String) -> String {
        Locale.current.localizedString(forRegionCode: countryCode) ?? countryCode
    }

    @MainActor
    private func load() async {
        if let cachedFeed = await client.cachedFeed() {
            feed = cachedFeed
            isLoading = false
        }
        await refresh()
    }

    @MainActor
    private func refresh() async {
        guard !isRefreshing else {
            return
        }
        isRefreshing = true
        defer {
            isRefreshing = false
            isLoading = false
        }

        do {
            feed = try await client.refresh()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private enum EventCalendarFilter: String, CaseIterable, Identifiable {
    case all
    case official
    case barCitizen

    var id: Self { self }

    var title: String {
        switch self {
        case .all:
            return AppLocalizer.string("All")
        case .official:
            return AppLocalizer.string("Official")
        case .barCitizen:
            return AppLocalizer.string("Bar Citizen")
        }
    }

    func includes(_ event: StarCitizenEvent) -> Bool {
        switch self {
        case .all:
            return true
        case .official:
            return event.category == .official
        case .barCitizen:
            return event.category == .barCitizen
        }
    }
}

private struct EventCalendarHeroCard: View {
    let event: StarCitizenEvent
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Label("Next Event", systemImage: "sparkles")
                        .font(.caption.weight(.bold))
                        .textCase(.uppercase)
                        .foregroundStyle(.white.opacity(0.86))

                    Spacer()

                    HStack(spacing: 6) {
                        if event.isAnticipated {
                            EventDateConfidenceBadge(inverted: true)
                        }
                        EventCategoryBadge(category: event.category, inverted: true)
                    }
                }

                Text(event.displayTitle)
                    .font(.title2.bold())
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.leading)

                VStack(alignment: .leading, spacing: 7) {
                    Label(EventCalendarFormatting.fullSchedule(event), systemImage: "calendar")
                    Label(event.location.displayName, systemImage: event.location.isOnline ? "network" : "mappin.and.ellipse")
                }
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.white.opacity(0.9))
                .lineLimit(2)
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                LinearGradient(
                    colors: [Color.accentColor, Color.accentColor.opacity(0.62)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                in: RoundedRectangle(cornerRadius: 24, style: .continuous)
            )
            .overlay(alignment: .bottomTrailing) {
                Image(systemName: "calendar.badge.clock")
                    .font(.system(size: 74, weight: .light))
                    .foregroundStyle(.white.opacity(0.12))
                    .padding(12)
            }
        }
        .buttonStyle(.plain)
        .accessibilityHint("Shows event details")
    }
}

private struct EventCalendarRow: View {
    let event: StarCitizenEvent

    var body: some View {
        HStack(spacing: 14) {
            VStack(spacing: 1) {
                Text(EventCalendarFormatting.month(event.startsAt))
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(categoryColor)
                Text(EventCalendarFormatting.day(event.startsAt))
                    .font(.title3.bold())
            }
            .frame(width: 48, height: 52)
            .background(categoryColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 13, style: .continuous))

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(event.displayTitle)
                        .font(.headline)
                        .lineLimit(2)

                    if event.status == .postponed {
                        Text("Postponed")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.orange)
                    }
                }

                HStack(spacing: 6) {
                    Text(EventCalendarFormatting.compactSchedule(event))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    if event.isAnticipated {
                        EventDateConfidenceBadge()
                    }
                }

                Label(
                    event.location.displayName,
                    systemImage: event.location.isOnline ? "network" : "mappin"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }

            Spacer(minLength: 6)

            Image(systemName: "chevron.right")
                .font(.caption.weight(.bold))
                .foregroundStyle(.tertiary)
        }
        .padding(14)
        .contentShape(Rectangle())
    }

    private var categoryColor: Color {
        event.category == .official ? .blue : .purple
    }
}

private struct EventCategoryBadge: View {
    let category: StarCitizenEvent.Category
    var inverted = false

    var body: some View {
        Text(category == .official ? "Official" : "Bar Citizen")
            .font(.caption2.weight(.bold))
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .foregroundStyle(inverted ? .white : badgeColor)
            .background(
                (inverted ? Color.white.opacity(0.18) : badgeColor.opacity(0.12)),
                in: Capsule()
            )
    }

    private var badgeColor: Color {
        category == .official ? .blue : .purple
    }
}

private struct EventDateConfidenceBadge: View {
    var inverted = false

    var body: some View {
        Text("Anticipated Date")
            .font(.caption2.weight(.bold))
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .foregroundStyle(inverted ? .white : .orange)
            .background(
                (inverted ? Color.white.opacity(0.18) : Color.orange.opacity(0.14)),
                in: Capsule()
            )
    }
}

private struct EventCalendarDetailView: View {
    let event: StarCitizenEvent

    @Environment(\.dismiss) private var dismiss
    @State private var webPage: EventCalendarWebPage?
    @State private var calendarMessage: String?
    @State private var isSavingToCalendar = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 12) {
                        EventCategoryBadge(category: event.category)

                        Text(event.displayTitle)
                            .font(.title.bold())

                        Label(EventCalendarFormatting.fullSchedule(event), systemImage: "calendar")
                        Label(event.location.displayName, systemImage: event.location.isOnline ? "network" : "mappin.and.ellipse")

                        if event.isAnticipated {
                            VStack(alignment: .leading, spacing: 6) {
                                EventDateConfidenceBadge()
                                Text("Based on last year’s official dates. CIG has not confirmed this date.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }

                        if let originalTimeZone = event.schedule.originalTimeZone,
                           !originalTimeZone.isEmpty {
                            Label(
                                AppLocalizer.format("Source time zone: %@", originalTimeZone),
                                systemImage: "globe"
                            )
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(20)
                    .background(
                        RoundedRectangle(cornerRadius: 24, style: .continuous)
                            .fill(Color(.secondarySystemGroupedBackground))
                    )

                    if !event.summary.isEmpty {
                        Text(event.summary)
                            .font(.body)
                            .foregroundStyle(.secondary)
                    }

                    HStack(spacing: 12) {
                        Button {
                            Task { await addToCalendar() }
                        } label: {
                            Label(
                                isSavingToCalendar ? "Adding..." : "Add to Calendar",
                                systemImage: "calendar.badge.plus"
                            )
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(isSavingToCalendar)

                        ShareLink(item: event.sourceURL ?? URL(string: "https://starcitizen-info.pages.dev/events.json")!) {
                            Image(systemName: "square.and.arrow.up")
                                .frame(width: 44, height: 44)
                        }
                        .buttonStyle(.bordered)
                        .accessibilityLabel("Share event")
                    }

                    if let sourceURL = event.sourceURL {
                        Button {
                            webPage = EventCalendarWebPage(url: sourceURL)
                        } label: {
                            HStack {
                                Label(
                                    event.category == .barCitizen ? "Event Details & RSVP" : "Official Source",
                                    systemImage: "safari"
                                )
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.caption.weight(.bold))
                            }
                            .padding(16)
                            .background(
                                RoundedRectangle(cornerRadius: 16, style: .continuous)
                                    .fill(Color(.secondarySystemGroupedBackground))
                            )
                        }
                        .buttonStyle(.plain)
                    }

                    Text(AppLocalizer.format(
                        "Verified %@",
                        AppLocalizer.displayDateTime(event.lastVerifiedAt)
                    ))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity)
                }
                .padding(16)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Event Details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
            .sheet(item: $webPage) { page in
                EventCalendarInAppBrowser(url: page.url)
                    .ignoresSafeArea()
            }
            .alert("Calendar", isPresented: Binding(
                get: { calendarMessage != nil },
                set: { if !$0 { calendarMessage = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(calendarMessage ?? "")
            }
        }
    }

    @MainActor
    private func addToCalendar() async {
        guard !isSavingToCalendar else {
            return
        }
        isSavingToCalendar = true
        defer { isSavingToCalendar = false }

        do {
            let store = EKEventStore()
            guard try await store.requestWriteOnlyAccessToEvents() else {
                calendarMessage = AppLocalizer.string("Calendar access was not granted.")
                return
            }

            let calendarEvent = EKEvent(eventStore: store)
            calendarEvent.title = event.isAnticipated
                ? AppLocalizer.format("%@ — Anticipated Date", event.displayTitle)
                : event.displayTitle
            calendarEvent.startDate = event.startsAt
            calendarEvent.endDate = event.endsAt
            calendarEvent.isAllDay = event.schedule.isAllDay
            calendarEvent.location = event.location.formattedAddress ?? event.location.name
            calendarEvent.notes = event.isAnticipated
                ? "\(AppLocalizer.string("Based on last year’s official dates. CIG has not confirmed this date."))\n\n\(event.summary)"
                : event.summary
            calendarEvent.url = event.sourceURL
            calendarEvent.calendar = store.defaultCalendarForNewEvents
            try store.save(calendarEvent, span: .thisEvent, commit: true)
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            calendarMessage = AppLocalizer.string("Event added to Calendar.")
        } catch {
            calendarMessage = error.localizedDescription
        }
    }
}

private struct EventCalendarWebPage: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}

private struct EventCalendarInAppBrowser: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        SFSafariViewController(url: url)
    }

    func updateUIViewController(_ uiViewController: SFSafariViewController, context: Context) {}
}

private enum EventCalendarFormatting {
    static func month(_ date: Date) -> String {
        date.formatted(.dateTime.month(.abbreviated).locale(AppLocalizer.currentLocale)).uppercased()
    }

    static func day(_ date: Date) -> String {
        date.formatted(.dateTime.day().locale(AppLocalizer.currentLocale))
    }

    static func sectionDate(_ date: Date) -> String {
        date.formatted(
            .dateTime.weekday(.wide).month(.wide).day().year()
                .locale(AppLocalizer.currentLocale)
        )
    }

    static func compactSchedule(_ event: StarCitizenEvent) -> String {
        if event.schedule.isAllDay {
            return AppLocalizer.string("All day")
        }
        return event.startsAt.formatted(
            .dateTime.hour().minute().locale(AppLocalizer.currentLocale)
        )
    }

    static func fullSchedule(_ event: StarCitizenEvent) -> String {
        if event.schedule.isAllDay {
            let inclusiveEnd = event.endsAt.addingTimeInterval(-1)
            if Calendar.current.isDate(event.startsAt, inSameDayAs: inclusiveEnd) {
                return event.startsAt.formatted(
                    .dateTime.weekday(.abbreviated).month(.wide).day().year()
                        .locale(AppLocalizer.currentLocale)
                )
            }
            return "\(event.startsAt.formatted(.dateTime.month(.abbreviated).day().locale(AppLocalizer.currentLocale))) – \(inclusiveEnd.formatted(.dateTime.month(.abbreviated).day().year().locale(AppLocalizer.currentLocale)))"
        }

        let date = event.startsAt.formatted(
            .dateTime.weekday(.abbreviated).month(.wide).day().year()
                .locale(AppLocalizer.currentLocale)
        )
        let startTime = event.startsAt.formatted(
            .dateTime.hour().minute().locale(AppLocalizer.currentLocale)
        )
        let endTime = event.endsAt.formatted(
            .dateTime.hour().minute().locale(AppLocalizer.currentLocale)
        )
        return "\(date), \(startTime) – \(endTime)"
    }
}
