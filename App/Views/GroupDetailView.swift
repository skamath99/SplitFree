import SwiftUI
import SwiftData
import SplitCore

struct GroupDetailView: View {
    @Environment(\.modelContext) private var context
    @Bindable var group: SpendingGroup
    @State private var showingAddExpense = false
    @State private var showingSettleUp = false
    @State private var showingMembers = false
    @State private var expenseToEdit: Expense?

    var body: some View {
        List {
            balancesSection
            expensesSection
        }
        .navigationTitle("\(group.emoji) \(group.name)")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("Members", systemImage: "person.2") { showingMembers = true }
                    Button("Settle up", systemImage: "checkmark.circle") { showingSettleUp = true }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            HStack {
                Button {
                    showingAddExpense = true
                } label: {
                    Label("Add expense", systemImage: "plus")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                Button {
                    showingSettleUp = true
                } label: {
                    Label("Settle up", systemImage: "checkmark.circle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            }
            .padding()
            .background(.bar)
        }
        .sheet(isPresented: $showingAddExpense) {
            ExpenseFormView(group: group)
        }
        .sheet(item: $expenseToEdit) { expense in
            ExpenseFormView(group: group, existing: expense)
        }
        .sheet(isPresented: $showingSettleUp) {
            SettleUpView(group: group)
        }
        .sheet(isPresented: $showingMembers) {
            MembersView(group: group)
        }
    }

    private var balancesSection: some View {
        Section("Balances") {
            if group.sortedExpenses.isEmpty && (group.settlements ?? []).isEmpty {
                Text("Add your first expense to see who owes whom.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(group.sortedMembers) { member in
                    let balance = group.balances[member.id] ?? 0
                    HStack {
                        MemberAvatar(member: member, size: 30)
                        Text(member.displayName)
                        Spacer()
                        if balance == 0 {
                            Text("settled").foregroundStyle(.secondary).font(.subheadline)
                        } else {
                            VStack(alignment: .trailing, spacing: 0) {
                                BalancePill(minorUnits: balance, currencyCode: group.currencyCode)
                                Text(balance > 0 ? "is owed" : "owes")
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
    }

    private var expensesSection: some View {
        let byMonth = Dictionary(grouping: group.sortedExpenses) { expense in
            Calendar.current.dateInterval(of: .month, for: expense.date)?.start ?? expense.date
        }
        return ForEach(byMonth.keys.sorted(by: >), id: \.self) { month in
            Section(month.formatted(.dateTime.month(.wide).year())) {
                ForEach(byMonth[month] ?? []) { expense in
                    Button {
                        expenseToEdit = expense
                    } label: {
                        ExpenseRow(expense: expense)
                    }
                    .buttonStyle(.plain)
                }
                .onDelete { offsets in
                    let expenses = byMonth[month] ?? []
                    for offset in offsets { context.delete(expenses[offset]) }
                    try? context.save()
                }
            }
        }
    }
}

struct ExpenseRow: View {
    let expense: Expense

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: expense.category.symbol)
                .font(.body)
                .foregroundStyle(.secondary)
                .frame(width: 34, height: 34)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 2) {
                Text(expense.title).font(.body)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(expense.money.formatted()).font(.callout.weight(.semibold))
                if expense.recurrence != .none {
                    Image(systemName: "repeat").font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var subtitle: String {
        let payerName = expense.payer?.displayName ?? "Someone"
        let date = expense.date.formatted(date: .abbreviated, time: .omitted)
        return "\(payerName) paid · \(date)"
    }
}

struct MembersView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Bindable var group: SpendingGroup
    @State private var newName = ""

    var body: some View {
        NavigationStack {
            List {
                ForEach(group.sortedMembers) { member in
                    HStack {
                        MemberAvatar(member: member, size: 30)
                        Text(member.displayName)
                        Spacer()
                        BalancePill(minorUnits: group.balances[member.id] ?? 0,
                                    currencyCode: group.currencyCode)
                    }
                }
                Section {
                    HStack {
                        TextField("New member name", text: $newName)
                        Button("Add") {
                            let trimmed = newName.trimmingCharacters(in: .whitespaces)
                            guard !trimmed.isEmpty else { return }
                            let hue = Double.random(in: 0...1)
                            group.members = (group.members ?? []) + [Member(name: trimmed, colorHue: hue)]
                            try? context.save()
                            newName = ""
                        }
                        .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                } footer: {
                    Text("Members with recorded expenses can't be removed, to keep history intact.")
                }
            }
            .navigationTitle("Members")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
