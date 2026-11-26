import AppKit
import SwiftUI
import UsageCore

@MainActor
final class AccountsPresentation: ObservableObject {
    @Published var addAccountRequested = false
}

struct AccountsView: View {
    @ObservedObject var store: AppStore
    @ObservedObject var presentation: AccountsPresentation
    @State private var selection: UUID?
    @State private var editor: EditorItem?
    @State private var deleting: Account?
    @State private var error: String?
    private var selected: Account? { store.accounts.first { $0.id == selection } }

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                List(selection: $selection) {
                    ForEach(store.accounts) { account in
                        HStack(spacing: 10) {
                            ProviderBadge(provider: account.provider)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(account.displayProviderName).fontWeight(.medium)
                                Text(account.provider == .githubCopilot && !account.email.hasPrefix("@") ? "@\(account.email)" : account.email)
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }.padding(.vertical, 5).tag(account.id)
                    }
                }
                .listStyle(.sidebar)
                if !store.accounts.isEmpty {
                    Divider()
                    HStack {
                        Button { editor = EditorItem(account: nil) } label: {
                            Label("Add account", systemImage: "plus")
                        }
                        .buttonStyle(.borderless)
                        Spacer()
                    }.padding(14)
                }
            }.frame(minWidth: 235, idealWidth: 255, maxWidth: 310)

            VStack(alignment: .leading, spacing: 0) {
                if let account = selected {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 22) {
                            let status = store.statuses[account.id] ?? AccountStatus()
                            HStack(spacing: 12) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(account.displayProviderName).font(.title2.bold())
                                    Text(account.provider == .githubCopilot && !account.email.hasPrefix("@") ? "@\(account.email)" : account.email)
                                        .font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                                }
                                Spacer()
                                if status.refreshing {
                                    ProgressView().controlSize(.small)
                                }
                            }
                             if let snapshot = status.snapshot {
                                if let billing = snapshot.billing {
                                    APIBillingView(billing: billing, stale: status.error != nil)
                                    Text(billing.kind == .monthToDateCost
                                         ? "Organization-wide API costs for this calendar month (UTC). Provider billing data may be delayed. This is not a prepaid balance or subscription quota."
                                         : account.provider == .deepSeek
                                         ? "Available DeepSeek API balance, including granted credit. DeepSeek has no subscription quotas."
                                         : "Global Open Platform available balance, including vouchers. This is not Kimi Code subscription usage.")
                                        .font(.caption).foregroundStyle(.secondary)
                                    if account.provider == .anthropic {
                                        Text("After discounts, before credits. Analytics may lag by 4–24 hours; Priority Tier commitment fees are excluded.")
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                    Text("No percentage alerts: the API does not supply a spending allowance.")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                VStack(spacing: 18) {
                                    ForEach(snapshot.windows) { window in
                                        UsageMeter(window: window, color: account.provider.tint,
                                                   stale: status.error != nil, showsAllowanceSource: false)
                                    }
                                }
                            } else if status.error == nil {
                                Text("Checking usage…").font(.caption).foregroundStyle(.secondary)
                            }
                            if let error = status.error {
                                Text(error).font(.caption).foregroundStyle(.orange)
                                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                            }
                            if status.keychainApprovalRequired {
                                Button("Allow Keychain access") { store.allowKeychainAccess(for: account) }
                            }
                        }.padding(26)
                    }
                    Divider()
                    HStack {
                        Spacer()
                        Button("Edit") { editor = EditorItem(account: account) }
                        Button("Remove", role: .destructive) { deleting = account }
                            .foregroundStyle(.red)
                    }
                    .padding(.horizontal, 26).padding(.vertical, 14)
                } else {
                    VStack(spacing: 14) {
                        Image(systemName: "person.crop.circle.badge.plus").font(.system(size: 44, weight: .ultraLight))
                            .foregroundStyle(.secondary)
                        Text(store.accounts.isEmpty ? "You don't have any monitored account." : "Choose an account")
                            .multilineTextAlignment(.center).foregroundStyle(.secondary)
                        Button("Add account") { editor = EditorItem(account: nil) }.buttonStyle(.borderedProminent)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                if let storageError = store.storageError {
                    Divider()
                    VStack(alignment: .leading, spacing: 8) {
                        Text(storageError).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                    }.padding(18)
                }
            }.frame(minWidth: 455, maxWidth: .infinity, maxHeight: .infinity)
        }
        .sheet(item: $editor) { item in
            AccountEditor(store: store, existing: item.account) { id in selection = id }
        }
        .confirmationDialog("Remove \(deleting?.provider.name ?? "") account?",
                            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            titleVisibility: .visible) {
            Button("Remove", role: .destructive) {
                guard let account = deleting else { return }
                do { try store.remove(account); selection = nil } catch { self.error = error.localizedDescription }
                deleting = nil
            }
        } message: { Text("The saved credential and alert history will be removed. The provider account and any CLI login are not affected.") }
        .alert("Could not remove account", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK") { error = nil }
        } message: { Text(error ?? "") }
        .onAppear { if selection == nil { selection = store.accounts.first?.id } }
        .onChange(of: presentation.addAccountRequested, initial: true) { _, requested in
            guard requested else { return }
            if editor == nil { editor = EditorItem(account: nil) }
            presentation.addAccountRequested = false
        }
    }
}

