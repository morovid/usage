import Foundation
import Testing
@testable import UsageCore

@Test func discoversOnlySupportedLocalSessions() throws {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: home) }
    func write(_ path: String, _ text: String) throws {
        let url = home.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }
    try write(".claude/.credentials.json", #"{"claudeAiOauth":{"accessToken":"claude-test"}}"#)
    try write(".claude.json", #"{"oauthAccount":{"emailAddress":"person@example.com","accountUuid":"claude-id"}}"#)
    try write(".local/share/opencode/auth.json", #"{"opencode-go":{"type":"api","key":"oc-test"},"other":{"type":"api","key":"unrelated"}}"#)
    try write(".dsh/.credentials.yaml", "version: 1\nrefs:\n  DEEPSEEK_API_KEY: sk-test\n")
    try write(".codex/auth.json", #"{"tokens":{"access_token":"codex-test","account_id":"codex-id"}}"#)
    let candidates = LocalHarnessDetection.scan(home: home, environment: [:])
    // Installed/signed-in Codex is intentionally excluded: adding it needs another login.
    #expect(candidates.map(\.kind) == [.claudeCode, .openCode, .deepSeek])
    #expect(candidates.first?.name == "person@example.com")
    #expect(candidates.first?.accountID == "claude-id")
    #expect(candidates.first?.fingerprint != "claude-test")
}

@Test func discoveryRespectsExplicitHomesAndIgnoresMalformedFiles() throws {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: home) }
    let custom = home.appendingPathComponent("custom/opencode")
    try FileManager.default.createDirectory(at: custom, withIntermediateDirectories: true)
    let auth = custom.appendingPathComponent("auth.json")
    try Data(#"{"opencode-go":{"type":"api","key":"oc-custom"}}"#.utf8).write(to: auth)
    let found = LocalHarnessDetection.scan(home: home, environment: ["XDG_DATA_HOME": custom.deletingLastPathComponent().path])
    #expect(found.map(\.kind) == [.openCode])
    try Data("invalid-json-secret".utf8).write(to: auth)
    #expect(LocalHarnessDetection.scan(home: home, environment: ["XDG_DATA_HOME": custom.deletingLastPathComponent().path]).isEmpty)
}

@Test func detectionsExcludeAddedCredentialsWithoutKeychainReads() throws {
    let credential = Credential(accessToken: "test-token")
    let fingerprint = LocalHarnessDetection.fingerprint(credential)
    let detected = DetectedHarness(kind: .openCode, fingerprint: fingerprint)
    var account = Account(provider: .openCode, email: "Custom name")
    #expect(!detected.isAdded(accounts: [account]))
    #expect(detected.isAdded(accounts: [account], cachedFingerprints: [account.id: fingerprint]))
    account.importFingerprint = fingerprint
    #expect(detected.isAdded(accounts: [account]))
    let decoded = try JSONDecoder().decode(Account.self, from: JSONEncoder().encode(account))
    #expect(decoded.importFingerprint == fingerprint)
    #expect(!detected.isAdded(accounts: [Account(provider: .deepSeek, email: "Other", apiAccess: true)]))
}

@Test func detectionsMatchLegacyIdentityButNotAPIAccounts() {
    let detected = DetectedHarness(kind: .claudeCode, name: "person@example.com", accountID: "account-id")
    #expect(detected.isAdded(accounts: [Account(provider: .anthropic, email: "Person@example.com")]))
    #expect(detected.isAdded(accounts: [Account(provider: .anthropic, email: "Work", externalAccountID: "account-id")]))
    #expect(!detected.isAdded(accounts: [Account(provider: .anthropic, email: "person@example.com", apiAccess: true)]))
}

@Test func dismissedDetectionIdentitySurvivesTokenChanges() {
    let before = DetectedHarness(kind: .claudeCode, name: "person@example.com", fingerprint: "old", accountID: "account")
    let after = DetectedHarness(kind: .claudeCode, name: "renamed@example.com", fingerprint: "new", accountID: "account")
    #expect(before.dismissalID == after.dismissalID)
    #expect(before.dismissalID != DetectedHarness(kind: .claudeCode, accountID: "another-account").dismissalID)
    #expect(DetectedHarness(kind: .openCode, fingerprint: "old").dismissalID ==
            DetectedHarness(kind: .openCode, fingerprint: "new").dismissalID)
    #expect(DetectedHarness(kind: .openCode).dismissalID != DetectedHarness(kind: .deepSeek).dismissalID)
}
