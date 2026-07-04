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

final class ReceiptParserTests: XCTestCase {
    /// Builds a receipt row the way Vision reports it: the name and the price
    /// as separate observations sharing a vertical center.
    private func row(_ name: String, _ price: String, y: Double) -> [ScannedLine] {
        [ScannedLine(text: name, x: 0.05, y: y, height: 0.02),
         ScannedLine(text: price, x: 0.80, y: y, height: 0.02)]
    }

    private var dinnerReceipt: [ScannedLine] {
        var lines: [ScannedLine] = [
            ScannedLine(text: "LUIGI'S TRATTORIA", x: 0.2, y: 0.05, height: 0.02),
            ScannedLine(text: "Table 12 · 07/04/2026", x: 0.2, y: 0.08, height: 0.02),
        ]
        lines += row("2 Margherita Pizza", "24.00", y: 0.20)
        lines += row("Caesar Salad", "9.50", y: 0.24)
        lines += row("House Red (btl)", "28.00", y: 0.28)
        lines += row("Subtotal", "61.50", y: 0.40)
        lines += row("Sales Tax 8%", "4.92", y: 0.44)
        lines += row("Tip", "12.30", y: 0.48)
        lines += row("TOTAL", "78.72", y: 0.52)
        lines += row("VISA ****1234", "78.72", y: 0.60)
        return lines
    }

    func testParsesItemsAndFooter() {
        let receipt = ReceiptParser.parse(lines: dinnerReceipt.shuffled())
        XCTAssertEqual(receipt.items, [
            ScannedItem(name: "2 Margherita Pizza", amount: 24),
            ScannedItem(name: "Caesar Salad", amount: Decimal(string: "9.50")!),
            ScannedItem(name: "House Red (btl)", amount: 28),
        ])
        XCTAssertEqual(receipt.subtotal, Decimal(string: "61.50"))
        XCTAssertEqual(receipt.tax, Decimal(string: "4.92"))
        XCTAssertEqual(receipt.tip, Decimal(string: "12.30"))
        XCTAssertEqual(receipt.total, Decimal(string: "78.72"))
        XCTAssertEqual(receipt.effectiveTotal, Decimal(string: "78.72"))
    }

    func testPaymentRowsAreIgnored() {
        let receipt = ReceiptParser.parse(lines: dinnerReceipt)
        XCTAssertFalse(receipt.items.contains { $0.name.localizedCaseInsensitiveContains("visa") })
    }

    func testSingleObservationRows() {
        // Some OCR passes return the whole row as one string.
        let lines = [
            ScannedLine(text: "Latte 5.25", x: 0.1, y: 0.2, height: 0.02),
            ScannedLine(text: "Croissant 4.00", x: 0.1, y: 0.25, height: 0.02),
            ScannedLine(text: "Total 9.25", x: 0.1, y: 0.35, height: 0.02),
        ]
        let receipt = ReceiptParser.parse(lines: lines)
        XCTAssertEqual(receipt.items, [
            ScannedItem(name: "Latte", amount: Decimal(string: "5.25")!),
            ScannedItem(name: "Croissant", amount: 4),
        ])
        XCTAssertEqual(receipt.total, Decimal(string: "9.25"))
    }

    func testEffectiveTotalRebuiltWhenNoTotalPrinted() {
        var lines = row("Burger", "12.00", y: 0.2)
        lines += row("Fries", "5.00", y: 0.25)
        lines += row("Tax", "1.36", y: 0.35)
        let receipt = ReceiptParser.parse(lines: lines)
        XCTAssertNil(receipt.total)
        XCTAssertEqual(receipt.effectiveTotal, Decimal(string: "18.36"))
    }

    func testGrandTotalWinsOverSmallerTotalRows() {
        var lines = row("Pasta", "20.00", y: 0.2)
        lines += row("Total before tip", "21.60", y: 0.3)
        lines += row("Grand Total", "25.60", y: 0.35)
        let receipt = ReceiptParser.parse(lines: lines)
        XCTAssertEqual(receipt.total, Decimal(string: "25.60"))
    }

    func testNumbersOnlyRowsAreNotItems() {
        let lines = [
            ScannedLine(text: "07/04/2026 19:32", x: 0.1, y: 0.1, height: 0.02),
            ScannedLine(text: "1 23.50", x: 0.1, y: 0.2, height: 0.02),
        ] + row("Steak", "23.50", y: 0.3)
        let receipt = ReceiptParser.parse(lines: lines)
        XCTAssertEqual(receipt.items, [ScannedItem(name: "Steak", amount: Decimal(string: "23.50")!)])
    }

    func testEuropeanDecimalComma() {
        let lines = row("Bier", "4,50", y: 0.2) + row("Summe Total", "4,50", y: 0.3)
        let receipt = ReceiptParser.parse(lines: lines)
        XCTAssertEqual(receipt.items.first?.amount, Decimal(string: "4.50"))
        XCTAssertEqual(receipt.total, Decimal(string: "4.50"))
    }

    func testTotalsFallbackRanksTotalLinesFirst() {
        let candidates = ReceiptParser.totals(from: [
            "Latte 5.25", "Croissant 4.00", "Subtotal 9.25", "Total 10.05",
        ])
        XCTAssertEqual(candidates.first, Decimal(string: "10.05"))
        XCTAssertTrue(candidates.contains(Decimal(string: "9.25")!))
    }
}
