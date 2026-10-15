import Charts
import SwiftUI

@main
struct BigNumsApp: App {
    @State private var store: Store

    init() {
        #if DEBUG
        Snapshot.renderIfRequested()
        #endif
        let store = Store()
        _store = State(initialValue: store)
        StatusItemMenu.install(store)
    }

    var body: some Scene {
        MenuBarExtra {
            MenuView(store: store)
        } label: {
            if store.isConfigured {
                Text(store.label).monospacedDigit()
            } else {
                Image(systemName: "exclamationmark.triangle")
            }
        }
        .menuBarExtraStyle(.window)
    }
}

struct MenuView: View {
    let store: Store
    @AppStorage("period") private var period: Period = .month
    @AppStorage("accountsExpanded") private var accountsExpanded = false
    @AppStorage("recurringExpanded") private var recurringExpanded = false
    @AppStorage("trendExpanded") private var trendExpanded = false
    @State private var trendSelection: Date?
    @State private var offset = 0  // 0 = current period, -1 = previous, ...
    @State private var removing: String?  // connection awaiting remove confirmation
    @State private var window: NSWindow?
    @State private var contentHeight: CGFloat = 0

    /// Same row cap on every tab, so the menu keeps a steady height when switching periods.
    private static let maxRows = 5

    var body: some View {
        let interval = period.interval(offset: offset, from: store.referenceDate)
        let breakdown = store.breakdown(interval)
        VStack(alignment: .leading, spacing: 0) {
            if store.connections.isEmpty {
                emptyState
            } else {
                toolbar(interval)
                summary(interval, breakdown)
                    .padding(.top, 18)
                spending(breakdown)
                    .padding(.top, 22)
                trendSection(interval, breakdown)
                    .padding(.top, 18)
                recurringSection
                    .padding(.top, 18)
                accounts(breakdown)
                    .padding(.top, 4)
            }

            if let message = store.message {
                Text(message)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, Self.inset)
                    .padding(.top, 12)
            }

            Divider()
                .padding(.top, 14)
                .padding(.bottom, 8)
            footer
        }
        .padding(14)
        .frame(width: 320)
        .fixedSize(horizontal: false, vertical: true)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
            contentHeight = height
            fitWindow(window, to: height)
        }
        .background(WindowReader { found in
            window = found
            fitWindow(found, to: contentHeight)
        })
        .task { await store.refreshIfStale() }
        .onChange(of: period) { offset = 0 }
        // Closing the menu returns it to the current period, so it never reopens on old numbers.
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { note in
            if note.object as? NSWindow === window {
                offset = 0
                removing = nil
            }
        }
    }

    /// Everything shares one left edge: the outer padding plus this inset, which leaves room for row hover highlights.
    fileprivate static let inset: CGFloat = 6

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

    private func summary(_ interval: DateInterval, _ breakdown: Breakdown) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title(interval))
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
            HeroAmount(value: breakdown.total)
            // Always reserve the line so the menu doesn't change height when there's nothing to compare.
            Text(comparison(interval, spent: breakdown.total) ?? " ")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, Self.inset)
    }

    // MARK: Spending

    @ViewBuilder
    private func spending(_ breakdown: Breakdown) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionTitle(period == .day ? "Top purchases" : "Top merchants")
            if breakdown.purchases.isEmpty {
                Note(offset == 0 ? "No purchases yet \(period == .day ? "today" : "this \(period.unit)")" : "No purchases")
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
            uncountedNote(breakdown.uncounted)
        }
    }

    /// "Ysi Inc. isn't counted  $2,095.03": what's missing from this period's total, and the way to count it again.
    /// Only shown when a merchant that isn't counted actually charged you in the selected period.
    @ViewBuilder
    private func uncountedNote(_ uncounted: [String: Double]) -> some View {
        let names = uncounted.keys.sorted { uncounted[$0]! > uncounted[$1]! }
        if !names.isEmpty {
            restoreNote(names.count == 1 ? "\(names[0]) isn't counted" : "\(names.count) merchants aren't counted",
                        amount: uncounted.values.reduce(0, +),
                        help: "Left out of this total. Click to count it again.",
                        names: names, itemTitle: { "Count \($0) again" }, allTitle: "Count all again",
                        restore: store.unhide, restoreAll: { names.forEach(store.unhide) })
        }
    }

    /// Quiet clickable line that lists what was set aside, each with a way to bring it back.
    private func restoreNote(_ text: String, amount: Double? = nil, help: String, names: [String], itemTitle: @escaping (String) -> String,
                             allTitle: String, restore: @escaping (String) -> Void, restoreAll: @escaping () -> Void) -> some View {
        Button {
            var items = names.map { name in ActionMenu.Item.action(itemTitle(name)) { restore(name) } }
            if names.count > 1 { items += [.divider, .action(allTitle) { restoreAll() }] }
            ActionMenu.show(items)
        } label: {
            HStack {
                Text(text)
                    .font(.system(size: 12))
                Spacer()
                if let amount {
                    Text(amount.formatted(.currency(code: "USD")))
                        .font(.system(size: 13))
                        .monospacedDigit()
                }
            }
            .foregroundStyle(.secondary)
            .padding(.vertical, 4)
        }
        .buttonStyle(RowButtonStyle())
        .help(help)
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
        Button { countMenu(merchant.name) } label: { merchantRowContent(merchant, share: share) }
            .buttonStyle(RowButtonStyle())
    }

    private func merchantRowContent(_ merchant: MerchantTotal, share: Double) -> some View {
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

    // MARK: Trend

    private var trendCount: Int {
        switch period {
        case .day: 14
        case .week: 8
        case .month: 6
        }
    }

    /// Spending in each of the last few days/weeks/months, ending at the one being viewed. The current one is partial.
    private func trendPoints(_ interval: DateInterval) -> [(start: Date, total: Double)] {
        guard let historyStart = store.historyStart else { return [] }
        return (-(trendCount - 1)...0).compactMap { step in
            let slot = period.interval(offset: offset + step, from: store.referenceDate)
            guard slot.end > historyStart else { return nil }
            return (slot.start, store.breakdown(slot).total)
        }
    }

    private func trendSection(_ interval: DateInterval, _ breakdown: Breakdown) -> some View {
        let points = trendPoints(interval)
        let average = points.isEmpty ? 0 : points.reduce(0) { $0 + $1.total } / Double(points.count)
        let unit = period == .month ? "mo" : period == .week ? "wk" : "day"
        return VStack(alignment: .leading, spacing: 0) {
            CollapsibleHeader(
                title: "Trend",
                value: points.count > 1 ? "avg \(Store.money(average))/\(unit)" : "",
                alert: nil,
                alertColor: .secondary,
                expanded: $trendExpanded
            )
            if trendExpanded {
                if points.count < 2 {
                    Note("Not enough history yet")
                } else {
                    trendChart(points, average: average, selected: interval.start)
                }
            }
        }
    }

    private func trendChart(_ points: [(start: Date, total: Double)], average: Double, selected: Date) -> some View {
        let hovered = trendSelection.flatMap { date in points.min { abs($0.start.timeIntervalSince(date)) < abs($1.start.timeIntervalSince(date)) } }
        let shown = hovered ?? points.first { $0.start == selected }
        let format: Date.FormatStyle = switch period {
        case .day: .dateTime.month(.abbreviated).day()
        case .week: .dateTime.month(.abbreviated).day()
        case .month: .dateTime.month(.abbreviated)
        }
        return VStack(alignment: .leading, spacing: 12) {
            Text(shown.map { "\(period == .week ? "Week of " : "")\($0.start.formatted(format)): \(Store.money($0.total))" } ?? " ")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .monospacedDigit()
            Chart {
                ForEach(points, id: \.start) { point in
                    LineMark(x: .value("Date", point.start), y: .value("Spent", point.total))
                        .foregroundStyle(Color.accentColor)
                    AreaMark(x: .value("Date", point.start), y: .value("Spent", point.total))
                        .foregroundStyle(Color.accentColor.opacity(0.12))
                }
                RuleMark(y: .value("Average", average))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    .foregroundStyle(.secondary.opacity(0.6))
                if let shown {
                    PointMark(x: .value("Date", shown.start), y: .value("Spent", shown.total))
                        .foregroundStyle(Color.accentColor)
                }
            }
            .chartXSelection(value: $trendSelection)
            .chartXScale(range: .plotDimension(startPadding: 12, endPadding: 32))
            .chartXAxis {
                if period == .month {
                    AxisMarks(values: points.map(\.start)) { _ in AxisTick(); AxisValueLabel(format: format, anchor: .top).font(.system(size: 10)) }
                } else {
                    AxisMarks(values: .automatic(desiredCount: 4)) { _ in AxisValueLabel(format: format).font(.system(size: 10)) }
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { value in
                    AxisGridLine()
                    AxisValueLabel { if let v = value.as(Double.self) { Text(Store.compactMoney(v)).font(.system(size: 10)) } }
                }
            }
            .frame(height: 110)
        }
        .padding(.horizontal, Self.inset)
        .padding(.top, 8)
    }

    // MARK: Recurring

    @ViewBuilder
    private var recurringSection: some View {
        let items = store.recurring
        let dismissed = store.dismissedRecurring.sorted()
        if !items.isEmpty || !dismissed.isEmpty {
            let increase = items.first { ($0.change ?? 0) > 0 }
            VStack(alignment: .leading, spacing: 0) {
                CollapsibleHeader(
                    title: "Recurring",
                    value: "\(Store.money(items.reduce(0) { $0 + $1.monthlyCost }))/mo",
                    alert: increase.map { "\($0.name) went up \(($0.change ?? 0).formatted(.currency(code: "USD")))" },
                    alertColor: .orange,
                    expanded: $recurringExpanded
                )
                if recurringExpanded {
                    ForEach(items) { recurringRow($0) }
                    if !dismissed.isEmpty {
                        restoreNote("\(dismissed.count) dismissed", help: "Marked as not recurring. Click to restore.",
                                    names: dismissed, itemTitle: { "Restore \($0)" }, allTitle: "Restore all",
                                    restore: store.restoreRecurring, restoreAll: store.restoreAllRecurring)
                    }
                }
            }
        }
    }

    private func recurringRow(_ item: Recurring) -> some View {
        let next = item.next.formatted(.dateTime.month(.abbreviated).day())
        let counted = store.isCounted(item.name)
        let via = item.account.map { " · \($0)" } ?? ""
        return Button {
            ActionMenu.show([.action("Not a recurring charge") { store.dismissRecurring(item.name) }])
        } label: {
            ItemRow(title: item.name, amount: item.amount) {
                MerchantIcon(logo: item.sample.logoUrl.flatMap(URL.init(string:)), symbol: item.sample.symbol)
            } detail: {
                if let change = item.change, change > 0 {
                    Text("Went up \(change.formatted(.currency(code: "USD"))), next \(next)\(via)").foregroundStyle(.orange)
                } else if let change = item.change {
                    Text("Went down \((-change).formatted(.currency(code: "USD"))), next \(next)\(via)")
                } else if !counted {
                    Text("\(item.cadence.label), not counted in totals\(via)")
                } else {
                    Text("\(item.cadence.label), next \(next)\(via)")
                }
            }
            .opacity(counted ? 1 : 0.5)
        }
        .buttonStyle(RowButtonStyle())
    }

    // MARK: Accounts

    private func accounts(_ breakdown: Breakdown) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            accountsHeader
            if accountsExpanded {
                accountList(breakdown)
            }
        }
    }

    /// While collapsed it still surfaces problems, so a broken bank can't go unnoticed.
    private var accountsHeader: some View {
        let count = store.connections.reduce(0) { $0 + max($1.accounts?.count ?? 0, 1) }
        let problem: String? = store.connections.lazy.compactMap { connection -> String? in
            if connection.needsReconnect { return "\(connection.institution) needs you to sign in again" }
            if connection.error != nil { return "\(connection.institution) can't update" }
            return nil
        }.first
        return CollapsibleHeader(title: "Accounts", value: "\(count)", alert: problem, alertColor: .red, expanded: $accountsExpanded)
    }

    private func accountList(_ breakdown: Breakdown) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(store.connections) { connection in
                if removing == connection.id {
                    removeConfirmation(connection)
                } else if let accounts = connection.accounts, !accounts.isEmpty {
                    ForEach(accounts) { account in
                        accountRow(account, in: connection, value: breakdown.byAccount[account.id] ?? 0)
                    }
                } else {
                    // Just connected (or never synced): one row for the bank until its accounts arrive.
                    Button { showActions(for: connection, account: nil) } label: {
                        ItemRow(title: connection.institution) {
                            BankLogo(connection: connection)
                        } detail: {
                            Text(connection.error ?? "Getting your accounts…")
                                .foregroundStyle(connection.error == nil ? Color.secondary : Color.red)
                        }
                    }
                    .buttonStyle(RowButtonStyle())
                }
            }
            addAccountRow
        }
    }

    private func accountRow(_ account: Account, in connection: Connection, value: Double) -> some View {
        let counted = !store.excludedAccounts.contains(account.id)
        let detail: Text = if connection.needsReconnect {
            Text("Sign-in expired. Click to reconnect.").foregroundStyle(.red)
        } else if let error = connection.error {
            Text(error).foregroundStyle(.red)
        } else if !counted {
            Text("Not counted in totals")
        } else {
            Text(account.kind)
        }
        return Button { showActions(for: connection, account: account) } label: {
            ItemRow(title: account.displayName, amount: value) {
                BankLogo(connection: connection)
            } detail: {
                detail
            }
            .opacity(counted ? 1 : 0.5)
        }
        .buttonStyle(RowButtonStyle())
        .help("Options for \(account.displayName)")
    }

    /// Native menu with everything you can do to an account and its bank.
    private func showActions(for connection: Connection, account: Account?) {
        var items: [ActionMenu.Item] = []
        if let account {
            let counted = !store.excludedAccounts.contains(account.id)
            items.append(.action("Count in totals", checked: counted) { store.toggleExcluded(account.id) })
            items.append(.divider)
        }
        if let website = connection.websiteURL {
            items.append(.action("Open \(connection.institution) website") { NSWorkspace.shared.open(website) })
        }
        if !store.isLinking {
            items.append(.action("Reconnect \(connection.institution)…") { store.reconnect(connection.id) })
        }
        items.append(.divider)
        items.append(.action("Remove \(connection.institution)…") { removing = connection.id })
        ActionMenu.show(items)
    }

    private func removeConfirmation(_ connection: Connection) -> some View {
        let count = connection.accounts?.count ?? 0
        return VStack(alignment: .leading, spacing: 4) {
            Text("Remove \(connection.institution)?")
                .font(.system(size: 13, weight: .semibold))
            Text(count == 1 ? "Its account will be disconnected from BigNums."
                 : count > 1 ? "Its \(count) accounts will be disconnected from BigNums."
                 : "It will be disconnected from BigNums.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { removing = nil }
                    .keyboardShortcut(.cancelAction)
                Button("Remove", role: .destructive) {
                    removing = nil
                    Task { await store.remove(connection.id) }
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
            }
            .controlSize(.small)
            .padding(.top, 6)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.05)))
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var addAccountRow: some View {
        if store.isLinking {
            ItemRow(title: "Finish connecting in your browser") {
                ProgressView().controlSize(.small)
            } trailing: {
                Button("Cancel") { store.cancelLink() }
                    .buttonStyle(.borderless)
                    .font(.system(size: 12))
            }
            .padding(.horizontal, Self.inset)
        } else {
            Button { store.addConnection() } label: {
                ItemRow(title: "Add account…") {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 24, height: 24)
                        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.primary.opacity(0.07)))
                }
            }
            .buttonStyle(RowButtonStyle())
            .disabled(!store.isConfigured)
        }
    }

    // MARK: Empty state & footer

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("See what you spend")
                .font(.system(size: 15, weight: .semibold))
            Text("Connect a bank or card and your spending for today, this week, and this month will appear in the menu bar.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Group {
                if store.isLinking {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Finish connecting in your browser").font(.system(size: 12))
                        Button("Cancel") { store.cancelLink() }.buttonStyle(.borderless).font(.system(size: 12))
                    }
                } else {
                    Button("Add account…") { store.addConnection() }
                        .buttonStyle(.borderedProminent)
                        .disabled(!store.isConfigured)
                }
            }
            .padding(.top, 8)
        }
        .padding(.horizontal, Self.inset)
        .padding(.vertical, 4)
    }

    private var footer: some View {
        HStack(spacing: 4) {
            Group {
                if store.isRefreshing {
                    Text("Updating…")
                } else if let last = store.lastRefresh {
                    Text("Updated \(last.formatted(.relative(presentation: .named)))")
                }
            }
            Button { Task { await store.refresh() } } label: {
                Image(systemName: "arrow.clockwise").font(.system(size: 10, weight: .semibold))
            }
            .disabled(store.isRefreshing || !store.isConfigured)
            .help("Refresh now")
            Spacer()
            Button("Quit") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q")
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .buttonStyle(.borderless)
        .padding(.horizontal, Self.inset)
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

    /// One line of context: a day vs. the average day before it; a running week/month vs. the previous one up to the
    /// same point (Oct 1–7 vs. Sep 1–7); a finished week/month vs. the whole one before it.
    private func comparison(_ interval: DateInterval, spent: Double) -> String? {
        let cal = Calendar.current
        guard let historyStart = store.historyStart else { return nil }
        let reference: Double
        let phrase: String
        if period == .day {
            // 28 days = 4 full weeks, so weekends and weekdays weigh equally.
            guard let start = cal.date(byAdding: .day, value: -28, to: interval.start), start >= historyStart else { return nil }
            reference = store.breakdown(DateInterval(start: start, end: interval.start)).total / 28
            phrase = "your daily average"
        } else {
            guard let previousStart = cal.date(byAdding: period.component, value: -1, to: interval.start),
                  previousStart >= historyStart else { return nil }
            var end = interval.start
            if offset == 0 {
                let elapsedDays = (cal.dateComponents([.day], from: interval.start, to: cal.startOfDay(for: store.referenceDate)).day ?? 0) + 1
                end = min(cal.date(byAdding: .day, value: elapsedDays, to: previousStart) ?? end, end)
            }
            reference = store.breakdown(DateInterval(start: previousStart, end: end)).total
            phrase = offset == 0 ? "this time last \(period.unit)" : "the \(period.unit) before"
        }
        let difference = spent - reference
        if abs(difference) < 1 { return "About the same as \(phrase)" }
        return "\(Store.money(abs(difference))) \(difference > 0 ? "more" : "less") than \(phrase)"
    }
}

// MARK: - Building blocks

/// The one bold element: a light, large figure with a quieter dollar sign.
private struct HeroAmount: View {
    let value: Double

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 1) {
            Text("$")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(.secondary)
            Text(value.formatted(.number.precision(.fractionLength(0))))
                .font(.system(size: 44, weight: .light))
                .monospacedDigit()
                .contentTransition(.numericText())
                // Animate only the number: animating the layout makes the content resize smoothly while the
                // menu window jumps to its new size, leaving see-through gaps at the top and bottom.
                .animation(.snappy, value: value)
        }
    }
}

