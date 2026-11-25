import AppKit
import Combine
import UsageCore

@MainActor
final class GitHubSignIn: ObservableObject {
    @Published private(set) var authorization: GitHubDeviceAuthorization?
    @Published private(set) var identity: GitHubIdentity?
    @Published private(set) var credential: Credential?
    @Published private(set) var isSigningIn = false
    @Published private(set) var phase = ""
    @Published private(set) var error: String?
    @Published private(set) var creditUsage: CopilotCreditUsage?
    private var task: Task<Void, Never>?
    private var generation = UUID()
    private let auth = GitHubAuth()

    func start() {
        cancel()
        identity = nil
        credential = nil
        error = nil
        creditUsage = nil
        isSigningIn = true
        phase = "Requesting a sign-in code…"
        let attempt = generation
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let authorization = try await auth.begin()
                try Task.checkCancellation()
                guard generation == attempt else { return }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(authorization.userCode, forType: .string)
                self.authorization = authorization
                phase = "Enter this code on GitHub, then authorize Usage."
                NSApp.activate(ignoringOtherApps: true)
                let configuration = NSWorkspace.OpenConfiguration()
                configuration.activates = false
                NSWorkspace.shared.open(authorization.verificationURI, configuration: configuration) { [weak self] _, _ in
                    Task { @MainActor in
                        guard let self, self.generation == attempt, self.authorization != nil else { return }
                        // Keep the code visible instead of switching focus to the browser.
                        NSApp.activate(ignoringOtherApps: true)
                        (NSApp.keyWindow ?? NSApp.mainWindow)?.makeKeyAndOrderFront(nil)
                    }
                }
                var credential = try await auth.complete(authorization)
                try Task.checkCancellation()
                phase = "Signed in. Looking up your GitHub account…"
                let identity = try await auth.identity(credential: credential)
                credential.accountID = String(identity.id)
                try Task.checkCancellation()
                phase = "Signed in as \(identity.login). Checking Copilot quota access…"
                let account = Account(provider: .githubCopilot, email: identity.login)
                var creditUsage: CopilotCreditUsage?
                do {
                    _ = try await UsageClient().fetch(account: account, credential: credential)
                } catch is CancellationError { throw CancellationError() }
                catch let required as CopilotAllowanceRequired {
                    // Login and consumption access succeeded; only the denominator is missing.
                    creditUsage = required.usage
                }
                catch {
                    throw UsageError.message("GitHub sign-in succeeded as \(identity.login), but Copilot usage could not be read. \(error.localizedDescription)")
                }
                try Task.checkCancellation()
                guard generation == attempt else { return }
                self.identity = identity
                self.credential = credential
                self.creditUsage = creditUsage
                phase = creditUsage == nil
                    ? "Signed in as \(identity.login). Copilot usage access verified."
                    : "Signed in as \(identity.login). Enter your monthly allowance below."
                self.authorization = nil
                isSigningIn = false
                task = nil
                NSApp.activate(ignoringOtherApps: true)
            } catch {
                guard generation == attempt, !Task.isCancelled else { return }
                self.error = error.localizedDescription
                self.authorization = nil
                isSigningIn = false
                task = nil
                NSApp.activate(ignoringOtherApps: true)
            }
        }
    }

    func cancel() {
        generation = UUID()
        task?.cancel()
        task = nil
        authorization = nil
        isSigningIn = false
    }

    func reset() {
        cancel()
        identity = nil
        credential = nil
        error = nil
        creditUsage = nil
        phase = ""
    }
}
