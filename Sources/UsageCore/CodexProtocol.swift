import Foundation

public struct ChatGPTIdentity: Equatable, Sendable {
    public var email: String?
    public var accountID: String?
    public var label: String { email ?? "ChatGPT account" }

    public static func parse(_ result: [String: Any]) throws -> ChatGPTIdentity {
        guard let account = result["account"] as? [String: Any],
              account["type"] as? String == "chatgpt" else {
            throw UsageError.message("No ChatGPT session is available. Sign in with ChatGPT again.")
        }
        let email = (account["email"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return ChatGPTIdentity(email: email?.isEmpty == false ? email : nil,
                               accountID: account["id"] as? String ?? account["accountId"] as? String)
    }
}

public struct ChatGPTLogin: Sendable {
    public let id: String
    public let url: URL

    public static func parse(_ result: [String: Any]) throws -> ChatGPTLogin {
        guard result["type"] as? String == "chatgpt",
              let id = result["loginId"] as? String, !id.isEmpty,
              let rawURL = result["authUrl"] as? String, let url = URL(string: rawURL),
              url.scheme == "https", ["auth.openai.com", "chatgpt.com"].contains(url.host),
              url.user == nil, url.password == nil, url.port == nil || url.port == 443 else {
            throw UsageError.message("Codex returned an unexpected ChatGPT sign-in URL. Update the official Codex CLI and try again.")
        }
        return ChatGPTLogin(id: id, url: url)
    }
}

public enum CodexProtocol {
    public static func sessionHome(root: URL, id: UUID) -> URL {
        root.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    public static func validateSessionHome(_ path: String, root: URL) throws -> URL {
        let home = URL(fileURLWithPath: path).standardizedFileURL
        let parent = home.deletingLastPathComponent()
        guard UUID(uuidString: home.lastPathComponent) != nil,
              parent.resolvingSymlinksInPath().path == root.standardizedFileURL.resolvingSymlinksInPath().path,
              home.resolvingSymlinksInPath().deletingLastPathComponent().path ==
                root.standardizedFileURL.resolvingSymlinksInPath().path else {
            throw UsageError.message("The ChatGPT session location is invalid. Remove this account and sign in again.")
        }
        return home
    }

    public static func rateLimits(_ result: [String: Any], now: Date = Date()) throws -> UsageSnapshot {
        var windows: [UsageWindow] = []
        func append(_ raw: Any?, id: String, fallbackName: String? = nil) {
            guard let bucket = raw as? [String: Any] else { return }
            let name = bucket["limitName"] as? String ?? fallbackName
            for key in ["primary", "secondary"] {
                guard let item = bucket[key] as? [String: Any],
                      let percent = UsageParser.number(item["usedPercent"]), percent >= 0,
                      let minutes = UsageParser.number(item["windowDurationMins"]), minutes > 0,
                      minutes <= 525_600 else { continue }
                let duration = minutes * 60
                let label = UsageParser.durationLabel(duration)
                windows.append(UsageWindow(id: "\(id)-\(key)",
                    label: name.map { "\($0) · \(label)" } ?? label,
                    usedPercent: percent, duration: duration, resetsAt: UsageParser.date(item["resetsAt"])))
            }
        }
        if let buckets = result["rateLimitsByLimitId"] as? [String: Any], !buckets.isEmpty {
            for key in buckets.keys.sorted() {
                append(buckets[key], id: key, fallbackName: key == "codex" ? nil : key)
            }
        }
        // A malformed/empty multi-bucket response can still carry the legacy main bucket.
        if windows.isEmpty, let main = result["rateLimits"] as? [String: Any] {
            append(main, id: main["limitId"] as? String ?? "codex")
        }
        guard !windows.isEmpty else {
            throw UsageError.message("OpenAI did not report any supported finite ChatGPT/Codex quota windows for this account. No usage percentage has been estimated.")
        }
        return UsageSnapshot(windows: windows, fetchedAt: now)
    }
}
