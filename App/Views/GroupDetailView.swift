import SwiftUI
import CoreData
import CloudKit
import SplitCore

struct GroupDetailView: View {
    @Environment(\.managedObjectContext) private var context
    @ObservedObject var group: SpendingGroup
    @State private var showingAddExpense = false
    @State private var showingSettleUp = false
    @State private var showingMembers = false
    @State private var expenseToEdit: Expense?
    @State private var shareToPresent: PreparedShare?
    @State private var sharePreparationFailed = false

    struct PreparedShare: Identifiable {
        let id = UUID()
        let share: CKShare
    }

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
                    if PersistenceController.shared.isCloudBacked {
                        Button("Share group", systemImage: "person.crop.circle.badge.plus") {
                            prepareShare()
                        }
                    }
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
        .sheet(item: $shareToPresent) { prepared in
            CloudSharingView(share: prepared.share,
                             container: CKContainer(identifier: PersistenceController.cloudKitContainerID),
                             title: group.name)
                .ignoresSafeArea()
        }
        .alert("Couldn't prepare the share", isPresented: $sharePreparationFailed) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Check that you're signed into iCloud and try again.")
        }
    }

    private func prepareShare() {
        Task {
            do {
                shareToPresent = PreparedShare(share: try await PersistenceController.shared.share(group: group))
            } catch {
                sharePreparationFailed = true
            }
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

/// The system iCloud sharing sheet: invite people, manage participants,
/// stop sharing. Everyone invited sees the same live group.
struct CloudSharingView: UIViewControllerRepresentable {
    let share: CKShare
    let container: CKContainer
    let title: String

    func makeUIViewController(context: Context) -> UICloudSharingController {
        share[CKShare.SystemFieldKey.title] = title as CKRecordValue
        let controller = UICloudSharingController(share: share, container: container)
        controller.availablePermissions = [.allowReadWrite, .allowPrivate]
        return controller
    }

    func updateUIViewController(_ controller: UICloudSharingController, context: Context) {}
}

struct ExpenseRow: View {
    @ObservedObject var expense: Expense

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
    @Environment(\.managedObjectContext) private var context
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var group: SpendingGroup
    @State private var newName = ""

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(group.sortedMembers) { member in
                        HStack {
                            MemberAvatar(member: member, size: 30)
                            Text(member.displayName)
                            Spacer()
                            BalancePill(minorUnits: group.balances[member.id] ?? 0,
                                        currencyCode: group.currencyCode)
                        }
                        .contextMenu {
                            Button("This is me", systemImage: "person.crop.circle.badge.checkmark") {
                                CurrentUser.claim(member)
                            }
                        }
                    }
                } footer: {
                    if !CurrentUser.hasClaim(in: group) {
                        Text("Joined this group from an invite? Touch and hold your name and choose \"This is me\".")
                    }
                }
                Section {
                    HStack {
                        TextField("New member name", text: $newName)
                        Button("Add") {
                            let trimmed = newName.trimmingCharacters(in: .whitespaces)
                            guard !trimmed.isEmpty else { return }
                            let member = Member(context: context, name: trimmed,
                                                colorHue: Double.random(in: 0...1))
                            member.group = group
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
