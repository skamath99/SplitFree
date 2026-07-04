import SwiftUI
import SwiftData

@main
struct SplitFreeApp: App {
    let container: ModelContainer

    init() {
        let schema = Schema([SpendingGroup.self, Member.self, Expense.self,
                             ExpenseShare.self, LineItem.self, Settlement.self])
        // Sync through the user's private iCloud database (free, serverless).
        // Falls back to a device-local store when iCloud is unavailable —
        // signed out, entitlement missing, or tests forcing determinism.
        let forceLocal = CommandLine.arguments.contains("--local-store")
        var made: ModelContainer?
        if !forceLocal {
            let cloudConfig = ModelConfiguration(schema: schema,
                                                 cloudKitDatabase: .private("iCloud.com.sank.splitfree"))
            made = try? ModelContainer(for: schema, configurations: [cloudConfig])
        }
        if let made {
            container = made
        } else {
            // .none explicitly: the default (.automatic) would re-enable
            // CloudKit because the entitlement is present.
            let localConfig = ModelConfiguration(schema: schema, cloudKitDatabase: .none)
            do {
                container = try ModelContainer(for: schema, configurations: [localConfig])
            } catch {
                fatalError("Could not create ModelContainer: \(error)")
            }
        }
        if CommandLine.arguments.contains("--reset-data") {
            let context = ModelContext(container)
            try? context.delete(model: SpendingGroup.self)
            try? context.save()
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
