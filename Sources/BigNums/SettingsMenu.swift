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

/// Opens the Settings window. A menu bar app has no Dock icon, and such apps' windows don't reliably come to the front or
/// take typing, so while Settings is open the app presents itself as a regular app, then goes back to the menu bar.
@MainActor
enum SettingsWindow {
    private static var observer: NSObjectProtocol?
    /// SwiftUI's own action for opening the Settings scene. It can only be obtained from inside a view, so a view that always
    /// exists (the menu bar label) hands it over here.
    static var opener: (() -> Void)?

    static func open() {
        // The menu has done its job once Settings is wanted: close it rather than leave it open behind the window.
        NSApp.windows.filter { $0.level == .popUpMenu }.forEach { $0.orderOut(nil) }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        // One turn later, so the app has finished switching to a regular app before the window is asked for.
        DispatchQueue.main.async {
            if let opener { opener() } else { NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil) }
            NSApp.activate(ignoringOtherApps: true)
        }
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { note in
            guard let window = note.object as? NSWindow, window.identifier?.rawValue.localizedCaseInsensitiveContains("settings") == true else { return }
            MainActor.assumeIsolated { NSApp.setActivationPolicy(.accessory) }
        }
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
        items.append(.action("Settings…") { SettingsWindow.open() })
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
