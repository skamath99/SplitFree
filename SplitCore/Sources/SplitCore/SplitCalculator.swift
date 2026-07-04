import Foundation

/// How an expense is divided among participants.
public enum SplitMode: String, Codable, CaseIterable, Sendable {
    case equal
    case exactAmounts
    case percentages
    case shares

    public var displayName: String {
        switch self {
        case .equal: return "Equally"
        case .exactAmounts: return "Exact amounts"
        case .percentages: return "Percentages"
        case .shares: return "Shares"
        }
    }

    /// Short label for tight UI like segmented controls.
    public var shortName: String {
        switch self {
        case .equal: return "Equal"
        case .exactAmounts: return "Exact"
        case .percentages: return "Percent"
        case .shares: return "Shares"
        }
    }
}

public enum SplitError: Error, Equatable, LocalizedError {
    case noParticipants
    case exactAmountsMismatch(expected: Int, got: Int)
    case percentagesMismatch(total: Decimal)
    case zeroShares

    public var errorDescription: String? {
        switch self {
        case .noParticipants:
            return "Select at least one person to split with."
        case .exactAmountsMismatch:
            return "The amounts must add up to the expense total."
        case .percentagesMismatch(let total):
            return "Percentages add up to \(total)%, not 100%."
        case .zeroShares:
            return "At least one person needs a share greater than zero."
        }
    }
}

public enum SplitCalculator {
    /// Distributes `totalMinorUnits` across weights exactly, using the
    /// largest-remainder method so every penny is accounted for and the
    /// result is deterministic (earlier participants absorb leftover pennies).
    public static func allocate(totalMinorUnits: Int, weights: [Decimal]) -> [Int] {
        guard !weights.isEmpty else { return [] }
        let weightSum = weights.reduce(Decimal(0), +)
        guard weightSum > 0 else { return weights.map { _ in 0 } }

        let sign = totalMinorUnits < 0 ? -1 : 1
        let total = abs(totalMinorUnits)

        var floors: [Int] = []
        var remainders: [(index: Int, remainder: Decimal)] = []
        for (i, w) in weights.enumerated() {
            let ideal = Decimal(total) * w / weightSum
            var floorValue = Decimal()
            var idealCopy = ideal
            NSDecimalRound(&floorValue, &idealCopy, 0, .down)
            let floorInt = NSDecimalNumber(decimal: floorValue).intValue
            floors.append(floorInt)
            remainders.append((i, ideal - floorValue))
        }

        var leftover = total - floors.reduce(0, +)
        // Hand out leftover pennies to the largest remainders first; ties go
        // to earlier participants for determinism.
        for (index, _) in remainders.sorted(by: { ($0.remainder, $1.index) > ($1.remainder, $0.index) }) {
            guard leftover > 0 else { break }
            floors[index] += 1
            leftover -= 1
        }
        return floors.map { $0 * sign }
    }

    /// Computes each participant's owed amount in minor units.
    /// `inputs` meaning depends on mode: exact amounts (minor units),
    /// percentages (0–100), or share counts. Ignored for `.equal`.
    public static func shares(
        totalMinorUnits: Int,
        mode: SplitMode,
        participants: [UUID],
        inputs: [UUID: Decimal] = [:]
    ) throws -> [UUID: Int] {
        guard !participants.isEmpty else { throw SplitError.noParticipants }

        switch mode {
        case .equal:
            let amounts = allocate(totalMinorUnits: totalMinorUnits, weights: participants.map { _ in 1 })
            return Dictionary(uniqueKeysWithValues: zip(participants, amounts))

        case .exactAmounts:
            let amounts = participants.map { NSDecimalNumber(decimal: inputs[$0] ?? 0).intValue }
            let sum = amounts.reduce(0, +)
            guard sum == totalMinorUnits else {
                throw SplitError.exactAmountsMismatch(expected: totalMinorUnits, got: sum)
            }
            return Dictionary(uniqueKeysWithValues: zip(participants, amounts))

        case .percentages:
            let percents = participants.map { inputs[$0] ?? 0 }
            let sum = percents.reduce(Decimal(0), +)
            guard sum == 100 else { throw SplitError.percentagesMismatch(total: sum) }
            let amounts = allocate(totalMinorUnits: totalMinorUnits, weights: percents)
            return Dictionary(uniqueKeysWithValues: zip(participants, amounts))

        case .shares:
            let weights = participants.map { inputs[$0] ?? 0 }
            guard weights.reduce(Decimal(0), +) > 0 else { throw SplitError.zeroShares }
            let amounts = allocate(totalMinorUnits: totalMinorUnits, weights: weights)
            return Dictionary(uniqueKeysWithValues: zip(participants, amounts))
        }
    }
}
