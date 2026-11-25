import AppKit
import Combine
import UsageCore

@MainActor
final class KimiSignIn: ObservableObject {
    @Published private(set) var authorization: KimiDeviceAuthorization?
    @Published private(set) var identity: KimiIdentity?
    @Published private(set) var credential: Credential?
    @Published private(set) var isSigningIn = false
    @Published private(set) var phase = ""
    @Published private(set) var error: String?
    private let auth = KimiAuth()
    private var task: Task<Void, Never>?
    private var generation = UUID()

    func start() {
        reset()
        isSigningIn = true
        phase = "Requesting a Kimi global sign-in code…"
        let attempt = generation
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let authorization = try await auth.begin()
                try Task.checkCancellation()
                guard generation == attempt else { return }
                self.authorization = authorization
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(authorization.userCode, forType: .string)
                phase = "Authorize sign-in on Kimi's global website."
                NSWorkspace.shared.open(authorization.verificationURI)
                var credential = try await auth.complete(authorization)
                phase = "Looking up your Kimi account…"
                let identity = try await auth.identity(credential: credential)
                credential.accountID = identity.userID
                try Task.checkCancellation()
                phase = "Checking Kimi Code usage access…"
                _ = try await UsageClient().fetch(
                    account: Account(provider: .moonshot, email: identity.label, kimiInternational: true),
                    credential: credential)
                try Task.checkCancellation()
                guard generation == attempt else { return }
                self.identity = identity
                self.credential = credential
                self.authorization = nil
                isSigningIn = false
                task = nil
                NSApp.activate(ignoringOtherApps: true)
            } catch {
                guard generation == attempt, !Task.isCancelled else { return }
                self.error = error.localizedDescription
                authorization = nil
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
        phase = ""
    }
}
