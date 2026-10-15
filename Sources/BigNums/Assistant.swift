import FoundationModels
import Observation
import SwiftUI

/// Whether this Mac can run the assistant. It runs on Apple's on-device model, so it needs macOS 26 and Apple Intelligence.
enum AssistantStatus {
    case available
    case needsAppleIntelligence  // eligible Mac, but Apple Intelligence is switched off
    case modelNotReady  // still downloading
    case notSupported  // older macOS, or hardware without Apple Intelligence
}

@MainActor
enum AssistantSupport {
    static var status: AssistantStatus {
        guard #available(macOS 26.0, *) else { return .notSupported }
        switch SystemLanguageModel.default.availability {
        case .available: return .available
        case .unavailable(.appleIntelligenceNotEnabled): return .needsAppleIntelligence
        case .unavailable(.modelNotReady): return .modelNotReady
        case .unavailable: return .notSupported
        }
    }
}

/// Keeps one conversation alive for the life of the app. Typed loosely so callers don't need a macOS 26 availability check.
@MainActor
enum AssistantProvider {
    private static var instance: AnyObject?

    @available(macOS 26.0, *)
    static func assistant(for store: Store) -> Assistant {
        if let existing = instance as? Assistant { return existing }
        let created = Assistant(store: store)
        instance = created
        return created
    }
}

/// A conversation with Apple's on-device model, which looks things up in BigNums through tools. The model only
/// interprets the question and phrases the answer: every amount, date and list comes back from the data itself.
@available(macOS 26.0, *)
@MainActor @Observable
final class Assistant {
    struct Turn: Identifiable {
        let id = UUID()
        let question: String
        var answer = ""
        var failed = false
        var followUps: [String] = []  // suggested next questions, shown under the latest answer
    }

    private(set) var turns: [Turn] = []
    private(set) var isResponding = false
    private(set) var activity: String?  // what it's doing right now, e.g. "Checking your spending…"

    let store: Store
    @ObservationIgnored private var session: LanguageModelSession?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var toolsUsed: [String] = []

    init(store: Store) { self.store = store }

    /// Starts answering without blocking the caller, so it can be stopped.
    func send(_ question: String) {
        guard !isResponding else { return }
        task = Task { await ask(question) }
    }

    func stop() { task?.cancel() }

    /// Asks the last question again, replacing its answer.
    func retry() {
        guard !isResponding, let last = turns.last else { return }
        turns.removeLast()
        send(last.question)
    }

    func noteTool(_ name: String) { toolsUsed.append(name) }

    func reset() {
        guard !isResponding else { return }
        turns = []
        session = nil
    }

    func setActivity(_ text: String) {
        if isResponding { activity = text }
    }

    func ask(_ question: String) async {
        let question = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !isResponding else { return }
        turns.append(Turn(question: question))
        let index = turns.count - 1
        isResponding = true
        activity = "Thinking…"
        toolsUsed = []
        defer {
            isResponding = false
            activity = nil
        }
        do {
            try await respond(to: question, turn: index)
            if !turns[index].answer.isEmpty { turns[index].followUps = Self.followUps(after: toolsUsed) }
        } catch is CancellationError {
            // Stopped by the user: keep whatever had streamed in, or drop an empty turn.
            if turns[index].answer.isEmpty { turns.remove(at: index) }
        } catch LanguageModelSession.GenerationError.exceededContextWindowSize {
            // The model's window is small (about 8K tokens), so a long chat eventually fills it: carry on fresh.
            session = nil
            do { try await respond(to: question, turn: index) } catch { fail(index, error) }
        } catch {
            fail(index, error)
        }
    }

    private func respond(to question: String, turn index: Int) async throws {
        let session = self.session ?? makeSession()
        self.session = session
        turns[index].answer = ""
        for try await snapshot in session.streamResponse(to: question, options: GenerationOptions(temperature: 0.2)) {
            turns[index].answer = snapshot.content
            if !snapshot.content.isEmpty { activity = nil }
        }
    }

    /// Natural next questions, chosen by what was just looked up. They're sent into the same chat, so "that" has context.
    private static func followUps(after tools: [String]) -> [String] {
        switch tools.last {
        case "spending": ["Break that down by merchant", "How does that compare to last month?"]
        case "balances": ["Which card has the highest balance?", "How has my net worth changed?"]
        case "recurring": ["Did any of these go up in price?", "What's due in the next 7 days?"]
        case "usualSpending": ["Why is it different from usual?"]
        case "whatChanged": ["Break that down by category", "What was my biggest purchase this month?"]
        default: []
        }
    }

