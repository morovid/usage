import Foundation
import Testing
@testable import UsageCore

private final class KimiMockProtocol: URLProtocol {
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
        if let stream = request.httpBodyStream {
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

private actor KimiSleeps {
    var values: [Double] = []
    func append(_ value: Double) { values.append(value) }
}

@Suite(.serialized)
struct KimiAuthTests {
    private var deviceJSON: String {
        #"{"device_code":"device-secret","user_code":"ABCD-EFGH","verification_uri_complete":"https://www.kimi.ai/code/authorize?user_code=ABCD-EFGH","expires_in":900,"interval":5}"#
    }
    private var tokenJSON: String {
        #"{"access_token":"access-test","refresh_token":"refresh-test","expires_in":3600,"token_type":"Bearer"}"#
    }
    private func service(_ replies: [KimiMockProtocol.Reply],
                         sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { _ in }) -> KimiAuth {
        KimiMockProtocol.lock.lock()
        KimiMockProtocol.replies = replies
        KimiMockProtocol.requests = []
        KimiMockProtocol.lock.unlock()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [KimiMockProtocol.self]
        return KimiAuth(session: URLSession(configuration: config), sleep: sleep)
    }

    @Test func globalDeviceLoginUsesPublishedClientAndOwnIdentity() async throws {
        let auth = service([.init(json: deviceJSON), .init(json: tokenJSON)])
        let device = try await auth.begin()
        let credential = try await auth.complete(device)
        #expect(device.userCode == "ABCD-EFGH")
        #expect(credential.oauthClientID == KimiAuth.clientID)
        #expect(credential.refreshToken == "refresh-test")
        #expect(credential.expiresAt! > Date().addingTimeInterval(3500))
        let requests = KimiMockProtocol.requests
        #expect(requests.map { $0.url!.host! } == ["auth.kimi.ai", "auth.kimi.ai"])
        #expect(requests[0].url?.path == "/api/oauth/device_authorization")
        #expect(requests[1].url?.path == "/api/oauth/token")
        #expect(requests.allSatisfy { $0.value(forHTTPHeaderField: "User-Agent") == "Usage/1.0" })
        let body = String(data: try #require(requests[1].httpBody), encoding: .utf8)!
        #expect(body.contains("device_code=device-secret"))
        #expect(!body.contains("client_secret"))
    }

    @Test func pendingAndSlowDownRespectPollingInterval() async throws {
        let sleeps = KimiSleeps()
        let auth = service([
            .init(json: deviceJSON),
            .init(status: 400, json: #"{"error":"authorization_pending"}"#),
            .init(status: 400, json: #"{"error":"slow_down"}"#),
            .init(json: tokenJSON)
        ], sleep: { await sleeps.append($0) })
        _ = try await auth.complete(auth.begin())
        #expect(await sleeps.values == [5, 5, 10])
    }

    @Test func chinaAndUnexpectedVerificationURLsAreRejected() async throws {
        for host in ["www.kimi.com", "auth.kimi.com", "evil.example", "www.kimi.ai.evil.example",
                     "user@www.kimi.ai", "www.kimi.ai:444"] {
            let auth = service([.init(json: deviceJSON.replacingOccurrences(of: "www.kimi.ai", with: host))])
            await #expect(throws: (any Error).self) { try await auth.begin() }
        }
    }

    @Test func refreshUsesGlobalHostAndPreservesAccountID() async throws {
        let auth = service([.init(json: tokenJSON)])
        let old = Credential(accessToken: "old", accountID: "user-1", refreshToken: "old-refresh",
                             oauthClientID: KimiAuth.clientID)
        let updated = try await auth.refresh(old)
        #expect(updated.accountID == "user-1")
        #expect(updated.accessToken == "access-test")
        #expect(updated.refreshToken == "refresh-test")
        let request = try #require(KimiMockProtocol.requests.first)
        #expect(request.url?.host == "auth.kimi.ai")
        let body = String(data: try #require(request.httpBody), encoding: .utf8)!
        #expect(body.contains("grant_type=refresh_token"))
        #expect(body.contains("refresh_token=old-refresh"))
    }

    @Test func wrongClientCannotRefreshAndLegacyKeysRemainReadable() async throws {
        let auth = service([])
        await #expect(throws: (any Error).self) {
            try await auth.refresh(Credential(accessToken: "key", refreshToken: "refresh", oauthClientID: "wrong"))
        }
        #expect(KimiMockProtocol.requests.isEmpty)
        let legacy = try JSONDecoder().decode(Credential.self, from: Data(#"{"accessToken":"key"}"#.utf8))
        #expect(legacy.oauthClientID == nil)
        #expect(legacy.refreshToken == nil)
    }

    @Test func identityComesFromGlobalAuthenticatedEndpoint() async throws {
        let auth = service([.init(json: #"{"user_id":"user-1","nickname":"Personal","email":"me@example.com"}"#)])
        let identity = try await auth.identity(credential: Credential(accessToken: "access-test"))
        #expect(identity.userID == "user-1")
        #expect(identity.label == "me@example.com")
        let request = try #require(KimiMockProtocol.requests.first)
        #expect(request.url?.absoluteString == "https://api.kimi.ai/coding/v1/me")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer access-test")
    }

    @Test func deniedExpiredAndIncompleteTokensStopSignIn() async throws {
        for reply in [
            KimiMockProtocol.Reply(status: 400, json: #"{"error":"access_denied"}"#),
            .init(status: 400, json: #"{"error":"expired_token"}"#),
            .init(json: #"{"access_token":"access-test","expires_in":3600}"#)
        ] {
            let auth = service([.init(json: deviceJSON), reply])
            let device = try await auth.begin()
            await #expect(throws: (any Error).self) { try await auth.complete(device) }
            #expect(KimiMockProtocol.requests.count == 2)
        }
    }

    @Test func cancellationPreventsTokenRequest() async throws {
        let auth = service([.init(json: deviceJSON)], sleep: { _ in throw CancellationError() })
        let device = try await auth.begin()
        await #expect(throws: CancellationError.self) { try await auth.complete(device) }
        #expect(KimiMockProtocol.requests.count == 1)
    }

    @Test func errorsNeverExposeResponseBodies() async throws {
        let auth = service([.init(status: 403, json: #"{"error_description":"secret-marker"}"#)])
        do {
            _ = try await auth.begin()
            Issue.record("Expected failure")
        } catch {
            #expect(error.localizedDescription.contains("HTTP 403"))
            #expect(!error.localizedDescription.contains("secret-marker"))
        }
    }
}
