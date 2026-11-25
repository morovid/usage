import Foundation

public struct CopilotCreditUsage: Sendable {
    public let usedCredits: Double
    public let resetsAt: Date?

    public static func parseAllowance(_ input: String, locale: Locale = .current) -> Double? {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let separator = locale.decimalSeparator ?? "."
        if separator != "." {
            guard !text.contains(".") else { return nil }
            text = text.replacingOccurrences(of: separator, with: ".")
        }
        guard text.range(of: #"^(?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+)$"#, options: .regularExpression) != nil,
              let value = Double(text), value.isFinite, value > 0 else { return nil }
        return value
    }

    public func window(monthlyAllowance: Double) throws -> UsageWindow {
        guard monthlyAllowance.isFinite, monthlyAllowance > 0 else {
            throw UsageError.message("Enter a monthly allowance greater than zero, in GitHub credits.")
        }
        return UsageWindow(id: "premium_interactions", label: "Monthly · Credits",
                           usedPercent: usedCredits >= monthlyAllowance ? 100 : usedCredits / monthlyAllowance * 100,
                           duration: 2_592_000,
                           resetsAt: resetsAt, usedCredits: usedCredits, creditAllowance: monthlyAllowance,
                           isUserProvidedAllowance: true)
    }
}

public struct CopilotAllowanceRequired: LocalizedError, Sendable {
    public let usage: CopilotCreditUsage
    public var errorDescription: String? {
        "GitHub reports consumed credits but no finite monthly allowance. Enter your monthly allowance in GitHub credits to calculate usage and enable alerts. This is a user-provided monitoring limit, not an enforced GitHub cap."
    }
}
