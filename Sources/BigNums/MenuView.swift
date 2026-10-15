import Charts
import SwiftUI

struct MenuView: View {
    let store: Store
    @AppStorage("period") private var period: Period = .month
    @AppStorage("accountsExpanded") private var accountsExpanded = false
    @AppStorage("recurringExpanded") private var recurringExpanded = false
    @AppStorage("trendExpanded") private var trendExpanded = false
    @AppStorage("netWorthExpanded") private var netWorthExpanded = false
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
                netWorthSection
                    .padding(.top, 4)
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
    static let inset: CGFloat = 6

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
            (comparison(interval, spent: breakdown.total) ?? Text(" "))
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
                    TrendChart(points: points, average: average, selected: interval.start, period: period)
                }
            }
        }
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
                    let accounts = store.accountsByID
                    ForEach(items) { recurringRow($0, account: $0.sample.accountId.flatMap { accounts[$0] }) }
                    if !dismissed.isEmpty {
                        restoreNote("\(dismissed.count) dismissed", help: "Marked as not recurring. Click to restore.",
                                    names: dismissed, itemTitle: { "Restore \($0)" }, allTitle: "Restore all",
                                    restore: store.restoreRecurring, restoreAll: store.restoreAllRecurring)
                    }
                }
            }
        }
    }

    private func recurringRow(_ item: Recurring, account: Account?) -> some View {
        let next = item.next.formatted(.dateTime.month(.abbreviated).day())
        let counted = store.isCounted(item.name)
        // Shorter than shortName's "credit card ••1009", which would push the line past the row width.
        let via = account.map { a in " · " + (a.displayName.count <= 16 ? a.shortName : "Card" + (a.mask.map { " ••\($0)" } ?? "")) } ?? ""
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

    // MARK: Net worth

    @ViewBuilder
    private var netWorthSection: some View {
        if let worth = store.netWorth {
            VStack(alignment: .leading, spacing: 0) {
                CollapsibleHeader(title: "Net worth", value: Store.money(worth.total), alert: nil, alertColor: .secondary,
                                  expanded: $netWorthExpanded)
                if netWorthExpanded {
                    netWorthGroup("Assets", worth.assets, total: worth.assetsTotal, sign: 1)
                    netWorthGroup("Debts", worth.debts, total: worth.debtsTotal, sign: -1)
                        .padding(.top, worth.assets.isEmpty ? 0 : 8)
                    netWorthChange
                }
            }
        }
    }

    /// A subtotal heading, then one row per account with its bank's logo and its balance.
    @ViewBuilder
    private func netWorthGroup(_ title: String, _ lines: [Store.NetWorth.Line], total: Double, sign: Double) -> some View {
        if !lines.isEmpty {
            // One container, so spacing applied to the group lands once rather than on every row.
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text(title)
                    Spacer()
                    Text(Store.money(total * sign))
                        .monospacedDigit()
                }
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, Self.inset)
                .padding(.top, 4)
                .padding(.bottom, 2)
                ForEach(lines) { line in
                    let connection = store.connections.first { $0.id == line.connectionID }
                    ItemRow(title: line.account.displayName, icon: {
                        if let connection { BankLogo(connection: connection) }
                    }, detail: {
                        Text(line.account.kind)
                    }, trailing: {
                        Text((line.balance * sign).formatted(.currency(code: "USD")))
                            .font(.system(size: 13))
                            .monospacedDigit()
                    })
                    .padding(.horizontal, Self.inset)
                }
            }
        }
    }

    /// How net worth moved since the earliest figure we've recorded in the last 30 days.
    @ViewBuilder
    private var netWorthChange: some View {
        if let change = store.netWorthChange(), abs(change.amount) >= 1 {
            let up = change.amount > 0
            HStack(spacing: 4) {
                Image(systemName: up ? "arrow.up.right" : "arrow.down.right")
                    .font(.system(size: 10, weight: .semibold))
                Text("\(Store.money(abs(change.amount))) since \(change.since.formatted(.dateTime.month(.abbreviated).day()))")
            }
            .font(.system(size: 12))
            .foregroundStyle(up ? Color.secondary : Color.orange)
            .padding(.horizontal, Self.inset)
            .padding(.top, 8)
            .padding(.bottom, 2)
        }
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
