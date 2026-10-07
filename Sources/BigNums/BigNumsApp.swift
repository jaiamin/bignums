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

    var body: some View {
        let breakdown = store.breakdown
        VStack(alignment: .leading, spacing: 0) {
            Picker("Period", selection: $period.animation(.snappy)) {
                ForEach(Period.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            VStack(alignment: .leading, spacing: 2) {
                Text(Store.money(period.value(breakdown.total)))
                    .font(.system(size: 34, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                Text(period.caption)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 6)
            .padding(.top, 14)
            .padding(.bottom, 6)

            if store.connections.isEmpty {
                emptyState
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
                status(error, color: .red)
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