/// Section title that opens and closes its section. While closed, an alert (if any) replaces the summary value.
private struct CollapsibleHeader: View {
    let title: String
    let value: String
    let alert: String?
    let alertColor: Color
    @Binding var expanded: Bool

    var body: some View {
        Button { expanded.toggle() } label: {
            HStack(spacing: 6) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if let alert, !expanded {
                    Text(alert)
                        .font(.system(size: 11))
                        .foregroundStyle(alertColor)
                        .lineLimit(1)
                } else {
                    Text(value)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Image(systemName: expanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 12)
            }
            .padding(.vertical, 4)
        }
        .buttonStyle(RowButtonStyle())
        .help(expanded ? "Hide \(title.lowercased())" : "Show \(title.lowercased())")
    }
}

private struct SectionTitle: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, MenuView.inset)
            .padding(.bottom, 4)
    }
}

private struct Note: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .padding(.horizontal, MenuView.inset)
            .padding(.vertical, 4)
    }
}

/// The one row anatomy used everywhere: 24pt icon, name with an optional second line, and a trailing amount or control.
private struct ItemRow<Icon: View, Detail: View, Trailing: View>: View {
    let title: String
    @ViewBuilder let icon: Icon
    @ViewBuilder let detail: Detail
    @ViewBuilder let trailing: Trailing

