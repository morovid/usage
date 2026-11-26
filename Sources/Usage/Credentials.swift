import Foundation
import Security
import LocalAuthentication
import UsageCore

enum CredentialAccessError: LocalizedError {
    case approvalRequired
    var errorDescription: String? {
        "Keychain access needs approval. Open Accounts and choose Allow Keychain access. Background checks will not show permission dialogs."
    }
}

/// All account credentials live in one Keychain item, so a single approval covers every account.
/// Items from older versions (one per account) are migrated into it. Safe to call from any thread.
enum Keychain {
    static let service = "app.morovid.Usage.credentials"
    private static let vaultAccount = "vault"
    private final class State: @unchecked Sendable {
        let lock = NSLock()
        var credentials: [UUID: Credential] = [:]
        var loaded = false
        var dirty = false
    }
    private static let state = State()

    private static func locked<T>(_ body: (State) -> T) -> T {
        state.lock.lock(); defer { state.lock.unlock() }
        return body(state)
    }

    /// Loads the vault and migrates legacy per-account items. Returns accounts whose legacy item needs approval.
    @discardableResult
    static func load(allowInteraction: Bool, legacyIDs: [UUID] = []) throws -> Set<UUID> {
        if !locked({ $0.loaded }) {
            var map: [UUID: Credential] = [:]
            if let data = try copy(service: service, account: vaultAccount, allowInteraction: allowInteraction) {
                let raw = try JSONDecoder().decode([String: Credential].self, from: data)
                for (key, value) in raw { if let id = UUID(uuidString: key) { map[id] = value } }
            }
            locked { state in
                // Anything saved while loading wins over the stored copy.
                state.credentials = map.merging(state.credentials) { _, new in new }
                state.loaded = true
            }
        }
        return migrateLegacy(legacyIDs.filter { id in locked { $0.credentials[id] == nil } }, allowInteraction: allowInteraction)
    }

    private static func migrateLegacy(_ ids: [UUID], allowInteraction: Bool) -> Set<UUID> {
        var denied: Set<UUID> = []
        var migrated: [UUID] = []
        for id in ids {
            do {
                guard let data = try copy(service: service, account: id.uuidString, allowInteraction: allowInteraction),
                      let credential = try? JSONDecoder().decode(Credential.self, from: data) else { continue }
                locked { $0.credentials[id] = credential }
                migrated.append(id)
            } catch { denied.insert(id) }
        }
        guard !migrated.isEmpty else { return denied }
        do {
            try persist(allowInteraction: allowInteraction)
            for id in migrated { deleteItem(account: id.uuidString) }
        } catch { locked { $0.dirty = true } }
        return denied
    }

    static func save(_ credential: Credential, for id: UUID, allowInteraction: Bool = true) throws {
        try load(allowInteraction: allowInteraction)
        let previous = locked { state -> Credential? in
            let old = state.credentials[id]
            state.credentials[id] = credential
            return old
        }
        do { try persist(allowInteraction: allowInteraction) } catch {
            if allowInteraction {
                locked { $0.credentials[id] = previous }
            } else {
                // A rotated OAuth token must not be lost if Keychain is temporarily locked.
                locked { $0.dirty = true }
            }
            throw error
        }
    }

    static func read(for id: UUID, allowInteraction: Bool = false) throws -> Credential {
        try load(allowInteraction: allowInteraction)
        if locked({ $0.credentials[id] == nil }) {
            if migrateLegacy([id], allowInteraction: allowInteraction).contains(id) { throw CredentialAccessError.approvalRequired }
        }
        guard let credential = locked({ $0.credentials[id] }) else {
            throw UsageError.message("Credential not found. Import a signed-in session or enter a token.")
        }
        if locked({ $0.dirty }) { try persist(allowInteraction: allowInteraction) }
        return credential
    }

    static func read(service: String, account: String? = nil, allowInteraction: Bool = true) throws -> Data {
        guard let data = try copy(service: service, account: account, allowInteraction: allowInteraction) else {
            throw UsageError.message("Credential not found. Import a signed-in session or enter a token.")
        }
        return data
    }

    static func delete(for id: UUID) throws {
        try load(allowInteraction: true)
        let removed = locked { $0.credentials.removeValue(forKey: id) }
        if removed != nil {
            do { try persist(allowInteraction: true) } catch {
                locked { $0.credentials[id] = removed }
                throw error
            }
        }
        deleteItem(account: id.uuidString)
    }

