import SwiftUI

@main
struct BigNumsApp: App {
    @State private var store = Store()

    var body: some Scene {
        MenuBarExtra {
            MenuView(store: store)
        } label: {
            Text(store.label).monospacedDigit()
        }
        .menuBarExtraStyle(.window)
    }
}

struct MenuView: View {
    let store: Store
    @State private var confirmingRemoval: String?

    var body: some View {
        let breakdown = store.breakdown
        VStack(alignment: .leading, spacing: 10) {
            row {
                Spacer()
            } values: {
                ForEach(["Today", "Week", "Month"], id: \.self) { title in
                    Text(title).font(.caption).foregroundStyle(.secondary).frame(width: Self.column, alignment: .trailing)
                }
            }
            row {
                Text("Total").font(.headline)
            } values: {
                amounts(breakdown.total, font: .headline)
            }

            Divider()

            if store.connections.isEmpty {
                Text("No accounts connected yet.").foregroundStyle(.secondary)
            }
            ForEach(store.connections) { connection in
                connectionSection(connection, breakdown)
            }

            if store.isLinking {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Finish connecting in your browser…").font(.callout)
                    Spacer()
                    Button("Cancel") { store.cancelLink() }
                }
            } else {
                Button { store.addConnection() } label: { Label("Add connection", systemImage: "plus") }
                    .disabled(!store.isConfigured)
            }

            if let message = store.message {
                Text(message).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            HStack {
                Button(store.isRefreshing ? "Refreshing…" : "Refresh") { Task { await store.refresh() } }
                    .disabled(store.isRefreshing || !store.isConfigured)
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }
            }
        }
        .padding()
        .frame(width: 400)
        .task { await store.refreshIfStale() }
    }

    private static let column: CGFloat = 64

    /// A name on the left and the three fixed-width number columns on the right, so every row lines up.
    private func row<Name: View, Values: View>(@ViewBuilder _ name: () -> Name, @ViewBuilder values: () -> Values) -> some View {
        HStack(spacing: 0) {
            name().frame(maxWidth: .infinity, alignment: .leading)
            values()
        }
    }

    private func amounts(_ totals: Totals?, font: Font = .body) -> some View {
        let t = totals ?? Totals()
        return ForEach(Array([t.day, t.week, t.month].enumerated()), id: \.offset) { _, value in
            Text(value > 0 ? Store.money(value) : "—")
                .font(font)
                .monospacedDigit()
                .foregroundStyle(value > 0 ? .primary : .secondary)
                .frame(width: Self.column, alignment: .trailing)
        }
    }

    private func connectionSection(_ connection: Connection, _ breakdown: Breakdown) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text(connection.institution).font(.subheadline.weight(.semibold))
                    if let error = connection.error {
                        Text(error).font(.caption).foregroundStyle(.red).lineLimit(2)
                    } else if connection.cursor == nil {
                        Text("Waiting for transactions…").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if confirmingRemoval == connection.id {
                    Button("Remove", role: .destructive) {
                        confirmingRemoval = nil
                        Task { await store.remove(connection.id) }
                    }
                    Button("Cancel") { confirmingRemoval = nil }
                } else {
                    Button { confirmingRemoval = connection.id } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless)
                        .help("Remove \(connection.institution)")
                }
            }

            ForEach(connection.accounts ?? []) { account in
                let excluded = store.excludedAccounts.contains(account.id)
                Button { store.toggleExcluded(account.id) } label: {
                    row {
                        Text(account.displayName)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .strikethrough(excluded)
                            .padding(.leading, 10)
                    } values: {
                        amounts(breakdown.byAccount[account.id])
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .opacity(excluded ? 0.4 : 1)
                .help(excluded ? "Excluded from totals — click to include" : "Click to exclude from totals")
            }
        }
    }
}
