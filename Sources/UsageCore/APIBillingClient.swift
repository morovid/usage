import Foundation

/// Money readings are deliberately separate from subscription quota windows.
/// These billing APIs do not supply a quota denominator.
public struct APIBillingSummary: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case balance, monthToDateCost }
    public let kind: Kind
    public let amount: Double
    public let currency: String
    public let periodStart: Date?
    public let cashBalance: Double?
    public let voucherBalance: Double?
    public var dataRefreshedAt: Date? = nil
}

public final class APIBillingClient: @unchecked Sendable {
    private let session: URLSession
    public init(session: URLSession? = nil) {
        if let session { self.session = session } else {
            let config = URLSessionConfiguration.ephemeral
            config.httpShouldSetCookies = false
            config.urlCache = nil
            config.timeoutIntervalForRequest = 20
            config.timeoutIntervalForResource = 30
            self.session = URLSession(configuration: config, delegate: NoRedirectDelegate(), delegateQueue: nil)
        }
    }

    public func fetch(account: Account, credential: Credential, now: Date = Date()) async throws -> UsageSnapshot {
        guard account.isAPI, account.source == .keychain,
              [.anthropic, .openAI, .moonshot, .deepSeek].contains(account.provider) else {
            throw UsageError.message("This account does not support API billing.")
        }
        guard !credential.accessToken.isEmpty,
              credential.accessToken.rangeOfCharacter(from: .controlCharacters) == nil else {
            throw UsageError.message("Enter a valid API key without line breaks.")
        }
        let billing: APIBillingSummary
        if account.provider == .anthropic {
            billing = try await anthropicCosts(credential: credential, now: now)
        } else if account.provider == .deepSeek {
            let data = try await get(URL(string: "https://api.deepseek.com/user/balance")!,
                                     credential: credential, provider: .deepSeek)
            billing = try Self.parseDeepSeekBalance(data)
        } else if account.provider == .moonshot {
            guard account.kimiInternational else {
                throw UsageError.message("Moonshot API monitoring currently supports Global accounts only.")
            }
            let data = try await get(URL(string: "https://api.moonshot.ai/v1/users/me/balance")!,
                                     credential: credential, provider: .moonshot)
            billing = try Self.parseMoonshotBalance(data)
        } else {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(secondsFromGMT: 0)!
            let start = calendar.dateInterval(of: .month, for: now)!.start
            var page: String?
            var seenPages: Set<String> = []
            var seenBuckets: Set<Int64> = []
            var total = 0.0
            var complete = false
            // A bounded paginated read: never silently present a partial total.
            for _ in 0..<100 {
                try Task.checkCancellation()
                var components = URLComponents(string: "https://api.openai.com/v1/organization/costs")!
                components.queryItems = [
                    URLQueryItem(name: "start_time", value: String(Int64(start.timeIntervalSince1970))),
                    URLQueryItem(name: "end_time", value: String(Int64(now.timeIntervalSince1970))),
                    URLQueryItem(name: "bucket_width", value: "1d"),
                    URLQueryItem(name: "limit", value: "31")
                ]
                if let page { components.queryItems!.append(URLQueryItem(name: "page", value: page)) }
                let data = try await get(components.url!, credential: credential, provider: .openAI)
                let result = try JSONDecoder().decode(CostPage.self, from: data)
                guard result.object == "page" else { throw Self.malformed() }
                for bucket in result.data {
                    guard bucket.object == "bucket", bucket.endTime > bucket.startTime,
                          bucket.endTime > Int64(start.timeIntervalSince1970),
                          bucket.startTime < Int64(now.timeIntervalSince1970),
                          seenBuckets.insert(bucket.startTime).inserted else { throw Self.malformed() }
                    for cost in bucket.results {
                        guard cost.object == "organization.costs.result",
                              cost.amount.currency.lowercased() == "usd", cost.amount.value.isFinite else {
                            throw Self.malformed()
                        }
                        total += cost.amount.value
                        guard total.isFinite else { throw Self.malformed() }
                    }
                }
                if !result.hasMore { complete = true; break }
                guard let next = result.nextPage, !next.isEmpty,
                      seenPages.insert(next).inserted else { throw Self.malformed() }
                page = next
            }
            guard complete else { throw UsageError.message("OpenAI returned too many billing pages. The total is unavailable.") }
            billing = APIBillingSummary(kind: .monthToDateCost, amount: total, currency: "USD",
                                        periodStart: start, cashBalance: nil, voucherBalance: nil)
        }
        return UsageSnapshot(windows: [], fetchedAt: now, billing: billing)
    }

