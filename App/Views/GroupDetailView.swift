import SwiftUI
import CoreData
import CloudKit
import SplitCore
import OSLog

struct GroupDetailView: View {
    @Environment(\.managedObjectContext) private var context
    @ObservedObject var group: SpendingGroup
    @State private var showingAddExpense = false
    @State private var showingSettleUp = false
    @State private var showingMembers = false
    @State private var expenseToEdit: Expense?
    @State private var sharePreparationFailed = false
    @State private var inviteLinkCopied = false
    @State private var needsClaim = false

    var body: some View {
        List {
            balancesSection
            expensesSection
        }
        .navigationTitle("\(group.emoji) \(group.name)")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if PersistenceController.shared.isCloudBacked {
                ToolbarItem(placement: .primaryAction) {
                    // The system share sheet with a collaboration item is
                    // the invite path that actually works from SwiftUI;
                    // UICloudSharingController only manages existing shares.
                    ShareLink(item: GroupShareItem(group: group),
                              preview: SharePreview(group.name)) {
                        Label("Share group", systemImage: "person.crop.circle.badge.plus")
                    }
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    if PersistenceController.shared.isCloudBacked {
                        Button("Copy invite link", systemImage: "link") {
                            copyInviteLink()
                        }
                        if PersistenceController.shared.existingShare(for: group) != nil {
                            Button("Manage sharing", systemImage: "person.2.badge.gearshape") {
                                manageSharing()
                            }
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
        .alert("Couldn't prepare the share", isPresented: $sharePreparationFailed) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Check that you're signed into iCloud and try again.")
        }
        .alert("Invite link copied", isPresented: $inviteLinkCopied) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Send it to your friends — anyone with the link can join this group.")
        }
        .onAppear {
            needsClaim = !CurrentUser.hasClaim(in: group)
        }
        .fullScreenCover(isPresented: $needsClaim) {
            ClaimMemberView(group: group) { needsClaim = false }
        }
    }

    /// Puts the group's share URL on the pasteboard, creating the share the
    /// first time. Works even where the system share sheet misbehaves.
    private func copyInviteLink() {
        Task {
            do {
                let share = try await PersistenceController.shared.share(group: group)
                guard let url = share.url else {
                    sharePreparationFailed = true
                    return
                }
                UIPasteboard.general.url = url
                inviteLinkCopied = true
            } catch {
                sharePreparationFailed = true
            }
        }
    }

    /// Participant list, permissions, stop sharing — the management UI.
    /// Presented from UIKit directly: UICloudSharingController's actions
    /// misfire when it's wrapped in a SwiftUI sheet.
    private func manageSharing() {
        Task {
            do {
                let share = try await PersistenceController.shared.share(group: group)
                CloudSharePresenter.presentManagement(for: share, title: group.name)
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

/// Collaboration item for the system share sheet: hands ShareLink the group's
/// CKShare (creating it on demand), so Messages/Mail/Copy Link send a real
/// CloudKit invite. Everyone who joins sees the same live group.
struct GroupShareItem: Transferable {
    let group: SpendingGroup

    static var transferRepresentation: some TransferRepresentation {
        CKShareTransferRepresentation { item in
            let log = Logger(subsystem: "com.sank.splitfree", category: "sharing")
            let container = CKContainer(identifier: PersistenceController.cloudKitContainerID)
            if let share = PersistenceController.shared.existingShare(for: item.group) {
                log.log("exporter: existing share, url: \(share.url?.absoluteString ?? "nil", privacy: .public)")
                return .existing(share, container: container)
            }
            log.log("exporter: prepareShare branch")
            let options = CKAllowedSharingOptions(allowedParticipantPermissionOptions: .any,
                                                  allowedParticipantAccessOptions: .any)
            return .prepareShare(container: container, allowedSharingOptions: options) {
                log.log("preparationHandler: creating share")
                let share = try await PersistenceController.shared.share(group: item.group)
                log.log("preparationHandler: created, url: \(share.url?.absoluteString ?? "nil", privacy: .public)")
                return share
            }
        }
    }
}

/// Participant list, permissions, stop sharing. Presented directly from the
/// top UIKit view controller: UICloudSharingController's buttons silently
/// fail when the controller lives inside a SwiftUI sheet.
@MainActor
enum CloudSharePresenter {
    private static var delegate: Delegate?

    static func presentManagement(for share: CKShare, title: String) {
        let container = CKContainer(identifier: PersistenceController.cloudKitContainerID)
        let controller = UICloudSharingController(share: share, container: container)
        controller.availablePermissions = [.allowReadWrite, .allowPrivate, .allowPublic]
        let holder = Delegate(title: title)
        delegate = holder // the controller only holds a weak reference
        controller.delegate = holder

        guard let scene = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene })
                .first(where: { $0.activationState == .foregroundActive }),
              let root = scene.keyWindow?.rootViewController else { return }
        var top = root
        while let presented = top.presentedViewController { top = presented }
        top.present(controller, animated: true)
    }

    final class Delegate: NSObject, UICloudSharingControllerDelegate {
        let title: String
        init(title: String) { self.title = title }

        func itemTitle(for csc: UICloudSharingController) -> String? { title }

        func cloudSharingControllerDidSaveShare(_ csc: UICloudSharingController) {
            // Participant/permission edits happen server-side; without this the
            // local mirror keeps the stale share record.
            if let share = csc.share {
                PersistenceController.shared.persistUpdatedShare(share)
            }
        }

        func cloudSharingController(_ csc: UICloudSharingController,
                                    failedToSaveShareWithError error: Error) {
            print("Share save failed: \(error)")
        }

        func cloudSharingControllerDidStopSharing(_ csc: UICloudSharingController) {
            if let share = csc.share {
                PersistenceController.shared.persistUpdatedShare(share)
            }
        }
    }
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

/// Blocks a group until the person says who they are: joined-from-invite
/// users must claim an existing member or add themselves before they can
/// see or touch the ledger.
struct ClaimMemberView: View {
    @Environment(\.managedObjectContext) private var context
    @ObservedObject var group: SpendingGroup
    let onClaimed: () -> Void
    @State private var newName = ""

    var body: some View {
        NavigationStack {
            List {
                if !group.sortedMembers.isEmpty {
                    Section {
                        ForEach(group.sortedMembers) { member in
                            Button {
                                CurrentUser.claim(member)
                                onClaimed()
                            } label: {
                                HStack {
                                    MemberAvatar(member: member, size: 30)
                                    Text(member.name)
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .font(.caption)
                                        .foregroundStyle(.tertiary)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    } header: {
                        Text("Pick your name")
                    } footer: {
                        Text("If someone already added you, choose that name so existing expenses stay yours.")
                    }
                }
                Section("Not in the list?") {
                    HStack {
                        TextField("Your name", text: $newName)
                        Button("Join") {
                            let trimmed = newName.trimmingCharacters(in: .whitespaces)
                            guard !trimmed.isEmpty else { return }
                            let member = Member(context: context, name: trimmed,
                                                colorHue: Double.random(in: 0...1))
                            member.group = group
                            try? context.save()
                            CurrentUser.claim(member)
                            onClaimed()
                        }
                        .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            }
            .navigationTitle("Who are you?")
            .navigationBarTitleDisplayMode(.inline)
        }
        .interactiveDismissDisabled()
    }
}

struct MembersView: View {
    @Environment(\.managedObjectContext) private var context
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var group: SpendingGroup
    @State private var newName = ""
    @State private var memberToRename: Member?
    @State private var renameText = ""
    @State private var claimRefresh = 0

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(group.sortedMembers) { member in
                        HStack {
                            MemberAvatar(member: member, size: 30)
                            Text(member.displayName)
                            if member.isMe {
                                Image(systemName: "checkmark.seal.fill")
                                    .font(.caption)
                                    .foregroundStyle(.tint)
                            }
                            Spacer()
                            BalancePill(minorUnits: group.balances[member.id] ?? 0,
                                        currencyCode: group.currencyCode)
                        }
                        .contextMenu {
                            Button("This is me", systemImage: "person.crop.circle.badge.checkmark") {
                                CurrentUser.claim(member)
                                claimRefresh += 1
                            }
                            Button("Rename", systemImage: "pencil") {
                                renameText = member.name
                                memberToRename = member
                            }
                        }
                    }
                } footer: {
                    Text("The checkmark shows which member is you on this device. Touch and hold a member to rename them.")
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
            .id(claimRefresh)
            .navigationTitle("Members")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .alert("Rename member", isPresented: Binding(
                get: { memberToRename != nil },
                set: { if !$0 { memberToRename = nil } })) {
                TextField("Name", text: $renameText)
                Button("Save") {
                    let trimmed = renameText.trimmingCharacters(in: .whitespaces)
                    if let member = memberToRename, !trimmed.isEmpty {
                        member.name = trimmed
                        try? context.save()
                    }
                    memberToRename = nil
                }
                Button("Cancel", role: .cancel) { memberToRename = nil }
            }
        }
    }
}
