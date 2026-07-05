import SwiftUI
import CoreData
import SplitCore

/// Re-renders ledger-derived UI (balances, suggested transfers, totals) when
/// anything in the view context changes. Group balances are computed from
/// Expense/ExpenseShare/Settlement objects, so edits to those — or remote
/// CloudKit merges — never touch the SpendingGroup row itself and would
/// otherwise leave @ObservedObject group views stale.
///
/// It also republishes on CurrentUser.didChange: per-device "who am I" claims
/// live in UserDefaults, not Core Data, so they emit no context change and
/// need their own signal to refresh the "You owe/are owed" perspective.
final class LedgerRefresher: ObservableObject {
    private var observers: [NSObjectProtocol] = []

    init() {
        let center = NotificationCenter.default
        let refresh: (Notification) -> Void = { [weak self] _ in self?.objectWillChange.send() }
        observers.append(center.addObserver(
            forName: .NSManagedObjectContextObjectsDidChange,
            object: PersistenceController.shared.container.viewContext,
            queue: .main, using: refresh))
        observers.append(center.addObserver(
            forName: CurrentUser.didChange, object: nil, queue: .main, using: refresh))
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }
}

extension Int {
    func asMoney(_ currencyCode: String) -> String {
        Money(minorUnits: self, currencyCode: currencyCode).formatted()
    }
}

struct MemberAvatar: View {
    let member: Member
    var size: CGFloat = 36

    var body: some View {
        ZStack {
            Circle()
                .fill(Color(hue: member.colorHue, saturation: 0.55, brightness: 0.85).gradient)
            Text(member.initials.isEmpty ? "?" : member.initials)
                .font(.system(size: size * 0.4, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
        }
        .frame(width: size, height: size)
    }
}

/// Text field bound to a Decimal amount, tolerant of partial input.
struct AmountField: View {
    let title: String
    @Binding var value: Decimal
    @State private var text: String = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField(title, text: $text)
            .keyboardType(.decimalPad)
            .multilineTextAlignment(.trailing)
            .focused($focused)
            .onAppear { text = value == 0 ? "" : "\(value)" }
            .onChange(of: text) {
                let normalized = text.replacingOccurrences(of: ",", with: ".")
                value = Decimal(string: normalized) ?? 0
            }
            .onChange(of: value) {
                // Keep external resets (e.g. receipt scan) in sync without
                // fighting the user's keystrokes.
                if !focused {
                    let normalized = text.replacingOccurrences(of: ",", with: ".")
                    if Decimal(string: normalized) ?? 0 != value {
                        text = value == 0 ? "" : "\(value)"
                    }
                }
            }
    }
}

struct BalancePill: View {
    let minorUnits: Int
    let currencyCode: String

    var body: some View {
        Text(abs(minorUnits).asMoney(currencyCode))
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(minorUnits >= 0 ? Color.green : Color.orange)
    }
}
