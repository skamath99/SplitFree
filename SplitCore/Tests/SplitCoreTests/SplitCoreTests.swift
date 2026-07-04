import XCTest
@testable import SplitCore

final class SplitCalculatorTests: XCTestCase {
    let a = UUID(), b = UUID(), c = UUID()

    func testEqualSplitExactPennies() throws {
        let shares = try SplitCalculator.shares(totalMinorUnits: 1000, mode: .equal, participants: [a, b, c])
        XCTAssertEqual(shares.values.reduce(0, +), 1000)
        XCTAssertEqual(shares.values.sorted(), [333, 333, 334])
    }

    func testEqualSplitEven() throws {
        let shares = try SplitCalculator.shares(totalMinorUnits: 900, mode: .equal, participants: [a, b, c])
        XCTAssertEqual(Set(shares.values), [300])
    }

    func testExactAmountsMustSum() {
        XCTAssertThrowsError(try SplitCalculator.shares(
            totalMinorUnits: 1000, mode: .exactAmounts,
            participants: [a, b], inputs: [a: 400, b: 500]
        )) { error in
            XCTAssertEqual(error as? SplitError, .exactAmountsMismatch(expected: 1000, got: 900))
        }
    }

    func testExactAmountsValid() throws {
        let shares = try SplitCalculator.shares(
            totalMinorUnits: 1000, mode: .exactAmounts,
            participants: [a, b], inputs: [a: 400, b: 600]
        )
        XCTAssertEqual(shares[a], 400)
        XCTAssertEqual(shares[b], 600)
    }

    func testPercentagesMustBe100() {
        XCTAssertThrowsError(try SplitCalculator.shares(
            totalMinorUnits: 1000, mode: .percentages,
            participants: [a, b], inputs: [a: 60, b: 30]
        ))
    }

    func testPercentagesAllocateExactly() throws {
        let shares = try SplitCalculator.shares(
            totalMinorUnits: 1001, mode: .percentages,
            participants: [a, b, c], inputs: [a: Decimal(string: "33.33")!, b: Decimal(string: "33.33")!, c: Decimal(string: "33.34")!]
        )
        XCTAssertEqual(shares.values.reduce(0, +), 1001)
    }

    func testSharesWeighted() throws {
        let shares = try SplitCalculator.shares(
            totalMinorUnits: 3000, mode: .shares,
            participants: [a, b], inputs: [a: 2, b: 1]
        )
        XCTAssertEqual(shares[a], 2000)
        XCTAssertEqual(shares[b], 1000)
    }

    func testZeroParticipantsThrows() {
        XCTAssertThrowsError(try SplitCalculator.shares(totalMinorUnits: 100, mode: .equal, participants: []))
    }

    func testAllocateNegativeTotal() {
        let result = SplitCalculator.allocate(totalMinorUnits: -100, weights: [1, 1, 1])
        XCTAssertEqual(result.reduce(0, +), -100)
    }

    func testAllocateFuzzAlwaysExact() {
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<500 {
            let total = Int.random(in: 1...1_000_000, using: &generator)
            let count = Int.random(in: 1...12, using: &generator)
            let weights = (0..<count).map { _ in Decimal(Int.random(in: 1...100, using: &generator)) }
            let result = SplitCalculator.allocate(totalMinorUnits: total, weights: weights)
            XCTAssertEqual(result.reduce(0, +), total, "weights \(weights) total \(total)")
        }
    }
}

final class LedgerTests: XCTestCase {
    let a = UUID(), b = UUID(), c = UUID()

    func testBalancesFromSingleExpense() {
        // A pays 30, split equally three ways.
        let entry = LedgerEntry(payer: a, shares: [a: 1000, b: 1000, c: 1000])
        let balances = Ledger.balances(entries: [entry], payments: [])
        XCTAssertEqual(balances[a], 2000)
        XCTAssertEqual(balances[b], -1000)
        XCTAssertEqual(balances[c], -1000)
        XCTAssertEqual(balances.values.reduce(0, +), 0)
    }

    func testPaymentClearsDebt() {
        let entry = LedgerEntry(payer: a, shares: [a: 1000, b: 1000])
        let payment = LedgerPayment(from: b, to: a, minorUnits: 1000)
        let balances = Ledger.balances(entries: [entry], payments: [payment])
        XCTAssertEqual(balances[a], 0)
        XCTAssertEqual(balances[b], 0)
    }

    func testSimplifierChainCollapses() {
        // A owes B 10, B owes C 10 → single transfer A → C.
        let balances = [a: -1000, b: 0, c: 1000]
        let transfers = DebtSimplifier.simplify(balances: balances)
        XCTAssertEqual(transfers, [Transfer(from: a, to: c, minorUnits: 1000)])
    }

    func testSimplifierProducesNetZero() {
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<200 {
            let ids = (0..<Int.random(in: 2...8, using: &generator)).map { _ in UUID() }
            var balances: [UUID: Int] = [:]
            var running = 0
            for id in ids.dropLast() {
                let v = Int.random(in: -50_000...50_000, using: &generator)
                balances[id] = v
                running += v
            }
            balances[ids.last!] = -running

            let transfers = DebtSimplifier.simplify(balances: balances)
            var settled = balances
            for t in transfers {
                settled[t.from, default: 0] += t.minorUnits
                settled[t.to, default: 0] -= t.minorUnits
                XCTAssertGreaterThan(t.minorUnits, 0)
            }
            XCTAssertTrue(settled.values.allSatisfy { $0 == 0 })
            // Never more transfers than participants - 1.
            XCTAssertLessThanOrEqual(transfers.count, max(0, ids.count - 1))
        }
    }
}

final class MoneyTests: XCTestCase {
    func testDecimalRoundTrip() {
        let money = Money(Decimal(string: "12.34")!, currencyCode: "USD")
        XCTAssertEqual(money.minorUnits, 1234)
        XCTAssertEqual(money.decimalValue, Decimal(string: "12.34")!)
    }

    func testZeroDecimalCurrency() {
        let yen = Money(Decimal(1500), currencyCode: "JPY")
        XCTAssertEqual(yen.minorUnits, 1500)
    }

    func testConversionRoundTrip() {
        let converter = CurrencyConverter.bundledSnapshot
        let usd = Money(minorUnits: 10_000, currencyCode: "USD")
        let eur = converter.convert(usd, to: "EUR")
        XCTAssertEqual(eur?.currencyCode, "EUR")
        XCTAssertEqual(eur?.minorUnits, 9_200)
        XCTAssertNil(converter.convert(usd, to: "XXX"))
    }
}
