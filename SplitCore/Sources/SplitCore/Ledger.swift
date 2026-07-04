import Foundation

/// Value-type snapshot of an expense for balance math, decoupled from storage.
public struct LedgerEntry: Sendable {
    public let payer: UUID
    /// Participant → amount owed for this expense, in minor units.
    public let shares: [UUID: Int]

    public init(payer: UUID, shares: [UUID: Int]) {
        self.payer = payer
        self.shares = shares
    }
}

/// A recorded settle-up payment.
public struct LedgerPayment: Sendable {
    public let from: UUID
    public let to: UUID
    public let minorUnits: Int

    public init(from: UUID, to: UUID, minorUnits: Int) {
        self.from = from
        self.to = to
        self.minorUnits = minorUnits
    }
}

public enum Ledger {
    /// Net balance per member in minor units. Positive = others owe them.
    public static func balances(entries: [LedgerEntry], payments: [LedgerPayment]) -> [UUID: Int] {
        var balances: [UUID: Int] = [:]
        for entry in entries {
            let total = entry.shares.values.reduce(0, +)
            balances[entry.payer, default: 0] += total
            for (member, owed) in entry.shares {
                balances[member, default: 0] -= owed
            }
        }
        for payment in payments {
            balances[payment.from, default: 0] += payment.minorUnits
            balances[payment.to, default: 0] -= payment.minorUnits
        }
        return balances
    }

    public static func settlementPlan(entries: [LedgerEntry], payments: [LedgerPayment]) -> [Transfer] {
        DebtSimplifier.simplify(balances: balances(entries: entries, payments: payments))
    }
}
