import Foundation
import Testing
@testable import UsageCore

private func parse(_ json: String, _ provider: Provider) throws -> UsageSnapshot {
    try UsageParser.parse(Data(json.utf8), provider: provider)
}

@Test func anthropicLegacyAndLowPercent() throws {
    let snapshot = try parse(#"""
    {"five_hour":{"utilization":0.7,"resets_at":"2027-01-02T13:00:00.123Z"},
     "seven_day":{"utilization":71,"resets_at":null},"seven_day_opus":null,
     "internal_codename":{"utilization":100}}
    """#, .anthropic)
    #expect(snapshot.windows.count == 2)
    #expect(snapshot.windows[0].usedPercent == 0.7) // Never mistake 0.7% for 70%.
    #expect(snapshot.windows[0].resetsAt != nil)
    #expect(snapshot.windows[1].label == "Weekly")
}

@Test func anthropicModernPreferred() throws {
    let snapshot = try parse(#"""
    {"limits":[{"kind":"session","percent":25},
      {"kind":"weekly_scoped","percent":82,"scope":{"model":{"id":"opus","display_name":"Opus"}}},
      {"kind":"weekly_scoped","percent":100,"is_active":false},
      {"kind":"promotion","percent":99}],
     "five_hour":{"utilization":60}}
    """#, .anthropic)
    #expect(snapshot.windows.count == 2)
    #expect(snapshot.windows[0].usedPercent == 25)
    #expect(snapshot.windows[1].id == "weekly_scoped-opus")
}

@Test func codexDerivesDurationAndSkipsNull() throws {
    let snapshot = try parse(#"""
    {"rate_limit":{"primary_window":{"used_percent":40,"limit_window_seconds":604800,"reset_at":1900000000},
      "secondary_window":null}}
    """#, .openAI)
    #expect(snapshot.windows.count == 1)
    #expect(snapshot.windows[0].label == "Weekly")
    #expect(snapshot.windows[0].resetsAt == Date(timeIntervalSince1970: 1_900_000_000))
}

@Test func codexAdditionalLimitsIncluded() throws {
    let snapshot = try parse(#"""
    {"rate_limit":{"primary_window":{"used_percent":5,"limit_window_seconds":18000},
                  "secondary_window":{"used_percent":42,"limit_window_seconds":604800}},
     "additional_rate_limits":[{"limit_name":"Spark","rate_limit":{
       "primary_window":{"used_percent":100,"limit_window_seconds":18000}}}]}
    """#, .openAI)
    #expect(snapshot.windows.count == 3)
    #expect(snapshot.windows.contains { $0.usedPercent == 100 })
    #expect(snapshot.prominentWindows.count == 2)
}

@Test func kimiCountsOverrideBrokenRatios() throws {
    let snapshot = try parse(#"""
    {"usage":{"limit":"100","used":"100","resetTime":"2027-01-01T00:00:00Z"},
     "limits":[{"window":{"duration":300,"timeUnit":"TIME_UNIT_MINUTE"},
       "detail":{"limit":"100","remaining":"12","resetTime":"2027-01-01T00:00:00.123456Z"}}],
     "usages":{"limit_5h":{"used_ratio":0},"limit_7d":{"used_ratio":0},
       "limit_month_total":{"used_ratio":0.34,"reset_time":"2027-01-02T00:00:00Z"}}}
    """#, .moonshot)
    #expect(snapshot.windows.count == 3)
    #expect(snapshot.windows[0].usedPercent == 88)
    #expect(snapshot.windows[1].usedPercent == 100)
    #expect(snapshot.windows[2].usedPercent == 34)
    #expect(snapshot.prominentWindows.map(\.label) == ["5-hour", "Monthly"])
}

@Test func kimiZeroLimitIsUnknownNotZero() throws {
    #expect(throws: (any Error).self) {
        try parse(#"{"usage":{"limit":0,"used":0}}"#, .moonshot)
    }
}

@Test func openCodeThreeWindows() throws {
    let snapshot = try parse(#"""
    {"usage":{"rolling":{"percent":70,"resetsAt":"2027-01-01T00:00:00Z"},
      "weekly":{"percent":98},"monthly":{"percent":20}}}
    """#, .openCode)
    #expect(snapshot.windows.count == 3)
    #expect(snapshot.prominentWindows.map(\.label) == ["5-hour", "Monthly"])
}

@Test(arguments: Provider.allCases)
func missingDataIsNeverZero(_ provider: Provider) throws {
    #expect(throws: (any Error).self) { try parse("{}", provider) }
    #expect(throws: (any Error).self) { try parse("[]", provider) }
    #expect(throws: (any Error).self) { try parse("<html>sign in</html>", provider) }
}

@Test func malformedNumbersAreRejected() throws {
    #expect(throws: (any Error).self) {
        try parse(#"{"usage":{"rolling":{"percent":true},"monthly":{"percent":"NaN"},"weekly":{"percent":-1}}}"#, .openCode)
    }
}

@Test func percentIsClamped() throws {
    let snapshot = try parse(#"{"five_hour":{"utilization":145}}"#, .anthropic)
    #expect(snapshot.windows[0].usedPercent == 100)
}

@Test func thresholdsDeduplicate() {
    let now = Date(timeIntervalSince1970: 1_900_000_000)
    var window = UsageWindow(id: "5h", label: "5-hour", usedPercent: 69.9, duration: 18_000,
                             resetsAt: now.addingTimeInterval(100))
    var decision = AlertPolicy.evaluate(window, previous: nil, now: now)
    #expect(decision.threshold == nil)
    window.usedPercent = 70
    decision = AlertPolicy.evaluate(window, previous: decision.state, now: now)
    #expect(decision.threshold == 70)
    window.usedPercent = 99
    decision = AlertPolicy.evaluate(window, previous: decision.state, now: now)
    #expect(decision.threshold == nil)
    window.usedPercent = 100
    decision = AlertPolicy.evaluate(window, previous: decision.state, now: now)
    #expect(decision.threshold == 100)
    #expect(AlertPolicy.evaluate(window, previous: decision.state, now: now).threshold == nil)
}

@Test func jumpingToExhaustedSendsOnlyOneAlert() {
    let window = UsageWindow(id: "monthly", label: "Monthly", usedPercent: 100, duration: 2_592_000)
    #expect(AlertPolicy.evaluate(window, previous: nil).threshold == 100)
}

@Test func resetRearmsThresholds() {
    let now = Date()
    let window = UsageWindow(id: "5h", label: "5-hour", usedPercent: 72, duration: 18_000,
                             resetsAt: now.addingTimeInterval(18_000))
    let old = AlertState(highestThreshold: 100, resetsAt: now.addingTimeInterval(-60))
    #expect(AlertPolicy.evaluate(window, previous: old, now: now).threshold == 70)
}

@Test func resetTimestampJitterDoesNotSpam() {
    let now = Date()
    let window = UsageWindow(id: "5h", label: "5-hour", usedPercent: 90, duration: 18_000,
                             resetsAt: now.addingTimeInterval(1_801))
    let old = AlertState(highestThreshold: 70, resetsAt: now.addingTimeInterval(1_800))
    #expect(AlertPolicy.evaluate(window, previous: old, now: now).threshold == nil)
}

@Test func droppingBelowWarningRearmsUnknownResetWindow() {
    var window = UsageWindow(id: "5h", label: "5-hour", usedPercent: 5, duration: 18_000)
    let decision = AlertPolicy.evaluate(window, previous: AlertState(highestThreshold: 100))
    #expect(decision.state.highestThreshold == 0)
    window.usedPercent = 80
    #expect(AlertPolicy.evaluate(window, previous: decision.state).threshold == 70)
}

@Test func accountAndAlertStateRoundTrip() throws {
    let account = Account(provider: .openAI, email: "user@example.com", source: .codexFile,
                          credentialPath: "/example/auth.json", externalAccountID: "account-1")
    let restored = try JSONDecoder().decode(Account.self, from: JSONEncoder().encode(account))
    #expect(restored == account)
    let state = AlertState(highestThreshold: 70, resetsAt: Date())
    #expect(try JSONDecoder().decode(AlertState.self, from: JSONEncoder().encode(state)) == state)
}

@Test func copilotPremiumUsageAndReset() throws {
    let snapshot = try parse(#"""
    {"quota_reset_date":"2027-01-01","quota_snapshots":{
      "premium_interactions":{"percent_remaining":28.5,"entitlement":300,"quota_reset_at":0},
      "chat":{"unlimited":true,"entitlement":-1,"remaining":-1},
      "completions":{"unlimited":true,"percent_remaining":0}}}
    """#, .githubCopilot)
    #expect(snapshot.windows.count == 1)
    #expect(snapshot.windows[0].usedPercent == 71.5)
    #expect(snapshot.windows[0].resetsAt == ISO8601DateFormatter().date(from: "2027-01-01T00:00:00Z"))
    #expect(AlertPolicy.evaluate(snapshot.windows[0], previous: nil).threshold == 70)
}

@Test func copilotFractionalRemainingAndCredits() throws {
    let snapshot = try parse(#"""
    {"token_based_billing":true,"quota_reset_date_utc":"2027-01-01T12:00:00Z","quota_snapshots":{
      "premium_interactions":{"entitlement":100,"quota_remaining":12.5,"remaining":12}}}
    """#, .githubCopilot)
    #expect(snapshot.windows[0].usedPercent == 87.5)
    #expect(snapshot.windows[0].label == "Monthly · Credits")
    #expect(snapshot.windows[0].resetsAt == ISO8601DateFormatter().date(from: "2027-01-01T12:00:00Z"))
}

@Test func copilotLegacyFreePlan() throws {
    let snapshot = try parse(#"""
    {"monthly_quotas":{"chat":500,"completions":4000},
     "limited_user_quotas":{"chat":100,"completions":0},
     "limited_user_reset_date":"2027-02-01"}
    """#, .githubCopilot)
    #expect(snapshot.windows.count == 2)
    #expect(snapshot.windows.first { $0.id == "chat" }?.usedPercent == 80)
    #expect(snapshot.windows.first { $0.id == "completions" }?.usedPercent == 100)
}

@Test func copilotUnlimitedAndMissingQuotasDoNotBecomeExhausted() throws {
    for json in [
        #"{"quota_snapshots":{"premium_interactions":{"unlimited":true,"percent_remaining":0}}}"#,
        #"{"quota_snapshots":{"premium_interactions":{"entitlement":0,"percent_remaining":0}}}"#,
        #"{"quota_snapshots":{"chat":{"entitlement":-1,"remaining":-1}}}"#,
        #"{"quota_snapshots":{"premium_interactions":{"has_quota":false,"percent_remaining":0}}}"#,
        #"{"quota_snapshots":{"premium_interactions":{"entitlement":100}}}"#
    ] {
        #expect(throws: (any Error).self) { try parse(json, .githubCopilot) }
    }
}

@Test func legacyNotificationPreferenceDoesNotDisableAlwaysOnAlerts() throws {
    let account = Account(provider: .moonshot, email: "Personal")
    var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(account)) as! [String: Any]
    json["notificationsEnabled"] = false
    let restored = try JSONDecoder().decode(Account.self, from: JSONSerialization.data(withJSONObject: json))
    #expect(restored == account)
}

@Test func onlyEmailBasedProvidersRequireEmailLabels() {
    #expect(Provider.anthropic.usesEmailLabel)
    #expect(Provider.openAI.usesEmailLabel)
    #expect(!Provider.moonshot.usesEmailLabel)
    #expect(!Provider.openCode.usesEmailLabel)
    #expect(!Provider.githubCopilot.usesEmailLabel)
}

@Test func copilotOrganizationSeatCanReportPersonalQuota() throws {
    let snapshot = try parse(#"""
    {"copilot_plan":"business","organization_login_list":["example-org"],
     "quota_reset_date":"2027-01-01","quota_snapshots":{
       "chat":{"entitlement":0,"remaining":0,"unlimited":true},
       "completions":{"entitlement":0,"remaining":0,"unlimited":true},
       "premium_interactions":{"entitlement":300,"quota_remaining":93.5,"percent_remaining":31.166666666666664,"unlimited":false}}}
    """#, .githubCopilot)
    #expect(snapshot.windows.count == 1)
    #expect(abs(snapshot.windows[0].usedPercent - 68.83333333333333) < 0.00001)
}

@Test func copilotCreditBasedPlaceholdersExplainMissingDenominator() throws {
    let data = Data(#"""
    {"copilot_plan":"business","token_based_billing":true,"quota_snapshots":{
      "premium_interactions":{"entitlement":0,"remaining":0,"unlimited":false,"credits_used":18.5},
      "chat":{"unlimited":true,"entitlement":0}}}
    """#.utf8)
    do {
        _ = try UsageParser.parse(data, provider: .githubCopilot)
        Issue.record("A placeholder without an allowance must not become a percentage")
    } catch let error as CopilotAllowanceRequired {
        #expect(error.usage.usedCredits == 18.5)
    }
}

@Test func copilotDiagnosticsDoNotExposePrivateResponseFields() throws {
    let data = Data(#"""
    {"access_token":"secret-token-marker","organization_login_list":["private-org-marker"],
     "copilot_plan":"secret-plan-marker","arbitrary-private-key":"private-value",
     "quota_snapshots":{}}
    """#.utf8)
    do {
        _ = try UsageParser.parse(data, provider: .githubCopilot)
        Issue.record("Missing quotas must be unavailable")
    } catch let error as CopilotQuotaUnavailable {
        #expect(error.reason == .noSnapshots)
        let text = error.localizedDescription
        #expect(!text.contains("secret-token-marker"))
        #expect(!text.contains("private-org-marker"))
        #expect(!text.contains("secret-plan-marker"))
        #expect(!text.contains("arbitrary-private-key"))
        #expect(!text.contains("private-value"))
    }
}

@Test func copilotUnlimitedAndExpiredPlansHaveDistinctReasons() throws {
    for (json, expected) in [
        (#"{"quota_snapshots":{"chat":{"unlimited":true}}}"#, CopilotQuotaUnavailable.Reason.unlimited),
        (#"{"access_type_sku":"subscription_ended"}"#, .subscriptionEnded)
    ] {
        do {
            _ = try parse(json, .githubCopilot)
            Issue.record("Expected no finite quota")
        } catch let error as CopilotQuotaUnavailable {
            #expect(error.reason == expected)
        }
    }
}