    var body: some View {
        HStack(spacing: 10) {
            icon.frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 13))
                    .lineLimit(1)
                detail
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            trailing
        }
        .padding(.vertical, 4)
    }
}

extension ItemRow where Trailing == AmountText {
    init(title: String, amount: Double, @ViewBuilder icon: () -> Icon, @ViewBuilder detail: () -> Detail) {
        self.init(title: title, icon: icon, detail: detail, trailing: { AmountText(value: amount) })
    }
}

extension ItemRow where Detail == EmptyView {
    init(title: String, @ViewBuilder icon: () -> Icon, @ViewBuilder trailing: () -> Trailing) {
        self.init(title: title, icon: icon, detail: { EmptyView() }, trailing: trailing)
    }
}

extension ItemRow where Trailing == EmptyView {
    init(title: String, @ViewBuilder icon: () -> Icon, @ViewBuilder detail: () -> Detail) {
        self.init(title: title, icon: icon, detail: detail, trailing: { EmptyView() })
    }
}

extension ItemRow where Detail == EmptyView, Trailing == EmptyView {
    init(title: String, @ViewBuilder icon: () -> Icon) {
        self.init(title: title, icon: icon, detail: { EmptyView() }, trailing: { EmptyView() })
    }
}

struct AmountText: View {
    let value: Double

