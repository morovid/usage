import Foundation
import CoreFoundation

/// Only known provider fields are accepted. Missing data is never treated as zero usage.
public enum UsageParser {
    public static func parse(_ data: Data, provider: Provider, now: Date = Date(),
                             copilotMonthlyAllowance: Double? = nil) throws -> UsageSnapshot {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw UsageError.message("The provider returned an unexpected response.")
        }
        let windows: [UsageWindow]
        switch provider {
        case .anthropic: windows = anthropic(json)
        case .openAI: windows = openAI(json, now: now)
        case .moonshot: windows = kimi(json)
        case .deepSeek: windows = []
        case .openCode: windows = openCode(json)
        case .githubCopilot: windows = try copilot(json, monthlyAllowance: copilotMonthlyAllowance)
        }
        guard !windows.isEmpty else {
            if provider == .githubCopilot { throw CopilotQuotaUnavailable(json: json) }
            throw UsageError.message("No supported usage limits were returned. Check your subscription and credential type.")
        }
        return UsageSnapshot(windows: windows, fetchedAt: now)
    }

    static func number(_ value: Any?) -> Double? {
        if let n = value as? NSNumber {
            guard CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue.isFinite else { return nil }
            return n.doubleValue
        }
        if let s = value as? String, let n = Double(s.trimmingCharacters(in: .whitespacesAndNewlines)),
           n.isFinite { return n }
        return nil
    }

    static func date(_ value: Any?) -> Date? {
        if let s = value as? String {
            let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: trimmed) { return date }
            formatter.formatOptions = [.withInternetDateTime]
            if let date = formatter.date(from: trimmed) { return date }
        }
        guard let epoch = number(value), epoch > 0 else { return nil }
        return Date(timeIntervalSince1970: epoch > 100_000_000_000 ? epoch / 1000 : epoch)
    }

    static func window(_ raw: Any?, id: String, label: String, duration: Double,
                       percentKey: String, resetKey: String) -> UsageWindow? {
        guard let obj = raw as? [String: Any], let percent = number(obj[percentKey]), percent >= 0 else { return nil }
        return UsageWindow(id: id, label: label, usedPercent: percent, duration: duration, resetsAt: date(obj[resetKey]))
    }

    static func anthropic(_ json: [String: Any]) -> [UsageWindow] {
        var result: [UsageWindow] = []
        if let limits = json["limits"] as? [[String: Any]] {
            for (index, limit) in limits.enumerated() {
                guard let kind = limit["kind"] as? String,
                      kind == "session" || kind.hasPrefix("weekly"),
                      limit["is_active"] as? Bool != false else { continue }
                let scope = limit["scope"] as? [String: Any]
                let model = scope?["model"] as? [String: Any]
                let name = model?["display_name"] as? String
                let scopeID = model?["id"] as? String ?? name
                let id = kind == "weekly_scoped" ? "\(kind)-\(scopeID ?? String(index))" : kind
                if let item = window(limit, id: id,
                    label: kind == "session" ? "5-hour" : name.map { "Weekly · \($0)" } ?? "Weekly",
                    duration: kind == "session" ? 18_000 : 604_800, percentKey: "percent", resetKey: "resets_at") {
                    result.append(item)
                }
            }
        }
        if result.isEmpty {
            for (key, label, seconds) in [
                ("five_hour", "5-hour", 18_000.0), ("seven_day", "Weekly", 604_800),
                ("seven_day_opus", "Weekly · Opus", 604_800), ("seven_day_sonnet", "Weekly · Sonnet", 604_800)
            ] {
                if let item = window(json[key], id: key, label: label, duration: seconds,
                                     percentKey: "utilization", resetKey: "resets_at") { result.append(item) }
            }
        }
        return result
    }

    static func durationLabel(_ seconds: Double) -> String {
        if seconds >= 28 * 86_400 { return "Monthly" }
        if seconds == 604_800 { return "Weekly" }
        if seconds == 86_400 { return "Daily" }
        if seconds >= 86_400 { return "\(Int(seconds / 86_400))-day" }
        if seconds >= 3_600 { return "\(seconds / 3_600, specifier: "%g")-hour" }
        return "\(Int(seconds / 60))-minute"
    }

    static func openAI(_ json: [String: Any], now: Date) -> [UsageWindow] {
        var result: [UsageWindow] = []
        func append(_ raw: Any?, prefix: String, title: String = "") {
            guard let limit = raw as? [String: Any] else { return }
            for key in ["primary_window", "secondary_window"] {
                guard let obj = limit[key] as? [String: Any],
                      let percent = number(obj["used_percent"]), percent >= 0,
                      let seconds = number(obj["limit_window_seconds"]), seconds > 0 else { continue }
                let reset = date(obj["reset_at"]) ?? number(obj["reset_after_seconds"]).map { now.addingTimeInterval($0) }
                result.append(UsageWindow(id: "\(prefix)-\(key)", label: title + durationLabel(seconds),
                                          usedPercent: percent, duration: seconds, resetsAt: reset))
            }
        }
        append(json["rate_limit"], prefix: "main")
        if let extras = json["additional_rate_limits"] as? [[String: Any]] {
            for (index, extra) in extras.enumerated() {
                let title = extra["limit_name"] as? String ?? extra["title"] as? String ?? "Additional"
                let id = extra["id"] as? String ?? extra["limit_name"] as? String ?? String(index)
                append(extra["rate_limit"] ?? extra, prefix: id, title: title + " · ")
            }
        }
        append(json["code_review_rate_limit"], prefix: "review", title: "Code review · ")
        return result
    }

    static func kimi(_ json: [String: Any]) -> [UsageWindow] {
        var result: [UsageWindow] = []
        func counts(_ raw: Any?, id: String, label: String, duration: Double) -> UsageWindow? {
            guard let obj = raw as? [String: Any], let limit = number(obj["limit"]), limit > 0,
                  let used = number(obj["used"]) ?? number(obj["remaining"]).map({ limit - $0 }),
                  used >= 0 else { return nil }
            return UsageWindow(id: id, label: label, usedPercent: used / limit * 100, duration: duration,
                               resetsAt: date(obj["resetTime"] ?? obj["reset_at"]))
        }
        if let limits = json["limits"] as? [[String: Any]] {
            for (index, limit) in limits.enumerated() {
                let w = limit["window"] as? [String: Any]
                guard let duration = number(w?["duration"]), duration > 0,
                      let unit = w?["timeUnit"] as? String else { continue }
                let multiplier: Double
                if unit.contains("MINUTE") { multiplier = 60 }
                else if unit.contains("HOUR") { multiplier = 3_600 }
                else if unit.contains("DAY") { multiplier = 86_400 }
                else if unit.contains("SECOND") { multiplier = 1 }
                else { continue }
                let seconds = duration * multiplier
                if let item = counts(limit["detail"], id: seconds == 18_000 ? "5h" : "count-\(index)",
                                     label: durationLabel(seconds), duration: seconds) { result.append(item) }
            }
        }
        if let weekly = counts(json["usage"], id: "weekly", label: "Weekly", duration: 604_800) { result.append(weekly) }
        if let usages = json["usages"] as? [String: Any] {
            for (key, id, label, duration) in [
                ("limit_5h", "5h", "5-hour", 18_000.0),
                ("limit_7d", "weekly", "Weekly", 604_800),
                ("limit_month_total", "monthly", "Monthly", 2_592_000),
                ("limit_month_code", "monthly-code", "Monthly · Code", 2_592_000)
            ] {
                // Counts are authoritative: ratio-only legacy fields can incorrectly return zero.
                guard !result.contains(where: { $0.id == id }),
                      let obj = usages[key] as? [String: Any],
                      let ratio = number(obj["used_ratio"]), ratio >= 0 else { continue }
                result.append(UsageWindow(id: id, label: label, usedPercent: ratio * 100,
                                          duration: duration, resetsAt: date(obj["reset_time"])))
            }
        }
        return result
    }

    static func openCode(_ json: [String: Any]) -> [UsageWindow] {
        guard let usage = json["usage"] as? [String: Any] else { return [] }
        return [("rolling", "5-hour", 18_000.0), ("weekly", "Weekly", 604_800), ("monthly", "Monthly", 2_592_000)]
            .compactMap { key, label, seconds in
                window(usage[key], id: key, label: label, duration: seconds, percentKey: "percent", resetKey: "resetsAt")
            }
    }

    static func copilot(_ json: [String: Any], monthlyAllowance: Double? = nil) throws -> [UsageWindow] {
        func resetDate(_ raw: Any?) -> Date? {
            if let parsed = date(raw) { return parsed }
            guard let value = raw as? String,
                  value.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil else { return nil }
            return date(value + "T00:00:00Z")
        }
        let reset = resetDate(json["quota_reset_date_utc"]) ?? resetDate(json["quota_reset_date"])
        let snapshots = json["quota_snapshots"] as? [String: Any] ?? [:]
        var result: [UsageWindow] = []
        for (key, label) in [
            ("premium_interactions", "Monthly · Premium"),
            ("chat", "Monthly · Chat"),
            ("completions", "Monthly · Completions")
        ] {
            guard let quota = snapshots[key] as? [String: Any],
                  quota["unlimited"] as? Bool != true,
                  quota["has_quota"] as? Bool != false else { continue }
            let entitlement = number(quota["entitlement"])
            if let entitlement, entitlement <= 0 { continue } // Unlimited / inapplicable sentinel.
            let usesCredits = quota["token_based_billing"] as? Bool == true || json["token_based_billing"] as? Bool == true
            let reportedCredits = number(quota["credits_used"]).flatMap { $0 >= 0 ? $0 : nil }
            let percent: Double
            if let remaining = number(quota["percent_remaining"]), remaining <= 100 {
                percent = 100 - remaining
            } else if let entitlement, entitlement > 0,
                      let remaining = number(quota["quota_remaining"]) ?? number(quota["remaining"]) {
                percent = (entitlement - remaining) / entitlement * 100
            } else if usesCredits, let entitlement, let used = reportedCredits {
                percent = used >= entitlement ? 100 : used / entitlement * 100
            } else { continue }
            let resolvedLabel = key == "premium_interactions" && usesCredits ? "Monthly · Credits" : label
            result.append(UsageWindow(id: key, label: resolvedLabel, usedPercent: percent, duration: 2_592_000,
                                      resetsAt: resetDate(quota["quota_reset_at"]) ?? reset,
                                      usedCredits: usesCredits ? reportedCredits : nil,
                                      creditAllowance: usesCredits ? entitlement : nil))
        }
        // Older free-plan responses report remaining counts in a separate pair of objects.
        if let remaining = json["limited_user_quotas"] as? [String: Any],
           let limits = json["monthly_quotas"] as? [String: Any] {
            for (key, label) in [("chat", "Monthly · Chat"), ("completions", "Monthly · Completions")] {
                guard snapshots[key] == nil, let limit = number(limits[key]), limit > 0,
                      let left = number(remaining[key]), left >= 0 else { continue }
                result.append(UsageWindow(id: key, label: label, usedPercent: (limit - left) / limit * 100,
                                          duration: 2_592_000, resetsAt: resetDate(json["limited_user_reset_date"]) ?? reset))
            }
        }
        // A provider-reported premium limit always wins over a saved manual allowance.
        // The snapshots can repeat the same consumption; take one known source, never sum.
        if !result.contains(where: { $0.id == "premium_interactions" }),
           json["access_type_sku"] as? String != "subscription_ended" {
            let known = ["premium_interactions", "chat", "completions"].compactMap { snapshots[$0] as? [String: Any] }
            let creditBilling = json["token_based_billing"] as? Bool == true ||
                known.contains { $0["token_based_billing"] as? Bool == true }
            if (creditBilling || result.isEmpty),
               let credits = known.compactMap({ number($0["credits_used"]) }).first,
               credits >= 0 {
                let usage = CopilotCreditUsage(usedCredits: credits, resetsAt: reset)
                guard let monthlyAllowance else { throw CopilotAllowanceRequired(usage: usage) }
                result.append(try usage.window(monthlyAllowance: monthlyAllowance))
            }
        }
        return result
    }
}

private extension String.StringInterpolation {
    mutating func appendInterpolation(_ value: Double, specifier: String) {
        appendLiteral(String(format: specifier, value))
    }
}
