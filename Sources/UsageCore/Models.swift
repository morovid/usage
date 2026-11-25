import Foundation

public enum Provider: String, Codable, CaseIterable, Identifiable, Sendable {
    case anthropic, openAI, moonshot, openCode, githubCopilot
    public var id: String { rawValue }
    public var name: String {
        switch self {
        case .anthropic: "Anthropic"
        case .openAI: "OpenAI"
        case .moonshot: "Moonshot"
        case .openCode: "OpenCode"
        case .githubCopilot: "GitHub Copilot"
        }
    }
    public var product: String {
        switch self {
        case .anthropic: "Claude subscription"
        case .openAI: "ChatGPT / Codex subscription"
        case .moonshot: "Kimi Code subscription"
        case .openCode: "OpenCode Go subscription"
        case .githubCopilot: "GitHub Copilot subscription"
        }
    }
    public var consoleURL: URL {
        switch self {
        case .anthropic: URL(string: "https://claude.ai/settings/usage")!
        case .openAI: URL(string: "https://chatgpt.com/codex/settings/usage")!
        case .moonshot: URL(string: "https://www.kimi.com/code/console")!
        case .openCode: URL(string: "https://opencode.ai/console")!
        case .githubCopilot: URL(string: "https://github.com/settings/copilot")!
        }
    }
    public var credentialHelp: String {
        switch self {
        case .anthropic:
            "Sign in with the official Claude Code CLI, import an existing CLI session, or paste an OAuth access token. Standard Anthropic API keys do not expose subscription quotas; choose API key for organization billing instead. Imported tokens must be reimported when they expire."
        case .openAI:
            "Sign in with ChatGPT in your browser. Usage uses the official Codex CLI to manage sign-in and refresh in an isolated account session. Reported ChatGPT/Codex quota windows are monitored; these are not total usage across all ChatGPT products."
        case .moonshot:
            "Sign in with Kimi for a Global Kimi Code subscription, or use a subscription API key from the matching region's console. Moonshot pay-as-you-go API keys do not expose subscription quotas."
        case .openCode:
            "Use an API key from an OpenCode workspace with an active Go subscription. Zen pay-as-you-go balances are not subscription usage limits."
        case .githubCopilot:
            "Sign in on GitHub and authorize Usage using the displayed code. Usage will retrieve your username and test access to your Copilot quotas. GitHub Enterprise Server hosts are not supported."
        }
    }
    public var usesEmailLabel: Bool { self == .anthropic || self == .openAI }
    public var supportsAPIBilling: Bool { [.anthropic, .openAI, .moonshot].contains(self) }
    public var apiCredentialHelp: String {
        switch self {
        case .anthropic:
            "Enter a Claude Console organization Admin API key with analytics access. Ordinary inference keys and Claude subscription tokens cannot read API billing. Shows organization-wide month-to-date USD costs after discounts and before credits. Analytics can lag by 4–24 hours and exclude Priority Tier commitment fees."
        case .openAI:
            "Enter an organization Admin API key with permission to read costs. Ordinary project/model API keys do not provide billing access. Usage shows organization-wide month-to-date spend in USD, not remaining credits or ChatGPT quotas."
        case .moonshot:
            "Enter a Global Moonshot Open Platform API key. Usage shows your available USD balance, including vouchers—not Kimi Code quotas. China-region API keys are not supported."
        default: ""
        }
    }
    public var apiConsoleURL: URL {
        switch self {
        case .anthropic: URL(string: "https://platform.claude.com/settings/admin-keys")!
        case .openAI: URL(string: "https://platform.openai.com/settings/organization/admin-keys")!
        case .moonshot: URL(string: "https://platform.kimi.ai/console/api-keys")!
        default: consoleURL
        }
    }
}

public enum CredentialSource: String, Codable, Sendable {
    case keychain, codexFile, codexAppServer
}