private struct EditorItem: Identifiable {
    let id = UUID()
    var account: Account?
}

struct AccountEditor: View {
    @ObservedObject var store: AppStore
    var existing: Account?
    var onSaved: (UUID) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var provider: Provider
    @State private var email: String
    @State private var token = ""
    @State private var accountID: String
    @State private var international: Bool
    @State private var source: CredentialSource
    @State private var credentialPath: String?
    @State private var error: String?
    @State private var importMessage: String?
    @State private var saving = false
    @StateObject private var github = GitHubSignIn()
    @StateObject private var openAI = OpenAISignIn()
    @StateObject private var kimi = KimiSignIn()
    @StateObject private var claude = ClaudeSignIn()
    @State private var kimiUsesKey = false
    @State private var claudeImportsSession = false
    @State private var copilotAllowanceInput: String
    @State private var usesAPI: Bool
    @State private var apiSaveTask: Task<Void, Never>?

    private var pendingCreditUsage: CopilotCreditUsage? {
        github.creditUsage ?? (github.credential == nil ? existing.flatMap { store.statuses[$0.id]?.copilotCreditUsage } : nil)
    }
    private var needsCopilotAllowance: Bool {
        provider == .githubCopilot && (pendingCreditUsage != nil || existing?.copilotMonthlyAllowance != nil)
    }
    private var copilotAccountName: String? {
        github.identity?.login ?? (provider == .githubCopilot ? existing?.email : nil)
    }
    private var openAIAccountName: String? {
        openAI.identity?.label ?? (provider == .openAI ? existing?.email : nil)
    }
    private var canSaveAccount: Bool {
        if usesAPI { return true }
        if usesKimiLogin { return existing != nil || kimi.credential != nil }
        if provider == .githubCopilot { return existing != nil || github.credential != nil }
        if provider == .openAI { return existing != nil || openAI.identity != nil }
        return true
    }
    private var usesKimiLogin: Bool { provider == .moonshot && !usesAPI && international && !kimiUsesKey }
    private var kimiAccountName: String? { kimi.identity?.label ?? existing?.email }
    private var isAuthenticating: Bool { github.isSigningIn || openAI.isSigningIn || kimi.isSigningIn || claude.isSigningIn }

    init(store: AppStore, existing: Account?, onSaved: @escaping (UUID) -> Void) {
        self.store = store
        self.existing = existing
        self.onSaved = onSaved
        _provider = State(initialValue: existing?.provider ?? .anthropic)
        _email = State(initialValue: existing?.email ?? "")
        _accountID = State(initialValue: existing?.externalAccountID ?? "")
        _international = State(initialValue: existing?.kimiInternational ?? true)
        _source = State(initialValue: existing?.source ?? .keychain)
        _credentialPath = State(initialValue: existing?.credentialPath)
        _copilotAllowanceInput = State(initialValue: existing?.copilotMonthlyAllowance?.formatted(.number.grouping(.never)) ?? "")
        _usesAPI = State(initialValue: existing?.isAPI ?? false)
    }

    private var usesKimiKeyFlow: Bool { provider == .moonshot && !usesAPI && !usesKimiLogin }
    private var namesAreOptional: Bool { usesAPI || provider == .openCode || provider == .anthropic || usesKimiKeyFlow }

