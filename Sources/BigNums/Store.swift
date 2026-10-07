import AppKit
import Foundation
import Observation

struct Connection: Codable, Identifiable {
    let id: String  // Plaid item_id
    let accessToken: String
    var institution: String
    var cursor: String?
    var transactions: [String: Transaction] = [:]
    var lastSynced: Date?
    var error: String?
}

struct Totals { var day = 0.0, week = 0.0, month = 0.0 }

@MainActor @Observable
final class Store {
    private(set) var connections: [Connection] = []
    private(set) var isLinking = false
    private(set) var isRefreshing = false
    private(set) var lastRefresh: Date?
    var message: String?

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

    init() {
        load()
        do { plaid = Plaid(config: try PlaidConfig.load()) } catch { message = error.localizedDescription }
        timer = Timer.scheduledTimer(withTimeInterval: 15 * 60, repeats: true) { [weak self] _ in
            Task { await self?.refresh() }
        }
        Task { await refresh() }
    }

    // MARK: Totals

    var totals: Totals {
        let now = lastRefresh ?? Date()
        let cal = Calendar.current
        let day = cal.startOfDay(for: now)
        let week = cal.dateInterval(of: .weekOfYear, for: now)?.start ?? day
        let month = cal.dateInterval(of: .month, for: now)?.start ?? day

        var t = Totals()
        for txn in connections.flatMap(\.transactions.values) where txn.amount > 0 {
            if let category = txn.personalFinanceCategory?.primary, Self.ignoredCategories.contains(category) { continue }
            guard let date = Self.dayFormatter.date(from: txn.authorizedDate ?? txn.date), date <= now else { continue }
            if date >= day { t.day += txn.amount }
            if date >= week { t.week += txn.amount }
            if date >= month { t.month += txn.amount }
        }
        return t
    }

    var label: String {
        guard isConfigured else { return "$ ⚠︎" }
        let t = totals
        return [t.day, t.week, t.month].map(Self.money).joined(separator: " | ")
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
            for txn in result.added { connections[i].transactions[txn.transactionId] = txn }
            for txnID in result.removed { connections[i].transactions[txnID] = nil }
            if !result.cursor.isEmpty { connections[i].cursor = result.cursor }  // empty = data not ready yet
            // Keep ~2 months so the file stays small; only the current month is ever displayed.
            let cutoff = Self.dayFormatter.string(from: Date().addingTimeInterval(-62 * 86400))
            connections[i].transactions = connections[i].transactions.filter { $0.value.date >= cutoff }
            connections[i].lastSynced = Date()
            connections[i].error = nil
        } catch {
            if let i = connections.firstIndex(where: { $0.id == id }) { connections[i].error = error.localizedDescription }
        }
        save()
    }

    // MARK: Connections

    func addConnection() {
        guard let plaid, !isLinking else { return }
        isLinking = true
        message = nil
        linkTask = Task {
            defer { isLinking = false }
            do {
                let link = try await plaid.createHostedLink()
                NSWorkspace.shared.open(link.url)
                let deadline = Date().addingTimeInterval(30 * 60)
                while Date() < deadline {
                    try await Task.sleep(for: .seconds(3))
                    let status = try await plaid.linkStatus(link.token)
                    if !status.results.isEmpty {
                        for result in status.results { try await finishLink(result) }
                        return
                    }
                    if status.finished { return }  // user closed Link without connecting
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
        if name == nil { name = try? await plaid.institutionName(accessToken: accessToken) }
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
        connections.removeAll { $0.id == id }
        save()
    }

    // MARK: Persistence

    private func load() {
        guard let data = try? Data(contentsOf: Self.fileURL) else { return }
        connections = (try? JSONDecoder().decode([Connection].self, from: data)) ?? []
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(connections) else { return }
        try? data.write(to: Self.fileURL, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: Self.fileURL.path)
    }
}
