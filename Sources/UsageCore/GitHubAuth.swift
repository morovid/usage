import Foundation

public struct GitHubDeviceAuthorization: Decodable, Sendable {
    public let deviceCode: String
    public let userCode: String
    public let verificationURI: URL
    public let expiresIn: Int
    public let interval: Int
    enum CodingKeys: String, CodingKey {
        case deviceCode = "device_code", userCode = "user_code", verificationURI = "verification_uri"
        case expiresIn = "expires_in", interval
    }
}

public struct GitHubIdentity: Decodable, Sendable {
    public let id: Int64
    public let login: String
}

private struct GitHubTokenResponse: Decodable {
    var accessToken: String?
    var tokenType: String?
    var refreshToken: String?
    var expiresIn: Int?
    var refreshTokenExpiresIn: Int?
    var error: String?
    var interval: Int?
    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token", tokenType = "token_type", refreshToken = "refresh_token"
        case expiresIn = "expires_in", refreshTokenExpiresIn = "refresh_token_expires_in"
        case error, interval
    }

    func credential(clientID: String, now: Date = Date()) throws -> Credential {
        guard let accessToken, !accessToken.isEmpty,
              tokenType?.lowercased() == "bearer",
              expiresIn == nil || (expiresIn ?? 0) > 0,
              expiresIn == nil || refreshToken?.isEmpty == false else {
            throw UsageError.message("GitHub returned an incomplete authorization. Please sign in again.")
        }
        return Credential(accessToken: accessToken, refreshToken: refreshToken,
                          expiresAt: expiresIn.map { now.addingTimeInterval(Double($0)) },
                          refreshTokenExpiresAt: refreshTokenExpiresIn.map { now.addingTimeInterval(Double($0)) },
                          oauthClientID: clientID)
    }
}

/// GitHub App device authorization. No client secret, browser cookies, or borrowed client IDs.
public final class GitHubAuth: @unchecked Sendable {
    public static let clientID = "Iv23li89IJLYqBiDzGoi"
    private let session: URLSession
    private let sleep: @Sendable (TimeInterval) async throws -> Void

    public init(session: URLSession? = nil,
                sleep: @escaping @Sendable (TimeInterval) async throws -> Void = {
                    try await Task.sleep(for: .seconds($0))
                }) {
        if let session { self.session = session } else {
            let config = URLSessionConfiguration.ephemeral
            config.httpShouldSetCookies = false
            config.urlCache = nil
            config.timeoutIntervalForRequest = 20
            config.timeoutIntervalForResource = 30
            self.session = URLSession(configuration: config, delegate: NoRedirectDelegate(), delegateQueue: nil)
        }
        self.sleep = sleep
    }

    public func begin() async throws -> GitHubDeviceAuthorization {
        let data = try await post(path: "/login/device/code",
                                  fields: ["client_id": Self.clientID, "scope": "offline_access"])
        let possibleError = try JSONDecoder().decode(GitHubTokenResponse.self, from: data)
        if let error = possibleError.error { throw authError(error) }
        let authorization = try JSONDecoder().decode(GitHubDeviceAuthorization.self, from: data)
        guard authorization.expiresIn > 0, authorization.expiresIn <= 3_600,
              authorization.interval > 0, authorization.interval <= 60,
              !authorization.deviceCode.isEmpty, !authorization.userCode.isEmpty,
              authorization.verificationURI.scheme == "https",
              authorization.verificationURI.host == "github.com",
              authorization.verificationURI.path == "/login/device",
              authorization.verificationURI.user == nil, authorization.verificationURI.password == nil else {
            throw UsageError.message("GitHub returned an unexpected device authorization.")
        }
        return authorization
    }

