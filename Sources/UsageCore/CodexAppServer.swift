import Foundation
import Darwin

/// A private stdio connection to the official CLI. No inference/thread methods are exposed.
/// Codex owns OAuth, its local callback, secure credential storage and token refresh.
@MainActor
public final class CodexAppServer {
    public let home: URL
    public let executable: URL
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var buffer = Data()
    private var nextID = 0
    private var processID = UUID()
    private var initialized = false
    private var pending: [Int: CheckedContinuation<[String: Any], Error>] = [:]
    private var timeouts: [Int: Task<Void, Never>] = [:]
    private var loginWaiters: [String: CheckedContinuation<Void, Error>] = [:]
    private var loginTimeouts: [String: Task<Void, Never>] = [:]
    private var completedLogins: [String: Bool] = [:]

    public init(home: URL, executable: URL) {
        self.home = home
        self.executable = executable
    }

    public static func locateExecutable() throws -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var paths = [
            home.appendingPathComponent(".local/bin/codex").path,
            "/opt/homebrew/bin/codex", "/usr/local/bin/codex",
            "/Applications/Codex.app/Contents/Resources/codex"
        ]
        paths += (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":")
            .filter { $0.hasPrefix("/") }.map { String($0) + "/codex" }
        guard let path = paths.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw UsageError.message("Install the official Codex CLI to sign in with ChatGPT, then try again. Visit developers.openai.com/codex/cli. Usage will not install software automatically.")
        }
        return URL(fileURLWithPath: path)
    }

    public func start() async throws {
        if initialized, process?.isRunning == true { return }
        close()
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let launch = Process()
        let stdin = Pipe()
        let stdout = Pipe()
        let generation = UUID()
        processID = generation
        launch.executableURL = executable
        launch.arguments = ["-c", "cli_auth_credentials_store=\"keyring\"", "app-server", "--listen", "stdio://"]
        // Do not load the user's shell, project, global Codex home, API keys or gateway overrides.
        var environment: [String: String] = [:]
        for key in ["HOME", "USER", "LOGNAME", "TMPDIR", "PATH"] {
            environment[key] = ProcessInfo.processInfo.environment[key]
        }
        environment["CODEX_HOME"] = home.path
        launch.environment = environment
        launch.currentDirectoryURL = home
        launch.standardInput = stdin
        launch.standardOutput = stdout
        launch.standardError = FileHandle.nullDevice // Never log auth URLs, callback codes or token bodies.
        input = stdin.fileHandleForWriting
        output = stdout.fileHandleForReading
        output?.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            Task { @MainActor in
                guard let self, self.processID == generation else { return }
                self.receive(data)
            }
        }
        launch.terminationHandler = { [weak self] _ in
            Task { @MainActor in
                guard let self, self.processID == generation else { return }
                self.close(error: UsageError.message("The Codex connection stopped. Please try again or update the official Codex CLI."))
            }
        }
        process = launch
        do {
            try launch.run()
            _ = try await request("initialize", params: [
                "clientInfo": ["name": "morovid_usage", "title": "Usage", "version": "1.0.0"]
            ])
            try send(["method": "initialized", "params": [:]])
            initialized = true
        } catch {
            close()
            if error is CancellationError { throw error }
            throw UsageError.message("Could not start the official Codex app-server. Check the Codex installation and update it if needed.")
        }
    }

    public func beginLogin() async throws -> ChatGPTLogin {
        try await start()
        return try ChatGPTLogin.parse(try await request("account/login/start", params: ["type": "chatgpt"]))
    }

    public func waitForLogin(_ login: ChatGPTLogin) async throws {
        try Task.checkCancellation()
        if let success = completedLogins.removeValue(forKey: login.id) {
            guard success else { throw UsageError.message("ChatGPT sign-in failed or was cancelled. Please try again.") }
            return
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                loginWaiters[login.id] = continuation
                loginTimeouts[login.id] = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(600)) } catch { return }
                    self?.finishLogin(login.id, result: .failure(UsageError.message("ChatGPT sign-in timed out. Please try again.")))
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.finishLogin(login.id, result: .failure(CancellationError())) }
        }
    }

    public func identity() async throws -> ChatGPTIdentity {
        try await start()
        return try ChatGPTIdentity.parse(try await request("account/read", params: ["refreshToken": false]))
    }

    public func usage() async throws -> UsageSnapshot {
        try await start()
        return try CodexProtocol.rateLimits(try await request("account/rateLimits/read", params: [:]))
    }

    public func cancelLogin(_ login: ChatGPTLogin) async {
        _ = try? await request("account/login/cancel", params: ["loginId": login.id], timeout: 3)
    }

    public func logout() async throws {
        try await start()
        _ = try await request("account/logout", params: [:])
    }

    public func discard() async {
        if initialized, process?.isRunning == true {
            _ = try? await request("account/logout", params: [:], timeout: 3)
        }
        close()
    }

    public func close() {
        close(error: CancellationError())
    }

    private func close(error: Error) {
        processID = UUID()
        initialized = false
        output?.readabilityHandler = nil
        try? input?.close()
        try? output?.close()
        input = nil
        output = nil
        if let process, process.isRunning {
            process.terminate()
            Task {
                try? await Task.sleep(for: .seconds(2))
                if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) }
            }
        }
        process = nil
        buffer.removeAll()
        for task in timeouts.values { task.cancel() }
        timeouts.removeAll()
        let requests = pending.values
        pending.removeAll()
        for request in requests { request.resume(throwing: error) }
        for task in loginTimeouts.values { task.cancel() }
        loginTimeouts.removeAll()
        let logins = loginWaiters.values
        loginWaiters.removeAll()
        for login in logins { login.resume(throwing: error) }
        completedLogins.removeAll()
    }

    private func request(_ method: String, params: [String: Any], timeout: Double = 30) async throws -> [String: Any] {
        try Task.checkCancellation()
        guard process?.isRunning == true else { throw UsageError.message("The Codex connection is not running.") }
        nextID += 1
        let id = nextID
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pending[id] = continuation
                timeouts[id] = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(timeout)) } catch { return }
                    self?.finish(id, result: .failure(UsageError.message("The Codex account request timed out. Please try again.")))
                }
                do { try send(["id": id, "method": method, "params": params]) }
                catch { finish(id, result: .failure(error)) }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.finish(id, result: .failure(CancellationError())) }
        }
    }

    private func send(_ message: [String: Any]) throws {
        guard let input else { throw UsageError.message("The Codex connection is closed.") }
        var data = try JSONSerialization.data(withJSONObject: message, options: [.withoutEscapingSlashes])
        data.append(0x0A)
        try input.write(contentsOf: data)
    }

    private func receive(_ data: Data) {
        guard !data.isEmpty else {
            close(error: UsageError.message("The Codex connection closed unexpectedly. Please try again."))
            return
        }
        buffer.append(data)
        guard buffer.count <= 2_000_000 else {
            close(error: UsageError.message("Codex returned an oversized protocol message."))
            return
        }
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[..<newline]
            buffer.removeSubrange(...newline)
            guard !line.isEmpty else { continue }
            guard let message = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else {
                close(error: UsageError.message("Codex returned an invalid protocol message. Update Codex and retry."))
                return
            }
            if let method = message["method"] as? String {
                if let id = message["id"] {
                    // Never service filesystem, tool, inference, attestation or other server requests.
                    try? send(["id": id, "error": ["code": -32601, "message": "Usage supports account monitoring only."]])
                } else if method == "account/login/completed",
                          let params = message["params"] as? [String: Any],
                          let id = params["loginId"] as? String, let success = params["success"] as? Bool {
                    if loginWaiters[id] != nil {
                        finishLogin(id, result: success ? .success(()) :
                            .failure(UsageError.message("ChatGPT sign-in failed or was cancelled. Please try again.")))
                    } else if completedLogins.count < 16 { completedLogins[id] = success }
                }
                continue
            }
            guard let id = message["id"] as? Int else { continue }
            if message["error"] as? [String: Any] != nil {
                // Raw RPC errors can contain tokens/URLs; expose only a fixed actionable message.
                finish(id, result: .failure(UsageError.message("Codex could not complete the account request. Sign in again or update the official Codex CLI.")))
            } else if let result = message["result"] as? [String: Any] {
                finish(id, result: .success(result))
            } else {
                finish(id, result: .failure(UsageError.message("Codex returned an unexpected account response.")))
            }
        }
    }

    private func finish(_ id: Int, result: Result<[String: Any], Error>) {
        timeouts.removeValue(forKey: id)?.cancel()
        pending.removeValue(forKey: id)?.resume(with: result)
    }

    private func finishLogin(_ id: String, result: Result<Void, Error>) {
        loginTimeouts.removeValue(forKey: id)?.cancel()
        loginWaiters.removeValue(forKey: id)?.resume(with: result)
    }
}
