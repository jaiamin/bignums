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

enum Period: String, CaseIterable, Identifiable {
    case day = "Today", week = "Week", month = "Month"

    var id: Self { self }

    var caption: String {
        switch self {
        case .day: "Spent today"
        case .week: "Spent this week"
        case .month: "Spent this month"
        }
    }

    func value(_ totals: Totals?) -> Double {
        guard let totals else { return 0 }
        switch self {
        case .day: return totals.day
        case .week: return totals.week
        case .month: return totals.month
        }
    }
}

struct MenuView: View {
    let store: Store
    @AppStorage("period") private var period: Period = .month
    @State private var confirmingRemoval: String?
    @State private var contentHeight: CGFloat = 0

    var body: some View {
        let breakdown = store.breakdown
        VStack(alignment: .leading, spacing: 0) {
            Picker("Period", selection: $period) {
                ForEach(Period.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            VStack(alignment: .leading, spacing: 2) {
                Text(Store.money(period.value(breakdown.total)))
                    .font(.system(size: 34, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    // Animate only the number: animating the layout makes the content resize smoothly while the
                    // menu window jumps to its new size, leaving see-through gaps at the top and bottom.
                    .animation(.snappy, value: period)
                Text(period.caption)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 6)
            .padding(.top, 14)
            .padding(.bottom, 6)

            if store.connections.isEmpty {
                emptyState
            } else if period == .day {
                todayPurchases(breakdown.today)
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
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
        .background(WindowSizer(contentHeight: contentHeight))
        .task { await store.refreshIfStale() }
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

    private func todayPurchases(_ purchases: [Transaction]) -> some View {
        let accounts = Dictionary(store.connections.flatMap { $0.accounts ?? [] }.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let shown = purchases.prefix(Self.maxPurchases)
        return VStack(alignment: .leading, spacing: 2) {
            if purchases.isEmpty {
                status("No purchases yet today", color: .secondary)
            }
            ForEach(shown, id: \.transactionId) { txn in
                purchaseRow(txn, account: txn.accountId.flatMap { accounts[$0] })
            }
            if purchases.count > shown.count {
                status("+\(purchases.count - shown.count) more", color: .secondary)
            }
        }
    }

    private static let maxPurchases = 6

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
                Text(connection.institution)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
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
                accountRow(account, value: period.value(breakdown.byAccount[account.id]))
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
private struct WindowSizer: NSViewRepresentable {
    let contentHeight: CGFloat

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async {
            guard let window = view.window, contentHeight > 0 else { return }
            let frame = window.frame
            let delta = contentHeight - window.contentRect(forFrameRect: frame).height
            guard abs(delta) > 0.5 else { return }
            let height = frame.height + delta
            window.setFrame(NSRect(x: frame.minX, y: frame.maxY - height, width: frame.width, height: height), display: true)
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
