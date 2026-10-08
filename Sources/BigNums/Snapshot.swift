#if DEBUG
import SwiftUI

/// Debug-only: renders the menu to a PNG so the design can be reviewed without clicking the menu bar.
/// `BIGNUMS_SNAPSHOT=out.png [BIGNUMS_PERIOD=Day|Week|Month] [BIGNUMS_DARK=1] [BIGNUMS_ACCOUNTS=1] [BIGNUMS_RECURRING=1]
/// [BIGNUMS_HIDDEN=merchant] swift run`
@MainActor
enum Snapshot {
    static func renderIfRequested() {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["BIGNUMS_SNAPSHOT"] else { return }
        if let period = env["BIGNUMS_PERIOD"] { UserDefaults.standard.set(period, forKey: "period") }
        UserDefaults.standard.set(env["BIGNUMS_ACCOUNTS"] != nil, forKey: "accountsExpanded")
        UserDefaults.standard.set(env["BIGNUMS_RECURRING"] != nil, forKey: "recurringExpanded")
        UserDefaults.standard.set(env["BIGNUMS_HIDDEN"].map { [$0] } ?? [], forKey: "hiddenMerchants")

        let root = MenuView(store: Store(autoRefresh: false))
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
