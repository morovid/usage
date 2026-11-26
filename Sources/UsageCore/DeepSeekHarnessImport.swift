import Foundation
import Yams

/// Reads only DeepSeek's known credential records. Never executes Harness or evaluates YAML tags.
public enum DeepSeekHarnessImport {
    public static func read(home: URL? = nil) throws -> Credential {
        let environment = ProcessInfo.processInfo.environment
        let directory = home ?? environment["DSH_HOME"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".dsh")
        let url = directory.appendingPathComponent(".credentials.yaml")
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 1_000_000,
              let data = try? Data(contentsOf: url) else {
            throw UsageError.message("No DeepSeek Harness credentials found. Sign in to DeepSeek in Harness, then import again.")
        }
        return try parse(data)
    }

    public static func parse(_ data: Data) throws -> Credential {
        guard data.count <= 1_000_000 else { throw invalid() }
        let root: [String: Any]
        do {
            guard let text = String(data: data, encoding: .utf8),
                  let document = try Yams.load(yaml: text) as? [String: Any] else { throw invalid() }
            root = document
        } catch { throw invalid() } // YAML diagnostics can contain secrets.
        guard root["version"] as? Int == 1 else { throw invalid() }
        let records = root["records"] as? [String: Any] ?? [:]
        if let account = records["deepseek-account-platform/default"] as? [String: Any],
           account["kind"] as? String == "grant",
           let grant = account["payload"] as? [String: Any],
           grant["version"] as? Int == 1,
           grant["issuer"] as? String == "https://platform.deepseek.com",
           let token = grant["token"] as? String, valid(token) {
            var credential = Credential(accessToken: token)
            credential.deepSeekHarness = true
            return credential
        }
        // Only the standard DeepSeek provider/reference, never another provider's credentials.
        if let refs = root["refs"] as? [String: Any],
           let key = refs["DEEPSEEK_API_KEY"] as? String, valid(key) {
            return Credential(accessToken: key)
        }
        throw invalid()
    }

    private static func valid(_ value: String) -> Bool {
        !value.isEmpty && value.rangeOfCharacter(from: .whitespacesAndNewlines.union(.controlCharacters)) == nil
    }

    private static func invalid() -> UsageError {
        .message("No supported DeepSeek credential found. Sign in to DeepSeek in Harness, or use an API key.")
    }
}
