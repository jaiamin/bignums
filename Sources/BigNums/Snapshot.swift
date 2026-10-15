#if DEBUG
import SwiftUI

/// Debug-only: renders the menu to a PNG so the design can be reviewed without clicking the menu bar.
/// `BIGNUMS_SNAPSHOT=out.png [BIGNUMS_TAB=spend|bills|balances] [BIGNUMS_LENS=merchants|categories|cards|trend]
/// [BIGNUMS_PERIOD=Day|Week|Month] [BIGNUMS_DARK=1] [BIGNUMS_REFRESH=1] [BIGNUMS_ASK_OPEN=1] [BIGNUMS_NOKEYS=1] [BIGNUMS_SETTINGS=1] [BIGNUMS_ASK='question|another'] [BIGNUMS_HIDDEN=merchant] [BIGNUMS_DISMISSED=merchant] swift run`
@MainActor
enum Snapshot {
    static func renderIfRequested() {
        let env = ProcessInfo.processInfo.environment
        if env["BIGNUMS_LABELS"] != nil {  // what the menu bar item would say for each style
            let store = Store(autoRefresh: false)
            for style in MenuBarStyle.allCases { print("\(style.title): \(store.label(for: style))") }
            exit(0)
        }
        if env["BIGNUMS_INSIGHTS"] != nil, #available(macOS 26.0, *) {  // the raw analysis, to check the numbers behind the answers
            let assistant = AssistantProvider.assistant(for: Store(autoRefresh: false))
            for topic in [InsightTopic.savingsIdeas, .impulseSpending, .trends, .budget] { print("== \(topic)\n\(assistant.insights(topic, groupBy: nil))\n") }
            exit(0)
        }
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
        // Open the Ask screen, optionally asking real questions of the on-device model first.
        UserDefaults.standard.set(env["BIGNUMS_ASK_OPEN"] != nil || env["BIGNUMS_ASK"] != nil, forKey: "askOpen")
        if let questions = env["BIGNUMS_ASK"], #available(macOS 26.0, *) {
            let assistant = AssistantProvider.assistant(for: store)
            for question in questions.split(separator: "|") {
                var done = false
                let start = Date()
                Task { await assistant.ask(String(question)); done = true }
                while !done { RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05)) }
                if let turn = assistant.turns.last { print("Q: \(turn.question)\nA: \(turn.answer)  [\(String(format: "%.1f", Date().timeIntervalSince(start)))s]\n") }
            }
        }
        if env["BIGNUMS_NOKEYS"] != nil { store.debugDisconnect() }  // the first-run welcome
        // The Settings window, or the menu.
        let root = Group {
            if env["BIGNUMS_SETTINGS"] != nil { SettingsView(store: store) } else { MenuView(store: store) }
        }
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
