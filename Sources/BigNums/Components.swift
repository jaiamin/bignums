import Charts
import SwiftUI

// MARK: - Building blocks

/// The one bold element: a light, large figure with a quieter dollar sign (and an optional unit like "/mo").
struct HeroAmount: View {
    let value: Double
    var suffix: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 1) {
            if value < 0 {
                Text("−")
                    .font(.system(size: 26, weight: .light))
                    .foregroundStyle(.secondary)
            }
            Text("$")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(.secondary)
            Text(value.magnitude.formatted(.number.precision(.fractionLength(0))))
                .font(.system(size: 44, weight: .light))
                .monospacedDigit()
                .contentTransition(.numericText())
                // Animate only the number: animating the layout makes the content resize smoothly while the
                // menu window jumps to its new size, leaving see-through gaps at the top and bottom.
                .animation(.snappy, value: value)
            if let suffix {
                Text(suffix)
                    .font(.system(size: 15, weight: .light))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 3)
            }
        }
    }
}

/// What every tab opens with: a small label, the big number, and one line of context beneath it.
struct Hero: View {
    let label: String
    let value: Double
    var suffix: String?
    var context: Text?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
            HeroAmount(value: value, suffix: suffix)
            // Always reserve the line so the layout doesn't shift when there's nothing to say.
            (context ?? Text(" "))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, MenuView.inset)
    }
}

struct SectionTitle: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, MenuView.inset)
            .padding(.bottom, 4)
    }
}

/// Heading for a group of rows, with an optional subtotal on the right.
struct GroupHeader: View {
    let title: String
    var total: String?

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            if let total { Text(total).monospacedDigit() }
        }
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, MenuView.inset)
        .padding(.top, 4)
        .padding(.bottom, 2)
    }
}

struct Note: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .padding(.horizontal, MenuView.inset)
            .padding(.vertical, 4)
    }
}

/// The one row anatomy used everywhere: 24pt icon, name with an optional second line, and a trailing amount or control.
struct ItemRow<Icon: View, Detail: View, Trailing: View>: View {
    let title: String
    @ViewBuilder let icon: Icon
    @ViewBuilder let detail: Detail
    @ViewBuilder let trailing: Trailing

    var body: some View {
        HStack(spacing: 10) {
            icon.frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 13))
                    .lineLimit(1)
                detail
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            trailing
        }
        .padding(.vertical, 4)
    }
}

extension ItemRow where Trailing == AmountText {
    init(title: String, amount: Double, @ViewBuilder icon: () -> Icon, @ViewBuilder detail: () -> Detail) {
        self.init(title: title, icon: icon, detail: detail, trailing: { AmountText(value: amount) })
    }
}

extension ItemRow where Detail == EmptyView {
    init(title: String, @ViewBuilder icon: () -> Icon, @ViewBuilder trailing: () -> Trailing) {
        self.init(title: title, icon: icon, detail: { EmptyView() }, trailing: trailing)
    }
}

extension ItemRow where Trailing == EmptyView {
    init(title: String, @ViewBuilder icon: () -> Icon, @ViewBuilder detail: () -> Detail) {
        self.init(title: title, icon: icon, detail: detail, trailing: { EmptyView() })
    }
}

extension ItemRow where Detail == EmptyView, Trailing == EmptyView {
    init(title: String, @ViewBuilder icon: () -> Icon) {
        self.init(title: title, icon: icon, detail: { EmptyView() }, trailing: { EmptyView() })
    }
}

struct AmountText: View {
    let value: Double

    var body: some View {
        Text(value > 0 ? value.formatted(.currency(code: "USD")) : "—")
            .font(.system(size: 13))
            .monospacedDigit()
            .foregroundStyle(value > 0 ? .primary : .secondary)
    }
}

/// Merchants are circles…
struct MerchantIcon: View {
    let logo: URL?
    let symbol: String

    var body: some View {
        AsyncImage(url: logo) { image in
            image.resizable().scaledToFill()
        } placeholder: {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.primary.opacity(0.07))
        }
        .frame(width: 24, height: 24)
        .clipShape(Circle())
    }
}

/// …banks are rounded squares, so the two kinds of row read differently at a glance.
struct BankLogo: View {
    let connection: Connection

