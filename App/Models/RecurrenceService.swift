import Foundation
import CoreData

enum RecurrenceService {
    /// Clones recurring template expenses whose next occurrence has passed.
    /// Runs at launch; catches up multiple missed periods.
    static func materializeDueExpenses(context: NSManagedObjectContext) {
        let request = NSFetchRequest<Expense>(entityName: "Expense")
        request.predicate = NSPredicate(format: "recurrenceRaw != %@ AND recurrenceNextDate != nil",
                                        RecurrenceFrequency.none.rawValue)
        guard let templates = try? context.fetch(request) else { return }
        let now = Date.now

        for template in templates {
            var nextDate = template.recurrenceNextDate!
            var safety = 0
            while nextDate <= now, safety < 24 {
                let clone = Expense(context: context, title: template.title,
                                    amountMinorUnits: template.amountMinorUnits,
                                    currencyCode: template.currencyCode)
                clone.date = nextDate
                clone.categoryRaw = template.categoryRaw
                clone.notes = template.notes
                clone.splitModeRaw = template.splitModeRaw
                clone.payer = template.payer
                clone.group = template.group
                clone.shares = Set((template.shares ?? []).map {
                    ExpenseShare(context: context, member: $0.member,
                                 amountMinorUnits: $0.amountMinorUnits, inputValue: $0.inputValue)
                })
                guard let following = template.recurrence.next(after: nextDate) else { break }
                nextDate = following
                safety += 1
            }
            template.recurrenceNextDate = nextDate
        }
        try? context.save()
    }
}
