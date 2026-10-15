#if DEBUG
import SwiftUI

/// Debug-only: renders the menu to a PNG so the design can be reviewed without clicking the menu bar.
/// `BIGNUMS_SNAPSHOT=out.png [BIGNUMS_TAB=spend|bills|balances] [BIGNUMS_LENS=merchants|categories|cards|trend]
/// [BIGNUMS_PERIOD=Day|Week|Month] [BIGNUMS_DARK=1] [BIGNUMS_REFRESH=1] [BIGNUMS_HIDDEN=merchant] [BIGNUMS_DISMISSED=merchant] swift run`
@MainActor
enum Snapshot {
    static func renderIfRequested() {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["BIGNUMS_SNAPSHOT"] else { return }
        if let period = env["BIGNUMS_PERIOD"] { UserDefaults.standard.set(period, forKey: "period") }
        UserDefaults.standard.set(env["BIGNUMS_TAB"] ?? "spend", forKey: "tab")
        UserDefaults.standard.set(env["BIGNUMS_LENS"] ?? "merchants", forKey: "lens")
        UserDefaults.standard.set(env["BIGNUMS_HIDDEN"].map { [$0] } ?? [], forKey: "hiddenMerchants")
        UserDefaults.standard.set(env["BIGNUMS_DISMISSED"].map { [$0] } ?? [], forKey: "dismissedRecurring")

        let store = Store(autoRefresh: false)
        if env["BIGNUMS_REFRESH"] != nil {
            // A real sync, so balances and anything else new come from the actual accounts. Pump the run loop so the async work finishes.
            var done = false
            Task { await store.refresh(); done = true }
            while !done { RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05)) }
        }
        let root = MenuView(store: store)
            .background(Color(nsColor: .windowBackgroundColor))
        let host = NSHostingView(rootView: root)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 800), styleMask: .borderless,
                              backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: env["BIGNUMS_DARK"] == nil ? .aqua : .darkAqua)
        window.contentView = host
        host.frame.size = host.fittingSize
        host.layoutSubtreeIfNeeded()

        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { exit(1) }
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        exit(0)
    }
}
#endif