    private func fail(_ index: Int, _ error: Error) {
        turns[index].failed = true
        switch error {
        case LanguageModelSession.GenerationError.guardrailViolation:
            turns[index].answer = "I can't help with that one. Try asking about your spending, bills or balances."
        default:
            turns[index].answer = "Sorry, that didn't work: \(error.localizedDescription)"
        }
    }

    private func makeSession() -> LanguageModelSession {
        let today = Date().formatted(.dateTime.weekday(.wide).month(.wide).day().year())
        let instructions = """
        You are the assistant inside BigNums, a personal finance app that lives in the menu bar. Today is \(today). \
        All amounts are US dollars.

        You answer questions about the user's own spending, bills, balances and net worth, using only your tools.

        Rules:
        - Call a tool for every amount, date or list. Never guess, estimate or do arithmetic yourself. If you need a \
        total or a difference, call a tool again, or use a figure a tool already returned.
        - If the user gives no time range, use thisMonth, and say that you did. Words like "total", "ever", "overall" or \
        "all time" mean allTime.
        - Only state facts that appear in a tool's result. If something isn't in the result, such as a credit limit, say \
        you don't have that information. Never fill gaps with assumptions.
        - Quote the tool's figures exactly, and mention the time range you used.
        - When you name merchants, categories or accounts, include their amounts.
        - Answer in one to three short sentences, or a short list. Plain text only: no markdown, no headings.
        - If a tool finds nothing, say so plainly.
        - If the question isn't about the user's money, say you can only help with their finances.
        """
        let tools: [any Tool] = [SpendingTool(assistant: self), BalancesTool(assistant: self),
                                 RecurringTool(assistant: self), UsualSpendingTool(assistant: self), ChangesTool(assistant: self)]
        return LanguageModelSession(model: .default, tools: tools, instructions: instructions)
    }
}

// MARK: - Tools

@available(macOS 26.0, *)
@Generable
enum AssistantPeriod: String {
    case today, yesterday, thisWeek, lastWeek, thisMonth, lastMonth, last30Days, thisYear, allTime
}

@available(macOS 26.0, *)
@Generable
enum AssistantGroup: String {
    case merchant, category, card, day, month
}

@available(macOS 26.0, *)
@Generable
struct SpendingArguments {
    @Guide(description: "The time range. Use allTime when the user says total, ever, overall or all time. Use thisMonth if they gave no time range.")
    var period: AssistantPeriod
    @Guide(description: "Only this merchant, for example DoorDash. Leave empty for all merchants.")
    var merchant: String?
    @Guide(description: "Only this category, for example Food & drink, Transportation or General merchandise. Leave empty for all.")
    var category: String?
    @Guide(description: "Only this card or account, matched by its name or last four digits. Leave empty for all.")
    var account: String?
    @Guide(description: "Break the total down by merchant, category, card, day or month. Leave empty for just the total.")
    var groupBy: AssistantGroup?
    @Guide(description: "Exact start date as yyyy-MM-dd. Only for a custom range the periods can't express; overrides period.")
    var from: String?
    @Guide(description: "Exact end date as yyyy-MM-dd, inclusive. Use together with from.")
    var to: String?
}

@available(macOS 26.0, *)
struct SpendingTool: Tool {
    let assistant: Assistant
    let name = "spending"
    let description = """
        Looks up how much the user spent. Filter by time range, merchant, category or card, and optionally break the total \
        down by merchant, category, card, day or month. Also lists the largest purchases. Use it for any question about \
        spending, purchases or what something cost.
        """

    func call(arguments: SpendingArguments) async throws -> String {
        await assistant.noteTool("spending")
        await assistant.setActivity("Checking your spending…")
        return await assistant.spending(arguments)
    }
}

@available(macOS 26.0, *)
struct BalancesTool: Tool {
    let assistant: Assistant
    let name = "balances"
    let description = "Looks up net worth and every account's current balance: cash, investments, credit card balances and loans."

    @Generable struct Arguments {
        @Guide(description: "Leave empty.") var unused: String?
    }

    func call(arguments: Arguments) async throws -> String {
        await assistant.noteTool("balances")
        await assistant.setActivity("Checking your balances…")
        return await assistant.balances()
    }
}

