import CryptoKit
import Foundation

public struct DetectedHarness: Identifiable, Sendable {
    public enum Kind: String, Sendable {
        case claudeCode, openCode, deepSeek, openCodeCopilot, openCodeDeepSeek, openCodeMoonshot
    }
    public let kind: Kind
    public let name: String?
    public let fingerprint: String?
    public let accountID: String?
    public var id: String { kind.rawValue }
    /// Stable across token refreshes. Unknown identities refer to the harness's
    /// single default credential slot, not to its current access token.
    public var dismissalID: String {
        let identity = accountID ?? name?.lowercased() ?? "default"
        let digest = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
        return "\(kind.rawValue):\(digest)"
    }
    public var provider: Provider {
        switch kind {
        case .claudeCode: .anthropic
        case .openCode: .openCode
        case .deepSeek: .deepSeek
        case .openCodeCopilot: .githubCopilot
        case .openCodeDeepSeek: .deepSeek
        case .openCodeMoonshot: .moonshot
        }
    }
    public var title: String {
        switch kind {
        case .claudeCode: "Claude Code"
        case .openCode: "OpenCode Go"
        case .deepSeek: "DeepSeek Harness"
        case .openCodeCopilot: "GitHub Copilot · OpenCode"
        case .openCodeDeepSeek: "DeepSeek API · OpenCode"
        case .openCodeMoonshot: "Moonshot API · OpenCode"
        }
    }
    public var isAPI: Bool { kind == .deepSeek || kind == .openCodeDeepSeek || kind == .openCodeMoonshot }
    public var openCodeProviderID: String? {
        switch kind {
        case .openCode: "opencode-go"
        case .openCodeCopilot: "github-copilot"
        case .openCodeDeepSeek: "deepseek"
        case .openCodeMoonshot: "moonshotai"
        default: nil
        }
    }
    public init(kind: Kind, name: String? = nil, fingerprint: String? = nil, accountID: String? = nil) {
        self.kind = kind; self.name = name; self.fingerprint = fingerprint; self.accountID = accountID
    }

    public func isAdded(accounts: [Account], cachedFingerprints: [UUID: String] = [:]) -> Bool {
        accounts.contains { account in
            guard account.provider == provider else { return false }
            guard account.isAPI == isAPI else { return false }
            if kind == .claudeCode, account.isAPI { return false }
            if let fingerprint, fingerprint == account.importFingerprint || fingerprint == cachedFingerprints[account.id] { return true }
            if let accountID, account.externalAccountID == accountID { return true }
            // Claude identity metadata also supports accounts saved before fingerprinting.
            if kind == .claudeCode, let name,
               account.email.caseInsensitiveCompare(name) == .orderedSame { return true }
            return false
        }
    }
}

public enum LocalHarnessDetection {
    public static func fingerprint(_ credential: Credential) -> String {
        SHA256.hash(data: Data(credential.accessToken.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// No network, subprocesses, writes or Keychain access. Only known user-level locations.
    public static func scan(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                            environment: [String: String] = ProcessInfo.processInfo.environment) -> [DetectedHarness] {
        var result: [DetectedHarness] = []
        let claudeHome = directory(environment["CLAUDE_CONFIG_DIR"], fallback: home.appendingPathComponent(".claude"))
        let metadata = json(home.appendingPathComponent(".claude.json"))?["oauthAccount"] as? [String: Any]
        if let oauth = json(claudeHome.appendingPathComponent(".credentials.json"))?["claudeAiOauth"] as? [String: Any],
           !claudeTokenExpired(oauth),
           let token = oauth["accessToken"] as? String, !token.isEmpty {
            result.append(DetectedHarness(kind: .claudeCode, name: metadata?["emailAddress"] as? String,
                                          fingerprint: fingerprint(Credential(accessToken: token)),
                                          accountID: metadata?["accountUuid"] as? String))
        }
        let dataHome = directory(environment["XDG_DATA_HOME"], fallback: home.appendingPathComponent(".local/share"))
        if let document = json(dataHome.appendingPathComponent("opencode/auth.json")) {
            for kind: DetectedHarness.Kind in [.openCode, .openCodeCopilot, .openCodeDeepSeek, .openCodeMoonshot] {
                let candidate = DetectedHarness(kind: kind)
                if let id = candidate.openCodeProviderID,
                   let credential = try? OpenCodeCredentialImport.parse(document: document, providerID: id) {
                    result.append(DetectedHarness(kind: kind, fingerprint: fingerprint(credential)))
                }
            }
        }
        let dshHome = directory(environment["DSH_HOME"], fallback: home.appendingPathComponent(".dsh"))
        if let credential = try? DeepSeekHarnessImport.read(home: dshHome) {
            result.append(DetectedHarness(kind: .deepSeek, fingerprint: fingerprint(credential)))
        }
        return result
    }

    public static func claudeTokenExpired(_ oauth: [String: Any], now: Date = Date()) -> Bool {
        guard let expiry = UsageParser.number(oauth["expiresAt"]) else { return oauth["expiresAt"] != nil }
        return !expiry.isFinite || expiry / 1000 <= now.timeIntervalSince1970
    }

    private static func directory(_ value: String?, fallback: URL) -> URL {
        guard let value, !value.isEmpty, value.hasPrefix("/") else { return fallback }
        return URL(fileURLWithPath: value)
    }

    private static func json(_ url: URL) -> [String: Any]? {
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 1_000_000,
              let data = try? Data(contentsOf: url) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}
