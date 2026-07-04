import Foundation

/// A single "A pays B" instruction produced by debt simplification.
public struct Transfer: Hashable, Sendable {
    public let from: UUID
    public let to: UUID
    public let minorUnits: Int

    public init(from: UUID, to: UUID, minorUnits: Int) {
        self.from = from
        self.to = to
        self.minorUnits = minorUnits
    }
}

public enum DebtSimplifier {
    /// Nets everyone's balance (positive = is owed money, negative = owes)
    /// down to a minimal set of transfers using the greedy min-cash-flow
    /// approach: repeatedly match the largest debtor with the largest creditor.
    /// Balances must sum to zero (they do by construction from expenses).
    public static func simplify(balances: [UUID: Int]) -> [Transfer] {
        var creditors: [(id: UUID, amount: Int)] = []
        var debtors: [(id: UUID, amount: Int)] = []
        for (id, balance) in balances where balance != 0 {
            if balance > 0 {
                creditors.append((id, balance))
            } else {
                debtors.append((id, -balance))
            }
        }
        // Deterministic ordering: largest first, ties by UUID.
        creditors.sort { ($0.amount, $1.id.uuidString) > ($1.amount, $0.id.uuidString) }
        debtors.sort { ($0.amount, $1.id.uuidString) > ($1.amount, $0.id.uuidString) }

        var transfers: [Transfer] = []
        var ci = 0, di = 0
        while ci < creditors.count && di < debtors.count {
            let paid = min(creditors[ci].amount, debtors[di].amount)
            transfers.append(Transfer(from: debtors[di].id, to: creditors[ci].id, minorUnits: paid))
            creditors[ci].amount -= paid
            debtors[di].amount -= paid
            if creditors[ci].amount == 0 { ci += 1 }
            if debtors[di].amount == 0 { di += 1 }
        }
        return transfers
    }
}
