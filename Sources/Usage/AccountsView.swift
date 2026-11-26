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
                    .onMove { offsets, destination in
                        do { try store.moveAccounts(from: offsets, to: destination) }
                        catch { self.error = error.localizedDescription }
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
        .alert("Could not update accounts", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
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
    @State private var claudeImportsSession = false
    @State private var importedClaudeName: String?
    @State private var importsProviderSession = false
    @State private var importedCredential: Credential?
    @State private var copilotAllowanceInput: String
    @State private var usesAPI: Bool
    @State private var apiSaveTask: Task<Void, Never>?
    @State private var detectedHarnesses: [DetectedHarness] = []
    @State private var detecting = true
    @State private var choosingDetected = true
    @State private var selectedDetection: DetectedHarness?
    @State private var detectedName = ""
    @AppStorage("dismissedLocalAccountSuggestions") private var dismissedDetectionIDs = ""

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
    private var usesKimiLogin: Bool { provider == .moonshot && !usesAPI }
    private var claudeAccountName: String? { claude.accountName ?? importedClaudeName }
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
        _importsProviderSession = State(initialValue: existing?.importsCLI ?? false)
        _choosingDetected = State(initialValue: existing == nil)
    }

    private var namesAreOptional: Bool { usesAPI || provider == .openCode || provider == .anthropic }

    var body: some View {
        Group {
            if choosingDetected { detectionView } else { editorView }
        }
        .task {
            guard existing == nil else { return }
            let found = await Task.detached(priority: .utility) {
                var found = LocalHarnessDetection.scan()
                if !found.contains(where: { $0.kind == .claudeCode }),
                   let claude = SessionImport.claudeKeychainDetected() {
                    found.insert(claude, at: 0)
                }
                return found
            }.value
            guard !Task.isCancelled else { return }
            detectedHarnesses = found
            detecting = false
            if availableDetections.isEmpty { choosingDetected = false }
        }
        .onDisappear { apiSaveTask?.cancel(); github.cancel(); openAI.cancel(); kimi.cancel(); claude.cancel() }
    }

    private var availableDetections: [DetectedHarness] {
        let cached = Dictionary(uniqueKeysWithValues: store.accounts.compactMap { account -> (UUID, String)? in
            guard let credential = Keychain.cachedCredential(for: account.id) else { return nil }
            return (account.id, LocalHarnessDetection.fingerprint(credential))
        })
        let dismissed = Set(dismissedDetectionIDs.split(separator: "\n").map(String.init))
        return detectedHarnesses.filter {
            !dismissed.contains($0.dismissalID) && !$0.isAdded(accounts: store.accounts, cachedFingerprints: cached)
        }
    }

    private func dismissDetection(_ detected: DetectedHarness) {
        var dismissed = Set(dismissedDetectionIDs.split(separator: "\n").map(String.init))
        dismissed.insert(detected.dismissalID)
        dismissedDetectionIDs = dismissed.sorted().joined(separator: "\n")
        selectedDetection = nil
        error = nil
        if availableDetections.isEmpty { choosingDetected = false }
    }

    private var detectionView: some View {
        VStack(spacing: 24) {
            Text("Detected on this Mac").font(.title2.bold()).frame(maxWidth: .infinity, alignment: .leading)
            if detecting {
                ProgressView("Looking for local sessions…").padding(.vertical, 24)
            } else if let detected = selectedDetection {
                VStack(spacing: 16) {
                    Text(detected.title).font(.headline)
                    if let name = detected.name {
                        Text(name).foregroundStyle(.secondary)
                    } else if detected.provider != .githubCopilot {
                        TextField("Account name (optional)", text: $detectedName, prompt: Text(detectedDefaultName(detected)))
                            .textFieldStyle(.roundedBorder).frame(width: 300)
                    }
                    Button(saving ? "Verifying…" : "Import account") { importDetected(detected) }
                        .buttonStyle(.borderedProminent).disabled(saving || store.storageError != nil)
                    Button("Remove") { dismissDetection(detected) }
                        .buttonStyle(.link).foregroundStyle(.secondary).disabled(saving)
                        .help("Hide this suggestion. The original account and login are not changed.")
                }.padding(.vertical, 12)
            } else {
                Text("Import a local session, or connect another account.")
                    .font(.callout).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                ForEach(availableDetections) { detected in
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(detected.title).fontWeight(.medium)
                            Text(detected.name ?? "Local session available")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Import") {
                            error = nil
                            if detected.name != nil || detected.provider == .githubCopilot {
                                importDetected(detected)
                            } else {
                                detectedName = ""
                                selectedDetection = detected
                            }
                        }.disabled(saving || store.storageError != nil)
                        Button("Remove") { dismissDetection(detected) }
                            .buttonStyle(.link).foregroundStyle(.secondary).disabled(saving)
                            .help("Hide this suggestion. The original account and login are not changed.")
                    }.padding(.vertical, 8)
                }
            }
            if let error {
                Text(error).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                if selectedDetection != nil {
                    Button("Back") { selectedDetection = nil; error = nil }.disabled(saving)
                } else {
                    Button("Connect manually") { choosingDetected = false; error = nil }.disabled(saving)
                }
                Spacer()
                Button("Cancel") { apiSaveTask?.cancel(); dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(26).frame(width: 560)
    }

    private func detectedDefaultName(_ detected: DetectedHarness) -> String {
        let base = detected.provider == .openCode ? "OpenCode Go" : detected.provider.name + (detected.isAPI ? " API" : "")
        let others = store.accounts.filter { $0.provider == detected.provider }
        guard !others.isEmpty else { return base }
        let taken = Set(others.map(\.email))
        var number = others.count + 1
        while taken.contains("\(base) #\(number)") { number += 1 }
        return "\(base) #\(number)"
    }

    private func importDetected(_ detected: DetectedHarness) {
        guard !saving else { return }
        saving = true
        error = nil
        apiSaveTask = Task { @MainActor in
            do {
                var session = try await Task.detached(priority: .userInitiated) { () throws -> ImportedSession in
                    switch detected.kind {
                    case .claudeCode: return try SessionImport.claudeDefault()
                    case .openCode: return try SessionImport.openCodeGo()
                    case .deepSeek: return ImportedSession(credential: try DeepSeekHarnessImport.read(), email: nil)
                    case .openCodeCopilot, .openCodeDeepSeek, .openCodeMoonshot:
                        guard let id = detected.openCodeProviderID else { throw UsageError.message("Unsupported OpenCode provider.") }
                        return ImportedSession(credential: try OpenCodeCredentialImport.read(providerID: id), email: nil)
                    }
                }.value
                try Task.checkCancellation()
                if detected.provider == .githubCopilot {
                    let identity = try await GitHubAuth().identity(credential: session.credential)
                    session.email = identity.login
                    session.credential.accountID = String(identity.id)
                }
                let fingerprint = LocalHarnessDetection.fingerprint(session.credential)
                let current = DetectedHarness(kind: detected.kind, name: session.email,
                                              fingerprint: fingerprint, accountID: session.credential.accountID)
                guard !current.isAdded(accounts: store.accounts) else {
                    throw UsageError.message("This account is already added.")
                }
                let name = (session.email ?? detected.name ?? detectedName).trimmingCharacters(in: .whitespacesAndNewlines)
                let label = name.isEmpty ? detectedDefaultName(detected) : name
                guard label.rangeOfCharacter(from: .controlCharacters) == nil else {
                    throw UsageError.message("Account names must not contain line breaks.")
                }
                let account = Account(provider: detected.provider, email: label,
                                      externalAccountID: session.credential.accountID,
                                      kimiInternational: true, apiAccess: detected.isAPI,
                                      importsCLI: true)
                do {
                    _ = try await UsageClient().fetch(account: account, credential: session.credential)
                } catch is CopilotAllowanceRequired {
                    // The identity and consumption are valid, but GitHub omitted the denominator.
                    // Save without inventing a quota; it can be configured in Edit.
                }
                try Task.checkCancellation()
                try store.save(account, credential: session.credential)
                onSaved(account.id)
                dismiss()
            } catch {
                guard !Task.isCancelled else { return }
                self.error = error.localizedDescription
                saving = false
            }
        }
    }

    private var editorView: some View {
        VStack(spacing: 28) {
            HStack {
                Text(existing == nil ? "Connect an account" : "Edit account").font(.title2.bold())
                Spacer()
            }
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
                if provider == .openCode || provider == .deepSeek {
                    Picker("Connection", selection: $importsProviderSession) {
                        Text(provider == .deepSeek ? "Harness / CLI" : "Import").tag(true)
                        Text("API key").tag(false)
                    }.pickerStyle(.segmented).disabled(isAuthenticating)
                }
                if provider == .anthropic && !usesAPI {
                    if let name = claudeAccountName {
                        TextField("Account name", text: .constant(name)).disabled(true)
                    } else if claude.credential != nil || !token.isEmpty || existing != nil {
                        TextField("Account name (optional)", text: $email, prompt: Text(existing?.email ?? defaultAccountLabel))
                    }
                } else if namesAreOptional {
                    TextField("Account name (optional)", text: $email, prompt: Text(existing?.email ?? defaultAccountLabel))
                }
                if provider == .moonshot {
                    TextField("Kimi region", text: .constant("Global")).disabled(true)
                }
            }
            .formStyle(.grouped).scrollDisabled(true).fixedSize(horizontal: false, vertical: true)
            .disabled(saving || claude.isSigningIn)

            setup.frame(maxWidth: .infinity).disabled(saving)

            if let error { Text(error).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
            HStack {
                Spacer()
                Button("Cancel") {
                    apiSaveTask?.cancel()
                    github.cancel(); openAI.cancel(); kimi.cancel(); claude.cancel(); dismiss()
                }.keyboardShortcut(.cancelAction)
                if canSaveAccount {
                    Button(saving ? "Verifying…" : existing == nil ? (usesAPI || provider == .openCode ? "Verify and add account" : "Add account") : "Save", action: { save() })
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
            claudeImportsSession = false
            importedClaudeName = nil
            importsProviderSession = false
            importedCredential = nil
            usesAPI = provider.isAPIOnly
            copilotAllowanceInput = ""
            token = ""; accountID = ""; source = .keychain; credentialPath = nil; importMessage = nil; error = nil
        }
        .onChange(of: usesAPI) { _, _ in
            openAI.reset()
            kimi.reset()
            claude.reset()
            importedClaudeName = nil
            token = ""; error = nil; importMessage = nil
        }
        .onChange(of: importsProviderSession) { _, _ in
            importedCredential = nil; token = ""; error = nil; importMessage = nil
        }
        .onChange(of: isAuthenticating) { wasAuthenticating, authenticating in
            guard wasAuthenticating, !authenticating, !saving, existing == nil, !usesAPI else { return }
            let succeeded: Bool
            switch provider {
            case .anthropic: succeeded = claude.credential != nil && claude.error == nil
            case .openAI: succeeded = openAI.identity != nil && openAI.error == nil
            case .moonshot: succeeded = kimi.credential != nil && kimi.error == nil
            case .githubCopilot: succeeded = github.credential != nil && github.error == nil
            default: succeeded = false
            }
            if succeeded { save(allowMissingCopilotAllowance: true) }
        }
        .onDisappear { apiSaveTask?.cancel(); github.cancel(); openAI.cancel(); kimi.cancel(); claude.cancel() }
    }

    @ViewBuilder
    private var setup: some View {
        if (provider == .deepSeek || provider == .openCode) && importsProviderSession {
            VStack(spacing: 16) {
                Button(provider == .deepSeek ? "Import from DeepSeek Harness" : "Import from OpenCode",
                       action: provider == .deepSeek ? importDeepSeek : importOpenCode)
                    .buttonStyle(.borderedProminent)
                Text(provider == .deepSeek
                     ? "Sign in to DeepSeek in Harness, then import the session."
                     : "Connect OpenCode Go in OpenCode, then import the key.")
                    .font(.caption).foregroundStyle(.secondary)
                if let importMessage { Text(importMessage).font(.caption).foregroundStyle(.secondary) }
            }
        } else if usesAPI {
            switch provider {
            case .openAI:
                keySteps(title: "Create Admin Key",
                         instruction: "Settings → Organization → Admin keys → Create new admin key",
                         note: "Requires an organization owner and Usage: Read (api.usage.read).",
                         placeholder: "sk-admin-abcd…")
            case .anthropic:
                keySteps(title: "Create Admin Key",
                         instruction: "Settings → Admin keys → Create admin key → Add",
                         note: "Requires the organization admin role. Console admin keys include analytics access; no scopes to select.",
                         placeholder: "sk-ant-admin01-abcd…")
            default:
                keySteps(instruction: "API keys → Create API key")
            }
        } else {
            switch provider {
            case .openCode:
                keySteps(dashboard: provider.consoleURL,
                         instruction: "Account → Personal API keys → Add API key", placeholder: "oc_sk_abcd…")
            case .githubCopilot: githubSetup
            case .openAI: openAISetup
            case .moonshot: kimiSetup
            case .anthropic: claudeSetup
            case .deepSeek: EmptyView()
            }
        }
    }

    private func keySteps(dashboard: URL? = nil, title: String = "Create API Key", instruction: String,
                          note: String? = nil, placeholder: String = "sk-abcd…") -> some View {
        SetupSteps {
            SetupStep(1, "Open the \(provider.name) dashboard") {
                Button("Open dashboard") { NSWorkspace.shared.open(dashboard ?? provider.apiConsoleURL) }
            }
            SetupStep(2, title) {
                Text(instruction).font(.callout).foregroundStyle(.secondary)
                if let note { Text(note).font(.caption).foregroundStyle(.secondary) }
            }
            SetupStep(3, "Paste the key") {
                SecureField(existing == nil ? placeholder : "New key (leave blank to keep current)", text: $token)
                    .textFieldStyle(.roundedBorder).textContentType(.password).multilineTextAlignment(.center)
                    .frame(width: 300)
            }
        }
    }

    private var kimiSetup: some View {
        VStack(spacing: 22) {
            SetupSteps {
                VStack(spacing: 12) {
                    signInControls(button: "Sign in with Kimi", again: "Sign in again", isSigningIn: kimi.isSigningIn,
                                   phase: kimi.phase, signedIn: kimiAccountName.map { "Signed in as \($0)" },
                                   error: kimi.error) { error = nil; kimi.start() }
                }
                if kimi.isSigningIn, let authorization = kimi.authorization {
                    VStack(spacing: 12) {
                        Text("Enter the code on Kimi").font(.callout.weight(.medium))
                        DeviceCodeView(code: authorization.userCode, initiallyCopied: true).id(authorization.userCode)
                        Link("Open Kimi sign-in ↗", destination: authorization.verificationURI).font(.caption)
                    }
                }
            }
        }
    }

    private var githubSetup: some View {
        SetupSteps {
            VStack(spacing: 12) {
                signInControls(button: "Sign in with GitHub", isSigningIn: github.isSigningIn, phase: github.phase,
                               signedIn: copilotAccountName.map { "Signed in as \($0.hasPrefix("@") ? $0 : "@\($0)")" },
                               error: github.error, canSignIn: copilotAccountName == nil) { error = nil; github.start() }
            }
            if github.isSigningIn, let authorization = github.authorization {
                VStack(spacing: 12) {
                    Text("Enter the code on GitHub").font(.callout.weight(.medium))
                    DeviceCodeView(code: authorization.userCode, initiallyCopied: true).id(authorization.userCode)
                }
            }
            if needsCopilotAllowance && !github.isSigningIn {
                VStack(spacing: 12) {
                    Text("Enter your monthly credit allowance").font(.callout.weight(.medium))
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
            VStack(spacing: 12) {
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
                    VStack(spacing: 12) {
                        signInControls(button: "Sign in with Claude", isSigningIn: claude.isSigningIn, phase: claude.phase,
                                       signedIn: claude.credential == nil ? nil : claudeAccountName.map { "Signed in as \($0)" } ?? "Signed in",
                                       error: claude.error) {
                            token = ""; error = nil; claude.start()
                        }
                    }
                }
            }
            if !claude.isSigningIn {
                Button(claudeImportsSession ? "Sign in with Claude" : "Import existing session") {
                    claude.reset(); token = ""; error = nil; importMessage = nil
                    importedClaudeName = nil
                    claudeImportsSession.toggle()
                }.buttonStyle(.link).font(.caption)
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

    private func importDeepSeek() {
        saving = true
        error = nil
        apiSaveTask = Task { @MainActor in
            do {
                let credential = try await Task.detached(priority: .userInitiated) {
                    try DeepSeekHarnessImport.read()
                }.value
                try Task.checkCancellation()
                importedCredential = credential
                token = credential.accessToken
                importMessage = "Session imported."
                saving = false
            } catch {
                guard !Task.isCancelled else { return }
                self.error = error.localizedDescription
                saving = false
            }
        }
    }

    private func importClaude() {
        do {
            claude.reset()
            let session = try SessionImport.claudeDefault()
            token = session.credential.accessToken
            importedClaudeName = session.email
            source = .keychain
            importMessage = nil
            error = nil
        } catch { self.error = error.localizedDescription }
    }

    private func save(allowMissingCopilotAllowance: Bool = false) {
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
            saveVerifiedKeyAccount(Account(id: existing?.id ?? UUID(), provider: .openCode, email: label,
                                           importsCLI: importsProviderSession), secret: secret)
            return
        }
        let typedLabel = (provider == .githubCopilot ? github.identity?.login ?? existing?.email ?? ""
                     : provider == .openAI ? openAIAccountName ?? ""
                     : provider == .anthropic ? claudeAccountName ?? email
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
        // OAuth completion should close the sheet even if GitHub omits the quota
        // denominator. Keep it unknown; the allowance can be supplied in Edit.
        if needsCopilotAllowance, monthlyAllowance == nil, !allowMissingCopilotAllowance {
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
                                kimiInternational: provider == .moonshot ? true : international, copilotMonthlyAllowance: monthlyAllowance)
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
                              kimiInternational: true, apiAccess: true,
                              importsCLI: provider == .deepSeek ? importsProviderSession : nil)
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
                    credential = importedCredential ?? Credential(accessToken: secret)
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
