import SwiftUI
import SwiftData

@main
struct SplitFreeApp: App {
    let container: ModelContainer

    init() {
        let schema = Schema([SpendingGroup.self, Member.self, Expense.self,
                             ExpenseShare.self, LineItem.self, Settlement.self])
        // Local store today; the models are CloudKit-compatible, so switching
        // to ModelConfiguration(cloudKitDatabase: .private(...)) plus the
        // iCloud entitlement is all sync needs.
        let config = ModelConfiguration(schema: schema)
        do {
            container = try ModelContainer(for: schema, configurations: [config])
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
        RecurrenceService.materializeDueExpenses(context: ModelContext(container))
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .modelContainer(container)
    }
}
