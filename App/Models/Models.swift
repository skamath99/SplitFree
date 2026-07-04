import Foundation
import SwiftData
import SplitCore

// All models follow CloudKit-compatible rules (no unique constraints,
// optional relationships with inverses, defaults on every attribute) so
// sync + CKShare group sharing can be enabled without a schema migration.

@Model
final class SpendingGroup {
    var id: UUID = UUID()
    var name: String = ""
    var emoji: String = "👥"
    var currencyCode: String = "USD"
    var createdAt: Date = Date.now
    @Relationship(deleteRule: .cascade, inverse: \Member.group)
    var members: [Member]? = []
    @Relationship(deleteRule: .cascade, inverse: \Expense.group)
    var expenses: [Expense]? = []
    @Relationship(deleteRule: .cascade, inverse: \Settlement.group)
    var settlements: [Settlement]? = []

    init(name: String, emoji: String = "👥", currencyCode: String = "USD") {
        self.name = name
        self.emoji = emoji
        self.currencyCode = currencyCode
    }

    var sortedMembers: [Member] {
        (members ?? []).sorted { ($0.isCurrentUser ? 0 : 1, $0.name) < ($1.isCurrentUser ? 0 : 1, $1.name) }
    }

    var sortedExpenses: [Expense] {
        (expenses ?? []).sorted { $0.date > $1.date }
    }

    /// Net balance per member id, in minor units of the group currency.
    /// Expenses in other currencies are converted with the bundled snapshot.
    var balances: [UUID: Int] {
        let converter = CurrencyConverter.bundledSnapshot
        let entries: [LedgerEntry] = (expenses ?? []).compactMap { expense in
            guard let payer = expense.payer else { return nil }
            var shares: [UUID: Int] = [:]
            for share in expense.shares ?? [] {
                guard let member = share.member else { continue }
                var amount = share.amountMinorUnits
                if expense.currencyCode != currencyCode {
                    let money = Money(minorUnits: amount, currencyCode: expense.currencyCode)
                    amount = converter.convert(money, to: currencyCode)?.minorUnits ?? amount
                }
                shares[member.id, default: 0] += amount
            }
            return LedgerEntry(payer: payer.id, shares: shares)
        }
        let payments: [LedgerPayment] = (settlements ?? []).compactMap { settlement in
            guard let from = settlement.from, let to = settlement.to else { return nil }
            return LedgerPayment(from: from.id, to: to.id, minorUnits: settlement.amountMinorUnits)
        }
        return Ledger.balances(entries: entries, payments: payments)
    }

    var suggestedTransfers: [Transfer] {
        DebtSimplifier.simplify(balances: balances)
    }

    func member(id: UUID) -> Member? {
        (members ?? []).first { $0.id == id }
    }
}

@Model
final class Member {
    var id: UUID = UUID()
    var name: String = ""
    var isCurrentUser: Bool = false
    var colorHue: Double = 0.55
    var group: SpendingGroup?

    init(name: String, isCurrentUser: Bool = false, colorHue: Double = 0.55) {
        self.name = name
        self.isCurrentUser = isCurrentUser
        self.colorHue = colorHue
    }

    var displayName: String { isCurrentUser ? "You" : name }
    var initials: String {
        let parts = name.split(separator: " ").prefix(2)
        return parts.map { String($0.prefix(1)).uppercased() }.joined()
    }
}

enum ExpenseCategory: String, Codable, CaseIterable, Identifiable {
    case general, food, groceries, transport, home, utilities
    case entertainment, travel, shopping, health

    var id: String { rawValue }
    var displayName: String { rawValue.capitalized }
    var symbol: String {
        switch self {
        case .general: return "square.grid.2x2"
        case .food: return "fork.knife"
        case .groceries: return "cart"
        case .transport: return "car"
        case .home: return "house"
        case .utilities: return "bolt"
        case .entertainment: return "popcorn"
        case .travel: return "airplane"
        case .shopping: return "bag"
        case .health: return "cross.case"
        }
    }
}

