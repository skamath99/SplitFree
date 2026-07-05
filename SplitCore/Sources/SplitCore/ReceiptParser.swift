import Foundation

/// One piece of OCR text with its normalized position on the receipt.
/// `y` grows downward (0 = top) so sorting ascending reads top-to-bottom.
public struct ScannedLine: Sendable {
    public let text: String
    public let x: Double
    public let y: Double
    public let height: Double

    public init(text: String, x: Double, y: Double, height: Double) {
        self.text = text
        self.x = x
        self.y = y
        self.height = height
    }
}

public struct ScannedItem: Equatable, Sendable {
    public let name: String
    public let amount: Decimal

    public init(name: String, amount: Decimal) {
        self.name = name
        self.amount = amount
    }
}

public struct ScannedReceipt: Sendable {
    public var items: [ScannedItem] = []
    public var subtotal: Decimal?
    public var tax: Decimal?
    public var tip: Decimal?
    public var total: Decimal?

    public init() {}

    public var itemsSum: Decimal {
        items.map(\.amount).reduce(0, +)
    }

    /// Best guess at the grand total: the printed total when found, otherwise
    /// rebuilt from subtotal (or the items) plus tax and tip.
    public var effectiveTotal: Decimal {
        if let total { return total }
        let base = subtotal ?? itemsSum
        return base + (tax ?? 0) + (tip ?? 0)
    }
}

/// Turns OCR output into an itemized receipt. Names and prices usually land in
/// separate OCR observations, so lines are grouped into visual rows by
/// vertical overlap and paired left-to-right within each row.
public enum ReceiptParser {
    static let moneyRegex = #/(?:[$€£]\s*)?(\d{1,6}[.,]\d{2})\b/#

    // Footer keywords checked against a row's name text, most specific first.
    private static let subtotalKeywords = ["subtotal", "sub total", "sub-total"]
    // "mwst" is the German/Swiss VAT marker (Mehrwertsteuer).
    private static let taxKeywords = ["tax", "vat", "gst", "hst", "mwst"]
    private static let tipKeywords = ["tip", "gratuity", "service charge", "service fee"]
    // "lotal" catches Vision's frequent T→l misread of "Total".
    private static let totalKeywords = ["total", "lotal", "amount due", "balance due", "to pay"]
    // Rows that carry an amount but aren't part of the bill. "entspricht"
    // ("corresponds to …") is the currency-conversion line on German receipts;
    // we don't ignore bare "euro" so genuine EUR receipts still parse.
    private static let ignoreKeywords = ["cash", "change", "card", "visa", "mastercard",
                                         "amex", "debit", "credit", "payment", "tender",
                                         "auth", "approved", "entspricht"]

    public static func parse(lines: [ScannedLine]) -> ScannedReceipt {
        var receipt = ScannedReceipt()
        for row in rows(from: lines) {
            guard let price = trailingAmount(in: row) else { continue }
            let name = nameText(of: row)
            let lowered = name.lowercased()

            if ignoreKeywords.contains(where: lowered.contains) { continue }
            if subtotalKeywords.contains(where: lowered.contains) {
                receipt.subtotal = receipt.subtotal ?? price
            } else if taxKeywords.contains(where: lowered.contains) {
                receipt.tax = (receipt.tax ?? 0) + price
            } else if tipKeywords.contains(where: lowered.contains) {
                receipt.tip = receipt.tip ?? price
            } else if totalKeywords.contains(where: lowered.contains) {
                // Receipts often print several total-ish rows; the grand
                // total is the largest.
                receipt.total = max(receipt.total ?? 0, price)
            } else if isPlausibleItemName(name) {
                receipt.items.append(ScannedItem(name: name, amount: price))
            }
        }
        return receipt
    }

    /// Ranked flat amounts for the "just use the total" fallback: values on
    /// lines mentioning "total" first, then everything else, descending.
    public static func totals(from strings: [String]) -> [Decimal] {
        var totalLineAmounts: [Decimal] = []
        var otherAmounts: [Decimal] = []
        for line in strings {
            let isTotalLine = line.localizedCaseInsensitiveContains("total")
                && !line.localizedCaseInsensitiveContains("subtotal")
            for match in line.matches(of: moneyRegex) {
                guard let value = decimal(from: match.1), value > 0 else { continue }
                if isTotalLine {
                    totalLineAmounts.append(value)
                } else {
                    otherAmounts.append(value)
                }
            }
        }
        var seen = Set<Decimal>()
        let ranked = totalLineAmounts.sorted(by: >) + otherAmounts.sorted(by: >)
        return ranked.filter { seen.insert($0).inserted }
    }

    // MARK: - Row assembly

    /// Groups lines into visual rows: a line joins the current row when its
    /// vertical center is within half a text-height of the row's center.
    static func rows(from lines: [ScannedLine]) -> [[ScannedLine]] {
        let sorted = lines.sorted { $0.y < $1.y }
        var rows: [[ScannedLine]] = []
        for line in sorted {
            if let last = rows.last, let anchor = last.first,
               abs(line.y - anchor.y) < max(anchor.height, line.height) * 0.6 {
                rows[rows.count - 1].append(line)
            } else {
                rows.append([line])
            }
        }
        return rows.map { $0.sorted { $0.x < $1.x } }
    }

    /// The price of a row is the last money value in its rightmost text.
    private static func trailingAmount(in row: [ScannedLine]) -> Decimal? {
        for line in row.reversed() {
            let matches = line.text.matches(of: moneyRegex)
            if let last = matches.last, let value = decimal(from: last.1), value > 0 {
                return value
            }
        }
        return nil
    }

    /// Row text with the trailing price stripped — what's left is the name.
    private static func nameText(of row: [ScannedLine]) -> String {
        var pieces = row.map(\.text)
        for index in pieces.indices.reversed() {
            if let match = pieces[index].matches(of: moneyRegex).last {
                pieces[index].removeSubrange(match.range)
                break
            }
        }
        return pieces.joined(separator: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: " \t-–—:·.*"))
    }

    /// Filters out rows that read as numbers-only noise (dates, order
    /// numbers, quantity columns) rather than a purchasable item.
    private static func isPlausibleItemName(_ name: String) -> Bool {
        guard name.count >= 2 else { return false }
        return name.contains { $0.isLetter }
    }

    private static func decimal(from raw: Substring) -> Decimal? {
        Decimal(string: String(raw.replacing(",", with: ".")))
    }
}