    var body: some View {
        Group {
            if let logo = connection.logo.flatMap({ Data(base64Encoded: $0) }).flatMap(NSImage.init(data:)) {
                Image(nsImage: logo).resizable().scaledToFill()
            } else {
                Image(systemName: "building.columns.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.primary.opacity(0.07))
            }
        }
        .frame(width: 24, height: 24)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

/// A merchant's share of the period's spending. Neutral, so the total stays the only emphasis.
struct ShareBar: View {
    let share: Double
    var help = " of spending"

    var body: some View {
        // Fill only, no track: a track's ragged start (after "1 purchase" vs "12 purchases") reads as noise.
        GeometryReader { geometry in
            Capsule()
                .fill(Color.primary.opacity(0.3))
                .frame(width: max(3, geometry.size.width * min(share, 1)), height: 3)
                .frame(maxHeight: .infinity)
        }
        .frame(height: 3)
        .help(share.formatted(.percent.precision(.fractionLength(0))) + help)
    }
}

/// Full-width clickable row with the rounded hover highlight macOS menus use.
struct RowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Row(configuration: configuration)
    }

    private struct Row: View {
        let configuration: Configuration
        @State private var hovering = false
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .padding(.horizontal, MenuView.inset)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.primary.opacity(configuration.isPressed ? 0.12 : hovering && isEnabled ? 0.06 : 0))
                )
                .opacity(isEnabled ? 1 : 0.5)
                .onHover { hovering = $0 }
        }
    }
}

/// The trend chart keeps its own hover state, so moving the mouse over it redraws only the chart, not the whole menu.
struct TrendChart: View {
    let points: [(start: Date, total: Double)]
    let average: Double
    let selected: Date
    let period: Period
    @State private var selection: Date?

    var body: some View {
        let hovered = selection.flatMap { date in points.min { abs($0.start.timeIntervalSince(date)) < abs($1.start.timeIntervalSince(date)) } }
        let shown = hovered ?? points.first { $0.start == selected }
        let format: Date.FormatStyle = switch period {
        case .day: .dateTime.month(.abbreviated).day()
        case .week: .dateTime.month(.abbreviated).day()
        case .month: .dateTime.month(.abbreviated)
        }
        return VStack(alignment: .leading, spacing: 12) {
            Text(shown.map { "\(period == .week ? "Week of " : "")\($0.start.formatted(format)): \(Store.money($0.total))" } ?? " ")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .monospacedDigit()
            Chart {
                ForEach(points, id: \.start) { point in
                    LineMark(x: .value("Date", point.start), y: .value("Spent", point.total))
                        .foregroundStyle(Color.accentColor)
                    AreaMark(x: .value("Date", point.start), y: .value("Spent", point.total))
                        .foregroundStyle(Color.accentColor.opacity(0.12))
                }
                RuleMark(y: .value("Average", average))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    .foregroundStyle(.secondary.opacity(0.6))
                if let shown {
                    PointMark(x: .value("Date", shown.start), y: .value("Spent", shown.total))
                        .foregroundStyle(Color.accentColor)
                }
            }
            .chartXSelection(value: $selection)
            .chartXScale(range: .plotDimension(startPadding: 12, endPadding: 32))
            .chartXAxis {
                if period == .month {
                    AxisMarks(values: points.map(\.start)) { _ in AxisTick(); AxisValueLabel(format: format, anchor: .top).font(.system(size: 10)) }
                } else {
                    AxisMarks(values: .automatic(desiredCount: 4)) { _ in AxisValueLabel(format: format).font(.system(size: 10)) }
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { value in
                    AxisGridLine()
                    AxisValueLabel { if let v = value.as(Double.self) { Text(Store.compactMoney(v)).font(.system(size: 10)) } }
                }
            }
            .frame(height: 110)
        }
        .padding(.horizontal, MenuView.inset)
        .padding(.top, 8)
    }
}

/// Pops up a native NSMenu at the mouse, for row actions.
@MainActor
enum ActionMenu {
    enum Item {
        case action(String, checked: Bool = false, () -> Void)
        case label(String)  // greyed-out information
        case divider
    }

    private final class Target: NSObject {
        let handler: () -> Void
        init(_ handler: @escaping () -> Void) { self.handler = handler }
        @objc func run() { handler() }
    }

    static func show(_ items: [Item]) {
        let menu = NSMenu()
        for item in items {
            switch item {
            case .divider:
                if menu.items.last?.isSeparatorItem == false { menu.addItem(.separator()) }
            case let .label(title):
                let menuItem = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                menuItem.isEnabled = false
                menu.addItem(menuItem)
            case let .action(title, checked, handler):
                let target = Target(handler)
                let menuItem = NSMenuItem(title: title, action: #selector(Target.run), keyEquivalent: "")
                menuItem.target = target
                menuItem.representedObject = target  // NSMenuItem holds its target weakly; this keeps it alive
                menuItem.state = checked ? .on : .off
                menu.addItem(menuItem)
            }
        }
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }
}

/// MenuBarExtra's window grows with its content but doesn't shrink back, leaving the content centered between
/// empty bands. Resize the window to the measured content height ourselves, keeping its top edge under the menu bar.
/// Resizing, relayout and redraw happen in one transaction so no unpainted (black) area flashes in between.
@MainActor
func fitWindow(_ window: NSWindow?, to contentHeight: CGFloat) {
    guard let window, contentHeight > 0 else { return }
    let frame = window.frame
    let delta = contentHeight - window.contentRect(forFrameRect: frame).height
    guard abs(delta) > 0.5 else { return }
    let height = frame.height + delta
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    window.setFrame(NSRect(x: frame.minX, y: frame.maxY - height, width: frame.width, height: height), display: false)
    window.contentView?.layoutSubtreeIfNeeded()
    window.displayIfNeeded()
    CATransaction.commit()
}

/// Hands back the NSWindow hosting the SwiftUI content once it's attached.
struct WindowReader: NSViewRepresentable {
    let onWindow: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView { ReaderView(onWindow: onWindow) }
    func updateNSView(_ view: NSView, context: Context) {}

