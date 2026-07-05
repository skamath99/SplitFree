import SwiftUI
import CoreData
import CloudKit
import SplitCore
import OSLog

struct GroupDetailView: View {
    @Environment(\.managedObjectContext) private var context
    @ObservedObject var group: SpendingGroup
    @StateObject private var ledger = LedgerRefresher()
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
            CurrentUser.backfillSyncedClaim(in: group)
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
            // Always go through prepareShare, even when a share already exists:
            // an existing share can be half-published (no URL, publicPermission
            // .none) — the exact state that gives link recipients "no permission
            // to open". share(group:) returns the existing share AND re-runs
            // publish(), which repairs it. The old .existing fast path skipped
            // that and shipped the broken share as-is.
            log.log("exporter: prepareShare branch")
            let options = CKAllowedSharingOptions(allowedParticipantPermissionOptions: .any,
                                                  allowedParticipantAccessOptions: .any)
            return .prepareShare(container: container, allowedSharingOptions: options) {
                log.log("preparationHandler: publishing share")
                let share = try await PersistenceController.shared.share(group: item.group)
                log.log("preparationHandler: published, url: \(share.url?.absoluteString ?? "nil", privacy: .public)")
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
    @State private var joinError: String?

    // An imported Member sets its inverse (member.group = group); that does not
    // reliably fire the group's objectWillChange, so @ObservedObject group can
    // stay empty after the members import lands. Fetch members directly so
    // context inserts are observed and the list fills in live once they arrive.
    @FetchRequest private var members: FetchedResults<Member>

    init(group: SpendingGroup, onClaimed: @escaping () -> Void) {
        self.group = group
        self.onClaimed = onClaimed
        let request = NSFetchRequest<Member>(entityName: "Member")
        request.predicate = NSPredicate(format: "group == %@", group)
        request.sortDescriptors = [NSSortDescriptor(key: "name", ascending: true)]
        _members = FetchRequest(fetchRequest: request, animation: .default)
    }

    // Same ordering as SpendingGroup.sortedMembers, over the observed fetch.
    private var sortedMembers: [Member] {
        members.sorted { ($0.isMe ? 0 : 1, $0.name) < ($1.isMe ? 0 : 1, $1.name) }
    }

    var body: some View {
        NavigationStack {
            List {
                // A shared group always has at least one member (the owner), so
                // an empty list here can only mean the members import hasn't
                // finished. Show a loading state instead of the "Not in the list?"
                // join section, which would otherwise tempt the person to re-add
                // themselves and duplicate the member a friend already made.
                if sortedMembers.isEmpty {
                    Section {
                        HStack(spacing: 12) {
                            ProgressView()
                            Text("Loading members…")
                                .foregroundStyle(.secondary)
                        }
                    } footer: {
                        Text("This group is still syncing. Your name will appear here in a moment.")
                    }
                } else {
                    Section {
                        ForEach(sortedMembers) { member in
                            let taken = member.isClaimedByAnotherDevice
                            Button {
                                CurrentUser.claim(member)
                                onClaimed()
                            } label: {
                                HStack {
                                    MemberAvatar(member: member, size: 30)
                                    Text(member.name)
                                    Spacer()
                                    if taken {
                                        Text("Claimed")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    } else {
                                        Image(systemName: "chevron.right")
                                            .font(.caption)
                                            .foregroundStyle(.tertiary)
                                    }
                                }
                                .opacity(taken ? 0.5 : 1)
                                // Plain-style buttons only hit-test opaque label
                                // content, so the Spacer is a dead zone without this.
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .disabled(taken)
                        }
                    } header: {
                        Text("Pick your name")
                    } footer: {
                        Text("If someone already added you, choose that name so existing expenses stay yours. Names marked Claimed are already taken by other group members.")
                    }
                    Section("Not in the list?") {
                        HStack {
                            TextField("Your name", text: $newName)
                            Button("Join") { join() }
                                .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
                        }
                        if let joinError {
                            Text(joinError)
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                    }
                }
            }
            .navigationTitle("Who are you?")
            .navigationBarTitleDisplayMode(.inline)
            .onChange(of: newName) { joinError = nil }
        }
        .interactiveDismissDisabled()
    }

    private func join() {
        let trimmed = newName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        if let existing = sortedMembers.first(where: {
            $0.name.caseInsensitiveCompare(trimmed) == .orderedSame
        }) {
            joinError = existing.isClaimedByAnotherDevice
                ? "That name is already claimed."
                : "That name is already in the group — pick it from the list above."
            return
        }
        let member = Member(context: context, name: trimmed,
                            colorHue: Double.random(in: 0...1))
        member.group = group
        try? context.save()
        CurrentUser.claim(member)
        onClaimed()
    }
}

struct MembersView: View {
    @Environment(\.managedObjectContext) private var context
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var group: SpendingGroup
    @StateObject private var ledger = LedgerRefresher()
    @State private var newName = ""
    @State private var memberToRename: Member?
    @State private var renameText = ""

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(group.sortedMembers) { member in
                        HStack {
                            MemberAvatar(member: member, size: 30)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(member.displayName)
                                if !member.isClaimed {
                                    Text("Not claimed yet")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            if member.isMe {
                                Image(systemName: "checkmark.seal.fill")
                                    .font(.caption)
                                    .foregroundStyle(.tint)
                            } else if member.isClaimedByAnotherDevice {
                                Image(systemName: "checkmark.seal.fill")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            BalancePill(minorUnits: group.balances[member.id] ?? 0,
                                        currencyCode: group.currencyCode)
                        }
                        .contextMenu {
                            Button("This is me", systemImage: "person.crop.circle.badge.checkmark") {
                                CurrentUser.claim(member)
                            }
                            .disabled(member.isClaimedByAnotherDevice)
                            Button("Rename", systemImage: "pencil") {
                                renameText = member.name
                                memberToRename = member
                            }
                        }
                    }
                } footer: {
                    Text("A tinted seal marks who you are on this device; a grey seal marks a member another person has claimed. \"Not claimed yet\" means no one has picked that name. Touch and hold a member to rename them.")
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
