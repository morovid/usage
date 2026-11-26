import AppKit
import Combine
import UsageCore

@MainActor
final class ClaudeSignIn: ObservableObject {
    @Published private(set) var credential: Credential?
    @Published private(set) var accountName: String?
    @Published private(set) var isSigningIn = false
    @Published private(set) var phase = ""
    @Published private(set) var error: String?
    private var runner: ClaudeLoginProcess?
    private var task: Task<Void, Never>?
    private var generation = UUID()

    func start() {
        reset()
        isSigningIn = true
        phase = "Complete Claude Code sign-in in your browser…"
        let attempt = generation
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let runner = ClaudeLoginProcess(executable: try ClaudeLoginProcess.locateExecutable())
                self.runner = runner
                try await runner.login()
                try Task.checkCancellation()
                guard generation == attempt else { return }
                phase = "Importing your signed-in session and checking Claude usage…"
                // The Sign in action explicitly authorizes this import; macOS may ask for Keychain approval.
                let session = try SessionImport.claudeDefault()
                let credential = session.credential
                _ = try await UsageClient().fetch(account: Account(provider: .anthropic, email: "Claude account"),
                                                  credential: credential)
                try Task.checkCancellation()
                guard generation == attempt else { return }
                self.credential = credential
                self.accountName = session.email
                isSigningIn = false
                phase = ""
                self.runner = nil
                task = nil
                NSApp.activate(ignoringOtherApps: true)
            } catch {
                guard generation == attempt, !Task.isCancelled else { return }
                self.error = error.localizedDescription
                isSigningIn = false
                self.runner = nil
                task = nil
                NSApp.activate(ignoringOtherApps: true)
            }
        }
    }

    func cancel() {
        generation = UUID()
        task?.cancel()
        task = nil
        runner?.cancel()
        runner = nil
        isSigningIn = false
    }

    func reset() {
        cancel()
        credential = nil
        accountName = nil
        phase = ""
        error = nil
    }
}
