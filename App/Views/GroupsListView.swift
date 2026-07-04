import SwiftUI
import SwiftData

struct GroupsListView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \SpendingGroup.createdAt, order: .reverse) private var groups: [SpendingGroup]
    @State private var showingNewGroup = false

    var body: some View {
        NavigationStack {
            Group {
                if groups.isEmpty {
                    ContentUnavailableView {
                        Label("No groups yet", systemImage: "person.3")
                    } description: {
                        Text("Create a group for your trip, house, or friends and start splitting expenses — every feature is free.")
                    } actions: {
                        Button("Create a group") { showingNewGroup = true }
                            .buttonStyle(.borderedProminent)
                    }
                } else {
                    List {
                        ForEach(groups) { group in
                            NavigationLink(value: group.id) {
                                GroupRow(group: group)
                            }
                        }
                        .onDelete { offsets in
                            for offset in offsets { context.delete(groups[offset]) }
                            try? context.save()
                        }
                    }
                }
            }
            .navigationTitle("SplitFree")
            .navigationDestination(for: UUID.self) { id in
                if let group = groups.first(where: { $0.id == id }) {
                    GroupDetailView(group: group)
                }
            }
            .toolbar {
                Button {
                    showingNewGroup = true
                } label: {
                    Image(systemName: "plus")
                }
            }
            .sheet(isPresented: $showingNewGroup) {
                GroupFormView()
            }
        }
    }
}

private struct GroupRow: View {
    let group: SpendingGroup

    var body: some View {
        HStack(spacing: 12) {
            Text(group.emoji)
                .font(.title2)
                .frame(width: 44, height: 44)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 2) {
                Text(group.name).font(.headline)
                Text(summaryLine)
                    .font(.subheadline)
                    .foregroundStyle(myBalance == 0 ? .secondary : myBalance > 0 ? Color.green : Color.orange)
            }
            Spacer()
        }
        .padding(.vertical, 2)
    }

    private var myBalance: Int {
        guard let me = group.sortedMembers.first(where: { $0.isCurrentUser }) else { return 0 }
        return group.balances[me.id] ?? 0
    }

    private var summaryLine: String {
        if (group.expenses ?? []).isEmpty { return "No expenses yet" }
        if myBalance == 0 { return "You're settled up" }
        let amount = abs(myBalance).asMoney(group.currencyCode)
        return myBalance > 0 ? "You are owed \(amount)" : "You owe \(amount)"
    }
}

struct GroupFormView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var emoji = "✈️"
    @State private var currencyCode = "USD"
    @State private var memberNames: [String] = [""]

    private let emojiOptions = ["✈️", "🏠", "🍕", "🎉", "⛺️", "💼", "❤️", "👥"]

    var body: some View {
        NavigationStack {
            Form {
                Section("Group") {
                    TextField("Name (e.g. Tahoe Trip)", text: $name)
                    Picker("Icon", selection: $emoji) {
                        ForEach(emojiOptions, id: \.self) { Text($0).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    Picker("Currency", selection: $currencyCode) {
                        ForEach(SupportedCurrencies.all, id: \.self) { Text($0).tag($0) }
                    }
                }
                Section {
                    LabeledContent("You", value: "included automatically")
                    ForEach(memberNames.indices, id: \.self) { index in
                        TextField("Member name", text: $memberNames[index])
                    }
                    Button("Add another member", systemImage: "plus.circle") {
                        memberNames.append("")
                    }
                } header: {
                    Text("Members")
                } footer: {
                    Text("Members live on this device today. iCloud sharing via CloudKit is on the roadmap — no accounts, no servers.")
                }
            }
            .navigationTitle("New group")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") { create() }
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }

    private func create() {
        let group = SpendingGroup(name: name.trimmingCharacters(in: .whitespaces),
                                  emoji: emoji, currencyCode: currencyCode)
        context.insert(group)
        var members: [Member] = [Member(name: "You", isCurrentUser: true, colorHue: 0.55)]
        let names = memberNames.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        for (index, memberName) in names.enumerated() {
            let hue = (0.55 + Double(index + 1) * 0.17).truncatingRemainder(dividingBy: 1)
            members.append(Member(name: memberName, colorHue: hue))
        }
        group.members = members
        try? context.save()
        dismiss()
    }
}

enum SupportedCurrencies {
    static let all = ["USD", "EUR", "GBP", "JPY", "CAD", "AUD", "INR", "MXN",
                      "BRL", "CHF", "CNY", "KRW", "SEK", "NOK", "DKK", "NZD",
                      "SGD", "HKD", "THB", "VND", "PHP", "IDR", "TRY", "ZAR",
                      "AED", "SAR", "ILS", "PLN", "CZK", "HUF"]
}
