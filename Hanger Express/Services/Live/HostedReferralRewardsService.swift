import Foundation

actor HostedReferralRewardsClient {
    static let shared = HostedReferralRewardsClient()
    private let store: ValidatedHostedFeedStore<ReferralRewardsCatalog>
    private let urls: [URL]
    private let session: URLSession

    init(urls: [URL] = HostedShipFeedEndpoints.referralRewardsURLs, session: URLSession = .shared, directory: URL? = nil) {
        self.urls = urls
        self.session = session
        let root = directory ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("HangarExpress/referral-rewards", isDirectory: true)
        store = ValidatedHostedFeedStore(directory: root, freshness: 86_400, maximumStaleAge: 365 * 86_400)
    }

    func load() async throws -> ReferralRewardsCatalog {
        try await store.load(urls: urls, session: session, decode: ReferralRewardsCatalog.decode)
    }
}