    public static func parseMoonshotBalance(_ data: Data) throws -> APIBillingSummary {
        let response = try JSONDecoder().decode(BalanceResponse.self, from: data)
        guard response.code == 0, response.status,
              response.data.availableBalance.isFinite, response.data.cashBalance.isFinite,
              response.data.voucherBalance.isFinite, response.data.voucherBalance >= 0 else {
            throw malformed()
        }
        return APIBillingSummary(kind: .balance, amount: response.data.availableBalance, currency: "USD",
                                 periodStart: nil, cashBalance: response.data.cashBalance,
                                 voucherBalance: response.data.voucherBalance)
    }

    public static func parseDeepSeekBalance(_ data: Data) throws -> APIBillingSummary {
        let response = try JSONDecoder().decode(DeepSeekBalanceResponse.self, from: data)
        // Prefer USD; otherwise show the first reported currency rather than convert.
        guard let info = response.balanceInfos.first(where: { $0.currency == "USD" }) ?? response.balanceInfos.first,
              let total = Double(info.totalBalance), total.isFinite,
              let granted = Double(info.grantedBalance), granted.isFinite,
              let toppedUp = Double(info.toppedUpBalance), toppedUp.isFinite,
              ["USD", "CNY"].contains(info.currency) else { throw malformed() }
        return APIBillingSummary(kind: .balance, amount: total, currency: info.currency,
                                 periodStart: nil, cashBalance: toppedUp, voucherBalance: granted)
    }

    private func anthropicCosts(credential: Credential, now: Date) async throws -> APIBillingSummary {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let start = calendar.dateInterval(of: .month, for: now)!.start
        var page: String?
        var seenPages: Set<String> = []
        var seenRows: Set<Date> = []
        var refreshedAt: Date?
        var total = 0.0
        for _ in 0..<100 {
            try Task.checkCancellation()
            var components = URLComponents(string: "https://api.anthropic.com/v1/organizations/analytics/cost")!
            components.queryItems = [
                URLQueryItem(name: "starting_at", value: start.formatted(.iso8601)),
                URLQueryItem(name: "ending_at", value: now.formatted(.iso8601)),
                URLQueryItem(name: "time_bucket_width", value: "1h"),
                URLQueryItem(name: "limit", value: "1000")
            ]
            if let page { components.queryItems!.append(URLQueryItem(name: "page", value: page)) }
            let data = try await get(components.url!, credential: credential, provider: .anthropic)
            let result = try JSONDecoder().decode(AnthropicCostPage.self, from: data)
            guard let timestamp = result.dataRefreshedAt, let refreshed = Self.timestamp(timestamp) else {
                throw UsageError.message("Anthropic billing data is not available yet. Try again after the provider refreshes analytics.")
            }
            guard refreshedAt == nil || refreshedAt == refreshed else { throw Self.malformed() }
            refreshedAt = refreshed
            for row in result.data {
                guard let rowStart = Self.timestamp(row.startingAt), let rowEnd = Self.timestamp(row.endingAt),
                      rowStart >= start, rowStart < now, rowEnd > rowStart, rowEnd <= now,
                      seenRows.insert(rowStart).inserted,
                      row.cost.currency == "USD",
                      row.cost.amount.range(of: #"^-?[0-9]+(?:\.[0-9]+)?$"#, options: .regularExpression) != nil,
                      let cents = Double(row.cost.amount), cents.isFinite else { throw Self.malformed() }
                // Anthropic reports decimal strings in cents, not dollars.
                total += cents / 100
                guard total.isFinite else { throw Self.malformed() }
            }
            if !result.hasMore {
                return APIBillingSummary(kind: .monthToDateCost, amount: total, currency: "USD",
                                         periodStart: start, cashBalance: nil, voucherBalance: nil,
                                         dataRefreshedAt: refreshedAt)
            }
            guard let next = result.nextPage, !next.isEmpty, seenPages.insert(next).inserted else {
                throw Self.malformed()
            }
            page = next
        }
        throw UsageError.message("Anthropic returned too many billing pages. The total is unavailable.")
    }

    private static func timestamp(_ string: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: string) { return date }
        formatter.formatOptions.insert(.withFractionalSeconds)
        return formatter.date(from: string)
    }

