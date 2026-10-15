import SwiftUI

/// The Settings window. BigNums has no server: you use your own free Plaid account, so your keys and your bank data stay
/// between your Mac and Plaid. This is a real window, not part of the menu, so it stays put while you go to the Plaid
/// dashboard to copy your keys.
struct SettingsView: View {
    let store: Store

    var body: some View {
        PlaidKeysView(store: store)
            .padding(28)
            .frame(width: 480)
            .fixedSize(horizontal: false, vertical: true)
    }
}

struct PlaidKeysView: View {
    let store: Store

    @State private var clientID = ""
    @State private var secret = ""
    @State private var environment: PlaidEnvironment = .production
    @State private var checking = false
    @State private var problem: String?
    @State private var saved = false
    @FocusState private var secretFocused: Bool

    private static let dashboard = URL(string: "https://dashboard.plaid.com/developers/api")!

    private var canSave: Bool {
        let hasSecret = !secret.trimmingCharacters(in: .whitespaces).isEmpty || store.hasStoredKeys
        return !clientID.trimmingCharacters(in: .whitespaces).isEmpty && hasSecret && !checking
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Plaid")
                .font(.system(size: 20, weight: .semibold))
            Text("BigNums reads your accounts through your own Plaid account. There's no BigNums server: your keys and your bank data stay between this Mac and Plaid.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 4)

            VStack(alignment: .leading, spacing: 10) {
                step(1, "Create a free Plaid account and request production access.")
                step(2, "In the dashboard, open Developers → Keys and copy your client ID and secret.")
                step(3, "Paste them below and press Save.")
            }
            .padding(.top, 18)

            Button { NSWorkspace.shared.open(Self.dashboard) } label: {
                HStack(spacing: 4) {
                    Text("Open the Plaid dashboard")
                    Image(systemName: "arrow.up.forward").font(.system(size: 10, weight: .semibold))
                }
            }
            .buttonStyle(.link)
            .padding(.top, 10)

            VStack(alignment: .leading, spacing: 12) {
                labeled("Client ID") {
                    TextField("", text: $clientID).textFieldStyle(.roundedBorder).autocorrectionDisabled()
                }
                labeled("Secret") {
                    SecureField(store.hasStoredKeys ? "Saved in your Keychain" : "", text: $secret)
                        .textFieldStyle(.roundedBorder)
                        .focused($secretFocused)
                }
                labeled("Environment") {
                    Picker("", selection: $environment) {
                        ForEach(PlaidEnvironment.allCases) { Text($0.title).tag($0) }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .fixedSize()
                }
            }
            .padding(.top, 20)

            if let problem {
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 12)
            } else if saved {
                Label("Saved. You can close this window and add your accounts from the menu bar.", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.green)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 12)
            }

            HStack {
                if store.hasStoredKeys {
                    Button("Remove keys", role: .destructive) {
                        store.removePlaidKeys()
                        clientID = ""
                        secret = ""
                        saved = false
                    }
                }
                Spacer()
                Button(action: save) {
                    if checking { ProgressView().controlSize(.small) } else { Text("Save") }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canSave)
            }
            .padding(.top, 18)

            Divider().padding(.top, 18)
            Label("Saved in your Mac's Keychain, never in a file or inside the app. Sent only to Plaid.", systemImage: "lock.fill")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .padding(.top, 12)
            // Only worth saying when the keys are actually about to change.
            if let stored = PlaidKeys.stored, !store.connections.isEmpty, clientID.trimmingCharacters(in: .whitespaces) != stored.clientID {
                Text("Banks you linked with the old keys will need reconnecting.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
            }
        }
        .onAppear {
            // Show what's saved, apart from the secret itself, which is never put back on screen.
            if let keys = PlaidKeys.stored {
                clientID = keys.clientID
                environment = keys.environment
            }
        }
    }

    // MARK: Pieces

    private func step(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(number)")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 20, height: 20)
                .background(Circle().fill(Color.primary.opacity(0.08)))
            Text(text)
                .font(.system(size: 13))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func labeled<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .frame(width: 90, alignment: .trailing)
            content()
        }
    }

    private func save() {
        problem = nil
        saved = false
        checking = true
        // Keep the old secret if only the other fields changed.
        let typed = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        let keys = PlaidKeys(clientID: clientID.trimmingCharacters(in: .whitespacesAndNewlines),
                             secret: typed.isEmpty ? (PlaidKeys.stored?.secret ?? "") : typed, environment: environment)
        Task {
            do {
                try await store.connectPlaid(keys)
                // A field that still has focus keeps showing what was typed, so let go of it before clearing the secret.
                secretFocused = false
                secret = ""
                saved = true
            } catch {
                problem = error.localizedDescription
            }
            checking = false
        }
    }
}
