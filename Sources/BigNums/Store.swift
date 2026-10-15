import AppKit
import Foundation
import Observation
import UserNotifications

struct Connection: Codable, Identifiable {
    let id: String  // Plaid item_id
    let accessToken: String
    var institution: String
    var cursor: String?
    var accounts: [Account]?
    var transactions: [String: Transaction] = [:]
    var lastSynced: Date?
    var error: String?
    var errorCode: String?
    var website: String?
    var logo: String?  // base64 PNG from Plaid
    var institutionFetched: Bool?
    var siteIconFetched: Bool?

    var websiteURL: URL? {
        guard let website, !website.isEmpty else { return nil }
        return URL(string: website.contains("://") ? website : "https://\(website)")
    }

    /// Errors only the user can fix by logging in to the bank again through Plaid.
    var needsReconnect: Bool {
        ["ITEM_LOGIN_REQUIRED", "PENDING_EXPIRATION", "PENDING_DISCONNECT", "INVALID_CREDENTIALS", "INVALID_MFA",
         "USER_SETUP_REQUIRED", "ACCESS_NOT_GRANTED", "NO_ACCOUNTS"].contains(errorCode ?? "")
    }
}

enum Period: String, CaseIterable, Identifiable {
    case day = "Day", week = "Week", month = "Month"

    var id: Self { self }

    var component: Calendar.Component {
        switch self {
        case .day: .day
        case .week: .weekOfYear
        case .month: .month
        }
    }

    /// The calendar day/week/month `offset` periods away from the one containing `date` (0 = current, -1 = previous).
    func interval(offset: Int, from date: Date) -> DateInterval {
        let cal = Calendar.current
        let shifted = cal.date(byAdding: component, value: offset, to: date) ?? date
        return cal.dateInterval(of: component, for: shifted) ?? DateInterval(start: shifted, duration: 86400)
    }
}

/// Counted spending inside one date range.
struct Breakdown {
    var total = 0.0
    var byAccount: [String: Double] = [:]  // includes excluded accounts, so their rows still show a number
    var purchases: [Transaction] = []  // biggest first; excluded accounts left out
    var uncounted: [String: Double] = [:]  // spending by merchants that aren't counted, in this range only
}

struct MerchantTotal: Identifiable {
    let name: String
    var total: Double
    var count: Int
    let sample: Transaction  // supplies the logo and category icon
    var id: String { name.lowercased() }

    /// Purchases grouped by merchant, biggest total first.
    static func top(_ purchases: [Transaction], limit: Int) -> [MerchantTotal] {
        var groups: [String: MerchantTotal] = [:]
        for txn in purchases {
            let key = txn.merchant.lowercased()
            groups[key, default: MerchantTotal(name: txn.merchant, total: 0, count: 0, sample: txn)].total += txn.amount
            groups[key]!.count += 1
        }
        return Array(groups.values.sorted { $0.total > $1.total }.prefix(limit))
    }
}

/// A charge that repeats on a steady schedule: a subscription or a bill.
struct Recurring: Identifiable {
    enum Cadence: CaseIterable {
        case weekly, biweekly, monthly

        /// Gaps between charges, in days, that count as this cadence (billing dates drift a few days).
        var days: ClosedRange<Int> {
            switch self {
            case .weekly: 6...8
            case .biweekly: 13...16
            case .monthly: 26...35
            }
        }

        var label: String {
            switch self {
            case .weekly: "Weekly"
            case .biweekly: "Every 2 weeks"
            case .monthly: "Monthly"
            }
        }

        func advance(_ date: Date) -> Date {
            let cal = Calendar.current
            switch self {
            case .weekly: return cal.date(byAdding: .day, value: 7, to: date) ?? date
            case .biweekly: return cal.date(byAdding: .day, value: 14, to: date) ?? date
            case .monthly: return cal.date(byAdding: .month, value: 1, to: date) ?? date
            }
        }
    }

    let name: String
    let amount: Double  // latest charge
    let cadence: Cadence
    let next: Date
    let change: Double?  // latest charge minus the one before, when the price moved
    let sample: Transaction  // supplies the logo and category icon
    var id: String { "\(name.lowercased())-\(amount)" }

