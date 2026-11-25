import Foundation
import Testing
@testable import UsageCore

struct CodexProtocolTests {
    private func object(_ json: String) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any]
    }

    @Test func identityUsesAccountEndpointNotUnverifiedJWTClaims() throws {
        let identity = try ChatGPTIdentity.parse(object(#"{"account":{"type":"chatgpt","email":"user@example.com","planType":"plus","id":"account-1"}}"#))
        #expect(identity.email == "user@example.com")
        #expect(identity.accountID == "account-1")
        #expect(identity.label == "user@example.com")
    }

    @Test func emailIsOptionalAndAPIKeyLoginIsNotSubscriptionLogin() throws {
        let identity = try ChatGPTIdentity.parse(object(#"{"account":{"type":"chatgpt","email":null}}"#))
        #expect(identity.label == "ChatGPT account")
        for response in [#"{"account":null}"#, #"{"account":{"type":"apiKey"}}"#, "{}"] {
            #expect(throws: (any Error).self) { try ChatGPTIdentity.parse(object(response)) }
        }
    }

    @Test func loginRequiresAnExpectedSecureAuthorizationHost() throws {
        for url in ["https://auth.openai.com/oauth/authorize?state=opaque", "https://chatgpt.com/auth/login"] {
            let login = try ChatGPTLogin.parse(["type": "chatgpt", "loginId": "login-1", "authUrl": url])
            #expect(login.id == "login-1")
        }
        for url in ["http://auth.openai.com/login", "https://other.example/login",
                    "https://auth.openai.com.evil.example/login", "https://user:pass@auth.openai.com/login",
                    "https://auth.openai.com:444/login", "file:///example"] {
            #expect(throws: (any Error).self) {
                try ChatGPTLogin.parse(["type": "chatgpt", "loginId": "login-1", "authUrl": url])
            }
        }
    }

    @Test func quotaWindowsComeFromProviderWithoutManualAllowance() throws {
        let snapshot = try CodexProtocol.rateLimits(object(#"""
        {"rateLimits":{"primary":{"usedPercent":17,"windowDurationMins":300,"resetsAt":1900000000},
                       "secondary":{"usedPercent":72,"windowDurationMins":10080,"resetsAt":1900600000}}}
        """#))
        #expect(snapshot.windows.count == 2)
        #expect(snapshot.windows.map(\.label) == ["5-hour", "Weekly"])
        #expect(snapshot.windows.map(\.usedPercent) == [17, 72])
        #expect(snapshot.windows[0].resetsAt == Date(timeIntervalSince1970: 1_900_000_000))
        #expect(snapshot.windows.allSatisfy { $0.isUserProvidedAllowance != true })
        #expect(AlertPolicy.evaluate(snapshot.windows[1], previous: nil).threshold == 70)
    }

    @Test func multiBucketQuotasAreNotDuplicated() throws {
        let snapshot = try CodexProtocol.rateLimits(object(#"""
        {"rateLimits":{"primary":{"usedPercent":17,"windowDurationMins":300}},
         "rateLimitsByLimitId":{
           "codex":{"primary":{"usedPercent":17,"windowDurationMins":300}},
           "spark":{"limitName":"Spark","primary":{"usedPercent":100,"windowDurationMins":300}}}}
        """#))
        #expect(snapshot.windows.count == 2)
        #expect(snapshot.windows.contains { $0.label == "Spark · 5-hour" && $0.usedPercent == 100 })
    }

    @Test func singleWeeklyPrimaryIsNotMislabelledAsFiveHours() throws {
        let snapshot = try CodexProtocol.rateLimits(object(#"""
        {"rateLimits":{"primary":{"usedPercent":42,"windowDurationMins":10080},"secondary":null}}
        """#))
        #expect(snapshot.windows.count == 1)
        #expect(snapshot.windows[0].label == "Weekly")
    }

    @Test func malformedQuotaDataIsNeverZeroUsage() throws {
        for json in [
            "{}",
            #"{"rateLimits":{"primary":{"windowDurationMins":300}}}"#,
            #"{"rateLimits":{"primary":{"usedPercent":true,"windowDurationMins":300}}}"#,
            #"{"rateLimits":{"primary":{"usedPercent":-1,"windowDurationMins":300}}}"#,
            #"{"rateLimits":{"primary":{"usedPercent":10,"windowDurationMins":0}}}"#
        ] {
            #expect(throws: (any Error).self) { try CodexProtocol.rateLimits(object(json)) }
        }
    }

    @Test func legacyBucketCanRecoverMalformedMultiBucketResponse() throws {
        let snapshot = try CodexProtocol.rateLimits(object(#"""
        {"rateLimitsByLimitId":{"codex":{}},"rateLimits":{"primary":{"usedPercent":0.7,"windowDurationMins":300}}}
        """#))
        #expect(snapshot.windows[0].usedPercent == 0.7)
    }

    @Test func managedAccountStorageRoundTrips() throws {
        let account = Account(provider: .openAI, email: "user@example.com", source: .codexAppServer,
                              credentialPath: "/example/isolated-home")
        #expect(try JSONDecoder().decode(Account.self, from: JSONEncoder().encode(account)) == account)
    }

    @Test func onlyIsolatedUsageHomesCanBeUsedForManagedSessions() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("UsageProtocolTest")
        let home = CodexProtocol.sessionHome(root: root, id: UUID())
        #expect(try CodexProtocol.validateSessionHome(home.path, root: root).path == home.path)
        for path in ["/Users/example/.codex", root.path, root.appendingPathComponent("not-a-uuid").path,
                     root.appendingPathComponent("../\(UUID().uuidString)").path] {
            #expect(throws: (any Error).self) { try CodexProtocol.validateSessionHome(path, root: root) }
        }
    }
}
