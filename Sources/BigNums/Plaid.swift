import Foundation

struct PlaidError: LocalizedError {
    let code: String
    let message: String
    var errorDescription: String? { message.isEmpty ? code : message }
}

struct PlaidConfig {
    let clientID: String
    let secret: String
    let baseURL: String

    /// The user's keys from the Keychain. For development only, `PLAID_CLIENT_ID` and `PLAID_SECRET` from the environment or a
    /// `.env` in the working directory (`swift run`) also work. Never from inside the app bundle: a secret there would travel
    /// with the app to anyone it's shared with.
    static func load() throws -> PlaidConfig {
        if let keys = PlaidKeys.stored { return keys.config }
        let cwdEnv = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".env")
        let values = parseEnvFile(cwdEnv)
        let env = ProcessInfo.processInfo.environment
        func value(_ key: String) -> String { values[key].flatMap { $0.isEmpty ? nil : $0 } ?? env[key] ?? "" }

        let clientID = value("PLAID_CLIENT_ID"), secret = value("PLAID_SECRET")
        guard !clientID.isEmpty, !secret.isEmpty else {
            throw PlaidError(code: "CONFIG", message: "Add your Plaid keys to get started.")
        }
        let plaidEnv = value("PLAID_ENV").isEmpty ? "production" : value("PLAID_ENV")
        return PlaidConfig(clientID: clientID, secret: secret, baseURL: "https://\(plaidEnv).plaid.com")
    }

    /// `KEY=value` lines, ignoring comments and surrounding quotes.
    static func parseEnvFile(_ url: URL) -> [String: String] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [:] }
        var values: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2, !parts[0].hasPrefix("#") else { continue }
            values[parts[0]] = parts[1].trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        }
        return values
    }

    /// Moves the keys from a `.env` file into the Keychain. Used by `build.sh`, so a developer's keys are never copied into the app.
    @discardableResult
    static func importEnvFile(_ url: URL) -> Bool {
        let values = parseEnvFile(url)
        guard let clientID = values["PLAID_CLIENT_ID"], let secret = values["PLAID_SECRET"], !clientID.isEmpty, !secret.isEmpty else { return false }
        let environment = PlaidEnvironment(rawValue: values["PLAID_ENV"] ?? "") ?? .production
        return PlaidKeys(clientID: clientID, secret: secret, environment: environment).save()
    }
}

struct Transaction: Codable {
    struct Category: Codable { let primary: String; let detailed: String? }

    // Most fields are optional only so older caches still decode (they are then re-synced).
    let transactionId: String
    let accountId: String?
    let amount: Double  // positive = money out
    let date: String
    let authorizedDate: String?
    let datetime: String?
    let authorizedDatetime: String?
    let name: String?
    let merchantName: String?
    let logoUrl: String?
    let pending: Bool?
    let personalFinanceCategory: Category?
}

struct Account: Codable, Identifiable {
    let accountId: String
    let name: String
    let mask: String?
    let type: String?  // credit, depository, loan, investment
    let subtype: String?  // credit card, checking, savings, ...
    var balances: Balances?
    var id: String { accountId }

    struct Balances: Codable {
        let current: Double?  // what's in a deposit/investment account, or what's owed on a credit/loan account
        let available: Double?
        let limit: Double?  // credit limit on a card
    }
}

struct HostedLink {
    let token: String
    let url: URL
}

struct LinkResult {
    let publicToken: String
    let institution: String?
}

struct SyncResult {
    var added: [Transaction] = []
    var removed: [String] = []
    var accounts: [Account]?
    var cursor: String
}

private struct APIError: Decodable { let errorCode: String; let errorMessage: String?; let displayMessage: String? }

struct Plaid {
    let config: PlaidConfig

    /// Pass an access token to open Link in update mode (re-login to an existing Item) instead of adding a new one.
    func createHostedLink(updating accessToken: String? = nil) async throws -> HostedLink {
        struct Response: Decodable { let linkToken: String; let hostedLinkUrl: String? }
        var body: [String: Any] = [
            "client_name": "BigNums",
            "language": "en",
            "country_codes": ["US"],
            "user": ["client_user_id": "bignums-local-user"],
            "hosted_link": [String: Any](),
        ]
        if let accessToken {
            body["access_token"] = accessToken  // update mode must not list products
        } else {
            body["products"] = ["transactions"]
            body["transactions"] = ["days_requested": 730]  // max history, for browsing past months
        }
        let r: Response = try await call("/link/token/create", body)
        guard let url = r.hostedLinkUrl.flatMap(URL.init(string:)) else {
            throw PlaidError(code: "NO_HOSTED_LINK", message: "Plaid did not return a Hosted Link URL.")
        }
        return HostedLink(token: r.linkToken, url: url)
    }

