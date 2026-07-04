import SwiftUI
import SwiftData
import SplitCore

/// Settle-up: shows the minimal transfer plan and records payments.
///
/// Why no in-app Apple Pay button: Apple exposes no public API for sending
/// person-to-person Apple Cash payments (PassKit is for paying merchants and
/// requires a payment processor). The free, serverless approach is to open
/// Messages with the amount prefilled — iMessage surfaces its own Apple Cash
/// suggestion — and record the settlement here.
struct SettleUpView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    let group: SpendingGroup
    @State private var recordingTransfer: Transfer?
    @State private var showingManualPayment = false

    var body: some View {
        NavigationStack {
            List {
                if group.suggestedTransfers.isEmpty {
                    ContentUnavailableView("All settled up",
                                           systemImage: "checkmark.seal.fill",
                                           description: Text("Nobody owes anything in this group."))
                } else {
                    Section {
                        ForEach(Array(group.suggestedTransfers.enumerated()), id: \.offset) { _, transfer in
                            TransferRow(group: group, transfer: transfer) {
                                recordingTransfer = transfer
                            }
                        }
                    } header: {
                        Text("Suggested payments")
                    } footer: {
                        Text("Debts are simplified to the fewest possible payments. Tapping the Messages button pre-fills the amount so Apple Cash is one tap away — then record it here.")
                    }
                }
                Section {
                    Button("Record a different payment", systemImage: "square.and.pencil") {
                        showingManualPayment = true
                    }
                }
                if !(group.settlements ?? []).isEmpty {
                    Section("Past payments") {
                        ForEach((group.settlements ?? []).sorted { $0.date > $1.date }) { settlement in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("\(settlement.from?.displayName ?? "?") paid \(settlement.to?.displayName ?? "?")")
                                    Text("\(settlement.method.displayName) · \(settlement.date.formatted(date: .abbreviated, time: .omitted))")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text(settlement.money.formatted()).font(.callout.weight(.semibold))
                            }
                        }
                        .onDelete { offsets in
                            let sorted = (group.settlements ?? []).sorted { $0.date > $1.date }
                            for offset in offsets { context.delete(sorted[offset]) }
                            try? context.save()
                        }
                    }
                }
            }
            .navigationTitle("Settle up")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(item: $recordingTransfer) { transfer in
                RecordPaymentView(group: group,
                                  fromID: transfer.from,
                                  toID: transfer.to,
                                  amount: Money(minorUnits: transfer.minorUnits,
                                                currencyCode: group.currencyCode).decimalValue)
            }
            .sheet(isPresented: $showingManualPayment) {
                RecordPaymentView(group: group)
            }
        }
    }
}

extension Transfer: Identifiable {
    public var id: String { "\(from)-\(to)-\(minorUnits)" }
}

private struct TransferRow: View {
    let group: SpendingGroup
    let transfer: Transfer
    let onRecord: () -> Void

    private var fromMember: Member? { group.member(id: transfer.from) }
    private var toMember: Member? { group.member(id: transfer.to) }
    private var amountText: String { transfer.minorUnits.asMoney(group.currencyCode) }
    private var involvesMe: Bool {
        fromMember?.isCurrentUser == true || toMember?.isCurrentUser == true
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                if let fromMember { MemberAvatar(member: fromMember, size: 28) }
                Image(systemName: "arrow.right")
                    .font(.caption).foregroundStyle(.secondary)
                if let toMember { MemberAvatar(member: toMember, size: 28) }
                Text("\(fromMember?.displayName ?? "?") pays \(toMember?.displayName ?? "?")")
                    .font(.subheadline)
                Spacer()
                Text(amountText).font(.headline)
            }
            HStack {
                if involvesMe {
                    Button {
                        openMessages()
                    } label: {
                        Label(fromMember?.isCurrentUser == true ? "Pay in Messages" : "Request in Messages",
                              systemImage: "message.fill")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                Button("Record payment", systemImage: "checkmark.circle", action: onRecord)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
        }
        .padding(.vertical, 4)
    }

    private func openMessages() {
        let paying = fromMember?.isCurrentUser == true
        let other = paying ? toMember?.name : fromMember?.name
        let body = paying
            ? "Sending you \(amountText) for \(group.name) 💸 (Apple Cash)"
            : "Hey\(other.map { " \($0)" } ?? "")! Requesting \(amountText) for \(group.name) 💸 (Apple Cash)"
        var components = URLComponents(string: "sms:")
        components?.queryItems = [URLQueryItem(name: "body", value: body)]
        if let url = components?.url {
            UIApplication.shared.open(url)
        }
    }
}

struct RecordPaymentView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    let group: SpendingGroup
    @State var fromID: UUID?
    @State var toID: UUID?
    @State var amount: Decimal = 0
    @State private var method = SettlementMethod.appleCash
    @State private var date = Date.now

    init(group: SpendingGroup, fromID: UUID? = nil, toID: UUID? = nil, amount: Decimal = 0) {
        self.group = group
        _fromID = State(initialValue: fromID)
        _toID = State(initialValue: toID)
        _amount = State(initialValue: amount)
    }

    var body: some View {
        NavigationStack {
            Form {
                Picker("From", selection: $fromID) {
                    Text("Choose").tag(UUID?.none)
                    ForEach(group.sortedMembers) { Text($0.displayName).tag(Optional($0.id)) }
                }
                Picker("To", selection: $toID) {
                    Text("Choose").tag(UUID?.none)
                    ForEach(group.sortedMembers) { Text($0.displayName).tag(Optional($0.id)) }
                }
                HStack {
                    Text("Amount (\(group.currencyCode))")
                    AmountField(title: "0.00", value: $amount)
                }
                Picker("Method", selection: $method) {
                    ForEach(SettlementMethod.allCases) { Text($0.displayName).tag($0) }
                }
                DatePicker("Date", selection: $date, displayedComponents: .date)
            }
            .navigationTitle("Record payment")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(fromID == nil || toID == nil || fromID == toID || amount <= 0)
                }
            }
        }
        .presentationDetents([.medium])
    }

    private func save() {
        guard let fromID, let toID else { return }
        let settlement = Settlement(from: group.member(id: fromID),
                                    to: group.member(id: toID),
                                    amountMinorUnits: Money(amount, currencyCode: group.currencyCode).minorUnits,
                                    method: method)
        settlement.date = date
        settlement.group = group
        context.insert(settlement)
        try? context.save()
        dismiss()
    }
}
