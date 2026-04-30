import Foundation

enum CurrencyFormatter {
    static let usd: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = "USD"
        formatter.maximumFractionDigits = 0
        return formatter
    }()
}

extension Decimal {
    var usdString: String {
        CurrencyFormatter.usd.string(from: NSDecimalNumber(decimal: self)) ?? "$0"
    }
}
