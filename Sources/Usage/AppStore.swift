import AppKit
import Combine
import UsageCore
import UserNotifications

struct AccountStatus {
    var snapshot: UsageSnapshot?
    var error: String?
    var refreshing = false
    var failures = 0
    var nextAttempt = Date.distantPast
    var copilotCreditUsage: CopilotCreditUsage?
    var keychainApprovalRequired = false
}

private struct SavedState: Codable {
    var accounts: [Account]
}

/// Serializes account state writes.
private final class StateWriter: @unchecked Sendable {
    private let lock = NSLock()
    private var lastRevision: UInt64 = 0

    func write(_ data: Data, to url: URL, revision: UInt64) throws {
        lock.lock()
        defer { lock.unlock() }
        guard revision >= lastRevision else { return }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try data.write(to: url, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        lastRevision = revision
    }
}

@MainActor
final class AppStore: ObservableObject {
    @Published private(set) var accounts: [Account] = []
    @Published private(set) var statuses: [UUID: AccountStatus] = [:]
    @Published private(set) var lastCheckedAt: Date?
    @Published var storageError: String?
    @Published var notificationStatus = "Not requested"
    @Published var notificationsAllowed = false
    private var alerts: [String: AlertState] = [:]
    private var requestingNotificationPermission = false
    private let client = UsageClient()
    private let githubAuth = GitHubAuth()
    private let kimiAuth = KimiAuth()
    private var codexSessions: [UUID: CodexAppServer] = [:]
    private var pollingTask: Task<Void, Never>?
    private var inFlight: Set<UUID> = []
    private var keychainDenied: Set<UUID> = []
    private var accountRevisions: [UUID: UUID] = [:]
    private let stateURL: URL
    private let stateWriter = StateWriter()
    private var stateRevision: UInt64 = 0
    private let center = UNUserNotificationCenter.current()
    private var openAISessionRoot: URL { stateURL.deletingLastPathComponent().appendingPathComponent("OpenAI", isDirectory: true) }

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        stateURL = support.appendingPathComponent("Usage/accounts.json")
        do {
            if FileManager.default.fileExists(atPath: stateURL.path) {
                let saved = try JSONDecoder().decode(SavedState.self, from: Data(contentsOf: stateURL))
                accounts = saved.accounts
            }
        } catch {
            storageError = "Could not read saved accounts. The original file has been preserved. \(error.localizedDescription)"
        }
    }

    func start() {
        guard pollingTask == nil else { return }
        pollingTask = Task { [weak self] in
            await self?.requestNotifications()
            await self?.requestKeychainAccess()
            while !Task.isCancelled {
                guard let self else { return }
                let startedAt = Date()
                await self.updateNotificationStatus()
                await self.refreshAll()
                let remaining = max(1, 60 - Date().timeIntervalSince(startedAt))
                try? await Task.sleep(for: .seconds(remaining))
            }
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(didWake), name: NSWorkspace.didWakeNotification, object: nil)
    }

    @objc private func didWake() { Task { await updateNotificationStatus(); await refreshAll() } }

