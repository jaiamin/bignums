import ServiceManagement
import SwiftUI

/// Open at login, through the system's login items. Needs a real app bundle, so it's unavailable under `swift run`.
@MainActor
enum LaunchAtLogin {
    static var isAvailable: Bool { Bundle.main.bundleIdentifier != nil }
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    static func toggle() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled { try service.unregister() } else { try service.register() }
        } catch {
            NSLog("BigNums: couldn't change open at login: \(error.localizedDescription)")
        }
        // macOS may want the user's say-so before an app can start at login.
        if service.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
    }
}

/// The settings shown by both the gear button and a right click on the menu bar item, so they can't drift apart.
@MainActor
enum SettingsMenu {
    static func items(store: Store, status: String? = nil) -> [ActionMenu.Item] {
        var items: [ActionMenu.Item] = []
        if let status { items += [.label(status), .divider] }

        items.append(.label("Menu bar shows"))
        items += MenuBarStyle.allCases.map { style in
            .action(style.title, checked: store.menuBarStyle == style) { store.menuBarStyle = style }
        }
        items.append(.action("Hide amounts", checked: store.hideNumbers) { store.hideNumbers.toggle() })
        items.append(.divider)

        if LaunchAtLogin.isAvailable {
            items.append(.action("Open at login", checked: LaunchAtLogin.isEnabled) { LaunchAtLogin.toggle() })
        }
        items.append(.action("Notify on new charges", checked: store.notifyCharges) { store.notifyCharges.toggle() })
        if AssistantSupport.status != .notSupported {
            let enabled = UserDefaults.standard.object(forKey: "assistantEnabled") as? Bool ?? true
            items.append(.action("Ask assistant (experimental)", checked: enabled) {
                UserDefaults.standard.set(!enabled, forKey: "assistantEnabled")
                if enabled { UserDefaults.standard.set(false, forKey: "askOpen") }
            })
        }

        // Merchants set aside stay reachable even in a period where they didn't charge you.
        let hidden = store.hiddenMerchants.sorted()
        if !hidden.isEmpty {
            items += [.divider, .label("Not counted")]
            items += hidden.map { name in .action("Count \(name) again") { store.unhide(name) } }
        }

        items += [
            .divider,
            .action("Refresh now") { Task { await store.refresh() } },
            .action("Quit BigNums") { NSApplication.shared.terminate(nil) },
        ]
        return items
    }
}
