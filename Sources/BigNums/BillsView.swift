import SwiftUI

/// "What's coming up?": the charges that repeat, grouped by how soon each one is due.
struct BillsView: View {
    let store: Store

    /// How soon a charge is due, which is how the list is grouped.
    private enum Bucket: Int, CaseIterable {
        case week, month, nextMonth, later

        var title: String {
            switch self {
            case .week: "Next 7 days"
            case .month: "Later this month"
            case .nextMonth: "Next month"
            case .later: "Later"
            }
        }
    }

    private func bucket(for date: Date, today: Date) -> Bucket {
        let cal = Calendar.current
        let days = cal.dateComponents([.day], from: today, to: cal.startOfDay(for: date)).day ?? 0
        if days <= 7 { return .week }
        if cal.isDate(date, equalTo: today, toGranularity: .month) { return .month }
        if let next = cal.date(byAdding: .month, value: 1, to: today), cal.isDate(date, equalTo: next, toGranularity: .month) {
            return .nextMonth
        }
        return .later
    }

    var body: some View {
        let items = store.recurring
        let dismissed = store.dismissedRecurring.sorted()
        let today = Calendar.current.startOfDay(for: store.referenceDate)
        let grouped = Dictionary(grouping: items) { bucket(for: $0.next, today: today) }
        VStack(alignment: .leading, spacing: 0) {
            Hero(label: "Recurring", value: items.reduce(0) { $0 + $1.monthlyCost }, suffix: "/mo",
                 context: context(items, week: grouped[.week] ?? []))
            if items.isEmpty {
                Note("Nothing recurring found yet. Charges that repeat on a steady schedule show up here once there's a few months of history.")
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 22)
            } else {
                let accounts = store.accountsByID
                ForEach(Bucket.allCases, id: \.self) { bucket in
                    if let group = grouped[bucket] {
                        GroupHeader(title: bucket.title, total: Store.money(group.reduce(0) { $0 + $1.amount }))
                            .padding(.top, bucket == Bucket.allCases.first(where: { grouped[$0] != nil }) ? 22 : 10)
                        ForEach(group) { row($0, account: $0.sample.accountId.flatMap { accounts[$0] }) }
                    }
                }
            }
            if !dismissed.isEmpty {
                RestoreNote(text: dismissed.count == 1 ? "\(dismissed[0]) isn't recurring" : "\(dismissed.count) aren't recurring", help: "Marked as not recurring. Click to restore.",
                            names: dismissed, itemTitle: { "Restore \($0)" }, allTitle: "Restore all",
                            restore: store.restoreRecurring, restoreAll: store.restoreAllRecurring)
                    .padding(.top, 14)
            }
        }
    }

    /// A price increase is the thing worth knowing; otherwise what's due soon, otherwise what's next.
    private func context(_ items: [Recurring], week: [Recurring]) -> Text? {
        if let up = items.first(where: { ($0.change ?? 0) > 0 }), let change = up.change {
            return Text("\(up.name) went up \(change.formatted(.currency(code: "USD")))").foregroundStyle(.orange)
        }
        if !week.isEmpty {
            return Text("\(Store.money(week.reduce(0) { $0 + $1.amount })) due in the next 7 days")
        }
        if let next = items.first {
            return Text("Next: \(next.name) · \(next.next.formatted(.dateTime.month(.abbreviated).day()))")
        }
        return nil
    }

    private func row(_ item: Recurring, account: Account?) -> some View {
        let date = item.next.formatted(.dateTime.month(.abbreviated).day())
        let counted = store.isCounted(item.name)
        // Shorter than shortName's "credit card ••1009", which would push the line past the row width.
        let card = account.map { a in a.displayName.count <= 16 ? a.shortName : "Card" + (a.mask.map { " ••\($0)" } ?? "") }
        let cadence = item.cadence == .monthly ? nil : item.cadence.label
        let parts = [cadence, date, card].compactMap { $0 }.joined(separator: " · ")
        return Button {
            ActionMenu.show([.action("Not a recurring charge") { store.dismissRecurring(item.name) }])
        } label: {
            ItemRow(title: item.name, amount: item.amount) {
                MerchantIcon(logo: item.sample.logoUrl.flatMap(URL.init(string:)), symbol: item.sample.symbol)
            } detail: {
                if let change = item.change, change > 0 {
                    Text("Up \(change.formatted(.currency(code: "USD"))) · \(parts)").foregroundStyle(.orange)
                } else if let change = item.change {
                    Text("Down \((-change).formatted(.currency(code: "USD"))) · \(parts)")
                } else {
                    Text(parts)
                }
            }
            .opacity(counted ? 1 : 0.5)
        }
        .buttonStyle(RowButtonStyle())
        .help(counted ? "" : "Not counted in spending totals")
    }
}
