import FoundationModels
import SwiftUI

@available(macOS 26.0, *)
@Generable
enum InsightTopic: String {
    case savingsIdeas, impulseSpending, trends, budget, subscriptions, focus
}

/// Open-ended questions: what to cut, where the habits are, how things moved, what a budget looks like. The ranking and
/// the arithmetic happen here in code; the model only explains what comes back.
@available(macOS 26.0, *)
struct InsightsTool: Tool {
    let assistant: Assistant
    let name = "insights"
    let description = """
        Analyzes the user's habits over past months. Topics: savingsIdeas (which spending to cut to save more, ranked by \
        monthly amount and trend), impulseSpending (where impulsive or habitual spending happens), trends (how categories \
        or merchants moved month to month), budget (average monthly spending, essentials versus discretionary, income and \
        savings rate), subscriptions (recurring charges ranked by cost, to decide which to cancel), focus (a close look at \
        one merchant or kind of spending, such as food delivery, coffee or DoorDash: monthly totals, trend, and whether it's \
        above its average). Use it for any question about saving money, what to cut, budgeting, habits, patterns, trends, \
        subscriptions, "am I overspending on X" or advice.
        """

    @Generable struct Arguments {
        @Guide(description: "What to analyze.") var topic: InsightTopic
        @Guide(description: "For trends only: compare by category or merchant. Default category.") var groupBy: AssistantGroup?
        @Guide(description: "For savingsIdeas: how many dollars a month the user wants to save, for example 200.") var targetMonthlySavings: Double?
        @Guide(description: "For focus: the merchant or kind of spending to look at, for example food delivery, coffee, groceries or DoorDash.") var subject: String?
    }

    func call(arguments: Arguments) async throws -> String {
        await assistant.noteTool("insights")
        let activity: String = switch arguments.topic {
        case .savingsIdeas: "Looking for savings…"
        case .impulseSpending: "Looking for patterns…"
        case .trends: "Reading your trends…"
        case .budget: "Working out your budget…"
        case .subscriptions: "Reviewing your subscriptions…"
        case .focus: "Taking a closer look…"
        }
        await assistant.setActivity(activity)
        return await assistant.insights(arguments.topic, groupBy: arguments.groupBy, target: arguments.targetMonthlySavings, subject: arguments.subject)
    }
}

@available(macOS 26.0, *)
extension Assistant {
    func insights(_ topic: InsightTopic, groupBy: AssistantGroup?, target: Double? = nil, subject: String? = nil) -> String {
        switch topic {
        case .savingsIdeas: savingsIdeas(target: numberInQuestion() ?? nil)  // the model drops the target, so read it from the question
        case .focus: focus(subject)
        case .impulseSpending: impulse()
        case .trends: trends(byMerchant: groupBy == .merchant)
        case .budget: budget()
        case .subscriptions: subscriptions()
        }
    }

    // MARK: Helpers

    private static func money(_ value: Double) -> String { Store.money(value) }
    private static func compact(_ value: Double) -> String { Store.compactMoney(value) }

    private func monthKey(_ date: Date) -> Int {
        let parts = Calendar.current.dateComponents([.year, .month], from: date)
        return (parts.year ?? 0) * 12 + (parts.month ?? 0)
    }

    private func monthName(_ date: Date) -> String { date.formatted(.dateTime.month(.abbreviated)) }

    private func span(_ window: MonthWindow) -> String {
        guard let first = window.complete.first, let last = window.complete.last else { return "this month so far" }
        let n = window.complete.count
        return "the last \(n) full month\(n == 1 ? "" : "s") (\(monthName(first))\(n == 1 ? "" : " to \(monthName(last))"))"
    }

    /// How a run of monthly totals (oldest first) is heading: the latest months against the ones before.
    private func direction(_ values: [Double]) -> String {
        guard values.count >= 3 else { return "" }  // two points is a difference, not a trend
        let recentCount = values.count >= 4 ? 2 : 1
        let recent = values.suffix(recentCount).reduce(0, +) / Double(recentCount)
        let earlier = values.dropLast(recentCount).reduce(0, +) / Double(values.count - recentCount)
        guard earlier >= 1 else { return recent >= 1 ? "new lately" : "" }
        let change = (recent - earlier) / earlier
        if change >= 1 { return "rising sharply (about \(String(format: "%.1f", recent / earlier))x)" }
        if change > 0.15 { return "rising (+\(Int((change * 100).rounded()))%)" }
        if change < -0.15 { return "falling (\(Int((change * 100).rounded()))%)" }
        return "steady"
    }

