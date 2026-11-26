import Foundation

/// Do not follow redirects with credentials or accept cookies from provider responses.
final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

public final class UsageClient: @unchecked Sendable {
    private let session: URLSession
    public init(session: URLSession? = nil) {
        if let session { self.session = session; return }
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 30
        config.httpShouldSetCookies = false
        config.urlCache = nil
        self.session = URLSession(configuration: config, delegate: NoRedirectDelegate(), delegateQueue: nil)
    }

    public func fetch(account: Account, credential: Credential) async throws -> UsageSnapshot {
        if account.isAPI {
            return try await APIBillingClient(session: session).fetch(account: account, credential: credential)
        }
        let url: URL
        switch account.provider {
        case .anthropic: url = URL(string: "https://api.anthropic.com/api/oauth/usage")!
        case .openAI: url = URL(string: "https://chatgpt.com/backend-api/wham/usage")!
        case .moonshot:
            url = URL(string: "https://\(account.kimiInternational ? "api.kimi.ai" : "api.kimi.com")/coding/v1/usages")!
        case .deepSeek: throw UsageError.message("DeepSeek has no subscription quotas. Use an API account.")
        case .openCode: url = URL(string: "https://opencode.ai/inference/go/v1/usage")!
        case .githubCopilot: url = URL(string: "https://api.github.com/copilot_internal/user")!
        }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(credential.accessToken)", forHTTPHeaderField: "Authorization")
        if account.provider == .githubCopilot {
            request.setValue("token \(credential.accessToken)", forHTTPHeaderField: "Authorization")
        }
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Usage/1.0 (macOS; usage monitor)", forHTTPHeaderField: "User-Agent")
        if account.provider == .anthropic {
            request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        }
        if account.provider == .openAI, let id = credential.accountID, !id.isEmpty {
            request.setValue(id, forHTTPHeaderField: "ChatGPT-Account-Id")
        }
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw UsageError.message("Invalid HTTP response.") }
        switch response.statusCode {
        case 200...299: break
        case 401:
            if account.provider == .anthropic {
                throw UsageError.message("Claude rejected the imported session. Its access token may be expired or revoked. Choose Sign in with Claude, or run `claude auth login` and import again.")
            }
            if account.provider == .moonshot, credential.oauthClientID != nil {
                throw UsageError.message("Kimi sign-in expired or was revoked. Edit this account and sign in again with Kimi.")
            }
            throw UsageError.message("Sign-in expired or credential rejected. Sign in with the official CLI and reimport, or replace your token.")
        case 403:
            if account.provider == .githubCopilot {
                throw UsageError.message("GitHub denied Copilot quota access (HTTP 403). The internal quota endpoint may not accept this GitHub App's token. Successful GitHub sign-in does not guarantee quota access.")
            }
            throw UsageError.message("Access denied. Check that this credential has an eligible subscription and usage access.")
        case 429:
            throw UsageError.message("Provider rate limit reached. Refreshing will retry after a cooldown.")
        default:
            // Never put response bodies (which may contain secrets) into UI, logs or notifications.
            throw UsageError.message("The provider returned HTTP \(response.statusCode).")
        }
        guard data.count <= 2_000_000 else { throw UsageError.message("The provider response is too large.") }
        return try UsageParser.parse(data, provider: account.provider,
                                     copilotMonthlyAllowance: account.copilotMonthlyAllowance)
    }
}
