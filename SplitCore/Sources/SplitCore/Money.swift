import Foundation

/// Money represented in minor units (cents) to avoid floating-point drift.
public struct Money: Hashable, Codable, Comparable, Sendable {
    public var minorUnits: Int
    public var currencyCode: String

    public init(minorUnits: Int, currencyCode: String = "USD") {
        self.minorUnits = minorUnits
        self.currencyCode = currencyCode
    }

    public init(_ decimal: Decimal, currencyCode: String = "USD") {
        let exponent = Money.minorUnitExponent(for: currencyCode)
        let scaled = decimal * pow(Decimal(10), exponent)
        var rounded = Decimal()
        var value = scaled
        NSDecimalRound(&rounded, &value, 0, .bankers)
        self.minorUnits = NSDecimalNumber(decimal: rounded).intValue
        self.currencyCode = currencyCode
    }

    public var decimalValue: Decimal {
        Decimal(minorUnits) / pow(Decimal(10), Money.minorUnitExponent(for: currencyCode))
    }

    public static func minorUnitExponent(for currencyCode: String) -> Int {
        switch currencyCode {
        case "JPY", "KRW", "VND": return 0
        case "BHD", "KWD", "OMR": return 3
        default: return 2
        }
    }

    public func formatted(locale: Locale = .current) -> String {
        decimalValue.formatted(.currency(code: currencyCode).locale(locale))
    }

    public static func < (lhs: Money, rhs: Money) -> Bool {
        lhs.minorUnits < rhs.minorUnits
    }

    public static func + (lhs: Money, rhs: Money) -> Money {
        Money(minorUnits: lhs.minorUnits + rhs.minorUnits, currencyCode: lhs.currencyCode)
    }

    public static func - (lhs: Money, rhs: Money) -> Money {
        Money(minorUnits: lhs.minorUnits - rhs.minorUnits, currencyCode: lhs.currencyCode)
    }
}