@available(macOS 26.0, *)
struct RecurringTool: Tool {
    let assistant: Assistant
    let name = "recurring"
    let description = "Lists recurring charges: subscriptions and bills, how much each costs, and when each is due next."

    @Generable struct Arguments {
        @Guide(description: "Only charges due within this many days from today: 7 for \"this week\", 30 for \"this month\". Leave empty for all.")
        var dueWithinDays: Int?
    }

    func call(arguments: Arguments) async throws -> String {
        await assistant.noteTool("recurring")
        await assistant.setActivity("Checking your bills…")
        return await assistant.recurring(dueWithinDays: arguments.dueWithinDays)
    }
}

@available(macOS 26.0, *)
struct UsualSpendingTool: Tool {
    let assistant: Assistant
    let name = "usualSpending"
    let description = """
        Compares what the user has spent so far today, this week or this month with what they usually spend by this point. \
        Use it for "am I spending more than usual?" questions.
        """

    @Generable struct Arguments {
        @Guide(description: "today, thisWeek or thisMonth.") var period: AssistantPeriod
    }

    func call(arguments: Arguments) async throws -> String {
        await assistant.noteTool("usualSpending")
        await assistant.setActivity("Comparing with your usual…")
        return await assistant.usual(arguments.period)
    }
}

@available(macOS 26.0, *)
struct ChangesTool: Tool {
    let assistant: Assistant
    let name = "whatChanged"
    let description = """
        Explains how spending changed compared with the period before: both totals, and the merchants or categories that \
        rose or fell the most. Use it for "why is my spending up or down?" and "what changed since last month?".
        """

    @Generable struct Arguments {
        @Guide(description: "The period to explain: today, thisWeek, thisMonth, lastWeek or lastMonth.") var period: AssistantPeriod
        @Guide(description: "Compare by merchant or category. Use merchant unless the user asks about categories.") var groupBy: AssistantGroup?
    }

    func call(arguments: Arguments) async throws -> String {
        await assistant.noteTool("whatChanged")
        await assistant.setActivity("Comparing periods…")
        return await assistant.changes(arguments.period, groupBy: arguments.groupBy)
    }
}

// MARK: - Answers from the data

@available(macOS 26.0, *)
extension Assistant {
    private static func money(_ value: Double) -> String { value.formatted(.currency(code: "USD")) }

    private static let dayParser: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// The date range for a named period, and how to describe it.
    private func range(for period: AssistantPeriod) -> (interval: DateInterval, label: String) {
        let cal = Calendar.current
        let now = store.referenceDate
        func span(_ p: Period, _ offset: Int) -> DateInterval { p.interval(offset: offset, from: now) }
        func label(_ interval: DateInterval) -> String {
            let last = interval.end.addingTimeInterval(-1)
            let f = Date.FormatStyle.dateTime.month(.abbreviated).day()
            return cal.isDate(interval.start, inSameDayAs: last) ? interval.start.formatted(f) : "\(interval.start.formatted(f)) to \(last.formatted(f))"
        }
        switch period {
        case .today: let i = span(.day, 0); return (i, "today (\(label(i)))")
        case .yesterday: let i = span(.day, -1); return (i, "yesterday (\(label(i)))")
        case .thisWeek: let i = span(.week, 0); return (i, "this week (\(label(i)))")
        case .lastWeek: let i = span(.week, -1); return (i, "last week (\(label(i)))")
        case .thisMonth: let i = span(.month, 0); return (i, "this month (\(label(i)))")
        case .lastMonth: let i = span(.month, -1); return (i, "last month (\(label(i)))")
        case .last30Days:
            let end = span(.day, 0).end
            let i = DateInterval(start: cal.date(byAdding: .day, value: -30, to: end) ?? end, end: end)
            return (i, "the last 30 days (\(label(i)))")
        case .thisYear:
            let i = cal.dateInterval(of: .year, for: now) ?? span(.month, 0)
            return (i, "this year (since \(i.start.formatted(.dateTime.month(.abbreviated).day())))")
        case .allTime: return (DateInterval(start: .distantPast, end: .distantFuture), "all the history available")
        }
    }

