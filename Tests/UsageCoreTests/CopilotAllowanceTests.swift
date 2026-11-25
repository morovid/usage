import Foundation
import Testing
@testable import UsageCore

struct CopilotAllowanceTests {
    private let credits = Data(#"""
    {"token_based_billing":true,"quota_reset_date":"2027-01-01","quota_snapshots":{
      "premium_interactions":{"entitlement":0,"percent_remaining":100,"unlimited":true,"credits_used":75},
      "chat":{"entitlement":0,"unlimited":true,"credits_used":75},
      "completions":{"entitlement":0,"unlimited":true,"credits_used":75}}}
    """#.utf8)

    @Test func missingLimitRequestsAnAllowanceWithoutLosingConsumption() throws {
        do {
            _ = try UsageParser.parse(credits, provider: .githubCopilot)
            Issue.record("Expected allowance prompt")
        } catch let required as CopilotAllowanceRequired {
            #expect(required.usage.usedCredits == 75)
            #expect(required.usage.resetsAt == ISO8601DateFormatter().date(from: "2027-01-01T00:00:00Z"))
        }
    }

    @Test func manualAllowanceProducesOneWindowNotThreeSummedCounters() throws {
        let snapshot = try UsageParser.parse(credits, provider: .githubCopilot, copilotMonthlyAllowance: 100)
        #expect(snapshot.windows.count == 1)
        let window = try #require(snapshot.windows.first)
        #expect(window.usedPercent == 75)
        #expect(window.usedCredits == 75)
        #expect(window.creditAllowance == 100)
        #expect(window.isUserProvidedAllowance == true)
        #expect(AlertPolicy.evaluate(window, previous: nil).threshold == 70)
    }

    @Test func premiumCounterTakesPrecedenceOverOtherCategoryCounters() throws {
        let data = Data(#"""
        {"token_based_billing":true,"quota_snapshots":{
          "premium_interactions":{"unlimited":true,"credits_used":20},
          "chat":{"unlimited":true,"credits_used":60},
          "completions":{"unlimited":true,"credits_used":80}}}
        """#.utf8)
        let snapshot = try UsageParser.parse(data, provider: .githubCopilot, copilotMonthlyAllowance: 100)
        #expect(snapshot.windows[0].usedPercent == 20)
    }

    @Test func creditsOverAllowanceTriggerExhaustedAlertAndRetainActualAmount() throws {
        let snapshot = try UsageParser.parse(credits, provider: .githubCopilot, copilotMonthlyAllowance: 50)
        let window = snapshot.windows[0]
        #expect(window.usedPercent == 100)
        #expect(window.usedCredits == 75)
        #expect(AlertPolicy.evaluate(window, previous: nil).threshold == 100)
    }

    @Test(arguments: [0.0, -10, Double.nan, Double.infinity])
    func invalidAllowanceIsRejected(_ allowance: Double) throws {
        #expect(throws: (any Error).self) {
            try UsageParser.parse(credits, provider: .githubCopilot, copilotMonthlyAllowance: allowance)
        }
    }

    @Test func providerLimitOverridesSavedManualAllowance() throws {
        let data = Data(#"""
        {"token_based_billing":true,"quota_snapshots":{
          "premium_interactions":{"unlimited":false,"entitlement":200,"percent_remaining":90,"credits_used":20}}}
        """#.utf8)
        let snapshot = try UsageParser.parse(data, provider: .githubCopilot, copilotMonthlyAllowance: 50)
        #expect(snapshot.windows[0].usedPercent == 10)
        #expect(snapshot.windows[0].isUserProvidedAllowance != true)
    }

    @Test func providerCreditAmountsCanSupplyLimitWithoutPercentField() throws {
        let data = Data(#"""
        {"token_based_billing":true,"quota_snapshots":{
          "premium_interactions":{"unlimited":false,"entitlement":200,"credits_used":50}}}
        """#.utf8)
        let snapshot = try UsageParser.parse(data, provider: .githubCopilot, copilotMonthlyAllowance: 50)
        #expect(snapshot.windows[0].usedPercent == 25)
        #expect(snapshot.windows[0].isUserProvidedAllowance != true)
        #expect(snapshot.windows[0].creditAllowance == 200)
    }

    @Test func manualAllowanceDoesNotInventMissingConsumption() throws {
        let data = Data(#"{"token_based_billing":true,"quota_snapshots":{"premium_interactions":{"unlimited":true}}}"#.utf8)
        #expect(throws: CopilotQuotaUnavailable.self) {
            try UsageParser.parse(data, provider: .githubCopilot, copilotMonthlyAllowance: 100)
        }
    }

    @Test func zeroCreditsIsAValidReading() throws {
        let data = Data(#"{"token_based_billing":true,"quota_snapshots":{"premium_interactions":{"unlimited":true,"credits_used":0}}}"#.utf8)
        let snapshot = try UsageParser.parse(data, provider: .githubCopilot, copilotMonthlyAllowance: 100)
        #expect(snapshot.windows[0].usedPercent == 0)
        #expect(snapshot.windows[0].usedCredits == 0)
    }

    @Test func endedSubscriptionDoesNotBecomeManualAllowanceAccount() throws {
        let data = Data(#"{"access_type_sku":"subscription_ended","token_based_billing":true,"quota_snapshots":{"premium_interactions":{"credits_used":10}}}"#.utf8)
        #expect(throws: CopilotQuotaUnavailable.self) {
            try UsageParser.parse(data, provider: .githubCopilot, copilotMonthlyAllowance: 100)
        }
    }

    @Test func decimalInputUsesLocalSeparatorAndRejectsAmbiguousValues() {
        let en = Locale(identifier: "en_US")
        let de = Locale(identifier: "de_DE")
        #expect(CopilotCreditUsage.parseAllowance(" 1000.5 ", locale: en) == 1000.5)
        #expect(CopilotCreditUsage.parseAllowance("1000,5", locale: de) == 1000.5)
        for input in ["", "0", "-1", "NaN", "inf", "10garbage", "1,000", "1e999", "$100"] {
            #expect(CopilotCreditUsage.parseAllowance(input, locale: en) == nil)
        }
        #expect(CopilotCreditUsage.parseAllowance("1.000", locale: de) == nil)
    }

    @Test func allowancePersistsAndOldAccountsRemainReadable() throws {
        let account = Account(provider: .githubCopilot, email: "octocat", copilotMonthlyAllowance: 1000)
        let restored = try JSONDecoder().decode(Account.self, from: JSONEncoder().encode(account))
        #expect(restored.copilotMonthlyAllowance == 1000)
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(account)) as! [String: Any]
        json.removeValue(forKey: "copilotMonthlyAllowance")
        let legacy = try JSONDecoder().decode(Account.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(legacy.copilotMonthlyAllowance == nil)
    }

    @Test func extremelySmallAllowanceCannotOverflowToZeroUsage() throws {
        let snapshot = try UsageParser.parse(credits, provider: .githubCopilot,
                                             copilotMonthlyAllowance: Double.leastNormalMagnitude)
        #expect(snapshot.windows[0].usedPercent == 100)
    }
}