enum RecurrenceFrequency: String, Codable, CaseIterable, Identifiable {
    case none, weekly, monthly

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .none: return "Never"
        case .weekly: return "Weekly"
        case .monthly: return "Monthly"
        }
    }

    func next(after date: Date) -> Date? {
        switch self {
        case .none: return nil
        case .weekly: return Calendar.current.date(byAdding: .weekOfYear, value: 1, to: date)
        case .monthly: return Calendar.current.date(byAdding: .month, value: 1, to: date)
        }
    }
}

@Model
final class Expense {
    var id: UUID = UUID()
    var title: String = ""
    var amountMinorUnits: Int = 0
    var currencyCode: String = "USD"
    var date: Date = Date.now
    var categoryRaw: String = ExpenseCategory.general.rawValue
    var notes: String = ""
    var splitModeRaw: String = SplitMode.equal.rawValue
    var isItemized: Bool = false
    var recurrenceRaw: String = RecurrenceFrequency.none.rawValue
    /// When this template expense should next be cloned. Nil for one-offs.
    var recurrenceNextDate: Date?
    var payer: Member?
    var group: SpendingGroup?
    @Relationship(deleteRule: .cascade, inverse: \ExpenseShare.expense)
    var shares: [ExpenseShare]? = []
    @Relationship(deleteRule: .cascade, inverse: \LineItem.expense)
    var lineItems: [LineItem]? = []

    init(title: String, amountMinorUnits: Int, currencyCode: String) {
        self.title = title
        self.amountMinorUnits = amountMinorUnits
        self.currencyCode = currencyCode
    }

    var category: ExpenseCategory {
        get { ExpenseCategory(rawValue: categoryRaw) ?? .general }
        set { categoryRaw = newValue.rawValue }
    }

    var splitMode: SplitMode {
        get { SplitMode(rawValue: splitModeRaw) ?? .equal }
        set { splitModeRaw = newValue.rawValue }
    }

    var recurrence: RecurrenceFrequency {
        get { RecurrenceFrequency(rawValue: recurrenceRaw) ?? .none }
        set { recurrenceRaw = newValue.rawValue }
    }

    var money: Money { Money(minorUnits: amountMinorUnits, currencyCode: currencyCode) }
}

@Model
final class ExpenseShare {
    var id: UUID = UUID()
    var amountMinorUnits: Int = 0
    /// The raw value the user typed for percent/shares modes, kept for editing.
    var inputValue: Decimal = 0
    var member: Member?
    var expense: Expense?

    init(member: Member?, amountMinorUnits: Int, inputValue: Decimal = 0) {
        self.member = member
        self.amountMinorUnits = amountMinorUnits
        self.inputValue = inputValue
    }
}

@Model
final class LineItem {
    var id: UUID = UUID()
    var name: String = ""
    var amountMinorUnits: Int = 0
    /// Members splitting this item equally. Many-to-many, no inverse needed
    /// for CloudKit as long as it stays optional.
    var participants: [Member]? = []
    var expense: Expense?

    init(name: String, amountMinorUnits: Int, participants: [Member]) {
        self.name = name
        self.amountMinorUnits = amountMinorUnits
        self.participants = participants
    }
}

enum SettlementMethod: String, Codable, CaseIterable, Identifiable {
    case appleCash, cash, bankTransfer, other

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .appleCash: return "Apple Cash"
        case .cash: return "Cash"
        case .bankTransfer: return "Bank transfer"
        case .other: return "Other"
        }
    }
}

@Model
final class Settlement {
    var id: UUID = UUID()
    var amountMinorUnits: Int = 0
    var date: Date = Date.now
    var methodRaw: String = SettlementMethod.appleCash.rawValue
    var from: Member?
    var to: Member?
    var group: SpendingGroup?

    init(from: Member?, to: Member?, amountMinorUnits: Int, method: SettlementMethod) {
        self.from = from
        self.to = to
        self.amountMinorUnits = amountMinorUnits
        self.methodRaw = method.rawValue
    }

    var method: SettlementMethod {
        get { SettlementMethod(rawValue: methodRaw) ?? .other }
        set { methodRaw = newValue.rawValue }
    }

    var money: Money { Money(minorUnits: amountMinorUnits, currencyCode: group?.currencyCode ?? "USD") }
}
