import SwiftUI

/// "What do I have?": net worth, and every account with its balance. Also where accounts are managed.
struct BalancesView: View {
    let store: Store
    @Binding var removing: String?  // connection awaiting remove confirmation

    var body: some View {
        let worth = store.netWorth
        VStack(alignment: .leading, spacing: 0) {
            Hero(label: "Net worth", value: worth?.total ?? 0, context: context(worth))
            if let id = removing, let connection = store.connections.first(where: { $0.id == id }) {
                removeConfirmation(connection)
                    .padding(.top, 14)
            }
            if let worth {
                group("Assets", worth.assets, total: worth.assetsTotal, sign: 1, first: true)
                group("Debts", worth.debts, total: worth.debtsTotal, sign: -1, first: worth.assets.isEmpty)
                group("Not counted", worth.uncounted, total: nil, sign: 1, first: false)
            }
            pending
            addAccountRow
                .padding(.top, 10)
        }
    }

    /// Change since we started recording, otherwise the split that makes up the total.
    private func context(_ worth: Store.NetWorth?) -> Text? {
        guard let worth else { return nil }
        guard worth.hasBalances else { return Text("Balances arrive with the next update") }
        if let change = store.netWorthChange(), abs(change.amount) >= 1 {
            let up = change.amount > 0
            let since = change.since.formatted(.dateTime.month(.abbreviated).day())
            let text = Text(Image(systemName: up ? "arrow.up.right" : "arrow.down.right")) + Text(" \(Store.money(abs(change.amount))) since \(since)")
            return up ? text : text.foregroundStyle(.orange)
        }
        return Text("\(Store.money(worth.assetsTotal)) assets · \(Store.money(worth.debtsTotal)) debts")
    }

    // MARK: Groups

    @ViewBuilder
    private func group(_ title: String, _ lines: [Store.NetWorth.Line], total: Double?, sign: Double, first: Bool) -> some View {
        if !lines.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                GroupHeader(title: title, total: total.map { Store.money($0 * sign) })
                ForEach(lines) { accountRow($0, sign: sign) }
            }
            .padding(.top, first ? 22 : 10)
        }
    }

    private func accountRow(_ line: Store.NetWorth.Line, sign: Double) -> some View {
        let account = line.account
        let connection = store.connections.first { $0.id == line.connectionID }
        let counted = !store.excludedAccounts.contains(account.id)
        return Button {
            if let connection { showActions(for: connection, account: account) }
        } label: {
            ItemRow(title: account.displayName, icon: {
                if let connection { BankLogo(connection: connection) }
            }, detail: {
                detail(for: line, in: connection, counted: counted)
            }, trailing: {
                Text(line.balance.map { amount in (amount == 0 ? 0 : amount * sign).formatted(.currency(code: "USD")) } ?? "—")
                    .font(.system(size: 13))
                    .monospacedDigit()
                    .foregroundStyle(line.balance == nil ? .secondary : .primary)
            })
            .opacity(counted ? 1 : 0.5)
        }
        .buttonStyle(RowButtonStyle())
        .help("Options for \(account.displayName)")
    }

    @ViewBuilder
    private func detail(for line: Store.NetWorth.Line, in connection: Connection?, counted: Bool) -> some View {
        let account = line.account
        if connection?.needsReconnect == true {
            Text("Sign-in expired. Click to reconnect.").foregroundStyle(.red)
        } else if let error = connection?.error {
            Text(error).foregroundStyle(.red)
        } else if !counted {
            Text("Not counted in totals")
        } else if account.type == "credit", let limit = account.balances?.limit, limit > 0, let owed = line.balance, owed / limit >= 0.01 {
            // How much of the limit is used, in the same quiet bar the spending rows use. Under 1% it would only be a dot.
            HStack(spacing: 8) {
                Text(account.kind).fixedSize()
                ShareBar(share: owed / limit, help: " of your \(Store.money(limit)) limit")
            }
        } else {
            Text(account.kind)
        }
    }

    /// Banks that were just connected (or never synced) have no accounts yet: one row each until they arrive.
    @ViewBuilder
    private var pending: some View {
        let waiting = store.connections.filter { ($0.accounts ?? []).isEmpty }
        if !waiting.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                GroupHeader(title: "Connecting")
                ForEach(waiting) { connection in
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
            .padding(.top, 10)
        }
    }

    // MARK: Actions

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
            .padding(.horizontal, MenuView.inset)
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
}