    var monthlyCost: Double {
        switch cadence {
        case .weekly: amount * 52 / 12
        case .biweekly: amount * 26 / 12
        case .monthly: amount
        }
    }
}

extension Transaction {
    /// The name purchases are grouped and hidden by.
    var merchant: String { merchantName ?? name ?? "Other" }
}

@MainActor @Observable
final class Store {
    private(set) var connections: [Connection] = [] {
        didSet { indexCache = nil; generation &+= 1 }
    }
    /// Bumped whenever something the derived data depends on changes, so cached results know they're stale.
    private var generation = 0
    private(set) var isLinking = false
    private(set) var isRefreshing = false
    private(set) var lastRefresh: Date? {
        didSet { generation &+= 1 }
    }
    var message: String?
    /// Account IDs left out of the totals. Stored in UserDefaults.
    private(set) var excludedAccounts: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "excludedAccounts") ?? []) {
        didSet { UserDefaults.standard.set(Array(excludedAccounts), forKey: "excludedAccounts"); generation &+= 1 }
    }
    /// Merchants left out of spending totals (e.g. rent, which dwarfs everything else). They still appear in
    /// Recurring, since you still pay them. Stored in UserDefaults.
    private(set) var hiddenMerchants: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "hiddenMerchants") ?? []) {
        didSet { UserDefaults.standard.set(Array(hiddenMerchants), forKey: "hiddenMerchants") }
    }
    private var hiddenKeys: Set<String> { Set(hiddenMerchants.map { $0.lowercased() }) }
    /// Merchants the user said aren't recurring charges (a false match). Only affects Recurring. Stored in UserDefaults.
    private(set) var dismissedRecurring: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "dismissedRecurring") ?? []) {
        didSet { UserDefaults.standard.set(Array(dismissedRecurring), forKey: "dismissedRecurring"); generation &+= 1 }
    }

    /// Menu bar shows a placeholder instead of the amounts (for screen sharing, or just privacy). Stored in UserDefaults.
    var hideNumbers = UserDefaults.standard.bool(forKey: "hideNumbers") {
        didSet { UserDefaults.standard.set(hideNumbers, forKey: "hideNumbers") }
    }

    /// macOS notification for each new charge made today. Stored in UserDefaults; on unless turned off.
    var notifyCharges = UserDefaults.standard.object(forKey: "notifyCharges") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(notifyCharges, forKey: "notifyCharges")
            if notifyCharges { Self.requestNotificationAccess() }
        }
    }

    private var plaid: Plaid?
    private var linkTask: Task<Void, Never>?
    private var timer: Timer?

    /// Transfers, card payments and income aren't spending (and would double-count checking -> credit card payments).
    private static let ignoredCategories: Set<String> = ["TRANSFER_IN", "TRANSFER_OUT", "LOAN_PAYMENTS", "INCOME"]

    private static let fileURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BigNums", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("connections.json")
    }()

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    var isConfigured: Bool { plaid != nil }

    /// `autoRefresh: false` skips network activity (used by the debug snapshot renderer).
    init(autoRefresh: Bool = true) {
        load()
        do { plaid = Plaid(config: try PlaidConfig.load()) } catch { message = error.localizedDescription }
        guard autoRefresh else { return }
        if notifyCharges { Self.requestNotificationAccess() }
        timer = Timer.scheduledTimer(withTimeInterval: 15 * 60, repeats: true) { [weak self] _ in
            Task { await self?.refresh() }
        }
        // Refresh after sleep so "today" doesn't show yesterday's numbers; wait a moment for the network to return.
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task {
                try? await Task.sleep(for: .seconds(10))
                await self?.refresh()
            }
        }
        Task { await refresh() }
    }

    // MARK: Totals

    /// "Now" for all period math. Moves forward on every refresh, which also rolls the day/week/month over.
    var referenceDate: Date { lastRefresh ?? Date() }

    /// Earliest day we hold any transaction for; bounds browsing back and comparisons.
    var historyStart: Date? {
        connections.flatMap(\.transactions.values).map(\.date).min().flatMap(Self.dayFormatter.date(from:))
    }

    /// One spending-relevant charge with its date already parsed, so period math never touches strings.
    private struct Entry {
        let date: Date
        let merchantKey: String  // lowercased merchant, as hiding and recurring match on it
        let txn: Transaction
    }

    /// Every charge that could count toward spending (money out, not a transfer or income), oldest first. Built once
    /// per change to the data; with thousands of transactions this keeps each period lookup to a binary search plus
    /// the handful of charges inside it.
    @ObservationIgnored private var indexCache: [Entry]?
    @ObservationIgnored private var dayCache: [String: Date] = [:]

    private var index: [Entry] {
        if let indexCache { return indexCache }
        var entries: [Entry] = []
        for connection in connections {
            for txn in connection.transactions.values where txn.amount > 0 {
                if let category = txn.personalFinanceCategory?.primary, Self.ignoredCategories.contains(category) { continue }
                let day = txn.authorizedDate ?? txn.date
                let date: Date
                if let cached = dayCache[day] {
                    date = cached
                } else if let parsed = Self.dayFormatter.date(from: day) {
                    dayCache[day] = parsed
                    date = parsed
                } else {
                    continue
                }
                entries.append(Entry(date: date, merchantKey: txn.merchant.lowercased(), txn: txn))
            }
        }
        entries.sort { $0.date < $1.date }
        indexCache = entries
        return entries
    }

    /// Position of the first entry dated at or after `date`.
    private func lowerBound(_ entries: [Entry], _ date: Date) -> Int {
        var low = 0, high = entries.count
        while low < high {
            let mid = (low + high) / 2
            if entries[mid].date < date { low = mid + 1 } else { high = mid }
        }
        return low
    }

    func breakdown(_ interval: DateInterval) -> Breakdown {
        let now = referenceDate
        let hidden = hiddenKeys
        let entries = index
        var result = Breakdown()
        var i = lowerBound(entries, interval.start)
        while i < entries.count, entries[i].date < interval.end, entries[i].date <= now {
            let txn = entries[i].txn
            let isHidden = hidden.contains(entries[i].merchantKey)
            i += 1
            if let accountID = txn.accountId {
                if !isHidden { result.byAccount[accountID, default: 0] += txn.amount }
                if excludedAccounts.contains(accountID) { continue }
            }
            if isHidden {
                result.uncounted[txn.merchant, default: 0] += txn.amount
                continue
            }
            result.total += txn.amount
            result.purchases.append(txn)
        }
        result.purchases.sort { $0.amount > $1.amount }
        return result
    }

    // MARK: Usual spending

    /// What you typically spend over the same stretch as `interval`, as the median of recent comparable periods, so a
    /// single odd month or one big charge doesn't skew it. For the current week/month that's the same point in the period
    /// ("by now"); for a finished one, the whole period; for a day, a whole day of the same weekday. Nil until there are
    /// at least 3 earlier periods of history to learn from.
    func usualSpending(_ period: Period, interval: DateInterval, isCurrent: Bool) -> Double? {
        guard let historyStart else { return nil }
        let cal = Calendar.current
        var totals: [Double] = []
        let count = period == .month ? 6 : 8
        let elapsedDays = (cal.dateComponents([.day], from: interval.start, to: cal.startOfDay(for: referenceDate)).day ?? 0) + 1
        for k in 1...count {
            let past: DateInterval
            if period == .day {
                guard let start = cal.date(byAdding: .day, value: -7 * k, to: interval.start),
                      let end = cal.date(byAdding: .day, value: 1, to: start) else { continue }
                past = DateInterval(start: start, end: end)
            } else {
                past = period.interval(offset: -k, from: interval.start)
            }
            guard past.start >= historyStart else { break }
            var end = past.end
            if isCurrent, period != .day, let cut = cal.date(byAdding: .day, value: elapsedDays, to: past.start) { end = min(cut, past.end) }
            totals.append(breakdown(DateInterval(start: past.start, end: end)).total)
        }
        guard totals.count >= 3 else { return nil }
        totals.sort()
        let mid = totals.count / 2
        return totals.count % 2 == 1 ? totals[mid] : (totals[mid - 1] + totals[mid]) / 2
    }

    func toggleExcluded(_ accountID: String) {
        if excludedAccounts.contains(accountID) { excludedAccounts.remove(accountID) } else { excludedAccounts.insert(accountID) }
    }

    func hide(_ merchant: String) { hiddenMerchants.insert(merchant) }
    func unhide(_ merchant: String) { hiddenMerchants = hiddenMerchants.filter { $0.lowercased() != merchant.lowercased() } }
    func isCounted(_ merchant: String) -> Bool { !hiddenKeys.contains(merchant.lowercased()) }

    func dismissRecurring(_ merchant: String) { dismissedRecurring.insert(merchant) }
    func restoreRecurring(_ merchant: String) { dismissedRecurring.remove(merchant) }
    func restoreAllRecurring() { dismissedRecurring.removeAll() }

    // MARK: Recurring

    /// "Name ••1234" for an account ID, so a charge can be traced to the card it hit.
    private func accountLabel(_ accountID: String?) -> String? {
        guard let accountID, let account = connections.lazy.compactMap({ $0.accounts?.first { $0.id == accountID } }).first else { return nil }
        return account.mask.map { "\(account.name) ••\($0)" } ?? account.name
    }

    /// Charges that repeat at a steady interval with a steady price, still active, soonest first.
    /// Includes merchants that aren't counted in totals (you still pay them); leaves out excluded accounts
    /// (not your money) and charges dismissed as not recurring.
    var recurring: [Recurring] {
        if let cached = recurringCache, cached.generation == generation { return cached.items }
        let items = computeRecurring()
        recurringCache = (generation, items)
        return items
    }

    @ObservationIgnored private var recurringCache: (generation: Int, items: [Recurring])?

    private func computeRecurring() -> [Recurring] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: referenceDate)
        let dismissed = Set(dismissedRecurring.map { $0.lowercased() })
        var byMerchant: [String: [(date: Date, txn: Transaction)]] = [:]
        for entry in index where entry.txn.pending != true {
            let txn = entry.txn
            if let accountID = txn.accountId, excludedAccounts.contains(accountID) { continue }
            guard !dismissed.contains(entry.merchantKey) else { continue }
            byMerchant[entry.merchantKey, default: []].append((entry.date, txn))
        }

        var result: [Recurring] = []
        for charges in byMerchant.values {
            // One merchant can bill several subscriptions (Apple: iCloud and Music), so split by similar amounts.
            var clusters: [[(date: Date, txn: Transaction)]] = []
            for charge in charges.sorted(by: { $0.txn.amount < $1.txn.amount }) {
                if let last = clusters.last?.last, charge.txn.amount <= last.txn.amount * 1.1 + 0.01 {
                    clusters[clusters.count - 1].append(charge)
                } else {
                    clusters.append([charge])
                }
            }
            for cluster in clusters where cluster.count >= 2 {
                let sorted = cluster.sorted { $0.date < $1.date }
                let gaps = zip(sorted, sorted.dropFirst()).map { cal.dateComponents([.day], from: $0.date, to: $1.date).day ?? 0 }
                guard let cadence = Recurring.Cadence.allCases.first(where: { c in gaps.allSatisfy(c.days.contains) }) else { continue }
                let amounts = sorted.map(\.txn.amount)
                // Two charges are thin evidence (two similar takeout orders a month apart): only trust exact monthly prices.
                if sorted.count == 2, cadence != .monthly || abs(amounts[0] - amounts[1]) > 0.01 * amounts[1] { continue }
                let last = sorted[sorted.count - 1]
                // Missed its slot by half a cycle or more: cancelled.
                let sinceLast = cal.dateComponents([.day], from: last.date, to: today).day ?? 0
                guard sinceLast <= cadence.days.upperBound * 3 / 2 else { continue }
                var next = cadence.advance(last.date)
                while next < today { next = cadence.advance(next) }
                let change = amounts[amounts.count - 1] - amounts[amounts.count - 2]
                result.append(Recurring(name: last.txn.merchant, amount: last.txn.amount, cadence: cadence, next: next,
                                        change: abs(change) >= 0.5 ? change : nil, sample: last.txn))
            }
        }
        return result.sorted { $0.next < $1.next }
    }

    /// Menu bar text: always the current day, week and month, whatever the menu is browsing.
    var label: String {
        if hideNumbers { return Period.allCases.map { _ in "$•••" }.joined(separator: " | ") }
        return Period.allCases
            .map { Self.compactMoney(breakdown($0.interval(offset: 0, from: referenceDate)).total) }
            .joined(separator: " | ")
    }

    /// "$987", "$3.2K", "$12.6K", "$126K": keeps the menu bar item narrow and roughly the same width all month,
    /// so macOS doesn't hide it behind the notch. The exact figure is in the menu.
    static func compactMoney(_ value: Double) -> String {
        let rounded = value.rounded()
        if rounded < 1000 { return "$\(Int(rounded))" }
        let (scaled, suffix) = rounded < 1_000_000 ? (rounded / 1000, "K") : (rounded / 1_000_000, "M")
        return "$" + scaled.formatted(.number.precision(.fractionLength(0...(scaled < 100 ? 1 : 0)))) + suffix
    }

    static func money(_ value: Double) -> String {
        value.formatted(.currency(code: "USD").precision(.fractionLength(0)))
    }

    // MARK: Refresh

    func refreshIfStale() async {
        if lastRefresh.map({ Date().timeIntervalSince($0) > 60 }) ?? true { await refresh() }
    }

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        for id in connections.map(\.id) { await sync(id) }
        isRefreshing = false
        lastRefresh = Date()  // also re-evaluates the day/week/month boundaries
    }

    private func sync(_ id: String) async {
        guard let plaid, let connection = connections.first(where: { $0.id == id }) else { return }
        do {
            let result = try await plaid.sync(accessToken: connection.accessToken, cursor: connection.cursor)
            guard let i = connections.firstIndex(where: { $0.id == id }) else { return }
            // The first sync loads history, which isn't news.
            if connection.cursor != nil { notifyNewCharges(result, existing: connections[i].transactions) }
            // Edit a copy and assign once: every write to `connections` invalidates the derived data.
            var transactions = connections[i].transactions
            for txn in result.added { transactions[txn.transactionId] = txn }
            for txnID in result.removed { transactions[txnID] = nil }
            if let accounts = result.accounts { connections[i].accounts = accounts }
            if !result.cursor.isEmpty { connections[i].cursor = result.cursor }  // empty = data not ready yet
            // Keep up to 2 years for browsing past periods (the most Plaid provides).
            let cutoff = Self.dayFormatter.string(from: Date().addingTimeInterval(-730 * 86400))
            connections[i].transactions = transactions.filter { $0.value.date >= cutoff }
            // Fetch the account list if we've never received one (or saved it before account types were stored).
            if connections[i].accounts.map({ $0.isEmpty || $0.contains { $0.type == nil } }) ?? true, let accounts = try? await plaid.accounts(accessToken: connection.accessToken),
               let i = connections.firstIndex(where: { $0.id == id }) {
                connections[i].accounts = accounts
            }
            // Website and logo only need fetching once per bank.
            if connections[i].institutionFetched != true, let info = try? await plaid.institution(accessToken: connection.accessToken),
               let i = connections.firstIndex(where: { $0.id == id }) {
                connections[i].website = info.url
                connections[i].logo = info.logo
                connections[i].institutionFetched = true
            }
            // Plaid has no logo for some banks (e.g. Chase, Wells Fargo): use the bank website's own icon instead.
            if let i = connections.firstIndex(where: { $0.id == id }), connections[i].logo == nil,
               connections[i].siteIconFetched != true, let site = connections[i].websiteURL {
                let icon = await Self.siteIcon(site)
                if let i = connections.firstIndex(where: { $0.id == id }) {
                    connections[i].logo = icon
                    connections[i].siteIconFetched = true
                }
            }
            guard let i = connections.firstIndex(where: { $0.id == id }) else { return }
            connections[i].lastSynced = Date()
            connections[i].error = nil
            connections[i].errorCode = nil
        } catch {
            if let i = connections.firstIndex(where: { $0.id == id }) {
                connections[i].error = error.localizedDescription
                connections[i].errorCode = (error as? PlaidError)?.code
            }
        }
        save()
    }

    // MARK: Notifications

    /// Notifies for charges from today that we haven't seen before. A pending charge that posts arrives as a new
    /// transaction while the pending one is removed, so a posted charge matching a removed one isn't new.
    private func notifyNewCharges(_ result: SyncResult, existing: [String: Transaction]) {
        guard notifyCharges else { return }
        let today = Self.dayFormatter.string(from: Date())
        let removed = result.removed.compactMap { existing[$0] }
        let hidden = hiddenKeys
        for txn in result.added where existing[txn.transactionId] == nil && txn.amount > 0 {
            guard (txn.authorizedDate ?? txn.date) == today else { continue }
            if let category = txn.personalFinanceCategory?.primary, Self.ignoredCategories.contains(category) { continue }
            if let accountID = txn.accountId, excludedAccounts.contains(accountID) { continue }
            if hidden.contains(txn.merchant.lowercased()) { continue }
            if txn.pending != true, removed.contains(where: { $0.accountId == txn.accountId && abs($0.amount - txn.amount) < 0.01 }) { continue }
            let amount = txn.amount.formatted(.currency(code: "USD"))
            let content = UNMutableNotificationContent()
            content.title = "\(amount) at \(txn.merchant)"
            content.body = [accountLabel(txn.accountId), txn.pending == true ? "Pending" : nil].compactMap { $0 }.joined(separator: " · ")
            content.sound = .default
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: txn.transactionId, content: content, trigger: nil))
        }
    }

    /// Notifications need a real app bundle, so this does nothing under `swift run`.
    private static func requestNotificationAccess() {
        guard Bundle.main.bundleIdentifier != nil else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// A bank website's own icon as base64 PNG. Prefers the largest icon its homepage declares (Wells Fargo's links
    /// a 192px icon on a separate CDN while its /favicon.ico is 16px), then the standard /apple-touch-icon.png and
    /// /favicon.ico locations.
    private static func siteIcon(_ site: URL) async -> String? {
        var candidates: [(url: URL, minSize: Int)] = []
        if let html = await fetch(site).flatMap({ String(data: $0, encoding: .utf8) }), let linkTag = try? Regex(#"<link[^>]+>"#) {
            let declared = html.matches(of: linkTag.ignoresCase())
                .map { String(html[$0.range]) }
                .filter { attribute("rel", in: $0)?.localizedCaseInsensitiveContains("icon") == true }
                .compactMap { tag -> (url: URL, size: Int)? in
                    guard let href = attribute("href", in: tag), let url = URL(string: href, relativeTo: site) else { return nil }
                    let size = attribute("sizes", in: tag).flatMap { Int($0.split(separator: "x").first ?? "") } ?? 0
                    return (url.absoluteURL, size)
                }
                .sorted { $0.size > $1.size }
            candidates += declared.map { ($0.url, 32) }
        }
        for (path, minSize) in [("/apple-touch-icon.png", 32), ("/favicon.ico", 16)] {
            if let url = URL(string: path, relativeTo: site) { candidates.append((url.absoluteURL, minSize)) }
        }

        for candidate in candidates {
            guard let data = await fetch(candidate.url),
                  let rep = NSImage(data: data)?.representations.max(by: { $0.pixelsWide < $1.pixelsWide }),
                  rep.pixelsWide >= candidate.minSize else { continue }
            let image = NSImage(size: NSSize(width: rep.pixelsWide, height: rep.pixelsHigh))
            image.addRepresentation(rep)
            if let tiff = image.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                return png.base64EncodedString()
            }
        }
        return nil
    }

    private static func fetch(_ url: URL) async -> Data? {
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.setValue("Mozilla/5.0 (Macintosh)", forHTTPHeaderField: "User-Agent")  // some bank sites reject unknown clients
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return data
    }

    /// Value of an HTML attribute in a single tag, e.g. `href` in `<link rel="icon" href="...">`.
    private static func attribute(_ name: String, in tag: String) -> String? {
        guard let regex = try? Regex(name + #"\s*=\s*["']([^"']*)["']"#).ignoresCase(),
              let match = tag.firstMatch(of: regex) else { return nil }
        return match.output[1].substring.map(String.init)
    }

    // MARK: Connections

    func addConnection() {
        runLink(updating: nil) { [weak self] results in
            for result in results { try await self?.finishLink(result) }
        }
    }

    /// Re-login to a bank via Plaid update mode. The access token doesn't change, so we just re-sync afterwards:
    /// if the user fixed the login, the error clears; if they bailed, it stays.
    func reconnect(_ id: String) {
        guard let connection = connections.first(where: { $0.id == id }) else { return }
        runLink(updating: connection.accessToken) { [weak self] _ in
            await self?.sync(id)
            self?.lastRefresh = Date()
        }
    }

    /// Opens Hosted Link in the browser and polls until the session finishes (or 30 minutes pass).
    private func runLink(updating accessToken: String?, onFinish: @escaping ([LinkResult]) async throws -> Void) {
        guard let plaid, !isLinking else { return }
        isLinking = true
        message = nil
        linkTask = Task {
            defer { isLinking = false }
            do {
                let link = try await plaid.createHostedLink(updating: accessToken)
                NSWorkspace.shared.open(link.url)
                let deadline = Date().addingTimeInterval(30 * 60)
                while Date() < deadline {
                    try await Task.sleep(for: .seconds(3))
                    let status = try await plaid.linkStatus(link.token)
                    if !status.results.isEmpty || status.finished {
                        try await onFinish(status.results)  // results is empty if the user exited without finishing
                        return
                    }
                }
            } catch is CancellationError {
            } catch {
                message = error.localizedDescription
            }
        }
    }

    func cancelLink() {
        linkTask?.cancel()
    }

    private func finishLink(_ result: LinkResult) async throws {
        guard let plaid else { return }
        let (accessToken, itemID) = try await plaid.exchange(result.publicToken)
        var name = result.institution
        if name == nil { name = try? await plaid.institution(accessToken: accessToken)?.name }
        connections.removeAll { $0.id == itemID }
        connections.append(Connection(id: itemID, accessToken: accessToken, institution: name ?? "Bank"))
        save()

        // Plaid needs a little time to pull initial transactions; retry briefly until a cursor arrives.
        Task {
            for _ in 0..<12 {
                await sync(itemID)
                lastRefresh = Date()
                if connections.first(where: { $0.id == itemID })?.cursor != nil { break }
                try? await Task.sleep(for: .seconds(10))
            }
        }
    }

    func remove(_ id: String) async {
        guard let connection = connections.first(where: { $0.id == id }) else { return }
        do {
            try await plaid?.removeItem(accessToken: connection.accessToken)
        } catch let e as PlaidError where ["ITEM_NOT_FOUND", "INVALID_ACCESS_TOKEN"].contains(e.code) {
            // Already gone on Plaid's side; just forget it locally.
        } catch {
            message = "Couldn't remove \(connection.institution): \(error.localizedDescription)"
            return
        }
        excludedAccounts.subtract(connection.accounts?.map(\.id) ?? [])
        connections.removeAll { $0.id == id }
        save()
    }

    // MARK: Persistence

    private func load() {
        guard let data = try? Data(contentsOf: Self.fileURL) else { return }
        connections = (try? JSONDecoder().decode([Connection].self, from: data)) ?? []
        // Caches from older versions lack account IDs or merchant names: drop them and re-sync from scratch once.
        for i in connections.indices where connections[i].accounts == nil
            || connections[i].transactions.values.contains(where: { $0.accountId == nil || $0.name == nil }) {
            connections[i].cursor = nil
            connections[i].transactions = [:]
        }
    }

    private static let saveQueue = DispatchQueue(label: "bignums.save", qos: .utility)

    /// Encoding every transaction is slow at scale, so it happens off the main thread on a snapshot of the data.
    private func save() {
        let snapshot = connections
        Self.saveQueue.async {
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            try? data.write(to: Self.fileURL, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: Self.fileURL.path)
        }
    }
}
