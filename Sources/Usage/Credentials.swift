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

@MainActor
enum Keychain {
    static let service = "app.morovid.Usage.credentials"
    private static var credentials: [UUID: Credential] = [:]
    private static var pendingWrites: Set<UUID> = []

    static func save(_ credential: Credential, for id: UUID, allowInteraction: Bool = true) throws {
        let data = try JSONEncoder().encode(credential)
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id.uuidString
        ]
        if !allowInteraction {
            let context = LAContext()
            context.interactionNotAllowed = true
            query[kSecUseAuthenticationContext as String] = context
        }
        do {
            let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
            if status == errSecItemNotFound {
                var item = query
                item[kSecValueData as String] = data
                item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
                // The creating, signed application is trusted by the item's default ACL.
                // Never grant access to arbitrary applications or change other apps' ACLs.
                try check(SecItemAdd(item as CFDictionary, nil))
            } else { try check(status) }
            credentials[id] = credential
            pendingWrites.remove(id)
        } catch {
            if !allowInteraction {
                // A rotated OAuth token must not be lost if Keychain is temporarily locked.
                credentials[id] = credential
                pendingWrites.insert(id)
            }
            throw error
        }
    }

    static func read(for id: UUID, allowInteraction: Bool = false) throws -> Credential {
        if let credential = credentials[id] {
            if pendingWrites.contains(id) {
                try save(credential, for: id, allowInteraction: allowInteraction)
            }
            return credential
        }
        let data = try read(service: service, account: id.uuidString, allowInteraction: allowInteraction)
        let credential = try JSONDecoder().decode(Credential.self, from: data)
        credentials[id] = credential
        return credential
    }

    static func read(service: String, account: String? = nil, allowInteraction: Bool = true) throws -> Data {
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
        try check(SecItemCopyMatching(query as CFDictionary, &result))
        guard let data = result as? Data else { throw UsageError.message("No credential was found in Keychain.") }
        return data
    }

    static func delete(for id: UUID) throws {
        let status = SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id.uuidString
        ] as CFDictionary)
        if status != errSecItemNotFound { try check(status) }
        credentials.removeValue(forKey: id)
        pendingWrites.remove(id)
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