    var body: some View {
        VStack(spacing: 28) {
            Text(existing == nil ? "Connect an account" : "Edit account")
                .font(.title2.bold()).frame(maxWidth: .infinity, alignment: .leading)
            Form {
                Picker("Provider", selection: $provider) {
                    ForEach(Provider.allCases) { Text($0.name).tag($0) }
                }.disabled(existing != nil || isAuthenticating)
                if provider.supportsAPIBilling && !provider.isAPIOnly {
                    Picker("Account type", selection: $usesAPI) {
                        Text(provider == .anthropic ? "Claude" : "Subscription").tag(false)
                        Text("API key").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .disabled(existing != nil || isAuthenticating)
                }
                if provider == .moonshot {
                    TextField("Kimi region", text: .constant(international ? "Global" : "China")).disabled(true)
                }
            }
            .formStyle(.grouped).scrollDisabled(true).fixedSize(horizontal: false, vertical: true)
            .disabled(saving || claude.isSigningIn)

            setup.frame(maxWidth: .infinity).disabled(saving)

            if namesAreOptional {
                TextField("Account name (optional)", text: $email, prompt: Text(existing?.email ?? defaultAccountLabel))
                    .textFieldStyle(.roundedBorder).multilineTextAlignment(.center)
                    .frame(width: 300).disabled(saving)
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
            HStack {
                Spacer()
                Button("Cancel") {
                    apiSaveTask?.cancel()
                    github.cancel(); openAI.cancel(); kimi.cancel(); claude.cancel(); dismiss()
                }.keyboardShortcut(.cancelAction)
                if canSaveAccount {
                    Button(saving ? "Verifying…" : existing == nil ? (usesAPI || provider == .openCode ? "Verify and add account" : "Add account") : "Save", action: save)
                        .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                        .disabled(saving || store.storageError != nil || isAuthenticating ||
                                  (needsCopilotAllowance && CopilotCreditUsage.parseAllowance(copilotAllowanceInput) == nil))
                }
            }
        }
        .padding(26).frame(width: 560)
        .onAppear {
            // Sheets focus their first text field; the optional name must not grab focus.
            DispatchQueue.main.async { NSApp.keyWindow?.makeFirstResponder(nil) }
        }
        .onChange(of: provider) { _, _ in
            github.reset()
            openAI.reset()
            kimi.reset()
            claude.reset()
            kimiUsesKey = false
            claudeImportsSession = false
            usesAPI = provider.isAPIOnly
            copilotAllowanceInput = ""
            token = ""; accountID = ""; source = .keychain; credentialPath = nil; importMessage = nil; error = nil
        }
        .onChange(of: usesAPI) { _, _ in
            openAI.reset()
            kimi.reset()
            claude.reset()
            token = ""; error = nil; importMessage = nil
        }
        .onDisappear { apiSaveTask?.cancel(); github.cancel(); openAI.cancel(); kimi.cancel(); claude.cancel() }
    }

    @ViewBuilder
    private var setup: some View {
        if usesAPI {
            switch provider {
            case .openAI:
                keySteps(instruction: "Open Admin keys, create an Admin API key with only Usage: Read and copy it",
                         note: "Only organization owners can create admin keys.")
            case .anthropic:
                keySteps(instruction: "Open Admin keys, create an Admin API key and copy it",
                         note: "Admin keys require an organization admin role.")
            default:
                keySteps(instruction: "Open API keys, create a key and copy it")
            }
        } else {
            switch provider {
            case .openCode:
                keySteps(dashboard: provider.consoleURL,
                         instruction: "Open Account › Personal API keys, create a key and copy it", canImport: true)
            case .githubCopilot: githubSetup
            case .openAI: openAISetup
            case .moonshot: usesKimiLogin ? AnyView(kimiSetup) : AnyView(kimiKeySetup)
            case .anthropic: claudeSetup
            case .deepSeek: EmptyView()
            }
        }
    }

    private func keySteps(dashboard: URL? = nil, instruction: String, note: String? = nil, canImport: Bool = false) -> some View {
        SetupSteps {
            SetupStep(1, "Open the \(provider.name) dashboard") {
                Button("Open dashboard ↗") { NSWorkspace.shared.open(dashboard ?? provider.apiConsoleURL) }
            }
            SetupStep(2, instruction) {
                if let note { Text(note).font(.caption).foregroundStyle(.secondary) }
            }
            SetupStep(3, "Paste the key") {
                SecureField(existing == nil ? "Paste key" : "New key (leave blank to keep current)", text: $token)
                    .textFieldStyle(.roundedBorder).textContentType(.password).multilineTextAlignment(.center)
                    .frame(width: 300)
                if canImport {
                    Button("Import from OpenCode", action: importOpenCode)
                    if let importMessage { Text(importMessage).font(.caption).foregroundStyle(.secondary) }
                }
            }
        }
    }

    private var kimiKeySetup: some View {
        VStack(spacing: 22) {
            keySteps(dashboard: international ? URL(string: "https://www.kimi.ai/code/console")! : provider.consoleURL,
                     instruction: "Open API keys, create a key and copy it")
            if international {
                Button("Use browser sign-in instead") { token = ""; kimiUsesKey = false }.buttonStyle(.link)
            }
        }
    }

    private var kimiSetup: some View {
        VStack(spacing: 22) {
            SetupSteps {
                SetupStep(1, "Sign in with Kimi") {
                    signInControls(button: "Sign in with Kimi", again: "Sign in again", isSigningIn: kimi.isSigningIn,
                                   phase: kimi.phase, signedIn: kimiAccountName.map { "Signed in as \($0)" },
                                   error: kimi.error) { error = nil; kimi.start() }
                }
                if kimi.isSigningIn, let authorization = kimi.authorization {
                    SetupStep(2, "Enter the code on Kimi") {
                        DeviceCodeView(code: authorization.userCode, initiallyCopied: true).id(authorization.userCode)
                        Link("Open Kimi sign-in ↗", destination: authorization.verificationURI).font(.caption)
                    }
                }
            }
            if !kimi.isSigningIn {
                Button("Use an API key instead") { kimi.reset(); kimiUsesKey = true }.buttonStyle(.link)
            }
        }
    }

    private var githubSetup: some View {
        SetupSteps {
            SetupStep(1, "Sign in with GitHub") {
                signInControls(button: "Sign in with GitHub", isSigningIn: github.isSigningIn, phase: github.phase,
                               signedIn: copilotAccountName.map { "Signed in as \($0.hasPrefix("@") ? $0 : "@\($0)")" },
                               error: github.error, canSignIn: copilotAccountName == nil) { error = nil; github.start() }
            }
            if github.isSigningIn, let authorization = github.authorization {
                SetupStep(2, "Enter the code on GitHub") {
                    DeviceCodeView(code: authorization.userCode, initiallyCopied: true).id(authorization.userCode)
                }
            }
            if needsCopilotAllowance && !github.isSigningIn {
                SetupStep(2, "Enter your monthly credit allowance") {
                    HStack {
                        TextField("Monthly credits", text: $copilotAllowanceInput, prompt: Text("e.g. 1000"))
                            .textFieldStyle(.roundedBorder).multilineTextAlignment(.center).frame(width: 200)
                            .accessibilityLabel("Monthly allowance in GitHub credits")
                        Text("credits").foregroundStyle(.secondary)
                    }
                    Text("GitHub reports credits used, but not the limit.").font(.caption).foregroundStyle(.secondary)
                    if !copilotAllowanceInput.isEmpty, CopilotCreditUsage.parseAllowance(copilotAllowanceInput) == nil {
                        Text("Enter a number greater than zero, without thousands separators.")
                            .font(.caption).foregroundStyle(.red)
                    }
                }
            }
        }
    }

    private var openAISetup: some View {
        SetupSteps {
            SetupStep(1, "Sign in with ChatGPT") {
                signInControls(button: "Sign in with ChatGPT", isSigningIn: openAI.isSigningIn, phase: openAI.phase,
                               signedIn: openAIAccountName.map { "Signed in as \($0)" },
                               error: openAI.error, canSignIn: openAIAccountName == nil) { error = nil; openAI.start() }
                if openAI.error != nil {
                    Link("Codex setup ↗", destination: URL(string: "https://developers.openai.com/codex/cli/")!).font(.caption)
                }
            }
        }
    }

    private var claudeSetup: some View {
        VStack(spacing: 22) {
            SetupSteps {
                if claudeImportsSession {
                    SetupStep(1, "Sign in to Claude Code in Terminal") {
                        Text("claude auth login").font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                    }
                    SetupStep(2, "Import the session") {
                        Button("Import session", action: importClaude)
                        if !token.isEmpty { Label("Session imported", systemImage: "checkmark.circle").foregroundStyle(.secondary) }
                    }
                } else {
                    SetupStep(1, "Sign in with Claude") {
                        signInControls(button: "Sign in with Claude", isSigningIn: claude.isSigningIn, phase: claude.phase,
                                       signedIn: claude.credential == nil ? nil : "Signed in", error: claude.error) {
                            token = ""; error = nil; claude.start()
                        }
                    }
                }
            }
            if !claude.isSigningIn {
                Button(claudeImportsSession ? "Sign in with Claude instead" : "Import an existing session instead") {
                    claude.reset(); token = ""; error = nil; importMessage = nil
                    claudeImportsSession.toggle()
                }.buttonStyle(.link)
            }
        }
    }

    @ViewBuilder
    private func signInControls(button: String, again: String? = nil, isSigningIn: Bool, phase: String, signedIn: String?,
                                error: String?, canSignIn: Bool = true, action: @escaping () -> Void) -> some View {
        if isSigningIn {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(phase).font(.callout).foregroundStyle(.secondary)
            }
        } else {
            if let signedIn { Label(signedIn, systemImage: "checkmark.circle").foregroundStyle(.secondary) }
            if canSignIn && (signedIn == nil || again != nil) {
                Button(signedIn == nil ? button : again ?? button, action: action)
                    .buttonStyle(.borderedProminent).disabled(saving || store.storageError != nil)
            }
            if let error {
                Text(error).font(.caption).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            }
        }
    }

    private var defaultAccountLabel: String {
        let base = provider == .openCode ? "OpenCode Go" : provider.name + (usesAPI ? " API" : "")
        let others = store.accounts.filter { $0.provider == provider && $0.isAPI == usesAPI && $0.id != existing?.id }
        guard !others.isEmpty else { return base }
        let taken = Set(others.map(\.email))
        var n = others.count + 1
        while taken.contains("\(base) #\(n)") { n += 1 }
        return "\(base) #\(n)"
    }

    private func importOpenCode() {
        do {
            token = try SessionImport.openCodeGo().credential.accessToken
            importMessage = "Key imported."
            error = nil
        } catch { importMessage = nil; self.error = error.localizedDescription }
    }

    private func importClaude() {
        do {
            claude.reset()
            let session = try SessionImport.claudeDefault()
            token = session.credential.accessToken
            source = .keychain
            importMessage = nil
            error = nil
        } catch { self.error = error.localizedDescription }
    }

    private func save() {
        if usesAPI { saveAPIAccount(); return }
        if provider == .openCode {
            let secret = token.trimmingCharacters(in: .whitespacesAndNewlines)
            let typed = email.trimmingCharacters(in: .whitespacesAndNewlines)
            guard typed.rangeOfCharacter(from: .controlCharacters) == nil,
                  secret.rangeOfCharacter(from: .controlCharacters) == nil else {
                error = "Name and key must not contain line breaks."; return
            }
            guard !secret.isEmpty || existing != nil else { error = "Paste a key or import it from OpenCode."; return }
            let label = typed.isEmpty ? (existing?.email ?? defaultAccountLabel) : typed
            saveVerifiedKeyAccount(Account(id: existing?.id ?? UUID(), provider: .openCode, email: label), secret: secret)
            return
        }
        let typedLabel = (provider == .githubCopilot ? github.identity?.login ?? existing?.email ?? ""
                     : provider == .openAI ? openAIAccountName ?? ""
                     : usesKimiLogin ? kimiAccountName ?? "" : email)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let label = namesAreOptional && typedLabel.isEmpty ? (existing?.email ?? defaultAccountLabel) : typedLabel
        guard !label.isEmpty, label.rangeOfCharacter(from: .controlCharacters) == nil else {
            error = provider.usesEmailLabel ? "Enter an account email." : "Enter an account name."
            return
        }
        if provider.usesEmailLabel, provider != .openAI, !namesAreOptional,
           label.range(of: #"^[^@\s]+@[^@\s]+\.[^@\s]+$"#, options: .regularExpression) == nil {
            error = "Enter a valid email address to identify this account."
            return
        }
        let secret = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !secret.contains("\n"), !secret.contains("\r"), !accountID.contains("\n"), !accountID.contains("\r") else {
            error = "Credentials must not contain line breaks."; return
        }
        if provider == .githubCopilot, github.credential == nil, existing == nil {
            error = "Sign in with GitHub to verify Copilot usage access."; return
        }
        if usesKimiLogin, kimi.credential == nil, existing == nil {
            error = "Sign in with Kimi to verify your account and usage."; return
        }
        if provider != .githubCopilot, provider != .openAI, !usesKimiLogin,
           source == .keychain, secret.isEmpty, existing?.source != .keychain, claude.credential == nil {
            error = "Enter a credential or import an OAuth session."; return
        }
        if provider == .openAI, openAI.identity == nil, existing == nil {
            error = "Sign in with ChatGPT to verify your account and usage."; return
        }
        let monthlyAllowance = needsCopilotAllowance ? CopilotCreditUsage.parseAllowance(copilotAllowanceInput) : nil
        if needsCopilotAllowance, monthlyAllowance == nil {
            error = "Enter a monthly allowance greater than zero, in GitHub credits."; return
        }
        let managedSession = provider == .openAI ? openAI.session : nil
        let account = Account(id: existing?.id ?? UUID(), provider: provider, email: label,
                               source: managedSession == nil ? source : .codexAppServer,
                               credentialPath: managedSession?.home.path ?? credentialPath,
                                externalAccountID: provider == .githubCopilot
                                    ? github.credential?.accountID ?? existing?.externalAccountID
                                     : provider == .openAI ? openAI.identity?.accountID ?? existing?.externalAccountID
                                     : usesKimiLogin ? kimi.credential?.accountID ?? existing?.externalAccountID
                                    : accountID.isEmpty ? nil : accountID,
                                kimiInternational: international, copilotMonthlyAllowance: monthlyAllowance)
        saving = true
        do {
            var credential: Credential?
            if provider == .openAI {
                // The official CLI owns tokens for managed sessions; preserve legacy credentials unchanged.
                credential = nil
            } else if provider == .githubCopilot {
                credential = github.credential
            } else if usesKimiLogin {
                credential = kimi.credential
            } else if provider == .anthropic, secret.isEmpty, let signedIn = claude.credential {
                credential = signedIn
            } else if source == .keychain {
                if !secret.isEmpty { credential = Credential(accessToken: secret, accountID: account.externalAccountID) }
                else if provider == .openAI, let existing {
                    var stored = try Keychain.read(for: existing.id)
                    stored.accountID = account.externalAccountID
                    credential = stored
                }
            }
            try store.save(account, credential: credential, openAISession: managedSession)
            openAI.detachSession()
            onSaved(account.id)
            dismiss()
        } catch { self.error = error.localizedDescription; saving = false }
    }

    private func saveAPIAccount() {
        let typed = email.trimmingCharacters(in: .whitespacesAndNewlines)
        let label = typed.isEmpty ? (existing?.email ?? defaultAccountLabel) : typed
        let secret = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty, label.rangeOfCharacter(from: .controlCharacters) == nil else {
            error = "Enter an account name."; return
        }
        guard secret.rangeOfCharacter(from: .controlCharacters) == nil,
              !secret.isEmpty || existing?.isAPI == true else {
            error = "Enter an API key without line breaks."; return
        }
        guard provider.supportsAPIBilling else { return }
        let account = Account(id: existing?.id ?? UUID(), provider: provider, email: label,
                              kimiInternational: true, apiAccess: true)
        saveVerifiedKeyAccount(account, secret: secret)
    }

    private func saveVerifiedKeyAccount(_ account: Account, secret: String) {
        saving = true
        error = nil
        apiSaveTask = Task { @MainActor in
            do {
                let credential: Credential
                if secret.isEmpty {
                    credential = try Keychain.read(for: account.id, allowInteraction: true)
                } else {
                    credential = Credential(accessToken: secret)
                }
                // Validate actual billing/Go quota access, not just the ability to list models.
                _ = try await UsageClient().fetch(account: account, credential: credential)
                try Task.checkCancellation()
                try store.save(account, credential: credential)
                onSaved(account.id)
                dismiss()
            } catch {
                guard !Task.isCancelled else { return }
                self.error = error.localizedDescription
                saving = false
                apiSaveTask = nil
            }
        }
    }
}

private struct SetupSteps<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(spacing: 30) { content }.frame(maxWidth: .infinity)
    }
}

private struct SetupStep<Content: View>: View {
    let number: Int
    let title: String
    @ViewBuilder var content: Content
    init(_ number: Int, _ title: String, @ViewBuilder content: () -> Content) {
        self.number = number; self.title = title; self.content = content()
    }
    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 10) {
                Text("\(number)").font(.caption.weight(.bold)).foregroundStyle(.secondary)
                    .frame(width: 22, height: 22).background(.primary.opacity(0.08), in: Circle())
                Text(title).font(.callout.weight(.medium)).multilineTextAlignment(.center)
            }
            VStack(spacing: 10) { content }
        }
        .frame(maxWidth: .infinity)
    }
}