    private static func copy(service: String, account: String?, allowInteraction: Bool) throws -> Data? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        if let account { query[kSecAttrAccount as String] = account }
        if !allowInteraction {
            let context = LAContext()
            context.interactionNotAllowed = true
            query[kSecUseAuthenticationContext as String] = context
        }
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        try check(status)
        guard let data = result as? Data else { throw UsageError.message("No credential was found in Keychain.") }
        return data
    }

    private static func persist(allowInteraction: Bool) throws {
        let snapshot = locked { state in Dictionary(uniqueKeysWithValues: state.credentials.map { ($0.key.uuidString, $0.value) }) }
        let data = try JSONEncoder().encode(snapshot)
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: vaultAccount
        ]
        if !allowInteraction {
            let context = LAContext()
            context.interactionNotAllowed = true
            query[kSecUseAuthenticationContext as String] = context
        }
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            // The creating, signed application is trusted by the item's default ACL.
            // Never grant access to arbitrary applications or change other apps' ACLs.
            try check(SecItemAdd(item as CFDictionary, nil))
        } else { try check(status) }
        locked { $0.dirty = false }
    }

    private static func deleteItem(account: String) {
        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ] as CFDictionary)
    }

    private static func check(_ status: OSStatus) throws {
        guard status == errSecSuccess else {
            if status == errSecInteractionNotAllowed || status == errSecAuthFailed || status == errSecUserCanceled {
                throw CredentialAccessError.approvalRequired
            }
            if status == errSecItemNotFound {
                throw UsageError.message("Credential not found. Import a signed-in session or enter a token.")
            }
            throw UsageError.message("Keychain: \(SecCopyErrorMessageString(status, nil) as String? ?? "access failed")")
        }
    }
}

struct ImportedSession {
    var credential: Credential
    var email: String?
}

enum SessionImport {
    @MainActor
    static func claudeDefault() throws -> ImportedSession {
        let path = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/.credentials.json")
        let data = FileManager.default.fileExists(atPath: path.path)
            ? try Data(contentsOf: path) : try Keychain.read(service: "Claude Code-credentials")
        guard data.count < 1_000_000 else { throw UsageError.message("The Claude credential file is too large.") }
        return try claude(data: data)
    }

    static func claude(data: Data) throws -> ImportedSession {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = root["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String, !token.isEmpty else {
            throw UsageError.message("This is not a Claude Code OAuth credential file. Run `claude auth login` first.")
        }
        return ImportedSession(credential: Credential(accessToken: token), email: nil)
    }

    static func openCodeGo() throws -> ImportedSession {
        let env = ProcessInfo.processInfo.environment
        let base = env["XDG_DATA_HOME"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/share")
        let url = base.appendingPathComponent("opencode/auth.json")
        guard let data = try? Data(contentsOf: url), data.count < 1_000_000 else {
            throw UsageError.message("No OpenCode login found. Run /connect in OpenCode and choose OpenCode Go, or paste a key.")
        }
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entry = root["opencode-go"] as? [String: Any],
              let key = entry["key"] as? String, !key.isEmpty else {
            throw UsageError.message("OpenCode has no OpenCode Go key. Run /connect and choose OpenCode Go, or paste a key.")
        }
        return ImportedSession(credential: Credential(accessToken: key), email: nil)
    }

    static func codex(path: String) throws -> ImportedSession {
        let url = URL(fileURLWithPath: path)
        let data = try Data(contentsOf: url)
        guard data.count < 1_000_000,
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = root["tokens"] as? [String: Any],
              let token = tokens["access_token"] as? String, !token.isEmpty,
              let accountID = tokens["account_id"] as? String, !accountID.isEmpty else {
            throw UsageError.message("No Codex OAuth session found. Run `codex login` (not API-key login) first.")
        }
        let identity = (tokens["id_token"] as? String).flatMap(jwtPayload)
        return ImportedSession(credential: Credential(accessToken: token, accountID: accountID),
                               email: identity?["email"] as? String)
    }

    /// Used only as a suggested label, never as verification or authorization.
    static func jwtPayload(_ token: String) -> [String: Any]? {
        let parts = token.split(separator: ".")
        guard parts.count == 3 else { return nil }
        var base64 = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        guard let data = Data(base64Encoded: base64) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}
