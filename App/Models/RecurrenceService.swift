import Foundation
import SwiftData

enum RecurrenceService {
    /// Clones recurring template expenses whose next occurrence has passed.
    /// Runs at launch; catches up multiple missed periods.
    static func materializeDueExpenses(context: ModelContext) {
        let noneRaw = RecurrenceFrequency.none.rawValue
        let now = Date.now
        let predicate = #Predicate<Expense> {
            $0.recurrenceRaw != noneRaw && $0.recurrenceNextDate != nil
        }
        guard let templates = try? context.fetch(FetchDescriptor(predicate: predicate)) else { return }

        for template in templates {
            var nextDate = template.recurrenceNextDate!
            var safety = 0
            while nextDate <= now, safety < 24 {
                let clone = Expense(title: template.title,
                                    amountMinorUnits: template.amountMinorUnits,
                                    currencyCode: template.currencyCode)
                clone.date = nextDate
                clone.categoryRaw = template.categoryRaw
                clone.notes = template.notes
                clone.splitModeRaw = template.splitModeRaw
                clone.payer = template.payer
                clone.group = template.group
                context.insert(clone)
                clone.shares = (template.shares ?? []).map {
                    ExpenseShare(member: $0.member, amountMinorUnits: $0.amountMinorUnits, inputValue: $0.inputValue)
                }
                guard let following = template.recurrence.next(after: nextDate) else { break }
                nextDate = following
                safety += 1
            }
            template.recurrenceNextDate = nextDate
        }
        try? context.save()
    }
}