    /// Said whenever there isn't enough history for trends to mean much.
    private func historyNote(_ window: MonthWindow) -> String? {
        window.complete.count < 3
            ? "Note: only \(window.complete.count) full month\(window.complete.count == 1 ? "" : "s") of history so far, so treat any pattern as rough."
            : nil
    }

    private func categoryName(_ txn: Transaction) -> String {
        CategoryTotal(key: txn.personalFinanceCategory?.primary ?? "OTHER", total: 0, count: 0).name
    }

    // MARK: Savings ideas

    private func savingsIdeas(target: Double?) -> String {
        let window = store.monthWindow(maxMonths: 6)
        let completeKeys = window.complete.map(monthKey)
        let limited = completeKeys.isEmpty
        let counted = limited ? [monthKey(window.current)] : completeKeys  // with no full month yet, use this one
        let n = Double(counted.count)
        let all = store.countedPurchases(from: window.first)
        guard !all.isEmpty else { return "There isn't enough spending history yet to say." }

        struct Habit { var name: String; var months: [Int: Double] = [:]; var count = 0 }
        var habits: [String: Habit] = [:]
        var categories: [String: Double] = [:]
        var total = 0.0, discretionary = 0.0
        for purchase in all {
            let key = monthKey(purchase.date)
            guard counted.contains(key) else { continue }
            total += purchase.txn.amount
            guard purchase.txn.nature == .discretionary else { continue }
            discretionary += purchase.txn.amount
            categories[categoryName(purchase.txn), default: 0] += purchase.txn.amount
            let id = purchase.merchant.lowercased()
            habits[id, default: Habit(name: purchase.merchant)].months[key, default: 0] += purchase.txn.amount
            habits[id]!.count += 1
        }

        // A habit repeats: it shows up in more than one month, or very often. A few one-off purchases aren't something you can stop doing.
        let ranked = habits.values
            .filter { limited || $0.months.count >= 2 || $0.count >= 4 }
            .map { habit -> (habit: Habit, average: Double) in (habit, habit.months.values.reduce(0, +) / n) }
            .sorted { $0.average > $1.average }
            .prefix(5)
        guard let top = ranked.first else { return "Nothing in your discretionary spending repeats enough yet to call a habit." }

        var lines = ["Looked at counted spending over \(span(window)). Discretionary (non-essential) spending averages \(Self.money(discretionary / n)) a month, "
            + "\(Int((discretionary / max(total, 1) * 100).rounded()))% of all spending."]
        lines.append("Most cuttable habits, by monthly average:")
        for (index, item) in ranked.enumerated() {
            let perMonth = Double(item.habit.count) / n
            let series = counted.map { item.habit.months[$0] ?? 0 }
            let frequency = perMonth >= 1.5 ? "about \(Int(perMonth.rounded())) purchases a month" : "occasional"
            let trend = limited ? "" : direction(series)
            lines.append("\(index + 1). \(item.habit.name): about \(Self.money(item.average)) a month, \(frequency)" + (trend.isEmpty ? "" : ", \(trend)"))
        }
        let topCategories = categories.sorted { $0.value > $1.value }.prefix(3)
        lines.append("Discretionary by category: " + topCategories.map { "\($0.key) \(Self.money($0.value / n))/mo" }.joined(separator: "; ") + ".")

        let subscriptions = store.recurring.filter { $0.sample.nature != .essential }.sorted { $0.monthlyCost > $1.monthlyCost }
        if !subscriptions.isEmpty {
            lines.append("Recurring non-essential charges you could cancel: " + subscriptions.prefix(4).map { "\($0.name) \(Self.money($0.monthlyCost))" }.joined(separator: "; ")
                + " (\(Self.money(subscriptions.reduce(0) { $0 + $1.monthlyCost })) a month in all).")
        }
        lines.append("Cutting \(top.habit.name) entirely would save about \(Self.money(top.average)) a month (\(Self.money(top.average * 12)) a year).")
        if let target, target > 0 {
            // Ways to reach the amount: trim one habit by a share, or drop a few outright.
            var options: [String] = []
            for item in ranked.prefix(3) {
                options.append(item.average >= target
                    ? "cut \(item.habit.name) by about \(Int((target / item.average * 100).rounded()))% (\(Self.money(target)) of its \(Self.money(item.average)) a month)"
                    : "drop \(item.habit.name) entirely (\(Self.money(item.average)))")
            }
            var sum = 0.0, combo: [String] = []
            for item in ranked.reversed() where sum < target {  // the smallest habits first, so as little as possible is given up
                sum += item.average
                combo.append(item.habit.name)
            }
            if sum >= target, combo.count >= 2 { options.append("or drop \(combo.joined(separator: " and ")) entirely (about \(Self.money(sum)) a month)") }
            lines.append("To save \(Self.money(target)) a month: " + options.joined(separator: "; ") + ".")
        }
        lines.append("Note: essential versus discretionary is a rough guess from spending categories.")
        if let note = historyNote(window) { lines.append(note) }
        return lines.joined(separator: "\n")
    }

