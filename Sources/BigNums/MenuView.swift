import Combine
import SwiftUI

/// The menu bar window: one tab at a time, a line for anything that needs attention, and a footer to move around.
struct MenuView: View {
    let store: Store
    @AppStorage("tab") private var tab: Tab = .spend
    @AppStorage("askOpen") private var asking = false  // the Ask screen is showing instead of a tab
    @AppStorage("assistantEnabled") private var assistantEnabled = true
    @State private var offset = 0  // Spend's period offset; kept here so it survives the content relaying out
    @State private var removing: String?  // connection awaiting remove confirmation
    @State private var window: NSWindow?
    @State private var contentHeight: CGFloat = 0
    @State private var isOpen = false
    @State private var session = UUID()  // a new value is a fresh menu: scroll positions and view state start over
    @State private var observers = WindowObservers()

    /// Everything shares one left edge: the outer padding plus this inset, which leaves room for row hover highlights.
    static let inset: CGFloat = 6

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !store.isConfigured {
                welcome
            } else if store.connections.isEmpty {
                emptyState
            } else {
                if let issue {
                    AttentionBanner(text: issue.text, actionTitle: issue.canFix ? "Sign in" : "View") {
                        if issue.canFix { store.reconnect(issue.connectionID) } else { tab = .balances }
                    }
                    .padding(.bottom, 12)
                }
                if asking && assistantVisible {
                    AskView(store: store)
                        .id(session)
                } else {
                    CappedScroll(maxHeight: MenuMetrics.tabMaxHeight) {
                        tabContent
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .id(session)
                }
            }

            if let message = store.message {
                Text(message)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, Self.inset)
                    .padding(.top, 12)
            }

