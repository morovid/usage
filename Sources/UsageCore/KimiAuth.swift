import Foundation

public struct KimiDeviceAuthorization: Decodable, Sendable {
    public let deviceCode: String
    public let userCode: String
    public let verificationURI: URL
    public let expiresIn: Int
    public let interval: Int
    enum CodingKeys: String, CodingKey {
        case deviceCode = "device_code", userCode = "user_code"
        case verificationURI = "verification_uri_complete", expiresIn = "expires_in", interval
    }
}

public struct KimiIdentity: Decodable, Sendable {
    public let userID: String
    public let nickname: String?
    public let email: String?
    public var label: String {
        [email, nickname, userID].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty } ?? "Kimi account"
    }
    enum CodingKeys: String, CodingKey { case userID = "user_id", nickname, email }
}

private struct KimiTokenResponse: Decodable {
    let accessToken: String?
    let refreshToken: String?
    let expiresIn: Double?
    let tokenType: String?
    let error: String?
    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token", refreshToken = "refresh_token"
        case expiresIn = "expires_in", tokenType = "token_type", error
    }
    func credential(now: Date = Date()) throws -> Credential {
        guard let accessToken, !accessToken.isEmpty,
              let refreshToken, !refreshToken.isEmpty,
              let expiresIn, expiresIn.isFinite, expiresIn > 0,
              tokenType == nil || tokenType?.lowercased() == "bearer",
              !accessToken.contains(where: \.isNewline), !refreshToken.contains(where: \.isNewline) else {
            throw UsageError.message("Kimi returned an incomplete authorization. Please sign in again.")
        }
        return Credential(accessToken: accessToken, refreshToken: refreshToken,
                          expiresAt: now.addingTimeInterval(expiresIn), oauthClientID: KimiAuth.clientID)
    }
}

/// Global-only Kimi device protocol, as published in MoonshotAI/kimi-code's OAuth toolkit.
/// Uses Usage's own product identity, not CLI impersonation. No region discovery or China fallback.
public final class KimiAuth: @unchecked Sendable {
    public static let clientID = "17e5f671-d194-4dfb-9706-5516cb48c098"
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

    public func begin() async throws -> KimiDeviceAuthorization {
        let (data, status) = try await post(path: "device_authorization", fields: ["client_id": Self.clientID])
        guard status == 200 else { throw failure(status: status) }
        let authorization = try JSONDecoder().decode(KimiDeviceAuthorization.self, from: data)
        let url = authorization.verificationURI
        guard authorization.expiresIn > 0, authorization.expiresIn <= 3_600,
              authorization.interval > 0, authorization.interval <= 60,
              !authorization.deviceCode.isEmpty, !authorization.userCode.isEmpty,
              url.scheme == "https", ["auth.kimi.ai", "www.kimi.ai", "kimi.ai"].contains(url.host ?? ""),
              url.user == nil, url.password == nil, url.port == nil else {
            throw UsageError.message("Kimi returned an unexpected global sign-in URL or device code.")
        }
        return authorization
    }

    public func complete(_ authorization: KimiDeviceAuthorization) async throws -> Credential {
        let deadline = Date().addingTimeInterval(Double(authorization.expiresIn))
        var interval = Double(authorization.interval)
        while Date() < deadline {
            try Task.checkCancellation()
            try await sleep(interval)
            try Task.checkCancellation()
            guard Date() < deadline else { break }
            let (data, status) = try await post(path: "token", fields: [
                "client_id": Self.clientID, "device_code": authorization.deviceCode,
                "grant_type": "urn:ietf:params:oauth:grant-type:device_code"
            ])
            guard status == 200 || status == 400 else { throw failure(status: status) }
            let response = try JSONDecoder().decode(KimiTokenResponse.self, from: data)
            switch response.error {
            case "authorization_pending": continue
            case "slow_down": interval += 5; continue
            case "access_denied": throw UsageError.message("Kimi sign-in was declined. You can try again.")
            case "expired_token": throw UsageError.message("The Kimi sign-in code expired. Start sign-in again.")
            case .some: throw failure(status: status)
            case nil:
                guard status == 200 else { throw failure(status: status) }
                return try response.credential()
            }
        }
        throw UsageError.message("The Kimi sign-in code expired. Start sign-in again.")
    }

    public func identity(credential: Credential) async throws -> KimiIdentity {
        var request = URLRequest(url: URL(string: "https://api.kimi.ai/coding/v1/me")!)
        request.setValue("Bearer \(credential.accessToken)", forHTTPHeaderField: "Authorization")
        let (data, status) = try await send(request)
        guard status == 200 else { throw failure(status: status) }
        let identity = try JSONDecoder().decode(KimiIdentity.self, from: data)
        guard !identity.userID.isEmpty, !identity.label.contains(where: \.isNewline) else {
            throw UsageError.message("Kimi did not return an account identity.")
        }
        return identity
    }

    public func refresh(_ credential: Credential) async throws -> Credential {
        guard credential.oauthClientID == Self.clientID,
              let refreshToken = credential.refreshToken, !refreshToken.isEmpty else {
            throw UsageError.message("Please sign in with Kimi again to renew this session.")
        }
        let (data, status) = try await post(path: "token", fields: [
            "client_id": Self.clientID, "grant_type": "refresh_token", "refresh_token": refreshToken
        ])
        guard status == 200 else { throw failure(status: status) }
        let response = try JSONDecoder().decode(KimiTokenResponse.self, from: data)
        guard response.error == nil else { throw failure(status: status) }
        var updated = try response.credential()
        updated.accountID = credential.accountID
        return updated
    }

    private func post(path: String, fields: [String: String]) async throws -> (Data, Int) {
        var request = URLRequest(url: URL(string: "https://auth.kimi.ai/api/oauth/\(path)")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = GitHubAuth.formBody(fields)
        return try await send(request)
    }

    private func send(_ input: URLRequest) async throws -> (Data, Int) {
        var request = input
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Usage/1.0", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse, data.count <= 1_000_000 else {
            throw UsageError.message("Invalid or oversized Kimi authorization response.")
        }
        return (data, http.statusCode)
    }

    private func failure(status: Int) -> UsageError {
        UsageError.message("Kimi authorization failed (HTTP \(status)). Please sign in again. The global OAuth service must allow this client.")
    }
}
