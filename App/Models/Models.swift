import Foundation
import CoreData
import SplitCore

// Core Data + NSPersistentCloudKitContainer (not SwiftData) because shared
// groups need CKShare, which SwiftData doesn't support. The model follows
// CloudKit rules: every attribute optional or defaulted, every relationship
// optional with an inverse, no unique constraints.

@objc(SpendingGroup)
final class SpendingGroup: NSManagedObject, Identifiable {
    @NSManaged var id: UUID
    @NSManaged var name: String
    @NSManaged var emoji: String
    @NSManaged var currencyCode: String
    @NSManaged var createdAt: Date
    @NSManaged var members: Set<Member>?
    @NSManaged var expenses: Set<Expense>?
    @NSManaged var settlements: Set<Settlement>?

    override func awakeFromInsert() {
        super.awakeFromInsert()
        id = UUID()
        createdAt = Date.now
    }

    convenience init(context: NSManagedObjectContext, name: String,
                     emoji: String = "👥", currencyCode: String = "USD") {
        self.init(context: context)
        self.name = name
        self.emoji = emoji
        self.currencyCode = currencyCode
    }

    static func fetchAll() -> NSFetchRequest<SpendingGroup> {
        let request = NSFetchRequest<SpendingGroup>(entityName: "SpendingGroup")
        request.sortDescriptors = [NSSortDescriptor(key: "createdAt", ascending: false)]
        return request
    }