    var body: some View {
        Text(value > 0 ? value.formatted(.currency(code: "USD")) : "—")
            .font(.system(size: 13))
            .monospacedDigit()
            .foregroundStyle(value > 0 ? .primary : .secondary)
    }
}

/// Merchants are circles…
private struct MerchantIcon: View {
    let logo: URL?
    let symbol: String

    var body: some View {
        AsyncImage(url: logo) { image in
            image.resizable().scaledToFill()
        } placeholder: {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.primary.opacity(0.07))
        }
        .frame(width: 24, height: 24)
        .clipShape(Circle())
    }
}

/// …banks are rounded squares, so the two kinds of row read differently at a glance.
private struct BankLogo: View {
    let connection: Connection

    var body: some View {
        Group {
            if let logo = connection.logo.flatMap({ Data(base64Encoded: $0) }).flatMap(NSImage.init(data:)) {
                Image(nsImage: logo).resizable().scaledToFill()
            } else {
                Image(systemName: "building.columns.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.primary.opacity(0.07))
            }
        }
        .frame(width: 24, height: 24)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

/// A merchant's share of the period's spending. Neutral, so the total stays the only emphasis.
private struct ShareBar: View {
    let share: Double

    var body: some View {
        // Fill only, no track: a track's ragged start (after "1 purchase" vs "12 purchases") reads as noise.
        GeometryReader { geometry in
            Capsule()
                .fill(Color.primary.opacity(0.3))
                .frame(width: max(3, geometry.size.width * min(share, 1)), height: 3)
                .frame(maxHeight: .infinity)
        }
        .frame(height: 3)
        .help(share.formatted(.percent.precision(.fractionLength(0))) + " of spending")
    }
}

/// Full-width clickable row with the rounded hover highlight macOS menus use.
private struct RowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Row(configuration: configuration)
    }

    private struct Row: View {
        let configuration: Configuration
        @State private var hovering = false
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .padding(.horizontal, MenuView.inset)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.primary.opacity(configuration.isPressed ? 0.12 : hovering && isEnabled ? 0.06 : 0))
                )
                .opacity(isEnabled ? 1 : 0.5)
                .onHover { hovering = $0 }
        }
    }
}

