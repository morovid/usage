import Foundation
import Testing
@testable import UsageCore

@MainActor
struct ClaudeLoginProcessTests {
    private func helper(_ source: String) throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Usage-Claude-test-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let file = folder.appendingPathComponent("claude")
        try Data(("#!/bin/sh\n" + source).utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
        return file
    }

    @Test func launchesOnlyAuthLoginWithoutInference() async throws {
        let executable = try helper(#"""
        [ "$#" = 2 ] && [ "$1" = auth ] && [ "$2" = login ] || exit 7
        exit 0
        """#)
        defer { try? FileManager.default.removeItem(at: executable.deletingLastPathComponent()) }
        try await ClaudeLoginProcess(executable: executable).login()
    }

    @Test func environmentDoesNotInheritKeysTokensConfigOrGatewayOverrides() {
        let clean = ClaudeLoginProcess.environment([
            "HOME": "/Users/test", "PATH": ".:relative:/usr/bin",
            "ANTHROPIC_API_KEY": "secret", "ANTHROPIC_AUTH_TOKEN": "secret",
            "CLAUDE_CODE_OAUTH_TOKEN": "secret", "ANTHROPIC_BASE_URL": "https://evil.example",
            "CLAUDE_CONFIG_DIR": "/other/account", "NODE_OPTIONS": "--require=bad",
            "HTTPS_PROXY": "https://evil.example"
        ])
        #expect(clean["HOME"] == "/Users/test")
        #expect(clean.keys.sorted() == ["HOME", "PATH"])
        #expect(clean["PATH"]!.split(separator: ":").allSatisfy { $0.hasPrefix("/") })
    }

    @Test func failedCLIHasActionableErrorAndNeverSurfacesOutput() async throws {
        let executable = try helper("echo secret-marker >&2\nexit 9\n")
        defer { try? FileManager.default.removeItem(at: executable.deletingLastPathComponent()) }
        do {
            try await ClaudeLoginProcess(executable: executable).login()
            Issue.record("Expected failure")
        } catch {
            #expect(error.localizedDescription.contains("Terminal"))
            #expect(!error.localizedDescription.contains("secret-marker"))
        }
    }

    @Test func cancellationUnblocksPendingLogin() async throws {
        let executable = try helper("exec /bin/sleep 30\n")
        defer { try? FileManager.default.removeItem(at: executable.deletingLastPathComponent()) }
        let runner = ClaudeLoginProcess(executable: executable)
        let task = Task { try await runner.login() }
        try await Task.sleep(for: .milliseconds(30))
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test func timeoutUnblocksPendingLogin() async throws {
        let executable = try helper("exec /bin/sleep 30\n")
        defer { try? FileManager.default.removeItem(at: executable.deletingLastPathComponent()) }
        let runner = ClaudeLoginProcess(executable: executable)
        do {
            try await runner.login(timeoutSeconds: 0.03)
            Issue.record("Expected timeout")
        } catch {
            #expect(error.localizedDescription.contains("timed out"))
        }
    }
}
