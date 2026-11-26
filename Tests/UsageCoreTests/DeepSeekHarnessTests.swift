import Foundation
import Testing
@testable import UsageCore

@Test func harnessImportsBrowserGrant() throws {
    let data = Data("""
    version: 1
    records:
      deepseek-account-platform/default:
        kind: grant
        payload:
          version: 1
          token: "test-account-token"
          issuer: https://platform.deepseek.com
    """.utf8)
    let credential = try DeepSeekHarnessImport.parse(data)
    #expect(credential.accessToken == "test-account-token")
    #expect(credential.deepSeekHarness == true)
    let decoded = try JSONDecoder().decode(Credential.self, from: JSONEncoder().encode(credential))
    #expect(decoded.deepSeekHarness == true)
}

@Test func harnessImportsAPIKeyReference() throws {
    let data = Data("""
    version: 1
    refs:
      DEEPSEEK_API_KEY: 'sk-test-key'
      OTHER_KEY: unrelated
    """.utf8)
    let credential = try DeepSeekHarnessImport.parse(data)
    #expect(credential.accessToken == "sk-test-key")
    #expect(credential.deepSeekHarness != true)
}

@Test func harnessRejectsUnknownAndUnsafeCredentials() {
    for text in [
        "version: 2\nrefs:\n  DEEPSEEK_API_KEY: sk-test",
        "version: 1\nrefs:\n  OTHER_KEY: sk-test",
        "version: 1\nrefs:\n  DEEPSEEK_API_KEY: \"secret\\nvalue\"",
        """
        version: 1
        records:
          deepseek-account-platform/default:
            kind: grant
            payload:
              version: 1
              token: secret
              issuer: https://untrusted.example
        """,
        "version: 1\nrefs: [bad yaml secret"
    ] {
        do {
            _ = try DeepSeekHarnessImport.parse(Data(text.utf8))
            Issue.record("Expected invalid credentials to be rejected")
        } catch {
            #expect(!error.localizedDescription.contains("secret"))
        }
    }
}

@Test func harnessBalanceCombinesOnlyMatchingCurrencies() throws {
    let data = Data(#"{"code":0,"data":{"biz_code":0,"biz_data":{"normal_wallets":[{"currency":"CNY","balance":"70"},{"currency":"USD","balance":"10.5"}],"bonus_wallets":[{"currency":"USD","balance":"2.5"}]}}}"#.utf8)
    let summary = try APIBillingClient.parseDeepSeekHarnessBalance(data)
    #expect(summary.currency == "USD")
    #expect(summary.amount == 13)
    #expect(summary.cashBalance == 10.5)
    #expect(summary.voucherBalance == 2.5)
    #expect(summary.kind == .balance)
}

@Test func harnessBalanceRejectsFailuresAndMissingWallets() {
    for json in [
        #"{"code":40003,"data":{"biz_code":0,"biz_data":{"normal_wallets":[],"bonus_wallets":[]}}}"#,
        #"{"code":0,"data":{"biz_code":1,"biz_data":{"normal_wallets":[],"bonus_wallets":[]}}}"#,
        #"{"code":0,"data":{"biz_code":0,"biz_data":{"normal_wallets":[],"bonus_wallets":[]}}}"#,
        #"{"code":0,"data":{"biz_code":0,"biz_data":{"normal_wallets":[{"currency":"USD","balance":"NaN"}],"bonus_wallets":[]}}}"#
    ] {
        #expect(throws: (any Error).self) { try APIBillingClient.parseDeepSeekHarnessBalance(Data(json.utf8)) }
    }
}
