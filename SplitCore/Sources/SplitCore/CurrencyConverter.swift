import Foundation

/// Offline currency conversion. Splitwise charges for this; we ship a bundled
/// snapshot of rates (editable by the user per-expense) so it works with no
/// network and no server. Rates are expressed as USD → currency.
public struct CurrencyConverter: Sendable {
    public private(set) var usdRates: [String: Decimal]

    /// Approximate mid-market snapshot; the UI lets users override per expense.
    public static let bundledSnapshot = CurrencyConverter(usdRates: [
        "USD": 1, "EUR": 0.92, "GBP": 0.79, "JPY": 155, "CAD": 1.37,
        "AUD": 1.51, "INR": 84, "MXN": 18.2, "BRL": 5.6, "CHF": 0.88,
        "CNY": 7.25, "KRW": 1380, "SEK": 10.5, "NOK": 10.7, "DKK": 6.9,
        "NZD": 1.65, "SGD": 1.34, "HKD": 7.8, "THB": 34.5, "VND": 25400,
        "PHP": 58, "IDR": 16200, "TRY": 34, "ZAR": 18, "AED": 3.67,
        "SAR": 3.75, "ILS": 3.7, "PLN": 3.9, "CZK": 23, "HUF": 360
    ])

    public init(usdRates: [String: Decimal]) {
        self.usdRates = usdRates
    }

    public var supportedCurrencies: [String] {
        usdRates.keys.sorted()
    }

    /// Converts using USD as the pivot. Returns nil when a rate is unknown.
    public func convert(_ money: Money, to targetCode: String) -> Money? {
        if money.currencyCode == targetCode { return money }
        guard let fromRate = usdRates[money.currencyCode],
              let toRate = usdRates[targetCode],
              fromRate > 0 else { return nil }
        let usdValue = money.decimalValue / fromRate
        return Money(usdValue * toRate, currencyCode: targetCode)
    }

    public mutating func setRate(_ rate: Decimal, for code: String) {
        usdRates[code] = rate
    }
}
