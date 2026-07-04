import SwiftUI
import CoreData
import Charts
import SplitCore

/// Charts & totals — a Splitwise Pro feature, free here.
/// Chart design: magnitude data with identity on the axis, so a single hue
/// carries the marks; the headline total is a stat tile, not a chart.
struct InsightsView: View {
    @FetchRequest(fetchRequest: Expense.fetchAll(), animation: .default)
    private var expenses: FetchedResults<Expense>
    @FetchRequest(fetchRequest: SpendingGroup.fetchAll(), animation: .default)
    private var groups: FetchedResults<SpendingGroup>
    @State private var selectedGroupID: UUID?

    private let displayCurrency = "USD"

    private var scopedExpenses: [Expense] {
        guard let selectedGroupID else { return Array(expenses) }
        return expenses.filter { $0.group?.id == selectedGroupID }
    }

    private var currencyCode: String {
        guard let selectedGroupID else { return displayCurrency }
        return groups.first { $0.id == selectedGroupID }?.currencyCode ?? displayCurrency
    }

    /// Expense amount converted into the display currency's minor units.
    private func converted(_ expense: Expense) -> Int {
        let converter = CurrencyConverter.bundledSnapshot
        return converter.convert(expense.money, to: currencyCode)?.minorUnits ?? expense.amountMinorUnits
    }

    var body: some View {
        NavigationStack {
            Group {
                if expenses.isEmpty {
                    ContentUnavailableView("Nothing to chart yet", systemImage: "chart.pie",
                                           description: Text("Add a few expenses and spending breakdowns appear here."))
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 24) {
                            statTiles
                            monthlyChart
                            categoryChart
                        }
                        .padding()
                    }
                }
            }
            .navigationTitle("Insights")
            .toolbar {
                Picker("Group", selection: $selectedGroupID) {
                    Text("All groups").tag(UUID?.none)
                    ForEach(groups) { group in
                        Text("\(group.emoji) \(group.name)").tag(Optional(group.id))
                    }
                }
            }
        }
    }

    // MARK: - Stat tiles

    private var thisMonthTotal: Int {
        let start = Calendar.current.dateInterval(of: .month, for: .now)?.start ?? .now
        return scopedExpenses.filter { $0.date >= start }.map(converted).reduce(0, +)
    }

    private var allTimeTotal: Int {
        scopedExpenses.map(converted).reduce(0, +)
    }

    private var statTiles: some View {
        HStack(spacing: 12) {
            StatTile(title: "This month", value: thisMonthTotal.asMoney(currencyCode))
            StatTile(title: "All time", value: allTimeTotal.asMoney(currencyCode))
        }
    }

    // MARK: - Monthly bars (last 6 months)

    private struct MonthTotal: Identifiable {
        let month: Date
        let totalMinorUnits: Int
        var id: Date { month }
    }

    private var monthTotals: [MonthTotal] {
        let calendar = Calendar.current
        let thisMonth = calendar.dateInterval(of: .month, for: .now)?.start ?? .now
        let months = (0..<6).compactMap { calendar.date(byAdding: .month, value: -$0, to: thisMonth) }.reversed()
        let byMonth = Dictionary(grouping: scopedExpenses) {
            calendar.dateInterval(of: .month, for: $0.date)?.start ?? $0.date
        }
        return months.map { month in
            MonthTotal(month: month,
                       totalMinorUnits: (byMonth[month] ?? []).map(converted).reduce(0, +))
        }
    }

    private var monthlyChart: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Spending by month").font(.headline)
            Chart(monthTotals) { item in
                BarMark(
                    x: .value("Month", item.month, unit: .month),
                    y: .value("Total", Double(item.totalMinorUnits) / 100.0),
                    width: .ratio(0.55)
                )
                .cornerRadius(4)
                .foregroundStyle(Color.accentColor)
            }
            .chartXAxis {
                AxisMarks(values: .stride(by: .month)) {
                    AxisValueLabel(format: .dateTime.month(.narrow))
                }
            }
            .chartYAxis {
                AxisMarks { value in
                    AxisGridLine().foregroundStyle(.quaternary)
                    AxisValueLabel {
                        if let doubleValue = value.as(Double.self) {
                            Text(Int(doubleValue * 100).asMoney(currencyCode))
                        }
                    }
                }
            }
            .frame(height: 200)
        }
        .padding()
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Category bars

    private struct CategoryTotal: Identifiable {
        let category: ExpenseCategory
        let totalMinorUnits: Int
        var id: String { category.rawValue }
    }

    private var categoryTotals: [CategoryTotal] {
        Dictionary(grouping: scopedExpenses, by: \.category)
            .map { CategoryTotal(category: $0.key, totalMinorUnits: $0.value.map(converted).reduce(0, +)) }
            .filter { $0.totalMinorUnits > 0 }
            .sorted { $0.totalMinorUnits > $1.totalMinorUnits }
    }

    private var categoryChart: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Spending by category").font(.headline)
            Chart(categoryTotals) { item in
                BarMark(
                    x: .value("Total", Double(item.totalMinorUnits) / 100.0),
                    y: .value("Category", item.category.displayName),
                    width: .ratio(0.55)
                )
                .cornerRadius(4)
                .foregroundStyle(Color.accentColor)
                .annotation(position: .trailing, alignment: .leading) {
                    Text(item.totalMinorUnits.asMoney(currencyCode))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .chartXAxis(.hidden)
            .chartYAxis {
                AxisMarks { _ in AxisValueLabel() }
            }
            .frame(height: CGFloat(max(1, categoryTotals.count)) * 36 + 20)
        }
        .padding()
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
    }
}

private struct StatTile: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value)
                .font(.title2.weight(.semibold))
                .monospacedDigit()
                .minimumScaleFactor(0.6)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
    }
}
