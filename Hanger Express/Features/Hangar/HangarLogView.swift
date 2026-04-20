import SwiftUI

struct HangarLogView: View {
    private let entryBatchSize = 100

    private enum TimeFilter: String, CaseIterable, Identifiable {
        case all = "All Time"
        case last30Days = "30 Days"
        case last90Days = "90 Days"
        case lastYear = "1 Year"

        var id: Self { self }
    }

    private enum ActionFilter: Hashable, Identifiable {
        case all
        case action(HangarLogAction)

        var id: String {
            switch self {
            case .all:
                return "all"
            case let .action(action):
                return action.rawValue
            }
        }

        var title: String {
            switch self {
            case .all:
                return "All Actions"
            case let .action(action):
                return action.title
            }
        }

        static var allCases: [ActionFilter] {
            [.all] + HangarLogAction.allCases.map(Self.action)
        }
    }

    let appModel: AppModel

    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""
    @State private var timeFilter: TimeFilter = .all
    @State private var actionFilter: ActionFilter = .all
    @State private var didAttemptInitialLoad = false
    @State private var visibleEntryCount = 100

    private var hangarLogs: [HangarLogEntry] {
        appModel.snapshot?.hangarLogs ?? []
    }

    private var filteredHangarLogs: [HangarLogEntry] {
        hangarLogs.filter { entry in
            matchesTimeFilter(entry) && matchesActionFilter(entry) && matchesSearch(entry)
        }
    }

    private var displayedHangarLogs: [HangarLogEntry] {
        Array(filteredHangarLogs.prefix(visibleEntryCount))
    }

    private var hasHiddenResults: Bool {
        filteredHangarLogs.count > displayedHangarLogs.count
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 12) {
                        Menu {
                            Picker("Action", selection: $actionFilter) {
                                ForEach(ActionFilter.allCases) { filter in
                                    Text(filter.title).tag(filter)
                                }
                            }
                        } label: {
                            filterChip(
                                title: actionFilter.title,
                                systemImage: "line.3.horizontal.decrease.circle"
                            )
                        }

                        Menu {
                            Picker("Time", selection: $timeFilter) {
                                ForEach(TimeFilter.allCases) { filter in
                                    Text(filter.rawValue).tag(filter)
                                }
                            }
                        } label: {
                            filterChip(
                                title: timeFilter.rawValue,
                                systemImage: "calendar"
                            )
                        }

                        Spacer()

                        Text("\(filteredHangarLogs.count)")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                } footer: {
                    Text("Search items, pledge IDs, orders, or raw log text. Filters can narrow results by action and time window.")
                }

                if appModel.isRefreshing(.hangarLog), hangarLogs.isEmpty {
                    Section {
                        VStack(alignment: .leading, spacing: 12) {
                            ProgressView()
                            Text("Loading your RSI hangar log.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 12)
                    }
                } else if filteredHangarLogs.isEmpty {
                    Section {
                        ContentUnavailableView(
                            "No Log Entries",
                            systemImage: "doc.text.magnifyingglass",
                            description: Text(emptyStateDescription)
                        )
                    }
                } else {
                    Section {
                        ForEach(displayedHangarLogs) { entry in
                            HangarLogRow(entry: entry)
                                .onAppear {
                                    loadMoreIfNeeded(currentEntry: entry)
                                }
                        }
                    }

                    if hasHiddenResults {
                        Section {
                            VStack(alignment: .leading, spacing: 12) {
                                Text("Showing \(displayedHangarLogs.count) of \(filteredHangarLogs.count) log entries.")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)

                                HStack(spacing: 12) {
                                    Button("Load More") {
                                        revealNextBatch()
                                    }
                                    .buttonStyle(.bordered)

                                    Button("Load All") {
                                        visibleEntryCount = filteredHangarLogs.count
                                    }
                                    .buttonStyle(.borderedProminent)

                                    Spacer()
                                }
                            }
                            .padding(.vertical, 6)
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .searchable(
                text: $searchText,
                prompt: "Search log entries"
            )
            .navigationTitle("Hangar Log")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .topBarTrailing) {
                    Button(appModel.isRefreshing(.hangarLog) ? "Refreshing..." : "Refresh") {
                        Task {
                            await appModel.refresh(scope: .hangarLog)
                        }
                    }
                    .disabled(appModel.isRefreshing)
                }
            }
            .task {
                guard !didAttemptInitialLoad else {
                    return
                }

                didAttemptInitialLoad = true
                resetVisibleEntryCount()
                guard hangarLogs.isEmpty else {
                    return
                }

                await appModel.refresh(scope: .hangarLog)
            }
            .onChange(of: searchText) { _, _ in
                resetVisibleEntryCount()
            }
            .onChange(of: timeFilter) { _, _ in
                resetVisibleEntryCount()
            }
            .onChange(of: actionFilter) { _, _ in
                resetVisibleEntryCount()
            }
        }
    }

    private var emptyStateDescription: String {
        if !hangarLogs.isEmpty {
            return "Try adjusting the search text or filters."
        }

        return "Open the log again after a refresh, or pull a fresh copy from RSI with the Refresh button."
    }

    @ViewBuilder
    private func filterChip(title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .font(.subheadline.weight(.medium))
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .foregroundStyle(Color.accentColor)
            .background(
                Capsule(style: .continuous)
                    .fill(Color.accentColor.opacity(0.12))
            )
    }

