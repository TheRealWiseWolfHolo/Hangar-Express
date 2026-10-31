import SwiftUI

struct ReferralRewardsView: View {
    let appModel: AppModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(AppLanguage.storageKey) private var language = AppLanguage.system.rawValue
    @State private var ladder = ReferralLadder.current
    @State private var catalog: ReferralRewardsCatalog?
    @State private var isLoading = true
    @State private var failed = false
    @State private var selectedReward: ReferralRewardDestination?
    @State private var openingRewardID: Int?
    @State private var openingTask: Task<Void, Never>?
    @State private var rewardDetailMessage: String?
    @State private var legacyImageRatios: [URL: Double] = [:]

    private var stats: ReferralStats { appModel.snapshot?.referralStats ?? .unavailable }
    private var count: Int? { ladder.count(in: stats) }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    HStack(spacing: 0) {
                        ForEach(ReferralLadder.allCases) { option in
                            Button { ladder = option } label: {
                                Text(option.title)
                                    .font(.subheadline.weight(.semibold))
                                    .frame(maxWidth: .infinity, minHeight: 44)
                                    .background {
                                        if ladder == option {
                                            Capsule().fill(Color(.tertiarySystemGroupedBackground))
                                        }
                                    }
                                    .padding(4)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("referrals.ladder.\(option.rawValue)")
                            .accessibilityAddTraits(ladder == option ? .isSelected : [])
                        }
                    }
                    .background(Color(.secondarySystemGroupedBackground), in: Capsule())
                    .accessibilityLabel(AppLocalizer.string("Referral Ladder"))
                    summary
                    if let catalog {
                        ForEach(catalog.rewards(for: ladder)) { reward in
                            if let count, count >= reward.threshold {
                                Button { openReward(reward) } label: {
                                    rewardCard(reward).contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .disabled(openingRewardID != nil)
                                .accessibilityHint(AppLocalizer.string("View matching item in Hangar"))
                            } else {
                                rewardCard(reward)
                            }
                        }
                        Text(AppLocalizer.string("Rewards shown are from RSI's referral program. Your progress updates with Refresh Account."))
                            .font(.footnote).foregroundStyle(.secondary)
                    } else if isLoading {
                        ProgressView().frame(maxWidth: .infinity).padding()
                    } else if failed {
                        ContentUnavailableView {
                            Label(AppLocalizer.string("Unable to Load Rewards"), systemImage: "wifi.exclamationmark")
                        } description: {
                            Text(AppLocalizer.string("Check your connection and try again."))
                        } actions: {
                            Button(AppLocalizer.string("Try Again")) { Task { await load() } }
                        }
                    }
                }
                .padding()
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle(AppLocalizer.string("Referrals"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button(AppLocalizer.string("Done")) { dismiss() } } }
            .task { await load() }
            .navigationDestination(item: $selectedReward) { selection in
                ReferralRewardDestinationView(selection: selection, appModel: appModel)
            }
            .alert(AppLocalizer.string("Hangar item unavailable"), isPresented: Binding(
                get: { rewardDetailMessage != nil }, set: { if !$0 { rewardDetailMessage = nil } })) {
                Button(AppLocalizer.string("OK"), role: .cancel) { rewardDetailMessage = nil }
            } message: {
                Text(rewardDetailMessage ?? "")
            }
            .onChange(of: ladder) { _, _ in
                cancelOpeningReward(); selectedReward = nil; rewardDetailMessage = nil
            }
            .onChange(of: appModel.readyInventoryPresentation?.identity) { _, _ in
                cancelOpeningReward(); selectedReward = nil
            }
            .onDisappear { cancelOpeningReward() }
            .onChange(of: appModel.authenticationFlowID) { _, _ in dismiss() }
            .onChange(of: appModel.session?.id) { _, _ in dismiss() }
            .id(language)
        }
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let count {
                Text(AppLocalizer.format(count == 1 ? "%lld referral" : "%lld referrals", count)).font(.title2.bold())
                    .accessibilityIdentifier("referrals.count")
                if let rewards = catalog?.rewards(for: ladder), let next = rewards.first(where: { $0.threshold > count }) {
                    Text(AppLocalizer.format("%lld more to the next reward", next.threshold - count)).foregroundStyle(.secondary)
                    ProgressView(value: Double(count), total: Double(next.threshold)).tint(.blue)
                } else if catalog != nil {
                    Text(AppLocalizer.string("All milestones reached")).foregroundStyle(.secondary)
                }
            } else if ladder == .legacy && !stats.hasLegacyLadder {
                Text(AppLocalizer.string("View Only")).font(.headline)
                Text(AppLocalizer.string("The legacy ladder is not available for this account. You can still browse its rewards."))
                    .font(.subheadline).foregroundStyle(.secondary)
            } else {
                Text(AppLocalizer.string("Referral count unavailable")).font(.headline)
                Text(AppLocalizer.string("Use Refresh Account to update your referral progress."))
                    .font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding()
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20))
    }

    private func rewardCard(_ reward: ReferralReward) -> some View {
        let reached = count.map { $0 >= reward.threshold } ?? false
        let surface = reached ? reachedSurface : Color(.secondarySystemGroupedBackground)

        return VStack(alignment: .leading, spacing: 0) {
            rewardImage(reward)
                .aspectRatio(ladder == .legacy ? (legacyImageRatios[reward.imageURL] ?? reward.imageAspectRatio ?? (16.0 / 9.0)) : (reward.imageAspectRatio ?? (16.0 / 9.0)), contentMode: .fit)

            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 10) {
                    Text(reward.title)
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                    if reached {
                        Spacer(minLength: 0)
                        if openingRewardID == reward.id { ProgressView().controlSize(.small) }
                        else { Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(reachedAccent) }
                    }
                }
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(AppLocalizer.format(reward.threshold == 1 ? "%lld referral" : "%lld referrals", reward.threshold))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(reached ? reachedAccent : Color.secondary)
                    Spacer(minLength: 0)
                    if count != nil {
                        Label(AppLocalizer.string(reached ? "Milestone Reached" : "Not Yet Reached"),
                              systemImage: reached ? "checkmark.circle.fill" : "lock")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(reached ? reachedAccent : Color.secondary)
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(surface)
        }
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.07), lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("referrals.reward.\(ladder.rawValue).\(reward.threshold)")
    }

    private var reachedSurface: Color {
        colorScheme == .dark
            ? Color(red: 0.055, green: 0.25, blue: 0.16)
            : Color(red: 0.80, green: 0.94, blue: 0.85)
    }

    private var reachedAccent: Color {
        colorScheme == .dark
            ? Color(red: 0.48, green: 0.93, blue: 0.64)
            : Color(red: 0.06, green: 0.38, blue: 0.21)
    }

    private func rewardImage(_ reward: ReferralReward) -> some View {
        GeometryReader { geometry in
            artwork(reward)
                .frame(width: geometry.size.width, height: geometry.size.height)
                .clipped()
        }
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func artwork(_ reward: ReferralReward) -> some View {
        #if DEBUG || HANGAR_BENCHMARKS
        if ReferralRewardsBenchmark.enabled {
            if let image = ReferralRewardsBenchmark.artwork(for: reward, ladder: ladder) {
                Image(uiImage: image).resizable().aspectRatio(contentMode: ladder == .legacy ? .fit : .fill)
                    .task(id: reward.imageURL) { recordLegacyImageSize(image.size, for: reward) }
            } else {
                Image(systemName: "gift.fill").font(.largeTitle).foregroundStyle(.blue)
            }
        } else {
            remoteImage(reward)
        }
        #else
        remoteImage(reward)
        #endif
    }

    private func remoteImage(_ reward: ReferralReward) -> some View {
        CachedRemoteImage(
            url: reward.imageURL,
            targetSize: CGSize(width: 480, height: 270),
            onImageSize: ladder == .legacy ? { recordLegacyImageSize($0, for: reward) } : nil
        ) { phase in
            switch phase {
            case .success(let image): image.resizable().aspectRatio(contentMode: ladder == .legacy ? .fit : .fill)
            case .empty: ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failure: Image(systemName: "photo").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func recordLegacyImageSize(_ size: CGSize, for reward: ReferralReward) {
        guard ladder == .legacy, size.width > 0, size.height > 0 else { return }
        let ratio = Double(size.width / size.height)
        guard ratio.isFinite, legacyImageRatios[reward.imageURL] != ratio else { return }
        legacyImageRatios[reward.imageURL] = ratio
    }

    private func cancelOpeningReward() {
        openingTask?.cancel(); openingTask = nil; openingRewardID = nil
    }

    private func openReward(_ reward: ReferralReward) {
        guard let count, count >= reward.threshold, openingRewardID == nil else { return }
        guard let presentation = appModel.readyInventoryPresentation else {
            rewardDetailMessage = AppLocalizer.string("Your saved Hangar is being prepared. Try again in a moment, or refresh Hangar if it has not been loaded yet.")
            return
        }
        let identity = presentation.identity
        let requestedLadder = ladder
        openingRewardID = reward.id
        openingTask = Task {
            defer { if !Task.isCancelled { openingRewardID = nil; openingTask = nil } }
            do {
                let matches = try await ReferralRewardPackageMatcher.shared.matches(reward: reward,
                    ladder: requestedLadder, groups: presentation.packages)
                try Task.checkCancellation()
                guard ladder == requestedLadder, appModel.readyInventoryPresentation?.identity == identity else { return }
                if matches.isEmpty {
                    rewardDetailMessage = AppLocalizer.string("This milestone is reached, but its reward was not found in your saved Hangar. Refresh Hangar and try again.")
                } else {
                    selectedReward = ReferralRewardDestination(title: reward.title, groups: matches)
                }
            } catch { /* Cancelled on account, inventory, navigation or ladder changes. */ }
        }
    }

    private func load() async {
        #if DEBUG || HANGAR_BENCHMARKS
        if ReferralRewardsBenchmark.enabled {
            catalog = ReferralRewardsBenchmark.catalog; isLoading = false; return
        }
        #endif
        isLoading = true; failed = false
        defer { isLoading = false }
        do { catalog = try await HostedReferralRewardsClient.shared.load() }
        catch { if !Task.isCancelled { failed = true } }
    }
}
