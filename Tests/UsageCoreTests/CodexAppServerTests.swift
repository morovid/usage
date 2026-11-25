import Foundation
import Testing
@testable import UsageCore

@MainActor
struct CodexAppServerTests {
    private func fixture(script: String) throws -> (URL, CodexAppServer) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Usage-CodexTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let executable = root.appendingPathComponent("mock-codex")
        try Data(("#!/bin/zsh\n" + script).utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        return (root, CodexAppServer(home: root.appendingPathComponent("home"), executable: executable))
    }

    @Test func privateProcessSupportsAuthEarlyCompletionAndQuotas() async throws {
        let (root, server) = try fixture(script: #"""
        while IFS= read -r line; do
          if [[ "$line" == *'"method":"initialize"'* ]]; then
            print -r -- '{"id":1,"result":{}}'
          elif [[ "$line" == *'"method":"account/login/start"'* ]]; then
            print -r -- '{"method":"account/login/completed","params":{"loginId":"login-1","success":true}}'
            print -r -- '{"id":2,"result":{"type":"chatgpt","loginId":"login-1","authUrl":"https://auth.openai.com/oauth/authorize"}}'
          elif [[ "$line" == *'"method":"account/read"'* ]]; then
            print -r -- '{"id":3,"result":{"account":{"type":"chatgpt","email":"user@example.com"}}}'
          elif [[ "$line" == *'"method":"account/rateLimits/read"'* ]]; then
            print -r -- '{"id":4,"result":{"rateLimits":{"primary":{"usedPercent":25,"windowDurationMins":300}}}}'
          fi
        done
        """#)
        defer { server.close(); try? FileManager.default.removeItem(at: root) }
        let login = try await server.beginLogin()
        try await server.waitForLogin(login)
        #expect(try await server.identity().email == "user@example.com")
        #expect(try await server.usage().windows[0].usedPercent == 25)
    }

    @Test func unexpectedRPCErrorDoesNotLeakTokenOrURL() async throws {
        let (root, server) = try fixture(script: #"""
        while IFS= read -r line; do
          if [[ "$line" == *'"method":"initialize"'* ]]; then
            print -r -- '{"id":1,"result":{}}'
          elif [[ "$line" == *'"method":"account/read"'* ]]; then
            print -r -- '{"id":2,"error":{"code":-1,"message":"secret-token-marker auth-url-marker"}}'
          fi
        done
        """#)
        defer { server.close(); try? FileManager.default.removeItem(at: root) }
        do {
            _ = try await server.identity()
            Issue.record("Expected RPC failure")
        } catch {
            #expect(!error.localizedDescription.contains("secret-token-marker"))
            #expect(!error.localizedDescription.contains("auth-url-marker"))
        }
    }

    @Test func processExitFailsPendingRequestsRatherThanHanging() async throws {
        let (root, server) = try fixture(script: "exit 1\n")
        defer { server.close(); try? FileManager.default.removeItem(at: root) }
        await #expect(throws: (any Error).self) { try await server.start() }
    }

    @Test func closingConnectionCancelsLoginWait() async throws {
        let (root, server) = try fixture(script: #"""
        while IFS= read -r line; do
          if [[ "$line" == *'"method":"initialize"'* ]]; then
            print -r -- '{"id":1,"result":{}}'
          elif [[ "$line" == *'"method":"account/login/start"'* ]]; then
            print -r -- '{"id":2,"result":{"type":"chatgpt","loginId":"login-1","authUrl":"https://auth.openai.com/oauth/authorize"}}'
          fi
        done
        """#)
        defer { server.close(); try? FileManager.default.removeItem(at: root) }
        let login = try await server.beginLogin()
        let waiting = Task { try await server.waitForLogin(login) }
        await Task.yield()
        waiting.cancel()
        await #expect(throws: CancellationError.self) { try await waiting.value }
    }
}