    // MARK: Impulse spending

    private static let timestampParser = ISO8601DateFormatter()

    private func impulse() -> String {
        let window = store.monthWindow(maxMonths: 6)
        let all = store.countedPurchases(from: window.first).filter { $0.txn.nature == .discretionary }
        guard !all.isEmpty else { return "No discretionary spending found to look at." }
        let cal = Calendar.current
        let total = all.reduce(0) { $0 + $1.txn.amount }
        var lines = ["Looked at discretionary (non-essential) purchases since \(monthName(window.first)): \(Self.money(total)) across \(all.count) purchases."]

        var merchants: [String: (name: String, count: Int, total: Double, largest: Purchase)] = [:]
        for p in all {
            let id = p.merchant.lowercased()
            var entry = merchants[id] ?? (p.merchant, 0, 0, p)
            entry.count += 1
            entry.total += p.txn.amount
            if p.txn.amount > entry.largest.txn.amount { entry.largest = p }
            merchants[id] = entry
        }

        let frequent = merchants.values.filter { $0.count >= 4 && $0.total / Double($0.count) <= 60 }.sorted { $0.total > $1.total }.prefix(3)
        if !frequent.isEmpty {
            lines.append("Frequent small purchases: " + frequent.map { "\($0.name) \($0.count) times averaging \(Self.money($0.total / Double($0.count))) (\(Self.money($0.total)) total)" }.joined(separator: "; ") + ".")
        }

        let byDay = Dictionary(grouping: all) { cal.startOfDay(for: $0.date) }
        let busy = byDay.filter { $0.value.count >= 3 }
        if !busy.isEmpty {
            let busiest = busy.max { $0.value.count < $1.value.count }!
            lines.append("Busy days: \(busy.count) day\(busy.count == 1 ? "" : "s") with 3 or more discretionary purchases, \(Self.money(busy.values.joined().reduce(0) { $0 + $1.txn.amount })) in all "
                + "(most: \(busiest.value.count) on \(busiest.key.formatted(.dateTime.month(.abbreviated).day()))).")
        }

        var weekdays: [Int: Int] = [:]  // by number of purchases, so a few big ones don't decide it
        for p in all { weekdays[cal.component(.weekday, from: p.date), default: 0] += 1 }
        if let peak = weekdays.max(by: { $0.value < $1.value }) {
            lines.append("Busiest day of the week: \(cal.weekdaySymbols[peak.key - 1]), with \(peak.value) of the \(all.count) discretionary purchases.")
        }

        let oneOffs = merchants.values.filter { $0.count == 1 && $0.largest.txn.amount >= 40 }.sorted { $0.total > $1.total }
        if !oneOffs.isEmpty {
            let biggest = oneOffs[0]
            lines.append("One-off purchases of $40 or more at merchants you didn't return to: \(oneOffs.count), \(Self.money(oneOffs.reduce(0) { $0 + $1.total })) in all "
                + "(largest: \(biggest.name) \(Self.money(biggest.total)) on \(biggest.largest.date.formatted(.dateTime.month(.abbreviated).day()))).")
        }

        let lateNight = all.filter { p in
            guard let stamp = p.txn.authorizedDatetime ?? p.txn.datetime, let time = Self.timestampParser.date(from: stamp) else { return false }
            let hour = cal.component(.hour, from: time)
            return hour >= 22 || hour < 5
        }
        if !lateNight.isEmpty {
            lines.append("Late-night purchases (10pm to 5am): \(lateNight.count) totaling \(Self.money(lateNight.reduce(0) { $0 + $1.txn.amount })).")
        }
        lines.append("These are patterns that often go with impulse buying, not proof that any purchase was.")
        if let note = historyNote(window) { lines.append(note) }
        return lines.joined(separator: "\n")
    }

    // MARK: Trends