    public func complete(_ authorization: GitHubDeviceAuthorization) async throws -> Credential {
        let deadline = Date().addingTimeInterval(Double(authorization.expiresIn))
        var interval = Double(authorization.interval)
        while Date() < deadline {
            try Task.checkCancellation()
            try await sleep(interval)
            try Task.checkCancellation()
            guard Date() < deadline else { break }
            let data = try await post(path: "/login/oauth/access_token", fields: [
                "client_id": Self.clientID, "device_code": authorization.deviceCode,
                "grant_type": "urn:ietf:params:oauth:grant-type:device_code"
            ])
            let response = try JSONDecoder().decode(GitHubTokenResponse.self, from: data)
            switch response.error {
            case "authorization_pending": continue
            case "slow_down":
                interval = max(interval + 5, Double(response.interval ?? 0))
                continue
            case .some(let error): throw authError(error)
            case nil: return try response.credential(clientID: Self.clientID)
            }
        }
        throw authError("expired_token")
    }

    public func identity(credential: Credential) async throws -> GitHubIdentity {
        var request = URLRequest(url: URL(string: "https://api.github.com/user")!)
        request.setValue("Bearer \(credential.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Usage/1.0", forHTTPHeaderField: "User-Agent")
        let data = try await send(request)
        let identity = try JSONDecoder().decode(GitHubIdentity.self, from: data)
        guard identity.id > 0, !identity.login.isEmpty else {
            throw UsageError.message("GitHub did not return an account identity.")
        }
        return identity
    }

    public func refresh(_ credential: Credential) async throws -> Credential {
        guard let refreshToken = credential.refreshToken, !refreshToken.isEmpty,
              let clientID = credential.oauthClientID, clientID == Self.clientID else {
            throw UsageError.message("Please sign in to GitHub again to renew this session.")
        }
        if let expiry = credential.refreshTokenExpiresAt, expiry <= Date() {
            throw UsageError.message("Your GitHub session has expired. Please sign in again.")
        }
        let data = try await post(path: "/login/oauth/access_token", fields: [
            "client_id": clientID, "grant_type": "refresh_token", "refresh_token": refreshToken
        ])
        let response = try JSONDecoder().decode(GitHubTokenResponse.self, from: data)
        if let error = response.error { throw authError(error) }
        var updated = try response.credential(clientID: clientID)
        updated.accountID = credential.accountID
        return updated
    }

    private func post(path: String, fields: [String: String]) async throws -> Data {
        var request = URLRequest(url: URL(string: "https://github.com" + path)!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Usage/1.0", forHTTPHeaderField: "User-Agent")
        request.httpBody = Self.formBody(fields)
        return try await send(request)
    }

    public static func formBody(_ fields: [String: String]) -> Data {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        let encoded = fields.sorted { $0.key < $1.key }.map {
            "\($0.key.addingPercentEncoding(withAllowedCharacters: allowed)!)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed)!)"
        }.joined(separator: "&")
        return Data(encoded.utf8)
    }

    private func send(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse else { throw UsageError.message("Invalid GitHub response.") }
        guard (200...299).contains(http.statusCode) else {
            throw UsageError.message("GitHub authorization request failed (HTTP \(http.statusCode)).")
        }
        guard data.count <= 1_000_000 else { throw UsageError.message("GitHub returned an oversized response.") }
        // Error descriptions/bodies are deliberately not surfaced: they may contain secrets.
        return data
    }

    private func authError(_ code: String) -> UsageError {
        let message: String
        switch code {
        case "device_flow_disabled": message = "Enable Device Flow in the Usage GitHub App's settings, then try again."
        case "incorrect_client_credentials": message = "GitHub rejected Usage's Client ID. Check the GitHub App registration."
        case "access_denied": message = "GitHub sign-in was declined. You can try again."
        case "expired_token", "token_expired": message = "The GitHub sign-in code expired. Start sign-in again."
        case "bad_refresh_token": message = "GitHub could not renew your session. Please sign in again."
        default: message = "GitHub could not authorize Usage. Please try signing in again."
        }
        return UsageError.message(message)
    }
}
