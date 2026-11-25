import Foundation

/// Runs only the official CLI's authentication command, never an agent or inference.
/// This intentionally signs in to the user's normal Claude Code account.
@MainActor
public final class ClaudeLoginProcess {
    private let executable: URL
    private var process: Process?
    private var continuation: CheckedContinuation<Void, Error>?
    private var timeout: Task<Void, Never>?

    public init(executable: URL) { self.executable = executable }

    public static func locateExecutable() throws -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let paths = [
            home.appendingPathComponent(".local/bin/claude").path,
            "/opt/homebrew/bin/claude", "/usr/local/bin/claude"
        ] + (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":")
            .filter { $0.hasPrefix("/") }.map { String($0) + "/claude" }
        guard let path = paths.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw UsageError.message("Install the official Claude Code CLI first, then try again. You can also import an existing Claude Code session.")
        }
        return URL(fileURLWithPath: path)
    }

    public static func environment(_ input: [String: String]) -> [String: String] {
        var output = input.filter { ["HOME", "USER", "LOGNAME", "TMPDIR", "LANG", "LC_ALL"].contains($0.key) }
        let paths = (input["PATH"] ?? "").split(separator: ":").filter { $0.hasPrefix("/") }.map(String.init)
        output["PATH"] = (paths + ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]).joined(separator: ":")
        return output
    }

    public func login(timeoutSeconds: TimeInterval = 600) async throws {
        try Task.checkCancellation()
        guard process == nil else { throw UsageError.message("Claude sign-in is already running.") }
        let child = Process()
        child.executableURL = executable
        child.arguments = ["auth", "login"]
        child.environment = Self.environment(ProcessInfo.processInfo.environment)
        child.currentDirectoryURL = FileManager.default.temporaryDirectory
        child.standardInput = FileHandle.nullDevice
        // Never log CLI output: it may include OAuth codes or credentials.
        child.standardOutput = FileHandle.nullDevice
        child.standardError = FileHandle.nullDevice
        process = child
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                child.terminationHandler = { [weak self] child in
                    Task { @MainActor in
                        guard let self, self.process === child else { return }
                        if child.terminationStatus == 0 { self.finish(.success(())) }
                        else {
                            self.finish(.failure(UsageError.message("Claude Code sign-in did not complete. Try `claude auth login` in Terminal, then Import Claude Code session. Some CLI versions require an interactive terminal.")))
                        }
                    }
                }
                do {
                    try child.run()
                    timeout = Task { [weak self] in
                        do { try await Task.sleep(for: .seconds(timeoutSeconds)) } catch { return }
                        guard let self, self.process === child else { return }
                        if child.isRunning { child.terminate() }
                        self.finish(.failure(UsageError.message("Claude sign-in timed out. Please try again.")))
                    }
                } catch {
                    finish(.failure(UsageError.message("Could not start Claude Code sign-in. Check your CLI installation.")))
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard let self, self.process === child else { return }
                self.cancel()
            }
        }
        try Task.checkCancellation()
    }

    public func cancel() {
        if let process, process.isRunning { process.terminate() }
        finish(.failure(CancellationError()))
    }

    private func finish(_ result: Result<Void, Error>) {
        timeout?.cancel()
        timeout = nil
        process = nil
        let waiting = continuation
        continuation = nil
        waiting?.resume(with: result)
    }
}
