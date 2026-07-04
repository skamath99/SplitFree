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
                               detail: "On-device Vision OCR finds the total. Photos never leave your phone.")
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
                    Text("Apple doesn't offer an API for apps to send person-to-person Apple Cash payments, so no app can move money for free without a payment processor. SplitFree does the next best thing: \"Pay in Messages\" opens iMessage with the amount pre-filled, where Apple Cash is built in — then you record the payment here.")
                        .font(.callout)
                }

                Section("Your data") {
                    Text("Everything lives on this device in a local database. The data model is CloudKit-ready: iCloud sync and shared groups (via CKShare, Apple's free infrastructure — the same family as Game Center) are the planned next step, still with no third-party servers.")
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