    private func trends(byMerchant: Bool) -> String {
        let window = store.monthWindow(maxMonths: 5)
        let completeKeys = window.complete.map(monthKey)
        let keys = completeKeys + [monthKey(window.current)]
        let all = store.countedPurchases(from: window.first)
        guard !all.isEmpty else { return "There isn't enough spending history yet to show a trend." }

        var series: [String: [Int: Double]] = [:]
        var overall: [Int: Double] = [:]
        for p in all {
            let key = monthKey(p.date)
            overall[key, default: 0] += p.txn.amount
            series[byMerchant ? p.merchant : categoryName(p.txn), default: [:]][key, default: 0] += p.txn.amount
        }
        func describe(_ months: [Int: Double]) -> String {
            let values = keys.map { months[$0] ?? 0 }
            let text = values.enumerated().map { index, value in
                Self.compact(value) + (index == values.count - 1 ? " so far" : "")
            }.joined(separator: ", ")
            let trend = direction(completeKeys.map { months[$0] ?? 0 })
            return text + (trend.isEmpty ? "" : " (\(trend))")
        }
        var lines = ["Monthly spending, oldest to newest: " + (window.complete + [window.current]).map(monthName).joined(separator: ", ") + " (the last month is still in progress)."]
        lines.append("All spending: " + describe(overall))
        let top = series.sorted { $0.value.values.reduce(0, +) > $1.value.values.reduce(0, +) }.prefix(6)
        for (name, months) in top { lines.append("\(name): " + describe(months)) }
        if let note = historyNote(window) { lines.append(note) }
        return lines.joined(separator: "\n")
    }

    // MARK: Budget

    private func budget() -> String {
        let window = store.monthWindow(maxMonths: 6)
        let completeKeys = window.complete.map(monthKey)
        guard !completeKeys.isEmpty else { return "There isn't a full month of history yet, so a budget baseline isn't possible." }
        let n = Double(completeKeys.count)
        let all = store.countedPurchases(from: window.first)

        var essential = 0.0, discretionary = 0.0, other = 0.0, thisMonth = 0.0
        for p in all {
            let key = monthKey(p.date)
            if key == monthKey(window.current) { thisMonth += p.txn.amount }
            guard completeKeys.contains(key) else { continue }
            switch p.txn.nature {
            case .essential: essential += p.txn.amount
            case .discretionary: discretionary += p.txn.amount
            case .other: other += p.txn.amount
            }
        }
        let spending = (essential + discretionary + other) / n
        var lines = ["Average monthly spending: \(Self.money(spending)) (\(span(window)))."]
        if let income = store.income(during: window.complete) {
            let average = income / n
            let saved = average - spending
            let rate = Int((saved / average * 100).rounded())
            lines.append("Savings rate: \(rate)%\(saved < 0 ? " (negative: spending is higher than income)" : ""). Income averaged \(Self.money(average)) a month against \(Self.money(spending)) spent, "
                + (saved >= 0 ? "so about \(Self.money(saved)) a month was saved." : "so about \(Self.money(-saved)) a month more was spent than earned."))
        } else {
            lines.append("No income deposits were found in the checking or savings accounts, so a savings rate can't be worked out.")
        }
        lines.append("Average monthly spending splits into essentials \(Self.money(essential / n)), discretionary \(Self.money(discretionary / n)) and other \(Self.money(other / n)) (other includes irregular items like home improvement). Transfers and card payments aren't counted.")
        lines.append("Recurring bills and subscriptions come to about \(Self.money(store.recurring.reduce(0) { $0 + $1.monthlyCost })) a month.")
        lines.append("Cutting discretionary spending by 10% would save about \(Self.money(discretionary / n * 0.1)) a month; by 20%, \(Self.money(discretionary / n * 0.2)).")
        let usual = store.usualSpending(.month, interval: Period.month.interval(offset: 0, from: store.referenceDate), isCurrent: true)
        lines.append("Separately, this month so far: \(Self.money(thisMonth))" + (usual.map { ", where usually about \(Self.money($0)) is spent by now." } ?? "."))
        if let note = historyNote(window) { lines.append(note) }
        return lines.joined(separator: "\n")
    }

    // MARK: Subscriptions

