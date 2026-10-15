import Charts
import SwiftUI

@main
struct BigNumsApp: App {
    @State private var store: Store

    init() {
        // `build.sh` uses this to move a developer's `.env` keys into the Keychain, so they're never copied into the app.
        if let flag = CommandLine.arguments.firstIndex(of: "--import-env"), CommandLine.arguments.indices.contains(flag + 1) {
            let imported = PlaidConfig.importEnvFile(URL(fileURLWithPath: CommandLine.arguments[flag + 1]))
            print(imported ? "Plaid keys saved to the Keychain." : "No Plaid keys found to import.")
            exit(imported ? 0 : 1)
        }
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
            StatusLabel(store: store)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(store: store)
        }
    }
}

/// What the menu bar item shows. It exists from launch, which makes it the place to pick up SwiftUI's `openSettings` action.
private struct StatusLabel: View {
    let store: Store
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Group {
            if store.isConfigured {
                if store.menuBarStyle == .iconOnly {
                    Image(systemName: "dollarsign.circle")
                } else {
                    Text(store.label).monospacedDigit()
                }
            } else {
                Image(systemName: "exclamationmark.triangle")
            }
        }
        .task {
            SettingsWindow.opener = { openSettings() }
            // `open -a BigNums --args --settings` opens Settings straight away.
            if CommandLine.arguments.contains("--settings") {
                try? await Task.sleep(for: .milliseconds(600))
                SettingsWindow.open()
            }
        }
    }
}

/// MenuBarExtra has no right-click hook, so watch for right clicks that land on the menu bar item's own window.
@MainActor
enum StatusItemMenu {
    private static var monitor: Any?

    static func install(_ store: Store) {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .rightMouseDown) { event in
            guard let window = event.window, window.className.contains("StatusBar") else { return event }
            ActionMenu.show(SettingsMenu.items(store: store))
            return nil
        }
    }
}
