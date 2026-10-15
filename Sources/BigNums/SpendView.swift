import SwiftUI

/// "How am I spending?": the period's total, then the same spending through one lens at a time.
struct SpendView: View {
    let store: Store
    @Binding var offset: Int  // 0 = current period, -1 = previous, ...; owned by the menu so it survives relayout
    @AppStorage("period") private var period: Period = .month
    @AppStorage("lens") private var lens: Lens = .merchants

    /// Same row cap on every period, so the menu keeps a steady height when switching.
    private static let maxRows = 5

    var body: some View {
        let interval = period.interval(offset: offset, from: store.referenceDate)
        let breakdown = store.breakdown(interval)
        VStack(alignment: .leading, spacing: 0) {
            toolbar(interval)
            Hero(label: title(interval), value: breakdown.total, context: comparison(interval, spent: breakdown.total))
                .padding(.top, 18)
            LensStrip(period: period, selection: $lens)
                .padding(.top, 18)
            lensContent(interval, breakdown)
                .padding(.top, 8)
            uncountedNote(breakdown.uncounted)
        }
        .onChange(of: period) { offset = 0 }
    }

    @ViewBuilder
    private func lensContent(_ interval: DateInterval, _ breakdown: Breakdown) -> some View {
        switch lens {
        case .merchants: merchants(breakdown)
        case .categories: categories(breakdown)
        case .cards: cards(breakdown)
        case .trend: trend(interval)
        }
    }

    private var emptyText: String {
        offset == 0 ? "No purchases yet \(period == .day ? "today" : "this \(period.unit)")" : "No purchases"
    }

    // MARK: Header

