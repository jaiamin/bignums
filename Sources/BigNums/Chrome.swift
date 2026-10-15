import SwiftUI

/// The three questions the menu answers. Each is a tab; everything else lives inside one of them.
enum Tab: String, CaseIterable, Identifiable {
    case spend, bills, balances

    var id: Self { self }

    var title: String {
        switch self {
        case .spend: "Spend"
        case .bills: "Bills"
        case .balances: "Balances"
        }
    }

    var symbol: String {
        switch self {
        case .spend: "chart.bar"
        case .bills: "calendar"
        case .balances: "building.columns"
        }
    }
}

/// Ways to look at the same period's spending, one at a time in the same slot.
enum Lens: String, CaseIterable, Identifiable {
    case merchants, categories, cards, trend

    var id: Self { self }

    func title(for period: Period) -> String {
        switch self {
        case .merchants: period == .day ? "Purchases" : "Merchants"
        case .categories: "Categories"
        case .cards: "Cards"
        case .trend: "Trend"
        }
    }
}

/// Switches between lenses with quiet text, the way Music or Notes switch views: no boxes, just which one is selected.
struct LensStrip: View {
    let period: Period
    @Binding var selection: Lens

    var body: some View {
        HStack(spacing: 14) {
            ForEach(Lens.allCases) { lens in
                Button { selection = lens } label: {
                    Text(lens.title(for: period))
                        .font(.system(size: 12, weight: selection == lens ? .semibold : .regular))
                        .foregroundStyle(selection == lens ? Color.primary : Color.secondary)
                        .padding(.vertical, 3)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, MenuView.inset)
    }
}

/// Footer navigation: icons, with the current tab's name beside its icon, a small dot on a tab that needs a look.
struct TabBar: View {
    @Binding var selection: Tab
    let attention: [Tab: Color]
    var active = true  // false while another screen (Ask) is showing, so no tab looks selected

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Tab.allCases) { tab in
                Button { selection = tab } label: {
                    HStack(spacing: 5) {
                        Image(systemName: tab.symbol)
                            .font(.system(size: 11, weight: .medium))
                        // Only the current tab spells itself out; the others are icons, which keeps room for the rest of the footer.
                        if active && selection == tab {
                            Text(tab.title)
                                .font(.system(size: 11, weight: .semibold))
                                .lineLimit(1)
                                .fixedSize()
                        }
                    }
                    .foregroundStyle((active && selection == tab) ? Color.primary : Color.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color.primary.opacity(active && selection == tab ? 0.08 : 0))
                    )
                    .overlay(alignment: .topTrailing) {
                        if let color = attention[tab], !(active && selection == tab) {
                            Circle().fill(color).frame(width: 5, height: 5).offset(x: -2, y: 3)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(tab.title)
            }
        }
    }
}

/// One line for the thing that most needs attention, shown above whichever tab is open.
struct AttentionBanner: View {
    let text: String
    var actionTitle: String?
    var action: () -> Void = {}

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11))
                .foregroundStyle(.red)
            Text(text)
                .font(.system(size: 12))
                .lineLimit(1)
            Spacer(minLength: 0)
            if let actionTitle {
                Button(actionTitle, action: action)
                    .buttonStyle(.borderless)
                    .font(.system(size: 12, weight: .medium))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.red.opacity(0.08)))
    }
}

/// Shows its content at natural height, and only scrolls once that would be taller than `maxHeight`.
/// So a short tab hugs its content and a long one can never outgrow the screen.
struct CappedScroll<Content: View>: View {
    let maxHeight: CGFloat
    let content: Content

    init(maxHeight: CGFloat, @ViewBuilder content: () -> Content) {
        self.maxHeight = maxHeight
        self.content = content()
    }

    var body: some View {
        ScrollView(.vertical) { content }
            .scrollBounceBehavior(.basedOnSize)
            .frame(maxHeight: maxHeight)
    }
}

enum MenuMetrics {
    /// Leaves room for the footer and the menu bar: the tallest the tab content may be on this screen.
    static var tabMaxHeight: CGFloat {
        #if DEBUG
        if let cap = ProcessInfo.processInfo.environment["BIGNUMS_CAP"].flatMap(Double.init) { return cap }  // to review scrolling
        #endif
        let screen = NSScreen.main?.visibleFrame.height ?? 900
        return min(560, screen - 160)
    }
}
