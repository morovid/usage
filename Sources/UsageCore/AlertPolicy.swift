import Foundation

public struct AlertState: Codable, Equatable, Sendable {
    public var highestThreshold: Int = 0
    public var resetsAt: Date?
    public init(highestThreshold: Int = 0, resetsAt: Date? = nil) {
        self.highestThreshold = highestThreshold
        self.resetsAt = resetsAt
    }
}

public struct AlertDecision: Sendable {
    public var threshold: Int?
    public var state: AlertState
}

public enum AlertPolicy {
    /// Notify once per threshold per app run. A jump to 100% emits just the exhausted alert.
    /// Keep the returned state in memory only; usage drops and window resets do not re-arm it.
    public static func evaluate(_ window: UsageWindow, previous: AlertState?, now: Date = Date()) -> AlertDecision {
        var state = previous ?? AlertState()
        state.resetsAt = window.resetsAt
        let threshold = window.usedPercent >= 100 ? 100 : window.usedPercent >= 70 ? 70 : 0
        if threshold > state.highestThreshold {
            state.highestThreshold = threshold
            return AlertDecision(threshold: threshold, state: state)
        }
        return AlertDecision(threshold: nil, state: state)
    }
}