    private func subscriptions() -> String {
        let items = store.recurring.sorted { $0.monthlyCost > $1.monthlyCost }
        guard !items.isEmpty else { return "No recurring charges were found." }
        let total = items.reduce(0) { $0 + $1.monthlyCost }
        var lines = ["\(items.count) recurring charges cost about \(Self.money(total)) a month (\(Self.money(total * 12)) a year)."]
        lines.append("Most expensive first: " + items.prefix(6).map { item in
            let kind = item.sample.nature == .essential ? "essential" : "non-essential"
            let up = (item.change ?? 0) > 0 ? ", price just rose" : ""
            return "\(item.name) \(Self.money(item.monthlyCost)) a month (\(Self.money(item.monthlyCost * 12)) a year, \(kind)\(up))"
        }.joined(separator: "; ") + ".")
        let optional = items.filter { $0.sample.nature != .essential }
        if let first = optional.first {
            lines.append("Best candidate to cancel: \(first.name), the most expensive non-essential one. Cancelling all non-essential ones would save \(Self.money(optional.reduce(0) { $0 + $1.monthlyCost })) a month.")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: Focus on one thing

    private static func plain(_ text: String) -> String {
        text.lowercased().replacingOccurrences(of: "&", with: "and").filter { $0.isLetter || $0.isNumber }
    }

    /// Words people use for a group of merchants rather than a category Plaid has.
    private static let merchantGroups: [String: [String]] = [
        "delivery": ["doordash", "ubereats", "grubhub", "postmates", "seamless", "caviar", "instacart", "gopuff"],
        "takeout": ["doordash", "ubereats", "grubhub", "postmates", "seamless", "caviar"],
        "rideshare": ["uber", "lyft"],
        "streaming": ["netflix", "hulu", "spotify", "disney", "hbo", "youtube", "appletv", "peacock", "paramount"],
        "subscription": [],
    ]

    /// One merchant or kind of spending over the months: how much, how it's moving, and how it compares with the rest.
    private func focus(_ subject: String?) -> String {
        guard let raw = subject?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return "Name a merchant or kind of spending to look at, such as DoorDash, coffee or groceries."
        }
        let needle = Self.plain(raw)
        var terms = [needle]
        for (word, merchants) in Self.merchantGroups where needle.contains(word) { terms += merchants }
        let window = store.monthWindow(maxMonths: 6)
        let completeKeys = window.complete.map(monthKey)
        let currentKey = monthKey(window.current)
        let all = store.countedPurchases(from: window.first)
        let matches = all.filter { p in
            let merchant = Self.plain(p.merchant)
            let category = Self.plain(categoryName(p.txn))
            let detailed = Self.plain(p.txn.personalFinanceCategory?.detailed ?? "")
            return terms.contains { merchant.contains($0) } || category.contains(needle) || detailed.contains(needle)
        }
        guard !matches.isEmpty else { return "No counted spending matching \"\(raw)\" was found in the available history." }

        var months: [Int: Double] = [:]
        var merchants: [String: Double] = [:]
        for p in matches {
            months[monthKey(p.date), default: 0] += p.txn.amount
            merchants[p.merchant, default: 0] += p.txn.amount
        }
        let values = completeKeys.map { months[$0] ?? 0 }
        let thisMonth = months[currentKey] ?? 0
        let totalAll = all.filter { completeKeys.contains(monthKey($0.date)) }.reduce(0) { $0 + $1.txn.amount }
        var lines: [String] = []
        if values.isEmpty {
            lines.append("\(raw): \(Self.money(thisMonth)) so far this month. There isn't a full month of history yet to compare against.")
        } else {
            let average = values.reduce(0, +) / Double(values.count)
            lines.append("\(raw): averages \(Self.money(average)) a month over \(span(window)), about \(Int((average / max(totalAll / Double(values.count), 1) * 100).rounded()))% of all spending.")
            let monthly = (window.complete + [window.current]).map { date in
                "\(monthName(date)) \(Self.compact(months[monthKey(date)] ?? 0))\(monthKey(date) == currentKey ? " so far" : "")"
            }
            lines.append("By month: " + monthly.joined(separator: ", ") + ".")
            let trend = direction(values)
            if !trend.isEmpty { lines.append("Trend: \(trend).") }
            let paceNote = thisMonth > average ? "already above its monthly average" : "below its monthly average so far"
            lines.append("This month so far \(Self.money(thisMonth)), \(paceNote) of \(Self.money(average)).")
        }
        let top = merchants.sorted { $0.value > $1.value }.prefix(3)
        if top.count > 1 || (top.first.map { Self.plain($0.key) != needle } ?? false) {
            lines.append("Biggest merchants: " + top.map { "\($0.key) \(Self.money($0.value))" }.joined(separator: "; ") + " over the whole period.")
        }
        if let note = historyNote(window) { lines.append(note) }
        return lines.joined(separator: "\n")
    }

    /// The first number in the question, like the 200 in "where can I cut $200 a month?".
    func numberInQuestion() -> Double? {
        guard let number = try? Regex(#"\d[\d,]*(?:\.\d+)?"#), let match = currentQuestion.firstMatch(of: number) else { return nil }
        return Double(String(currentQuestion[match.range]).replacingOccurrences(of: ",", with: ""))
    }
}