/// MenuBarExtra has no right-click hook, so watch for right clicks that land on the menu bar item's own window.
@MainActor
private enum StatusItemMenu {
    private static var monitor: Any?

    static func install(_ store: Store) {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .rightMouseDown) { event in
            guard let window = event.window, window.className.contains("StatusBar") else { return event }
            ActionMenu.show([
                .action(store.hideNumbers ? "Show numbers" : "Hide numbers") { store.hideNumbers.toggle() },
                .action("Notify on new charges", checked: store.notifyCharges) { store.notifyCharges.toggle() },
            ])
            return nil
        }
    }
}

/// Pops up a native NSMenu at the mouse, for row actions.
@MainActor
private enum ActionMenu {
    enum Item {
        case action(String, checked: Bool = false, () -> Void)
        case divider
    }

    private final class Target: NSObject {
        let handler: () -> Void
        init(_ handler: @escaping () -> Void) { self.handler = handler }
        @objc func run() { handler() }
    }

    static func show(_ items: [Item]) {
        let menu = NSMenu()
        for item in items {
            switch item {
            case .divider:
                if menu.items.last?.isSeparatorItem == false { menu.addItem(.separator()) }
            case let .action(title, checked, handler):
                let target = Target(handler)
                let menuItem = NSMenuItem(title: title, action: #selector(Target.run), keyEquivalent: "")
                menuItem.target = target
                menuItem.representedObject = target  // NSMenuItem holds its target weakly; this keeps it alive
                menuItem.state = checked ? .on : .off
                menu.addItem(menuItem)
            }
        }
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }
}

/// MenuBarExtra's window grows with its content but doesn't shrink back, leaving the content centered between
/// empty bands. Resize the window to the measured content height ourselves, keeping its top edge under the menu bar.
/// Resizing, relayout and redraw happen in one transaction so no unpainted (black) area flashes in between.
@MainActor
private func fitWindow(_ window: NSWindow?, to contentHeight: CGFloat) {
    guard let window, contentHeight > 0 else { return }
    let frame = window.frame
    let delta = contentHeight - window.contentRect(forFrameRect: frame).height
    guard abs(delta) > 0.5 else { return }
    let height = frame.height + delta
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    window.setFrame(NSRect(x: frame.minX, y: frame.maxY - height, width: frame.width, height: height), display: false)
    window.contentView?.layoutSubtreeIfNeeded()
    window.displayIfNeeded()
    CATransaction.commit()
}

/// Hands back the NSWindow hosting the SwiftUI content once it's attached.
private struct WindowReader: NSViewRepresentable {
    let onWindow: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView { ReaderView(onWindow: onWindow) }
    func updateNSView(_ view: NSView, context: Context) {}