    var sortedMembers: [Member] {
        (members ?? []).sorted { ($0.isMe ? 0 : 1, $0.name) < ($1.isMe ? 0 : 1, $1.name) }
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

@objc(Member)
final class Member: NSManagedObject, Identifiable {
    @NSManaged var id: UUID
    @NSManaged var name: String
    /// True for the member the group's *creator* made for themselves. Kept
    /// for seeding, but "who am I" is answered per-device by CurrentUser —
    /// in a shared group this flag belongs to someone else's device.
    @NSManaged var isCurrentUser: Bool
    @NSManaged var colorHue: Double
    @NSManaged var group: SpendingGroup?
    @NSManaged var lineItems: Set<LineItem>?
    @NSManaged var paidExpenses: Set<Expense>?
    @NSManaged var expenseShares: Set<ExpenseShare>?
    @NSManaged var settlementsSent: Set<Settlement>?
    @NSManaged var settlementsReceived: Set<Settlement>?

    override func awakeFromInsert() {
        super.awakeFromInsert()
        id = UUID()
    }

    convenience init(context: NSManagedObjectContext, name: String,
                     isCurrentUser: Bool = false, colorHue: Double = 0.55) {
        self.init(context: context)
        self.name = name
        self.isCurrentUser = isCurrentUser
        self.colorHue = colorHue
    }

    /// Whether this member is the person holding the device.
    var isMe: Bool { CurrentUser.isMe(self) }

    var displayName: String { isMe ? "You" : name }
    var initials: String {
        let parts = name.split(separator: " ").prefix(2)
        return parts.map { String($0.prefix(1)).uppercased() }.joined()
    }
}

/// Per-device record of which member the device's owner is in each group.
/// This can't be a synced attribute: in a shared group every participant is
/// "You" on their own device and someone else on everyone else's.
enum CurrentUser {
    private static let key = "currentUserMemberIDs" // [groupID: memberID]

    static func claim(_ member: Member) {
        guard let groupID = member.group?.id else { return }
        var map = UserDefaults.standard.dictionary(forKey: key) as? [String: String] ?? [:]
        map[groupID.uuidString] = member.id.uuidString
        UserDefaults.standard.set(map, forKey: key)
    }

    static func isMe(_ member: Member) -> Bool {
        guard let groupID = member.group?.id else { return member.isCurrentUser }
        let map = UserDefaults.standard.dictionary(forKey: key) as? [String: String] ?? [:]
        if let claimed = map[groupID.uuidString] {
            return claimed == member.id.uuidString
        }
        // No claim on this device (e.g. a group someone shared with us and
        // we haven't picked ourselves yet): nobody is "You".
        return false
    }

    static func hasClaim(in group: SpendingGroup) -> Bool {
        let map = UserDefaults.standard.dictionary(forKey: key) as? [String: String] ?? [:]
        return map[group.id.uuidString] != nil
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

@objc(Expense)
final class Expense: NSManagedObject, Identifiable {
    @NSManaged var id: UUID
    @NSManaged var title: String
    @NSManaged var amountMinorUnits: Int
    @NSManaged var currencyCode: String
    @NSManaged var date: Date
    @NSManaged var categoryRaw: String
    @NSManaged var notes: String
    @NSManaged var splitModeRaw: String
    @NSManaged var isItemized: Bool
    @NSManaged var recurrenceRaw: String
    /// When this template expense should next be cloned. Nil for one-offs.
    @NSManaged var recurrenceNextDate: Date?
    @NSManaged var payer: Member?
    @NSManaged var group: SpendingGroup?
    @NSManaged var shares: Set<ExpenseShare>?
    @NSManaged var lineItems: Set<LineItem>?

    override func awakeFromInsert() {
        super.awakeFromInsert()
        id = UUID()
        date = Date.now
    }

    convenience init(context: NSManagedObjectContext, title: String,
                     amountMinorUnits: Int, currencyCode: String) {
        self.init(context: context)
        self.title = title
        self.amountMinorUnits = amountMinorUnits
        self.currencyCode = currencyCode
    }

    static func fetchAll() -> NSFetchRequest<Expense> {
        let request = NSFetchRequest<Expense>(entityName: "Expense")
        request.sortDescriptors = [NSSortDescriptor(key: "date", ascending: false)]
        return request
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

@objc(ExpenseShare)
final class ExpenseShare: NSManagedObject, Identifiable {
    @NSManaged var id: UUID
    @NSManaged var amountMinorUnits: Int
    /// The raw value the user typed for percent/shares modes, kept for editing.
    @NSManaged private var inputValueRaw: NSDecimalNumber?
    @NSManaged var member: Member?
    @NSManaged var expense: Expense?

    override func awakeFromInsert() {
        super.awakeFromInsert()
        id = UUID()
    }

    convenience init(context: NSManagedObjectContext, member: Member?,
                     amountMinorUnits: Int, inputValue: Decimal = 0) {
        self.init(context: context)
        self.member = member
        self.amountMinorUnits = amountMinorUnits
        self.inputValue = inputValue
    }

    var inputValue: Decimal {
        get { inputValueRaw?.decimalValue ?? 0 }
        set { inputValueRaw = NSDecimalNumber(decimal: newValue) }
    }
}

@objc(LineItem)
final class LineItem: NSManagedObject, Identifiable {
    @NSManaged var id: UUID
    @NSManaged var name: String
    @NSManaged var amountMinorUnits: Int
    /// Members splitting this item equally.
    @NSManaged var participants: Set<Member>?
    @NSManaged var expense: Expense?

    override func awakeFromInsert() {
        super.awakeFromInsert()
        id = UUID()
    }

    convenience init(context: NSManagedObjectContext, name: String,
                     amountMinorUnits: Int, participants: [Member]) {
        self.init(context: context)
        self.name = name
        self.amountMinorUnits = amountMinorUnits
        self.participants = Set(participants)
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

@objc(Settlement)
final class Settlement: NSManagedObject, Identifiable {
    @NSManaged var id: UUID
    @NSManaged var amountMinorUnits: Int
    @NSManaged var date: Date
    @NSManaged var methodRaw: String
    @NSManaged var from: Member?
    @NSManaged var to: Member?
    @NSManaged var group: SpendingGroup?

    override func awakeFromInsert() {
        super.awakeFromInsert()
        id = UUID()
        date = Date.now
    }

    convenience init(context: NSManagedObjectContext, from: Member?, to: Member?,
                     amountMinorUnits: Int, method: SettlementMethod) {
        self.init(context: context)
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
