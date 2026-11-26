import Foundation
import Testing
@testable import UsageCore

private final class BillingMockProtocol: URLProtocol {
    struct Reply {
        var status = 200
        let json: String
    }
    static var replies: [Reply] = []
    static var requests: [URLRequest] = []
    static let lock = NSLock()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock()
        Self.requests.append(request)
        let reply = Self.replies.isEmpty ? Reply(status: 500, json: "{}") : Self.replies.removeFirst()
        Self.lock.unlock()
        let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: nil,
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(reply.json.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Suite(.serialized)
struct APIBillingTests {
    private var now: Date { ISO8601DateFormatter().date(from: "2026-11-25T12:00:00Z")! }
    private var key: Credential { Credential(accessToken: "test-key") }
    private var openAI: Account { Account(provider: .openAI, email: "API", apiAccess: true) }
    private var moonshot: Account {
        Account(provider: .moonshot, email: "API", kimiInternational: true, apiAccess: true)
    }
    private var balance: String {
        #"{"code":0,"status":true,"data":{"available_balance":49.58894,"voucher_balance":46.58893,"cash_balance":3.00001}}"#
    }
    private func session(_ replies: [BillingMockProtocol.Reply]) -> URLSession {
        BillingMockProtocol.lock.lock()
        BillingMockProtocol.replies = replies
        BillingMockProtocol.requests = []
        BillingMockProtocol.lock.unlock()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [BillingMockProtocol.self]
        return URLSession(configuration: config)
    }
    private func page(day: Int = 0, values: String = "1.25,2.5", more: Bool = false,
                      next: String = "null", currency: String = "usd") -> String {
        let start = Int64(ISO8601DateFormatter().date(from: "2026-11-01T00:00:00Z")!.timeIntervalSince1970) + Int64(day * 86400)
        let results = values.split(separator: ",").map {
            #"{"object":"organization.costs.result","amount":{"value":\#($0),"currency":"\#(currency)"}}"#
        }.joined(separator: ",")
        return #"{"object":"page","has_more":\#(more),"next_page":\#(next),"data":[{"object":"bucket","start_time":\#(start),"end_time":\#(start + 86400),"results":[\#(results)]}]}"#
    }

    @Test func moonshotGlobalBalanceIsNotSubscriptionUsage() async throws {
        let client = APIBillingClient(session: session([.init(json: balance)]))
        let snapshot = try await client.fetch(account: moonshot, credential: key, now: now)
        #expect(snapshot.windows.isEmpty)
        #expect(snapshot.billing?.kind == .balance)
        #expect(snapshot.billing?.amount == 49.58894)
        #expect(snapshot.billing?.cashBalance == 3.00001)
        #expect(snapshot.billing?.voucherBalance == 46.58893)
        #expect(snapshot.billing?.currency == "USD")
        let request = try #require(BillingMockProtocol.requests.first)
        #expect(request.httpMethod == "GET")
        #expect(request.url?.absoluteString == "https://api.moonshot.ai/v1/users/me/balance")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-key")
        #expect(request.httpBody == nil)
    }

    @Test func deepSeekBalanceUsesUserBalanceEndpoint() async throws {
        let json = #"{"is_available":true,"balance_infos":[{"currency":"CNY","total_balance":"70.00","granted_balance":"0.00","topped_up_balance":"70.00"},{"currency":"USD","total_balance":"12.34","granted_balance":"2.34","topped_up_balance":"10.00"}]}"#
        let client = APIBillingClient(session: session([.init(json: json)]))
        let account = Account(provider: .deepSeek, email: "DeepSeek API", apiAccess: true)
        let snapshot = try await client.fetch(account: account, credential: key, now: now)
        #expect(snapshot.windows.isEmpty)
        #expect(snapshot.billing?.kind == .balance)
        #expect(snapshot.billing?.currency == "USD")
        #expect(snapshot.billing?.amount == 12.34)
        #expect(snapshot.billing?.cashBalance == 10)
        #expect(snapshot.billing?.voucherBalance == 2.34)
        let request = try #require(BillingMockProtocol.requests.first)
        #expect(request.url?.absoluteString == "https://api.deepseek.com/user/balance")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-key")
        #expect(throws: (any Error).self) { try APIBillingClient.parseDeepSeekBalance(Data(#"{"balance_infos":[]}"#.utf8)) }
    }

    @Test func deepSeekHarnessUsesAccountHeaderNotAPIKey() async throws {
        let json = #"{"code":0,"data":{"biz_code":0,"biz_data":{"normal_wallets":[{"currency":"USD","balance":"9"}],"bonus_wallets":[]}}}"#
        let client = APIBillingClient(session: session([.init(json: json)]))
        var credential = Credential(accessToken: "test-harness-token")
        credential.deepSeekHarness = true
        let snapshot = try await client.fetch(account: Account(provider: .deepSeek, email: "Harness", apiAccess: true),
                                              credential: credential, now: now)
        #expect(snapshot.billing?.amount == 9)
        let request = try #require(BillingMockProtocol.requests.first)
        #expect(request.url?.absoluteString == "https://platform.deepseek.com/api/v0/users/get_user_summary")
        #expect(request.value(forHTTPHeaderField: "x-dsh-auth-token") == "test-harness-token")
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(request.httpBody == nil)
    }

    @Test func zeroAndNegativeBalancesAreRealReadings() throws {
        for value in ["0", "-1.5"] {
            let data = balance.replacingOccurrences(of: "49.58894", with: value)
            let reading = try APIBillingClient.parseMoonshotBalance(Data(data.utf8))
            #expect(reading.amount == Double(value))
        }
    }

    @Test func missingBalanceAndProviderErrorsNeverBecomeZero() {
        for json in ["{}", #"{"code":0,"status":true,"data":{}}"#,
                     balance.replacingOccurrences(of: "\"code\":0", with: "\"code\":1"),
                     balance.replacingOccurrences(of: "\"status\":true", with: "\"status\":false")] {
            #expect(throws: (any Error).self) { try APIBillingClient.parseMoonshotBalance(Data(json.utf8)) }
        }
    }

    @Test func openAICostsSumAllPagesUsingUTCMonthAndNoModelCalls() async throws {
        let client = APIBillingClient(session: session([
            .init(json: page(more: true, next: #""next+page&cursor""#)),
            .init(json: page(day: 1, values: "0.25"))
        ]))
        let snapshot = try await client.fetch(account: openAI, credential: key, now: now)
        #expect(snapshot.billing?.amount == 4)
        #expect(snapshot.billing?.kind == .monthToDateCost)
        #expect(snapshot.billing?.periodStart == ISO8601DateFormatter().date(from: "2026-11-01T00:00:00Z"))
        #expect(snapshot.windows.isEmpty)
        let requests = BillingMockProtocol.requests
        #expect(requests.count == 2)
        #expect(requests.allSatisfy { $0.url?.host == "api.openai.com" && $0.url?.path == "/v1/organization/costs" && $0.httpMethod == "GET" })
        let query = URLComponents(url: requests[1].url!, resolvingAgainstBaseURL: false)!.queryItems!
        #expect(query.first { $0.name == "page" }?.value == "next+page&cursor")
        #expect(query.first { $0.name == "limit" }?.value == "31")
        #expect(query.first { $0.name == "start_time" }?.value == "1793491200")
        #expect(query.first { $0.name == "end_time" }?.value == String(Int64(now.timeIntervalSince1970)))
        #expect(requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer test-key" })
    }

    @Test func emptyCostResultsAreValidZeroNotMissingSchema() async throws {
        for json in [page(values: ""), #"{"object":"page","data":[],"has_more":false,"next_page":null}"#] {
            let client = APIBillingClient(session: session([.init(json: json)]))
            #expect(try await client.fetch(account: openAI, credential: key, now: now).billing?.amount == 0)
        }
    }

    @Test func malformedMixedCurrencyAndPartialPagesAreRejected() async throws {
        for replies in [
            [BillingMockProtocol.Reply(json: "{}")],
            [.init(json: page(currency: "eur"))],
            [.init(json: page().replacingOccurrences(of: "\"value\":1.25", with: "\"unexpected\":1.25"))],
            [.init(json: page(more: true))],
            [.init(json: page(more: true, next: #""next""#)), .init(status: 500, json: "{}")],
            [.init(json: page(more: true, next: #""next""#)), .init(json: page())],
            [.init(json: page(more: true, next: #""next""#)),
             .init(json: page(day: 1, more: true, next: #""next""#))]
        ] {
            let client = APIBillingClient(session: session(replies))
            await #expect(throws: (any Error).self) { try await client.fetch(account: openAI, credential: key, now: now) }
        }
    }

    @Test func billingRejectionExplainsCorrectKeyWithoutLeakingBody() async throws {
        for account in [openAI, moonshot] {
            let client = APIBillingClient(session: session([.init(status: 403, json: #"{"error":"secret-marker"}"#)]))
            do {
                _ = try await client.fetch(account: account, credential: key, now: now)
                Issue.record("Expected denied billing access")
            } catch {
                #expect(error.localizedDescription.contains("HTTP 403"))
                #expect(error.localizedDescription.contains(account.provider == .openAI ? "Admin API key" : "Global Moonshot"))
                #expect(!error.localizedDescription.contains("secret-marker"))
            }
        }
    }

    @Test func unsupportedAccountTypesAndRegionsNeverSendCredentials() async throws {
        let client = APIBillingClient(session: session([]))
        for account in [
            Account(provider: .openAI, email: "subscription"),
            Account(provider: .moonshot, email: "China API", apiAccess: true),
            Account(provider: .githubCopilot, email: "unsupported", apiAccess: true),
            Account(provider: .openAI, email: "wrong source", source: .codexAppServer, apiAccess: true)
        ] {
            await #expect(throws: (any Error).self) { try await client.fetch(account: account, credential: key) }
        }
        #expect(BillingMockProtocol.requests.isEmpty)
    }

    @Test func usageClientRoutesAPIAccountsToBillingInsteadOfSubscriptionEndpoints() async throws {
        let client = UsageClient(session: session([.init(json: balance)]))
        #expect(try await client.fetch(account: moonshot, credential: key).billing?.kind == .balance)
        #expect(BillingMockProtocol.requests.first?.url?.host == "api.moonshot.ai")
    }

    private var anthropic: Account { Account(provider: .anthropic, email: "Console", apiAccess: true) }
    private func anthropicPage(hour: Int = 0, amount: String = "12345.670000", more: Bool = false,
                               next: String = "null", refreshed: String = #""2026-11-25T08:00:00Z""#) -> String {
        let start = String(format: "2026-11-01T%02d:00:00Z", hour)
        let end = String(format: "2026-11-01T%02d:00:00Z", hour + 1)
        return #"{"data":[{"starting_at":"\#(start)","ending_at":"\#(end)","cost":{"amount":"\#(amount)","currency":"USD"}}],"has_more":\#(more),"next_page":\#(next),"data_refreshed_at":\#(refreshed)}"#
    }

    @Test func anthropicAdminCostsUseCorrectHeadersAndConvertCentsToDollars() async throws {
        let client = UsageClient(session: session([.init(json: anthropicPage())]))
        let snapshot = try await client.fetch(account: anthropic, credential: key)
        #expect(snapshot.billing?.kind == .monthToDateCost)
        #expect(abs(snapshot.billing!.amount - 123.4567) < 0.000001)
        #expect(snapshot.billing?.dataRefreshedAt == ISO8601DateFormatter().date(from: "2026-11-25T08:00:00Z"))
        #expect(snapshot.windows.isEmpty)
        let request = try #require(BillingMockProtocol.requests.first)
        #expect(request.url?.host == "api.anthropic.com")
        #expect(request.url?.path == "/v1/organizations/analytics/cost")
        #expect(request.httpMethod == "GET")
        #expect(request.value(forHTTPHeaderField: "x-api-key") == "test-key")
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(request.value(forHTTPHeaderField: "anthropic-version") == "2026-10-21")
        #expect(request.value(forHTTPHeaderField: "anthropic-beta") == "analytics-usage-cost-2026-08-24")
        let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
        #expect(query.first { $0.name == "starting_at" }?.value == "2026-11-01T00:00:00Z")
        #expect(query.first { $0.name == "time_bucket_width" }?.value == "1h")
    }

    @Test func anthropicPaginationMustBeCompleteAndHaveConsistentFreshness() async throws {
        let client = APIBillingClient(session: session([
            .init(json: anthropicPage(amount: "100", more: true, next: #""page+2&cursor""#)),
            .init(json: anthropicPage(hour: 1, amount: "250"))
        ]))
        #expect(try await client.fetch(account: anthropic, credential: key, now: now).billing?.amount == 3.5)
        let query = URLComponents(url: BillingMockProtocol.requests[1].url!, resolvingAgainstBaseURL: false)!.queryItems!
        #expect(query.first { $0.name == "page" }?.value == "page+2&cursor")
        for replies in [
            [BillingMockProtocol.Reply(json: anthropicPage(more: true))],
            [.init(json: anthropicPage(more: true, next: #""two""#)), .init(status: 500, json: "{}")],
            [.init(json: anthropicPage(more: true, next: #""two""#)), .init(json: anthropicPage())],
            [.init(json: anthropicPage(more: true, next: #""two""#)),
             .init(json: anthropicPage(hour: 1, refreshed: #""2026-11-25T09:00:00Z""#))]
        ] {
            let service = APIBillingClient(session: session(replies))
            await #expect(throws: (any Error).self) { try await service.fetch(account: anthropic, credential: key, now: now) }
        }
    }

    @Test func anthropicMissingOrUnrefreshedDataCannotBecomeZero() async throws {
        for json in ["{}", anthropicPage(refreshed: "null"), anthropicPage(amount: "NaN"),
                     anthropicPage(amount: "1e309"), anthropicPage().replacingOccurrences(of: "\"USD\"", with: "\"EUR\""),
                     anthropicPage().replacingOccurrences(of: "\"amount\":", with: "\"missing_amount\":")] {
            let client = APIBillingClient(session: session([.init(json: json)]))
            await #expect(throws: (any Error).self) { try await client.fetch(account: anthropic, credential: key, now: now) }
        }
        let client = APIBillingClient(session: session([
            .init(json: #"{"data":[],"has_more":false,"next_page":null,"data_refreshed_at":"2026-11-25T08:00:00Z"}"#)
        ]))
        #expect(try await client.fetch(account: anthropic, credential: key, now: now).billing?.amount == 0)
    }

    @Test func anthropicDeniedAccessExplainsAdminRequirementWithoutSecrets() async throws {
        let client = APIBillingClient(session: session([.init(status: 403, json: #"{"error":"secret-marker"}"#)]))
        do {
            _ = try await client.fetch(account: anthropic, credential: key, now: now)
            Issue.record("Expected failure")
        } catch {
            #expect(error.localizedDescription.contains("Admin API key"))
            #expect(!error.localizedDescription.contains("secret-marker"))
        }
    }

    @Test func openCodeGoUsesDocumentedUsageEndpointNotInferenceCalls() async throws {
        let client = UsageClient(session: session([.init(json: #"{"usage":{"rolling":{"status":"ok","percent":30,"resetsAt":"2026-11-25T18:00:00Z"},"weekly":{"percent":50},"monthly":{"percent":60}}}"#)]))
        let account = Account(provider: .openCode, email: "Go workspace")
        let snapshot = try await client.fetch(account: account, credential: key)
        #expect(snapshot.windows.count == 3)
        #expect(snapshot.billing == nil)
        #expect(account.displayProviderName == "OpenCode Go")
        let request = try #require(BillingMockProtocol.requests.first)
        #expect(request.httpMethod == "GET")
        #expect(request.url?.absoluteString == "https://opencode.ai/inference/go/v1/usage")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-key")
    }

    @Test func anthropicAccountTypesStaySeparateAndOldSubscriptionStateLoads() throws {
        let subscription = Account(provider: .anthropic, email: "me@example.com")
        for account in [subscription, anthropic] {
            let decoded = try JSONDecoder().decode(Account.self, from: JSONEncoder().encode(account))
            #expect(decoded.isAPI == account.isAPI)
        }
        #expect(Provider.anthropic.supportsAPIBilling)
        #expect(!Provider.openCode.supportsAPIBilling)
        #expect(anthropic.displayProviderName == "Anthropic API")
    }

    @Test func accountKindsAndBillingSnapshotsRoundTripWithoutMigratingOldAccounts() throws {
        var legacy = openAI
        legacy.apiAccess = nil
        let decodedLegacy = try JSONDecoder().decode(Account.self, from: JSONEncoder().encode(legacy))
        #expect(!decodedLegacy.isAPI)
        for account in [openAI, moonshot] {
            let decoded = try JSONDecoder().decode(Account.self, from: JSONEncoder().encode(account))
            #expect(decoded == account)
            #expect(decoded.displayProviderName.hasSuffix(" API"))
            #expect(decoded.source == .keychain)
        }
        let billing = try APIBillingClient.parseMoonshotBalance(Data(balance.utf8))
        let snapshot = UsageSnapshot(windows: [], billing: billing)
        let decoded = try JSONDecoder().decode(UsageSnapshot.self, from: JSONEncoder().encode(snapshot))
        #expect(decoded.billing == billing)
        #expect(decoded.prominentWindows.isEmpty)
    }
}