    private final class ReaderView: NSView {
        let onWindow: (NSWindow) -> Void
        init(onWindow: @escaping (NSWindow) -> Void) {
            self.onWindow = onWindow
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { fatalError() }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { DispatchQueue.main.async { self.onWindow(window) } }
        }
    }
}

// MARK: - Display helpers

private extension Period {
    var unit: String {
        switch self {
        case .day: "day"
        case .week: "week"
        case .month: "month"
        }
    }
}

private extension Store {
    var accountsByID: [String: Account] {
        Dictionary(connections.flatMap { $0.accounts ?? [] }.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }
}

private extension Transaction {
    var symbol: String {
        switch personalFinanceCategory?.detailed ?? personalFinanceCategory?.primary ?? "" {
        case let c where c.hasPrefix("FOOD_AND_DRINK_GROCERIES"): "cart.fill"
        case let c where c.hasPrefix("FOOD_AND_DRINK"): "fork.knife"
        case let c where c.hasPrefix("GENERAL_MERCHANDISE"): "bag.fill"
        case let c where c.hasPrefix("TRANSPORTATION"): "car.fill"
        case let c where c.hasPrefix("TRAVEL"): "airplane"
        case let c where c.hasPrefix("ENTERTAINMENT"): "tv.fill"
        case let c where c.hasPrefix("RENT_AND_UTILITIES"): "house.fill"
        case let c where c.hasPrefix("MEDICAL"): "cross.case.fill"
        case let c where c.hasPrefix("PERSONAL_CARE"): "heart.fill"
        case let c where c.hasPrefix("HOME_IMPROVEMENT"): "hammer.fill"
        case let c where c.hasPrefix("GENERAL_SERVICES"): "wrench.and.screwdriver.fill"
        default: "creditcard.fill"
        }
    }
}

private extension Account {
    /// Banks send messy names, e.g. "WELLS FARGO ACTIVE CASH VISA\u{FFFD}\u{FFFD} CARD ...4095": drop broken characters
    /// and the trailing account number (shown on the second line), and soften all caps to title case.
    var displayName: String {
        var cleaned = name.replacingOccurrences(of: "\u{FFFD}", with: "")
        if let trailingMask = try? Regex(#"\s*\.{2,}\s*\d+\s*$"#) {
            cleaned = cleaned.replacing(trailingMask, with: "")
        }
        cleaned = cleaned.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        if cleaned.isEmpty { return name }
        return cleaned == cleaned.uppercased() && cleaned.count > 4 ? cleaned.capitalized : cleaned
    }

    /// "Credit card ••4821". The bank logo beside it already says which bank.
    var kind: String {
        let type = (subtype ?? type ?? "account").prefix(1).uppercased() + (subtype ?? type ?? "account").dropFirst()
        return mask.map { "\(type) ••\($0)" } ?? type
    }

    /// The card a purchase was on: its name when short ("CSP ••0586"), otherwise its kind ("credit card ••1009").
    var shortName: String {
        let label = displayName.count <= 16 ? displayName : (subtype ?? "account")
        return mask.map { "\(label) ••\($0)" } ?? label
    }
}
