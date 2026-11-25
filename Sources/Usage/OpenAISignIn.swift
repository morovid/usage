import AppKit
import Combine
import UsageCore

@MainActor
final class OpenAISignIn: ObservableObject {
    @Published private(set) var identity: ChatGPTIdentity?
    @Published private(set) var snapshot: UsageSnapshot?
    @Published private(set) var isSigningIn = false
    @Published private(set) var phase = ""
    @Published private(set) var error: String?
    private(set) var session: CodexAppServer?
    private var task: Task<Void, Never>?
    private var generation = UUID()

    func start() {
        cancel()
        identity = nil
        snapshot = nil
        error = nil
        isSigningIn = true
        phase = "Starting ChatGPT sign-in…"
        let attempt = generation
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let executable = try CodexAppServer.locateExecutable()
                let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                let root = support.appendingPathComponent("Usage/OpenAI", isDirectory: true)
                let home = CodexProtocol.sessionHome(root: root, id: UUID())
                let client = CodexAppServer(home: home, executable: executable)
                session = client
                let login = try await client.beginLogin()
                try Task.checkCancellation()
                guard generation == attempt else { return }
                phase = "Complete sign-in in your browser…"
                guard NSWorkspace.shared.open(login.url) else {
                    throw UsageError.message("Could not open your browser. Set a default browser in macOS and try again.")
                }
                try await client.waitForLogin(login)
                try Task.checkCancellation()
                phase = "Checking your ChatGPT account and usage…"
                let identity = try await client.identity()
                let snapshot = try await client.usage()
                try Task.checkCancellation()
                guard generation == attempt else { return }
                self.identity = identity
                self.snapshot = snapshot
                isSigningIn = false
                phase = ""
                task = nil
                NSApp.activate(ignoringOtherApps: true)
                (NSApp.keyWindow ?? NSApp.mainWindow)?.makeKeyAndOrderFront(nil)
            } catch {
                guard generation == attempt, !Task.isCancelled else { return }
                self.error = error.localizedDescription
                isSigningIn = false
                task = nil
                if let session {
                    self.session = nil
                    Task { await session.discard() }
                }
                NSApp.activate(ignoringOtherApps: true)
            }
        }
    }

    /// Ownership passes to the app store after the account is successfully persisted.
    func detachSession() {
        session = nil
    }

    func cancel() {
        generation = UUID()
        task?.cancel()
        task = nil
        isSigningIn = false
        if let session {
            self.session = nil
            Task { await session.discard() }
        }
    }

    func reset() {
        cancel()
        identity = nil
        snapshot = nil
        error = nil
        phase = ""
    }
}
