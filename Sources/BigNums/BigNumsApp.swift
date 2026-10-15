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

/// MenuBarExtra has no right-click hook, so watch for right clicks that land on the menu bar item's own window.
@MainActor
enum StatusItemMenu {
    private static var monitor: Any?

    static func install(_ store: Store) {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .rightMouseDown) { event in
            guard let window = event.window, window.className.contains("StatusBar") else { return event }
            ActionMenu.show([
                .action("Show numbers", checked: !store.hideNumbers) { store.hideNumbers.toggle() },
                .action("Notify on new charges", checked: store.notifyCharges) { store.notifyCharges.toggle() },
                .divider,
                .action("Refresh now") { Task { await store.refresh() } },
                .action("Quit BigNums") { NSApplication.shared.terminate(nil) },
            ])
            return nil
        }
    }
}