    func requestNotifications() async {
        guard !requestingNotificationPermission else { return }
        requestingNotificationPermission = true
        defer { requestingNotificationPermission = false }
        let settings = await center.notificationSettings()
        if settings.authorizationStatus == .denied {
            await updateNotificationStatus()
            // macOS cannot show its authorization prompt again after a denial.
            let alert = NSAlert()
            alert.messageText = "Allow Usage notifications"
            alert.informativeText = "Enable notifications for Usage in System Settings. We'll notify you when your agent usage approaches or reaches its limits."
            alert.addButton(withTitle: "Open Notification Settings")
            alert.addButton(withTitle: "Not Now")
            NSApp.activate(ignoringOtherApps: true)
            if alert.runModal() == .alertFirstButtonReturn,
               let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=app.morovid.Usage") {
                NSWorkspace.shared.open(url)
            }
            return
        }
        guard settings.authorizationStatus == .notDetermined || settings.authorizationStatus == .provisional else {
            await updateNotificationStatus()
            return
        }
        do {
            NSApp.activate(ignoringOtherApps: true)
            _ = try await center.requestAuthorization(options: [.alert, .sound])
            await updateNotificationStatus()
        } catch { notificationStatus = "Could not enable notifications: \(error.localizedDescription)" }
    }

    func updateNotificationStatus() async {
        let settings = await center.notificationSettings()
        notificationsAllowed = settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral: notificationStatus = "Enabled · alerts at 70% and 100%"
        case .denied: notificationStatus = "Disabled in System Settings"
        case .notDetermined: notificationStatus = "Enable alerts at 70% and 100%"
        @unknown default: notificationStatus = "Unknown notification permission"
        }
    }

    func save(_ incoming: Account, credential: Credential?, openAISession: CodexAppServer? = nil) throws {
        var account = incoming
        if let credential { account.importFingerprint = LocalHarnessDetection.fingerprint(credential) }
        guard storageError == nil else { throw UsageError.message("Resolve the storage error before changing accounts.") }
        if let credential { try Keychain.save(credential, for: account.id); keychainDenied.remove(account.id) }
        let previous = accounts
        let previousAlerts = alerts
        if let old = previous.first(where: { $0.id == account.id }),
           old.copilotMonthlyAllowance != account.copilotMonthlyAllowance || old.externalAccountID != account.externalAccountID {
            alerts = alerts.filter { !$0.key.hasPrefix(account.id.uuidString + "/") }
        }
        if let index = accounts.firstIndex(where: { $0.id == account.id }) {
            accounts[index] = account
        } else { accounts.append(account) }
        do { try persist() } catch {
            accounts = previous
            alerts = previousAlerts
            if !previous.contains(where: { $0.id == account.id }) { try? Keychain.delete(for: account.id) }
            throw error
        }
        statuses[account.id] = AccountStatus()
        accountRevisions[account.id] = UUID()
        if let openAISession {
            if let previous = codexSessions[account.id], previous !== openAISession { previous.close() }
            codexSessions[account.id] = openAISession
        }
        Task { await refresh(account, force: true) }
    }

    func moveAccounts(from offsets: IndexSet, to destination: Int) throws {
        guard storageError == nil else { throw UsageError.message("Resolve the storage error before reordering accounts.") }
        let previous = accounts
        let reordered = AccountOrdering.moving(accounts, from: offsets, to: destination)
        guard reordered != accounts else { return }
        accounts = reordered
        do { try persist() } catch {
            accounts = previous
            throw error
        }
    }

    func remove(_ account: Account) throws {
        guard storageError == nil else { throw UsageError.message("Resolve the storage error before changing accounts.") }
        // Delete secrets first, rather than leave orphaned credentials after a Keychain failure.
        if account.source != .codexAppServer { try Keychain.delete(for: account.id) }
        let previous = accounts
        accounts.removeAll { $0.id == account.id }
        let previousAlerts = alerts
        alerts = alerts.filter { !$0.key.hasPrefix(account.id.uuidString + "/") }
        do { try persist() } catch {
            accounts = previous
            alerts = previousAlerts
            throw error
        }
        statuses.removeValue(forKey: account.id)
        keychainDenied.remove(account.id)
        accountRevisions[account.id] = UUID()
        if let session = codexSessions.removeValue(forKey: account.id) {
            Task { await session.discard() }
        } else if account.source == .codexAppServer, let path = account.credentialPath,
                  let home = try? CodexProtocol.validateSessionHome(path, root: openAISessionRoot),
                  let executable = try? CodexAppServer.locateExecutable() {
            let session = CodexAppServer(home: home, executable: executable)
            Task {
                try? await session.logout() // Only this isolated Usage session, never the CLI's default login.
                session.close()
            }
        }
        center.removeDeliveredNotifications(withIdentifiers: previousAlerts.keys.filter { $0.hasPrefix(account.id.uuidString) })
    }

    func refreshAll(force: Bool = false) async {
        // Each account has its own in-flight guard; one slow provider cannot block another.
        let tasks = accounts.map { account in
            Task { await self.refresh(account, force: force) }
        }
        for task in tasks { await task.value }
    }

    /// Asks for Keychain access once at launch, off the main thread. One approval covers every account.
    /// Accounts without access are skipped by background checks.
    private func requestKeychainAccess() async {
        let ids = accounts.filter { $0.source == .keychain }.map(\.id)
        guard !ids.isEmpty else { return }
        let result = await Task.detached(priority: .userInitiated) {
            Result { try Keychain.load(allowInteraction: true, legacyIDs: ids) }
        }.value
        switch result {
        case .success(let denied):
            for account in accounts where denied.contains(account.id) { denyKeychain(account, CredentialAccessError.approvalRequired) }
        case .failure(let error):
            guard error is CredentialAccessError else { return }
            for account in accounts where ids.contains(account.id) { denyKeychain(account, error) }
        }
    }

    private func denyKeychain(_ account: Account, _ error: Error) {
        keychainDenied.insert(account.id)
        var status = statuses[account.id] ?? AccountStatus()
        status.error = error.localizedDescription
        status.keychainApprovalRequired = true
        statuses[account.id] = status
    }

    func allowKeychainAccess(for account: Account) {
        Task {
            let id = account.id
            let result = await Task.detached(priority: .userInitiated) {
                Result { try Keychain.read(for: id, allowInteraction: true) }
            }.value
            switch result {
            case .success:
                keychainDenied.remove(id)
                statuses[id]?.keychainApprovalRequired = false
                statuses[id]?.error = nil
                await refresh(account, force: true)
            case .failure(let error):
                statuses[id]?.error = error.localizedDescription
                statuses[id]?.keychainApprovalRequired = error is CredentialAccessError
            }
        }
    }

    func refresh(_ account: Account, force: Bool = false) async {
        guard accounts.contains(where: { $0 == account }), !inFlight.contains(account.id),
              !keychainDenied.contains(account.id) else { return }
        var status = statuses[account.id] ?? AccountStatus()
        guard force || status.nextAttempt <= Date() else { return }
        inFlight.insert(account.id)
        let revision = accountRevisions[account.id]
        status.refreshing = true
        statuses[account.id] = status
        defer {
            lastCheckedAt = Date()
            inFlight.remove(account.id)
            if var latest = statuses[account.id] { latest.refreshing = false; statuses[account.id] = latest }
        }
        do {
            if account.source == .codexAppServer && !account.isAPI {
                let snapshot = try await openAIUsage(account)
                guard accounts.contains(where: { $0 == account }), accountRevisions[account.id] == revision else { return }
                statuses[account.id] = AccountStatus(snapshot: snapshot)
                await notify(account: account, snapshot: snapshot)
                return
            }
            let client = self.client, github = githubAuth, kimi = kimiAuth
            let snapshot = try await Task.detached(priority: .utility) {
                try await Self.fetchUsage(account, client: client, github: github, kimi: kimi) {
                    await MainActor.run { self.isCurrent(account, revision) }
                }
            }.value
            guard accounts.contains(where: { $0 == account }), accountRevisions[account.id] == revision else { return }
            statuses[account.id] = AccountStatus(snapshot: snapshot)
            await notify(account: account, snapshot: snapshot)
        } catch {
            guard accounts.contains(where: { $0 == account }), accountRevisions[account.id] == revision else { return }
            status.refreshing = false
            status.error = error.localizedDescription
            status.copilotCreditUsage = (error as? CopilotAllowanceRequired)?.usage
            if error is CredentialAccessError { keychainDenied.insert(account.id) }
            status.keychainApprovalRequired = error is CredentialAccessError
            status.failures += 1
            // Back off after failures, up to 15 minutes. Manual refresh bypasses the cooldown.
            status.nextAttempt = Date().addingTimeInterval(min(900, 60 * pow(2, Double(min(status.failures - 1, 4)))))
            statuses[account.id] = status
        }
    }

    private func isCurrent(_ account: Account, _ revision: UUID?) -> Bool {
        accounts.contains(where: { $0 == account }) && accountRevisions[account.id] == revision
    }

    /// Credential loading, token refresh and the network request all run off the main thread.
    nonisolated private static func fetchUsage(_ account: Account, client: UsageClient, github: GitHubAuth, kimi: KimiAuth,
                                               isCurrent: @Sendable () async -> Bool) async throws -> UsageSnapshot {
        var credential: Credential
        if account.source == .codexFile {
            guard let path = account.credentialPath else { throw UsageError.message("The Codex session path is missing.") }
            let session = try SessionImport.codex(path: path)
            guard session.credential.accountID == account.externalAccountID else {
                throw UsageError.message("Codex is now signed into a different account. Edit this account and reimport explicitly.")
            }
            credential = session.credential
        } else { credential = try Keychain.read(for: account.id) }
        if account.provider == .githubCopilot,
           let expiresAt = credential.expiresAt, expiresAt <= Date().addingTimeInterval(60) {
            // The per-account in-flight guard serializes rotating refresh tokens.
            credential = try await github.refresh(credential)
            guard await isCurrent() else { throw CancellationError() }
            try Keychain.save(credential, for: account.id, allowInteraction: false)
        }
        if account.provider == .moonshot, !account.isAPI, credential.oauthClientID != nil {
            guard account.kimiInternational else {
                throw UsageError.message("Kimi OAuth sessions require the Global region. Sign in again.")
            }
            if let expiresAt = credential.expiresAt, expiresAt <= Date().addingTimeInterval(60) {
                credential = try await kimi.refresh(credential)
                guard await isCurrent() else { throw CancellationError() }
                try Keychain.save(credential, for: account.id, allowInteraction: false)
            }
        }
        return try await client.fetch(account: account, credential: credential)
    }

    private func openAIUsage(_ account: Account) async throws -> UsageSnapshot {
        guard account.provider == .openAI, let path = account.credentialPath else {
            throw UsageError.message("The ChatGPT session location is missing. Remove this account and sign in again.")
        }
        let session: CodexAppServer
        if let existing = codexSessions[account.id] { session = existing }
        else {
            session = CodexAppServer(home: try CodexProtocol.validateSessionHome(path, root: openAISessionRoot),
                                     executable: try CodexAppServer.locateExecutable())
            codexSessions[account.id] = session
        }
        let identity = try await session.identity()
        guard identity.label == account.email,
              account.externalAccountID == nil || identity.accountID == nil || account.externalAccountID == identity.accountID else {
            throw UsageError.message("This isolated ChatGPT session now belongs to another account. Remove it and sign in again.")
        }
        return try await session.usage()
    }

    func stop() {
        pollingTask?.cancel()
        pollingTask = nil
        for session in codexSessions.values { session.close() }
        codexSessions.removeAll()
    }

    private func notify(account: Account, snapshot: UsageSnapshot) async {
        // Do not create or consume alerts before permission is granted.
        // Read live settings because permission can change while a fetch is running.
        await updateNotificationStatus()
        guard notificationsAllowed else { return }
        for window in snapshot.windows {
            // An already expired window is stale provider data, not a new alert.
            if let reset = window.resetsAt, reset <= snapshot.fetchedAt { continue }
            let key = "\(account.id.uuidString)/\(window.id)"
            let decision = AlertPolicy.evaluate(window, previous: alerts[key], now: snapshot.fetchedAt)
            if let threshold = decision.threshold {
                let content = UNMutableNotificationContent()
                let percent = Int(window.usedPercent.rounded(.down))
                content.title = "Your \(account.provider.name) usage is \(percent)%"
                content.subtitle = account.email
                let limitName = window.isUserProvidedAllowance == true
                    ? "Monthly credit allowance" : "\(window.label) limit"
                content.body = "\(limitName)\(threshold == 100 ? " reached" : " is approaching")."
                content.sound = .default
                content.userInfo = ["accountID": account.id.uuidString]
                do {
                    try await center.add(UNNotificationRequest(identifier: key, content: content, trigger: nil))
                } catch {
                    notificationStatus = "Notification delivery failed. Check System Settings."
                    continue // Retry later, without marking this alert delivered.
                }
            }
            alerts[key] = decision.state
        }
    }

    private func persist() throws {
        let data = try JSONEncoder().encode(SavedState(accounts: accounts))
        stateRevision += 1
        try stateWriter.write(data, to: stateURL, revision: stateRevision)
    }
}