            Divider()
                .padding(.top, 14)
                .padding(.bottom, 8)
            footer
        }
        .padding(14)
        .frame(width: 320)
        .fixedSize(horizontal: false, vertical: true)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
            contentHeight = height
            fitWindow(window, to: height)
        }
        .background(WindowReader { found in
            window = found
            observeVisibility(of: found)
            fitWindow(found, to: contentHeight)
        })
        .background(shortcuts)
        // While the menu is open it keeps itself current: sync on open, then whenever the data is a minute old.
        .task(id: isOpen) {
            guard isOpen else { return }
            await store.refreshIfStale()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                await store.refreshIfStale()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { note in
            if note.object as? NSWindow === window { isOpen = true }
        }
        // Losing focus also means it was dismissed (visibility, below, is the more reliable signal; either one resets).
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { note in
            if note.object as? NSWindow === window { resetToStart() }
        }
        .task { await store.refreshIfStale() }
    }

    /// Closing the menu returns it to the start, so it never reopens on old numbers, another tab, a half-finished
    /// confirmation or a scrolled-down list. The chat itself is kept: it's history, not view state.
    private func resetToStart() {
        isOpen = false
        asking = false
        tab = .spend
        offset = 0
        removing = nil
        UserDefaults.standard.set(Lens.merchants.rawValue, forKey: "lens")
        session = UUID()
    }

    /// Reacts to the window actually appearing and disappearing, which happens however it's dismissed: clicking the menu bar
    /// item again, clicking elsewhere, or Escape. Losing key status alone isn't reliably sent in all of those cases.
    private func observeVisibility(of window: NSWindow) {
        observers.bag.removeAll()
        window.publisher(for: \.isVisible)
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { visible in
                if visible { isOpen = true } else { resetToStart() }
            }
            .store(in: &observers.bag)
    }

    /// The sparkle button and Ask screen exist only where the on-device model could ever run, and unless switched off.
    private var assistantVisible: Bool { assistantEnabled && AssistantSupport.status != .notSupported }

    @ViewBuilder
    private var tabContent: some View {
        switch tab {
        case .spend: SpendView(store: store, offset: $offset)
        case .bills: BillsView(store: store)
        case .balances: BalancesView(store: store, removing: $removing)
        }
    }

    // MARK: Attention

    /// The one problem most worth interrupting for: a bank that needs you to sign in, then one that can't update.
    private var issue: (text: String, connectionID: String, canFix: Bool)? {
        if let c = store.connections.first(where: \.needsReconnect) {
            return ("\(c.institution) needs you to sign in again", c.id, true)
        }
        if let c = store.connections.first(where: { $0.error != nil }) {
            return ("\(c.institution) can't update", c.id, false)
        }
        return nil
    }

    /// A dot on tabs you aren't looking at that have something to see.
    private var attention: [Tab: Color] {
        var result: [Tab: Color] = [:]
        if store.recurring.contains(where: { ($0.change ?? 0) > 0 }) { result[.bills] = .orange }
        if issue != nil { result[.balances] = .red }
        return result
    }

    // MARK: Empty state & footer

    /// First run: BigNums needs the user's own Plaid keys, which are entered in the Settings window (the menu would close the
    /// moment they went to the Plaid dashboard to copy them).
    private var welcome: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Welcome to BigNums")
                .font(.system(size: 15, weight: .semibold))
            Text("BigNums reads your accounts through Plaid, using your own free Plaid keys, so your data stays between your Mac and Plaid. Setup takes about five minutes.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Set up Plaid…") { SettingsWindow.open() }
                .buttonStyle(.borderedProminent)
                .padding(.top, 8)
        }
        .padding(.horizontal, Self.inset)
        .padding(.vertical, 4)
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("See what you spend")
                .font(.system(size: 15, weight: .semibold))
            Text("Connect a bank or card and your spending for today, this week, and this month will appear in the menu bar.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Group {
                if store.isLinking {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Finish connecting in your browser").font(.system(size: 12))
                        Button("Cancel") { store.cancelLink() }.buttonStyle(.borderless).font(.system(size: 12))
                    }
                } else {
                    Button("Add account…") { store.addConnection() }
                        .buttonStyle(.borderedProminent)
                        .disabled(!store.isConfigured)
                }
            }
            .padding(.top, 8)
        }
        .padding(.horizontal, Self.inset)
        .padding(.vertical, 4)
    }

    private var footer: some View {
        HStack(spacing: 4) {
            if !store.connections.isEmpty && store.isConfigured {
                TabBar(selection: Binding(get: { tab }, set: { tab = $0; asking = false }), attention: attention, active: !asking)
            }
            Spacer()
            if assistantVisible && store.isConfigured && !store.connections.isEmpty {
                Button { asking.toggle() } label: {
                    Image(systemName: "sparkles")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(asking ? Color.primary : Color.secondary)
                        .frame(width: 24, height: 22)
                        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.primary.opacity(asking ? 0.08 : 0)))
                        .contentShape(Rectangle())
                }
                .help("Ask about your money (⌘K)")
            }
            // Re-evaluated every minute, so the tooltip's "Updated 3 minutes ago" never goes stale while the menu is open.
            TimelineView(.everyMinute) { _ in
                Button { Task { await store.refresh() } } label: {
                    Group {
                        if store.isRefreshing {
                            ProgressView().controlSize(.mini)
                        } else {
                            Image(systemName: "arrow.clockwise").font(.system(size: 11, weight: .medium))
                        }
                    }
                    .frame(width: 24, height: 22)
                    .contentShape(Rectangle())
                }
                .disabled(store.isRefreshing || !store.isConfigured)
                .help(updatedText + " Click to refresh.")
            }
            Button { showSettings() } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 11, weight: .medium))
                    .frame(width: 24, height: 22)
                    .contentShape(Rectangle())
            }
            .help("Settings")
        }
        .foregroundStyle(.secondary)
        .buttonStyle(.borderless)
    }

    private var updatedText: String {
        if store.isRefreshing { return "Updating…" }
        guard let last = store.lastRefresh else { return "Not updated yet." }
        return "Updated \(last.formatted(.relative(presentation: .named)))."
    }

    private func showSettings() {
        ActionMenu.show(SettingsMenu.items(store: store, status: updatedText))
    }

    /// ⌘1–3 switch tabs and ⌘Q quits, without any visible controls.
    private var shortcuts: some View {
        Group {
            Button("") { tab = .spend }.keyboardShortcut("1")
            Button("") { tab = .bills }.keyboardShortcut("2")
            Button("") { tab = .balances }.keyboardShortcut("3")
            Button("") { SettingsWindow.open() }.keyboardShortcut(",")
            Button("") { if assistantVisible { asking.toggle() } }.keyboardShortcut("k")
            Button("") { asking = false }.keyboardShortcut(.cancelAction)
            Button("") { NSApplication.shared.terminate(nil) }.keyboardShortcut("q")
        }
        .opacity(0)
        .allowsHitTesting(false)
    }
}

/// Keeps the window observers alive for as long as the menu exists.
private final class WindowObservers {
    var bag: Set<AnyCancellable> = []
}