    private func matchesSearch(_ entry: HangarLogEntry) -> Bool {
        guard !searchText.isEmpty else {
            return true
        }

        return entry.searchableText.localizedLowercase.contains(searchText.localizedLowercase)
    }

    private func matchesActionFilter(_ entry: HangarLogEntry) -> Bool {
        switch actionFilter {
        case .all:
            return true
        case let .action(action):
            return entry.action == action
        }
    }

    private func matchesTimeFilter(_ entry: HangarLogEntry) -> Bool {
        guard let thresholdDate = thresholdDate(for: timeFilter) else {
            return true
        }

        return entry.occurredAt >= thresholdDate
    }

    private func thresholdDate(for filter: TimeFilter) -> Date? {
        switch filter {
        case .all:
            return nil
        case .last30Days:
            return Calendar.current.date(byAdding: .day, value: -30, to: .now)
        case .last90Days:
            return Calendar.current.date(byAdding: .day, value: -90, to: .now)
        case .lastYear:
            return Calendar.current.date(byAdding: .year, value: -1, to: .now)
        }
    }

    private func resetVisibleEntryCount() {
        visibleEntryCount = min(entryBatchSize, filteredHangarLogs.count)
    }

    private func loadMoreIfNeeded(currentEntry: HangarLogEntry) {
        guard hasHiddenResults else {
            return
        }

        let trailingEntries = displayedHangarLogs.suffix(8)
        guard trailingEntries.contains(where: { $0.id == currentEntry.id }) else {
            return
        }

        revealNextBatch()
    }

    private func revealNextBatch() {
        visibleEntryCount = min(visibleEntryCount + entryBatchSize, filteredHangarLogs.count)
    }
}

private struct HangarLogRow: View {
    let entry: HangarLogEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(entry.itemName)
                        .font(.headline)

                    Text(entry.occurredAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Text(entry.actionTitle)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        Capsule(style: .continuous)
                            .fill(Color.accentColor.opacity(0.12))
                    )
            }

            if let summary = summaryText {
                Text(summary)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            if let metadata = metadataText {
                Text(metadata)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 6)
    }

    private var summaryText: String? {
        switch entry.action {
        case .created:
            var parts: [String] = []
            if let operatorName = entry.operatorName {
                parts.append("Created by \(operatorName)")
            }
            if let orderCode = entry.orderCode {
                parts.append("Order #\(orderCode)")
            }
            if let priceUSD = entry.priceUSD {
                parts.append(priceUSD.usdString)
            }
            return joined(parts)
        case .reclaimed:
            var parts: [String] = []
            if let operatorName = entry.operatorName {
                parts.append("Melted by \(operatorName)")
            }
            if let priceUSD = entry.priceUSD {
                parts.append(priceUSD.usdString)
            }
            return joined(parts)
        case .consumed:
            var parts: [String] = []
            if let sourcePledgeID = entry.sourcePledgeID {
                parts.append("Consumed on pledge #\(sourcePledgeID)")
            }
            if let priceUSD = entry.priceUSD {
                parts.append(priceUSD.usdString)
            }
            return joined(parts)
        case .appliedUpgrade:
            var parts: [String] = []
            if let sourcePledgeID = entry.sourcePledgeID {
                parts.append("Upgrade from pledge #\(sourcePledgeID)")
            }
            if let reason = entry.reason {
                parts.append(reason)
            }
            if let priceUSD = entry.priceUSD {
                parts.append("New value \(priceUSD.usdString)")
            }
            return joined(parts)
        case .buyback:
            var parts: [String] = []
            if let operatorName = entry.operatorName {
                parts.append("Bought back by \(operatorName)")
            }
            if let orderCode = entry.orderCode {
                parts.append("Order #\(orderCode)")
            }
            return joined(parts)
        case .gift:
            var parts: [String] = []
            if let operatorName = entry.operatorName {
                parts.append("Gifted to \(operatorName)")
            }
            if let priceUSD = entry.priceUSD {
                parts.append(priceUSD.usdString)
            }
            return joined(parts)
        case .giftClaimed:
            var parts: [String] = []
            if let operatorName = entry.operatorName {
                parts.append("Claimed by \(operatorName)")
            }
            if let priceUSD = entry.priceUSD {
                parts.append(priceUSD.usdString)
            }
            return joined(parts)
        case .giftCancelled:
            var parts: [String] = []
            if let operatorName = entry.operatorName {
                parts.append("Cancelled by \(operatorName)")
            }
            if let priceUSD = entry.priceUSD {
                parts.append(priceUSD.usdString)
            }
            return joined(parts)
        case .nameChange, .nameChangeReclaimed, .giveaway, .unknown:
            return entry.reason ?? entry.rawText
        }
    }

    private var metadataText: String? {
        let parts = [
            entry.targetPledgeID.map { "Target #\($0)" },
            entry.sourcePledgeID.map { "Source #\($0)" }
        ]
        .compactMap { $0 }

        return parts.isEmpty ? nil : parts.joined(separator: " • ")
    }

    private func joined(_ parts: [String]) -> String? {
        let filteredParts = parts.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        return filteredParts.isEmpty ? nil : filteredParts.joined(separator: " • ")
    }
}