public struct Account: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var provider: Provider
    /// Historical storage key; also holds a display name for non-email providers.
    public var email: String
    public var source: CredentialSource
    public var credentialPath: String?
    public var externalAccountID: String?
    public var kimiInternational: Bool
    public var copilotMonthlyAllowance: Double?
    /// Missing on older accounts, which are always subscription accounts.
    public var apiAccess: Bool?
    public var isAPI: Bool { apiAccess == true }
    public var displayProviderName: String { provider == .openCode ? "OpenCode Go" : provider.name + (isAPI ? " API" : "") }

    public init(id: UUID = UUID(), provider: Provider, email: String,
                source: CredentialSource = .keychain, credentialPath: String? = nil,
                externalAccountID: String? = nil, kimiInternational: Bool = false,
                copilotMonthlyAllowance: Double? = nil, apiAccess: Bool? = nil) {
        self.id = id
        self.provider = provider
        self.email = email
        self.source = source
        self.credentialPath = credentialPath
        self.externalAccountID = externalAccountID
        self.kimiInternational = kimiInternational
        self.copilotMonthlyAllowance = copilotMonthlyAllowance
        self.apiAccess = apiAccess
    }
}

public struct Credential: Codable, Sendable {
    public var accessToken: String
    public var accountID: String?
    public var refreshToken: String?
    public var expiresAt: Date?
    public var refreshTokenExpiresAt: Date?
    public var oauthClientID: String?
    public init(accessToken: String, accountID: String? = nil, refreshToken: String? = nil,
                expiresAt: Date? = nil, refreshTokenExpiresAt: Date? = nil, oauthClientID: String? = nil) {
        self.accessToken = accessToken
        self.accountID = accountID
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.refreshTokenExpiresAt = refreshTokenExpiresAt
        self.oauthClientID = oauthClientID
    }
}

public struct UsageWindow: Identifiable, Codable, Equatable, Sendable {
    public var id: String
    public var label: String
    public var usedPercent: Double
    public var duration: TimeInterval
    public var resetsAt: Date?
    public var usedCredits: Double?
    public var creditAllowance: Double?
    public var isUserProvidedAllowance: Bool?

    public init(id: String, label: String, usedPercent: Double,
                duration: TimeInterval, resetsAt: Date? = nil, usedCredits: Double? = nil,
                creditAllowance: Double? = nil, isUserProvidedAllowance: Bool? = nil) {
        self.id = id
        self.label = label
        self.usedPercent = min(100, max(0, usedPercent.isFinite ? usedPercent : 0))
        self.duration = duration
        self.resetsAt = resetsAt
        self.usedCredits = usedCredits
        self.creditAllowance = creditAllowance
        self.isUserProvidedAllowance = isUserProvidedAllowance
    }
}

public struct UsageSnapshot: Codable, Sendable {
    public var windows: [UsageWindow]
    public var fetchedAt: Date
    public var billing: APIBillingSummary?
    public init(windows: [UsageWindow], fetchedAt: Date = Date(), billing: APIBillingSummary? = nil) {
        self.billing = billing
        self.windows = windows.sorted {
            $0.duration == $1.duration ? $0.id < $1.id : $0.duration < $1.duration
        }
        self.fetchedAt = fetchedAt
    }
    /// Keep the compact view to two meters, without hiding other limits from alerts.
    public var prominentWindows: [UsageWindow] {
        guard windows.count > 2, let first = windows.first, let last = windows.last else { return windows }
        // At the same duration, display the most constrained scope rather than an arbitrary model.
        let shortest = windows.filter { $0.duration == first.duration }.max { $0.usedPercent < $1.usedPercent }!
        let longest = windows.filter { $0.duration == last.duration }.max { $0.usedPercent < $1.usedPercent }!
        if shortest.id == longest.id { return [shortest] }
        return [shortest, longest]
    }
}

public enum UsageError: LocalizedError {
    case message(String)
    public var errorDescription: String? {
        switch self { case .message(let text): text }
    }
}
