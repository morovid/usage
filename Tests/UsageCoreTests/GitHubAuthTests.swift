import Foundation
import Testing
@testable import UsageCore

private final class GitHubMockProtocol: URLProtocol {
    struct Reply {
        var status = 200
        var json: String
    }
    static var replies: [Reply] = []
    static var requests: [URLRequest] = []
    static let lock = NSLock()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var recorded = request
        if recorded.httpBody == nil, let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 1024)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count > 0 else { break }
                data.append(contentsOf: buffer.prefix(count))
            }
            recorded.httpBody = data
        }
        Self.lock.lock()
        Self.requests.append(recorded)
        let reply = Self.replies.isEmpty ? Reply(status: 500, json: "{}") : Self.replies.removeFirst()
        Self.lock.unlock()
        let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: nil,
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(reply.json.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private actor RecordedSleeps {
    var values: [Double] = []
    func append(_ value: Double) { values.append(value) }
}

@Suite(.serialized)
struct GitHubAuthTests {
    private func service(_ replies: [GitHubMockProtocol.Reply],
                         sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { _ in }) -> GitHubAuth {
        GitHubMockProtocol.lock.lock()
        GitHubMockProtocol.replies = replies
        GitHubMockProtocol.requests = []
        GitHubMockProtocol.lock.unlock()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [GitHubMockProtocol.self]
        return GitHubAuth(session: URLSession(configuration: config), sleep: sleep)
    }

    private var deviceJSON: String {
        #"{"device_code":"device-secret","user_code":"ABCD-EFGH","verification_uri":"https://github.com/login/device","expires_in":900,"interval":5}"#
    }

    private var tokenJSON: String {
        #"{"access_token":"ghu_test","token_type":"bearer","expires_in":28800,"refresh_token":"ghr_test","refresh_token_expires_in":15897600}"#
    }

    @Test func deviceAuthorizationUsesOurClientAndNoSecret() async throws {
        let auth = service([.init(json: deviceJSON)])
        let device = try await auth.begin()
        #expect(device.userCode == "ABCD-EFGH")
        let request = try #require(GitHubMockProtocol.requests.first)
        #expect(request.url?.absoluteString == "https://github.com/login/device/code")
        #expect(request.httpMethod == "POST")
        let body = String(data: try #require(request.httpBody), encoding: .utf8)!
        #expect(body.contains("client_id=Iv23li89IJLYqBiDzGoi"))
        #expect(body.contains("scope=offline_access"))
        #expect(!body.contains("client_secret"))
        #expect(request.url?.query == nil)
    }

    @Test func pendingAndSlowDownAreHandled() async throws {
        let sleeps = RecordedSleeps()
        let auth = service([
            .init(json: deviceJSON),
            .init(json: #"{"error":"authorization_pending"}"#),
            .init(json: #"{"error":"slow_down","interval":10}"#),
            .init(json: tokenJSON)
        ], sleep: { await sleeps.append($0) })
        let device = try await auth.begin()
        let credential = try await auth.complete(device)
        #expect(credential.accessToken == "ghu_test")
        #expect(credential.refreshToken == "ghr_test")
        #expect(credential.oauthClientID == GitHubAuth.clientID)
        #expect(credential.expiresAt != nil)
        #expect(await sleeps.values == [5, 5, 10])
        #expect(GitHubMockProtocol.requests.count == 4)
        #expect(GitHubMockProtocol.requests.allSatisfy { $0.url?.query == nil })
    }

    @Test func deviceFlowDisabledIsActionableAndSanitized() async throws {
        let auth = service([.init(json: #"{"error":"device_flow_disabled","error_description":"secret-marker"}"#)])
        do {
            _ = try await auth.begin()
            Issue.record("Expected disabled device flow to fail")
        } catch {
            #expect(error.localizedDescription.contains("Enable Device Flow"))
            #expect(!error.localizedDescription.contains("secret-marker"))
        }
    }

    @Test func unexpectedVerificationHostIsRejected() async throws {
        let auth = service([.init(json: deviceJSON.replacingOccurrences(of: "https://github.com/login/device",
                                                                      with: "https://other.example/login/device"))])
        await #expect(throws: (any Error).self) { try await auth.begin() }
    }

    @Test func authorizationDeniedAndExpiredStopPolling() async throws {
        for code in ["access_denied", "expired_token"] {
            let auth = service([.init(json: deviceJSON), .init(json: #"{"error":"\#(code)"}"#)])
            let device = try await auth.begin()
            await #expect(throws: (any Error).self) { try await auth.complete(device) }
            #expect(GitHubMockProtocol.requests.count == 2)
        }
    }

    @Test func identityComesFromAuthenticatedUserEndpoint() async throws {
        let auth = service([.init(json: #"{"id":12345,"login":"octocat"}"#)])
        let identity = try await auth.identity(credential: Credential(accessToken: "ghu_test"))
        #expect(identity.login == "octocat")
        #expect(identity.id == 12345)
        let request = try #require(GitHubMockProtocol.requests.first)
        #expect(request.url?.absoluteString == "https://api.github.com/user")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer ghu_test")
    }

    @Test func refreshRotatesCredentialsWithoutClientSecret() async throws {
        let auth = service([.init(json: tokenJSON)])
        let old = Credential(accessToken: "old-access", accountID: "12345", refreshToken: "old-refresh",
                             refreshTokenExpiresAt: Date().addingTimeInterval(900), oauthClientID: GitHubAuth.clientID)
        let updated = try await auth.refresh(old)
        #expect(updated.accessToken == "ghu_test")
        #expect(updated.refreshToken == "ghr_test")
        #expect(updated.accountID == "12345")
        let request = try #require(GitHubMockProtocol.requests.first)
        let body = String(data: try #require(request.httpBody), encoding: .utf8)!
        #expect(body.contains("grant_type=refresh_token"))
        #expect(body.contains("refresh_token=old-refresh"))
        #expect(!body.contains("client_secret"))
        #expect(request.url?.query == nil)
    }

    @Test func expiredRefreshTokenDoesNotMakeRequest() async throws {
        let auth = service([])
        let old = Credential(accessToken: "old", refreshToken: "old-refresh",
                             refreshTokenExpiresAt: Date().addingTimeInterval(-1), oauthClientID: GitHubAuth.clientID)
        await #expect(throws: (any Error).self) { try await auth.refresh(old) }
        #expect(GitHubMockProtocol.requests.isEmpty)
    }

    @Test func cancellationStopsBeforePolling() async throws {
        let auth = service([.init(json: deviceJSON)], sleep: { _ in throw CancellationError() })
        let device = try await auth.begin()
        await #expect(throws: CancellationError.self) { try await auth.complete(device) }
        #expect(GitHubMockProtocol.requests.count == 1)
    }

    @Test func formEncodingProtectsSpecialCharacters() {
        let body = String(data: GitHubAuth.formBody(["token": "abc+def&?#=/"]), encoding: .utf8)
        #expect(body == "token=abc%2Bdef%26%3F%23%3D%2F")
    }

    @Test func existingTokenOnlyCredentialsRemainDecodable() throws {
        let credential = try JSONDecoder().decode(Credential.self, from: Data(#"{"accessToken":"legacy"}"#.utf8))
        #expect(credential.accessToken == "legacy")
        #expect(credential.refreshToken == nil)
        #expect(credential.expiresAt == nil)
    }
}
