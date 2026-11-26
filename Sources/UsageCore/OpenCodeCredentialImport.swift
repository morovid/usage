import Foundation

/// Imports only provider/credential combinations with supported quota or balance endpoints.
public enum OpenCodeCredentialImport {
    public static func read(providerID: String) throws -> Credential {
        let env = ProcessInfo.processInfo.environment
        let base = env["XDG_DATA_HOME"].flatMap { $0.hasPrefix("/") ? URL(fileURLWithPath: $0) : nil }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/share")
        let url = base.appendingPathComponent("opencode/auth.json")
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 1_000_000,
              let data = try? Data(contentsOf: url),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw invalid()
        }
        return try parse(document: root, providerID: providerID)
    }

    public static func parse(document: [String: Any], providerID: String, now: Date = Date()) throws -> Credential {
        guard let entry = document[providerID] as? [String: Any] else { throw invalid() }
        switch providerID {
        case "opencode-go", "deepseek", "moonshotai":
            guard entry["type"] as? String == "api", let key = entry["key"] as? String, valid(key) else { throw invalid() }
            return Credential(accessToken: key)
        case "github-copilot":
            // Import the existing GitHub access token, never the refresh field.
            guard entry["type"] as? String == "oauth",
                  let access = entry["access"] as? String, valid(access),
                  let expiry = UsageParser.number(entry["expires"]),
                  expiry == 0 || expiry / 1000 > now.timeIntervalSince1970 else { throw invalid() }
            return Credential(accessToken: access)
        default: throw invalid()
        }
    }

    private static func valid(_ key: String) -> Bool {
        !key.isEmpty && key.rangeOfCharacter(from: .whitespacesAndNewlines.union(.controlCharacters)) == nil
    }

    private static func invalid() -> UsageError {
        .message("No supported, current credential found in OpenCode. Reconnect that provider in OpenCode and try again.")
    }
}
