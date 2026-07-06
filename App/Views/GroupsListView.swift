import SwiftUI
import CoreData

struct GroupsListView: View {
    @Environment(\.managedObjectContext) private var context
    @FetchRequest(fetchRequest: SpendingGroup.fetchAll(), animation: .default)
    private var groups: FetchedResults<SpendingGroup>
    @State private var showingNewGroup = false
    @State private var pendingDeletion: PendingDeletion?
    @State private var leaveFailed = false
    @StateObject private var syncStatus = CloudSyncStatus.shared

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
                            for offset in offsets { requestDeletion(of: groups[offset]) }
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
            .alert(pendingDeletion?.title ?? "", isPresented: Binding(
                get: { pendingDeletion != nil },
                set: { if !$0 { pendingDeletion = nil } }
            ), presenting: pendingDeletion) { pending in
                Button(pending.confirmTitle, role: .destructive) { confirmPending(pending) }
                Button("Cancel", role: .cancel) {}
            } message: { pending in
                Text(pending.message)
            }
            .alert("Couldn't leave the group", isPresented: $leaveFailed) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("Check your connection and try again.")
            }
            .safeAreaInset(edge: .top) {
                if syncStatus.state != .healthy {
                    SyncHealthBanner(state: syncStatus.state)
                }
            }
        }
    }

    /// Routes a swipe-delete: a group shared TO you is left (not deleted, which
    /// would export and destroy it for everyone); a group you own with a share
    /// asks first (deleting a shared group can't be undone and hits everyone);
    /// an unshared/local group deletes outright.
    private func requestDeletion(of group: SpendingGroup) {
        let controller = PersistenceController.shared
        guard let share = controller.existingShare(for: group) else {
            delete(group)
            return
        }
        if controller.isOwner(of: group) {
            // Ownership can't be handed off, so an owner delete is a delete for
            // all. Link-join can understate the mirror's participant list, so
            // always confirm when a share exists.
            let others = share.participants.filter { $0 != share.owner }.count
            pendingDeletion = .ownerDelete(group, others: others)
        } else {
            pendingDeletion = .leave(group)
        }
    }

    private func confirmPending(_ pending: PendingDeletion) {
        switch pending {
        case .leave(let group):
            Task {
                do { try await PersistenceController.shared.leave(group: group) }
                catch { leaveFailed = true }
            }
        case .ownerDelete(let group, _):
            delete(group)
        }
    }

    private func delete(_ group: SpendingGroup) {
        context.delete(group)
        try? context.save()
    }
}

/// Non-blocking warning shown above the list when iCloud can't sync. Only
/// rendered for non-healthy states, so `.healthy` needs no copy.
private struct SyncHealthBanner: View {
    let state: CloudSyncStatus.State

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
            Text(message)
            Spacer(minLength: 0)
        }
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal)
        .padding(.top, 4)
        .accessibilityIdentifier("SyncHealthBanner")
    }

    private var symbol: String {
        switch state {
        case .storageFull: return "exclamationmark.icloud"
        default: return "icloud.slash"
        }
    }

    private var message: String {
        switch state {
        case .noAccount: return "Sign in to iCloud to sync and share groups."
        case .unavailable: return "iCloud is temporarily unavailable. Syncing is paused."
        case .storageFull: return "Your iCloud storage is full. Changes aren't syncing."
        case .healthy: return ""
        }
    }
}

private enum PendingDeletion: Identifiable {
    case leave(SpendingGroup)
    case ownerDelete(SpendingGroup, others: Int)

    var group: SpendingGroup {
        switch self {
        case .leave(let group), .ownerDelete(let group, _): return group
        }
    }
    var id: NSManagedObjectID { group.objectID }

    var title: String {
        switch self {
        case .leave: return "Leave this group?"
        case .ownerDelete: return "Delete for everyone?"
        }
    }

    var confirmTitle: String {
        switch self {
        case .leave: return "Leave"
        case .ownerDelete: return "Delete for everyone"
        }
    }

    var message: String {
        switch self {
        case .leave:
            return "You'll stop seeing this group, but your expenses stay in it for everyone else."
        case .ownerDelete(_, let others):
            guard others > 0 else {
                return "You shared this group. Deleting it removes it from any device it was shared to — this can't be undone."
            }
            let people = others == 1 ? "1 other person is" : "\(others) other people are"
            return "\(people) in this group. Deleting it removes it from their devices too — this can't be undone."
        }
    }
}

private struct GroupRow: View {
    @ObservedObject var group: SpendingGroup
    @StateObject private var ledger = LedgerRefresher()

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
                    .foregroundStyle((myBalance ?? 0) == 0 ? .secondary : myBalance! > 0 ? Color.green : Color.orange)
            }
            Spacer()
        }
        .padding(.vertical, 2)
    }

    private var myBalance: Int? {
        guard let me = group.sortedMembers.first(where: { $0.isMe }) else { return nil }
        return group.balances[me.id] ?? 0
    }

    private var summaryLine: String {
        if (group.expenses ?? []).isEmpty { return "No expenses yet" }
        guard let myBalance else { return "Tap to pick your name" }
        if myBalance == 0 { return "You're settled up" }
        let amount = abs(myBalance).asMoney(group.currencyCode)
        return myBalance > 0 ? "You are owed \(amount)" : "You owe \(amount)"
    }
}

struct GroupFormView: View {
    @Environment(\.managedObjectContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var yourName = ""
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
                    TextField("Your name", text: $yourName)
                    ForEach(memberNames.indices, id: \.self) { index in
                        TextField("Member name", text: $memberNames[index])
                    }
                    Button("Add another member", systemImage: "plus.circle") {
                        memberNames.append("")
                    }
                } header: {
                    Text("Members")
                } footer: {
                    Text("Use real names — friends you invite see them too. Invite friends from the group's Share button and everyone sees the same live ledger through iCloud — no accounts, no servers.")
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
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty ||
                                  yourName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }

    private func create() {
        let group = SpendingGroup(context: context, name: name.trimmingCharacters(in: .whitespaces),
                                  emoji: emoji, currencyCode: currencyCode)
        let you = Member(context: context, name: yourName.trimmingCharacters(in: .whitespaces),
                         isCurrentUser: true, colorHue: 0.55)
        you.group = group
        let names = memberNames.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        for (index, memberName) in names.enumerated() {
            let hue = (0.55 + Double(index + 1) * 0.17).truncatingRemainder(dividingBy: 1)
            let member = Member(context: context, name: memberName, colorHue: hue)
            member.group = group
        }
        CurrentUser.claim(you)
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
