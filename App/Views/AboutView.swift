import SwiftUI

struct AboutView: View {
    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("SplitFree").font(.title.bold())
                        Text("Split group expenses with every feature free — no subscription, no ads, no accounts, no servers.")
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }

                Section("Everything Splitwise charges for, free") {
                    FeatureRow(symbol: "doc.text.viewfinder", title: "Receipt scanning",
                               detail: "On-device OCR reads the line items so each dish goes to whoever ordered it. Photos never leave your phone.")
                    FeatureRow(symbol: "dollarsign.arrow.circlepath", title: "Currency conversion",
                               detail: "Built-in rates across 30 currencies, applied automatically in balances.")
                    FeatureRow(symbol: "list.bullet.indent", title: "Itemization",
                               detail: "Split by line item; tax and tip spread proportionally.")
                    FeatureRow(symbol: "magnifyingglass", title: "Search",
                               detail: "Full search across every group in the Activity tab.")
                    FeatureRow(symbol: "chart.bar", title: "Charts & totals",
                               detail: "Monthly and category breakdowns in Insights.")
                    FeatureRow(symbol: "repeat", title: "Recurring expenses",
                               detail: "Rent and subscriptions add themselves.")
                }

                Section("How payments work") {
                    Text("SplitFree never moves money. Apple doesn't offer an API for apps to send or confirm person-to-person payments, so settle up with whatever you already use — Apple Cash, Venmo, cash — and mark the payment as paid here once it has actually gone through. Nothing is recorded until you say so.")
                        .font(.callout)
                }

                Section("Your data") {
                    Text("Your data syncs through your private iCloud database when you're signed into iCloud — Apple's free infrastructure, invisible to us and to third parties. Without iCloud it simply stays on-device. Shared groups that sync between friends are the next step on the roadmap.")
                        .font(.callout)
                }
            }
            .navigationTitle("About")
        }
    }
}

private struct FeatureRow: View {
    let symbol: String
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .foregroundStyle(Color.accentColor)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body.weight(.medium))
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}
