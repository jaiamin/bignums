import SwiftUI

@main
struct BigNumsApp: App {
    @State private var store = Store()

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
    @State private var offset = 0  // 0 = current period, -1 = previous, ...
    @State private var confirmingRemoval: String?
    @State private var window: NSWindow?
    @State private var contentHeight: CGFloat = 0

    var body: some View {
        let interval = period.interval(offset: offset, from: store.referenceDate)
        let breakdown = store.breakdown(interval)
        VStack(alignment: .leading, spacing: 0) {
            Picker("Period", selection: $period) {
                ForEach(Period.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            VStack(alignment: .leading, spacing: 2) {
                Text(Store.money(breakdown.total))
                    .font(.system(size: 34, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    // Animate only the number: animating the layout makes the content resize smoothly while the
                    // menu window jumps to its new size, leaving see-through gaps at the top and bottom.
                    .animation(.snappy, value: interval)
                HStack(spacing: 2) {
                    Text(title(interval))
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button { offset -= 1 } label: { Image(systemName: "chevron.left").frame(width: 22, height: 20) }
                        .disabled(!(store.historyStart.map { interval.start > $0 } ?? false))
                        .help("Previous")
                    Button { offset += 1 } label: { Image(systemName: "chevron.right").frame(width: 22, height: 20) }
                        .disabled(offset >= 0)
                        .help("Next")
                }
                .buttonStyle(.borderless)
                // Always reserve the line so the menu doesn't change height when there's nothing to compare.
                Text(comparison(interval, spent: breakdown.total) ?? " ")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 6)
            .padding(.top, 14)
            .padding(.bottom, 6)

            if store.connections.isEmpty {
                emptyState
            } else {
                if period == .day {
                    dayPurchases(breakdown.purchases)
                } else {
                    topMerchants(breakdown.purchases, total: breakdown.total)
                }
                Divider().padding(.top, 8).padding(.bottom, 2)
            }
            ForEach(store.connections) { connection in
                section(connection, breakdown)
            }

            if let message = store.message {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 6)
                    .padding(.top, 8)
            }

            Divider().padding(.vertical, 8)
            addRow
            Divider().padding(.vertical, 8)
            footer
        }
        .padding(12)
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
            if note.object as? NSWindow === window { offset = 0 }
        }
    }

    // MARK: Period title & comparison

    private func title(_ interval: DateInterval) -> String {
        let start = interval.start
        let last = interval.end.addingTimeInterval(-1)
        switch (period, offset) {
        case (.day, 0): return "Today"
        case (.day, -1): return "Yesterday"
        case (.day, _): return start.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
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
            let unit = period == .week ? "week" : "month"
            phrase = offset == 0 ? "this time last \(unit)" : "the \(unit) before"
        }
        let difference = spent - reference
        if abs(difference) < 1 { return "About the same as \(phrase)" }
        return "\(Store.money(abs(difference))) \(difference > 0 ? "more" : "less") than \(phrase)"
    }

    // MARK: Sections

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "creditcard")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text("No Accounts").font(.headline)
            Text("Connect a bank or card to start tracking your spending.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
    }

    private func dayPurchases(_ purchases: [Transaction]) -> some View {
        let accounts = Dictionary(store.connections.flatMap { $0.accounts ?? [] }.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let shown = purchases.prefix(Self.maxRows)
        return VStack(alignment: .leading, spacing: 2) {
            if purchases.isEmpty {
                status(offset == 0 ? "No purchases yet today" : "No purchases", color: .secondary)
            }
            ForEach(shown, id: \.transactionId) { txn in
                purchaseRow(txn, account: txn.accountId.flatMap { accounts[$0] })
            }
            if purchases.count > shown.count {
                status("+\(purchases.count - shown.count) more", color: .secondary)
            }
        }
    }

    /// Same row cap on every tab, so the menu keeps a steady height when switching periods.
    private static let maxRows = 5

    private func topMerchants(_ purchases: [Transaction], total: Double) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Top Merchants")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.top, 4)
            if purchases.isEmpty {
                status(offset == 0 ? "No purchases yet this \(period == .week ? "week" : "month")" : "No purchases", color: .secondary)
            }
            ForEach(MerchantTotal.top(purchases, limit: Self.maxRows)) { merchant in
                HStack(spacing: 10) {
                    MerchantIcon(logo: merchant.sample.logoUrl.flatMap(URL.init(string:)), symbol: merchant.sample.symbol)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(merchant.name).lineLimit(1)
                        HStack(spacing: 8) {
                            Text(merchant.count == 1 ? "1 purchase" : "\(merchant.count) purchases")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize()
                            ShareBar(share: total > 0 ? merchant.total / total : 0)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Text(merchant.total.formatted(.currency(code: "USD")))
                        .monospacedDigit()
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
            }
        }
    }

    private func purchaseRow(_ txn: Transaction, account: Account?) -> some View {
        let detail = [account.map { [$0.name, $0.mask.map { "••\($0)" }].compactMap { $0 }.joined(separator: " ") },
                      txn.pending == true ? "Pending" : nil]
            .compactMap { $0 }
            .joined(separator: " · ")
        return HStack(spacing: 10) {
            MerchantIcon(logo: txn.logoUrl.flatMap(URL.init(string:)), symbol: txn.symbol)
            VStack(alignment: .leading, spacing: 0) {
                Text(txn.merchantName ?? txn.name ?? "Purchase").lineLimit(1)
                if !detail.isEmpty {
                    Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            Text(txn.amount.formatted(.currency(code: "USD")))
                .monospacedDigit()
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
    }

    private func section(_ connection: Connection, _ breakdown: Breakdown) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                BankHeader(connection: connection)
                Spacer()
                if confirmingRemoval == connection.id {
                    Button("Cancel") { confirmingRemoval = nil }
                    Button("Remove", role: .destructive) {
                        confirmingRemoval = nil
                        Task { await store.remove(connection.id) }
                    }
                    .foregroundStyle(.red)
                } else {
                    Menu {
                        if let website = connection.websiteURL {
                            Button("Open Website") { NSWorkspace.shared.open(website) }
                            Divider()
                        }
                        Button("Reconnect…") { store.reconnect(connection.id) }
                            .disabled(store.isLinking)
                        Button("Remove \(connection.institution)…", role: .destructive) { confirmingRemoval = connection.id }
                    } label: {
                        Image(systemName: "ellipsis")
                    }
                    .menuStyle(.button)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .foregroundStyle(.tertiary)
                }
            }
            .buttonStyle(.borderless)
            .font(.caption)
            .frame(height: 18)
            .padding(.horizontal, 6)
            .padding(.top, 10)

            if let error = connection.error {
                HStack(alignment: .firstTextBaseline) {
                    status(error, color: .red)
                    if connection.needsReconnect {
                        Spacer()
                        Button("Reconnect") { store.reconnect(connection.id) }
                            .buttonStyle(.borderless)
                            .font(.caption.weight(.semibold))
                            .disabled(store.isLinking)
                            .padding(.trailing, 6)
                    }
                }
            } else if connection.cursor == nil {
                status("Waiting for transactions…", color: .secondary)
            }

            ForEach(connection.accounts ?? []) { account in
                accountRow(account, value: breakdown.byAccount[account.id] ?? 0)
            }
        }
    }

    private func status(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(color)
            .lineLimit(2)
            .padding(.horizontal, 6)
    }

    private func accountRow(_ account: Account, value: Double) -> some View {
        let included = !store.excludedAccounts.contains(account.id)
        return Button { store.toggleExcluded(account.id) } label: {
            HStack(spacing: 10) {
                CircleIcon(symbol: account.symbol, filled: included)
                VStack(alignment: .leading, spacing: 0) {
                    Text(account.name).lineLimit(1)
                    Text(account.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Text(value > 0 ? Store.money(value) : "—")
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .foregroundStyle(included && value > 0 ? .primary : .secondary)
            }
            .foregroundStyle(included ? .primary : .secondary)
        }
        .buttonStyle(RowButtonStyle())
        .help(included ? "Click to exclude from totals" : "Excluded from totals — click to include")
    }

    @ViewBuilder
    private var addRow: some View {
        if store.isLinking {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small).frame(width: 26, height: 26)
                Text("Finish in your browser…").foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { store.cancelLink() }
                    .buttonStyle(.borderless)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
        } else {
            Button { store.addConnection() } label: {
                HStack(spacing: 10) {
                    CircleIcon(symbol: "plus", filled: false)
                    Text("Add Account…")
                }
            }
            .buttonStyle(RowButtonStyle())
            .disabled(!store.isConfigured)
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Group {
                if store.isRefreshing {
                    Text("Updating…")
                } else if let last = store.lastRefresh {
                    Text("Updated \(last.formatted(.relative(presentation: .named)))")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            Spacer()
            Button { Task { await store.refresh() } } label: { Image(systemName: "arrow.clockwise") }
                .disabled(store.isRefreshing || !store.isConfigured)
                .help("Refresh")
            Button { NSApplication.shared.terminate(nil) } label: { Image(systemName: "power") }
                .keyboardShortcut("q")
                .help("Quit BigNums")
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 6)
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

/// Round SF Symbol badge, like the macOS Wi-Fi and Bluetooth menus: accent-filled when on, gray when off.
private struct CircleIcon: View {
    let symbol: String
    let filled: Bool

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(filled ? Color.white : Color.primary.opacity(0.6))
            .frame(width: 26, height: 26)
            .background(Circle().fill(filled ? Color.accentColor : Color.primary.opacity(0.1)))
    }
}

/// Bank logo and name. Clicking opens the bank's website, where the browser fills in the saved password or passkey.
private struct BankHeader: View {
    let connection: Connection
    @State private var hovering = false

    var body: some View {
        if let website = connection.websiteURL {
            Button { NSWorkspace.shared.open(website) } label: {
                HStack(spacing: 4) {
                    label
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 8, weight: .bold))
                        .opacity(hovering ? 1 : 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .help("Open \(connection.institution) website")
        } else {
            label
        }
    }

    private var label: some View {
        HStack(spacing: 6) {
            Group {
                if let logo = connection.logoImage {
                    Image(nsImage: logo).resizable()
                } else {
                    Image(systemName: "building.columns.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color.primary.opacity(0.1))
                }
            }
            .frame(width: 14, height: 14)
            .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
            Text(connection.institution)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(hovering ? .primary : .secondary)
        }
    }
}

/// Thin bar showing a merchant's share of the period's spending, like Screen Time's "Most Used" list.
private struct ShareBar: View {
    let share: Double

    var body: some View {
        Capsule()
            .fill(Color.primary.opacity(0.08))
            .frame(height: 4)
            .overlay(alignment: .leading) {
                GeometryReader { geometry in
                    Capsule()
                        .fill(Color.accentColor)
                        .frame(width: max(4, geometry.size.width * min(share, 1)))
                }
            }
            .help(share.formatted(.percent.precision(.fractionLength(0))) + " of spending")
    }
}

/// Merchant logo from Plaid when available, otherwise a category symbol.
private struct MerchantIcon: View {
    let logo: URL?
    let symbol: String

    var body: some View {
        AsyncImage(url: logo) { image in
            image.resizable().scaledToFill()
        } placeholder: {
            CircleIcon(symbol: symbol, filled: false)
        }
        .frame(width: 26, height: 26)
        .clipShape(Circle())
    }
}

/// Full-width menu row with the rounded hover highlight macOS menus use.
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
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.primary.opacity(configuration.isPressed ? 0.12 : hovering && isEnabled ? 0.07 : 0))
                )
                .opacity(isEnabled ? 1 : 0.5)
                .onHover { hovering = $0 }
        }
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

private extension Connection {
    var logoImage: NSImage? {
        logo.flatMap { Data(base64Encoded: $0) }.flatMap(NSImage.init(data:))
    }
}

private extension Account {
    var symbol: String {
        switch (type, subtype) {
        case ("credit", _): "creditcard.fill"
        case (_, "savings"), (_, "money market"), (_, "cd"), (_, "hsa"): "banknote.fill"
        case ("loan", _): "house.fill"
        case ("investment", _): "chart.line.uptrend.xyaxis"
        default: "building.columns.fill"
        }
    }

    /// e.g. "Credit Card ••4821"
    var detail: String {
        [subtype?.capitalized, mask.map { "••\($0)" }].compactMap { $0 }.joined(separator: " ")
    }
}