    func spending(_ args: SpendingArguments) -> String {
        var (interval, label) = range(for: args.period)
        if let from = args.from.flatMap(Self.dayParser.date(from:)) {
            let to = args.to.flatMap(Self.dayParser.date(from:)) ?? from
            interval = DateInterval(start: from, end: max(Calendar.current.date(byAdding: .day, value: 1, to: to) ?? to, from))
            label = "\(from.formatted(.dateTime.month(.abbreviated).day().year())) to \(to.formatted(.dateTime.month(.abbreviated).day().year()))"
        }
        func clean(_ text: String?) -> String? {
            guard let text = text?.trimmingCharacters(in: .whitespaces), !text.isEmpty else { return nil }
            return text
        }
        let query = SpendingQuery(interval: interval, merchant: clean(args.merchant), category: clean(args.category), account: clean(args.account))
        let group: SpendingGroup = switch args.groupBy {
        case .merchant: .merchant
        case .category: .category
        case .card: .card
        case .day: .day
        case .month: .month
        case nil: .none
        }
        let summary = store.spendingSummary(query, groupBy: group, limit: group == .day || group == .month ? 14 : 8)

        let filters = [query.merchant, query.category, query.account].compactMap { $0 }.joined(separator: ", ")
        var lines = ["Spent \(Self.money(summary.total)) across \(summary.count) purchase\(summary.count == 1 ? "" : "s") in \(label)"
            + (filters.isEmpty ? "." : " (\(filters)).")]
        if !summary.groups.isEmpty {
            let name = args.groupBy.map { "\($0)".capitalized } ?? ""
            lines.append("By \(name.lowercased()): " + summary.groups.map { "\($0.name) \(Self.money($0.total)) (\($0.count))" }.joined(separator: "; ") + ".")
        }
        if !summary.largest.isEmpty {
            let accounts = store.accountsByID
            lines.append("Largest: " + summary.largest.prefix(5).map { txn in
                let card = txn.accountId.flatMap { accounts[$0] }.map { " on \($0.shortName)" } ?? ""
                return "\(store.displayDate(txn)) \(txn.merchant) \(Self.money(txn.amount))\(card)"
            }.joined(separator: "; ") + ".")
        }
        if summary.notCounted >= 1 {
            lines.append("Not included: \(Self.money(summary.notCounted)) more at merchants the user has set aside, which the app doesn't count.")
        }
        return lines.joined(separator: "\n")
    }

    func balances() -> String {
        guard let worth = store.netWorth, worth.hasBalances else { return "No balances are available yet. They arrive with the next update." }
        func list(_ lines: [Store.NetWorth.Line]) -> String {
            lines.map { line in
                var text = "\(line.account.displayName) \(Self.money(line.balance ?? 0))"
                if line.account.type == "credit" {
                    if let limit = line.account.balances?.limit, limit > 0, let owed = line.balance {
                        text += " (\((owed / limit).formatted(.percent.precision(.fractionLength(0)))) of its \(Self.money(limit)) limit)"
                    } else {
                        text += " (no credit limit reported by the bank)"
                    }
                }
                return text
            }.joined(separator: "; ")
        }
        var lines = ["Net worth \(Self.money(worth.total)): assets \(Self.money(worth.assetsTotal)) minus debts \(Self.money(worth.debtsTotal))."]
        if !worth.assets.isEmpty { lines.append("Assets: " + list(worth.assets) + ".") }
        if !worth.debts.isEmpty { lines.append("Owed: " + list(worth.debts) + ".") }
        if let change = store.netWorthChange(), abs(change.amount) >= 1 {
            lines.append("Net worth \(change.amount > 0 ? "rose" : "fell") \(Self.money(abs(change.amount))) since \(change.since.formatted(.dateTime.month(.abbreviated).day())).")
        }
        return lines.joined(separator: "\n")
    }

    func recurring(dueWithinDays: Int?) -> String {
        let cal = Calendar.current
        let today = cal.startOfDay(for: store.referenceDate)
        var items = store.recurring
        if let days = dueWithinDays, let end = cal.date(byAdding: .day, value: max(days, 0) + 1, to: today) {
            items = items.filter { $0.next < end }
        }
        guard !items.isEmpty else { return dueWithinDays == nil ? "No recurring charges found." : "Nothing recurring is due in that time." }
        let accounts = store.accountsByID
        let monthly = store.recurring.reduce(0) { $0 + $1.monthlyCost }
        let list = items.prefix(12).map { item -> String in
            let card = item.sample.accountId.flatMap { accounts[$0] }.map { " on \($0.shortName)" } ?? ""
            let change = item.change.map { $0 > 0 ? ", up \(Self.money($0)) from before" : ", down \(Self.money(-$0))" } ?? ""
            return "\(item.name) \(Self.money(item.amount)) \(item.cadence.label.lowercased()), next \(item.next.formatted(.dateTime.month(.abbreviated).day()))\(card)\(change)"
        }
        return "Recurring charges cost about \(Self.money(monthly)) a month in total.\n" + (dueWithinDays == nil ? "" : "Due soon: ") + list.joined(separator: "; ") + "."
    }