    /// Polls a Hosted Link session. Returns finished = true once the user completes or exits Link.
    func linkStatus(_ linkToken: String) async throws -> (results: [LinkResult], finished: Bool) {
        struct Response: Decodable {
            struct Session: Decodable {
                struct Results: Decodable {
                    struct ItemAdd: Decodable {
                        struct Institution: Decodable { let name: String? }
                        let publicToken: String
                        let institution: Institution?
                    }
                    let itemAddResults: [ItemAdd]?
                }
                let finishedAt: String?
                let results: Results?
            }
            let linkSessions: [Session]?
        }
        let r: Response = try await call("/link/token/get", ["link_token": linkToken])
        let sessions = r.linkSessions ?? []
        let results = sessions.flatMap { $0.results?.itemAddResults ?? [] }
            .map { LinkResult(publicToken: $0.publicToken, institution: $0.institution?.name) }
        return (results, sessions.contains { $0.finishedAt != nil })
    }

    func exchange(_ publicToken: String) async throws -> (accessToken: String, itemID: String) {
        struct Response: Decodable { let accessToken: String; let itemId: String }
        let r: Response = try await call("/item/public_token/exchange", ["public_token": publicToken])
        return (r.accessToken, r.itemId)
    }

    struct Institution: Decodable {
        let name: String
        let url: String?
        let logo: String?  // base64 PNG
    }

    /// The bank behind an Item, including its website and logo when Plaid has them.
    func institution(accessToken: String) async throws -> Institution? {
        struct ItemResponse: Decodable { struct Item: Decodable { let institutionId: String? }; let item: Item }
        struct InstitutionResponse: Decodable { let institution: Institution }
        let item: ItemResponse = try await call("/item/get", ["access_token": accessToken])
        guard let id = item.item.institutionId else { return nil }
        let r: InstitutionResponse = try await call("/institutions/get_by_id", [
            "institution_id": id,
            "country_codes": ["US"],
            "options": ["include_optional_metadata": true],
        ])
        return r.institution
    }

    /// Asks Plaid for one institution, which any valid pair of keys can do, so a typo shows up right away.
    func validateKeys() async throws {
        struct Response: Decodable {}
        let _: Response = try await call("/institutions/get", ["count": 1, "offset": 0, "country_codes": ["US"]])
    }

    func accounts(accessToken: String) async throws -> [Account] {
        struct Response: Decodable { let accounts: [Account] }
        let r: Response = try await call("/accounts/get", ["access_token": accessToken])
        return r.accounts
    }

    func removeItem(accessToken: String) async throws {
        struct Response: Decodable {}
        let _: Response = try await call("/item/remove", ["access_token": accessToken])
    }

    /// Pulls every page of updates since `cursor`. Modified transactions are folded into `added` (upsert).
    func sync(accessToken: String, cursor: String?) async throws -> SyncResult {
        struct Response: Decodable {
            struct Removed: Decodable { let transactionId: String }
            let accounts: [Account]?
            let added: [Transaction], modified: [Transaction], removed: [Removed]
            let nextCursor: String, hasMore: Bool
        }
        var attempts = 0
        while true {
            var result = SyncResult(cursor: cursor ?? "")
            do {
                while true {
                    var body: [String: Any] = ["access_token": accessToken, "count": 500]
                    if !result.cursor.isEmpty { body["cursor"] = result.cursor }
                    let page: Response = try await call("/transactions/sync", body)
                    result.added += page.added + page.modified
                    result.removed += page.removed.map(\.transactionId)
                    result.cursor = page.nextCursor
                    if let accounts = page.accounts, !accounts.isEmpty { result.accounts = accounts }  // later pages/syncs send []
                    if !page.hasMore { return result }
                }
            } catch let e as PlaidError where e.code == "TRANSACTIONS_SYNC_MUTATION_DURING_PAGINATION" && attempts < 3 {
                attempts += 1  // Plaid requires restarting the whole pagination loop
            }
        }
    }

    private func call<T: Decodable>(_ path: String, _ body: [String: Any]) async throws -> T {
        var request = URLRequest(url: URL(string: config.baseURL + path)!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body = body
        body["client_id"] = config.clientID
        body["secret"] = config.secret
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            let e = try? decoder.decode(APIError.self, from: data)
            throw PlaidError(
                code: e?.errorCode ?? "HTTP_ERROR",
                message: e?.displayMessage ?? e?.errorMessage ?? String(decoding: data, as: UTF8.self)
            )
        }
        return try decoder.decode(T.self, from: data)
    }
}
