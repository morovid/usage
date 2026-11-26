import Foundation
import Testing
@testable import UsageCore

@Test func importsSupportedOpenCodeProvidersWithoutCopyingRefreshTokens() throws {
    let document: [String: Any] = [
        "github-copilot": ["type": "oauth", "access": "github-access", "refresh": "never-copy", "expires": 0],
        "deepseek": ["type": "api", "key": "deepseek-key"],
        "moonshotai": ["type": "api", "key": "global-moonshot-key"],
        "opencode-go": ["type": "api", "key": "go-key"]
    ]
    for id in ["github-copilot", "deepseek", "moonshotai", "opencode-go"] {
        let credential = try OpenCodeCredentialImport.parse(document: document, providerID: id)
        #expect(!credential.accessToken.isEmpty)
        #expect(credential.refreshToken == nil)
    }
    #expect(try OpenCodeCredentialImport.parse(document: document, providerID: "github-copilot").accessToken == "github-access")
}

@Test func refusesUnsupportedExpiredAndMalformedOpenCodeEntries() {
    let document: [String: Any] = [
        "github-copilot": ["type": "oauth", "access": "expired-secret", "expires": 1000],
        "deepseek": ["type": "api", "key": "secret\nvalue"],
        "moonshotai-cn": ["type": "api", "key": "china-key"],
        "zai-coding-plan": ["type": "api", "key": "zai-key"],
        "openai": ["type": "oauth", "access": "openai-token", "refresh": "rotating-token"]
    ]
    for id in ["github-copilot", "deepseek", "moonshotai-cn", "zai-coding-plan", "openai"] {
        do {
            _ = try OpenCodeCredentialImport.parse(document: document, providerID: id)
            Issue.record("Should reject this credential")
        } catch {
            #expect(!error.localizedDescription.contains("secret"))
        }
    }
}

@Test func detectsSupportedOpenCodeAccountsAndOmitsExpiredClaude() throws {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: home) }
    func write(_ path: String, _ data: String) throws {
        let url = home.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(data.utf8).write(to: url)
    }
    try write(".claude/.credentials.json", #"{"claudeAiOauth":{"accessToken":"expired","expiresAt":1000}}"#)
    try write(".local/share/opencode/auth.json", """
    {"github-copilot":{"type":"oauth","access":"github-token","expires":0},
     "deepseek":{"type":"api","key":"deepseek-key"},
     "moonshotai":{"type":"api","key":"moonshot-key"},
     "moonshotai-cn":{"type":"api","key":"china-key"},
     "openrouter":{"type":"api","key":"router-key"},
     "zai-coding-plan":{"type":"api","key":"zai-key"}}
    """)
    let found = LocalHarnessDetection.scan(home: home, environment: [:])
    #expect(found.map(\.kind) == [.openCodeCopilot, .openCodeDeepSeek, .openCodeMoonshot])
    #expect(found.map(\.isAPI) == [false, true, true])
    #expect(found.map(\.provider) == [.githubCopilot, .deepSeek, .moonshot])
}

@Test func claudeExpiryUsesMillisecondsAndAllowsUnknownExpiry() {
    let now = Date(timeIntervalSince1970: 100)
    #expect(LocalHarnessDetection.claudeTokenExpired(["expiresAt": 99_000.0], now: now))
    #expect(!LocalHarnessDetection.claudeTokenExpired(["expiresAt": 101_000.0], now: now))
    #expect(!LocalHarnessDetection.claudeTokenExpired([:], now: now))
}