    func usual(_ period: AssistantPeriod) -> String {
        let p: Period = switch period {
        case .today, .yesterday: .day
        case .thisWeek, .lastWeek: .week
        default: .month
        }
        let interval = p.interval(offset: 0, from: store.referenceDate)
        let spent = store.breakdown(interval).total
        guard let usual = store.usualSpending(p, interval: interval, isCurrent: true) else {
            return "Spent \(Self.money(spent)) so far this \(p == .day ? "day" : p == .week ? "week" : "month"). There isn't enough history yet to say what's usual."
        }
        let difference = spent - usual
        let unit = p == .day ? "today" : p == .week ? "this week" : "this month"
        return "Spent \(Self.money(spent)) \(unit) so far. Usually about \(Self.money(usual)) by this point, so \(Self.money(abs(difference))) \(difference > 0 ? "over" : "under") usual."
    }

    /// This period against the one before it. A period still in progress is compared with the same stretch of the
    /// previous one, so "this month so far" isn't set against a whole finished month.
    func changes(_ period: AssistantPeriod, groupBy: AssistantGroup?) -> String {
        let p: Period
        let offset: Int
        switch period {
        case .today: (p, offset) = (.day, 0)
        case .yesterday: (p, offset) = (.day, -1)
        case .thisWeek: (p, offset) = (.week, 0)
        case .lastWeek: (p, offset) = (.week, -1)
        case .lastMonth: (p, offset) = (.month, -1)
        default: (p, offset) = (.month, 0)
        }
        let cal = Calendar.current
        let now = store.referenceDate
        let current = p.interval(offset: offset, from: now)
        var previous = p.interval(offset: offset - 1, from: now)
        var sameStretch = false
        if offset == 0 {
            let elapsed = (cal.dateComponents([.day], from: current.start, to: cal.startOfDay(for: now)).day ?? 0) + 1
            if let cut = cal.date(byAdding: .day, value: elapsed, to: previous.start) {
                previous = DateInterval(start: previous.start, end: min(cut, previous.end))
                sameStretch = true
            }
        }
        let group: SpendingGroup = groupBy == .category ? .category : .merchant
        let recent = store.spendingSummary(SpendingQuery(interval: current), groupBy: group, limit: 500)
        let earlier = store.spendingSummary(SpendingQuery(interval: previous), groupBy: group, limit: 500)
        var net: [String: (now: Double, before: Double)] = [:]
        for g in recent.groups { net[g.name, default: (0, 0)].now = g.total }
        for g in earlier.groups { net[g.name, default: (0, 0)].before = g.total }
        let changes = net.map { (name: $0.key, delta: $0.value.now - $0.value.before, now: $0.value.now) }
        func line(_ c: (name: String, delta: Double, now: Double)) -> String {
            "\(c.name) \(c.delta > 0 ? "+" : "-")\(Self.money(abs(c.delta))) (now \(Self.money(c.now)))"
        }
        let up = changes.filter { $0.delta >= 1 }.sorted { $0.delta > $1.delta }.prefix(4)
        let down = changes.filter { $0.delta <= -1 }.sorted { $0.delta < $1.delta }.prefix(3)

        let label = p == .day ? "day" : p == .week ? "week" : "month"
        let difference = recent.total - earlier.total
        var lines = ["Spent \(Self.money(recent.total)) in the current \(label)\(sameStretch ? " so far" : ""), versus \(Self.money(earlier.total)) "
            + (sameStretch ? "over the same days of the previous \(label)" : "in the previous \(label)")
            + ": \(Self.money(abs(difference))) \(difference >= 0 ? "more" : "less")."]
        if !up.isEmpty { lines.append("Biggest increases: " + up.map(line).joined(separator: "; ") + ".") }
        if !down.isEmpty { lines.append("Biggest decreases: " + down.map(line).joined(separator: "; ") + ".") }
        return lines.joined(separator: "\n")
    }
}