    private func get(_ url: URL, credential: Credential, provider: Provider) async throws -> Data {
        var request = URLRequest(url: url)
        if provider == .anthropic {
            request.setValue(credential.accessToken, forHTTPHeaderField: "x-api-key")
            request.setValue("2026-10-21", forHTTPHeaderField: "anthropic-version")
            request.setValue("analytics-usage-cost-2026-08-24", forHTTPHeaderField: "anthropic-beta")
        } else {
            request.setValue("Bearer \(credential.accessToken)", forHTTPHeaderField: "Authorization")
        }
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Usage/1.0", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse else { throw Self.malformed() }
        switch http.statusCode {
        case 200: break
        case 401, 403:
            let hint = provider == .anthropic
                ? "Anthropic cost monitoring requires a Claude Console organization Admin API key with analytics access. A normal inference key or Claude subscription token cannot read API billing."
                : provider == .openAI
                ? "OpenAI cost monitoring requires an organization Admin API key with the Usage: Read (api.usage.read) permission, which only organization owners can create. Regular project keys cannot read spend."
                : provider == .deepSeek
                ? "Use a valid DeepSeek API key from platform.deepseek.com."
                : "Use a Global Moonshot Open Platform API key, not a Kimi Code subscription key or a China-region key."
            throw UsageError.message("API billing access denied (HTTP \(http.statusCode)). \(hint)")
        case 429: throw UsageError.message("API billing rate limit reached. Please try again later.")
        default: throw UsageError.message("API billing request failed (HTTP \(http.statusCode)).")
        }
        guard data.count <= 2_000_000 else { throw Self.malformed() }
        return data
    }

    private static func malformed() -> UsageError {
        UsageError.message("The API returned unrecognized or incomplete billing data. No balance or cost can be shown.")
    }
}

private struct AnthropicCostPage: Decodable {
    let data: [Row]
    let hasMore: Bool
    let nextPage: String?
    let dataRefreshedAt: String?
    enum CodingKeys: String, CodingKey {
        case data, hasMore = "has_more", nextPage = "next_page", dataRefreshedAt = "data_refreshed_at"
    }
    struct Row: Decodable {
        let startingAt: String
        let endingAt: String
        let cost: Cost
        enum CodingKeys: String, CodingKey { case cost, startingAt = "starting_at", endingAt = "ending_at" }
    }
    struct Cost: Decodable {
        let currency: String
        let amount: String
    }
}

private struct DeepSeekBalanceResponse: Decodable {
    let balanceInfos: [Info]
    enum CodingKeys: String, CodingKey { case balanceInfos = "balance_infos" }
    struct Info: Decodable {
        let currency: String
        let totalBalance: String
        let grantedBalance: String
        let toppedUpBalance: String
        enum CodingKeys: String, CodingKey {
            case currency, totalBalance = "total_balance", grantedBalance = "granted_balance", toppedUpBalance = "topped_up_balance"
        }
    }
}

private struct BalanceResponse: Decodable {
    let code: Int
    let status: Bool
    let data: BalanceData
    struct BalanceData: Decodable {
        let availableBalance: Double
        let voucherBalance: Double
        let cashBalance: Double
        enum CodingKeys: String, CodingKey {
            case availableBalance = "available_balance", voucherBalance = "voucher_balance", cashBalance = "cash_balance"
        }
    }
}

private struct CostPage: Decodable {
    let object: String
    let data: [Bucket]
    let hasMore: Bool
    let nextPage: String?
    enum CodingKeys: String, CodingKey { case object, data, hasMore = "has_more", nextPage = "next_page" }
    struct Bucket: Decodable {
        let object: String
        let startTime: Int64
        let endTime: Int64
        let results: [Cost]
        enum CodingKeys: String, CodingKey { case object, results, startTime = "start_time", endTime = "end_time" }
    }
    struct Cost: Decodable {
        let object: String
        let amount: Amount
    }
    struct Amount: Decodable {
        let value: Double
        let currency: String
    }
}
