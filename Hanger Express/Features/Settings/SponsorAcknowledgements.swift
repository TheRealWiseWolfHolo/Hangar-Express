import Foundation

struct SponsorAcknowledgement: Identifiable, Hashable, Sendable {
    let name: String
    let contributionCNY: Decimal

    var id: String {
        name
    }
}

enum SponsorDirectory {
    // Keep contribution totals here for internal reference only.
    // The app UI intentionally shows supporter names without donation amounts.
    static let supporters: [SponsorAcknowledgement] = [
        SponsorAcknowledgement(name: "阿狸", contributionCNY: Decimal(string: "1000") ?? .zero),
        SponsorAcknowledgement(name: "BrAhMaJiNg", contributionCNY: Decimal(string: "500") ?? .zero),
        SponsorAcknowledgement(name: "Moiety", contributionCNY: Decimal(string: "666.66") ?? .zero),
        SponsorAcknowledgement(name: "Nekkonyan", contributionCNY: Decimal(string: "30") ?? .zero),
        SponsorAcknowledgement(name: "AJMZBXS", contributionCNY: Decimal(string: "200") ?? .zero),
        SponsorAcknowledgement(name: "baozi3160", contributionCNY: Decimal(string: "66.66") ?? .zero),
        SponsorAcknowledgement(name: "zby005160", contributionCNY: Decimal(string: "88.88") ?? .zero),
        SponsorAcknowledgement(name: "新疆宴全羊馆", contributionCNY: Decimal(string: "52") ?? .zero)
    ]

    static var displayedSponsors: [SponsorAcknowledgement] {
        supporters.sorted { lhs, rhs in
            let amountComparison = NSDecimalNumber(decimal: lhs.contributionCNY)
                .compare(NSDecimalNumber(decimal: rhs.contributionCNY))

            if amountComparison != .orderedSame {
                return amountComparison == .orderedDescending
            }

            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }
}
