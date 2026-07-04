import SwiftUI
import CoreData

/// Cross-group feed with full-text search — a Splitwise Pro feature, free here.
struct ActivityView: View {
    @FetchRequest(fetchRequest: Expense.fetchAll(), animation: .default)
    private var expenses: FetchedResults<Expense>
    @State private var searchText = ""
    @State private var category: ExpenseCategory?

    private var filtered: [Expense] {
        expenses.filter { expense in
            if let category, expense.category != category { return false }
            guard !searchText.isEmpty else { return true }
            let haystacks = [expense.title, expense.notes,
                             expense.payer?.name ?? "", expense.group?.name ?? ""]
            return haystacks.contains { $0.localizedCaseInsensitiveContains(searchText) }
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if expenses.isEmpty {
                    ContentUnavailableView("No activity yet", systemImage: "list.bullet.rectangle",
                                           description: Text("Expenses from all your groups show up here."))
                } else if filtered.isEmpty {
                    ContentUnavailableView.search(text: searchText)
                } else {
                    List(filtered) { expense in
                        VStack(alignment: .leading, spacing: 2) {
                            ExpenseRow(expense: expense)
                            if let groupName = expense.group?.name {
                                Text(groupName)
                                    .font(.caption2)
                                    .padding(.horizontal, 6).padding(.vertical, 2)
                                    .background(.quaternary, in: Capsule())
                                    .padding(.leading, 46)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Activity")
            .searchable(text: $searchText, prompt: "Search title, notes, payer, group")
            .toolbar {
                Menu {
                    Picker("Category", selection: $category) {
                        Text("All categories").tag(ExpenseCategory?.none)
                        ForEach(ExpenseCategory.allCases) { cat in
                            Label(cat.displayName, systemImage: cat.symbol).tag(Optional(cat))
                        }
                    }
                } label: {
                    Image(systemName: category == nil ? "line.3.horizontal.decrease.circle"
                                                      : "line.3.horizontal.decrease.circle.fill")
                }
            }
        }
    }
}
