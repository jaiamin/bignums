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
        VStack(alignment: .leading, spacing: 12) {
            let totals = store.totals
            HStack {
                stat("Today", totals.day)
                stat("This week", totals.week)
                stat("This month", totals.month)
            }

            Divider()

            Text("Connections").font(.caption).foregroundStyle(.secondary)
            if store.connections.isEmpty {
                Text("No accounts connected yet.").foregroundStyle(.secondary)
            }
            ForEach(store.connections) { connection in
                connectionRow(connection)
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
        .frame(width: 320)
        .task { await store.refreshIfStale() }
    }

    private func stat(_ title: String, _ value: Double) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(Store.money(value)).font(.title3.weight(.semibold)).monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func connectionRow(_ connection: Connection) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(connection.institution)
                Group {
                    if let error = connection.error {
                        Text(error).foregroundStyle(.red)
                    } else if connection.cursor == nil {
                        Text("Waiting for transactions…")
                    } else if let synced = connection.lastSynced {
                        Text("Updated \(synced.formatted(.relative(presentation: .named)))")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
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
                    .help("Remove connection")
            }
        }
    }
}