    private func toolbar(_ interval: DateInterval) -> some View {
        HStack(spacing: 0) {
            Picker("Period", selection: $period) {
                ForEach(Period.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            Spacer()
            stepButton("chevron.left", help: "Previous \(period.unit)") { offset -= 1 }
                .disabled(!(store.historyStart.map { interval.start > $0 } ?? false))
            stepButton("chevron.right", help: "Next \(period.unit)") { offset += 1 }
                .disabled(offset >= 0)
        }
    }

    private func stepButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 26, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(help)
    }

    // MARK: Merchants

    @ViewBuilder
    private func merchants(_ breakdown: Breakdown) -> some View {
        if breakdown.purchases.isEmpty {
            Note(emptyText)
        } else if period == .day {
            let accounts = store.accountsByID
            ForEach(breakdown.purchases.prefix(Self.maxRows), id: \.transactionId) { txn in
                purchaseRow(txn, account: txn.accountId.flatMap { accounts[$0] })
            }
            let more = breakdown.purchases.count - Self.maxRows
            if more > 0 {
                Note(more == 1 ? "1 more purchase" : "\(more) more purchases")
            }
        } else {
            ForEach(MerchantTotal.top(breakdown.purchases, limit: Self.maxRows)) { merchant in
                merchantRow(merchant, share: breakdown.total > 0 ? merchant.total / breakdown.total : 0)
            }
        }
    }

    private func countMenu(_ merchant: String) {
        ActionMenu.show([.action("Don't count \(merchant)") { store.hide(merchant) }])
    }

    private func purchaseRow(_ txn: Transaction, account: Account?) -> some View {
        let card = account?.shortName
        let detail = txn.pending == true ? card.map { "Pending on \($0)" } ?? "Pending" : card
        return Button { countMenu(txn.merchant) } label: {
            ItemRow(title: txn.merchant, amount: txn.amount) {
                MerchantIcon(logo: txn.logoUrl.flatMap(URL.init(string:)), symbol: txn.symbol)
            } detail: {
                if let detail { Text(detail) }
            }
        }
        .buttonStyle(RowButtonStyle())
    }

    private func merchantRow(_ merchant: MerchantTotal, share: Double) -> some View {
        Button { countMenu(merchant.name) } label: {
            ItemRow(title: merchant.name, amount: merchant.total) {
                MerchantIcon(logo: merchant.sample.logoUrl.flatMap(URL.init(string:)), symbol: merchant.sample.symbol)
            } detail: {
                HStack(spacing: 8) {
                    Text(merchant.count == 1 ? "1 purchase" : "\(merchant.count) purchases")
                        .fixedSize()
                    ShareBar(share: share)
                }
            }
        }
        .buttonStyle(RowButtonStyle())
    }

    /// "Ysi Inc. isn't counted  $2,095.03": what's missing from this period's total, and the way to count it again.
    /// Only shown when a merchant that isn't counted actually charged you in the selected period.
    @ViewBuilder
    private func uncountedNote(_ uncounted: [String: Double]) -> some View {
        let names = uncounted.keys.sorted { uncounted[$0]! > uncounted[$1]! }
        if !names.isEmpty {
            RestoreNote(text: names.count == 1 ? "\(names[0]) isn't counted" : "\(names.count) merchants aren't counted",
                        amount: uncounted.values.reduce(0, +),
                        help: "Left out of this total. Click to count it again.",
                        names: names, itemTitle: { "Count \($0) again" }, allTitle: "Count all again",
                        restore: store.unhide, restoreAll: { names.forEach(store.unhide) })
                .padding(.top, 8)
        }
    }

    // MARK: Categories

    @ViewBuilder
    private func categories(_ breakdown: Breakdown) -> some View {
        let all = CategoryTotal.all(breakdown.purchases)
        if all.isEmpty {
            Note(emptyText)
        } else {
            ForEach(all.prefix(Self.maxRows)) { category in
                ItemRow(title: category.name, amount: category.total) {
                    MerchantIcon(logo: nil, symbol: Transaction.symbol(forCategory: category.key))
                } detail: {
                    HStack(spacing: 8) {
                        Text(category.count == 1 ? "1 purchase" : "\(category.count) purchases")
                            .fixedSize()
                        ShareBar(share: breakdown.total > 0 ? category.total / breakdown.total : 0)
                    }
                }
                .padding(.horizontal, MenuView.inset)
            }
            if all.count > Self.maxRows {
                Note("\(all.count - Self.maxRows) more categories")
            }
        }
    }

    // MARK: Cards

    @ViewBuilder
    private func cards(_ breakdown: Breakdown) -> some View {
        let rows = store.connections
            .flatMap { connection in (connection.accounts ?? []).map { (connection: connection, account: $0) } }
            .sorted { (breakdown.byAccount[$0.account.id] ?? 0) > (breakdown.byAccount[$1.account.id] ?? 0) }
        if rows.isEmpty {
            Note("No accounts yet")
        } else {
            ForEach(rows, id: \.account.id) { row in
                let counted = !store.excludedAccounts.contains(row.account.id)
                Button {
                    ActionMenu.show([.action("Count in totals", checked: counted) { store.toggleExcluded(row.account.id) }])
                } label: {
                    ItemRow(title: row.account.displayName, amount: breakdown.byAccount[row.account.id] ?? 0) {
                        BankLogo(connection: row.connection)
                    } detail: {
                        Text(counted ? row.account.kind : "Not counted in totals")
                    }
                    .opacity(counted ? 1 : 0.5)
                }
                .buttonStyle(RowButtonStyle())
            }
        }
    }

    // MARK: Trend

    private var trendCount: Int {
        switch period {
        case .day: 14
        case .week: 8
        case .month: 6
        }
    }

    /// Spending in each of the last few days/weeks/months, ending at the one being viewed. The current one is partial.
    private func trendPoints() -> [(start: Date, total: Double)] {
        guard let historyStart = store.historyStart else { return [] }
        return (-(trendCount - 1)...0).compactMap { step in
            let slot = period.interval(offset: offset + step, from: store.referenceDate)
            guard slot.end > historyStart else { return nil }
            return (slot.start, store.breakdown(slot).total)
        }
    }

    @ViewBuilder
    private func trend(_ interval: DateInterval) -> some View {
        let points = trendPoints()
        if points.count < 2 {
            Note("Not enough history yet")
        } else {
            let average = points.reduce(0) { $0 + $1.total } / Double(points.count)
            let unit = period == .month ? "mo" : period == .week ? "wk" : "day"
            TrendChart(points: points, average: average, selected: interval.start, period: period)
            Note("Dashed line is your average: \(Store.money(average))/\(unit)")
        }
    }

    // MARK: Period title & comparison

    private func title(_ interval: DateInterval) -> String {
        let start = interval.start
        let last = interval.end.addingTimeInterval(-1)
        switch (period, offset) {
        case (.day, 0): return "Today"
        case (.day, -1): return "Yesterday"
        case (.day, _): return start.formatted(.dateTime.weekday(.wide).month(.wide).day())
        case (.week, 0): return "This week"
        case (.week, -1): return "Last week"
        case (.week, _): return "\(start.formatted(.dateTime.month(.abbreviated).day())) – \(last.formatted(.dateTime.month(.abbreviated).day()))"
        case (.month, 0): return "This month"
        case (.month, _):
            let sameYear = Calendar.current.isDate(start, equalTo: store.referenceDate, toGranularity: .year)
            return sameYear ? start.formatted(.dateTime.month(.wide)) : start.formatted(.dateTime.month(.wide).year())
        }
    }

    /// One line of context: what you usually spend over the same stretch, and how this compares. Over is orange;
    /// under stays quiet, so spending less never reads as a warning.
    private func comparison(_ interval: DateInterval, spent: Double) -> Text? {
        let isCurrent = offset == 0
        guard let usual = store.usualSpending(period, interval: interval, isCurrent: isCurrent) else { return nil }
        let when: String = switch period {
        case .day: "on \(interval.start.formatted(.dateTime.weekday(.wide)))s"
        case .week: isCurrent ? "by now" : "a week"
        case .month: isCurrent ? "by now" : "a month"
        }
        let difference = spent - usual
        let head = Text("Usually \(Store.money(usual)) \(when)")
        if abs(difference) < 1 { return head + Text(" · about the same") }
        let tail = Text(" · \(Store.money(abs(difference))) \(difference > 0 ? "over" : "under")")
        return head + (difference > 0 ? tail.foregroundStyle(.orange) : tail)
    }
}