    private final class ReaderView: NSView {
        let onWindow: (NSWindow) -> Void
        init(onWindow: @escaping (NSWindow) -> Void) {
            self.onWindow = onWindow
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { fatalError() }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { DispatchQueue.main.async { self.onWindow(window) } }
        }
    }
}

// MARK: - Display helpers

extension Period {
    var unit: String {
        switch self {
        case .day: "day"
        case .week: "week"
        case .month: "month"
        }
    }
}

extension Store {
    var accountsByID: [String: Account] {
        Dictionary(connections.flatMap { $0.accounts ?? [] }.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }
}

extension Transaction {
    var symbol: String { Self.symbol(forCategory: personalFinanceCategory?.detailed ?? personalFinanceCategory?.primary ?? "") }

    /// Icon for a Plaid category, detailed ("FOOD_AND_DRINK_GROCERIES") or primary ("FOOD_AND_DRINK").
    static func symbol(forCategory category: String) -> String {
        switch category {
        case let c where c.hasPrefix("FOOD_AND_DRINK_GROCERIES"): "cart.fill"
        case let c where c.hasPrefix("FOOD_AND_DRINK"): "fork.knife"
        case let c where c.hasPrefix("GENERAL_MERCHANDISE"): "bag.fill"
        case let c where c.hasPrefix("TRANSPORTATION"): "car.fill"
        case let c where c.hasPrefix("TRAVEL"): "airplane"
        case let c where c.hasPrefix("ENTERTAINMENT"): "tv.fill"
        case let c where c.hasPrefix("RENT_AND_UTILITIES"): "house.fill"
        case let c where c.hasPrefix("MEDICAL"): "cross.case.fill"
        case let c where c.hasPrefix("PERSONAL_CARE"): "heart.fill"
        case let c where c.hasPrefix("HOME_IMPROVEMENT"): "hammer.fill"
        case let c where c.hasPrefix("GENERAL_SERVICES"): "wrench.and.screwdriver.fill"
        default: "creditcard.fill"
        }
    }
}

extension Account {
    /// Banks send messy names, e.g. "WELLS FARGO ACTIVE CASH VISA\u{FFFD}\u{FFFD} CARD ...4095": drop broken characters
    /// and the trailing account number (shown on the second line), and soften all caps to title case.
    var displayName: String {
        var cleaned = name.replacingOccurrences(of: "\u{FFFD}", with: "")
        if let trailingMask = try? Regex(#"\s*\.{2,}\s*\d+\s*$"#) {
            cleaned = cleaned.replacing(trailingMask, with: "")
        }
        cleaned = cleaned.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        if cleaned.isEmpty { return name }
        return cleaned == cleaned.uppercased() && cleaned.count > 4 ? cleaned.capitalized : cleaned
    }

    /// "Credit card ••4821". The bank logo beside it already says which bank.
    var kind: String {
        let type = (subtype ?? type ?? "account").prefix(1).uppercased() + (subtype ?? type ?? "account").dropFirst()
        return mask.map { "\(type) ••\($0)" } ?? type
    }

    /// The card a purchase was on: its name when short ("CSP ••0586"), otherwise its kind ("credit card ••1009").
    var shortName: String {
        let label = displayName.count <= 16 ? displayName : (subtype ?? "account")
        return mask.map { "\(label) ••\($0)" } ?? label
    }
}


/// Quiet clickable line that lists what was set aside, each with a way to bring it back.
struct RestoreNote: View {
    let text: String
    var amount: Double?
    let help: String
    let names: [String]
    let itemTitle: (String) -> String
    let allTitle: String
    let restore: (String) -> Void
    let restoreAll: () -> Void

    var body: some View {
        Button {
            var items = names.map { name in ActionMenu.Item.action(itemTitle(name)) { restore(name) } }
            if names.count > 1 { items += [.divider, .action(allTitle) { restoreAll() }] }
            ActionMenu.show(items)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "eye.slash")
                    .font(.system(size: 10))
                    .frame(width: 14)
                Text(text)
                    .font(.system(size: 12))
                Spacer()
                if let amount {
                    Text(amount.formatted(.currency(code: "USD")))
                        .font(.system(size: 13))
                        .monospacedDigit()
                }
            }
            .foregroundStyle(.secondary)
            .padding(.vertical, 4)
        }
        .buttonStyle(RowButtonStyle())
        .help(help)
    }
}
