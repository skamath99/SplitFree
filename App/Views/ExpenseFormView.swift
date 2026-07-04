import SwiftUI
import SwiftData
import SplitCore

struct ExpenseFormView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    let group: SpendingGroup
    var existing: Expense?

    @State private var title = ""
    @State private var amount: Decimal = 0
    @State private var currencyCode = "USD"
    @State private var date = Date.now
    @State private var category = ExpenseCategory.general
    @State private var notes = ""
    @State private var payerID: UUID?
    @State private var splitMode = SplitMode.equal
    @State private var participantIDs: Set<UUID> = []
    @State private var inputs: [UUID: Decimal] = [:]
    @State private var recurrence = RecurrenceFrequency.none
    @State private var isItemized = false
    @State private var itemDrafts: [LineItemDraft] = []
    @State private var validationMessage: String?
    @State private var showingReceiptScanner = false

    private var members: [Member] { group.sortedMembers }
    private var totalMinorUnits: Int { Money(amount, currencyCode: currencyCode).minorUnits }

    var body: some View {
        NavigationStack {
            Form {
                detailsSection
                payerSection
                if isItemized {
                    itemizedSection
                } else {
                    splitSection
                }
                extrasSection
                if let validationMessage {
                    Section {
                        Label(validationMessage, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                }
            }
            .navigationTitle(existing == nil ? "Add expense" : "Edit expense")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty || amount <= 0)
                }
            }
            .sheet(isPresented: $showingReceiptScanner) {
                ReceiptScannerView { scannedTotal in
                    amount = scannedTotal
                    if title.isEmpty { title = "Receipt" }
                }
            }
            .onAppear(perform: populate)
        }
    }

    private var detailsSection: some View {
        Section {
            TextField("Title (e.g. Dinner at Luigi's)", text: $title)
            HStack {
                Picker("", selection: $currencyCode) {
                    ForEach(SupportedCurrencies.all, id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden()
                .frame(width: 90)
                AmountField(title: "0.00", value: $amount)
                    .font(.title3.weight(.semibold))
            }
            Button("Scan receipt for total", systemImage: "doc.text.viewfinder") {
                showingReceiptScanner = true
            }
            DatePicker("Date", selection: $date, displayedComponents: .date)
            Picker("Category", selection: $category) {
                ForEach(ExpenseCategory.allCases) { category in
                    Label(category.displayName, systemImage: category.symbol).tag(category)
                }
            }
        } footer: {
            if currencyCode != group.currencyCode {
                let converted = CurrencyConverter.bundledSnapshot
                    .convert(Money(amount, currencyCode: currencyCode), to: group.currencyCode)
                Text("≈ \(converted?.formatted() ?? "?") in this group's \(group.currencyCode). Balances use the built-in rate — free, no subscription.")
            }
        }
    }

    private var payerSection: some View {
        Section("Paid by") {
            Picker("Payer", selection: $payerID) {
                ForEach(members) { member in
                    Text(member.displayName).tag(Optional(member.id))
                }
            }
            .pickerStyle(.menu)
        }
    }

    private var splitSection: some View {
        Section {
            Picker("Split", selection: $splitMode) {
                ForEach(SplitMode.allCases, id: \.self) { mode in
                    Text(mode.shortName).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            ForEach(members) { member in
                SplitMemberRow(member: member,
                               isIncluded: participantIDs.contains(member.id),
                               mode: splitMode,
                               input: inputBinding(for: member.id),
                               computedText: computedShareText(for: member.id)) {
                    toggle(member.id)
                }
            }
        } header: {
            Text("Split \(splitMode.displayName.lowercased())")
        } footer: {
            Text(splitFooter)
        }
    }

    private var itemizedSection: some View {
        Section {
            ForEach($itemDrafts) { $draft in
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        TextField("Item", text: $draft.name)
                        AmountField(title: "0.00", value: $draft.amount)
                            .frame(width: 90)
                    }
                    MemberChips(members: members, selected: $draft.participantIDs)
                }
                .padding(.vertical, 2)
            }
            .onDelete { itemDrafts.remove(atOffsets: $0) }

            Button("Add item", systemImage: "plus.circle") {
                itemDrafts.append(LineItemDraft(participantIDs: Set(members.map(\.id))))
            }
        } header: {
            Text("Items")
        } footer: {
            Text(itemizedFooter)
        }
    }

    private var extrasSection: some View {
        Section {
            Toggle("Itemize (split by line item)", isOn: $isItemized.animation())
                .onChange(of: isItemized) {
                    if isItemized && itemDrafts.isEmpty {
                        itemDrafts = [LineItemDraft(participantIDs: Set(members.map(\.id)))]
                    }
                }
            Picker("Repeats", selection: $recurrence) {
                ForEach(RecurrenceFrequency.allCases) { Text($0.displayName).tag($0) }
            }
            TextField("Notes", text: $notes, axis: .vertical)
        } footer: {
            if recurrence != .none {
                Text("A copy of this expense is added automatically every \(recurrence == .weekly ? "week" : "month").")
            }
        }
    }

    // MARK: - Split helpers

    private func toggle(_ id: UUID) {
        if participantIDs.contains(id) {
            participantIDs.remove(id)
        } else {
            participantIDs.insert(id)
        }
    }

    private func inputBinding(for id: UUID) -> Binding<Decimal> {
        Binding(get: { inputs[id] ?? 0 }, set: { inputs[id] = $0 })
    }

    private var orderedParticipants: [UUID] {
        members.map(\.id).filter { participantIDs.contains($0) }
    }

    private func currentShares() throws -> [UUID: Int] {
        var shareInputs: [UUID: Decimal] = [:]
        for id in orderedParticipants {
            shareInputs[id] = splitMode == .exactAmounts
                ? Decimal(Money(inputs[id] ?? 0, currencyCode: currencyCode).minorUnits)
                : (inputs[id] ?? 0)
        }
        return try SplitCalculator.shares(totalMinorUnits: totalMinorUnits,
                                          mode: splitMode,
                                          participants: orderedParticipants,
                                          inputs: shareInputs)
    }

    private func computedShareText(for id: UUID) -> String? {
        guard participantIDs.contains(id), totalMinorUnits > 0 else { return nil }
        guard let shares = try? currentShares() else { return nil }
        return shares[id]?.asMoney(currencyCode)
    }

    private var splitFooter: String {
        switch splitMode {
        case .equal:
            return "Everyone selected pays the same. Leftover pennies go to the first people in the list."
        case .exactAmounts:
            let entered = orderedParticipants
                .map { Money(inputs[$0] ?? 0, currencyCode: currencyCode).minorUnits }
                .reduce(0, +)
            let remaining = totalMinorUnits - entered
            return remaining == 0 ? "Amounts add up — nice."
                : "\(abs(remaining).asMoney(currencyCode)) \(remaining > 0 ? "left to assign" : "over the total")."
        case .percentages:
            let total = orderedParticipants.map { inputs[$0] ?? 0 }.reduce(Decimal(0), +)
            return "Percentages add up to \(total)%."
        case .shares:
            return "Split proportionally — e.g. 2 shares for a couple, 1 for a single."
        }
    }

    private var itemizedFooter: String {
        let itemsTotal = itemDrafts.map { Money($0.amount, currencyCode: currencyCode).minorUnits }.reduce(0, +)
        let remainder = totalMinorUnits - itemsTotal
        if remainder == 0 { return "Items cover the whole bill." }
        if remainder > 0 {
            return "\(remainder.asMoney(currencyCode)) of tax/tip will be split proportionally to what each person ordered."
        }
        return "Items exceed the total by \(abs(remainder).asMoney(currencyCode)) — check the amounts."
    }

    /// Itemized shares: each item splits equally among its people; the
    /// remainder (tax/tip) is spread proportionally to each person's subtotal.
    private func itemizedShares() throws -> [UUID: Int] {
        guard !itemDrafts.isEmpty else { throw SplitError.noParticipants }
        var subtotals: [UUID: Int] = [:]
        for draft in itemDrafts {
            let people = members.map(\.id).filter { draft.participantIDs.contains($0) }
            guard !people.isEmpty else { throw SplitError.noParticipants }
            let itemAmount = Money(draft.amount, currencyCode: currencyCode).minorUnits
            let split = SplitCalculator.allocate(totalMinorUnits: itemAmount, weights: people.map { _ in 1 })
            for (person, amount) in zip(people, split) {
                subtotals[person, default: 0] += amount
            }
        }
        let itemsTotal = subtotals.values.reduce(0, +)
        let remainder = totalMinorUnits - itemsTotal
        guard remainder >= 0 else {
            throw SplitError.exactAmountsMismatch(expected: totalMinorUnits, got: itemsTotal)
        }
        if remainder > 0 {
            let people = subtotals.keys.sorted { $0.uuidString < $1.uuidString }
            let weights = people.map { subtotals[$0]! > 0 ? Decimal(subtotals[$0]!) : 0 }
            let effectiveWeights = weights.allSatisfy { $0 == 0 } ? people.map { _ in Decimal(1) } : weights
            let extra = SplitCalculator.allocate(totalMinorUnits: remainder, weights: effectiveWeights)
            for (person, amount) in zip(people, extra) {
                subtotals[person, default: 0] += amount
            }
        }
        return subtotals
    }

    // MARK: - Populate & save

    private func populate() {
        currencyCode = group.currencyCode
        participantIDs = Set(members.map(\.id))
        payerID = members.first(where: { $0.isCurrentUser })?.id ?? members.first?.id

        guard let existing else { return }
        title = existing.title
        amount = existing.money.decimalValue
        currencyCode = existing.currencyCode
        date = existing.date
        category = existing.category
        notes = existing.notes
        payerID = existing.payer?.id
        splitMode = existing.splitMode
        recurrence = existing.recurrence
        isItemized = existing.isItemized
        participantIDs = Set((existing.shares ?? []).compactMap { $0.member?.id })
        for share in existing.shares ?? [] {
            guard let memberID = share.member?.id else { continue }
            inputs[memberID] = splitMode == .exactAmounts
                ? Money(minorUnits: share.amountMinorUnits, currencyCode: currencyCode).decimalValue
                : share.inputValue
        }
        itemDrafts = (existing.lineItems ?? []).map { item in
            LineItemDraft(name: item.name,
                          amount: Money(minorUnits: item.amountMinorUnits, currencyCode: currencyCode).decimalValue,
                          participantIDs: Set((item.participants ?? []).map(\.id)))
        }
    }

    private func save() {
        do {
            let shares = try isItemized ? itemizedShares() : currentShares()
            guard let payerID, let payer = group.member(id: payerID) else {
                validationMessage = "Pick who paid."
                return
            }

            let expense = existing ?? Expense(title: "", amountMinorUnits: 0, currencyCode: currencyCode)
            if existing == nil { context.insert(expense) }
            for share in expense.shares ?? [] { context.delete(share) }
            for item in expense.lineItems ?? [] { context.delete(item) }

            expense.title = title.trimmingCharacters(in: .whitespaces)
            expense.amountMinorUnits = totalMinorUnits
            expense.currencyCode = currencyCode
            expense.date = date
            expense.category = category
            expense.notes = notes
            expense.splitMode = splitMode
            expense.isItemized = isItemized
            expense.recurrence = recurrence
            expense.recurrenceNextDate = recurrence.next(after: date)
            expense.payer = payer
            expense.group = group
            expense.shares = shares.map { memberID, amount in
                ExpenseShare(member: group.member(id: memberID),
                             amountMinorUnits: amount,
                             inputValue: inputs[memberID] ?? 0)
            }
            expense.lineItems = isItemized ? itemDrafts.map { draft in
                LineItem(name: draft.name,
                         amountMinorUnits: Money(draft.amount, currencyCode: currencyCode).minorUnits,
                         participants: members.filter { draft.participantIDs.contains($0.id) })
            } : []
            try? context.save()
            dismiss()
        } catch let error as SplitError {
            validationMessage = error.errorDescription
        } catch {
            validationMessage = error.localizedDescription
        }
    }
}

struct LineItemDraft: Identifiable {
    let id = UUID()
    var name: String = ""
    var amount: Decimal = 0
    var participantIDs: Set<UUID> = []
}

private struct SplitMemberRow: View {
    let member: Member
    let isIncluded: Bool
    let mode: SplitMode
    @Binding var input: Decimal
    let computedText: String?
    let onToggle: () -> Void

    var body: some View {
        HStack {
            Button(action: onToggle) {
                Image(systemName: isIncluded ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isIncluded ? Color.accentColor : Color.secondary)
                    .font(.title3)
            }
            .buttonStyle(.plain)
            MemberAvatar(member: member, size: 28)
            Text(member.displayName)
            Spacer()
            if isIncluded {
                switch mode {
                case .equal:
                    Text(computedText ?? "").foregroundStyle(.secondary).font(.subheadline)
                case .exactAmounts:
                    AmountField(title: "0.00", value: $input).frame(width: 80)
                case .percentages:
                    HStack(spacing: 2) {
                        AmountField(title: "0", value: $input).frame(width: 60)
                        Text("%").foregroundStyle(.secondary)
                    }
                case .shares:
                    Stepper(value: Binding(
                        get: { NSDecimalNumber(decimal: input).intValue },
                        set: { input = Decimal($0) }
                    ), in: 0...20) {
                        Text("\(NSDecimalNumber(decimal: input).intValue)×")
                            .frame(width: 40, alignment: .trailing)
                    }
                    .fixedSize()
                }
            }
        }
    }
}

struct MemberChips: View {
    let members: [Member]
    @Binding var selected: Set<UUID>

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(members) { member in
                    let isOn = selected.contains(member.id)
                    Button {
                        if isOn { selected.remove(member.id) } else { selected.insert(member.id) }
                    } label: {
                        Text(member.displayName)
                            .font(.caption.weight(.medium))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(isOn ? Color.accentColor : Color(.systemGray5),
                                        in: Capsule())
                            .foregroundStyle(isOn ? .white : .primary)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}
