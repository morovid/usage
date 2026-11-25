import Foundation

/// Deliberately allowlisted response diagnostics: no tokens, IDs, organization names,
/// arbitrary response keys, or raw response bodies are exposed.
public struct CopilotQuotaUnavailable: LocalizedError, Sendable {
    public enum Reason: String, Sendable {
        case subscriptionEnded, creditBillingWithoutLimit, unlimited, noSnapshots, unsupportedSnapshots
    }
    public let reason: Reason
    public let diagnosticSummary: String

    init(json: [String: Any]) {
        let snapshots = json["quota_snapshots"] as? [String: Any]
        let known = ["premium_interactions", "chat", "completions"].compactMap { key -> [String: Any]? in
            snapshots?[key] as? [String: Any]
        }
        if json["access_type_sku"] as? String == "subscription_ended" {
            reason = .subscriptionEnded
        } else if json["token_based_billing"] as? Bool == true ||
                    known.contains(where: { $0["token_based_billing"] as? Bool == true }) {
            reason = .creditBillingWithoutLimit
        } else if !known.isEmpty && known.allSatisfy({ $0["unlimited"] as? Bool == true }) {
            reason = .unlimited
        } else if snapshots == nil || snapshots?.isEmpty == true {
            reason = .noSnapshots
        } else {
            reason = .unsupportedSnapshots
        }

        func flag(_ raw: Any?) -> String {
            guard let value = raw as? Bool else { return "not reported" }
            return value ? "yes" : "no"
        }
        let categories = ["premium_interactions", "chat", "completions"].map { key in
            guard let quota = snapshots?[key] as? [String: Any] else { return "\(key): absent" }
            let entitlement = UsageParser.number(quota["entitlement"])
            let limit = entitlement.map { $0 > 0 ? "positive" : "zero/unlimited sentinel" } ?? "absent"
            let percent = UsageParser.number(quota["percent_remaining"]) == nil ? "absent" : "present"
            let credits = UsageParser.number(quota["credits_used"]) == nil ? "absent" : "present"
            return "\(key): limit \(limit), percent \(percent), unlimited \(flag(quota["unlimited"])), credits_used \(credits)"
        }
        diagnosticSummary = "Quota snapshots: \(snapshots == nil ? "absent" : "present"). " +
            "Credit billing: \(flag(json["token_based_billing"])). " + categories.joined(separator: "; ") + "."
    }

    public var errorDescription: String? {
        let explanation: String
        switch reason {
        case .subscriptionEnded:
            explanation = "GitHub reports that this Copilot subscription has ended."
        case .creditBillingWithoutLimit:
            explanation = "GitHub reports credit-based Copilot billing, but no usable finite allowance. Usage cannot calculate a percentage without a reported limit."
        case .unlimited:
            explanation = "GitHub reports only unlimited Copilot categories, not a finite quota to monitor."
        case .noSnapshots:
            explanation = "GitHub accepted the request but returned no quota snapshots. This can be an endpoint/token restriction; it does not prove that your account lacks Copilot."
        case .unsupportedSnapshots:
            explanation = "GitHub returned quota snapshots without a usable finite limit. This may be a plan-specific placeholder or an unsupported response."
        }
        return explanation + " For organization-funded seats, personal billing reports exclude this usage; organization/enterprise billing access generally requires an owner, billing role, or delegated permission. " +
            "Diagnostic: " + diagnosticSummary
    }
}
